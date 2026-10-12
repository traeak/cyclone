//! Choosing an alternate for a request, as ATS does
//! (`HttpTransactCache::SelectFromAlternates` in HttpTransactCache.cc).
//!
//! Each alternate gets a quality from the request's Accept, Accept-Charset,
//! Accept-Encoding and Accept-Language against the stored request and
//! response, and is ruled out (-1) when a header named in the response's
//! Vary differs. The best quality wins; ties go to the youngest document,
//! and among equal ages to the later alternate. Nothing is chosen unless
//! the best quality is above 0.
//!
//! The header parsing reproduces ATS's quirks (HttpCompat.cc, HdrUtils.cc,
//! MIME.cc), since they decide which alternate is served. ATS computes in
//! `float`, and so does this.
//!
//! Before the lookup ATS rewrites the request's Accept-Encoding
//! (`proxy.config.http.normalize_ae`); `normalizeAcceptEncoding` does the
//! same.

const std = @import("std");
const http = @import("format/http.zig");
const Field = http.Field;

/// The records.yaml settings that change the choice.
pub const Config = struct {
    /// proxy.config.http.cache.ignore_accept_mismatch and the charset,
    /// encoding and language variants: 0 checks always, 1 never, 2 only
    /// when the response has a Vary header.
    ignore_accept_mismatch: u2 = 2,
    ignore_accept_charset_mismatch: u2 = 2,
    ignore_accept_encoding_mismatch: u2 = 2,
    ignore_accept_language_mismatch: u2 = 2,
    /// proxy.config.http.global_user_agent_header is set, so ATS ignores
    /// `Vary: User-Agent`.
    global_user_agent_header: bool = false,
    /// proxy.config.http.normalize_ae (0 to 5).
    normalize_ae: u3 = 1,
};

/// How one alternate fared.
pub const Match = struct {
    /// Accept, Accept-Charset, Accept-Encoding and Accept-Language
    /// qualities; -2 where ATS stopped before computing one.
    q: [4]f32 = .{ -2, -2, -2, -2 },
    /// The product of `q`, or -1 when one of them, or Vary, rules the
    /// alternate out.
    quality: f32 = -1,
    variability: Variability = .none,
    /// The Vary header name that differs (`variability == .some`).
    vary_field: []const u8 = "",
    /// Seconds; the tie-break between equal qualities. 0 with one
    /// alternate, as in ATS.
    age: i64 = 0,
    /// The alternate has no object key, and ATS skips it.
    skipped: bool = false,
};

pub const Variability = enum { none, some, all };

pub const Selection = struct {
    /// The alternate ATS would serve, or null for a miss.
    index: ?usize,
    matches: []const Match,
};

/// ATS's `CacheHighAgeWatermark` (UINT_MAX).
const high_age: i64 = std.math.maxInt(u32);

/// Chooses among `alts` for a request with header fields `request`
/// (already normalized), at time `now` (seconds since the epoch).
pub fn select(gpa: std.mem.Allocator, cfg: Config, request: []const Field, alts: []const http.Alternate, now: i64) !Selection {
    const matches = try gpa.alloc(Match, alts.len);
    var best_q: f32 = -1.0;
    var best_age: i64 = high_age;
    var best: ?usize = null;
    for (alts, matches, 0..) |a, *m, i| {
        m.* = .{};
        if (a.object_key.isZero()) {
            m.skipped = true;
            continue;
        }
        const req: []const Field = if (a.request) |h| h.fields else &.{};
        const resp: []const Field = if (a.response) |h| h.fields else &.{};
        m.* = quality(cfg, request, req, resp);
        if (alts.len > 1) {
            m.age = documentAge(a.request_sent_time, a.response_received_time, resp, now);
            if (m.age < 0) m.age = high_age;
        }
        if (m.quality > best_q or (m.quality == best_q and m.age <= best_age)) {
            best_q = m.quality;
            best_age = m.age;
            best = i;
        }
    }
    return .{ .index = if (best != null and best_q > 0) best else null, .matches = matches };
}

/// `calculate_quality_of_match` for a GET (a PURGE matches anything).
pub fn quality(cfg: Config, client: []const Field, cached_req: []const Field, cached_resp: []const Field) Match {
    var m: Match = .{};
    const vary_skip_mask: u2 = if (find(cached_resp, "Vary") != null) 1 else 3;
    const content_type = first(cached_resp, "Content-Type");

    if (cfg.ignore_accept_mismatch & vary_skip_mask != 0) {
        m.q[0] = 1.0;
    } else {
        const accept = first(client, "Accept");
        m.q[0] = if (content_type == null or accept == null) 1.0 else acceptQuality(accept.?, content_type.?);
    }
    if (m.q[0] >= 0) {
        if (cfg.ignore_accept_charset_mismatch & vary_skip_mask != 0) {
            m.q[1] = 1.0;
        } else {
            const a = first(client, "Accept-Charset");
            const ca = first(cached_req, "Accept-Charset");
            m.q[1] = if (a == null and ca == null) 1.001 else charsetQuality(a, content_type, ca);
        }
        if (m.q[1] >= 0) {
            if (cfg.ignore_accept_encoding_mismatch & vary_skip_mask != 0) {
                m.q[2] = 1.0;
            } else {
                const a = first(client, "Accept-Encoding");
                const ca = first(cached_req, "Accept-Encoding");
                m.q[2] = if (a == null and ca == null) 1.001 else encodingQuality(a, first(cached_resp, "Content-Encoding"), ca);
            }
            if (m.q[2] >= 0) {
                if (cfg.ignore_accept_language_mismatch & vary_skip_mask != 0) {
                    m.q[3] = 1.0;
                } else {
                    const a = first(client, "Accept-Language");
                    const ca = first(cached_req, "Accept-Language");
                    m.q[3] = if (a == null and ca == null) 1.001 else languageQuality(a, first(cached_resp, "Content-Language"), ca);
                }
            }
        }
    }
    m.quality = if (m.q[0] < 0 or m.q[1] < 0 or m.q[2] < 0 or m.q[3] < 0) -1.0 else m.q[0] * m.q[1] * m.q[2] * m.q[3];

    if (m.quality >= 0) {
        variability(cfg, client, cached_req, cached_resp, &m);
        if (m.variability != .none) m.quality = -1.0;
    }
    return m;
}

