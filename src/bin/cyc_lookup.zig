//! cyc-lookup: find where a cache key lives: its stripe, directory bucket,
//! and the entries whose tag matches.

const std = @import("std");
const Io = std.Io;
const cyclone = @import("cyclone");
const cli = cyclone.cli;
const assign = cyclone.assign;
const dir = cyclone.dir;

const usage =
    \\usage: cyc-lookup --span PATH... [options] KEY|URL...
    \\       cyc-lookup --span PATH... [options] -        (keys or URLs from stdin)
    \\       cyc-lookup --span PATH... [options] --table
    \\
    \\Find where cache keys live: the stripe ATS assigns them to, the directory
    \\bucket, and the entries whose tag matches. A 32-digit hex argument is a key
    \\(as cyc-key prints it); anything else is a cache-key URL.
    \\
    \\Tag matches are candidates: 12 bits of the key, so a match must still be
    \\confirmed against the full key in the Doc (not implemented yet).
    \\
    \\options:
    \\
++ cli.Common.help ++
    \\  --volumes N,M,...   volumes of the host record, in order: a hosting.config
    \\                      volume= list or @volume= remap directive (default: all
    \\                      volumes, in the order ATS finds them on the spans)
    \\  --table             show how the assignment table splits slots over stripes
    \\  --json              machine-readable output
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var common: cli.Common = .{};
    var volumes: ?[]const i32 = null;
    var show_table = false;
    var json = false;
    var inputs: std.ArrayList([]const u8) = .empty;
    var from_stdin = false;

    var it: cli.ArgIterator = .init(args);
    while (it.next()) |arg| {
        if (cli.isHelp(arg)) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (try common.parse(arena, arg, &it)) {
            continue;
        } else if (std.mem.eql(u8, arg, "--volumes")) {
            volumes = try parseVolumes(arena, it.value(arg));
        } else if (std.mem.eql(u8, arg, "--table")) {
            show_table = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "-")) {
            from_stdin = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            cli.fatal("unknown option '{s}'\n\n{s}", .{ arg, usage });
        } else {
            try inputs.append(arena, arg);
        }
    }
    if (common.spans.items.len == 0) cli.fatal("no --span given\n\n{s}", .{usage});
    if (!show_table and inputs.items.len == 0 and !from_stdin) cli.fatal("nothing to look up\n\n{s}", .{usage});

    var out_buf: [8192]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_file.interface;

    // Open every span: the table needs all of them, in order.
    const spans = try arena.alloc(cyclone.Span, common.spans.items.len);
    for (common.spans.items, spans) |arg, *s| {
        s.* = cyclone.Span.open(gpa, io, arg.path, .{ .seed = arg.seed, .skip = arg.skip }) catch |err|
            cli.fatal("{s}: {s}", .{ arg.path, @errorName(err) });
    }
    defer for (spans) |*s| s.close(gpa, io);

    const refs = try assign.collectStripes(arena, spans, volumes, common.hash_type);
    if (refs.len == 0) cli.fatal("no stripes{s}", .{if (volumes != null) " in the given --volumes" else ""});
    var table = try assign.Table.build(gpa, refs);
    defer table.deinit(gpa);

    var finder: Finder = .{ .gpa = gpa, .io = io, .arena = arena, .spans = spans, .table = &table, .common = &common };
    defer finder.deinit();

    if (show_table) {
        try printTable(out, spans, &table, json);
        if (inputs.items.len == 0 and !from_stdin) return try out.flush();
        if (!json) try out.writeByte('\n');
    }

    var results: std.ArrayList(Result) = .empty;
    for (inputs.items) |text| try results.append(arena, try finder.find(text));
    if (from_stdin) {
        var in_buf: [16 * 1024]u8 = undefined;
        var in_file: Io.File.Reader = .init(.stdin(), io, &in_buf);
        while (try in_file.interface.takeDelimiter('\n')) |line| {
            const text = std.mem.trim(u8, line, " \t\r");
            if (text.len == 0) continue;
            try results.append(arena, try finder.find(try arena.dupe(u8, text)));
        }
    }

    if (json) {
        try std.json.Stringify.value(results.items, .{ .whitespace = .indent_2 }, out);
        try out.writeByte('\n');
    } else if (results.items.len == 1) {
        try printDetail(out, results.items[0]);
    } else {
        for (results.items) |r| try printLine(out, r);
    }
    try out.flush();

    var failed = false;
    for (results.items) |r| if (r.error_message != null) {
        failed = true;
    };
    if (failed) std.process.exit(1);
}

