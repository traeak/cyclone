//! URL parsing and cache key hashing, ported from ATS master
//! src/proxy/hdrs/URL.cc.
//!
//! Only what forming a cache key needs is ported: `url_parse` (scheme,
//! `url_parse_internet`, `url_parse_http`) and `url_CryptoHash_get_general`.
//! Quirks are kept on purpose, because a key that differs by one byte is a
//! cache miss. Host character validation and strict URI parsing are not
//! done; a cache-key URL is trusted input.

const std = @import("std");
const hash = @import("hash.zig");
const CacheKey = @import("key.zig").CacheKey;

pub const UrlType = enum { none, http, https };

/// A parsed URL. Absent components are empty strings, which hash the same.
pub const Url = struct {
    scheme: []const u8 = "",
    user: []const u8 = "",
    password: []const u8 = "",
    host: []const u8 = "",
    /// 0 when absent or out of range.
    port: u16 = 0,
    /// Path without its leading slashes, as ATS stores it.
    path: []const u8 = "",
    query: []const u8 = "",
    fragment: []const u8 = "",
    url_type: UrlType = .none,

    pub const ParseError = error{ Empty, InvalidScheme, InvalidAuthority };

    /// Port of `url_parse` (`url_parse_scheme` + `url_parse_http`).
    pub fn parse(text: []const u8) ParseError!Url {
        var url: Url = .{};
        const end = text.len;

        // url_parse_scheme
        var cur: usize = 0;
        while (cur < end and text[cur] == ' ') cur += 1;
        if (cur >= end) return error.Empty;
        if (text[cur] != '/') {
            var c = cur;
            while (c < end and text[c] != ':') c += 1;
            if (c + 2 < end and text[c + 1] == '/' and text[c + 2] == '/') {
                // Well-known schemes all pass this check too.
                if (!validScheme(text[cur..c])) return error.InvalidScheme;
                url.setScheme(text[cur..c]);
                cur = c;
            }
        }

        cur = try url.parseInternet(text, cur);
        url.parseHttp(text, cur);
        return url;
    }

    /// Port of `url_parse_internet`: user, password, host and port.
    /// Returns the index just past the authority.
    fn parseInternet(url: *Url, text: []const u8, start: usize) ParseError!usize {
        const max_colon = 8;
        var cur = start;
        var end = text.len;

        if (end - cur > 3 and std.mem.eql(u8, text[cur..][0..3], "://")) {
            cur += 3;
        } else if (text[cur] == ':') {
            cur += 1;
            if (cur >= end) return error.InvalidAuthority;
            if (text[cur] == '/') {
                cur += 1;
                if (cur >= end) return error.InvalidAuthority;
                if (text[cur] == '/') {
                    cur += 1;
                    if (cur >= end) return error.InvalidAuthority;
                }
            }
        }

        var base = cur;
        var bracket: ?usize = null;
        var n_colon: usize = 0;
        var last_colon: ?usize = null;
        var user: []const u8 = "";
        var passw: []const u8 = "";
        var host: []const u8 = "";

        while (cur < end) {
            switch (text[cur]) {
                ']' => {
                    const open = bracket orelse return error.InvalidAuthority;
                    if (n_colon >= max_colon) return error.InvalidAuthority;
                    cur += 1;
                    host = text[open..cur]; // brackets are kept
                    if (cur >= end or text[cur] == '/') {
                        last_colon = null;
                        continue;
                    }
                    if (text[cur] != ':') return error.InvalidAuthority;
                    // Allow exactly one more colon: the port separator.
                    n_colon = max_colon;
                    last_colon = cur;
                    cur += 1;
                },
                ':' => {
                    n_colon += 1;
                    if (n_colon > max_colon) return error.InvalidAuthority;
                    last_colon = cur;
                    cur += 1;
                },
                '@' => {
                    if (user.len != 0 or n_colon > 1) return error.InvalidAuthority;
                    if (n_colon != 0) {
                        user = text[base..last_colon.?];
                        passw = text[last_colon.? + 1 .. cur];
                    } else {
                        user = text[base..cur];
                    }
                    n_colon = 0;
                    last_colon = null;
                    cur += 1;
                    base = cur;
                },
                '[' => {
                    if (bracket != null or base != cur) return error.InvalidAuthority;
                    bracket = cur;
                    cur += 1;
                },
                '/', '?', '#' => end = cur,
                else => cur += 1,
            }
        }

        if (user.len != 0) {
            url.user = user;
            url.password = passw;
        }
        if (host.len == 0) {
            if (n_colon == 1 or n_colon == max_colon) {
                host = text[base..last_colon.?];
            } else {
                host = text[base..cur];
                last_colon = null;
            }
        }
        url.host = host;
        if (last_colon) |lc| {
            const port = text[lc + 1 .. cur];
            if (port.len == 0) return error.InvalidAuthority;
            url.port = parsePort(port);
        }
        return cur;
    }

    /// Port of the rest of `url_parse_http`: path, query and fragment.
    fn parseHttp(url: *Url, text: []const u8, start: usize) void {
        const end = text.len;
        if (start == end) return;

        var path_start: ?usize = if (text[start] == '/') start else null;
        var path_end = end;
        var query_start: ?usize = null;
        var query_end = end;
        var fragment_start: ?usize = null;

        var cur = start;
        while (cur < end) : (cur += 1) {
            if (query_start == null and text[cur] == '?') {
                path_end = cur;
                query_start = cur + 1;
            } else if (text[cur] == '#') {
                if (query_start == null) path_end = cur else query_end = cur;
                fragment_start = cur + 1;
                break;
            }
        }

        if (path_start) |*ps| {
            // ATS drops every leading slash, not just the first.
            while (ps.* < path_end and text[ps.*] == '/') ps.* += 1;
            url.path = text[ps.*..path_end];
        }
        if (query_start) |qs| url.query = text[@min(qs, end)..query_end];
        if (fragment_start) |fs| url.fragment = text[@min(fs, end)..];
    }

    fn setScheme(url: *Url, scheme: []const u8) void {
        url.scheme = scheme;
        // Well-known scheme tokens match case-insensitively; the UDS
        // schemes are not tokens and match exactly. Everything else is HTTP.
        url.url_type = if (std.ascii.eqlIgnoreCase(scheme, "https") or
            std.ascii.eqlIgnoreCase(scheme, "wss") or
            std.mem.eql(u8, scheme, "https+unix")) .https else .http;
    }

    /// True when the path carries `;params` (`URLImpl::has_path_params`).
    pub fn hasPathParams(url: *const Url) bool {
        return std.mem.indexOfScalar(u8, url.path, ';') != null;
    }

    /// The port that goes into the key (`url_canonicalize_port`).
    pub fn canonicalPort(url: *const Url) u16 {
        if (url.port != 0) return url.port;
        return switch (url.url_type) {
            .http => 80,
            .https => 443,
            .none => 0,
        };
    }

    /// Writes the string part of the hash input: scheme "://" user ":"
    /// password "@" host "/" path "?" query. The separators are always
    /// present, even when a component is empty.
    pub fn writeCanonical(url: *const Url, w: *std.Io.Writer, opts: KeyOptions) std.Io.Writer.Error!void {
        try unescape(w, url.scheme, .lower);
        try w.writeAll("://");
        try unescape(w, url.user, .keep);
        try w.writeAll(":");
        try unescape(w, url.password, .keep);
        try w.writeAll("@");
        try unescape(w, url.host, .lower);
        try w.writeAll("/");
        // The origin may treat escaped and unescaped paths differently, so
        // path and query are hashed exactly as given.
        try w.writeAll(url.path);
        if (opts.compat_92 and !url.hasPathParams()) try w.writeAll(";");
        try w.writeAll("?");
        if (!opts.ignore_query) try w.writeAll(url.query);
    }

    /// Port of `url_CryptoHash_get_general` (or `..._general_92` with
    /// `compat_92`): hash the canonical string, the canonical port as a
    /// little-endian u16, and the generation as a little-endian i64 unless
    /// it is -1.
    pub fn cacheKey(url: *const Url, hash_type: hash.HashType, opts: KeyOptions) CacheKey {
        var key: CacheKey = .{ .hash_type = hash_type };
        switch (hash_type) {
            inline else => |t| {
                const Hasher = switch (t) {
                    .md5 => std.crypto.hash.Md5,
                    .sha256 => std.crypto.hash.sha2.Sha256,
                };
                var hasher = Hasher.init(.{});
                var buf: [256]u8 = undefined;
                var hw = HashWriter(Hasher).init(&hasher, &buf);
                url.writeCanonical(&hw.writer, opts) catch unreachable;
                hw.writer.flush() catch unreachable;
                var tail: [10]u8 = undefined;
                std.mem.writeInt(u16, tail[0..2], url.canonicalPort(), .little);
                hasher.update(tail[0..2]);
                if (opts.generation != -1) {
                    std.mem.writeInt(i64, tail[2..10], opts.generation, .little);
                    hasher.update(tail[2..10]);
                }
                hasher.final(key.bytes[0..Hasher.digest_length]);
            },
        }
        return key;
    }
};

