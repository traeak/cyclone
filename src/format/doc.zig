//! Fragment header (`Doc`), from ATS master src/iocore/cache/P_CacheDoc.h.
//!
//! Every fragment in the content area starts with a Doc, then `hlen` bytes
//! of header (for HTTP, the marshalled alternate vector), then data, for
//! `len` bytes in all. The fragment occupies `dir_approx_size` bytes on
//! disk; the rest is padding.
//!
//! The layout depends on the key width, which follows the hash type. With
//! MD5 (16-byte keys, 72-byte Doc):
//!
//!    0  u32  magic          DOC_MAGIC, or DOC_CORRUPT
//!    4  u32  len            this fragment, Doc included, unrounded
//!    8  u64  total_len      the whole object's data
//!   16  key  first_key      the object's key (the cache key for HTTP)
//!   32  key  key            this fragment's key
//!   48  u32  hlen
//!   52  u8   doc_type       CacheFragType: 3 = HTTP
//!   53  u8   v_major        CACHE_DB_MAJOR_VERSION when written
//!   54  u8   v_minor
//!   55  u8   unused
//!   56  u32  sync_serial
//!   60  u32  write_serial
//!   64  u32  pinned         pinned until (seconds), 0 if not pinned
//!   68  u32  checksum       DOC_NO_CHECKSUM unless enable_checksum
//!
//! FIPS builds (SHA-256, 32-byte keys, 104-byte Doc) keep `first_key` at 16
//! and move `key` to the end, after `checksum`.

const std = @import("std");
const hash = @import("../hash.zig");
const CacheKey = @import("../key.zig").CacheKey;

pub const magic = 0x5F129B13;
/// Written over `magic` in memory when a read fails its checks; can reach
/// disk only through a rewrite of a damaged buffer.
pub const magic_corrupt = 0xDEADBABE;
/// `checksum` when checksums were off at write time.
pub const no_checksum = 0xA0B0C0D0;

/// `CacheFragType`.
pub const FragType = enum(u8) {
    none = 0,
    unused_1 = 1,
    rtsp = 2,
    http = 3,
    _,
};

/// `sizeof(Doc)`.
pub fn headerLen(hash_type: hash.HashType) usize {
    return 40 + 2 * hash_type.keyLen();
}

pub const max_header_len = 40 + 2 * hash.max_key_len;

pub const Doc = struct {
    magic: u32,
    len: u32,
    total_len: u64,
    first_key: CacheKey,
    key: CacheKey,
    hlen: u32,
    doc_type: FragType,
    v_major: u8,
    v_minor: u8,
    unused: u8,
    sync_serial: u32,
    write_serial: u32,
    pinned: u32,
    checksum: u32,

    /// Decodes the first `headerLen(hash_type)` bytes of `b`.
    pub fn decode(hash_type: hash.HashType, b: []const u8) Doc {
        const kl = hash_type.keyLen();
        std.debug.assert(b.len >= headerLen(hash_type));
        const r = struct {
            fn u(comptime T: type, bytes: []const u8, at: usize) T {
                return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
            }
        }.u;
        var first_key: CacheKey = .{ .hash_type = hash_type };
        var key: CacheKey = .{ .hash_type = hash_type };
        @memcpy(first_key.bytes[0..kl], b[16..][0..kl]);
        // Non-FIPS: key follows first_key. FIPS: key is at the end.
        const tail = 16 + kl + if (hash_type == .md5) kl else 0;
        const key_at = if (hash_type == .md5) 16 + kl else tail + 24;
        @memcpy(key.bytes[0..kl], b[key_at..][0..kl]);
        return .{
            .magic = r(u32, b, 0),
            .len = r(u32, b, 4),
            .total_len = r(u64, b, 8),
            .first_key = first_key,
            .key = key,
            .hlen = r(u32, b, tail),
            .doc_type = @fromBackingInt(@intCast(b[tail + 4])),
            .v_major = b[tail + 5],
            .v_minor = b[tail + 6],
            .unused = b[tail + 7],
            .sync_serial = r(u32, b, tail + 8),
            .write_serial = r(u32, b, tail + 12),
            .pinned = r(u32, b, tail + 16),
            .checksum = r(u32, b, tail + 20),
        };
    }

    /// `Doc::prefix_len`: bytes before the data.
    pub fn prefixLen(d: Doc) u64 {
        return headerLen(d.first_key.hash_type) + @as(u64, d.hlen);
    }

    /// `Doc::data_len`: data bytes in this fragment.
    pub fn dataLen(d: Doc) u64 {
        return if (d.len <= d.prefixLen()) 0 else d.len - d.prefixLen();
    }

    /// `Doc::single_fragment`: the whole object is in this fragment.
    pub fn singleFragment(d: Doc) bool {
        return d.dataLen() == d.total_len;
    }

    /// A sync marker: the empty Doc the aggregator writes when it has
    /// nothing else to flush (`StripeSM::aggWrite`). Zero keys, no data.
    pub fn isSyncMarker(d: Doc) bool {
        const zero: CacheKey = .{ .hash_type = d.key.hash_type };
        return d.magic == magic and d.hlen == 0 and d.total_len == 0 and d.key.eql(&zero) and d.first_key.eql(&zero);
    }
};

