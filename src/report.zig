//! Reports on lookups and objects, as plain structs that print as JSON:
//! shared by the command line tools (`--json`) and the service, so both
//! give the same answer in the same shape. Strings are allocated with the
//! arena passed in, or point into what was read.

const std = @import("std");
const Io = std.Io;
const Cache = @import("cache.zig").Cache;
const CacheKey = @import("key.zig").CacheKey;
const hash = @import("hash.zig");
const doc_mod = @import("doc.zig");
const fmt_doc = @import("format/doc.zig");
const http = @import("format/http.zig");
const object = @import("object.zig");
const select = @import("select.zig");
const assign = @import("assign.zig");
const dir = @import("dir.zig");
const stripe_mod = @import("stripe.zig");
const Stripe = stripe_mod.Stripe;
const span_mod = @import("span.zig");

pub const DocReport = struct {
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

/// `frag` is the whole fragment, for the checksum.
pub fn docReport(arena: std.mem.Allocator, doc: doc_mod.Doc, frag: []const u8, hash_type: hash.HashType) !DocReport {
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
        .checksum_state = if (doc.checksum == fmt_doc.no_checksum)
            "off"
        else if (fmt_doc.checksum(hash_type, frag, true) == doc.checksum)
            "ok"
        else
            "bad",
        .single_fragment = doc.singleFragment(),
    };
}

pub const AltReport = struct {
    index: usize,
    object_key: []const u8,
    object_size: i64,
    frag_offsets: []const u64,
    request_sent_time: i64,
    response_received_time: i64,
    method: []const u8,
    url: ?http.Url,
    request_version: []const u8,
    status: i16,
    reason: []const u8,
    response_version: []const u8,
    request_fields: []const http.Field,
    response_fields: []const http.Field,
    wks_identity: ?u64,
};

