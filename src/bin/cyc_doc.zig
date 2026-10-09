//! cyc-doc: read cached objects, and inspect the structures that hold them.

const std = @import("std");
const Io = std.Io;
const cyclone = @import("cyclone");
const cli = cyclone.cli;
const Span = cyclone.Span;

const usage =
    \\usage: cyc-doc span --span PATH... [--json]
    \\
    \\Read cached objects, and inspect the structures that hold them.
    \\
    \\commands:
    \\  span                show span headers and their stripe blocks
    \\  (object reading, stripe and dir commands: not implemented yet)
    \\
    \\options:
    \\
++ cli.Common.help ++
    \\  --json              machine-readable output
    \\
;

const Command = enum { span };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var common: cli.Common = .{};
    var json = false;
    var command: ?Command = null;

    var it: cli.ArgIterator = .init(args);
    while (it.next()) |arg| {
        if (cli.isHelp(arg)) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (try common.parse(arena, arg, &it)) {
            continue;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (command == null and !std.mem.startsWith(u8, arg, "-")) {
            command = std.meta.stringToEnum(Command, arg) orelse cli.fatal("unknown command '{s}'\n\n{s}", .{ arg, usage });
        } else {
            cli.fatal("unknown argument '{s}'\n\n{s}", .{ arg, usage });
        }
    }

    var out_buf: [8192]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const out = &out_file.interface;

    switch (command orelse cli.fatal("no command given\n\n{s}", .{usage})) {
        .span => try spanCommand(init.gpa, init.io, arena, out, common.spans.items, json),
    }
    try out.flush();
}

fn spanCommand(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, out: *Io.Writer, spans: []const cli.SpanArg, json: bool) !void {
    if (spans.len == 0) cli.fatal("span needs at least one --span", .{});

    var reports: std.ArrayList(SpanReport) = .empty;
    for (spans) |arg| {
        var span = Span.open(gpa, io, arg.path, .{ .seed = arg.seed, .skip = arg.skip }) catch |err| {
            try out.flush();
            cli.fatal("{s}: {s}", .{ arg.path, describeOpenError(err) });
        };
        defer span.close(gpa, io);
        try reports.append(arena, try .init(arena, &span));
    }

    if (json) {
        try std.json.Stringify.value(reports.items, .{ .whitespace = .indent_2 }, out);
        try out.writeByte('\n');
        return;
    }
    for (reports.items, 0..) |r, i| {
        if (i != 0) try out.writeByte('\n');
        try printSpan(out, r);
    }
}

/// Everything `span` shows, in a shape that serializes directly to JSON.
const SpanReport = struct {
    path: []const u8,
    seed: []const u8,
    size: u64,
    skip: u64,
    data_start: u64,
    num_volumes: u32,
    num_used: u32,
    num_free: u32,
    num_blocks: u64,
    blocks: []const Block,
    issues: []const cyclone.span.Issue,

    const Block = struct {
        index: usize,
        volume: i32,
        type: []const u8,
        free: bool,
        offset: u64,
        len_blocks: u64,
        len_bytes: u64,
        hash_text: ?[]const u8,
    };

    fn init(arena: std.mem.Allocator, span: *const Span) !SpanReport {
        const blocks = try arena.alloc(Block, span.blocks.len);
        for (span.blocks, blocks, 0..) |b, *r, i| {
            var hash_text: ?[]const u8 = null;
            if (!b.free) {
                var w: Io.Writer.Allocating = .init(arena);
                try span.stripeHashText(&w.writer, b);
                hash_text = w.written();
            }
            r.* = .{
                .index = i,
                .volume = b.number,
                .type = std.enums.tagName(cyclone.format.span.CacheType, b.type) orelse "unknown",
                .free = b.free,
                .offset = b.offset,
                .len_blocks = b.len,
                .len_bytes = b.byteLen(),
                .hash_text = hash_text,
            };
        }
        return .{
            .path = span.path,
            .seed = span.seed,
            .size = span.size,
            .skip = span.skip,
            .data_start = span.dataStart(),
            .num_volumes = span.header.num_volumes,
            .num_used = span.header.num_used,
            .num_free = span.header.num_free,
            .num_blocks = span.header.num_blocks,
            .blocks = blocks,
            .issues = try span.check(arena),
        };
    }
};

fn printSpan(out: *Io.Writer, r: SpanReport) !void {
    try out.print("span        {s}\n", .{r.path});
    if (!std.mem.eql(u8, r.seed, r.path)) try out.print("seed        {s}\n", .{r.seed});
    try out.print("size        {d} bytes ({Bi:.1})\n", .{ r.size, r.size });
    try out.print("header at   {d}\n", .{r.skip});
    try out.print("data start  {d}\n", .{r.data_start});
    try out.print("num_blocks  {d} store blocks\n", .{r.num_blocks});
    try out.print("volumes     {d}   blocks used {d}, free {d}\n\n", .{ r.num_volumes, r.num_used, r.num_free });

    try out.print("  {s: >3}  {s: >6}  {s: <5}  {s: <4}  {s: >14}  {s: >10}  {s}\n", .{ "#", "volume", "type", "use", "offset", "length", "hash text" });
    for (r.blocks) |b| {
        var len_buf: [32]u8 = undefined;
        const len = std.fmt.bufPrint(&len_buf, "{Bi:.1}", .{b.len_bytes}) catch "?";
        var vol_buf: [16]u8 = undefined;
        const vol = if (b.free) "-" else std.fmt.bufPrint(&vol_buf, "{d}", .{b.volume}) catch "?";
        try out.print("  {d: >3}  {s: >6}  {s: <5}  {s: <4}  {d: >14}  {s: >10}  {s}\n", .{
            b.index, vol, b.type, if (b.free) "free" else "used", b.offset, len, b.hash_text orelse "",
        });
    }
    if (r.issues.len != 0) {
        try out.writeAll("\n");
        for (r.issues) |issue| try out.print("{s}: {s}\n", .{ @tagName(issue.severity), issue.message });
    }
}

fn describeOpenError(err: cyclone.span.OpenError) []const u8 {
    return switch (err) {
        error.NoDiskHeader => "no ATS span header found (wrong --skip, or not an ATS cache span)",
        error.CorruptHeader => "span header lists more stripe blocks than the span can hold",
        error.Truncated => "span is shorter than its header",
        error.FileNotFound => "no such file",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        else => @errorName(err),
    };
}