/// `Doc::calculate_checksum` over a whole fragment (`len` bytes, Doc
/// included): the sum of the bytes after the Doc as C `char`. That is signed
/// on x86 and unsigned on ARM; `signed_char` picks which.
pub fn checksum(hash_type: hash.HashType, fragment: []const u8, signed_char: bool) u32 {
    var sum: u32 = 0;
    for (fragment[headerLen(hash_type)..]) |c| {
        sum +%= if (signed_char) @bitCast(@as(i32, @as(i8, @bitCast(c)))) else c;
    }
    return sum;
}

const testing = std.testing;

fn testDoc(hash_type: hash.HashType) [max_header_len]u8 {
    const kl = hash_type.keyLen();
    var b: [max_header_len]u8 = @splat(0);
    std.mem.writeInt(u32, b[0..4], magic, .little);
    std.mem.writeInt(u32, b[4..8], 1234, .little);
    std.mem.writeInt(u64, b[8..16], 99999, .little);
    @memset(b[16..][0..kl], 0xAA);
    const tail = 16 + kl + if (hash_type == .md5) kl else 0;
    @memset(b[(if (hash_type == .md5) 16 + kl else tail + 24)..][0..kl], 0xBB);
    std.mem.writeInt(u32, b[tail..][0..4], 300, .little);
    b[tail + 4] = 3;
    b[tail + 5] = 24;
    b[tail + 6] = 3;
    std.mem.writeInt(u32, b[tail + 20 ..][0..4], no_checksum, .little);
    return b;
}

test "decode md5 layout" {
    try testing.expectEqual(72, headerLen(.md5));
    const b = testDoc(.md5);
    const d = Doc.decode(.md5, &b);
    try testing.expectEqual(magic, d.magic);
    try testing.expectEqual(1234, d.len);
    try testing.expectEqual(99999, d.total_len);
    try testing.expectEqual(0xAA, d.first_key.bytes[15]);
    try testing.expectEqual(0xBB, d.key.bytes[0]);
    try testing.expectEqual(0, d.key.bytes[16]);
    try testing.expectEqual(300, d.hlen);
    try testing.expectEqual(FragType.http, d.doc_type);
    try testing.expectEqual(24, d.v_major);
    try testing.expectEqual(3, d.v_minor);
    try testing.expectEqual(no_checksum, d.checksum);
    try testing.expectEqual(1234 - 72 - 300, d.dataLen());
    try testing.expect(!d.singleFragment());
}

test "decode fips layout" {
    try testing.expectEqual(104, headerLen(.sha256));
    const b = testDoc(.sha256);
    const d = Doc.decode(.sha256, &b);
    try testing.expectEqual(0xAA, d.first_key.bytes[31]);
    try testing.expectEqual(0xBB, d.key.bytes[31]);
    try testing.expectEqual(300, d.hlen);
    try testing.expectEqual(FragType.http, d.doc_type);
    try testing.expectEqual(no_checksum, d.checksum);
}

test "checksum sums chars after the Doc" {
    var f: [72 + 3]u8 = @splat(0);
    f[72] = 1;
    f[73] = 0xff;
    f[74] = 0x80;
    try testing.expectEqual(@as(u32, 0xFFFF_FF80), checksum(.md5, &f, true));
    try testing.expectEqual(@as(u32, 1 + 255 + 128), checksum(.md5, &f, false));
}
