//! Reading a stripe's directory one segment at a time.
//!
//! A segment is at most 16384 buckets × 4 entries × 10 bytes = 640 KB, so a
//! lookup reads one segment and a full scan streams them, whatever the
//! stripe size.

const std = @import("std");
const Io = std.Io;
const fmt = @import("format/dir.zig");
const Stripe = @import("stripe.zig").Stripe;

pub const Dir = fmt.Dir;
pub const Slot = fmt.Slot;

/// Absolute byte offset in the span of the fragment an entry points at
/// (`Stripe::vol_offset`).
pub fn contentOffset(stripe: *const Stripe, d: Dir) u64 {
    return stripe.geometry.start + (d.offset() - 1) * fmt.cache_block_size;
}

/// Whether ATS would trust this entry (`Stripe::dir_valid`, with an empty
/// write buffer since ATS is not running). An entry in the current phase
/// must be behind `write_pos`. An entry from the previous phase must be
/// ahead of `agg_pos`, where the cyclone buffer has not overwritten it yet.
pub fn entryValid(stripe: *const Stripe, d: Dir) bool {
    const h = stripe.header() orelse return false;
    if (d.isEmpty()) return false;
    const start: i64 = @intCast(stripe.geometry.start);
    const block: i64 = @intCast(d.offset() - 1);
    if (d.phase() == h.phase) return block < @divFloor(h.write_pos - start, fmt.cache_block_size);
    return block >= @divFloor(h.agg_pos - start, fmt.cache_block_size);
}

pub const Link = struct {
    /// Entry index within the segment.
    index: u16,
    dir: Dir,
};

/// Why a chain walk stopped early.
pub const ChainError = enum {
    /// A `next` index past the end of the segment.
    bad_next,
    /// The chain came back to an entry it had already visited.
    loop,
};

/// One segment of the chosen directory copy, in memory.
pub const Segment = struct {
    index: u64,
    buckets: u64,
    /// Head of this segment's free list, from the stripe header.
    freelist_head: u16,
    raw: []u8,

    pub fn read(gpa: std.mem.Allocator, io: Io, stripe: *const Stripe, s: u64) !Segment {
        const copy = stripe.chosen orelse return error.NoUsableDirectory;
        const g = stripe.geometry;
        if (s >= g.segments) return error.NoSuchSegment;
        const len = g.buckets * fmt.depth * fmt.entry_len;
        const raw = try gpa.alloc(u8, len);
        errdefer gpa.free(raw);
        const off = g.entriesOffset(copy) + s * len;
        if (try stripe.span.file.readPositionalAll(io, raw, off) != len) return error.Truncated;
        return .{ .index = s, .buckets = g.buckets, .freelist_head = stripe.freelist[s], .raw = raw };
    }

    /// Bytes `get` needs in `buf` for a segment of this stripe.
    pub fn byteLen(stripe: *const Stripe) usize {
        return @intCast(stripe.geometry.buckets * fmt.depth * fmt.entry_len);
    }

    /// Segment `s` without allocating: a view of the directory in memory
    /// when the stripe has it loaded, else read into `buf` (at least
    /// `byteLen(stripe)` bytes, reused from one segment to the next). Not to be
    /// passed to `deinit`.
    pub fn get(io: Io, stripe: *const Stripe, s: u64, buf: []u8) !Segment {
        const copy = stripe.chosen orelse return error.NoUsableDirectory;
        const g = stripe.geometry;
        if (s >= g.segments) return error.NoSuchSegment;
        const n = byteLen(stripe);
        const raw = if (stripe.entries) |mem| mem[@intCast(s * n)..][0..n] else blk: {
            const b = buf[0..n];
            if (try stripe.span.file.readPositionalAll(io, b, g.entriesOffset(copy) + s * n) != n) return error.Truncated;
            break :blk b;
        };
        return .{ .index = s, .buckets = g.buckets, .freelist_head = stripe.freelist[s], .raw = raw };
    }

    pub fn deinit(self: *Segment, gpa: std.mem.Allocator) void {
        gpa.free(self.raw);
        self.* = undefined;
    }

    pub fn entryCount(self: *const Segment) u64 {
        return self.buckets * fmt.depth;
    }

    pub fn entry(self: *const Segment, i: u64) Dir {
        return Dir.decode(self.raw[i * fmt.entry_len ..][0..fmt.entry_len]);
    }

    /// The entries of bucket `b`, head first. Yields nothing for an empty
    /// bucket. Like `Directory::probe`, entries after the head are followed
    /// whatever their contents.
    pub fn chain(self: *const Segment, b: u64) ChainIterator {
        const head: u16 = @intCast(b * fmt.depth);
        return .{ .seg = self, .next_index = if (self.entry(head).isEmpty()) null else head };
    }

    /// The free list: entries ATS can hand out for new chain links.
    pub fn freeList(self: *const Segment) ChainIterator {
        return .{ .seg = self, .next_index = if (self.freelist_head == 0) null else self.freelist_head };
    }
};