/// `CalcVariability`: every header the response's Vary names must be in
/// both requests with matching values, or in neither.
fn variability(cfg: Config, client: []const Field, cached_req: []const Field, cached_resp: []const Field, m: *Match) void {
    const vary = first(cached_resp, "Vary") orelse return;
    var it = tokens(vary, ',');
    while (it.next()) |name| {
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, "*")) {
            m.variability = .all;
            m.vary_field = name;
            return;
        }
        if (cfg.global_user_agent_header and std.ascii.eqlIgnoreCase(name, "User-Agent")) continue;
        if (cfg.ignore_accept_encoding_mismatch == 1 and std.ascii.eqlIgnoreCase(name, "Accept-Encoding")) continue;
        if (!varyValuesMatch(cached_req, client, name)) {
            m.variability = .some;
            m.vary_field = name;
            return;
        }
    }
}

/// `HttpCompat::do_vary_header_values_match`: the same comma-separated
/// values across all fields of the name, compared without case.
fn varyValuesMatch(a: []const Field, b: []const Field, name: []const u8) bool {
    const fa = find(a, name);
    const fb = find(b, name);
    if (fa == null and fb == null) return true;
    if (fa == null or fb == null) return false;
    if (CsvIter.count(a, fa.?, name) != CsvIter.count(b, fb.?, name)) return false;
    var ia: CsvIter = .init(a, fa.?, name);
    var ib: CsvIter = .init(b, fb.?, name);
    while (true) {
        const va = ia.step();
        const vb = ib.step();
        if (va == .end and vb == .end) return true;
        if (va == .end or vb == .end) return false;
        const sa = if (va == .value) va.value else "";
        const sb = if (vb == .value) vb.value else "";
        if (sa.len != sb.len or !std.ascii.eqlIgnoreCase(sa, sb)) return false;
    }
}

/// `calculate_quality_of_accept_match`: Accept against Content-Type.
fn acceptQuality(accept: []const u8, content_type: []const u8) f32 {
    var c_params = tokens(content_type, ';');
    const c_param = c_params.next() orelse return 1.0;
    const c = mimeType(c_param);
    // Safari sends Accept: */* but cannot show webp, so webp needs an
    // explicit match.
    const webp = std.ascii.eqlIgnoreCase(c.subtype, "webp") and std.ascii.eqlIgnoreCase(c.type, "image");

    var q: f32 = -1.0;
    var wildcard_type: ?f32 = null;
    var wildcard_subtype: ?f32 = null;
    var values = tokens(accept, ',');
    while (values.next()) |value| {
        var params = tokens(value, ';');
        const head = params.next() orelse continue;
        const a = mimeType(head);
        var wildcard = true;
        if (!webp) {
            if (std.mem.eql(u8, a.type, "*")) {
                wildcard_type = findQ(value);
            } else if (std.mem.eql(u8, a.subtype, "*") and std.ascii.eqlIgnoreCase(a.type, c.type)) {
                wildcard_subtype = findQ(value);
            } else {
                wildcard = false;
            }
        }
        if (webp or !wildcard) {
            if (std.ascii.eqlIgnoreCase(a.type, c.type) and std.ascii.eqlIgnoreCase(a.subtype, c.subtype)) q = @max(q, findQ(value));
        }
    }
    if (q == -1.0) if (wildcard_subtype) |w| {
        q = w;
    };
    if (q == -1.0) if (wildcard_type) |w| {
        q = w;
    };
    return q;
}

/// `calculate_quality_of_accept_charset_match`: Accept-Charset against
/// the charset in Content-Type (utf-8 when none is given).
fn charsetQuality(accept: ?[]const u8, content_type: ?[]const u8, cached_accept: ?[]const u8) f32 {
    if (accept != null and cached_accept != null and std.mem.eql(u8, accept.?, cached_accept.?)) return 1.001;
    if (accept == null or content_type == null) return 1.0;
    const default_charset = "utf-8";
    const charset = lookupParam(content_type.?, "charset", 127) orelse default_charset;

    var q: f32 = -1.0;
    var wildcard: ?f32 = null;
    var values = tokens(accept.?, ',');
    while (values.next()) |value| {
        var params = tokens(value, ';');
        const a = params.next() orelse continue;
        if (std.mem.eql(u8, a, "*")) {
            wildcard = findQ(value);
        } else if (a.len == 0 or std.ascii.eqlIgnoreCase(a, charset)) {
            q = @max(q, findQ(value));
        }
    }
    if (q == -1.0) if (wildcard) |w| {
        q = w;
    };
    if (q == -1.0 and std.ascii.eqlIgnoreCase(charset, default_charset)) q = 1.0;
    return q;
}

/// `does_encoding_match`; `pattern` may be `*`, and x-gzip and x-compress
/// are their plain names.
fn encodingMatches(pattern: []const u8, encoding: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*") or std.ascii.eqlIgnoreCase(pattern, encoding)) return true;
    const pairs = [_][2][]const u8{ .{ "gzip", "x-gzip" }, .{ "compress", "x-compress" } };
    for (pairs) |p| {
        if (std.ascii.eqlIgnoreCase(pattern, p[0]) and std.ascii.eqlIgnoreCase(encoding, p[1])) return true;
        if (std.ascii.eqlIgnoreCase(pattern, p[1]) and std.ascii.eqlIgnoreCase(encoding, p[0])) return true;
    }
    return false;
}

