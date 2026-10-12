//! Whole objects: the head Doc, its alternates, and the chain of fragments
//! holding an alternate's body, followed as `CacheVC::openReadStartHead`,
//! `openReadStartEarliest` and `openReadReadDone` do.
//!
//! Every Doc of an object lives in the stripe its key (`first_key`) picks.
//! The body starts at the alternate's `object_key` (the earliest key) and
//! goes on through `next_CacheKey`, each fragment a Doc whose own `key`
//! matches, until `object_size` bytes are covered. A small object's data can
//! sit in the head Doc itself, when the head's `key` is the object key.

const std = @import("std");
const Io = std.Io;
const CacheKey = @import("key.zig").CacheKey;
const Stripe = @import("stripe.zig").Stripe;
const cache_mod = @import("cache.zig");
const Cache = cache_mod.Cache;
const doc_mod = @import("doc.zig");
const fmt_doc = @import("format/doc.zig");
const Doc = doc_mod.Doc;
const http = @import("format/http.zig");

/// ATS fragments are at most a few MB; refuse to read anything claiming more.
const max_fragment_len = 64 * 1024 * 1024;
/// A guard on following a chain through damaged data.
const max_fragments = 1 << 20;

pub const Head = struct {
    key: CacheKey,
    stripe: *Stripe,
    /// The directory entry and Doc ATS reads for the key.
    entry: cache_mod.Candidate,
    doc: Doc,
    /// The whole head fragment; header strings point into it.
    fragment: []const u8,
    /// HTTP alternates; empty for a non-HTTP object.
    alternates: []const http.Alternate,
};

/// Finds and reads an object's head Doc and decodes its alternates. Null
/// for a miss. Allocates with `arena`.
pub fn openHead(arena: std.mem.Allocator, cache: *Cache, key: *const CacheKey) !?Head {
    const s = try cache.homeStripe(key);
    if (s.chosen == null) return error.NoUsableDirectory;
    const entry = (try cache.find(s, key, .head)) orelse return null;
    const d = entry.doc.?;
    const frag = try doc_mod.readFragment(arena, cache.io, s.span.file, cache.config.hash_type, entry.offset, @min(entry.dir.approxSize(), max_fragment_len));
    var alts: []const http.Alternate = &.{};
    if (d.doc_type == .http) {
        if (d.hlen == 0) return error.HttpHeadWithoutHeader;
        alts = try doc_mod.alternates(arena, frag, d);
        if (alts.len == 0) return error.NoAlternates;
    }
    return .{ .key = key.*, .stripe = s, .entry = entry, .doc = d, .fragment = frag, .alternates = alts };
}

pub const Fragment = struct {
    index: usize,
    key: CacheKey,
    /// Where the body bytes start in the object.
    body_start: u64,
    /// Body bytes this fragment holds; 0 when missing.
    data_len: u64 = 0,
    /// Byte offset of the Doc in the span; null when the fragment is
    /// missing.
    offset: ?u64 = null,
    approx_size: u64 = 0,
    doc: ?Doc = null,
    /// The data is in the head Doc (a single-fragment object).
    in_head: bool = false,
    /// Missing, but a stale entry (one ATS no longer trusts) has the key.
    stale_only: bool = false,
};

pub const Chain = struct {
    /// Index of the alternate, or null for a non-HTTP object.
    alternate: ?usize,
    object_size: u64,
    /// The bytes asked for; the whole object without a range.
    range: ByteRange,
    /// The fragments walked: all of them for the whole object, or those
    /// holding the range.
    fragments: []const Fragment,
    /// Body offset up to which the fragments found hold data, without a
    /// gap, from the first fragment walked.
    covered: u64,
    /// Everything there and consistent: what ATS would serve.
    complete: bool,
    /// Inconsistencies found on the way, in plain words.
    problems: []const []const u8,
};

/// Body bytes `[start, end)`.
pub const ByteRange = struct {
    start: u64,
    end: u64,

    pub fn len(r: ByteRange) u64 {
        return r.end - r.start;
    }
};

