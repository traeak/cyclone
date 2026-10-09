//! Directory entries (`Dir`), from ATS master src/iocore/cache/P_CacheDir.h.
//!
//! An entry is five little-endian u16 words. ATS reads them only through
//! the `dir_*` macros, so the bit layout below is the layout on disk:
//!
//!   w[0]           offset bits 0-15
//!   w[1] bits 0-7  offset bits 16-23
//!   w[1] bits 8-9  big    (size unit: 512 << 3*big)
//!   w[1] bits 10-15 size  (approximate size = (size+1) units)
//!   w[2] bits 0-11 tag    (12 bits of the key)
//!   w[2] bit 12    phase
//!   w[2] bit 13    head   (first fragment of an object: the vector Doc)
//!   w[2] bit 14    pinned
//!   w[3]           next   (index of the next entry in the segment; 0 = end)
//!   w[4]           offset bits 24-39
//!
//! A free entry reuses w[2] as `prev`, its back link in the free list.

const std = @import("std");
const CacheKey = @import("../key.zig").CacheKey;

pub const entry_len = 10;
/// `DIR_DEPTH`: entries per bucket. Row 0 is the bucket's chain head; rows
/// 1-3 hold overflow entries for any bucket in the segment, or are free.
pub const depth = 4;
pub const tag_bits = 12;
/// `CACHE_BLOCK_SIZE`: the unit of `offset`.
pub const cache_block_size = 512;

pub const Dir = struct {
    w: [5]u16,

    pub fn decode(b: *const [entry_len]u8) Dir {
        var d: Dir = undefined;
        for (&d.w, 0..) |*w, i| w.* = std.mem.readInt(u16, b[i * 2 ..][0..2], .little);
        return d;
    }

    /// Position in the content area, in 512-byte blocks, plus one. 0 means
    /// the entry is empty.
    pub fn offset(d: Dir) u64 {
        return @as(u64, d.w[0]) | (@as(u64, d.w[1] & 0xff) << 16) | (@as(u64, d.w[4]) << 24);
    }

    pub fn isEmpty(d: Dir) bool {
        return d.offset() == 0;
    }

    pub fn big(d: Dir) u2 {
        return @truncate(d.w[1] >> 8);
    }

    pub fn size(d: Dir) u6 {
        return @truncate(d.w[1] >> 10);
    }

    /// `dir_approx_size`: an upper bound on the fragment's length in bytes,
    /// rounded up to 512 << 3*big.
    pub fn approxSize(d: Dir) u64 {
        return (@as(u64, d.size()) + 1) * (@as(u64, cache_block_size) << (3 * @as(u6, d.big())));
    }

    pub fn tag(d: Dir) u12 {
        return @truncate(d.w[2]);
    }

    pub fn phase(d: Dir) u1 {
        return @truncate(d.w[2] >> 12);
    }

    pub fn head(d: Dir) bool {
        return (d.w[2] >> 13) & 1 != 0;
    }

    pub fn pinned(d: Dir) bool {
        return (d.w[2] >> 14) & 1 != 0;
    }

    pub fn next(d: Dir) u16 {
        return d.w[3];
    }

    /// Back link, meaningful only for entries on the free list.
    pub fn prev(d: Dir) u16 {
        return d.w[2];
    }
};

/// Where a key lives in a directory (`Directory::probe`).
pub const Slot = struct {
    segment: u64,
    bucket: u64,
    tag: u12,

    pub fn of(key: *const CacheKey, segments: u64, buckets: u64) Slot {
        return .{
            .segment = key.slice32(0) % segments,
            .bucket = key.slice32(1) % buckets,
            .tag = @truncate(key.slice32(2)),
        };
    }
};

test "decode entry bits" {
    // offset 0x12_3456_789A, big 2, size 5, tag 0xABC, phase 1, head 1,
    // pinned 0, next 77.
    var b: [entry_len]u8 = undefined;
    const w = [5]u16{ 0x789A, 0x56 | (2 << 8) | (5 << 10), 0xABC | (1 << 12) | (1 << 13), 77, 0x1234 };
    for (w, 0..) |v, i| std.mem.writeInt(u16, b[i * 2 ..][0..2], v, .little);
    const d = Dir.decode(&b);
    try std.testing.expectEqual(0x12_3456_789A, d.offset());
    try std.testing.expectEqual(2, d.big());
    try std.testing.expectEqual(5, d.size());
    try std.testing.expectEqual(6 * (512 << 6), d.approxSize());
    try std.testing.expectEqual(0xABC, d.tag());
    try std.testing.expectEqual(1, d.phase());
    try std.testing.expect(d.head());
    try std.testing.expect(!d.pinned());
    try std.testing.expectEqual(77, d.next());
    try std.testing.expect(!d.isEmpty());
}

test "slot from key slices" {
    const k = try CacheKey.parseHex(.md5, "0a000000" ++ "07000000" ++ "cdab0000" ++ "00000000");
    const s = Slot.of(&k, 3, 5);
    try std.testing.expectEqual(10 % 3, s.segment);
    try std.testing.expectEqual(7 % 5, s.bucket);
    try std.testing.expectEqual(0xbcd, s.tag);
}
