//! cyc-doc: read cached objects, and inspect the structures that hold them.

const std = @import("std");
const Io = std.Io;
const cyclone = @import("cyclone");
const cli = cyclone.cli;
const Span = cyclone.Span;

const usage =
    \\usage: cyc-doc span   --span PATH... [--json]
    \\       cyc-doc stripe --span PATH... [--block SPAN:BLOCK] [--avg-obj-size [VOL=]N] [--json]
    \\       cyc-doc dir    --span PATH... [--block SPAN:BLOCK] [--segment N] [--entries [--docs]] [--json]
    \\       cyc-doc object   --span PATH... KEY|URL [--alt N | --select [--req-header 'NAME: VALUE']...]
    \\                                 [--range SPEC] [--headers | --body] [--json]
    \\       cyc-doc fragment --span PATH... --at SPAN:OFFSET [--headers | --data] [--json]
    \\
    \\Read cached objects, and inspect the structures that hold them.
    \\
    \\commands:
    \\  span                show span headers and their stripe blocks
    \\  stripe              show stripe geometry and directory headers
    \\  dir                 directory statistics; with --entries, every entry in use
    \\  object              a whole object: its alternates and the fragments of one,
    \\                      checked as ATS reads them; --body writes the body
    \\  fragment            one Doc: its header and, for an HTTP head, its alternates
    \\
    \\options:
    \\
++ cli.Common.help ++
    \\  --block S:B         only stripe block B of span S (both 0-based, as `span` lists them)
    \\  --segment N         dir: only directory segment N
    \\  --entries           dir: list entries in use (all of them, valid or not)
    \\  --docs              dir: with --entries, read each entry's Doc: its keys and
    \\                      lengths, and which key the entry is filed under
    \\  --at S:OFFSET       fragment: the Doc at byte OFFSET of span S (as cyc-lookup
    \\                      and `dir --entries` print offsets)
    \\  --alt N             object: the alternate to read (default 0)
    \\  --select            object: choose the alternate as ATS would for a GET with the
    \\                      --req-header fields (none: a request with no headers); exits
    \\                      1 when none matches. The fields are taken as ATS has them at
    \\                      the cache lookup, after remap; Accept-Encoding is normalized
    \\                      as proxy.config.http.normalize_ae says (default 1)
    \\  --req-header 'NAME: VALUE'
    \\                      object: a request field for --select (implies it); repeat
    \\                      for more, in order
    \\  --record NAME=VALUE object: a records.yaml setting --select follows:
    \\                      proxy.config.http.normalize_ae (0-5),
    \\                      proxy.config.http.cache.ignore_accept_mismatch (0-2) and its
    \\                      _charset_, _encoding_ and _language_ variants,
    \\                      proxy.config.http.global_user_agent_header
    \\  --range SPEC        object: only these body bytes, as an HTTP Range: FIRST-LAST,
    \\                      FIRST- or -SUFFIX (one range; "bytes=" optional); reads only
    \\                      the fragments that hold them
    \\  --body              object: write the alternate's body (or --range) to stdout;
    \\                      exits 1 if it is incomplete
    \\  --volumes N,M,...   object: the host record's volumes (as for cyc-lookup)
    \\  --headers           object, fragment: print every stored request and response
    \\                      field
    \\  --data              fragment: write the fragment's data bytes to stdout
    \\  --json              machine-readable output
    \\
;

