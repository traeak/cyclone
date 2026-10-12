//! cyclone-d: serves lookups and objects from an ATS cache over HTTP/1.1,
//! on unix domain sockets and TCP.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const cyclone = @import("cyclone");
const cli = cyclone.cli;
const Span = cyclone.Span;
const http_server = cyclone.http_server;

const usage =
    \\usage: cyclone-d --span PATH... (--unix PATH | --listen HOST:PORT)... [options]
    \\
    \\Serve lookups and objects from an ATS cache over HTTP/1.1. The cache must
    \\not be in use: nothing else may write the spans while this runs.
    \\
    \\  GET /v1/key?url=U
    \\  GET /v1/lookup/KEY        or ?url=U
    \\  GET /v1/object/KEY        or ?url=U    [&alt=N] [&range=SPEC]
    \\  GET /v1/body/KEY          or ?url=U    [&alt=N]    (Range, If-Range)
    \\
    \\KEY is a cache key in hex; U a cache-key URL, percent-encoded. Without alt,
    \\the alternate is chosen as ATS would for the request's own header fields.
    \\
    \\options:
    \\
++ cli.Common.help ++
    \\  --volumes N,M,...   volumes of the host record, in order (as for cyc-lookup)
    \\  --unix PATH         listen on a unix domain socket; repeatable. A stale socket
    \\                      file at PATH is removed first
    \\  --listen HOST:PORT  listen on TCP; repeatable ([::1]:PORT for IPv6)
    \\  --max-connections N connections served at once (default 256); beyond that,
    \\                      accepting waits
    \\  --record NAME=VALUE a records.yaml setting alternate selection follows (see
    \\                      cyc-doc --help)
    \\  --access-log        log each request to stderr
    \\
;

const Listener = struct {
    name: []const u8,
    server: net.Server,
};

