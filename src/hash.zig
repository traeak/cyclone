//! Cache key hash algorithm.
//!
//! ATS picks the algorithm at build time (`CryptoContext::Setting` in
//! src/tscore/CryptoHash.cc): MD5 normally, SHA-256 when built with FIPS.
//! Nothing on disk records which one was used, so the caller has to say;
//! the default is MD5.

const std = @import("std");

pub const HashType = enum {
    md5,
    sha256,

    pub const default: HashType = .md5;

    /// Width of a cache key (`CryptoHash`) in bytes.
    pub fn keyLen(self: HashType) usize {
        return switch (self) {
            .md5 => 16,
            .sha256 => 32,
        };
    }

    pub fn parse(name: []const u8) ?HashType {
        return std.meta.stringToEnum(HashType, name);
    }
};

/// The widest key any supported hash produces.
pub const max_key_len = 32;

test HashType {
    try std.testing.expectEqual(HashType.md5, HashType.parse("md5").?);
    try std.testing.expectEqual(HashType.sha256, HashType.parse("sha256").?);
    try std.testing.expectEqual(null, HashType.parse("mmh"));
    try std.testing.expectEqual(16, HashType.default.keyLen());
}
