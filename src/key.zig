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

    pub const ParseError = error{ InvalidLength, InvalidCharacter };

    /// Parse a key written as hex digits; the length must match `hash_type`.
    pub fn parseHex(hash_type: HashType, text: []const u8) ParseError!CacheKey {
        var k: CacheKey = .{ .hash_type = hash_type };
        if (text.len != hash_type.keyLen() * 2) return error.InvalidLength;
        _ = std.fmt.hexToBytes(k.bytes[0..hash_type.keyLen()], text) catch return error.InvalidCharacter;
        return k;
    }

    /// Writes the key as lowercase hex digits.
    pub fn format(self: CacheKey, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.slice()) |b| try w.print("{x:0>2}", .{b});
    }
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