pub const KeyOptions = struct {
    /// Leave the query out (`proxy.config.http.cache.ignore_query`).
    ignore_query: bool = false,
    /// `proxy.config.http.cache.generation`; -1 means not hashed.
    generation: i64 = -1,
    /// Hash as ATS 9.2 did (`url_CryptoHash_get_92`): add ";" after the
    /// path unless the path already contains one.
    compat_92: bool = false,
};

/// Parse a cache-key URL and hash it.
pub fn cacheKey(text: []const u8, hash_type: hash.HashType, opts: KeyOptions) Url.ParseError!CacheKey {
    const url = try Url.parse(text);
    return url.cacheKey(hash_type, opts);
}

/// RFC 3986 scheme: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ).
fn validScheme(scheme: []const u8) bool {
    if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

/// `URLImpl::set_port`: leading digits only; out of range means no port.
fn parsePort(text: []const u8) u16 {
    var port: u32 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) break;
        port = port * 10 + (c - '0');
        if (port > 65535) return 0;
    }
    return @intCast(port);
}

const Case = enum { keep, lower };

/// Port of `unescape_str` / `unescape_str_tolower`. Decodes %XX; a '%' not
/// followed by two hex digits is copied through; an escape cut off by the
/// end of the component is dropped. Decoded bytes are never lowercased.
///
/// Not reproduced: ATS hashes through a 4096-byte buffer, and the fast path
/// of `unescape_str` ignores an escape split across a buffer flush. That can
/// only matter for a user or password over 4 KB.
fn unescape(w: *std.Io.Writer, src: []const u8, case: Case) std.Io.Writer.Error!void {
    const fold = struct {
        fn f(c: u8, cs: Case) u8 {
            return if (cs == .lower) std.ascii.toLower(c) else c;
        }
    }.f;
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] != '%') {
            try w.writeByte(fold(src[i], case));
            i += 1;
            continue;
        }
        if (i + 1 >= src.len) return; // "%" at the end: dropped
        const hi = std.fmt.charToDigit(src[i + 1], 16) catch {
            try w.writeByte('%');
            i += 1;
            continue;
        };
        if (i + 2 >= src.len) return; // "%X" at the end: dropped
        const lo = std.fmt.charToDigit(src[i + 2], 16) catch {
            try w.writeByte('%');
            try w.writeByte(fold(src[i + 1], case));
            i += 2;
            continue;
        };
        try w.writeByte(hi * 16 + lo);
        i += 3;
    }
}