pub const ChainIterator = struct {
    seg: *const Segment,
    next_index: ?u64,
    steps: u64 = 0,
    err: ?ChainError = null,

    pub fn next(it: *ChainIterator) ?Link {
        const i = it.next_index orelse return null;
        if (i >= it.seg.entryCount()) {
            it.err = .bad_next;
            it.next_index = null;
            return null;
        }
        // A chain can hold at most every entry once; past that it loops.
        it.steps += 1;
        if (it.steps > it.seg.entryCount()) {
            it.err = .loop;
            it.next_index = null;
            return null;
        }
        const d = it.seg.entry(i);
        it.next_index = if (d.next() == 0) null else d.next();
        return .{ .index = @intCast(i), .dir = d };
    }
};

/// One bucket's chain, an entry at a time: from the stripe's directory in
/// memory when it is loaded (`Stripe.loadDirectory`), else from the span,
/// where a lookup visits a few entries instead of `Segment.read`'s 640 KB.
pub const BucketChain = struct {
    io: Io,
    stripe: *const Stripe,
    /// Byte offset of the segment's first entry.
    base: u64,
    entries: u64,
    next_index: ?u64,
    steps: u64 = 0,
    err: ?ChainError = null,

    pub fn init(io: Io, stripe: *const Stripe, segment: u64, bucket: u64) !BucketChain {
        const copy = stripe.chosen orelse return error.NoUsableDirectory;
        const g = stripe.geometry;
        if (segment >= g.segments or bucket >= g.buckets) return error.NoSuchBucket;
        const entries = g.buckets * fmt.depth;
        var it: BucketChain = .{
            .io = io,
            .stripe = stripe,
            .base = g.entriesOffset(copy) + segment * entries * fmt.entry_len,
            .entries = entries,
            .next_index = bucket * fmt.depth,
        };
        // An empty head means an empty bucket, as for `Segment.chain`.
        const head = try it.read(bucket * fmt.depth);
        if (head.isEmpty()) it.next_index = null;
        return it;
    }

    fn read(it: *const BucketChain, i: u64) !Dir {
        const at = it.base + i * fmt.entry_len;
        if (it.stripe.entries) |mem| {
            const rel = at - it.stripe.geometry.entriesOffset(it.stripe.chosen.?);
            return Dir.decode(mem[@intCast(rel)..][0..fmt.entry_len]);
        }
        var b: [fmt.entry_len]u8 = undefined;
        if (try it.stripe.span.file.readPositionalAll(it.io, &b, at) != b.len) return error.Truncated;
        return Dir.decode(&b);
    }

    pub fn next(it: *BucketChain) !?Link {
        const i = it.next_index orelse return null;
        if (i >= it.entries) {
            it.err = .bad_next;
            it.next_index = null;
            return null;
        }
        it.steps += 1;
        if (it.steps > it.entries) {
            it.err = .loop;
            it.next_index = null;
            return null;
        }
        const d = try it.read(i);
        it.next_index = if (d.next() == 0) null else d.next();
        return .{ .index = @intCast(i), .dir = d };
    }
};

