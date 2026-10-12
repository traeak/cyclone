//! Key → stripe assignment, ported from ATS master `build_vol_hash_table`
//! (src/iocore/cache/CacheProcessor.cc) and `Cache::key_to_stripe`.
//!
//! ATS spreads keys over a host record's stripes with a 32707-slot table.
//! Each stripe gets one random point per 8 MB of its length, from an LCG
//! seeded with the stripe's hash id (MD5 of its hash text). Each slot goes
//! to the stripe owning the first point at or past the slot's centre. A key
//! uses slot `(slice32(2) >> 12) % 32707`.

const std = @import("std");
const Io = std.Io;
const hash = @import("hash.zig");
const CacheKey = @import("key.zig").CacheKey;
const Span = @import("span.zig").Span;

/// `STRIPE_HASH_TABLE_SIZE`.
pub const table_size = 32707;
/// `STRIPE_HASH_ALLOC_SIZE`: one random point per this many bytes.
pub const alloc_size = 8 * 1024 * 1024;
/// `DIR_TAG_WIDTH`: the low key bits that pick the tag, skipped here.
const tag_width = 12;

/// One stripe as the table sees it.
pub const StripeRef = struct {
    span_index: usize,
    block_index: usize,
    volume: i32,
    /// Stripe length in bytes.
    len: u64,
    /// MD5 (or SHA-256) of the stripe's hash text.
    hash_id: CacheKey,
};

/// The stripes of a host record, in ATS's order: volumes in the order given
/// (default: the order `cplist_init` discovers them, first appearance
/// across spans and their headers), and within a volume, spans in order and
/// that span's blocks in header order (`Cache::open`).
pub fn collectStripes(gpa: std.mem.Allocator, spans: []const Span, volumes: ?[]const i32, hash_type: hash.HashType) ![]StripeRef {
    var order: std.ArrayList(i32) = .empty;
    defer order.deinit(gpa);
    if (volumes) |v| {
        try order.appendSlice(gpa, v);
    } else {
        for (spans) |*s| {
            var it = s.usedBlocks();
            while (it.next()) |b| {
                if (std.mem.indexOfScalar(i32, order.items, b.number) == null) try order.append(gpa, b.number);
            }
        }
    }

    var refs: std.ArrayList(StripeRef) = .empty;
    errdefer refs.deinit(gpa);
    var text_buf: [4096]u8 = undefined;
    for (order.items) |vol| {
        for (spans, 0..) |*s, si| {
            for (s.blocks, 0..) |b, bi| {
                if (b.free or b.number != vol) continue;
                var w: Io.Writer = .fixed(&text_buf);
                s.stripeHashText(&w, b) catch return error.HashTextTooLong;
                try refs.append(gpa, .{
                    .span_index = si,
                    .block_index = bi,
                    .volume = vol,
                    .len = b.byteLen(),
                    .hash_id = hashText(hash_type, w.buffered()),
                });
            }
        }
    }
    return refs.toOwnedSlice(gpa);
}

/// `CryptoContext().hash_immediate(hash_id, hash_text, strlen(hash_text))`.
pub fn hashText(hash_type: hash.HashType, text: []const u8) CacheKey {
    var k: CacheKey = .{ .hash_type = hash_type };
    switch (hash_type) {
        .md5 => std.crypto.hash.Md5.hash(text, k.bytes[0..16], .{}),
        .sha256 => std.crypto.hash.sha2.Sha256.hash(text, k.bytes[0..32], .{}),
    }
    return k;
}

/// `CryptoHash::fold`: XOR of its 64-bit words.
fn fold(k: CacheKey) u64 {
    var x: u64 = 0;
    var i: usize = 0;
    while (i < k.hash_type.keyLen()) : (i += 8) x ^= std.mem.readInt(u64, k.bytes[i..][0..8], .little);
    return x;
}

/// `next_rand`: the LCG ATS uses for the random points.
fn nextRand(state: *u32) u32 {
    state.* = state.* *% 1103515145 +% 12345;
    return state.*;
}

