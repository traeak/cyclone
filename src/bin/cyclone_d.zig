//! cyclone-d: serves lookups and objects from an ATS cache over HTTP/1.1,
//! on unix domain sockets and TCP.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const cyclone = @import("cyclone");
const cli = cyclone.cli;
const Span = cyclone.Span;
const http_server = cyclone.http_server;
const posix = std.posix;
const linux = std.os.linux;

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
    \\  GET /v1/stripes[/S:B]     [?stats=1]
    \\  GET /v1/dir[/S:B]         [?segment=N] [&docs=1] [&heads=1] [&valid=1]   (JSON lines)
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
    \\  --disk-directories  read directories from the spans for each lookup instead
    \\                      of loading them into memory at startup (memory: 10 bytes
    \\                      per directory entry, as ATS itself uses)
    \\  --shutdown-timeout S
    \\                      on SIGTERM or SIGINT, how long requests in flight may
    \\                      take to finish before their connections are cut (default
    \\                      10); a second signal stops at once
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
    /// Connections being served.
    active: std.atomic.Value(u32) = .init(0),
    /// Set on SIGTERM or SIGINT.
    stopping: std.atomic.Value(bool) = .init(false),
    /// Sockets of the connections being served, so a shutdown can wake
    /// them. A connection leaves this before its socket is closed, and the
    /// shutdown holds `mutex` while it acts, so it never touches a socket
    /// that was closed and reused.
    mutex: Io.Mutex = .init,
    conns: std.AutoArrayHashMapUnmanaged(net.Socket.Handle, void) = .empty,
    gpa: std.mem.Allocator,

    /// Shuts down every connection's socket in the `how` direction.
    fn shutdownConnections(shared: *Shared, io: Io, how: net.ShutdownHow) void {
        shared.mutex.lockUncancelable(io);
        defer shared.mutex.unlock(io);
        for (shared.conns.keys()) |h| socketShutdown(io, h, how);
    }
};