/// `HttpTransactCache::match_content_encoding`: whether an Accept-Encoding
/// value accepts `encoding` with a q other than 0.
pub fn acceptsEncoding(accept: ?[]const u8, encoding: []const u8) bool {
    var values = tokens(accept orelse return false, ',');
    while (values.next()) |value| {
        var params = tokens(value, ';');
        const a = params.next() orelse continue;
        if (findQ(value) != 0 and encodingMatches(a, encoding)) return true;
    }
    return false;
}

const Wildcard = struct {
    present: bool = false,
    q: f32 = 1.0,
};

/// `match_accept_content_encoding`: finds the first Accept-Encoding value
/// that is `*` or matches `encoding`. A `*` leaves `q` alone.
fn matchAcceptEncoding(encoding: []const u8, accept: []const u8, wildcard: *Wildcard, q: *f32) bool {
    var values = tokens(accept, ',');
    while (values.next()) |value| {
        var params = tokens(value, ';');
        const a = params.next() orelse continue;
        if (std.mem.eql(u8, a, "*")) {
            wildcard.* = .{ .present = true, .q = findQ(value) };
            return true;
        } else if (encodingMatches(a, encoding)) {
            q.* = @max(q.*, findQ(value));
            return true;
        }
    }
    return false;
}

/// `calculate_quality_of_accept_encoding_match`: Accept-Encoding against
/// Content-Encoding, with ATS's preferences for gzip.
fn encodingQuality(accept: ?[]const u8, content_encoding: ?[]const u8, cached_accept: ?[]const u8) f32 {
    if (accept != null and cached_accept != null and std.mem.eql(u8, accept.?, cached_accept.?)) return 1.001;
    if (accept == null and content_encoding == null) return 1.0;

    var identity = false;
    if (content_encoding) |ce| {
        if (ce.len == 0) {
            identity = true;
        } else {
            var values = tokens(ce, ',');
            while (values.next()) |v| if (std.ascii.eqlIgnoreCase(v, "identity")) {
                identity = true;
                break;
            };
        }
    } else {
        identity = true;
    }

    const a = accept orelse {
        if (!identity) return -1.0;
        return if (cached_accept == null) 1.0 else 0.001;
    };

    var q: f32 = -1.0;
    var wildcard: Wildcard = .{};
    if (content_encoding) |ce| {
        // Every content coding must be accepted; the qualities multiply.
        var combined: f32 = 1.0;
        var values = tokens(ce, ',');
        const all = while (values.next()) |v| {
            var this_q: f32 = -1.0;
            if (!matchAcceptEncoding(v, a, &wildcard, &this_q)) break false;
            combined *= this_q;
        } else true;
        if (all) q = combined;
    } else if (!matchAcceptEncoding("identity", a, &wildcard, &q)) {
        if (acceptsEncoding(a, "gzip") and acceptsEncoding(cached_accept, "gzip")) return 1.0;
    }

    if (q == -1.0 and wildcard.present) q = wildcard.q;
    if (q == -1.0 and identity) {
        if (acceptsEncoding(a, "gzip")) {
            // Fetch gzip unless the stored request already asked for it.
            return if (acceptsEncoding(cached_accept, "gzip")) 1.0 else -1.0;
        }
        if (cached_accept != null and !acceptsEncoding(cached_accept, "gzip")) return 0.001;
        return -1.0;
    }
    return q;
}

/// `does_language_range_match`: equal, or `range` is a prefix of `tag`
/// ending at a `-`.
fn languageRangeMatches(range: []const u8, tag: []const u8) bool {
    var i: usize = 0;
    while (i < range.len and i < tag.len and std.ascii.toLower(range[i]) == std.ascii.toLower(tag[i])) i += 1;
    if (i < range.len) return false;
    return i == tag.len or tag[i] == '-';
}

/// `match_accept_content_language`: finds the first Accept-Language range
/// that is `*` or matches `tag`, and sets `q` to its q (not the highest).
fn matchAcceptLanguage(tag: []const u8, accept: []const u8, wildcard: *Wildcard, q: *f32) bool {
    var values = tokens(accept, ',');
    while (values.next()) |value| {
        var params = tokens(value, ';');
        const range = params.next() orelse continue;
        if (std.mem.eql(u8, range, "*")) {
            wildcard.* = .{ .present = true, .q = findQ(value) };
            return true;
        } else if (languageRangeMatches(range, tag)) {
            q.* = findQ(value);
            return true;
        }
    }
    return false;
}

/// `calculate_quality_of_accept_language_match`: Accept-Language against
/// Content-Language; the lowest quality over the content's languages.
fn languageQuality(accept: ?[]const u8, content_language: ?[]const u8, cached_accept: ?[]const u8) f32 {
    if (accept != null and cached_accept != null and std.mem.eql(u8, accept.?, cached_accept.?)) return 1.001;
    const a = accept orelse return 1.0;

    var q: f32 = -1.0;
    var wildcard: Wildcard = .{};
    if (content_language) |cl| {
        var min_q: f32 = 1.0;
        var found = false;
        var values = tokens(cl, ',');
        while (values.next()) |tag| {
            if (matchAcceptLanguage(tag, a, &wildcard, &q)) {
                min_q = @min(min_q, q);
                found = true;
            }
        }
        q = if (found) min_q else -1.0;
    } else if (!matchAcceptLanguage("identity", a, &wildcard, &q)) {
        return 1.0;
    }
    if (q == -1.0 and wildcard.present) q = wildcard.q;
    return q;
}

