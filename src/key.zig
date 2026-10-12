//! Cache keys (`CryptoHash` / `CacheKey` in ATS).

const std = @import("std");
const hash = @import("hash.zig");
const HashType = hash.HashType;

pub const CacheKey = struct {
    hash_type: HashType,
    /// Only the first `hash_type.keyLen()` bytes are meaningful.
    bytes: [hash.max_key_len]u8 = @splat(0),

    pub fn slice(self: *const CacheKey) []const u8 {
        return self.bytes[0..self.hash_type.keyLen()];
    }

    /// The `i`th little-endian 32-bit word, as `CryptoHash::slice32()`.
    /// ATS uses these to pick the stripe, segment, bucket and tag.
    pub fn slice32(self: *const CacheKey, i: usize) u32 {
        return std.mem.readInt(u32, self.bytes[i * 4 ..][0..4], .little);
    }

    pub fn eql(a: *const CacheKey, b: *const CacheKey) bool {
        return a.hash_type == b.hash_type and std.mem.eql(u8, a.slice(), b.slice());
    }

    /// `CryptoHash::is_zero`: an alternate with no data has a zero key.
    pub fn isZero(self: *const CacheKey) bool {
        for (self.slice()) |b| if (b != 0) return false;
        return true;
    }

    pub const ParseError = error{ InvalidLength, InvalidCharacter };

    /// Parse a key written as hex digits; the length must match `hash_type`.
    pub fn parseHex(hash_type: HashType, text: []const u8) ParseError!CacheKey {
        var k: CacheKey = .{ .hash_type = hash_type };
        if (text.len != hash_type.keyLen() * 2) return error.InvalidLength;
        _ = std.fmt.hexToBytes(k.bytes[0..hash_type.keyLen()], text) catch return error.InvalidCharacter;
        return k;
    }

    /// `next_CacheKey`: the key of an object's next fragment. ATS derives each
    /// data fragment's key from the one before (`CacheKey_next_table` in
    /// src/iocore/cache/CacheDir.cc). Only the first 16 bytes change.
    pub fn next(self: *const CacheKey) CacheKey {
        var k = self.*;
        k.bytes[0] = next_table[self.bytes[0]];
        for (1..16) |i| k.bytes[i] = next_table[(@as(usize, k.bytes[i - 1]) + self.bytes[i]) & 0xff];
        return k;
    }

    /// `prev_CacheKey`: the inverse of `next`. A vector Doc written alone gets
    /// the key before its alternate's earliest key.
    pub fn prev(self: *const CacheKey) CacheKey {
        var k = self.*;
        var i: usize = 15;
        while (i > 0) : (i -= 1) k.bytes[i] = prev_table[self.bytes[i]] -% self.bytes[i - 1];
        k.bytes[0] = prev_table[self.bytes[0]];
        return k;
    }

    /// In JSON, the key is its hex string.
    pub fn jsonStringify(self: CacheKey, jw: anytype) !void {
        try jw.print("\"{f}\"", .{self});
    }

    /// Writes the key as lowercase hex digits.
    pub fn format(self: CacheKey, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.slice()) |b| try w.print("{x:0>2}", .{b});
    }
};

const next_table = [256]u8{
    21,  53,  167, 51,  255, 126, 241, 151, 115, 66,  155, 174, 226, 215, 80,  188,
    12,  95,  8,   24,  162, 201, 46,  104, 79,  172, 39,  68,  56,  144, 142, 217,
    101, 62,  14,  108, 120, 90,  61,  47,  132, 199, 110, 166, 83,  125, 57,  65,
    19,  130, 148, 116, 228, 189, 170, 1,   71,  0,   252, 184, 168, 177, 88,  229,
    242, 237, 183, 55,  13,  212, 240, 81,  211, 74,  195, 205, 147, 93,  30,  87,
    86,  63,  135, 102, 233, 106, 118, 163, 107, 10,  243, 136, 160, 119, 43,  161,
    206, 141, 203, 78,  175, 36,  37,  140, 224, 197, 185, 196, 248, 84,  122, 73,
    152, 157, 18,  225, 219, 145, 45,  2,   171, 249, 173, 32,  143, 137, 69,  41,
    35,  89,  33,  98,  179, 214, 114, 231, 251, 123, 180, 194, 29,  3,   178, 31,
    192, 164, 15,  234, 26,  230, 91,  156, 5,   16,  23,  244, 58,  50,  4,   67,
    134, 165, 60,  235, 250, 7,   138, 216, 49,  139, 191, 154, 11,  52,  239, 59,
    111, 245, 9,   64,  25,  129, 247, 232, 190, 246, 109, 22,  112, 210, 221, 181,
    92,  169, 48,  100, 193, 77,  103, 133, 70,  220, 207, 223, 176, 204, 76,  186,
    200, 208, 158, 182, 227, 222, 131, 38,  187, 238, 6,   34,  253, 128, 146, 44,
    94,  127, 105, 153, 113, 20,  27,  124, 159, 17,  72,  218, 96,  149, 213, 42,
    28,  254, 202, 40,  117, 82,  97,  209, 54,  236, 121, 75,  85,  150, 99,  198,
};

