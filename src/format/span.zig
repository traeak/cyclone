//! Span header (`DiskHeader` + `DiskStripeBlock[]`), from ATS master
//! src/iocore/cache/P_CacheDisk.h and CacheDisk.cc.
//!
//! A span is a raw device or file. Its `DiskHeader` sits `skip` bytes in
//! (normally `start_pos`, 8 KB) and lists the span's stripe blocks. All
//! fields are little-endian, laid out as GCC lays out the C++ structs on
//! x86-64.

const std = @import("std");

/// `STORE_BLOCK_SIZE`: the unit of span and stripe lengths.
pub const store_block_size = 8192;
/// `START_POS`: the default `skip`, where the `DiskHeader` starts.
pub const start_pos = 8192;
/// `STRIPE_BLOCK_SIZE` / `MIN_STRIPE_SIZE`: stripes are allocated in
/// multiples of 128 MB.
pub const stripe_block_size = 128 * 1024 * 1024;

pub const disk_header_magic: u32 = 0xABCD1237;

/// Size of `DiskHeader` up to `vol_info[]`.
pub const header_fixed_len = 32;
/// `sizeof(DiskStripeBlock)`.
pub const stripe_block_len = 24;

/// `CacheType`. Stored in a 3-bit field.
pub const CacheType = enum(u3) { none = 0, http = 1, rtsp = 2, _ };

/// `DiskHeader` without its `vol_info[]` array.
pub const DiskHeader = struct {
    magic: u32,
    /// Distinct volume numbers used on this span.
    num_volumes: u32,
    /// Stripe blocks that are free.
    num_free: u32,
    /// Stripe blocks in use.
    num_used: u32,
    /// Entries in `vol_info[]`, free and used.
    num_diskvol_blks: u32,
    /// Span length in store blocks, counted from `skip`.
    num_blocks: u64,

    pub fn decode(b: *const [header_fixed_len]u8) DiskHeader {
        return .{
            .magic = u32At(b, 0),
            .num_volumes = u32At(b, 4),
            .num_free = u32At(b, 8),
            .num_used = u32At(b, 12),
            .num_diskvol_blks = u32At(b, 16),
            // 4 bytes of padding at 20
            .num_blocks = u64At(b, 24),
        };
    }

    /// Bytes needed to hold the header and all of its stripe blocks.
    pub fn len(self: DiskHeader) u64 {
        return header_fixed_len + @as(u64, self.num_diskvol_blks) * stripe_block_len;
    }
};

/// `DiskStripeBlock`: one entry of `vol_info[]`.
pub const StripeBlock = struct {
    /// Byte offset of the stripe from the start of the span device.
    offset: u64,
    /// Length in store blocks.
    len: u64,
    /// Volume number (volume.config / volume.yaml).
    number: i32,
    type: CacheType,
    free: bool,

    pub fn decode(b: *const [stripe_block_len]u8) StripeBlock {
        const bits = u32At(b, 20); // type:3, free:1
        return .{
            .offset = u64At(b, 0),
            .len = u64At(b, 8),
            .number = @bitCast(u32At(b, 16)),
            .type = @enumFromInt(@as(u3, @truncate(bits))),
            .free = (bits >> 3) & 1 != 0,
        };
    }

    pub fn byteLen(self: StripeBlock) u64 {
        return self.len * store_block_size;
    }

    pub fn end(self: StripeBlock) u64 {
        return self.offset + self.byteLen();
    }
};

fn u32At(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn u64At(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

/// `skip` as ATS computes it (CacheProcessor.cc): a configured offset, or
/// `start_pos` plus the device alignment, rounded up to a store block.
pub fn defaultSkip(alignment: u64) u64 {
    return std.mem.alignForward(u64, start_pos + alignment, store_block_size);
}

/// The `num_blocks` ATS expects for a span of `size` bytes with `skip`.
pub fn expectedBlocks(size: u64, skip: u64) u64 {
    return size / store_block_size - skip / store_block_size;
}

/// Older ATS (3.2) counted `num_blocks` differently; ATS still accepts
/// headers that differ by exactly this much (CacheDisk::openStart).
pub fn blocksDelta32(skip: u64) u64 {
    return skip - (skip / store_block_size);
}

test "decode header and stripe block" {
    var b: [header_fixed_len + stripe_block_len]u8 = @splat(0);
    std.mem.writeInt(u32, b[0..4], disk_header_magic, .little);
    std.mem.writeInt(u32, b[4..8], 1, .little);
    std.mem.writeInt(u32, b[12..16], 1, .little);
    std.mem.writeInt(u32, b[16..20], 1, .little);
    std.mem.writeInt(u64, b[24..32], 32767, .little);
    const sb = b[header_fixed_len..];
    std.mem.writeInt(u64, sb[0..8], 16384, .little);
    std.mem.writeInt(u64, sb[8..16], 16384, .little);
    std.mem.writeInt(i32, sb[16..20], 2, .little);
    std.mem.writeInt(u32, sb[20..24], 0b0001, .little); // http, not free

    const h = DiskHeader.decode(b[0..header_fixed_len]);
    try std.testing.expectEqual(disk_header_magic, h.magic);
    try std.testing.expectEqual(1, h.num_diskvol_blks);
    try std.testing.expectEqual(32767, h.num_blocks);
    try std.testing.expectEqual(56, h.len());

    const s = StripeBlock.decode(sb[0..stripe_block_len]);
    try std.testing.expectEqual(16384, s.offset);
    try std.testing.expectEqual(128 * 1024 * 1024, s.byteLen());
    try std.testing.expectEqual(2, s.number);
    try std.testing.expectEqual(CacheType.http, s.type);
    try std.testing.expect(!s.free);

    std.mem.writeInt(u32, sb[20..24], 0b1000, .little);
    const f = StripeBlock.decode(sb[0..stripe_block_len]);
    try std.testing.expect(f.free);
    try std.testing.expectEqual(CacheType.none, f.type);
}

test "skip and block math" {
    try std.testing.expectEqual(8192, defaultSkip(0));
    try std.testing.expectEqual(16384, defaultSkip(4096));
    try std.testing.expectEqual(32767, expectedBlocks(256 * 1024 * 1024, 8192));
    try std.testing.expectEqual(8191, blocksDelta32(8192));
}