/// `HttpTransactCache::calculate_document_age`, with the response's Age
/// and Date headers parsed as ATS does.
pub fn documentAge(request_time: i64, response_time: i64, response: []const Field, now: i64) i64 {
    const age_value: i64 = if (first(response, "Age")) |v| blk: {
        const n = parseInt64(v);
        break :blk if (n < 0) 0 else @min(n, std.math.maxInt(i32));
    } else 0;
    const date_value = @max(0, if (first(response, "Date")) |v| parseDate(v) else 0);
    const now_value = @max(now, response_time);
    const apparent_age: i64 = if (date_value > 0) @max(0, response_time -% date_value) else 0;
    const corrected_received_age = @max(apparent_age, age_value);
    const response_delay = response_time -% request_time;
    const corrected_initial_age = corrected_received_age +% response_delay;
    const resident_time = now_value -% response_time;
    return corrected_initial_age +% resident_time;
}

/// Rewrites the request's Accept-Encoding as
/// `HttpTransactHeaders::normalize_accept_encoding` does before ATS looks
/// in the cache. Returns `request` or a new slice from `gpa`.
pub fn normalizeAcceptEncoding(gpa: std.mem.Allocator, request: []const Field, level: u3) ![]const Field {
    if (level == 0) return request;
    const at = find(request, "Accept-Encoding") orelse return request;
    const ae = request[at].value;
    const z = acceptsEncoding(ae, "zstd");
    const b = acceptsEncoding(ae, "br");
    const g = acceptsEncoding(ae, "gzip");
    const value: ?[]const u8 = switch (level) {
        1 => if (g) "gzip" else null,
        2 => if (b) "br" else if (g) "gzip" else null,
        3 => if (b and g) "br, gzip" else if (b) "br" else if (g) "gzip" else null,
        4 => if (z) "zstd" else if (b) "br" else if (g) "gzip" else null,
        5 => if (z and b and g) "zstd, br, gzip" else if (z and b) "zstd, br" else if (z and g) "zstd, gzip" else if (z) "zstd" else if (b and g) "br, gzip" else if (b) "br" else if (g) "gzip" else null,
        // ATS logs an error and leaves the header alone.
        else => return request,
    };
    var out: std.ArrayList(Field) = .empty;
    errdefer out.deinit(gpa);
    for (request, 0..) |f, i| {
        if (i == at) {
            // Only this field's value is set, but every duplicate goes with
            // a delete.
            if (value) |v| try out.append(gpa, .{ .name = f.name, .value = v });
        } else if (value != null or !std.ascii.eqlIgnoreCase(f.name, "Accept-Encoding")) {
            try out.append(gpa, f);
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Header parsing as ATS does it.

fn find(fields: []const Field, name: []const u8) ?usize {
    for (fields, 0..) |f, i| if (std.ascii.eqlIgnoreCase(f.name, name)) return i;
    return null;
}

/// The first field's value (`MIMEField::value_get` after `field_find`):
/// duplicates are not joined.
fn first(fields: []const Field, name: []const u8) ?[]const u8 {
    return if (find(fields, name)) |i| fields[i].value else null;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// `HttpCompat::parse_tok_list` with quote trimming: tokens split on `sep`
/// outside double quotes, trimmed of white space and of a quote pair, with
/// empty tokens kept (an empty or blank string is one empty token).
fn tokens(s: []const u8, sep: u8) TokIter {
    return .{ .s = s, .sep = sep };
}

const TokIter = struct {
    s: []const u8,
    sep: u8,
    at: usize = 0,
    before_ws: usize = 0,
    hit_sep: bool = false,
    count: usize = 0,
    done: bool = false,

    fn next(it: *TokIter) ?[]const u8 {
        const s = it.s;
        while (it.at < s.len) {
            while (it.at < s.len and isWs(s[it.at])) it.at += 1;
            if (it.at < s.len and s[it.at] == it.sep) {
                const tok = s[it.before_ws..it.before_ws];
                it.count += 1;
                it.before_ws = it.at + 1;
                it.at = it.before_ws;
                it.hit_sep = true;
                return tok;
            }
            if (it.at >= s.len) break;

            var start = it.at;
            var in_quote = false;
            var trim_end_quote = false;
            var e = start;
            if (s[start] == '"') {
                in_quote = true;
                trim_end_quote = true;
                start += 1;
                e = start;
            }
            while (e < s.len and !(s[e] == it.sep and !in_quote)) : (e += 1) {
                if (s[e] == '"') in_quote = !in_quote;
            }
            it.hit_sep = e < s.len;
            it.before_ws = e + 1;
            while (e > start and isWs(s[e - 1])) e -= 1;
            if (e > start and s[e - 1] == '"' and trim_end_quote) e -= 1;
            it.at = it.before_ws;
            it.count += 1;
            return s[start..e];
        }
        if (it.done) return null;
        it.done = true;
        if (it.hit_sep or it.count == 0) return s[0..0];
        return null;
    }
};

/// `HdrCsvIter`: the non-empty comma-separated values of a field and its
/// duplicates, trimmed of white space and of one leading and one trailing
/// quote. A quote preceded by a backslash does not close a quoted string.
const CsvIter = struct {
    fields: []const Field,
    name: []const u8,
    field: ?usize,
    rest: []const u8,

    /// What one `find_csv` call leaves in `m_csv`. Through the `char *`
    /// API that `do_vary_header_values_match` uses, a call that runs out
    /// after trimming an item to nothing (a trailing `,` or `""`) returns
    /// that empty item, not null: a zero-length value that still counts.
    const Item = union(enum) { value: []const u8, phantom, end };

    fn init(fields: []const Field, at: usize, name: []const u8) CsvIter {
        return .{ .fields = fields, .name = name, .field = at, .rest = fields[at].value };
    }

    /// `count_values`, which tests the `TextView` (non-empty) and so stops
    /// at a phantom.
    fn count(fields: []const Field, at: usize, name: []const u8) usize {
        var it: CsvIter = .init(fields, at, name);
        var n: usize = 0;
        while (it.step() == .value) n += 1;
        return n;
    }

    fn step(it: *CsvIter) Item {
        var computed = false;
        while (it.field) |fi| {
            while (it.rest.len != 0) {
                const v = it.rest;
                var in_quote = false;
                var idx: usize = 0;
                while (idx < v.len) {
                    if (v[idx] == '"') {
                        if (!in_quote) {
                            in_quote = true;
                        } else if (v[idx - 1] != '\\') {
                            in_quote = false;
                        }
                    } else if (v[idx] == ',' and !in_quote) {
                        break;
                    }
                    idx += 1;
                }
                var csv = std.mem.trim(u8, v[0..idx], " \t");
                it.rest = v[@min(idx + 1, v.len)..];
                if (csv.len != 0 and csv[0] == '"') csv = csv[1..];
                if (csv.len != 0 and csv[csv.len - 1] == '"') csv = csv[0 .. csv.len - 1];
                computed = true;
                if (csv.len != 0) return .{ .value = csv };
            }
            it.field = null;
            for (it.fields[fi + 1 ..], fi + 1..) |f, i| if (std.ascii.eqlIgnoreCase(f.name, it.name)) {
                it.field = i;
                it.rest = f.value;
                break;
            };
        }
        return if (computed) .phantom else .end;
    }
};

/// `HttpCompat::lookup_param_in_strlist` over a semicolon list: the first
/// item named `name` (without case, followed by its end, white space or
/// `=`). Its value after `=`, at most `max_len - 1` bytes, or "" when it
/// has none.
fn lookupParam(s: []const u8, name: []const u8, max_len: usize) ?[]const u8 {
    var params = tokens(s, ';');
    while (params.next()) |p| {
        if (p.len < name.len or !std.ascii.eqlIgnoreCase(p[0..name.len], name)) continue;
        var i = name.len;
        if (i < p.len and !isWs(p[i]) and p[i] != '=') continue;
        while (i < p.len and isWs(p[i])) i += 1;
        if (i == p.len or p[i] != '=') return "";
        i += 1;
        while (i < p.len and isWs(p[i])) i += 1;
        return p[i..][0..@min(p.len - i, max_len - 1)];
    }
    return null;
}

/// `HttpCompat::find_Q_param_in_strlist` on an unsplit list item: its `q`
/// read as `sscanf("%f")` reads the first 7 bytes, clamped to 0..1; 1 when
/// there is none or it does not parse.
fn findQ(item: []const u8) f32 {
    const v = lookupParam(item, "q", 8) orelse return 1.0;
    const f = scanFloat(v) orelse return 1.0;
    return if (f < 0) 0 else if (f > 1) 1 else f;
}

/// The longest decimal float at the start of `s`, as `%f` takes it.
fn scanFloat(s: []const u8) ?f32 {
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    const digits_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    var digits = i - digits_start;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        digits += i - frac;
    }
    if (digits == 0) return null;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        if (j < s.len and std.ascii.isDigit(s[j])) {
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            i = j;
        }
    }
    return std.fmt.parseFloat(f32, s[0..i]) catch null;
}

const MimeType = struct { type: []const u8, subtype: []const u8 };

/// `HttpCompat::parse_mime_type` with 32-byte buffers: each part stops at
/// white space, `;`, `,` or `/`, and keeps at most 31 bytes.
fn mimeType(s: []const u8) MimeType {
    const stop = " \t;,/";
    var i: usize = 0;
    while (i < s.len and isWs(s[i])) i += 1;
    const t0 = i;
    while (i < s.len and std.mem.indexOfScalar(u8, stop, s[i]) == null) i += 1;
    const t = s[t0..i];
    while (i < s.len and s[i] != ';' and s[i] != ',' and s[i] != '/') i += 1;
    if (i < s.len and s[i] == '/') i += 1;
    while (i < s.len and isWs(s[i])) i += 1;
    const s0 = i;
    while (i < s.len and std.mem.indexOfScalar(u8, stop, s[i]) == null) i += 1;
    const st = s[s0..i];
    return .{ .type = t[0..@min(t.len, 31)], .subtype = st[0..@min(st.len, 31)] };
}

/// `mime_parse_int64`: leading white space, then an optional sign and
/// digits; 0 when there are none, saturating on overflow.
fn parseInt64(s: []const u8) i64 {
    var i: usize = 0;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    var j = i;
    if (j < s.len and s[j] == '-') j += 1;
    const d = j;
    while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
    if (j == d) return 0;
    return std.fmt.parseInt(i64, s[i..j], 10) catch if (s[i] == '-') std.math.minInt(i64) else std.math.maxInt(i64);
}

/// `mime_parse_date`: RFC 1123, RFC 850, asctime and NNTP dates; 0 when
/// the date does not parse or is before 1970, INT_MAX after 2037.
pub fn parseDate(text: []const u8) i64 {
    var p: DateParser = .{ .s = text };
    return p.parse() orelse 0;
}

const DateParser = struct {
    s: []const u8,
    i: usize = 0,

    const days = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };
    const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };

    fn parse(p: *DateParser) ?i64 {
        while (p.i < p.s.len and isWs(p.s[p.i])) p.i += 1;
        var mday: i32 = undefined;
        var mon: usize = undefined;
        var yr: i32 = undefined;
        var hms: [3]i32 = undefined;
        if (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) {
            mday = p.integer() orelse return null;
            mon = p.name(&months) orelse return null;
            yr = p.year() orelse return null;
            hms = p.time() orelse return null;
        } else if (p.s.len - p.i >= 29 and p.s[p.i + 3] == ',') {
            // `mime_parse_rfc822_date_fastcase`: fixed positions, unchecked
            // digits.
            const b = p.s[p.i..];
            if (match3(b[0..3], &days) == null) return null;
            mday = digits(b[5..7]);
            mon = match3(b[8..11], &months) orelse return null;
            yr = digits(b[12..16]) -% 1900;
            hms = .{ digits(b[17..19]), digits(b[20..22]), digits(b[23..25]) };
            if (b[19] != ':' or b[22] != ':') return null;
        } else {
            _ = p.name(&days) orelse return null;
            while (p.i < p.s.len and isWs(p.s[p.i])) p.i += 1;
            if (p.i < p.s.len and (p.s[p.i] == ',' or std.ascii.isDigit(p.s[p.i]))) {
                mday = p.integer() orelse return null;
                mon = p.name(&months) orelse return null;
                yr = p.year() orelse return null;
                hms = p.time() orelse return null;
            } else {
                mon = p.name(&months) orelse return null;
                mday = p.integer() orelse return null;
                hms = p.time() orelse return null;
                yr = p.year() orelse return null;
            }
        }
        if (yr > 137) return std.math.maxInt(i32);
        if (yr < 70) return 0;
        // In C `int`, wrapping as it does on x86-64.
        const month_days = [12]i32{ 305, 336, -1, 30, 60, 91, 121, 152, 183, 213, 244, 274 };
        var y = yr;
        var d = mday +% month_days[mon];
        if (mon < 2) y -= 1;
        d +%= y *% 365 +% @divTrunc(y, 4) -% @divTrunc(y, 100) +% @divTrunc(@divTrunc(y, 100) + 3, 4);
        d -%= 25508;
        return ((d *% 24 +% hms[0]) *% 60 +% hms[1]) *% 60 +% hms[2];
    }

    /// `match_3char_ci` on exactly three bytes.
    fn match3(word: []const u8, names: []const []const u8) ?usize {
        for (names, 0..) |n, k| if (std.ascii.eqlIgnoreCase(word, n)) return k;
        return null;
    }

    /// Digits read as `(c - '0') * 10 + ...` on signed chars, unchecked.
    fn digits(b: []const u8) i32 {
        var v: i32 = 0;
        for (b) |c| v = v *% 10 +% (@as(i32, @as(i8, @bitCast(c))) - '0');
        return v;
    }

    /// `mime_parse_day`/`mime_parse_month`: the next word, matched on its
    /// first three letters without case.
    fn name(p: *DateParser, names: []const []const u8) ?usize {
        while (p.i < p.s.len and !std.ascii.isAlphabetic(p.s[p.i])) p.i += 1;
        var e = p.i;
        while (e < p.s.len and std.ascii.isAlphabetic(p.s[e])) e += 1;
        const word = p.s[p.i..e];
        if (word.len < 3) return null;
        for (names, 0..) |n, k| if (std.ascii.eqlIgnoreCase(word[0..3], n)) {
            p.i = e;
            return k;
        };
        return null;
    }

    /// `mime_parse_integer`: skips to a digit or `-`, then reads an int,
    /// saturating.
    fn integer(p: *DateParser) ?i32 {
        while (p.i < p.s.len and !std.ascii.isDigit(p.s[p.i]) and p.s[p.i] != '-') p.i += 1;
        if (p.i == p.s.len) return null;
        const start = p.i;
        var e = p.i;
        if (p.s[e] == '-') e += 1;
        const d = e;
        while (e < p.s.len and std.ascii.isDigit(p.s[e])) e += 1;
        if (e == d) return null;
        p.i = e;
        return std.fmt.parseInt(i32, p.s[start..e], 10) catch if (p.s[start] == '-') std.math.minInt(i32) else std.math.maxInt(i32);
    }

    /// `mime_parse_year`: years since 1900, two-digit years below 70 in
    /// the 2000s.
    fn year(p: *DateParser) ?i32 {
        while (p.i < p.s.len and !std.ascii.isDigit(p.s[p.i])) p.i += 1;
        if (p.i == p.s.len) return null;
        var v: i32 = 0;
        while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) : (p.i += 1) v = v *% 10 +% (p.s[p.i] - '0');
        if (v >= 1900) return v - 1900;
        if (v < 70) return v + 100;
        return v;
    }

    fn time(p: *DateParser) ?[3]i32 {
        return .{ p.integer() orelse return null, p.integer() orelse return null, p.integer() orelse return null };
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

fn collect(s: []const u8, sep: u8, want: []const []const u8) !void {
    var it = tokens(s, sep);
    for (want) |w| try testing.expectEqualStrings(w, it.next() orelse return error.TooFew);
    try testing.expectEqual(null, it.next());
}

test "token lists split as parse_tok_list does" {
    try collect("gzip, br", ',', &.{ "gzip", "br" });
    try collect("", ',', &.{""});
    try collect("   ", ',', &.{""});
    try collect("a,,b,", ',', &.{ "a", "", "b", "" });
    try collect(" \"x, y\" , z ", ',', &.{ "x, y", "z" });
    try collect("text/html; q=0.5", ';', &.{ "text/html", "q=0.5" });
}

test "q values" {
    try testing.expectEqual(@as(f32, 1.0), findQ("gzip"));
    try testing.expectEqual(@as(f32, 0.5), findQ("gzip;q=0.5"));
    try testing.expectEqual(@as(f32, 0.5), findQ("gzip ; Q = 0.5"));
    try testing.expectEqual(@as(f32, 0.0), findQ("gzip;q=0"));
    try testing.expectEqual(@as(f32, 1.0), findQ("gzip;q=7"));
    try testing.expectEqual(@as(f32, 1.0), findQ("gzip;q=x"));
    try testing.expectEqual(@as(f32, 1.0), findQ("gzip;quality=0.1"));
    // sscanf sees only the first 7 bytes.
    try testing.expectEqual(@as(f32, 0.12345), findQ("gzip;q=0.123456789"));
}

test "Vary values match across duplicates, ignoring case and space" {
    const a = [_]Field{.{ .name = "Accept-Encoding", .value = "gzip, br" }};
    const b = [_]Field{ .{ .name = "accept-encoding", .value = "GZIP" }, .{ .name = "Accept-Encoding", .value = " br" } };
    const c = [_]Field{.{ .name = "Accept-Encoding", .value = "gzip" }};
    try testing.expect(varyValuesMatch(&a, &b, "Accept-Encoding"));
    try testing.expect(!varyValuesMatch(&a, &c, "Accept-Encoding"));
    try testing.expect(!varyValuesMatch(&a, &.{}, "Accept-Encoding"));
    try testing.expect(varyValuesMatch(&.{}, &.{}, "Accept-Encoding"));
    // A trailing empty item is a zero-length value that ATS compares.
    const d = [_]Field{ .{ .name = "Accept-Encoding", .value = "gzip" }, .{ .name = "Accept-Encoding", .value = "\"\"" } };
    try testing.expect(!varyValuesMatch(&c, &d, "Accept-Encoding"));
    try testing.expect(varyValuesMatch(&d, &d, "Accept-Encoding"));
}

test "quality: Vary rules out a different Accept-Encoding" {
    const resp = [_]Field{ .{ .name = "Content-Type", .value = "text/plain" }, .{ .name = "Vary", .value = "Accept-Encoding" } };
    const gz = [_]Field{.{ .name = "Accept-Encoding", .value = "gzip" }};
    const none = [_]Field{};
    var m = quality(.{}, &gz, &gz, &resp);
    try testing.expectEqual(@as(f32, 1.001), m.q[2]);
    try testing.expectEqual(Variability.none, m.variability);
    try testing.expect(m.quality > 1.0);

    // A gzip request against an identity alternate fetched without AE: ATS
    // prefers to fetch gzip (-1).
    m = quality(.{}, &gz, &none, &resp);
    try testing.expectEqual(@as(f32, -1.0), m.q[2]);
    try testing.expectEqual(@as(f32, -1.0), m.quality);

    // No AE against the gzip alternate: no AE and no Content-Encoding
    // match (1.0), but Vary differs.
    m = quality(.{}, &none, &gz, &resp);
    try testing.expectEqual(@as(f32, 1.0), m.q[2]);
    try testing.expectEqual(Variability.some, m.variability);
    try testing.expectEqual(@as(f32, -1.0), m.quality);

    // Without Vary the Accept checks are skipped by default.
    const plain = [_]Field{.{ .name = "Content-Type", .value = "text/plain" }};
    m = quality(.{}, &gz, &none, &plain);
    try testing.expectEqual(@as(f32, 1.0), m.quality);
}

test "accept qualities" {
    try testing.expectEqual(@as(f32, 0.5), acceptQuality("text/*;q=0.5, */*;q=0.1", "text/html; charset=utf-8"));
    try testing.expectEqual(@as(f32, 0.8), acceptQuality("text/html;q=0.8, text/*;q=0.5", "text/html"));
    try testing.expectEqual(@as(f32, -1.0), acceptQuality("image/png", "text/html"));
    // webp needs an explicit match.
    try testing.expectEqual(@as(f32, -1.0), acceptQuality("*/*", "image/webp"));
    try testing.expectEqual(@as(f32, 1.0), acceptQuality("image/webp", "image/webp"));

    try testing.expectEqual(@as(f32, 1.0), charsetQuality("iso-8859-1", "text/html", null));
    try testing.expectEqual(@as(f32, -1.0), charsetQuality("iso-8859-1", "text/html; charset=koi8-r", null));
    try testing.expectEqual(@as(f32, 0.3), charsetQuality("*;q=0.3", "text/html; charset=koi8-r", null));

    try testing.expectEqual(@as(f32, 0.7), languageQuality("en;q=0.7", "en-US", null));
    try testing.expectEqual(@as(f32, -1.0), languageQuality("de", "en", null));
    try testing.expectEqual(@as(f32, 1.0), languageQuality("de", null, null));

    try testing.expectEqual(@as(f32, 0.5), encodingQuality("br, gzip;q=0.5", "x-gzip", null));
    try testing.expectEqual(@as(f32, -1.0), encodingQuality(null, "gzip", null));
}

test "Accept-Encoding normalization" {
    const gpa = testing.allocator;
    const req = [_]Field{ .{ .name = "Host", .value = "h" }, .{ .name = "Accept-Encoding", .value = "br;q=1, gzip;q=0.5" } };
    const n1 = try normalizeAcceptEncoding(gpa, &req, 1);
    defer gpa.free(n1);
    try testing.expectEqualStrings("gzip", first(n1, "Accept-Encoding").?);
    const n3 = try normalizeAcceptEncoding(gpa, &req, 3);
    defer gpa.free(n3);
    try testing.expectEqualStrings("br, gzip", first(n3, "Accept-Encoding").?);
    const br = [_]Field{.{ .name = "Accept-Encoding", .value = "br, gzip;q=0" }};
    const n = try normalizeAcceptEncoding(gpa, &br, 1);
    defer gpa.free(n);
    try testing.expectEqual(@as(usize, 0), n.len);
}

test "dates parse as mime_parse_date does" {
    try testing.expectEqual(@as(i64, 784111777), parseDate("Sun, 06 Nov 1994 08:49:37 GMT"));
    try testing.expectEqual(@as(i64, 784111777), parseDate("Sunday, 06-Nov-94 08:49:37 GMT"));
    try testing.expectEqual(@as(i64, 784111777), parseDate("Sun Nov  6 08:49:37 1994"));
    try testing.expectEqual(@as(i64, 1791201600), parseDate("Mon, 05 Oct 2026 12:00:00 GMT"));
    try testing.expectEqual(@as(i64, 0), parseDate("yesterday"));
}

test "document age" {
    const resp = [_]Field{ .{ .name = "Date", .value = "Mon, 05 Oct 2026 12:00:00 GMT" }, .{ .name = "Age", .value = "30" } };
    // Received 10 s after its Date, stored for 100 s: Age (30) beats the
    // apparent age (10); 2 s in flight.
    const t: i64 = 1791201610;
    try testing.expectEqual(@as(i64, 30 + 2 + 100), documentAge(t - 2, t, &resp, t + 100));
}

fn unescapeInto(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try out.append(gpa, switch (s[i]) {
                't' => '\t',
                'n' => '\n',
                else => s[i],
            });
        } else {
            try out.append(gpa, s[i]);
        }
    }
    return out.items;
}

