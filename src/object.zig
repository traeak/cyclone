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
    fragments: []const Fragment,
    /// Body bytes the fragments found cover, from the start.
    covered: u64,
    /// Everything there and consistent: what ATS would serve.
    complete: bool,
    /// Inconsistencies found on the way, in plain words.
    problems: []const []const u8,
};

/// Finds the fragments of alternate `alt` (ignored for a non-HTTP object).
pub fn chain(arena: std.mem.Allocator, cache: *Cache, head: *const Head, alt: usize) !Chain {
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
    } else if (size != 0) {
        var i: usize = 0;
        while (covered < size) : (i += 1) {
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
    if (covered == size and frags.items.len > 1 and frags.items.len - 1 != frag_offsets.len and alternate != null)
        try problems.append(arena, try std.fmt.allocPrint(arena, "{d} fragments, but the alternate lists {d} fragment offsets", .{ frags.items.len, frag_offsets.len }));

    return .{
        .alternate = alternate,
        .object_size = size,
        .fragments = frags.items,
        .covered = covered,
        .complete = covered == size and problems.items.len == 0,
        .problems = problems.items,
    };
}

/// Writes the body bytes the chain's fragments hold, in order, up to the
/// object size. Returns the number written; less than `object_size` when
/// fragments are missing.
pub fn writeBody(gpa: std.mem.Allocator, cache: *Cache, head: *const Head, c: Chain, w: *Io.Writer) !u64 {
    var written: u64 = 0;
    for (c.fragments) |f| {
        const off = f.offset orelse break;
        const want = @min(f.data_len, c.object_size - written);
        if (f.in_head) {
            const start = head.doc.prefixLen();
            try w.writeAll(head.fragment[start..][0..want]);
        } else {
            const frag = try doc_mod.readFragment(gpa, cache.io, head.stripe.span.file, cache.config.hash_type, off, @min(f.approx_size, max_fragment_len));
            defer gpa.free(frag);
            const d = Doc.decode(cache.config.hash_type, frag);
            if (!d.key.eql(&f.key)) return error.FragmentChanged;
            try w.writeAll(frag[d.prefixLen()..][0..want]);
        }
        written += want;
        if (written == c.object_size) break;
    }
    return written;
}