pub fn altReport(arena: std.mem.Allocator, a: http.Alternate, index: usize) !AltReport {
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

// ---------------------------------------------------------------------------
// Objects

/// What to read of an object.
pub const ObjectQuery = struct {
    /// The alternate, when not chosen by `select`.
    alt: usize = 0,
    /// Choose the alternate as ATS would for a GET with `request`.
    select: bool = false,
    request: []const http.Field = &.{},
    select_config: select.Config = .{},
    /// Seconds since the epoch, for document ages.
    now: i64 = 0,
    range: ?object.RangeSpec = null,
};

pub const ObjectReport = struct {
    input: []const u8,
    key: []const u8,
    found: bool = false,
    /// The object's stripe, as SPAN:BLOCK.
    stripe: []const u8 = "",
    head_offset: u64 = 0,
    head: ?DocReport = null,
    alternates: []const AltReport = &.{},
    /// How the alternate was chosen, with `select`.
    selection: ?SelectionReport = null,
    /// The alternate whose fragments are listed (null: non-HTTP object).
    selected: ?usize = null,
    object_size: u64 = 0,
    /// With a range: the bytes asked for (last inclusive, as in HTTP).
    range: ?struct { first: u64, last: u64, length: u64 } = null,
    covered: u64 = 0,
    complete: bool = false,
    fragments: []const FragmentEntry = &.{},
    problems: []const []const u8 = &.{},
    error_message: ?[]const u8 = null,

    pub const SelectionReport = struct {
        /// The request fields matched, after Accept-Encoding normalization.
        request: []const http.Field,
        normalize_ae: u3,
        chosen: ?usize,
        alternates: []const Match,

        pub const Match = struct {
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

    pub const FragmentEntry = struct {
        index: usize,
        key: []const u8,
        body_start: u64,
        data_len: u64,
        offset: ?u64,
        in_head: bool,
        stale_only: bool,
    };
};

/// How reading an object ended.
pub const Outcome = enum {
    /// The chain was followed; `complete` says whether it is all there.
    read,
    /// No head for the key.
    miss,
    /// The head could not be read or decoded.
    bad_head,
    /// The alternate asked for does not exist.
    no_such_alternate,
    /// `select` found no alternate for the request.
    no_match,
    /// The range starts past the end of the object.
    unsatisfiable,
    /// The fragments could not be followed.
    bad_chain,
};

pub const ObjectResult = struct {
    report: ObjectReport,
    outcome: Outcome,
    /// Set from `read` on: the head and the chain, for reading the body.
    head: ?object.Head = null,
    chain: ?object.Chain = null,
};

/// Finds `key`'s object, chooses an alternate and follows its fragments,
/// reporting each step. `input` is what the key was made from, for the
/// report.
pub fn readObject(arena: std.mem.Allocator, cache: *Cache, key: *const CacheKey, input: []const u8, q: ObjectQuery) !ObjectResult {
    var r: ObjectReport = .{ .input = input, .key = try std.fmt.allocPrint(arena, "{f}", .{key.*}) };
    const ref = cache.home(key);
    r.stripe = try std.fmt.allocPrint(arena, "{d}:{d}", .{ ref.span_index, ref.block_index });

    const head = object.openHead(arena, cache, key) catch |err| {
        r.error_message = try std.fmt.allocPrint(arena, "cannot read the object's head: {s}", .{@errorName(err)});
        return .{ .report = r, .outcome = .bad_head };
    } orelse {
        r.error_message = "not in the cache";
        return .{ .report = r, .outcome = .miss };
    };
    r.found = true;
    r.head_offset = head.entry.offset;
    r.head = try docReport(arena, head.doc, head.fragment, cache.config.hash_type);
    const alts = try arena.alloc(AltReport, head.alternates.len);
    for (head.alternates, alts, 0..) |a, *ar, i| ar.* = try altReport(arena, a, i);
    r.alternates = alts;

    var alt = q.alt;
    if (q.select and head.alternates.len != 0) {
        const cfg = q.select_config;
        const request = try select.normalizeAcceptEncoding(arena, q.request, cfg.normalize_ae);
        const sel = try select.select(arena, cfg, request, head.alternates, q.now);
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
            return .{ .report = r, .outcome = .no_match };
        };
    } else if (alts.len != 0 and alt >= alts.len) {
        r.error_message = try std.fmt.allocPrint(arena, "no alternate {d}; there {s} {d}", .{ alt, if (alts.len == 1) "is" else "are", alts.len });
        return .{ .report = r, .outcome = .no_such_alternate };
    }

    if (head.alternates.len != 0) r.selected = alt;
    // The head is returned by value; the chain keeps no pointer to it.
    const c = object.chain(arena, cache, &head, alt, q.range) catch |err| {
        r.error_message = switch (err) {
            error.Unsatisfiable => try std.fmt.allocPrint(arena, "the range is not satisfiable: alternate {d} has {d} bytes", .{ alt, objectSize(&head, alt) }),
            else => try std.fmt.allocPrint(arena, "cannot follow the fragments: {s}", .{@errorName(err)}),
        };
        const outcome: Outcome = if (err == error.Unsatisfiable) .unsatisfiable else .bad_chain;
        return .{ .report = r, .outcome = outcome, .head = head };
    };
    r.selected = c.alternate;
    r.object_size = c.object_size;
    if (q.range != null) r.range = .{ .first = c.range.start, .last = c.range.end - 1, .length = c.range.len() };
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
    return .{ .report = r, .outcome = .read, .head = head, .chain = c };
}

/// The body size of alternate `alt` (or of a non-HTTP object).
pub fn objectSize(head: *const object.Head, alt: usize) u64 {
    if (head.alternates.len == 0) return head.doc.total_len;
    return @intCast(@max(0, head.alternates[alt].object_size));
}

// ---------------------------------------------------------------------------
// Lookups

pub const LookupStatus = enum {
    /// A valid entry whose Doc confirms the key.
    hit,
    /// Only stale entries confirm the key.
    stale,
    miss,
};

/// The Doc fields worth showing for a lookup.
pub const LookupDoc = struct {
    len: u32,
    total_len: u64,
    hlen: u32,
    data_len: u64,
    doc_type: []const u8,
    version: []const u8,
    first_key: []const u8,
    key: []const u8,
    pinned_until: u32,

    fn init(arena: std.mem.Allocator, d: doc_mod.Doc) !LookupDoc {
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

pub fn docTypeName(t: doc_mod.FragType) []const u8 {
    return switch (t) {
        .none => "none",
        .unused_1 => "unused_1",
        .rtsp => "rtsp",
        .http => "http",
        _ => "unknown",
    };
}

pub const LookupCandidate = struct {
    /// Entry index within the segment.
    index: u16,
    /// Byte offset in the span.
    offset: u64,
    approx_size: u64,
    head: bool,
    pinned: bool,
    phase: u1,
    valid: bool,
    verdict: ?doc_mod.Verdict = null,
    /// Set when the Doc has the right magic.
    doc: ?LookupDoc = null,
    read_error: ?[]const u8 = null,
};

pub const LookupReport = struct {
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
    status: LookupStatus = .miss,
    candidates: []const LookupCandidate = &.{},
};

/// Probes `key` in its home stripe, or in `stripe_override` (span, block),
/// and checks every tag match against its Doc.
pub fn lookup(arena: std.mem.Allocator, cache: *Cache, key: *const CacheKey, input: []const u8, stripe_override: ?[2]usize) !LookupReport {
    var r: LookupReport = .{ .input = input };
    r.key = try std.fmt.allocPrint(arena, "{f}", .{key.*});
    r.slot = assign.Table.slotOf(key);

    const ref = cache.home(key);
    const where = stripe_override orelse .{ ref.span_index, ref.block_index };
    r.span_index = where[0];
    r.block_index = where[1];
    r.span = cache.spans[where[0]].path;
    r.volume = cache.spans[where[0]].blocks[where[1]].number;
    r.home = stripe_override == null or (where[0] == ref.span_index and where[1] == ref.block_index);

    const s = try cache.stripe(where[0], where[1]);
    if (s.chosen == null) {
        r.error_message = "the stripe has no usable directory (see cyc-doc stripe; is --avg-obj-size right?)";
        return r;
    }
    const p = try cache.probe(arena, s, key);
    r.segment = p.slot.segment;
    r.bucket = p.slot.bucket;
    r.tag = p.slot.tag;
    r.chain_length = p.chain_length;

    const candidates = try arena.alloc(LookupCandidate, p.candidates.len);
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
            out.doc = try .init(arena, h);
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

// ---------------------------------------------------------------------------
// Stripes

pub const StripeReport = struct {
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
    header: ?stripe_mod.HeaderFooter,
    freelist: []const u16,
    issues: []const span_mod.Issue,
    diagnosis: ?stripe_mod.Diagnosis,
    /// Directory statistics, when asked for (a walk of every segment).
    dir_stats: ?dir.Stats = null,

    pub const CopyReport = struct {
        header: ?stripe_mod.HeaderFooter,
        footer: ?stripe_mod.HeaderFooter,
    };
};

/// Headers, geometry and the copy in use of one stripe (`cyc-doc stripe`).
pub fn stripeReport(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, span_index: usize, s: *const Stripe) !StripeReport {
    const g = s.geometry;
    var hash_text: Io.Writer.Allocating = .init(arena);
    try s.hashText(&hash_text.writer);
    const issues = try s.check(arena);

    // Only worth the scan when the footer is missing but header A is there.
    var diagnosis: ?stripe_mod.Diagnosis = null;
    if (!s.copies[0].magicOk() and !s.copies[1].magicOk()) {
        if (try stripe_mod.diagnoseGeometry(gpa, io, s.span, s.block)) |d| {
            defer gpa.free(d.candidates);
            diagnosis = .{ .dir_len = d.dir_len, .candidates = try arena.dupe(stripe_mod.Candidate, d.candidates) };
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

// ---------------------------------------------------------------------------
// Directories

/// One directory entry in use (`cyc-doc dir --entries`, `/v1/dir`).
pub const DirEntry = struct {
    span_index: usize,
    block_index: usize,
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
    doc: ?DirEntryDoc = null,
};

pub const DirEntryDoc = struct {
    /// False when the bytes there are not a Doc.
    magic_ok: bool,
    len: u32 = 0,
    hlen: u32 = 0,
    total_len: u64 = 0,
    doc_type: u8 = 0,
    first_key: ?CacheKey = null,
    key: ?CacheKey = null,
    /// The Doc key whose segment, bucket and tag the entry is filed
    /// under: "first_key" for a vector or single-fragment head, "key"
    /// for a data fragment, null if neither (a stale or reused slot).
    filed_under: ?[]const u8 = null,
    read_error: ?[]const u8 = null,
};

/// The entry `link` of bucket `bucket` in segment `segment`; with `docs`,
/// also the Doc it points at (one read). Allocates nothing.
pub fn dirEntry(io: Io, s: *const Stripe, hash_type: hash.HashType, span_index: usize, segment: u64, bucket: u64, link: dir.Link, docs: bool) !DirEntry {
    const d = link.dir;
    return .{
        .span_index = span_index,
        .block_index = s.block_index,
        .segment = segment,
        .bucket = bucket,
        .index = link.index,
        .offset = dir.contentOffset(s, d),
        .approx_size = d.approxSize(),
        .tag = d.tag(),
        .phase = d.phase(),
        .head = d.head(),
        .pinned = d.pinned(),
        .valid = dir.entryValid(s, d),
        .doc = if (docs) entryDoc(io, s, hash_type, segment, bucket, d) else null,
    };
}

fn entryDoc(io: Io, s: *const Stripe, hash_type: hash.HashType, segment: u64, bucket: u64, d: dir.Dir) DirEntryDoc {
    const doc = doc_mod.readHeader(io, s.span.file, hash_type, dir.contentOffset(s, d)) catch |err|
        return .{ .magic_ok = false, .read_error = @errorName(err) };
    if (doc.magic != fmt_doc.magic) return .{ .magic_ok = false };
    const g = s.geometry;
    const filed = struct {
        fn under(k: *const CacheKey, gg: stripe_mod.Geometry, seg: u64, b: u64, tag: u12) bool {
            const slot = dir.Slot.of(k, gg.segments, gg.buckets);
            return slot.segment == seg and slot.bucket == b and slot.tag == tag;
        }
    }.under;
    return .{
        .magic_ok = true,
        .len = doc.len,
        .hlen = doc.hlen,
        .total_len = doc.total_len,
        .doc_type = @backingInt(doc.doc_type),
        .first_key = doc.first_key,
        .key = doc.key,
        .filed_under = if (filed(&doc.first_key, g, segment, bucket, d.tag()))
            "first_key"
        else if (filed(&doc.key, g, segment, bucket, d.tag()))
            "key"
        else
            null,
    };
}

/// Walks every segment of `s` (from memory when loaded, else read into
/// `buf`, `dir.Segment.byteLen(s)` bytes).
pub fn dirStats(gpa: std.mem.Allocator, io: Io, s: *const Stripe, buf: []u8) !dir.Stats {
    var stats: dir.Stats = .{};
    for (0..s.geometry.segments) |i| {
        const seg = try dir.Segment.get(io, s, i, buf);
        stats.add(try dir.segmentStats(gpa, s, &seg));
    }
    return stats;
}