test "matches ATS's own functions on every case in testdata/select_golden.txt" {
    // Made by tools/ats-httpinfo (selectq.cc on gen-select-cases.py).
    const golden = @embedFile("testdata/select_golden.txt");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg: Config = .{};
    var sides: [3]std.ArrayList(Field) = .{ .empty, .empty, .empty };
    var case_name: []const u8 = "";
    var date_text: []const u8 = "";
    var cases: usize = 0;
    var dates: usize = 0;
    var failures: usize = 0;
    var lines = std.mem.splitScalar(u8, golden, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "case ")) {
            case_name = line;
            cfg = .{};
            for (&sides) |*s| s.clearRetainingCapacity();
        } else if (std.mem.startsWith(u8, line, "cfg ")) {
            var it = std.mem.tokenizeScalar(u8, line[4..], ' ');
            cfg.ignore_accept_mismatch = try std.fmt.parseInt(u2, it.next().?, 10);
            cfg.ignore_accept_charset_mismatch = try std.fmt.parseInt(u2, it.next().?, 10);
            cfg.ignore_accept_encoding_mismatch = try std.fmt.parseInt(u2, it.next().?, 10);
            cfg.ignore_accept_language_mismatch = try std.fmt.parseInt(u2, it.next().?, 10);
            cfg.global_user_agent_header = !std.mem.eql(u8, it.next().?, "0");
        } else if (line.len > 2 and line[1] == ' ' and std.mem.indexOfScalar(u8, "crs", line[0]) != null) {
            const side = std.mem.indexOfScalar(u8, "crs", line[0]).?;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
            try sides[side].append(arena, .{
                .name = try unescapeInto(arena, line[2..tab]),
                .value = try unescapeInto(arena, if (tab < line.len) line[tab + 1 ..] else ""),
            });
        } else if (std.mem.startsWith(u8, line, "date ")) {
            date_text = try unescapeInto(arena, line[5..]);
        } else if (std.mem.startsWith(u8, line, "= ") and date_text.len + 1 > 0 and std.mem.indexOfScalar(u8, line[2..], ' ') == null) {
            dates += 1;
            const want = try std.fmt.parseInt(i64, line[2..], 10);
            const got = parseDate(date_text);
            if (got != want) {
                failures += 1;
                std.debug.print("date '{s}': ATS {d}, cyclone {d}\n", .{ date_text, want, got });
            }
        } else if (std.mem.startsWith(u8, line, "= ")) {
            cases += 1;
            const c = sides[0].items;
            const r = sides[1].items;
            const s = sides[2].items;
            var it = std.mem.tokenizeScalar(u8, line[2..], ' ');
            const m = quality(cfg, c, r, s);
            var got: [9]f32 = undefined;
            got[0] = m.quality;
            // The harness calls CalcVariability whatever the quality.
            var vm: Match = .{};
            variability(cfg, c, r, s, &vm);
            got[1] = @floatFromInt(@backingInt(vm.variability));
            const accept = first(c, "Accept");
            const ctype = first(s, "Content-Type");
            got[2] = if (accept != null and ctype != null) acceptQuality(accept.?, ctype.?) else std.math.nan(f32);
            got[3] = charsetQuality(first(c, "Accept-Charset"), ctype, first(r, "Accept-Charset"));
            got[4] = encodingQuality(first(c, "Accept-Encoding"), first(s, "Content-Encoding"), first(r, "Accept-Encoding"));
            got[5] = languageQuality(first(c, "Accept-Language"), first(s, "Content-Language"), first(r, "Accept-Language"));
            for ([_][]const u8{ "gzip", "br", "zstd" }, 6..) |enc, k| got[k] = if (acceptsEncoding(first(c, "Accept-Encoding"), enc)) 1 else 0;
            const names = [_][]const u8{ "Q", "variability", "accept", "charset", "encoding", "language", "gzip", "br", "zstd" };
            for (got, names) |g, n| {
                const text = it.next().?;
                const want: f32 = if (std.mem.eql(u8, text, "-")) std.math.nan(f32) else try std.fmt.parseFloat(f32, text);
                const same = (std.math.isNan(want) and std.math.isNan(g)) or want == g;
                if (!same) {
                    failures += 1;
                    if (failures <= 20) std.debug.print("{s}: {s}: ATS {s}, cyclone {d}\n", .{ case_name, n, text, g });
                }
            }
        }
    }
    try testing.expect(cases >= 500);
    try testing.expect(dates >= 20);
    try testing.expectEqual(@as(usize, 0), failures);
}