const prev_table = [256]u8{
    57,  55,  119, 141, 158, 152, 218, 165, 18,  178, 89,  172, 16,  68,  34,  146,
    153, 233, 114, 48,  229, 0,   187, 154, 19,  180, 148, 230, 240, 140, 78,  143,
    123, 130, 219, 128, 101, 102, 215, 26,  243, 127, 239, 94,  223, 118, 22,  39,
    194, 168, 157, 3,   173, 1,   248, 67,  28,  46,  156, 175, 162, 38,  33,  81,
    179, 47,  9,   159, 27,  126, 200, 56,  234, 111, 73,  251, 206, 197, 99,  24,
    14,  71,  245, 44,  109, 252, 80,  79,  62,  129, 37,  150, 192, 77,  224, 17,
    236, 246, 131, 254, 195, 32,  83,  198, 23,  226, 85,  88,  35,  186, 42,  176,
    188, 228, 134, 8,   51,  244, 86,  93,  36,  250, 110, 137, 231, 45,  5,   225,
    221, 181, 49,  214, 40,  199, 160, 82,  91,  125, 166, 169, 103, 97,  30,  124,
    29,  117, 222, 76,  50,  237, 253, 7,   112, 227, 171, 10,  151, 113, 210, 232,
    92,  95,  20,  87,  145, 161, 43,  2,   60,  193, 54,  120, 25,  122, 11,  100,
    204, 61,  142, 132, 138, 191, 211, 66,  59,  106, 207, 216, 15,  53,  184, 170,
    144, 196, 139, 74,  107, 105, 255, 41,  208, 21,  242, 98,  205, 75,  96,  202,
    209, 247, 189, 72,  69,  238, 133, 13,  167, 31,  235, 116, 201, 190, 213, 203,
    104, 115, 12,  212, 52,  63,  149, 135, 183, 84,  147, 163, 249, 65,  217, 174,
    70,  6,   64,  90,  155, 177, 185, 182, 108, 121, 164, 136, 58,  220, 241, 4,
};

test "parse and format round trip" {
    const text = "0123456789abcdef0123456789abcdef";
    const k = try CacheKey.parseHex(.md5, text);
    var buf: [64]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "{f}", .{k});
    try std.testing.expectEqualStrings(text, out);
    try std.testing.expectEqual(0x67452301, k.slice32(0));
}

test "parse rejects bad input" {
    try std.testing.expectError(error.InvalidLength, CacheKey.parseHex(.md5, "abcd"));
    try std.testing.expectError(error.InvalidLength, CacheKey.parseHex(.sha256, "0123456789abcdef0123456789abcdef"));
    try std.testing.expectError(error.InvalidCharacter, CacheKey.parseHex(.md5, "zz23456789abcdef0123456789abcdef"));
}

test "next and prev follow ATS's fragment keys" {
    // From an object in the test fixture: the vector Doc's key, the
    // alternate's earliest key, and the keys of fragments 1 and 2.
    const vector = try CacheKey.parseHex(.md5, "a608174e56d0f004d911d30b40f9767f");
    const earliest = try CacheKey.parseHex(.md5, "8a0f3dc24fd9dc5e0108227dd2df6a11");
    const frag1 = try CacheKey.parseHex(.md5, "b464a58c224b2f03ff97f6e140d937d3");
    const frag2 = try CacheKey.parseHex(.md5, "1989394d491a4a5da001d1094a6cebdd");
    try std.testing.expect(earliest.prev().eql(&vector));
    try std.testing.expect(earliest.next().eql(&frag1));
    try std.testing.expect(frag1.next().eql(&frag2));
    try std.testing.expect(frag2.prev().eql(&frag1));
}