const Command = enum { span, stripe, dir, object, fragment };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var common: cli.Common = .{};
    var json = false;
    var command: ?Command = null;
    var only: ?[2]usize = null;
    var dir_opts: DirOptions = .{};
    var frag_opts: FragmentOptions = .{};
    var obj_opts: ObjectOptions = .{};

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
        } else if (std.mem.eql(u8, arg, "--docs")) {
            dir_opts.entries = true;
            dir_opts.docs = true;
        } else if (std.mem.eql(u8, arg, "--at")) {
            const text = it.value(arg);
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse cli.fatal("--at wants SPAN:OFFSET, got '{s}'", .{text});
            frag_opts.at = .{
                std.fmt.parseInt(usize, text[0..colon], 10) catch cli.fatal("bad --at '{s}'", .{text}),
                std.fmt.parseInt(u64, text[colon + 1 ..], 0) catch cli.fatal("bad --at '{s}'", .{text}),
            };
        } else if (std.mem.eql(u8, arg, "--headers")) {
            frag_opts.headers = true;
            obj_opts.headers = true;
        } else if (std.mem.eql(u8, arg, "--alt")) {
            const text = it.value(arg);
            obj_opts.alt = std.fmt.parseInt(usize, text, 10) catch cli.fatal("bad --alt '{s}'", .{text});
            obj_opts.alt_given = true;
        } else if (std.mem.eql(u8, arg, "--select")) {
            obj_opts.select = true;
        } else if (std.mem.eql(u8, arg, "--req-header")) {
            const text = it.value(arg);
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse cli.fatal("--req-header wants 'NAME: VALUE', got '{s}'", .{text});
            const name = std.mem.trim(u8, text[0..colon], " \t");
            if (name.len == 0) cli.fatal("--req-header wants 'NAME: VALUE', got '{s}'", .{text});
            try obj_opts.request.append(arena, .{ .name = name, .value = std.mem.trim(u8, text[colon + 1 ..], " \t") });
            obj_opts.select = true;
        } else if (std.mem.eql(u8, arg, "--record")) {
            parseRecord(&obj_opts.select_config, it.value(arg));
        } else if (std.mem.eql(u8, arg, "--range")) {
            const text = it.value(arg);
            obj_opts.range = cyclone.object.RangeSpec.parse(text) catch cli.fatal("bad --range '{s}': want FIRST-LAST, FIRST- or -SUFFIX (one range)", .{text});
        } else if (std.mem.eql(u8, arg, "--body")) {
            obj_opts.body = true;
        } else if (std.mem.eql(u8, arg, "--volumes")) {
            obj_opts.volumes = try cli.parseVolumes(arena, it.value(arg));
        } else if (std.mem.eql(u8, arg, "--data")) {
            frag_opts.data = true;
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
        } else if (command == .object and obj_opts.input == null and !std.mem.startsWith(u8, arg, "--")) {
            obj_opts.input = arg;
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
        .object => try objectCommand(init.gpa, init.io, arena, out, &common, obj_opts, json),
        .fragment => try fragmentCommand(init.gpa, init.io, arena, out, &common, frag_opts, json),
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
    docs: bool = false,
    hash_type: cyclone.HashType = .default,
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
        doc: ?EntryDoc = null,
    };

    const EntryDoc = struct {
        /// Null when the bytes there are not a Doc.
        magic_ok: bool,
        len: u32 = 0,
        hlen: u32 = 0,
        total_len: u64 = 0,
        doc_type: u8 = 0,
        first_key: []const u8 = "",
        key: []const u8 = "",
        /// The Doc key whose segment, bucket and tag the entry is filed
        /// under: "first_key" for a vector or single-fragment head, "key"
        /// for a data fragment, null if neither (a stale or reused slot).
        filed_under: ?[]const u8 = null,
        read_error: ?[]const u8 = null,
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
            var o = opts;
            o.hash_type = common.hash_type;
            try reports.append(arena, try dirReport(gpa, io, arena, si, &stripe, o));
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
                    .doc = if (opts.docs) try entryDoc(io, arena, stripe, opts.hash_type, s, b, d) else null,
                });
            }
        }
    }
    r.stats = stats;
    r.entries = entries.items;
    return r;
}

