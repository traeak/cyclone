//! Reading fragments from a stripe's content area, and checking a
//! directory entry against the Doc it points at.

const std = @import("std");
const Io = std.Io;
const fmt = @import("format/doc.zig");
const dir = @import("dir.zig");
const hash = @import("hash.zig");
const CacheKey = @import("key.zig").CacheKey;
const Stripe = @import("stripe.zig").Stripe;

pub const Doc = fmt.Doc;
pub const FragType = fmt.FragType;

/// The newest Doc version this reader knows (`CACHE_DB_VERSION`). ATS
/// treats a newer one as corrupt.
pub const db_major = 24;
pub const db_minor = 3;

/// Reads the Doc at absolute span offset `offset`.
pub fn readHeader(io: Io, stripe: *const Stripe, hash_type: hash.HashType, offset: u64) !Doc {
    var b: [fmt.max_header_len]u8 = undefined;
    const n = fmt.headerLen(hash_type);
    if (try stripe.span.file.readPositionalAll(io, b[0..n], offset) != n) return error.Truncated;
    return Doc.decode(hash_type, b[0..n]);
}

/// Reads a whole fragment (`doc.len` bytes, Doc included) at `offset`.
/// `limit` bounds the read; a Doc claiming more is `error.TooLong`.
pub fn readFragment(gpa: std.mem.Allocator, io: Io, stripe: *const Stripe, hash_type: hash.HashType, offset: u64, limit: u64) ![]u8 {
    const doc = try readHeader(io, stripe, hash_type, offset);
    if (doc.magic != fmt.magic) return error.BadMagic;
    if (doc.len < fmt.headerLen(hash_type)) return error.TooShort;
    if (doc.len > limit) return error.TooLong;
    const buf = try gpa.alloc(u8, doc.len);
    errdefer gpa.free(buf);
    if (try stripe.span.file.readPositionalAll(io, buf, offset) != buf.len) return error.Truncated;
    return buf;
}

/// What a Doc says about a directory entry and the key that led to it.
pub const Verdict = enum {
    /// `first_key` is the key: the object's first fragment (for HTTP, the
    /// alternate vector), as ATS confirms a head lookup.
    first_key,
    /// `key` is the key: a data fragment looked up by its own key.
    key,
    /// A valid Doc for another object whose key shares the 12-bit tag.
    collision,
    /// Not a Doc: overwritten, or never written.
    bad_magic,
    /// Written by a newer cache version; ATS would not read it.
    future_version,
    /// Longer than the directory entry's approximate size, or shorter than
    /// a Doc, or the header runs past the fragment.
    bad_length,

    pub fn found(v: Verdict) bool {
        return v == .first_key or v == .key;
    }

    pub fn describe(v: Verdict) []const u8 {
        return switch (v) {
            .first_key => "hit (first_key matches)",
            .key => "hit (fragment key matches)",
            .collision => "collision: Doc for another key",
            .bad_magic => "no Doc there (bad magic)",
            .future_version => "Doc from a newer cache version",
            .bad_length => "Doc length does not fit the entry",
        };
    }
};

/// Checks `doc`, read through directory entry `d`, against `key`.
pub fn check(doc: Doc, d: dir.Dir, key: *const CacheKey) Verdict {
    if (doc.magic != fmt.magic) return .bad_magic;
    if (doc.v_major > db_major or (doc.v_major == db_major and doc.v_minor > db_minor)) return .future_version;
    const n = fmt.headerLen(key.hash_type);
    if (doc.len < n or doc.len > d.approxSize() or doc.prefixLen() > doc.len) return .bad_length;
    if (doc.first_key.eql(key)) return .first_key;
    if (doc.key.eql(key)) return .key;
    return .collision;
}

test "check verdicts" {
    const k = try CacheKey.parseHex(.md5, "00112233445566778899aabbccddeeff");
    const other = try CacheKey.parseHex(.md5, "ffeeddccbbaa99887766554433221100");
    // An entry of 1 KiB: size 1, big 0.
    const w = [5]u16{ 1, 1 << 10, 0, 0, 0 };
    var b: [10]u8 = undefined;
    for (w, 0..) |v, i| std.mem.writeInt(u16, b[i * 2 ..][0..2], v, .little);
    const d = dir.Dir.decode(&b);
    var doc: Doc = .{
        .magic = fmt.magic,
        .len = 500,
        .total_len = 0,
        .first_key = k,
        .key = other,
        .hlen = 400,
        .doc_type = .http,
        .v_major = 24,
        .v_minor = 3,
        .unused = 0,
        .sync_serial = 0,
        .write_serial = 0,
        .pinned = 0,
        .checksum = fmt.no_checksum,
    };
    try std.testing.expectEqual(Verdict.first_key, check(doc, d, &k));
    try std.testing.expectEqual(Verdict.key, check(doc, d, &other));
    doc.first_key = other;
    try std.testing.expectEqual(Verdict.collision, check(doc, d, &k));
    doc.hlen = 600;
    try std.testing.expectEqual(Verdict.bad_length, check(doc, d, &k));
    doc.hlen = 0;
    doc.len = 2000;
    try std.testing.expectEqual(Verdict.bad_length, check(doc, d, &k));
    doc.len = 500;
    doc.v_minor = 4;
    try std.testing.expectEqual(Verdict.future_version, check(doc, d, &k));
    doc.magic = 0;
    try std.testing.expectEqual(Verdict.bad_magic, check(doc, d, &k));
}