/// One HTTP byte range (RFC 9110 14.1.1), before the object size is known.
pub const RangeSpec = union(enum) {
    /// `first-last` (last inclusive), or `first-` (last null).
    span: struct { first: u64, last: ?u64 },
    /// `-n`: the last n bytes.
    suffix: u64,

    /// Parses `[bytes=]first-[last]` or `[bytes=]-suffix`. Only one range.
    pub fn parse(text: []const u8) error{BadRange}!RangeSpec {
        var t = std.mem.trim(u8, text, " \t");
        if (std.ascii.startsWithIgnoreCase(t, "bytes=")) t = std.mem.trim(u8, t["bytes=".len..], " \t");
        const dash = std.mem.indexOfScalar(u8, t, '-') orelse return error.BadRange;
        const a = std.mem.trim(u8, t[0..dash], " \t");
        const b = std.mem.trim(u8, t[dash + 1 ..], " \t");
        if (a.len == 0) return .{ .suffix = try number(b) };
        const first = try number(a);
        if (b.len == 0) return .{ .span = .{ .first = first, .last = null } };
        const last = try number(b);
        if (last < first) return error.BadRange;
        return .{ .span = .{ .first = first, .last = last } };
    }

    fn number(s: []const u8) error{BadRange}!u64 {
        if (s.len == 0) return error.BadRange;
        for (s) |c| if (!std.ascii.isDigit(c)) return error.BadRange;
        return std.fmt.parseInt(u64, s, 10) catch error.BadRange;
    }

    /// The bytes of an object of `size` the range selects; null when it is
    /// unsatisfiable (416).
    pub fn resolve(spec: RangeSpec, size: u64) ?ByteRange {
        switch (spec) {
            .span => |r| {
                if (r.first >= size) return null;
                const last = if (r.last) |l| @min(l, size - 1) else size - 1;
                return .{ .start = r.first, .end = last + 1 };
            },
            .suffix => |n| {
                if (n == 0 or size == 0) return null;
                return .{ .start = size - @min(n, size), .end = size };
            },
        }
    }
};

/// Finds the fragments of alternate `alt` (ignored for a non-HTTP object)
/// that hold `range`, or all of them for a null range. With a range it
/// starts at the fragment the alternate's offset table puts the first byte
/// in, as ATS does for a seek (`CacheVC::openReadMain`), and stops once
/// the last byte is covered.
pub fn chain(arena: std.mem.Allocator, cache: *Cache, head: *const Head, alt: usize, range: ?RangeSpec) !Chain {
    var problems: std.ArrayList([]const u8) = .empty;
    var frags: std.ArrayList(Fragment) = .empty;

    var size: u64 = undefined;
    var key: CacheKey = undefined;
    var frag_offsets: []const u64 = &.{};
    var alternate: ?usize = null;
    if (head.alternates.len != 0) {
        if (alt >= head.alternates.len) return error.NoSuchAlternate;
        const a = head.alternates[alt];
        alternate = alt;
        if (a.object_size < 0) return error.BadObjectSize;
        size = @intCast(a.object_size);
        key = a.object_key;
        frag_offsets = a.frag_offsets;
        // ATS refuses an alternate whose Content-Length disagrees.
        if (a.response) |r| if (r.get("Content-Length")) |cl| {
            const n = std.fmt.parseInt(u64, std.mem.trim(u8, cl, " \t"), 10) catch null;
            if (n == null or n.? != size)
                try problems.append(arena, try std.fmt.allocPrint(arena, "Content-Length {s} is not the object size {d}; ATS refuses this alternate", .{ cl, size }));
        };
    } else {
        // A non-HTTP object: its data follows from the head's own key.
        size = head.doc.total_len;
        key = head.doc.key;
    }
    const want: ByteRange = if (range) |r| r.resolve(size) orelse return error.Unsatisfiable else .{ .start = 0, .end = size };

    var covered: u64 = 0;
    if (key.eql(&head.doc.key)) {
        // The data is in the head Doc (`if (key == doc->key)`).
        const n = head.doc.dataLen();
        try frags.append(arena, .{
            .index = 0,
            .key = key,
            .body_start = 0,
            .data_len = n,
            .offset = head.entry.offset,
            .approx_size = head.entry.dir.approxSize(),
            .doc = head.doc,
            .in_head = true,
        });
        covered = n;
        if (n != size) try problems.append(arena, try std.fmt.allocPrint(arena, "the head Doc holds {d} data bytes, not the object size {d}", .{ n, size }));
    } else if (want.len() != 0) {
        // The fragment holding the first byte: one past the last table
        // entry at or before it.
        var i: usize = 0;
        while (i < frag_offsets.len and frag_offsets[i] <= want.start) i += 1;
        if (i > 0) covered = frag_offsets[i - 1];
        for (0..i) |_| key = key.next();
        while (covered < want.end) : (i += 1) {
            if (i == max_fragments) {
                try problems.append(arena, "over a million fragments; giving up");
                break;
            }
            if (i > 0) {
                if (i - 1 < frag_offsets.len and frag_offsets[i - 1] != covered)
                    try problems.append(arena, try std.fmt.allocPrint(arena, "fragment {d} starts at body offset {d}, but the alternate's table says {d}", .{ i, covered, frag_offsets[i - 1] }));
            }
            var f: Fragment = .{ .index = i, .key = key, .body_start = covered };
            var arena_probe: std.heap.ArenaAllocator = .init(cache.gpa);
            defer arena_probe.deinit();
            const p = try cache.probe(arena_probe.allocator(), head.stripe, &key);
            const found = p.hit(.fragment) orelse {
                f.stale_only = p.anyMatch(.fragment) != null;
                try frags.append(arena, f);
                try problems.append(arena, try std.fmt.allocPrint(arena, "fragment {d} (key {f}) is missing{s}", .{ i, key, if (f.stale_only) "; only a stale entry has it" else "" }));
                break;
            };
            const d = found.doc.?;
            f.offset = found.offset;
            f.approx_size = found.dir.approxSize();
            f.doc = d;
            f.data_len = d.dataLen();
            if (!d.first_key.eql(&head.key))
                try problems.append(arena, try std.fmt.allocPrint(arena, "fragment {d} names another object as its first_key ({f})", .{ i, d.first_key }));
            try frags.append(arena, f);
            covered += f.data_len;
            if (f.data_len == 0) {
                try problems.append(arena, try std.fmt.allocPrint(arena, "fragment {d} holds no data", .{i}));
                break;
            }
            key = key.next();
        }
    }
    if (covered > size) try problems.append(arena, try std.fmt.allocPrint(arena, "the fragments hold {d} bytes, more than the object size {d}", .{ covered, size }));
    if (covered == size and alternate != null and frags.items.len != 0) {
        const last = frags.items[frags.items.len - 1].index;
        if (last != frag_offsets.len)
            try problems.append(arena, try std.fmt.allocPrint(arena, "{d} fragments, but the alternate lists {d} fragment offsets", .{ last + 1, frag_offsets.len }));
    }

    return .{
        .alternate = alternate,
        .object_size = size,
        .range = want,
        .fragments = frags.items,
        .covered = covered,
        .complete = covered >= want.end and problems.items.len == 0,
        .problems = problems.items,
    };
}