const Shared = struct {
    svc: *cyclone.service.Service,
    options: http_server.Options,
    max_connections: u32,
    active: std.atomic.Value(u32) = .init(0),
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var common: cli.Common = .{};
    var volumes: ?[]const i32 = null;
    var unix_paths: std.ArrayList([]const u8) = .empty;
    var tcp: std.ArrayList([]const u8) = .empty;
    var select_config: cyclone.select.Config = .{};
    var options: http_server.Options = .{};
    var max_connections: u32 = 256;

    var it: cli.ArgIterator = .init(args);
    while (it.next()) |arg| {
        if (cli.isHelp(arg)) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (try common.parse(arena, arg, &it)) {
            continue;
        } else if (std.mem.eql(u8, arg, "--volumes")) {
            volumes = try cli.parseVolumes(arena, it.value(arg));
        } else if (std.mem.eql(u8, arg, "--unix")) {
            try unix_paths.append(arena, it.value(arg));
        } else if (std.mem.eql(u8, arg, "--listen")) {
            try tcp.append(arena, it.value(arg));
        } else if (std.mem.eql(u8, arg, "--max-connections")) {
            const text = it.value(arg);
            max_connections = std.fmt.parseInt(u32, text, 10) catch cli.fatal("bad --max-connections '{s}'", .{text});
            if (max_connections == 0) cli.fatal("--max-connections must be positive", .{});
        } else if (std.mem.eql(u8, arg, "--record")) {
            cli.parseRecord(&select_config, it.value(arg));
        } else if (std.mem.eql(u8, arg, "--access-log")) {
            options.access_log = true;
        } else {
            cli.fatal("unknown argument '{s}'\n\n{s}", .{ arg, usage });
        }
    }
    if (common.spans.items.len == 0) cli.fatal("give every --span, in storage.yaml order\n\n{s}", .{usage});
    if (unix_paths.items.len == 0 and tcp.items.len == 0) cli.fatal("give at least one --unix PATH or --listen HOST:PORT", .{});

    const spans = try arena.alloc(Span, common.spans.items.len);
    for (common.spans.items, spans) |a, *sp| {
        sp.* = Span.open(gpa, io, a.path, .{ .seed = a.seed, .skip = a.skip }) catch |err|
            cli.fatal("{s}: cannot open the span: {s}", .{ a.path, @errorName(err) });
    }
    defer for (spans) |*sp| sp.close(gpa, io);
    var cache = cyclone.Cache.init(gpa, io, spans, common.cacheConfig(volumes)) catch |err| switch (err) {
        error.NoStripes => cli.fatal("no stripes{s}", .{if (volumes != null) " in the given --volumes" else ""}),
        else => return err,
    };
    defer cache.deinit();
    const unusable = try cache.openAll();
    if (unusable != 0) std.debug.print("cyclone-d: {d} stripe(s) have no usable directory (is --avg-obj-size right?); their objects will miss\n", .{unusable});

    var svc: cyclone.service.Service = .{ .cache = &cache, .select_config = select_config };
    var shared: Shared = .{ .svc = &svc, .options = options, .max_connections = max_connections };

    var listeners: std.ArrayList(Listener) = .empty;
    defer for (listeners.items) |*l| l.server.deinit(io);
    for (unix_paths.items) |path| {
        removeStaleSocket(io, path);
        const addr = net.UnixAddress.init(path) catch cli.fatal("--unix {s}: path too long", .{path});
        const server = addr.listen(io, .{}) catch |err| cli.fatal("--unix {s}: {s}", .{ path, @errorName(err) });
        try listeners.append(arena, .{ .name = path, .server = server });
    }
    for (tcp.items) |text| {
        const addr = parseHostPort(text) orelse cli.fatal("--listen wants HOST:PORT, got '{s}'", .{text});
        const server = addr.listen(io, .{ .reuse_address = true }) catch |err| cli.fatal("--listen {s}: {s}", .{ text, @errorName(err) });
        try listeners.append(arena, .{ .name = text, .server = server });
    }
    for (listeners.items) |l| std.debug.print("cyclone-d: listening on {s}\n", .{l.name});

    // One accept loop per listener; the last runs on this thread.
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (listeners.items[0 .. listeners.items.len - 1]) |*l| {
        group.concurrent(io, acceptLoop, .{ &shared, io, l }) catch
            cli.fatal("cannot run {d} listeners at once", .{listeners.items.len});
    }
    acceptLoop(&shared, io, &listeners.items[listeners.items.len - 1]);
}

fn acceptLoop(shared: *Shared, io: Io, l: *Listener) void {
    var conns: Io.Group = .init;
    defer conns.cancel(io);
    while (true) {
        const stream = l.server.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            error.ConnectionAborted => continue,
            else => {
                std.debug.print("cyclone-d: {s}: accept: {s}\n", .{ l.name, @errorName(err) });
                // Out of descriptors and the like: back off a little.
                io.sleep(.fromMilliseconds(100), .awake) catch return;
                continue;
            },
        };
        // Beyond the limit, or when no task can start, serve on this one:
        // accepting waits meanwhile.
        if (shared.active.fetchAdd(1, .monotonic) < shared.max_connections) {
            if (conns.concurrent(io, serveCounted, .{ shared, io, stream })) continue else |_| {}
        }
        serveCounted(shared, io, stream);
    }
}

fn serveCounted(shared: *Shared, io: Io, stream: net.Stream) void {
    defer _ = shared.active.fetchSub(1, .monotonic);
    http_server.serveConnection(shared.svc, io, stream, shared.options);
}

/// HOST:PORT, with [IPv6]:PORT.
fn parseHostPort(text: []const u8) ?net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    var host = text[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    return net.IpAddress.parse(host, port) catch null;
}

/// Removes a unix socket left by an earlier run; anything else at the path
/// stays, and listening then fails.
fn removeStaleSocket(io: Io, path: []const u8) void {
    const cwd = Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch return;
    if (st.kind == .unix_domain_socket) cwd.deleteFile(io, path) catch {};
}