fn entryDoc(io: Io, arena: std.mem.Allocator, stripe: *const cyclone.Stripe, hash_type: cyclone.HashType, segment: u64, bucket: u64, d: cyclone.dir.Dir) !DirReport.EntryDoc {
    const doc = cyclone.doc.readHeader(io, stripe.span.file, hash_type, cyclone.dir.contentOffset(stripe, d)) catch |err|
        return .{ .magic_ok = false, .read_error = @errorName(err) };
    if (doc.magic != cyclone.format.doc.magic) return .{ .magic_ok = false };
    const g = stripe.geometry;
    const filed = struct {
        fn under(k: *const cyclone.CacheKey, gg: cyclone.stripe.Geometry, seg: u64, b: u64, tag: u12) bool {
            const slot = cyclone.dir.Slot.of(k, gg.segments, gg.buckets);
            return slot.segment == seg and slot.bucket == b and slot.tag == tag;
        }
    }.under;
    return .{
        .magic_ok = true,
        .len = doc.len,
        .hlen = doc.hlen,
        .total_len = doc.total_len,
        .doc_type = @backingInt(doc.doc_type),
        .first_key = try std.fmt.allocPrint(arena, "{f}", .{doc.first_key}),
        .key = try std.fmt.allocPrint(arena, "{f}", .{doc.key}),
        .filed_under = if (filed(&doc.first_key, g, segment, bucket, d.tag()))
            "first_key"
        else if (filed(&doc.key, g, segment, bucket, d.tag()))
            "key"
        else
            null,
    };
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
                e.segment,                   e.bucket,                        e.index,                       e.offset, size, e.tag, e.phase,
                if (e.head) " head" else "", if (e.pinned) " pinned" else "", if (e.valid) "" else " STALE",
            });
            const doc = e.doc orelse continue;
            if (doc.read_error) |m| {
                try out.print("        read error: {s}\n", .{m});
            } else if (!doc.magic_ok) {
                try out.writeAll("        no Doc (bad magic)\n");
            } else {
                try out.print("        first_key {s}  key {s}  len {d} hlen {d} object {d}  {s}\n", .{
                    doc.first_key,                                             doc.key, doc.len, doc.hlen, doc.total_len,
                    if (doc.filed_under) |f| f else "FILED UNDER NEITHER KEY",
                });
            }
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

const ObjectOptions = struct {
    input: ?[]const u8 = null,
    alt: usize = 0,
    alt_given: bool = false,
    select: bool = false,
    request: std.ArrayList(cyclone.format.http.Field) = .empty,
    select_config: cyclone.select.Config = .{},
    range: ?cyclone.object.RangeSpec = null,
    headers: bool = false,
    body: bool = false,
    volumes: ?[]const i32 = null,
};

fn parseRecord(cfg: *cyclone.select.Config, text: []const u8) void {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse cli.fatal("--record wants NAME=VALUE, got '{s}'", .{text});
    const name = text[0..eq];
    const value = text[eq + 1 ..];
    if (std.mem.eql(u8, name, "proxy.config.http.global_user_agent_header")) {
        cfg.global_user_agent_header = value.len != 0;
        return;
    }
    const n = std.fmt.parseInt(u8, value, 10) catch cli.fatal("--record {s}: bad value '{s}'", .{ name, value });
    const ignore = .{
        .{ "proxy.config.http.cache.ignore_accept_mismatch", "ignore_accept_mismatch" },
        .{ "proxy.config.http.cache.ignore_accept_charset_mismatch", "ignore_accept_charset_mismatch" },
        .{ "proxy.config.http.cache.ignore_accept_encoding_mismatch", "ignore_accept_encoding_mismatch" },
        .{ "proxy.config.http.cache.ignore_accept_language_mismatch", "ignore_accept_language_mismatch" },
    };
    inline for (ignore) |r| if (std.mem.eql(u8, name, r[0])) {
        if (n > 2) cli.fatal("--record {s}: want 0, 1 or 2", .{name});
        @field(cfg, r[1]) = @intCast(n);
        return;
    };
    if (std.mem.eql(u8, name, "proxy.config.http.normalize_ae")) {
        if (n > 5) cli.fatal("--record {s}: want 0 to 5", .{name});
        cfg.normalize_ae = @intCast(n);
        return;
    }
    cli.fatal("--record: '{s}' does not change alternate selection", .{name});
}

const ObjectReport = struct {
    input: []const u8,
    key: []const u8,
    found: bool = false,
    /// The object's stripe, as SPAN:BLOCK.
    stripe: []const u8 = "",
    head_offset: u64 = 0,
    head: ?FragmentReport.DocReport = null,
    alternates: []const FragmentReport.AltReport = &.{},
    /// How --select chose the alternate.
    selection: ?SelectionReport = null,
    /// The alternate whose fragments are listed (null: non-HTTP object).
    selected: ?usize = null,
    object_size: u64 = 0,
    /// With --range: the bytes asked for (last inclusive, as in HTTP).
    range: ?struct { first: u64, last: u64, length: u64 } = null,
    covered: u64 = 0,
    complete: bool = false,
    fragments: []const FragmentEntry = &.{},
    problems: []const []const u8 = &.{},
    error_message: ?[]const u8 = null,

    const SelectionReport = struct {
        /// The request fields matched, after Accept-Encoding normalization.
        request: []const cyclone.format.http.Field,
        normalize_ae: u3,
        chosen: ?usize,
        alternates: []const Match,

        const Match = struct {
            index: usize,
            /// The alternate has no data, and ATS skips it.
            skipped: bool,
            quality: f32,
            /// Accept, Accept-Charset, Accept-Encoding, Accept-Language
            /// (-2: not computed).
            q: [4]f32,
            /// "none", "some" or "all".
            vary: []const u8,
            /// The Vary field that differs.
            vary_field: []const u8,
            age: i64,
        };
    };

    const FragmentEntry = struct {
        index: usize,
        key: []const u8,
        body_start: u64,
        data_len: u64,
        offset: ?u64,
        in_head: bool,
        stale_only: bool,
    };
};