/// Writes the chain's range of the body, reading only the bytes needed
/// from each fragment. Returns the number written; less than the range's
/// length when fragments are missing.
pub fn writeBody(cache: *Cache, head: *const Head, c: Chain, w: *Io.Writer) !u64 {
    var written: u64 = 0;
    var buf: [64 * 1024]u8 = undefined;
    for (c.fragments) |f| {
        const off = f.offset orelse break;
        // This fragment's share of the range.
        const lo = @max(f.body_start, c.range.start + written);
        const hi = @min(f.body_start + f.data_len, c.range.end);
        if (lo >= hi) continue;
        if (lo != c.range.start + written) break; // a gap
        if (f.in_head) {
            const start = head.doc.prefixLen() + (lo - f.body_start);
            try w.writeAll(head.fragment[start..][0..@intCast(hi - lo)]);
        } else {
            const d = try doc_mod.readHeader(cache.io, head.stripe.span.file, cache.config.hash_type, off);
            if (d.magic != fmt_doc.magic or !d.key.eql(&f.key) or d.dataLen() != f.data_len) return error.FragmentChanged;
            var at = off + d.prefixLen() + (lo - f.body_start);
            var left = hi - lo;
            while (left != 0) {
                const n: usize = @intCast(@min(left, buf.len));
                if (try head.stripe.span.file.readPositionalAll(cache.io, buf[0..n], at) != n) return error.Truncated;
                try w.writeAll(buf[0..n]);
                at += n;
                left -= n;
            }
        }
        written += hi - lo;
        if (written == c.range.len()) break;
    }
    return written;
}

test "byte ranges resolve as RFC 9110 says" {
    const t = std.testing;
    const size = 1000;
    try t.expectEqual(ByteRange{ .start = 0, .end = 500 }, (try RangeSpec.parse("bytes=0-499")).resolve(size).?);
    try t.expectEqual(ByteRange{ .start = 500, .end = 1000 }, (try RangeSpec.parse("500-")).resolve(size).?);
    try t.expectEqual(ByteRange{ .start = 900, .end = 1000 }, (try RangeSpec.parse("-100")).resolve(size).?);
    try t.expectEqual(ByteRange{ .start = 0, .end = 1000 }, (try RangeSpec.parse("-5000")).resolve(size).?);
    try t.expectEqual(ByteRange{ .start = 990, .end = 1000 }, (try RangeSpec.parse("990-5000")).resolve(size).?);
    try t.expectEqual(@as(?ByteRange, null), (try RangeSpec.parse("1000-")).resolve(size));
    try t.expectEqual(@as(?ByteRange, null), (try RangeSpec.parse("-0")).resolve(size));
    try t.expectEqual(@as(?ByteRange, null), (try RangeSpec.parse("0-")).resolve(0));
    try t.expectError(error.BadRange, RangeSpec.parse("5-4"));
    try t.expectError(error.BadRange, RangeSpec.parse("1-2,5-6"));
    try t.expectError(error.BadRange, RangeSpec.parse("x-"));
    try t.expectError(error.BadRange, RangeSpec.parse("-"));
}
