//! cyc-doc: read cached objects, and inspect the structures that hold them.

const std = @import("std");
const Io = std.Io;
const cyclone = @import("cyclone");
const cli = cyclone.cli;
const Span = cyclone.Span;

const usage =
    \\usage: cyc-doc span   --span PATH... [--json]
    \\       cyc-doc stripe --span PATH... [--block SPAN:BLOCK] [--avg-obj-size [VOL=]N] [--json]
    \\       cyc-doc dir    --span PATH... [--block SPAN:BLOCK] [--segment N] [--entries] [--json]
    \\
    \\Read cached objects, and inspect the structures that hold them.
    \\
    \\commands:
    \\  span                show span headers and their stripe blocks
    \\  stripe              show stripe geometry and directory headers
    \\  dir                 directory statistics; with --entries, every entry in use
    \\  (object reading: not implemented yet)
    \\
    \\options:
    \\
++ cli.Common.help ++
    \\  --block S:B         only stripe block B of span S (both 0-based, as `span` lists them)
    \\  --segment N         dir: only directory segment N
    \\  --entries           dir: list entries in use (all of them, valid or not)
    \\  --json              machine-readable output
    \\
;

const Command = enum { span, stripe, dir };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var common: cli.Common = .{};
    var json = false;
    var command: ?Command = null;
    var only: ?[2]usize = null;
    var dir_opts: DirOptions = .{};

    var it: cli.ArgIterator = .init(args);
    while (it.next()) |arg| {
        if (cli.isHelp(arg)) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (try common.parse(arena, arg, &it)) {
            continue;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--entries")) {
            dir_opts.entries = true;
        } else if (std.mem.eql(u8, arg, "--segment")) {
            const text = it.value(arg);
            dir_opts.segment = std.fmt.parseInt(u64, text, 10) catch cli.fatal("bad --segment '{s}'", .{text});
        } else if (std.mem.eql(u8, arg, "--block")) {
            const text = it.value(arg);
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse cli.fatal("--block wants SPAN:BLOCK, got '{s}'", .{text});
            only = .{
                std.fmt.parseInt(usize, text[0..colon], 10) catch cli.fatal("bad --block '{s}'", .{text}),
                std.fmt.parseInt(usize, text[colon + 1 ..], 10) catch cli.fatal("bad --block '{s}'", .{text}),
            };
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
        .stripe => try stripeCommand(init.gpa, init.io, arena, out, &common, only, json),
        .dir => try dirCommand(init.gpa, init.io, arena, out, &common, only, dir_opts, json),
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

fn openSpan(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, arg: cli.SpanArg) !Span {
    return Span.open(gpa, io, arg.path, .{ .seed = arg.seed, .skip = arg.skip }) catch |err| {
        try out.flush();
        cli.fatal("{s}: {s}", .{ arg.path, describeOpenError(err) });
    };
}

fn stripeCommand(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, out: *Io.Writer, common: *const cli.Common, only: ?[2]usize, json: bool) !void {
    const spans = common.spans.items;
    if (spans.len == 0) cli.fatal("stripe needs at least one --span", .{});
    if (only) |o| if (o[0] >= spans.len) cli.fatal("--block {d}:{d}: there are only {d} spans", .{ o[0], o[1], spans.len });

    var reports: std.ArrayList(StripeReport) = .empty;
    for (spans, 0..) |arg, si| {
        if (only) |o| if (o[0] != si) continue;
        var span = try openSpan(gpa, io, out, arg);
        defer span.close(gpa, io);
        if (only) |o| if (o[1] >= span.blocks.len or span.blocks[o[1]].free)
            cli.fatal("--block {d}:{d}: no such stripe (see `cyc-doc span`)", .{ o[0], o[1] });
        for (span.blocks, 0..) |b, bi| {
            if (b.free) continue;
            if (only) |o| if (o[1] != bi) continue;
            var stripe = try cyclone.Stripe.open(gpa, io, &span, bi, common.avgObjSize(b.number));
            defer stripe.close(gpa);
            try reports.append(arena, try .init(gpa, io, arena, si, &stripe));
        }
    }

    if (json) {
        try std.json.Stringify.value(reports.items, .{ .whitespace = .indent_2 }, out);
        try out.writeByte('\n');
        return;
    }
    for (reports.items, 0..) |r, i| {
        if (i != 0) try out.writeByte('\n');
        try printStripe(out, r);
    }
}

const StripeReport = struct {
    span_index: usize,
    block_index: usize,
    span: []const u8,
    volume: i32,
    hash_text: []const u8,
    offset: u64,
    len: u64,
    avg_obj_size: u32,
    segments: u64,
    buckets: u64,
    entries: u64,
    dir_len: u64,
    copy_a: u64,
    copy_b: u64,
    content_start: u64,
    content_len: u64,
    copies: [2]CopyReport,
    using: ?[]const u8,
    header: ?cyclone.stripe.HeaderFooter,
    freelist: []const u16,
    issues: []const cyclone.span.Issue,
    diagnosis: ?cyclone.stripe.Diagnosis,

    const CopyReport = struct {
        header: ?cyclone.stripe.HeaderFooter,
        footer: ?cyclone.stripe.HeaderFooter,
    };

    fn init(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, span_index: usize, s: *const cyclone.Stripe) !StripeReport {
        const g = s.geometry;
        var hash_text: Io.Writer.Allocating = .init(arena);
        try s.hashText(&hash_text.writer);
        const issues = try s.check(arena);

        // Only worth the scan when the footer is missing but header A is there.
        var diagnosis: ?cyclone.stripe.Diagnosis = null;
        if (!s.copies[0].magicOk() and !s.copies[1].magicOk()) {
            if (try cyclone.stripe.diagnoseGeometry(gpa, io, s.span, s.block)) |d| {
                defer gpa.free(d.candidates);
                diagnosis = .{ .dir_len = d.dir_len, .candidates = try arena.dupe(cyclone.stripe.Candidate, d.candidates) };
            }
        }

        return .{
            .span_index = span_index,
            .block_index = s.block_index,
            .span = s.span.path,
            .volume = s.block.number,
            .hash_text = hash_text.written(),
            .offset = s.block.offset,
            .len = s.block.byteLen(),
            .avg_obj_size = s.avg_obj_size,
            .segments = g.segments,
            .buckets = g.buckets,
            .entries = g.entryCount(),
            .dir_len = g.dirLen(),
            .copy_a = g.copyOffset(.a),
            .copy_b = g.copyOffset(.b),
            .content_start = g.start,
            .content_len = g.dataLen(),
            .copies = .{
                .{ .header = s.copies[0].header, .footer = s.copies[0].footer },
                .{ .header = s.copies[1].header, .footer = s.copies[1].footer },
            },
            .using = if (s.chosen) |c| @tagName(c) else null,
            .header = s.header(),
            .freelist = try arena.dupe(u16, s.freelist),
            .issues = issues,
            .diagnosis = diagnosis,
        };
    }
};

fn printStripe(out: *Io.Writer, r: StripeReport) !void {
    const magic = cyclone.format.stripe.stripe_magic;
    try out.print("stripe      {d}:{d}  volume {d}  in {s}\n", .{ r.span_index, r.block_index, r.volume, r.span });
    try out.print("hash text   {s}\n", .{r.hash_text});
    try out.print("location    offset {d}, length {d} ({Bi:.1})\n", .{ r.offset, r.len, r.len });
    try out.print("geometry    avg_obj_size {d}: {d} segment{s} x {d} buckets x 4 = {d} entries\n", .{
        r.avg_obj_size, r.segments, if (r.segments == 1) "" else "s", r.buckets, r.entries,
    });
    try out.print("directory   {d} bytes per copy; A at {d}, B at {d}\n", .{ r.dir_len, r.copy_a, r.copy_b });
    try out.print("content     {d} .. {d} ({Bi:.1})\n\n", .{ r.content_start, r.content_start + r.content_len, r.content_len });

    try out.print("  {s: <4}  {s: <10}  {s: <9}  {s: >9}  {s: >9}  {s: >12}  {s}\n", .{ "copy", "magic h/f", "version", "sync h/f", "write ser", "write_pos", "phase/cycle" });
    for (r.copies, [_][]const u8{ "A", "B" }) |c, name| {
        const h = c.header orelse {
            try out.print("  {s: <4}  (past the end of the span)\n", .{name});
            continue;
        };
        var magic_buf: [16]u8 = undefined;
        const magic_text = std.fmt.bufPrint(&magic_buf, "{s}/{s}", .{
            if (h.magic == magic) "ok" else "bad",
            if (c.footer) |f| (if (f.magic == magic) "ok" else "bad") else "-",
        }) catch "?";
        var ver_buf: [16]u8 = undefined;
        const ver = std.fmt.bufPrint(&ver_buf, "{f}", .{h.version}) catch "?";
        var sync_buf: [32]u8 = undefined;
        const sync = std.fmt.bufPrint(&sync_buf, "{d}/{d}", .{ h.sync_serial, if (c.footer) |f| f.sync_serial else 0 }) catch "?";
        var pc_buf: [32]u8 = undefined;
        const pc = std.fmt.bufPrint(&pc_buf, "{d}/{d}", .{ h.phase, h.cycle }) catch "?";
        var wp_buf: [24]u8 = undefined;
        const wp = std.fmt.bufPrint(&wp_buf, "{d}", .{h.write_pos}) catch "?";
        try out.print("  {s: <4}  {s: <10}  {s: <9}  {s: >9}  {d: >9}  {s: >12}  {s}\n", .{ name, magic_text, ver, sync, h.write_serial, wp, pc });
    }

    if (r.header) |h| {
        try out.print("\nusing       copy {s}\n", .{r.using.?});
        const into = @as(i64, @intCast(r.content_start));
        try out.print("write_pos   {d} ({d} bytes into the content area), phase {d}, cycle {d}\n", .{ h.write_pos, h.write_pos - into, h.phase, h.cycle });
        try out.print("agg_pos     {d}   last_write_pos {d}\n", .{ h.agg_pos, h.last_write_pos });
        try out.print("created     {d} (unix time)   generation {d}   sector_size {d}   dirty {d}\n", .{ h.create_time, h.generation, h.sector_size, h.dirty });
        if (r.freelist.len <= 8) {
            try out.print("freelist    {any}\n", .{r.freelist});
        } else {
            try out.print("freelist    {d} segments: {any} ...\n", .{ r.freelist.len, r.freelist[0..8] });
        }
    } else {
        try out.writeAll("\nusing       none\n");
    }

    if (r.issues.len != 0) {
        try out.writeAll("\n");
        for (r.issues) |issue| try out.print("{s}: {s}\n", .{ @tagName(issue.severity), issue.message });
    }
    if (r.diagnosis) |d| try printDiagnosis(out, r, d);
}

fn printDiagnosis(out: *Io.Writer, r: StripeReport, d: cyclone.stripe.Diagnosis) !void {
    try out.print("\nfound the footer of copy A: each directory copy is {d} bytes, not {d}\n", .{ d.dir_len, r.dir_len });
    if (d.candidates.len == 0) {
        try out.writeAll("no avg_obj_size between 64 and 4M gives that size\n");
        return;
    }
    const lo = d.candidates[0].avg_min;
    const hi = d.candidates[d.candidates.len - 1].avg_max;
    try out.print("avg_obj_size values {d}..{d} give that size, with {d} different bucket counts\n", .{ lo, hi, d.candidates.len });
    if (d.candidates.len <= 6) {
        for (d.candidates) |c| try out.print("  {d}..{d}: {d} segments x {d} buckets\n", .{ c.avg_min, c.avg_max, c.segments, c.buckets });
    }
    // Configured values tend to be round numbers.
    try out.writeAll("round values in that range:");
    var shown: usize = 0;
    var v = (lo + 999) / 1000 * 1000;
    while (v <= hi and shown < 8) : (v += 1000) {
        try out.print(" {d}", .{v});
        shown += 1;
    }
    var p: u32 = 64;
    while (p <= hi) : (p *= 2) if (p >= lo and p % 1000 != 0) try out.print(" {d}", .{p});
    try out.print("\nretry with --avg-obj-size {d}=N, using the configured value: lookups need the exact bucket count\n", .{r.volume});
}

const DirOptions = struct {
    segment: ?u64 = null,
    entries: bool = false,
};

const DirReport = struct {
    span_index: usize,
    block_index: usize,
    volume: i32,
    segments: u64,
    buckets: u64,
    stats: ?cyclone.dir.Stats,
    error_message: ?[]const u8 = null,
    entries: []const Entry,

    const Entry = struct {
        segment: u64,
        bucket: u64,
        index: u16,
        offset: u64,
        approx_size: u64,
        tag: u12,
        phase: u1,
        head: bool,
        pinned: bool,
        valid: bool,
    };
};

fn dirCommand(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, out: *Io.Writer, common: *const cli.Common, only: ?[2]usize, opts: DirOptions, json: bool) !void {
    const spans = common.spans.items;
    if (spans.len == 0) cli.fatal("dir needs at least one --span", .{});
    if (only) |o| if (o[0] >= spans.len) cli.fatal("--block {d}:{d}: there are only {d} spans", .{ o[0], o[1], spans.len });

    var reports: std.ArrayList(DirReport) = .empty;
    for (spans, 0..) |arg, si| {
        if (only) |o| if (o[0] != si) continue;
        var span = try openSpan(gpa, io, out, arg);
        defer span.close(gpa, io);
        if (only) |o| if (o[1] >= span.blocks.len or span.blocks[o[1]].free)
            cli.fatal("--block {d}:{d}: no such stripe (see `cyc-doc span`)", .{ o[0], o[1] });
        for (span.blocks, 0..) |b, bi| {
            if (b.free) continue;
            if (only) |o| if (o[1] != bi) continue;
            var stripe = try cyclone.Stripe.open(gpa, io, &span, bi, common.avgObjSize(b.number));
            defer stripe.close(gpa);
            try reports.append(arena, try dirReport(gpa, io, arena, si, &stripe, opts));
        }
    }

    if (json) {
        try std.json.Stringify.value(reports.items, .{ .whitespace = .indent_2 }, out);
        try out.writeByte('\n');
        return;
    }
    var total: cyclone.dir.Stats = .{};
    var counted: usize = 0;
    for (reports.items, 0..) |r, i| {
        if (i != 0) try out.writeByte('\n');
        try printDir(out, r, opts);
        if (r.stats) |st| {
            total.add(st);
            counted += 1;
        }
    }
    if (counted > 1 and !opts.entries) {
        try out.print("\nall {d} stripes: {d} valid entries, {d} object heads, ~{Bi:.1}\n", .{ counted, total.entries_valid, total.heads, total.approx_bytes });
    }
}

fn dirReport(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, si: usize, stripe: *const cyclone.Stripe, opts: DirOptions) !DirReport {
    var r: DirReport = .{
        .span_index = si,
        .block_index = stripe.block_index,
        .volume = stripe.block.number,
        .segments = stripe.geometry.segments,
        .buckets = stripe.geometry.buckets,
        .stats = null,
        .entries = &.{},
    };
    if (stripe.chosen == null) {
        r.error_message = "no usable directory copy (see `cyc-doc stripe`)";
        return r;
    }
    if (opts.segment) |s| if (s >= stripe.geometry.segments) {
        r.error_message = try std.fmt.allocPrint(arena, "no segment {d}; this stripe has {d}", .{ s, stripe.geometry.segments });
        return r;
    };

    var entries: std.ArrayList(DirReport.Entry) = .empty;
    var stats: cyclone.dir.Stats = .{};
    for (0..stripe.geometry.segments) |s| {
        if (opts.segment) |want| if (want != s) continue;
        var seg = try cyclone.dir.Segment.read(gpa, io, stripe, s);
        defer seg.deinit(gpa);
        stats.add(try cyclone.dir.segmentStats(gpa, stripe, &seg));
        if (!opts.entries) continue;
        for (0..seg.buckets) |b| {
            var it = seg.chain(b);
            while (it.next()) |link| {
                const d = link.dir;
                if (d.isEmpty()) continue;
                try entries.append(arena, .{
                    .segment = s,
                    .bucket = b,
                    .index = link.index,
                    .offset = cyclone.dir.contentOffset(stripe, d),
                    .approx_size = d.approxSize(),
                    .tag = d.tag(),
                    .phase = d.phase(),
                    .head = d.head(),
                    .pinned = d.pinned(),
                    .valid = cyclone.dir.entryValid(stripe, d),
                });
            }
        }
    }
    r.stats = stats;
    r.entries = entries.items;
    return r;
}

fn printDir(out: *Io.Writer, r: DirReport, opts: DirOptions) !void {
    try out.print("stripe      {d}:{d}  volume {d}  {d} segment{s} x {d} buckets\n", .{
        r.span_index, r.block_index, r.volume, r.segments, if (r.segments == 1) "" else "s", r.buckets,
    });
    if (r.error_message) |m| {
        try out.print("error: {s}\n", .{m});
        return;
    }
    const st = r.stats.?;
    if (opts.entries) {
        try out.print("  {s: >4} {s: >6} {s: >6}  {s: >14}  {s: >10}  {s: >5}  {s}\n", .{ "seg", "bucket", "index", "offset", "approx", "tag", "flags" });
        for (r.entries) |e| {
            var size_buf: [32]u8 = undefined;
            const size = std.fmt.bufPrint(&size_buf, "{Bi:.1}", .{e.approx_size}) catch "?";
            try out.print("  {d: >4} {d: >6} {d: >6}  {d: >14}  {s: >10}  0x{x:0>3}  phase {d}{s}{s}{s}\n", .{
                e.segment,                       e.bucket,                     e.index, e.offset, size, e.tag, e.phase,
                if (e.head) " head" else "",     if (e.pinned) " pinned" else "",
                if (e.valid) "" else " STALE",
            });
        }
        return;
    }
    try out.print("entries     {d} total: {d} in use ({d} valid), {d} free, {d} unaccounted\n", .{ st.entries, st.entries_used, st.entries_valid, st.free, st.unaccounted });
    try out.print("buckets     {d} of {d} used ({d:.1}%)\n", .{ st.buckets_used, st.buckets, pct(st.buckets_used, st.buckets) });
    try out.print("objects     {d} heads, {d} pinned, ~{Bi:.1} in valid entries\n", .{ st.heads, st.pinned, st.approx_bytes });
    try out.print("chains      length 1: {d}  2: {d}  3: {d}  4: {d}  5+: {d}  (longest {d})\n", .{
        st.chain_lengths[0], st.chain_lengths[1], st.chain_lengths[2], st.chain_lengths[3], st.chain_lengths[4], st.max_chain,
    });
    if (st.problems() == 0) {
        try out.writeAll("problems    none\n");
    } else {
        try out.print("problems    bad next {d}, loops {d}, shared entries {d}, empty head with next {d}, empty entries in chains {d}\n", .{
            st.bad_next, st.loops, st.shared, st.empty_head_with_next, st.empty_in_chain,
        });
    }
}

fn pct(a: u64, b: u64) f64 {
    if (b == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
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