/// A `std.Io.Writer` that feeds a hash function.
fn HashWriter(comptime Hasher: type) type {
    return struct {
        hasher: *Hasher,
        writer: std.Io.Writer,

        const Self = @This();

        fn init(hasher: *Hasher, buffer: []u8) Self {
            return .{ .hasher = hasher, .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("writer", w));
            self.hasher.update(w.buffered());
            w.end = 0;
            var n: usize = 0;
            for (data[0 .. data.len - 1]) |d| {
                self.hasher.update(d);
                n += d.len;
            }
            const last = data[data.len - 1];
            for (0..splat) |_| self.hasher.update(last);
            return n + last.len * splat;
        }
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectCanonical(expected: []const u8, text: []const u8, opts: KeyOptions) !void {
    const url = try Url.parse(text);
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try url.writeCanonical(&w, opts);
    try testing.expectEqualStrings(expected, w.buffered());
}

fn keyOf(text: []const u8, opts: KeyOptions) !CacheKey {
    return cacheKey(text, .md5, opts);
}

test "parse components" {
    const u = try Url.parse("HTTPS://us%65r:pw@[::1]:8443//a/b;p=1?x=1&y#frag");
    try testing.expectEqualStrings("HTTPS", u.scheme);
    try testing.expectEqualStrings("us%65r", u.user);
    try testing.expectEqualStrings("pw", u.password);
    try testing.expectEqualStrings("[::1]", u.host);
    try testing.expectEqual(8443, u.port);
    try testing.expectEqualStrings("a/b;p=1", u.path);
    try testing.expectEqualStrings("x=1&y", u.query);
    try testing.expectEqualStrings("frag", u.fragment);
    try testing.expectEqual(UrlType.https, u.url_type);
    try testing.expectEqual(8443, u.canonicalPort());
}

test "parse edge cases" {
    try testing.expectError(error.Empty, Url.parse("   "));
    try testing.expectError(error.InvalidScheme, Url.parse("1http://h/"));
    try testing.expectError(error.InvalidAuthority, Url.parse("http://"));
    try testing.expectError(error.InvalidAuthority, Url.parse("http://h:/"));
    try testing.expectError(error.InvalidAuthority, Url.parse("http://a@b@c/"));

    const no_path = try Url.parse("http://h");
    try testing.expectEqualStrings("h", no_path.host);
    try testing.expectEqual(80, no_path.canonicalPort());

    const query_only = try Url.parse("http://h?q#f");
    try testing.expectEqualStrings("", query_only.path);
    try testing.expectEqualStrings("q", query_only.query);
    try testing.expectEqualStrings("f", query_only.fragment);

    // '?' inside the fragment does not start a query.
    const frag = try Url.parse("http://h/p#a?b");
    try testing.expectEqualStrings("", frag.query);
    try testing.expectEqualStrings("a?b", frag.fragment);

    try testing.expectEqual(0, (try Url.parse("http://h:99999/")).port);
    try testing.expectEqual(0, (try Url.parse("//h/p")).canonicalPort());
    try testing.expectEqual(UrlType.http, (try Url.parse("mysql://h/")).url_type);
}

test "canonical string" {
    try expectCanonical("http://:@example.com/a/path?q=1", "HTTP://Example.COM/a/path?q=1#x", .{});
    try expectCanonical("http://:@example.com/?", "http://example.com", .{});
    try expectCanonical("http://user:p$w@host/p%2Fq?", "http://us%65r:p%24w@ho%73t/p%2Fq", .{});
    try expectCanonical("http://:@h/p?", "http://h/p?secret", .{ .ignore_query = true });
    // Decoded host bytes are not lowercased, bad escapes pass through, and
    // an escape cut off by the end of the component is dropped.
    try expectCanonical("http://:@Ah%zz/?", "http://%41H%zz%4/", .{});
    try expectCanonical("http://:@h/path;?q", "http://h/path?q", .{ .compat_92 = true });
    try expectCanonical("http://:@h/a;b?", "http://h/a;b", .{ .compat_92 = true });
}

test "key bytes: md5 of canonical string, port, generation" {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update("http://:@example.com/a?");
    md5.update(&.{ 0x50, 0x00 }); // port 80, little-endian
    var want: [16]u8 = undefined;
    md5.final(&want);
    try testing.expectEqualSlices(u8, &want, (try keyOf("http://example.com/a", .{})).slice());

    md5 = std.crypto.hash.Md5.init(.{});
    md5.update("https://:@example.com/a?");
    md5.update(&.{ 0xbb, 0x01 }); // 443
    md5.update(&.{ 3, 0, 0, 0, 0, 0, 0, 0 });
    md5.final(&want);
    try testing.expectEqualSlices(u8, &want, (try keyOf("https://example.com/a", .{ .generation = 3 })).slice());

    try testing.expectEqual(32, (try cacheKey("http://h/", .sha256, .{})).slice().len);
}

// Equal/unequal pairs from ATS src/proxy/hdrs/unit_tests/test_URL.cc.
test "ATS UrlHashGet cases" {
    const Case_ = struct { a: []const u8, b: []const u8, ignore_query: bool, equal: bool };
    const cases = [_]Case_{
        .{ .a = "http://one.example.com/a/path?name=value#some=value?with_question#fragment", .b = "http://one.example.com/a/path?name=value#some=value?with_question#fragment", .ignore_query = false, .equal = true },
        .{ .a = "http://one%2Eexample.com/a/path?name=value#some=value?with_question#fragment", .b = "http://one.example.com/a/path?name=value#some=value?with_question#fragment", .ignore_query = false, .equal = true },
        .{ .a = "http://one.example.com/a%2Fpath?name=value#some=value?with_question#fragment", .b = "http://one.example.com/a/path?name=value#some=value?with_question#fragment", .ignore_query = false, .equal = false },
        .{ .a = "http://one.example.com/a/path?name%3Dvalue#some=value?with_question#fragment", .b = "http://one.example.com/a/path?name=value#some=value?with_question#fragment", .ignore_query = false, .equal = false },
        .{ .a = "http://one.example.com/a/path?name%3Dvalue#some=value?with_question#fragment", .b = "http://one.example.com/a/path?name=value#some=value?with_question#fragment", .ignore_query = true, .equal = true },
        .{ .a = "http://one.example.com/a/path?name=valu%5D#some=value?with_question#fragment", .b = "http://one.example.com/a/path?name=valu]#some=value?with_question#fragment", .ignore_query = false, .equal = false },
        .{ .a = "http://one.example.com/a/path?name=valu%5D#some=value?with_question#fragment", .b = "http://one.example.com/a/path?name=valu]#some=value?with_question#fragment", .ignore_query = true, .equal = true },
        .{ .a = "http://one.example.com/a/path?name=value#some=value?with_question#frag%7Dent", .b = "http://one.example.com/a/path?name=value#some=value?with_question/frag}ent", .ignore_query = false, .equal = true },
        .{ .a = "mysql://my%7Eser:mypassword@localhost/mydatabase", .b = "mysql://my~ser:mypassword@localhost/mydatabase", .ignore_query = false, .equal = true },
        .{ .a = "mysql://myuser:mypa%24sword@localhost/mydatabase", .b = "mysql://myuser:mypa$sword@localhost/mydatabase", .ignore_query = false, .equal = true },
        .{ .a = "http://ONE.EXAMPLE.COM/a/path?name=value", .b = "http://one.example.com/a/path?name=value", .ignore_query = false, .equal = true },
        .{ .a = "http://One.Example.Com/a/path?name=value", .b = "http://one.example.com/a/path?name=value", .ignore_query = false, .equal = true },
        .{ .a = "HTTP://one.example.com/a/path?name=value", .b = "http://one.example.com/a/path?name=value", .ignore_query = false, .equal = true },
        .{ .a = "http://A-VERY-LONG-HOST-NAME-FOR-SIMD.EXAMPLE.COM/a/path", .b = "http://a-very-long-host-name-for-simd.example.com/a/path", .ignore_query = false, .equal = true },
    };
    for (cases) |c| {
        const opts: KeyOptions = .{ .ignore_query = c.ignore_query };
        const ka = try keyOf(c.a, opts);
        const kb = try keyOf(c.b, opts);
        testing.expectEqual(c.equal, ka.eql(&kb)) catch |err| {
            std.debug.print("case failed: {s} vs {s}\n", .{ c.a, c.b });
            return err;
        };
    }
}

// From ATS test_URL.cc "UrlHashGet92 reproduces the 9.2 cache key".
test "ATS UrlHashGet92 cases" {
    const pairs = [_][2][]const u8{
        .{ "http://foo.test/path", "http://foo.test/path;" },
        .{ "http://foo.test/path?q=1", "http://foo.test/path;?q=1" },
        .{ "http://foo.test/a?b;c", "http://foo.test/a;?b;c" },
        .{ "http://foo.test/a;b=1", "http://foo.test/a;b=1" },
        .{ "http://foo.test/a;b;c", "http://foo.test/a;b;c" },
        .{ "http://foo.test/a;b=1?q=1", "http://foo.test/a;b=1?q=1" },
        .{ "http://foo.test/a%3Bb=1", "http://foo.test/a%3Bb=1;" },
    };
    for (pairs) |p| {
        const k92 = try keyOf(p[0], .{ .compat_92 = true });
        const k = try keyOf(p[1], .{});
        try testing.expect(k92.eql(&k));
    }
    const a = try keyOf("http://foo.test/path", .{ .compat_92 = true });
    const b = try keyOf("http://foo.test/path", .{});
    try testing.expect(!a.eql(&b));
}

// Keys produced by ATS master itself (tools/ats-keygen) for the URLs in
// testdata/key_urls.txt. Each line: default, ignore_query, generation=3 and
// 9.2-compat keys, a tab, then the URL; or PARSE_ERROR, a tab, the URL.
test "matches ATS master golden keys" {
    const golden = @embedFile("testdata/key_golden.txt");
    const variants = [_]KeyOptions{ .{}, .{ .ignore_query = true }, .{ .generation = 3 }, .{ .compat_92 = true } };
    var lines = std.mem.splitScalar(u8, golden, '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t').?;
        const text = line[tab + 1 ..];
        errdefer std.debug.print("golden mismatch for '{s}'\n", .{text});
        if (std.mem.eql(u8, line[0..tab], "PARSE_ERROR")) {
            try testing.expect(std.meta.isError(Url.parse(text)));
        } else {
            const url = try Url.parse(text);
            var keys = std.mem.splitScalar(u8, line[0..tab], ' ');
            for (variants) |opts| {
                const want = try CacheKey.parseHex(.md5, keys.next().?);
                const got = url.cacheKey(.md5, opts);
                try testing.expect(want.eql(&got));
            }
        }
        checked += 1;
    }
    try testing.expectEqual(68, checked);
}