/// Counts for one segment, or summed over a stripe.
pub const Stats = struct {
    entries: u64 = 0,
    buckets: u64 = 0,
    buckets_used: u64 = 0,
    /// Entries reachable from bucket heads.
    entries_used: u64 = 0,
    /// Of those, the ones ATS would trust (`entryValid`).
    entries_valid: u64 = 0,
    /// Valid entries with the head flag: one per cached object's vector Doc.
    heads: u64 = 0,
    pinned: u64 = 0,
    /// Sum of approximate sizes of valid entries.
    approx_bytes: u64 = 0,
    free: u64 = 0,
    /// Entries neither in use, nor free, nor an empty bucket head.
    unaccounted: u64 = 0,
    /// Chain lengths 1, 2, 3, 4, and 5 or more.
    chain_lengths: [5]u64 = @splat(0),
    max_chain: u64 = 0,
    // Problems.
    bad_next: u64 = 0,
    loops: u64 = 0,
    /// Entries reached from more than one chain, or both chained and free.
    shared: u64 = 0,
    /// Empty bucket heads whose `next` is set (`Directory::check_segment`).
    empty_head_with_next: u64 = 0,
    /// Chained entries after the head with offset 0.
    empty_in_chain: u64 = 0,

    pub fn add(self: *Stats, o: Stats) void {
        inline for (@typeInfo(Stats).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "max_chain")) {
                self.max_chain = @max(self.max_chain, o.max_chain);
            } else if (@TypeOf(@field(self, name)) == u64) {
                @field(self, name) += @field(o, name);
            } else {
                for (&@field(self, name), @field(o, name)) |*a, b| a.* += b;
            }
        }
    }

    pub fn problems(self: Stats) u64 {
        return self.bad_next + self.loops + self.shared + self.empty_head_with_next + self.empty_in_chain;
    }
};