fn objectCommand(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, out: *Io.Writer, common: *const cli.Common, opts: ObjectOptions, json: bool) !void {
    const input = opts.input orelse cli.fatal("object needs a KEY or URL", .{});
    if (common.spans.items.len == 0) cli.fatal("object needs every --span, in order", .{});
    if (opts.body and json) cli.fatal("--body and --json do not mix", .{});
    if (opts.select and opts.alt_given) cli.fatal("--alt and --select (or --req-header) do not mix", .{});
    const key = cli.parseKeyOrUrl(common.hash_type, input) catch cli.fatal("'{s}' is not a key, and not a URL that parses", .{input});

    const spans = try arena.alloc(Span, common.spans.items.len);
    for (common.spans.items, spans) |arg, *sp| sp.* = try openSpan(gpa, io, out, arg);
    defer for (spans) |*sp| sp.close(gpa, io);
    var cache = cyclone.Cache.init(gpa, io, spans, common.cacheConfig(opts.volumes)) catch |err| switch (err) {
        error.NoStripes => cli.fatal("no stripes{s}", .{if (opts.volumes != null) " in the given --volumes" else ""}),
        else => return err,
    };
    defer cache.deinit();

    var r: ObjectReport = .{ .input = input, .key = try std.fmt.allocPrint(arena, "{f}", .{key}) };
    const ref = cache.home(&key);
    r.stripe = try std.fmt.allocPrint(arena, "{d}:{d}", .{ ref.span_index, ref.block_index });

    const head = cyclone.object.openHead(arena, &cache, &key) catch |err| {
        r.error_message = try std.fmt.allocPrint(arena, "cannot read the object's head: {s}", .{@errorName(err)});
        return finishObject(out, r, opts, json);
    } orelse {
        r.error_message = "not in the cache";
        return finishObject(out, r, opts, json);
    };
    r.found = true;
    r.head_offset = head.entry.offset;
    r.head = try docReport(arena, head.doc, head.fragment, common.hash_type);
    const alts = try arena.alloc(FragmentReport.AltReport, head.alternates.len);
    for (head.alternates, alts, 0..) |a, *ar, i| ar.* = try altReport(arena, a, i);
    r.alternates = alts;
    if (alts.len != 0 and opts.alt >= alts.len) {
        r.error_message = try std.fmt.allocPrint(arena, "no alternate {d}; there {s} {d}", .{ opts.alt, if (alts.len == 1) "is" else "are", alts.len });
        return finishObject(out, r, opts, json);
    }

    var alt = opts.alt;
    if (opts.select and head.alternates.len != 0) {
        const cfg = opts.select_config;
        const request = try cyclone.select.normalizeAcceptEncoding(arena, opts.request.items, cfg.normalize_ae);
        const now = Io.Clock.real.now(io).toSeconds();
        const sel = try cyclone.select.select(arena, cfg, request, head.alternates, now);
        const matches = try arena.alloc(ObjectReport.SelectionReport.Match, sel.matches.len);
        for (sel.matches, matches, 0..) |m, *mr, i| mr.* = .{
            .index = i,
            .skipped = m.skipped,
            .quality = m.quality,
            .q = m.q,
            .vary = @tagName(m.variability),
            .vary_field = m.vary_field,
            .age = m.age,
        };
        r.selection = .{ .request = request, .normalize_ae = cfg.normalize_ae, .chosen = sel.index, .alternates = matches };
        alt = sel.index orelse {
            r.error_message = "no alternate matches the request; ATS would go to the origin";
            return finishObject(out, r, opts, json);
        };
    }

    const c = cyclone.object.chain(arena, &cache, &head, alt, opts.range) catch |err| {
        r.error_message = switch (err) {
            error.Unsatisfiable => try std.fmt.allocPrint(arena, "the range is not satisfiable: alternate {d} has {d} bytes", .{ alt, objectSize(head, alt) }),
            else => try std.fmt.allocPrint(arena, "cannot follow the fragments: {s}", .{@errorName(err)}),
        };
        return finishObject(out, r, opts, json);
    };
    r.selected = c.alternate;
    r.object_size = c.object_size;
    if (opts.range != null) r.range = .{ .first = c.range.start, .last = c.range.end - 1, .length = c.range.len() };
    r.covered = c.covered;
    r.complete = c.complete;
    r.problems = c.problems;
    const entries = try arena.alloc(ObjectReport.FragmentEntry, c.fragments.len);
    for (c.fragments, entries) |f, *e| e.* = .{
        .index = f.index,
        .key = try std.fmt.allocPrint(arena, "{f}", .{f.key}),
        .body_start = f.body_start,
        .data_len = f.data_len,
        .offset = f.offset,
        .in_head = f.in_head,
        .stale_only = f.stale_only,
    };
    r.fragments = entries;

    if (opts.body) {
        const n = try cyclone.object.writeBody(&cache, &head, c, out);
        try out.flush();
        if (n != c.range.len() or !c.complete) {
            std.debug.print("cyc-doc: body incomplete: wrote {d} of {d} bytes\n", .{ n, c.range.len() });
            for (c.problems) |p| std.debug.print("  {s}\n", .{p});
            std.process.exit(1);
        }
        return;
    }
    return finishObject(out, r, opts, json);
}