pub const Table = struct {
    stripes: []const StripeRef,
    /// Slot → index into `stripes`.
    slots: []u16,
    /// Slots each stripe would get in proportion to its size (`forvol`).
    requested: []u32,
    /// Slots each stripe got (`gotvol`).
    got: []u32,

    /// Port of `build_vol_hash_table`. `stripes` must outlive the table.
    pub fn build(gpa: std.mem.Allocator, stripes: []const StripeRef) !Table {
        if (stripes.len == 0) return error.NoStripes;
        if (stripes.len > std.math.maxInt(u16)) return error.TooManyStripes;

        var total: u64 = 0;
        for (stripes) |s| total += s.len / 8192;
        if (total == 0) return error.NoStripes;

        const requested = try gpa.alloc(u32, stripes.len);
        errdefer gpa.free(requested);
        const got = try gpa.alloc(u32, stripes.len);
        errdefer gpa.free(got);
        @memset(got, 0);

        var used: u64 = 0;
        var points_len: usize = 0;
        for (stripes, requested) |s, *r| {
            r.* = @intCast(table_size * (s.len / 8192) / total);
            used += r.*;
            points_len += @intCast(s.len / alloc_size);
        }
        // Spread the rounding remainder (as ATS does; affects only `requested`).
        const extra = table_size - used;
        for (0..extra) |i| requested[i % stripes.len] += 1;

        const Point = struct { rval: u32, idx: u16 };
        const points = try gpa.alloc(Point, points_len);
        defer gpa.free(points);
        var n: usize = 0;
        for (stripes, 0..) |s, i| {
            var rnd: u32 = @truncate(fold(s.hash_id));
            for (0..s.len / alloc_size) |_| {
                points[n] = .{ .rval = nextRand(&rnd), .idx = @intCast(i) };
                n += 1;
            }
        }
        if (points.len == 0) return error.StripesTooSmall;
        // ATS uses qsort, which is not guaranteed stable; equal 32-bit
        // values from different stripes are vanishingly rare.
        std.sort.block(Point, points, {}, struct {
            fn lt(_: void, a: Point, b: Point) bool {
                return a.rval < b.rval;
            }
        }.lt);

        const slots = try gpa.alloc(u16, table_size);
        errdefer gpa.free(slots);
        const width: u32 = @intCast((@as(u64, 1) << 32) / table_size);
        var i: usize = 0;
        for (slots, 0..) |*slot, j| {
            const pos: u32 = width / 2 + @as(u32, @intCast(j)) * width;
            while (pos > points[i].rval and i < points.len - 1) i += 1;
            slot.* = points[i].idx;
            got[points[i].idx] += 1;
        }
        return .{ .stripes = stripes, .slots = slots, .requested = requested, .got = got };
    }

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        gpa.free(self.slots);
        gpa.free(self.requested);
        gpa.free(self.got);
        self.* = undefined;
    }

    /// The slot a key uses (`Cache::key_to_stripe`).
    pub fn slotOf(key: *const CacheKey) u32 {
        return (key.slice32(2) >> tag_width) % table_size;
    }

    /// The stripe a key is stored in.
    pub fn stripeFor(self: *const Table, key: *const CacheKey) *const StripeRef {
        return &self.stripes[self.slots[slotOf(key)]];
    }
};

test "nextRand matches ATS next_rand" {
    var s: u32 = 1;
    try std.testing.expectEqual(@as(u32, 1103515145 +% 12345), nextRand(&s));
    try std.testing.expectEqual(@as(u32, @truncate(@as(u64, 1103515145) * (1103515145 + 12345) + 12345)), nextRand(&s));
}

test "table fills every slot in proportion to size" {
    const gpa = std.testing.allocator;
    const refs = [_]StripeRef{
        .{ .span_index = 0, .block_index = 0, .volume = 1, .len = 1 << 30, .hash_id = hashText(.md5, "/a 16384:131072") },
        .{ .span_index = 0, .block_index = 1, .volume = 1, .len = 3 << 30, .hash_id = hashText(.md5, "/a 1073758208:393216") },
    };
    var t = try Table.build(gpa, &refs);
    defer t.deinit(gpa);
    try std.testing.expectEqual(table_size, t.got[0] + t.got[1]);
    try std.testing.expectEqual(table_size, t.requested[0] + t.requested[1]);
    // Roughly 1:3, give or take the randomness.
    try std.testing.expect(t.got[1] > 2 * t.got[0]);
}
