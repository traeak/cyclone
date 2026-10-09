//! Stripe header/footer and directory geometry, from ATS master
//! src/iocore/cache/Stripe.{h,cc}, StripeSM.cc and P_CacheDir.h.
//!
//! A stripe holds two copies of its directory, A then B, followed by the
//! content area (the cyclone buffer). Each copy is:
//!
//!   header  StripeHeaderFooter + freelist[segments]   rounded to 8 KB
//!   entries segments * buckets * 4 Dir entries        rounded to 8 KB
//!   footer  StripeHeaderFooter                         rounded to 8 KB

const std = @import("std");
const span = @import("span.zig");

pub const stripe_magic: u32 = 0xF1D0F00D;

/// `CACHE_DB_MAJOR_VERSION` / `CACHE_DB_MINOR_VERSION` of ATS master.
pub const db_version: Version = .{ .major = 24, .minor = 3 };
/// `CACHE_DB_MAJOR_VERSION_COMPATIBLE`: oldest major version master reads.
pub const db_major_compatible = 21;

/// `DIR_DEPTH`: entries per bucket.
pub const dir_depth = 4;
/// `SIZEOF_DIR`.
pub const dir_entry_len = 10;
/// Most buckets in one segment; `Dir.next` is a u16 entry index.
pub const max_segment_buckets = (1 << 16) / dir_depth;
/// `proxy.config.cache.min_average_object_size` default.
pub const default_avg_obj_size = 8000;

/// `sizeof(StripeHeaderFooter)` with its one-element `freelist[]`.
pub const header_footer_len = 80;
/// Offset of `freelist[]` within the header.
pub const freelist_offset = 72;

pub const Version = struct {
    major: u16,
    minor: u16,

    pub fn format(v: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}", .{ v.major, v.minor });
    }
};

/// `StripeHeaderFooter`, without `freelist[]`.
pub const HeaderFooter = struct {
    magic: u32,
    version: Version,
    create_time: i64,
    /// Next write position: byte offset in the span.
    write_pos: i64,
    last_write_pos: i64,
    agg_pos: i64,
    /// "Token generation (vary)" per the ATS comment, but ATS master never
    /// sets it; it is 0 in practice.
    generation: u32,
    /// Flips each time `write_pos` wraps around the content area.
    phase: u32,
    /// Number of wraps.
    cycle: u32,
    sync_serial: u32,
    write_serial: u32,
    /// Set when the in-memory directory changes. The periodic sync clears
    /// it before writing, but the shutdown sync writes it set.
    dirty: u32,
    sector_size: u32,

    pub fn decode(b: *const [header_footer_len]u8) HeaderFooter {
        return .{
            .magic = int(u32, b, 0),
            .version = .{ .major = int(u16, b, 4), .minor = int(u16, b, 6) },
            .create_time = int(i64, b, 8),
            .write_pos = int(i64, b, 16),
            .last_write_pos = int(i64, b, 24),
            .agg_pos = int(i64, b, 32),
            .generation = int(u32, b, 40),
            .phase = int(u32, b, 44),
            .cycle = int(u32, b, 48),
            .sync_serial = int(u32, b, 52),
            .write_serial = int(u32, b, 56),
            .dirty = int(u32, b, 60),
            .sector_size = int(u32, b, 64),
            // unused u32 at 68, freelist[0] at 72
        };
    }

    /// The check ATS makes before using a directory (`handle_dir_read`).
    pub fn usable(self: HeaderFooter) bool {
        return self.magic == stripe_magic and
            self.version.major >= db_major_compatible and
            self.version.major <= db_version.major;
    }
};

fn int(comptime T: type, b: []const u8, off: usize) T {
    return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
}

pub const Copy = enum { a, b };

/// Which directory copy ATS uses, from the sync serials of the four
/// header/footer blocks (`StripeSM::handle_header_read`). A copy is whole
/// when its header and footer serials agree; A wins ties. Null means ATS
/// would clear the stripe.
pub fn chooseCopy(a_header: u32, a_footer: u32, b_header: u32, b_footer: u32) ?Copy {
    if (a_header == a_footer and (a_header >= b_header or b_header != b_footer)) return .a;
    if (b_header == b_footer) return .b;
    return null;
}