fn parseVolumes(arena: std.mem.Allocator, text: []const u8) ![]const i32 {
    var list: std.ArrayList(i32) = .empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |p| {
        const v = std.fmt.parseInt(i32, std.mem.trim(u8, p, " "), 10) catch cli.fatal("bad --volumes '{s}'", .{text});
        try list.append(arena, v);
    }
    return list.items;
}

const Candidate = struct {
    /// Entry index within the segment.
    index: u16,
    /// Byte offset in the span.
    offset: u64,
    approx_size: u64,
    head: bool,
    pinned: bool,
    phase: u1,
    valid: bool,
};

const Result = struct {
    input: []const u8,
    key: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    slot: u32 = 0,
    span_index: usize = 0,
    block_index: usize = 0,
    span: []const u8 = "",
    volume: i32 = 0,
    segment: u64 = 0,
    bucket: u64 = 0,
    tag: u12 = 0,
    /// Entries walked in the bucket's chain.
    chain_length: u64 = 0,
    candidates: []const Candidate = &.{},
};

/// Looks keys up, keeping each stripe open after first use.
const Finder = struct {
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    spans: []cyclone.Span,
    table: *const assign.Table,
    common: *const cli.Common,
    open: std.AutoHashMapUnmanaged([2]usize, cyclone.Stripe) = .empty,

    fn deinit(f: *Finder) void {
        var it = f.open.valueIterator();
        while (it.next()) |s| s.close(f.gpa);
        f.open.deinit(f.gpa);
    }

    fn stripe(f: *Finder, ref: *const assign.StripeRef) !*cyclone.Stripe {
        const gop = try f.open.getOrPut(f.gpa, .{ ref.span_index, ref.block_index });
        if (!gop.found_existing) {
            const span = &f.spans[ref.span_index];
            gop.value_ptr.* = cyclone.Stripe.open(f.gpa, f.io, span, ref.block_index, f.common.avgObjSize(ref.volume)) catch |err| {
                _ = f.open.remove(.{ ref.span_index, ref.block_index });
                return err;
            };
        }
        return gop.value_ptr;
    }

    fn find(f: *Finder, text: []const u8) !Result {
        var r: Result = .{ .input = text };
        const key = parseInput(f.common.hash_type, text) catch |err| {
            r.error_message = switch (err) {
                error.BadUrl => "not a key, and not a URL that parses",
            };
            return r;
        };
        r.key = try std.fmt.allocPrint(f.arena, "{f}", .{key});

        r.slot = assign.Table.slotOf(&key);
        const ref = f.table.stripeFor(&key);
        r.span_index = ref.span_index;
        r.block_index = ref.block_index;
        r.span = f.spans[ref.span_index].path;
        r.volume = ref.volume;

        const s = try f.stripe(ref);
        if (s.chosen == null) {
            r.error_message = "the stripe has no usable directory (see cyc-doc stripe; is --avg-obj-size right?)";
            return r;
        }
        const slot = dir.Slot.of(&key, s.geometry.segments, s.geometry.buckets);
        r.segment = slot.segment;
        r.bucket = slot.bucket;
        r.tag = slot.tag;

        var seg = try dir.Segment.read(f.gpa, f.io, s, slot.segment);
        defer seg.deinit(f.gpa);
        var candidates: std.ArrayList(Candidate) = .empty;
        var chain = seg.chain(slot.bucket);
        while (chain.next()) |link| {
            r.chain_length += 1;
            const d = link.dir;
            if (d.isEmpty() or d.tag() != slot.tag) continue;
            try candidates.append(f.arena, .{
                .index = link.index,
                .offset = dir.contentOffset(s, d),
                .approx_size = d.approxSize(),
                .head = d.head(),
                .pinned = d.pinned(),
                .phase = d.phase(),
                .valid = dir.entryValid(s, d),
            });
        }
        if (chain.err) |e| r.error_message = switch (e) {
            .bad_next => "bucket chain has a next index past the segment",
            .loop => "bucket chain loops",
        };
        r.candidates = candidates.items;
        return r;
    }
};

