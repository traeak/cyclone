//! cyc-lookup: find where a cache key lives: its stripe, directory bucket,
//! and the entries whose tag matches.

const std = @import("std");
const Io = std.Io;
const cyclone = @import("cyclone");
const cli = cyclone.cli;
const assign = cyclone.assign;

const usage =
    \\usage: cyc-lookup --span PATH... [options] KEY|URL...
    \\       cyc-lookup --span PATH... [options] -        (keys or URLs from stdin)
    \\       cyc-lookup --span PATH... [options] --table
    \\
    \\Find where cache keys live: the stripe ATS assigns them to, the directory
    \\bucket, and the entries whose tag matches. A 32-digit hex argument is a key
    \\(as cyc-key prints it); anything else is a cache-key URL.
    \\
    \\Each entry whose 12-bit tag matches is checked against the full key in the
    \\Doc it points at. A hit is a valid entry whose Doc has the key as its
    \\first_key (or, for a data fragment's key, as its key).
    \\
    \\Batch output (several inputs, or -) is one line per input:
    \\  KEY  STRIPE  hit|miss|stale  CANDIDATES  [URL]
    \\where stale means only entries ATS would no longer trust match, and each
    \\candidate is a byte offset, with h for a head entry, ! for a stale entry
    \\and ? for one whose Doc does not confirm the key.
    \\
    \\options:
    \\
++ cli.Common.help ++
    \\  --volumes N,M,...   volumes of the host record, in order: a hosting.config
    \\                      volume= list or @volume= remap directive (default: all
    \\                      volumes, in the order ATS finds them on the spans)
    \\  --stripe S:B        look in stripe block B of span S instead of the key's
    \\                      own stripe: a data fragment's key must be looked up in
    \\                      its object's stripe (where the URL's key leads)
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
    var stripe_override: ?[2]usize = null;
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
            volumes = try cli.parseVolumes(arena, it.value(arg));
        } else if (std.mem.eql(u8, arg, "--stripe")) {
            const text = it.value(arg);
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse cli.fatal("--stripe wants SPAN:BLOCK, got '{s}'", .{text});
            stripe_override = .{
                std.fmt.parseInt(usize, text[0..colon], 10) catch cli.fatal("bad --stripe '{s}'", .{text}),
                std.fmt.parseInt(usize, text[colon + 1 ..], 10) catch cli.fatal("bad --stripe '{s}'", .{text}),
            };
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

    var cache = cyclone.Cache.init(gpa, io, spans, common.cacheConfig(volumes)) catch |err| switch (err) {
        error.NoStripes => cli.fatal("no stripes{s}", .{if (volumes != null) " in the given --volumes" else ""}),
        else => return err,
    };
    defer cache.deinit();
    if (stripe_override) |o| {
        if (o[0] >= spans.len or o[1] >= spans[o[0]].blocks.len or spans[o[0]].blocks[o[1]].free)
            cli.fatal("--stripe {d}:{d}: no such stripe (see `cyc-doc span`)", .{ o[0], o[1] });
    }

    var finder: Finder = .{ .arena = arena, .cache = &cache, .hash_type = common.hash_type, .stripe_override = stripe_override };

    if (show_table) {
        try printTable(out, spans, &cache.table, json);
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
    } else if (results.items.len == 1 and !from_stdin) {
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
    verdict: ?cyclone.doc.Verdict = null,
    /// Set when the Doc has the right magic.
    doc: ?DocInfo = null,
    read_error: ?[]const u8 = null,
};

/// The Doc fields worth showing for a lookup.
const DocInfo = struct {
    len: u32,
    total_len: u64,
    hlen: u32,
    data_len: u64,
    doc_type: []const u8,
    version: []const u8,
    first_key: []const u8,
    key: []const u8,
    pinned_until: u32,

    fn init(arena: std.mem.Allocator, d: cyclone.doc.Doc) !DocInfo {
        return .{
            .len = d.len,
            .total_len = d.total_len,
            .hlen = d.hlen,
            .data_len = d.dataLen(),
            .doc_type = docTypeName(d.doc_type),
            .version = try std.fmt.allocPrint(arena, "{d}.{d}", .{ d.v_major, d.v_minor }),
            .first_key = try std.fmt.allocPrint(arena, "{f}", .{d.first_key}),
            .key = try std.fmt.allocPrint(arena, "{f}", .{d.key}),
            .pinned_until = d.pinned,
        };
    }
};

fn docTypeName(t: cyclone.doc.FragType) []const u8 {
    return switch (t) {
        .none => "none",
        .unused_1 => "unused_1",
        .rtsp => "rtsp",
        .http => "http",
        _ => "unknown",
    };
}

const Status = enum {
    /// A valid entry whose Doc confirms the key.
    hit,
    /// Only stale entries confirm the key.
    stale,
    miss,
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
    /// Whether the stripe searched is the one ATS assigns the key to.
    home: bool = true,
    segment: u64 = 0,
    bucket: u64 = 0,
    tag: u12 = 0,
    /// Entries walked in the bucket's chain.
    chain_length: u64 = 0,
    status: Status = .miss,
    candidates: []const Candidate = &.{},
};

/// Looks keys up through a `Cache`, which keeps stripes open.
const Finder = struct {
    arena: std.mem.Allocator,
    cache: *cyclone.Cache,
    hash_type: cyclone.HashType,
    /// `--stripe`: look in this stripe instead of the key's home stripe.
    stripe_override: ?[2]usize,

    fn find(f: *Finder, text: []const u8) !Result {
        var r: Result = .{ .input = text };
        const key = cli.parseKeyOrUrl(f.hash_type, text) catch |err| {
            r.error_message = switch (err) {
                error.BadUrl => "not a key, and not a URL that parses",
            };
            return r;
        };
        r.key = try std.fmt.allocPrint(f.arena, "{f}", .{key});
        r.slot = assign.Table.slotOf(&key);

        const ref = f.cache.home(&key);
        const where = f.stripe_override orelse .{ ref.span_index, ref.block_index };
        r.span_index = where[0];
        r.block_index = where[1];
        r.span = f.cache.spans[where[0]].path;
        r.volume = f.cache.spans[where[0]].blocks[where[1]].number;
        r.home = f.stripe_override == null or (where[0] == ref.span_index and where[1] == ref.block_index);

        const s = try f.cache.stripe(where[0], where[1]);
        if (s.chosen == null) {
            r.error_message = "the stripe has no usable directory (see cyc-doc stripe; is --avg-obj-size right?)";
            return r;
        }
        const p = try f.cache.probe(f.arena, s, &key);
        r.segment = p.slot.segment;
        r.bucket = p.slot.bucket;
        r.tag = p.slot.tag;
        r.chain_length = p.chain_length;

        const candidates = try f.arena.alloc(Candidate, p.candidates.len);
        for (p.candidates, candidates) |c, *out| {
            const d = c.dir;
            out.* = .{
                .index = c.index,
                .offset = c.offset,
                .approx_size = d.approxSize(),
                .head = d.head(),
                .pinned = d.pinned(),
                .phase = d.phase(),
                .valid = c.valid,
                .verdict = c.verdict,
                .read_error = if (c.read_error) |e| @errorName(e) else null,
            };
            if (c.doc) |h| if (c.verdict != .bad_magic) {
                out.doc = try .init(f.arena, h);
            };
            if (c.verdict) |v| if (v.found()) {
                if (c.valid) r.status = .hit else if (r.status == .miss) r.status = .stale;
            };
        }
        if (p.chain_error) |e| r.error_message = switch (e) {
            .bad_next => "bucket chain has a next index past the segment",
            .loop => "bucket chain loops",
        };
        r.candidates = candidates;
        return r;
    }
};

fn printDetail(out: *Io.Writer, r: Result) !void {
    if (r.key == null) {
        try out.print("{s}: {s}\n", .{ r.input, r.error_message.? });
        return;
    }
    if (!std.mem.eql(u8, r.input, r.key.?)) try out.print("url         {s}\n", .{r.input});
    try out.print("key         {s}\n", .{r.key.?});
    try out.print("slot        {d} of {d}\n", .{ r.slot, assign.table_size });
    try out.print("stripe      {d}:{d}  volume {d}  in {s}{s}\n", .{ r.span_index, r.block_index, r.volume, r.span, if (r.home) "" else "  (--stripe; not this key's own stripe)" });
    if (r.error_message) |m| if (r.chain_length == 0) {
        try out.print("error: {s}\n", .{m});
        return;
    };
    try out.print("directory   segment {d}, bucket {d}, tag 0x{x:0>3}, chain of {d}\n", .{ r.segment, r.bucket, r.tag, r.chain_length });
    if (r.candidates.len == 0) {
        try out.writeAll("result      miss: no entry with this tag\n");
    } else {
        try out.print("result      {s}\n", .{switch (r.status) {
            .hit => "hit",
            .stale => "stale: only entries ATS no longer trusts have this key",
            .miss => "miss: no Doc confirms the key",
        }});
        try out.print("candidates  {d}\n", .{r.candidates.len});
        for (r.candidates) |c| {
            try out.print("  offset {d}  ~{Bi:.1}  index {d}  phase {d}{s}{s}{s}\n", .{
                c.offset,                     c.approx_size,                    c.index,                        c.phase,
                if (c.head) "  head" else "", if (c.pinned) "  pinned" else "", if (c.valid) "" else "  STALE",
            });
            if (c.read_error) |e| {
                try out.print("    read error: {s}\n", .{e});
                continue;
            }
            const v = c.verdict orelse continue;
            try out.print("    {s}\n", .{v.describe()});
            const d = c.doc orelse continue;
            try out.print("    doc {s} v{s}  len {d} (header {d}, data {d})  object {d}\n", .{
                d.doc_type, d.version, d.len, d.hlen, d.data_len, d.total_len,
            });
            try out.print("    first_key {s}\n    key       {s}\n", .{ d.first_key, d.key });
            if (d.pinned_until != 0) try out.print("    pinned until {d}\n", .{d.pinned_until});
        }
    }
    if (r.error_message) |m| try out.print("error: {s}\n", .{m});
}

fn printLine(out: *Io.Writer, r: Result) !void {
    const key = r.key orelse {
        try out.print("-\t-\terror: {s}\t{s}\n", .{ r.error_message.?, r.input });
        return;
    };
    try out.print("{s}\t{d}:{d}\t{t}\t", .{ key, r.span_index, r.block_index, r.status });
    if (r.candidates.len == 0) {
        try out.writeByte('-');
    } else for (r.candidates, 0..) |c, i| {
        if (i != 0) try out.writeByte(',');
        const confirmed = if (c.verdict) |v| v.found() else false;
        try out.print("{d}{s}{s}{s}", .{
            c.offset,                 if (c.head) "h" else "",
            if (c.valid) "" else "!", if (confirmed) "" else "?",
        });
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