fn socketShutdown(io: Io, handle: net.Socket.Handle, how: net.ShutdownHow) void {
    const stream: net.Stream = .{ .socket = .{ .handle = handle, .address = .{ .ip4 = .loopback(0) } } };
    stream.shutdown(io, how) catch {};
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // SIGTERM and SIGINT are read from a signalfd, not handled: block them
    // before any task starts, so every thread inherits the mask.
    var signals = posix.sigemptyset();
    posix.sigaddset(&signals, .TERM);
    posix.sigaddset(&signals, .INT);
    posix.sigprocmask(posix.SIG.BLOCK, &signals, null);
    const signal_fd = posix.signalfd(-1, &signals, linux.SFD.CLOEXEC) catch |err|
        cli.fatal("cannot watch for signals: {s}", .{@errorName(err)});
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var common: cli.Common = .{};
    var volumes: ?[]const i32 = null;
    var unix_paths: std.ArrayList([]const u8) = .empty;
    var tcp: std.ArrayList([]const u8) = .empty;
    var select_config: cyclone.select.Config = .{};
    var options: http_server.Options = .{};
    var max_connections: u32 = 256;
    var disk_directories = false;
    var shutdown_timeout: u32 = 10;

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
        } else if (std.mem.eql(u8, arg, "--shutdown-timeout")) {
            const text = it.value(arg);
            shutdown_timeout = std.fmt.parseInt(u32, text, 10) catch cli.fatal("bad --shutdown-timeout '{s}'", .{text});
        } else if (std.mem.eql(u8, arg, "--disk-directories")) {
            disk_directories = true;
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
    if (!disk_directories) {
        const t0 = Io.Clock.awake.now(io);
        const bytes = cache.loadDirectories() catch |err| cli.fatal("cannot load the directories: {s}", .{@errorName(err)});
        const ms = t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
        std.debug.print("cyclone-d: directories in memory: {Bi:.1} in {d} ms\n", .{ bytes, ms });
    }
    if (unusable != 0) std.debug.print("cyclone-d: {d} stripe(s) have no usable directory (is --avg-obj-size right?); their objects will miss\n", .{unusable});

    var svc: cyclone.service.Service = .{ .cache = &cache, .select_config = select_config };
    var shared: Shared = .{ .svc = &svc, .options = options, .max_connections = max_connections, .gpa = gpa };
    shared.options.stopping = &shared.stopping;
    defer shared.conns.deinit(gpa);

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

    // One accept loop per listener; this thread waits for a signal.
    var group: Io.Group = .init;
    for (listeners.items) |*l| {
        group.concurrent(io, acceptLoop, .{ &shared, io, l }) catch
            cli.fatal("cannot run {d} listeners at once", .{listeners.items.len});
    }

    var info: linux.signalfd_siginfo = undefined;
    const signal_file: Io.File = .{ .handle = signal_fd, .flags = .{ .nonblocking = false } };
    _ = signal_file.readStreaming(io, &.{std.mem.asBytes(&info)}) catch |err|
        cli.fatal("reading signals: {s}", .{@errorName(err)});
    // A second signal stops the process at once.
    posix.sigprocmask(posix.SIG.UNBLOCK, &signals, null);
    const name = if (info.signo == @backingInt(posix.SIG.TERM)) "SIGTERM" else "SIGINT";
    std.debug.print("cyclone-d: {s}: stopping; {d} connection(s) open\n", .{ name, shared.active.load(.monotonic) });

    // Stop accepting, and wake idle connections: with their receiving side
    // shut, a connection waiting for its next request sees the end, and one
    // in the middle of a request finishes it and then closes.
    shared.stopping.store(true, .release);
    for (listeners.items) |*l| socketShutdown(io, l.server.socket.handle, .recv);
    shared.shutdownConnections(io, .recv);

    const deadline = Io.Clock.awake.now(io).addDuration(.fromSeconds(shutdown_timeout));
    while (shared.active.load(.monotonic) != 0 and Io.Clock.awake.now(io).compare(.lt, deadline)) {
        io.sleep(.fromMilliseconds(20), .awake) catch break;
    }
    const left = shared.active.load(.monotonic);
    if (left != 0) {
        std.debug.print("cyclone-d: {d} connection(s) still busy after {d} s; cutting them off\n", .{ left, shutdown_timeout });
        shared.shutdownConnections(io, .both);
        const cut = Io.Clock.awake.now(io).addDuration(.fromSeconds(2));
        while (shared.active.load(.monotonic) != 0 and Io.Clock.awake.now(io).compare(.lt, cut)) {
            io.sleep(.fromMilliseconds(20), .awake) catch break;
        }
    }
    for (unix_paths.items) |path| removeStaleSocket(io, path);
    if (shared.active.load(.monotonic) != 0) {
        std.debug.print("cyclone-d: connections did not end; exiting anyway\n", .{});
        std.process.exit(1);
    }
    group.await(io) catch {};
    std.debug.print("cyclone-d: stopped\n", .{});
}

fn acceptLoop(shared: *Shared, io: Io, l: *Listener) void {
    var conns: Io.Group = .init;
    defer conns.await(io) catch {};
    while (true) {
        const stream = l.server.accept(io) catch |err| {
            if (shared.stopping.load(.acquire)) return;
            switch (err) {
                error.Canceled => return,
                error.ConnectionAborted => continue,
                else => {
                    std.debug.print("cyclone-d: {s}: accept: {s}\n", .{ l.name, @errorName(err) });
                    // Out of descriptors and the like: back off a little.
                    io.sleep(.fromMilliseconds(100), .awake) catch return;
                    continue;
                },
            }
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
    const h = stream.socket.handle;
    {
        shared.mutex.lockUncancelable(io);
        defer shared.mutex.unlock(io);
        shared.conns.put(shared.gpa, h, {}) catch {};
        // Accepted as the shutdown began: answer one request at most.
        if (shared.stopping.load(.acquire)) socketShutdown(io, h, .recv);
    }
    http_server.serveConnection(shared.svc, io, stream, shared.options);
    {
        shared.mutex.lockUncancelable(io);
        defer shared.mutex.unlock(io);
        _ = shared.conns.swapRemove(h);
    }
    stream.close(io);
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