fn parseInput(hash_type: cyclone.HashType, text: []const u8) error{BadUrl}!cyclone.CacheKey {
    if (text.len == hash_type.keyLen() * 2) {
        if (cyclone.CacheKey.parseHex(hash_type, text)) |k| return k else |_| {}
    }
    return cyclone.url.cacheKey(text, hash_type, .{}) catch error.BadUrl;
}

fn printDetail(out: *Io.Writer, r: Result) !void {
    if (r.key == null) {
        try out.print("{s}: {s}\n", .{ r.input, r.error_message.? });
        return;
    }
    if (!std.mem.eql(u8, r.input, r.key.?)) try out.print("url         {s}\n", .{r.input});
    try out.print("key         {s}\n", .{r.key.?});
    try out.print("slot        {d} of {d}\n", .{ r.slot, assign.table_size });
    try out.print("stripe      {d}:{d}  volume {d}  in {s}\n", .{ r.span_index, r.block_index, r.volume, r.span });
    if (r.error_message) |m| if (r.chain_length == 0) {
        try out.print("error: {s}\n", .{m});
        return;
    };
    try out.print("directory   segment {d}, bucket {d}, tag 0x{x:0>3}, chain of {d}\n", .{ r.segment, r.bucket, r.tag, r.chain_length });
    if (r.candidates.len == 0) {
        try out.writeAll("result      miss: no entry with this tag\n");
    } else {
        try out.print("candidates  {d}\n", .{r.candidates.len});
        for (r.candidates) |c| {
            try out.print("  offset {d}  ~{Bi:.1}  index {d}  phase {d}{s}{s}{s}\n", .{
                c.offset,                         c.approx_size, c.index, c.phase,
                if (c.head) "  head" else "",     if (c.pinned) "  pinned" else "",
                if (c.valid) "" else "  STALE",
            });
        }
    }
    if (r.error_message) |m| try out.print("error: {s}\n", .{m});
}

fn printLine(out: *Io.Writer, r: Result) !void {
    const key = r.key orelse {
        try out.print("-\t-\terror: {s}\t{s}\n", .{ r.error_message.?, r.input });
        return;
    };
    try out.print("{s}\t{d}:{d}\t", .{ key, r.span_index, r.block_index });
    if (r.candidates.len == 0) {
        try out.writeAll("miss");
    } else for (r.candidates, 0..) |c, i| {
        if (i != 0) try out.writeByte(',');
        try out.print("{d}{s}{s}", .{ c.offset, if (c.head) "h" else "", if (c.valid) "" else "!" });
    }
    if (r.error_message) |m| try out.print(" (error: {s})", .{m});
    if (!std.mem.eql(u8, r.input, key)) try out.print("\t{s}", .{r.input});
    try out.writeByte('\n');
}

fn printTable(out: *Io.Writer, spans: []const cyclone.Span, table: *const assign.Table, json: bool) !void {
    if (json) {
        const Row = struct { index: usize, span_index: usize, block_index: usize, volume: i32, len: u64, requested: u32, got: u32 };
        var rows: [256]Row = undefined;
        const n = @min(rows.len, table.stripes.len);
        for (table.stripes[0..n], 0..) |s, i| rows[i] = .{
            .index = i,
            .span_index = s.span_index,
            .block_index = s.block_index,
            .volume = s.volume,
            .len = s.len,
            .requested = table.requested[i],
            .got = table.got[i],
        };
        try std.json.Stringify.value(rows[0..n], .{ .whitespace = .indent_2 }, out);
        try out.writeByte('\n');
        return;
    }
    try out.print("  {s: >5}  {s: >7}  {s: >6}  {s: >10}  {s: >9}  {s: >9}  {s}\n", .{ "index", "stripe", "volume", "length", "requested", "got", "span" });
    for (table.stripes, 0..) |s, i| {
        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "{d}:{d}", .{ s.span_index, s.block_index }) catch "?";
        var vol_buf: [16]u8 = undefined;
        const vol = std.fmt.bufPrint(&vol_buf, "{d}", .{s.volume}) catch "?";
        var len_buf: [32]u8 = undefined;
        const len = std.fmt.bufPrint(&len_buf, "{Bi:.1}", .{s.len}) catch "?";
        try out.print("  {d: >5}  {s: >7}  {s: >6}  {s: >10}  {d: >9}  {d: >9}  {s}\n", .{
            i, id, vol, len, table.requested[i], table.got[i], spans[s.span_index].path,
        });
    }
}