/// Directory and content-area layout of one stripe.
pub const Geometry = struct {
    /// Stripe start (byte offset in the span); where copy A begins.
    skip: u64,
    /// Stripe length in bytes.
    len: u64,
    segments: u64,
    buckets: u64,
    /// Content area start: `skip + 2 * dirLen()`.
    start: u64,

    /// Port of `Stripe::_init_data`: three passes, each sizing the
    /// directory from the space the previous pass left for content.
    pub fn compute(skip: u64, len: u64, avg_obj_size: u32) Geometry {
        var g: Geometry = .{ .skip = skip, .len = len, .segments = 0, .buckets = 0, .start = skip };
        for (0..3) |_| {
            const total_entries = (len - (g.start - skip)) / avg_obj_size;
            const total_buckets = total_entries / dir_depth;
            g.segments = (total_buckets + max_segment_buckets - 1) / max_segment_buckets;
            g.buckets = (total_buckets + g.segments - 1) / g.segments;
            g.start = skip + 2 * g.dirLen();
        }
        return g;
    }

    /// `Stripe::headerlen`.
    pub fn headerLen(g: Geometry) u64 {
        return roundStore(header_footer_len + 2 * (g.segments - 1));
    }

    pub fn entriesLen(g: Geometry) u64 {
        return roundStore(g.entryCount() * dir_entry_len);
    }

    pub fn footerLen(_: Geometry) u64 {
        return roundStore(header_footer_len);
    }

    /// `Stripe::dirlen`: one directory copy.
    pub fn dirLen(g: Geometry) u64 {
        return g.headerLen() + g.entriesLen() + g.footerLen();
    }

    pub fn entryCount(g: Geometry) u64 {
        return g.segments * g.buckets * dir_depth;
    }

    /// Byte offset in the span of a copy's header.
    pub fn copyOffset(g: Geometry, copy: Copy) u64 {
        return switch (copy) {
            .a => g.skip,
            .b => g.skip + g.dirLen(),
        };
    }

    pub fn footerOffset(g: Geometry, copy: Copy) u64 {
        return g.copyOffset(copy) + g.dirLen() - g.footerLen();
    }

    pub fn entriesOffset(g: Geometry, copy: Copy) u64 {
        return g.copyOffset(copy) + g.headerLen();
    }

    /// Bytes of content area (`data_blocks` × 8 KB).
    pub fn dataLen(g: Geometry) u64 {
        return (g.len - (g.start - g.skip)) / span.store_block_size * span.store_block_size;
    }
};

fn roundStore(n: u64) u64 {
    return std.mem.alignForward(u64, n, span.store_block_size);
}

test "geometry matches ATS for a 128 MB stripe" {
    // ATS logged "allocating 188416 directory bytes for a 134217728 byte
    // volume" for this stripe in the fixture.
    const g = Geometry.compute(16384, 128 * 1024 * 1024, default_avg_obj_size);
    try std.testing.expectEqual(1, g.segments);
    try std.testing.expectEqual(4182, g.buckets);
    try std.testing.expectEqual(188416, g.dirLen());
    try std.testing.expectEqual(16384 + 2 * 188416, g.start);
}

test "geometry splits large stripes into segments" {
    const g = Geometry.compute(16384, 1 << 40, default_avg_obj_size); // 1 TB
    try std.testing.expect(g.segments > 1);
    try std.testing.expect(g.buckets <= max_segment_buckets);
    try std.testing.expectEqual(roundStore(header_footer_len + 2 * (g.segments - 1)), g.headerLen());
}

test chooseCopy {
    try std.testing.expectEqual(Copy.a, chooseCopy(5, 5, 4, 4).?);
    try std.testing.expectEqual(Copy.a, chooseCopy(5, 5, 5, 5).?);
    try std.testing.expectEqual(Copy.b, chooseCopy(4, 4, 5, 5).?);
    try std.testing.expectEqual(Copy.a, chooseCopy(4, 4, 6, 5).?); // B torn
    try std.testing.expectEqual(Copy.b, chooseCopy(6, 5, 4, 4).?); // A torn
    try std.testing.expectEqual(null, chooseCopy(6, 5, 4, 3));
}

test "decode header" {
    var b: [header_footer_len]u8 = @splat(0);
    std.mem.writeInt(u32, b[0..4], stripe_magic, .little);
    std.mem.writeInt(u16, b[4..6], 24, .little);
    std.mem.writeInt(u16, b[6..8], 3, .little);
    std.mem.writeInt(i64, b[16..24], 1234567, .little);
    std.mem.writeInt(u32, b[44..48], 1, .little);
    std.mem.writeInt(u32, b[52..56], 9, .little);
    std.mem.writeInt(u32, b[64..68], 4096, .little);
    const h = HeaderFooter.decode(&b);
    try std.testing.expect(h.usable());
    try std.testing.expectEqual(1234567, h.write_pos);
    try std.testing.expectEqual(1, h.phase);
    try std.testing.expectEqual(9, h.sync_serial);
    try std.testing.expectEqual(4096, h.sector_size);
    b[4] = 20;
    try std.testing.expect(!HeaderFooter.decode(&b).usable());
}
