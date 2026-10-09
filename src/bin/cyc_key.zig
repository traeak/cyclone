//! cyc-key: make an ATS cache key from a cache-key URL.

const std = @import("std");
const Io = std.Io;
const cyclone = @import("cyclone");
const cli = cyclone.cli;
const url_mod = cyclone.url;

const usage =
    \\usage: cyc-key [options] URL...
    \\       cyc-key [options] -          (URLs from stdin, one per line)
    \\
    \\Make an ATS cache key from a cache-key URL, the way ATS master does
    \\(url_CryptoHash_get). Prints the key as hex. With more than one URL, or
    \\with -, each line is KEY<TAB>URL.
    \\
    \\options:
    \\
++ cli.Common.hash_help ++
    \\  --ignore-query      leave the query out (proxy.config.http.cache.ignore_query)
    \\  --generation N      add a cache generation (proxy.config.http.cache.generation)
    \\  --compat-92         hash as ATS 9.2 did (";" after the path)
    \\  --explain           show the parsed URL and the exact bytes that are hashed
    \\
;

const Options = struct {
    hash_type: cyclone.HashType = .default,
    key: url_mod.KeyOptions = .{},
    explain: bool = false,
    with_url: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var opts: Options = .{};
    var urls: std.ArrayList([]const u8) = .empty;
    var from_stdin = false;

    var it: cli.ArgIterator = .init(args);
    while (it.next()) |arg| {
        if (cli.isHelp(arg)) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, arg, "--hash")) {
            const name = it.value(arg);
            opts.hash_type = cyclone.HashType.parse(name) orelse cli.fatal("unknown hash type '{s}'", .{name});
        } else if (std.mem.eql(u8, arg, "--ignore-query")) {
            opts.key.ignore_query = true;
        } else if (std.mem.eql(u8, arg, "--generation")) {
            const text = it.value(arg);
            opts.key.generation = std.fmt.parseInt(i64, text, 10) catch cli.fatal("bad generation '{s}'", .{text});
        } else if (std.mem.eql(u8, arg, "--compat-92")) {
            opts.key.compat_92 = true;
        } else if (std.mem.eql(u8, arg, "--explain")) {
            opts.explain = true;
        } else if (std.mem.eql(u8, arg, "-")) {
            from_stdin = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            cli.fatal("unknown option '{s}'\n\n{s}", .{ arg, usage });
        } else {
            try urls.append(arena, arg);
        }
    }
    if (urls.items.len == 0 and !from_stdin) cli.fatal("no URL given\n\n{s}", .{usage});
    opts.with_url = from_stdin or urls.items.len > 1;

    var out_buf: [4096]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const out = &out_file.interface;

    var failed = false;
    for (urls.items) |text| {
        if (!try emit(out, text, opts)) failed = true;
    }
    if (from_stdin) {
        var in_buf: [16 * 1024]u8 = undefined;
        var in_file: Io.File.Reader = .init(.stdin(), init.io, &in_buf);
        while (try in_file.interface.takeDelimiter('\n')) |line| {
            const text = std.mem.trimEnd(u8, line, "\r");
            if (text.len == 0) continue;
            if (!try emit(out, text, opts)) failed = true;
        }
    }
    try out.flush();
    if (failed) std.process.exit(1);
}

/// Prints the key for one URL. Returns false if the URL did not parse.
fn emit(out: *Io.Writer, text: []const u8, opts: Options) !bool {
    const url = url_mod.Url.parse(text) catch |err| {
        try out.flush();
        std.debug.print("cyc: cannot parse '{s}': {s}\n", .{ text, @errorName(err) });
        return false;
    };
    const key = url.cacheKey(opts.hash_type, opts.key);
    if (opts.explain) {
        try explain(out, text, &url, opts);
        try out.print("key         {f}\n\n", .{key});
    } else if (opts.with_url) {
        try out.print("{f}\t{s}\n", .{ key, text });
    } else {
        try out.print("{f}\n", .{key});
    }
    return true;
}

fn explain(out: *Io.Writer, text: []const u8, url: *const url_mod.Url, opts: Options) !void {
    try out.print("url         {s}\n", .{text});
    inline for (.{ "scheme", "user", "password", "host", "path", "query", "fragment" }) |field| {
        const value = @field(url, field);
        if (value.len != 0) try out.print("  {s: <9} {s}\n", .{ field, value });
    }
    try out.print("  {s: <9} {d}{s}\n", .{ "port", url.canonicalPort(), if (url.port == 0) " (default)" else "" });

    var buf: [8192]u8 = undefined;
    var canon: Io.Writer = .fixed(&buf);
    url.writeCanonical(&canon, opts.key) catch return error.UrlTooLong;
    try out.writeAll("hashed      \"");
    for (canon.buffered()) |c| {
        if (std.ascii.isPrint(c) and c != '"' and c != '\\') try out.writeByte(c) else try out.print("\\x{x:0>2}", .{c});
    }
    const port = url.canonicalPort();
    try out.print("\" + port {d} ({x:0>2} {x:0>2})", .{ port, port & 0xff, port >> 8 });
    if (opts.key.generation != -1) try out.print(" + generation {d} (i64 LE)", .{opts.key.generation});
    try out.print("\nhash        {s}\n", .{@tagName(opts.hash_type)});
}