fn objectSize(head: cyclone.object.Head, alt: usize) u64 {
    if (head.alternates.len == 0) return head.doc.total_len;
    return @intCast(@max(0, head.alternates[alt].object_size));
}

fn finishObject(out: *Io.Writer, r: ObjectReport, opts: ObjectOptions, json: bool) !void {
    if (json) {
        try std.json.Stringify.value(r, .{ .whitespace = .indent_2 }, out);
        try out.writeByte('\n');
    } else if (!opts.body) {
        try printObject(out, r, opts);
    }
    if (r.error_message != null and (opts.body or !r.found or r.selected == null)) {
        try out.flush();
        if (opts.body) std.debug.print("cyc-doc: {s}: {s}\n", .{ r.input, r.error_message.? });
        std.process.exit(1);
    }
}

fn printObject(out: *Io.Writer, r: ObjectReport, opts: ObjectOptions) !void {
    if (!std.mem.eql(u8, r.input, r.key)) try out.print("url         {s}\n", .{r.input});
    try out.print("key         {s}\n", .{r.key});
    try out.print("stripe      {s}\n", .{r.stripe});
    if (r.head) |d| {
        try out.print("head        offset {d}: Doc {d} bytes (header {d}, data {d}), version {s}\n", .{ r.head_offset, d.len, d.hlen, d.data_len, d.version });
    }
    if (r.alternates.len != 0) try out.print("alternates  {d}\n", .{r.alternates.len});
    for (r.alternates) |a| try printAlt(out, a, opts.headers);
    if (r.selection) |sel| try printSelection(out, sel);
    if (r.found and r.error_message == null) {
        try out.writeByte('\n');
        if (r.selected) |i| try out.print("body        alt {d}: ", .{i}) else try out.writeAll("body        ");
        if (r.range) |rg| {
            try out.print("bytes {d}-{d} of {d} ({d} bytes), {d} fragment{s} read", .{ rg.first, rg.last, r.object_size, rg.length, r.fragments.len, if (r.fragments.len == 1) "" else "s" });
        } else {
            try out.print("{d} bytes in {d} fragment{s}", .{ r.object_size, r.fragments.len, if (r.fragments.len == 1) "" else "s" });
        }
        if (r.complete) {
            try out.writeAll(", complete\n");
        } else if (r.range != null) {
            try out.print(", data found up to byte {d}: INCOMPLETE\n", .{r.covered});
        } else {
            try out.print(", {d} bytes found: INCOMPLETE\n", .{r.covered});
        }
        for (r.fragments) |f| {
            try out.print("  {d: >4}  {s}  ", .{ f.index, f.key });
            if (f.offset) |o| {
                try out.print("offset {d: >12}  body {d}+{d}{s}\n", .{ o, f.body_start, f.data_len, if (f.in_head) "  (in the head Doc)" else "" });
            } else {
                try out.print("MISSING{s}\n", .{if (f.stale_only) " (a stale entry has it)" else ""});
            }
        }
        for (r.problems) |p| try out.print("problem: {s}\n", .{p});
    }
    if (r.error_message) |m| try out.print("error: {s}\n", .{m});
}