/// Walks every chain and the free list of a segment.
pub fn segmentStats(gpa: std.mem.Allocator, stripe: *const Stripe, seg: *const Segment) !Stats {
    var st: Stats = .{ .entries = seg.entryCount(), .buckets = seg.buckets };
    var seen = try std.DynamicBitSet.initEmpty(gpa, seg.entryCount());
    defer seen.deinit();
    var empty_heads: u64 = 0;

    for (0..seg.buckets) |b| {
        const head = seg.entry(b * fmt.depth);
        if (head.isEmpty()) {
            empty_heads += 1;
            if (head.next() != 0) st.empty_head_with_next += 1;
            continue;
        }
        st.buckets_used += 1;
        var len: u64 = 0;
        var it = seg.chain(b);
        while (it.next()) |link| {
            len += 1;
            if (seen.isSet(link.index)) {
                st.shared += 1;
                break;
            }
            seen.set(link.index);
            if (len > 1 and link.dir.isEmpty()) st.empty_in_chain += 1;
            if (link.dir.isEmpty()) continue;
            st.entries_used += 1;
            if (entryValid(stripe, link.dir)) {
                st.entries_valid += 1;
                st.approx_bytes += link.dir.approxSize();
                if (link.dir.head()) st.heads += 1;
                if (link.dir.pinned()) st.pinned += 1;
            }
        }
        if (it.err) |e| switch (e) {
            .bad_next => st.bad_next += 1,
            .loop => st.loops += 1,
        };
        st.chain_lengths[@min(len, 5) - 1] += 1;
        st.max_chain = @max(st.max_chain, len);
    }

    var it = seg.freeList();
    while (it.next()) |link| {
        if (seen.isSet(link.index)) {
            st.shared += 1;
            break;
        }
        seen.set(link.index);
        st.free += 1;
    }
    if (it.err) |e| switch (e) {
        .bad_next => st.bad_next += 1,
        .loop => st.loops += 1,
    };

    st.unaccounted = st.entries -| (st.entries_used + st.free + empty_heads);
    return st;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const stripe_fmt = @import("format/stripe.zig");

/// A stripe value good enough for `entryValid`: content starts at 1 MB,
/// phase 0, written up to 2 MB.
fn testStripe() Stripe {
    var h = std.mem.zeroes(stripe_fmt.HeaderFooter);
    h.magic = stripe_fmt.stripe_magic;
    h.write_pos = 2 * 1024 * 1024;
    h.agg_pos = h.write_pos;
    return .{
        .span = undefined,
        .block_index = 0,
        .block = undefined,
        .avg_obj_size = stripe_fmt.default_avg_obj_size,
        .geometry = .{ .skip = 0, .len = 64 * 1024 * 1024, .segments = 1, .buckets = 4, .start = 1024 * 1024 },
        .copies = .{ .{ .header = h, .footer = h }, .{ .header = h, .footer = h } },
        .chosen = .a,
        .freelist = &.{},
    };
}

fn putEntry(raw: []u8, i: usize, offset: u64, next: u16, head: bool) void {
    const w = [5]u16{
        @truncate(offset),
        @as(u16, @truncate(offset >> 16)) & 0xff,
        if (head) 1 << 13 else 0,
        next,
        @truncate(offset >> 24),
    };
    for (w, 0..) |v, j| std.mem.writeInt(u16, raw[i * fmt.entry_len + j * 2 ..][0..2], v, .little);
}

test "chains, free list and stats" {
    var raw: [4 * fmt.depth * fmt.entry_len]u8 = @splat(0);
    // bucket 0: 0 -> 5 -> 9 ; bucket 1: 4 ; buckets 2, 3 empty
    putEntry(&raw, 0, 1, 5, true);
    putEntry(&raw, 5, 3, 9, false);
    putEntry(&raw, 9, 5, 0, false);
    putEntry(&raw, 4, 4096, 0, true); // past write_pos: stale
    // free list: 1 -> 2 -> 3 -> 6 -> 7 -> 10 -> 11 -> 13 -> 14 -> 15
    const free = [_]u16{ 1, 2, 3, 6, 7, 10, 11, 13, 14, 15 };
    for (free, 0..) |e, k| putEntry(&raw, e, 0, if (k + 1 < free.len) free[k + 1] else 0, false);

    const stripe = testStripe();
    const seg: Segment = .{ .index = 0, .buckets = 4, .freelist_head = 1, .raw = &raw };

    var it = seg.chain(0);
    var got: [3]u16 = undefined;
    var n: usize = 0;
    while (it.next()) |link| : (n += 1) got[n] = link.index;
    try testing.expectEqual(3, n);
    try testing.expectEqualSlices(u16, &.{ 0, 5, 9 }, &got);
    try testing.expectEqual(null, it.err);
    try testing.expectEqual(null, seg.chain(2).next_index);

    const st = try segmentStats(testing.allocator, &stripe, &seg);
    try testing.expectEqual(4, st.entries_used);
    try testing.expectEqual(3, st.entries_valid);
    try testing.expectEqual(1, st.heads);
    try testing.expectEqual(10, st.free);
    try testing.expectEqual(0, st.unaccounted);
    try testing.expectEqual(1, st.chain_lengths[0]);
    try testing.expectEqual(1, st.chain_lengths[2]);
    try testing.expectEqual(0, st.problems());
    try testing.expectEqual(1 * 512 + 1 * 512 + 1 * 512, st.approx_bytes);
}

test "bucket chains walk the directory in memory as on disk" {
    var raw: [4 * fmt.depth * fmt.entry_len]u8 = @splat(0);
    putEntry(&raw, 0, 1, 5, true);
    putEntry(&raw, 5, 3, 9, false);
    putEntry(&raw, 9, 5, 0, false);
    var stripe = testStripe();
    stripe.entries = &raw;
    const seg: Segment = .{ .index = 0, .buckets = 4, .freelist_head = 0, .raw = &raw };

    // `span` is never touched: every entry comes from memory.
    var chain = try BucketChain.init(undefined, &stripe, 0, 0);
    var want = seg.chain(0);
    while (want.next()) |w| {
        const got = (try chain.next()).?;
        try testing.expectEqual(w.index, got.index);
        try testing.expectEqual(w.dir.offset(), got.dir.offset());
    }
    try testing.expectEqual(null, try chain.next());
    var empty = try BucketChain.init(undefined, &stripe, 0, 2);
    try testing.expectEqual(null, try empty.next());
}

test "broken chains are reported, not followed forever" {
    var raw: [4 * fmt.depth * fmt.entry_len]u8 = @splat(0);
    putEntry(&raw, 0, 1, 5, true);
    putEntry(&raw, 5, 2, 0, false); // ends: fine
    putEntry(&raw, 4, 3, 6, true);
    putEntry(&raw, 6, 4, 4, false); // back to 4: loop
    putEntry(&raw, 8, 5, 999, true); // past the segment
    putEntry(&raw, 12, 6, 5, true); // reaches 5, already in bucket 0's chain

    const stripe = testStripe();
    const seg: Segment = .{ .index = 0, .buckets = 4, .freelist_head = 0, .raw = &raw };
    const st = try segmentStats(testing.allocator, &stripe, &seg);
    try testing.expectEqual(1, st.bad_next);
    try testing.expectEqual(2, st.shared); // the loop revisits 4; bucket 3 reaches 5
    try testing.expect(st.problems() >= 3);

    var it = seg.chain(1);
    while (it.next()) |_| {}
    try testing.expectEqual(ChainError.loop, it.err.?);
}