fn printSelection(out: *Io.Writer, sel: ObjectReport.SelectionReport) !void {
    try out.writeAll("\nselect      ");
    if (sel.chosen) |i| try out.print("alt {d}", .{i}) else try out.writeAll("none (a miss)");
    try out.print(" for a GET with {d} field{s} (normalize_ae {d})\n", .{ sel.request.len, if (sel.request.len == 1) "" else "s", sel.normalize_ae });
    for (sel.request) |f| try out.print("            > {s}: {s}\n", .{ f.name, f.value });
    for (sel.alternates) |m| {
        try out.print("  alt {d: <4}  ", .{m.index});
        if (m.skipped) {
            try out.writeAll("skipped: no data\n");
            continue;
        }
        if (std.mem.eql(u8, m.vary, "some")) {
            try out.print("ruled out: Vary {s} differs", .{m.vary_field});
        } else if (std.mem.eql(u8, m.vary, "all")) {
            try out.writeAll("ruled out: Vary *");
        } else if (m.quality < 0) {
            const names = [_][]const u8{ "Accept", "Accept-Charset", "Accept-Encoding", "Accept-Language" };
            for (m.q, names) |q, n| if (q < 0 and q != -2) {
                try out.print("ruled out: {s} does not accept it", .{n});
                break;
            };
        } else {
            try out.print("quality {d:.4}", .{m.quality});
        }
        try out.print("  (accept {d}, charset {d}, encoding {d}, language {d}; age {d} s)\n", .{ m.q[0], m.q[1], m.q[2], m.q[3], m.age });
    }
}

const FragmentOptions = struct {
    at: ?struct { usize, u64 } = null,
    headers: bool = false,
    data: bool = false,
};

/// Fragments longer than this are not read (ATS's are at most a few MB).
const max_fragment_len = 64 * 1024 * 1024;

const FragmentReport = struct {
    span_index: usize,
    span: []const u8,
    offset: u64,
    /// The stripe whose content area holds the offset, as SPAN:BLOCK.
    stripe: ?[]const u8,
    doc: ?DocReport = null,
    error_message: ?[]const u8 = null,
    alternates: []const AltReport = &.{},

    const DocReport = struct {
        magic: u32,
        len: u32,
        total_len: u64,
        hlen: u32,
        data_len: u64,
        first_key: []const u8,
        key: []const u8,
        doc_type: u8,
        version: []const u8,
        sync_serial: u32,
        write_serial: u32,
        pinned: u32,
        checksum: u32,
        /// "off" (DOC_NO_CHECKSUM), "ok", or "bad".
        checksum_state: []const u8,
        single_fragment: bool,
    };

    const AltReport = struct {
        index: usize,
        object_key: []const u8,
        object_size: i64,
        frag_offsets: []const u64,
        request_sent_time: i64,
        response_received_time: i64,
        method: []const u8,
        url: ?cyclone.format.http.Url,
        request_version: []const u8,
        status: i16,
        reason: []const u8,
        response_version: []const u8,
        request_fields: []const cyclone.format.http.Field,
        response_fields: []const cyclone.format.http.Field,
        wks_identity: ?u64,
    };
};

fn fragmentCommand(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, out: *Io.Writer, common: *const cli.Common, opts: FragmentOptions, json: bool) !void {
    const at = opts.at orelse cli.fatal("fragment needs --at SPAN:OFFSET", .{});
    const spans = common.spans.items;
    if (at[0] >= spans.len) cli.fatal("--at {d}:{d}: there are only {d} spans", .{ at[0], at[1], spans.len });
    var span = try openSpan(gpa, io, out, spans[at[0]]);
    defer span.close(gpa, io);

    var r: FragmentReport = .{ .span_index = at[0], .span = span.path, .offset = at[1], .stripe = null };
    for (span.blocks, 0..) |b, bi| {
        if (!b.free and at[1] >= b.offset and at[1] < b.offset + b.byteLen())
            r.stripe = try std.fmt.allocPrint(arena, "{d}:{d}", .{ at[0], bi });
    }

    const hash_type = common.hash_type;
    const doc = cyclone.doc.readHeader(io, span.file, hash_type, at[1]) catch |err| {
        r.error_message = @errorName(err);
        return printFragmentReport(out, r, opts, json);
    };
    if (doc.magic != cyclone.format.doc.magic) {
        r.error_message = try std.fmt.allocPrint(arena, "no Doc at this offset (magic 0x{x:0>8})", .{doc.magic});
        return printFragmentReport(out, r, opts, json);
    }
    const frag = cyclone.doc.readFragment(arena, io, span.file, hash_type, at[1], max_fragment_len) catch |err| {
        r.error_message = try std.fmt.allocPrint(arena, "cannot read the fragment ({s}, len {d})", .{ @errorName(err), doc.len });
        return printFragmentReport(out, r, opts, json);
    };

    if (opts.data and !json) {
        const start = @min(doc.prefixLen(), frag.len);
        try out.writeAll(frag[start..]);
        return;
    }

    r.doc = try docReport(arena, doc, frag, hash_type);

    if (doc.doc_type == .http and doc.hlen > 0) {
        if (cyclone.doc.alternates(arena, frag, doc)) |alts| {
            const reports = try arena.alloc(FragmentReport.AltReport, alts.len);
            for (alts, reports, 0..) |a, *ar, i| ar.* = try altReport(arena, a, i);
            r.alternates = reports;
        } else |err| {
            r.error_message = try std.fmt.allocPrint(arena, "cannot decode the alternates: {s}", .{@errorName(err)});
        }
    }
    try printFragmentReport(out, r, opts, json);
}

fn docReport(arena: std.mem.Allocator, doc: cyclone.doc.Doc, frag: []const u8, hash_type: cyclone.HashType) !FragmentReport.DocReport {
    return .{
        .magic = doc.magic,
        .len = doc.len,
        .total_len = doc.total_len,
        .hlen = doc.hlen,
        .data_len = doc.dataLen(),
        .first_key = try std.fmt.allocPrint(arena, "{f}", .{doc.first_key}),
        .key = try std.fmt.allocPrint(arena, "{f}", .{doc.key}),
        .doc_type = @backingInt(doc.doc_type),
        .version = try std.fmt.allocPrint(arena, "{d}.{d}", .{ doc.v_major, doc.v_minor }),
        .sync_serial = doc.sync_serial,
        .write_serial = doc.write_serial,
        .pinned = doc.pinned,
        .checksum = doc.checksum,
        .checksum_state = if (doc.checksum == cyclone.format.doc.no_checksum)
            "off"
        else if (cyclone.format.doc.checksum(hash_type, frag, true) == doc.checksum)
            "ok"
        else
            "bad",
        .single_fragment = doc.singleFragment(),
    };
}

fn altReport(arena: std.mem.Allocator, a: cyclone.format.http.Alternate, index: usize) !FragmentReport.AltReport {
    const req = a.request;
    const resp = a.response;
    return .{
        .index = index,
        .object_key = try std.fmt.allocPrint(arena, "{f}", .{a.object_key}),
        .object_size = a.object_size,
        .frag_offsets = a.frag_offsets,
        .request_sent_time = a.request_sent_time,
        .response_received_time = a.response_received_time,
        .method = if (req) |h| h.method else "",
        .url = if (req) |h| h.url else null,
        .request_version = if (req) |h| try std.fmt.allocPrint(arena, "{d}.{d}", .{ h.version_major, h.version_minor }) else "",
        .status = if (resp) |h| h.status else 0,
        .reason = if (resp) |h| h.reason else "",
        .response_version = if (resp) |h| try std.fmt.allocPrint(arena, "{d}.{d}", .{ h.version_major, h.version_minor }) else "",
        .request_fields = if (req) |h| h.fields else &.{},
        .response_fields = if (resp) |h| h.fields else &.{},
        .wks_identity = a.wks_identity,
    };
}

fn printFragmentReport(out: *Io.Writer, r: FragmentReport, opts: FragmentOptions, json: bool) !void {
    if (json) {
        try std.json.Stringify.value(r, .{ .whitespace = .indent_2 }, out);
        try out.writeByte('\n');
        return;
    }
    try out.print("fragment    span {d} offset {d}", .{ r.span_index, r.offset });
    if (r.stripe) |st| try out.print(" (stripe {s})", .{st}) else try out.writeAll(" (not in any stripe)");
    try out.writeByte('\n');
    if (r.doc) |d| {
        try out.print("length      {d} (Doc {d}, header {d}, data {d})\n", .{ d.len, d.len - d.hlen - d.data_len, d.hlen, d.data_len });
        try out.print("object      {d} bytes{s}\n", .{ d.total_len, if (d.single_fragment) ", all in this fragment" else "" });
        try out.print("first_key   {s}\nkey         {s}\n", .{ d.first_key, d.key });
        try out.print("type        {s}  version {s}\n", .{ docTypeName(d.doc_type), d.version });
        try out.print("serials     sync {d}  write {d}\n", .{ d.sync_serial, d.write_serial });
        if (d.pinned != 0) try out.print("pinned      until {f}\n", .{Time{ .secs = d.pinned }});
        if (std.mem.eql(u8, d.checksum_state, "off")) {
            try out.writeAll("checksum    off\n");
        } else {
            try out.print("checksum    0x{x:0>8} ({s})\n", .{ d.checksum, d.checksum_state });
        }
    }
    if (r.alternates.len != 0) try out.print("alternates  {d}\n", .{r.alternates.len});
    for (r.alternates) |a| try printAlt(out, a, opts.headers);
    if (r.error_message) |m| try out.print("error: {s}\n", .{m});
}

fn printAlt(out: *Io.Writer, a: FragmentReport.AltReport, headers: bool) !void {
    try out.print("\nalt {d}       {s} ", .{ a.index, a.method });
    if (a.url) |u| try out.print("{f}", .{u});
    try out.print("\n            {d} {s}, {d} bytes", .{ a.status, a.reason, a.object_size });
    for (a.response_fields) |f| if (std.ascii.eqlIgnoreCase(f.name, "Content-Type")) {
        try out.print(", {s}", .{f.value});
        break;
    };
    try out.writeByte('\n');
    for (a.response_fields) |f| if (std.ascii.eqlIgnoreCase(f.name, "Vary")) {
        try out.print("            vary {s}\n", .{f.value});
    };
    try out.print("            object_key {s}, {d} fragment{s}", .{ a.object_key, a.frag_offsets.len + 1, if (a.frag_offsets.len == 0) "" else "s" });
    if (a.frag_offsets.len != 0) {
        try out.writeAll(" (starting at");
        for (a.frag_offsets) |o| try out.print(" {d}", .{o});
        try out.writeAll(")");
    }
    try out.print("\n            request sent {f}, response received {f}\n", .{ Time{ .secs = a.request_sent_time }, Time{ .secs = a.response_received_time } });
    if (headers) {
        try out.print("            > {s} ", .{a.method});
        if (a.url) |u| try out.print("{f}", .{u});
        try out.print(" HTTP/{s}\n", .{a.request_version});
        for (a.request_fields) |f| try out.print("            > {s}: {s}\n", .{ f.name, f.value });
        try out.print("            < HTTP/{s} {d} {s}\n", .{ a.response_version, a.status, a.reason });
        for (a.response_fields) |f| try out.print("            < {s}: {s}\n", .{ f.name, f.value });
    }
}

fn docTypeName(t: u8) []const u8 {
    return switch (t) {
        0 => "none",
        2 => "rtsp",
        3 => "http",
        else => "unknown",
    };
}

/// Seconds since the epoch, printed as UTC.
const Time = struct {
    secs: i64,

    pub fn format(t: Time, w: *Io.Writer) Io.Writer.Error!void {
        if (t.secs <= 0) return w.print("{d}", .{t.secs});
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(t.secs) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        try w.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}Z", .{
            yd.year,              md.month.numeric(),      @as(u32, md.day_index) + 1,
            ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        });
    }
};

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
