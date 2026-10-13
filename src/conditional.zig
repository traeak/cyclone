//! Conditional requests against a cached response, as ATS answers them
//! from the cache (`HttpTransactCache::match_response_to_request_conditionals`
//! and `validate_ifrange_header_if_any` in HttpTransactCache.cc):
//!
//! - If-None-Match, when the response has an ETag, compares weakly: a match
//!   is 304, no match serves the response, and If-Modified-Since is not
//!   looked at.
//! - If-Modified-Since against Last-Modified (else Date, else the time the
//!   response was received): not newer is 304.
//! - If-Match compares strongly (a weak or missing ETag matches only `*`):
//!   no match is 412.
//! - If-Unmodified-Since against Last-Modified: newer, or no
//!   Last-Modified, is 412.
//!
//! As in ATS, only the first field of each name counts, and dates are read
//! by `mime_parse_date` (`select.parseDate`).

const std = @import("std");
const http = @import("format/http.zig");
const Field = http.Field;
const select = @import("select.zig");

/// What a conditional request comes to.
pub fn evaluate(request: []const Field, response: []const Field, status: u16, received_time: i64) u16 {
    const inm = select.first(request, "If-None-Match");
    const ims = select.first(request, "If-Modified-Since");
    const im = select.first(request, "If-Match");
    const ius = select.first(request, "If-Unmodified-Since");
    if (inm == null and ims == null and im == null and ius == null) return status;

    if (inm) |list| {
        if (select.first(response, "ETag")) |etag| if (etag.len != 0) {
            return if (matchWeakly(etag, list)) 304 else status;
        };
    }

    var code: ?u16 = null;
    if (ims) |text| {
        const since = select.parseDate(text);
        const reference = if (select.first(response, "Last-Modified")) |lm|
            select.parseDate(lm)
        else if (select.first(response, "Date")) |d|
            select.parseDate(d)
        else
            null;
        if (reference) |t| {
            // Not 304 when the reference time is too recent, or unreadable.
            if (t == 0 or since < t) return status;
        } else if (since < received_time) {
            return status;
        }
        code = 304;
    }
    if (code) |c| return c;

    if (im) |list| {
        return if (matchStrongly(select.first(response, "ETag") orelse "", list)) status else 412;
    }

    if (ius) |text| {
        const lm = if (select.first(response, "Last-Modified")) |v| select.parseDate(v) else 0;
        if (select.parseDate(text) < lm or lm == 0) return 412;
    }
    return status;
}

/// Whether a Range may be honoured: no If-Range, or one that is a strong
/// match for the ETag (when it looks like an ETag) or exactly the
/// Last-Modified date.
pub fn ifRangeValid(request: []const Field, response: []const Field) bool {
    const value = select.first(request, "If-Range") orelse return true;
    if (value.len == 0 or value[0] == '"' or (value.len > 1 and value[1] == '/')) {
        return matchStrongly(select.first(response, "ETag") orelse "", value);
    }
    const lm = if (select.first(response, "Last-Modified")) |v| select.parseDate(v) else 0;
    return select.parseDate(value) == lm and lm != 0;
}

/// The cached response fields a 304 carries (`HttpTransact::build_response`,
/// after RFC 2616 10.3.5), besides a new Date.
pub const not_modified_fields = [_][]const u8{ "ETag", "Content-Location", "Expires", "Cache-Control", "Vary" };

/// `find_etag`: the tag without a leading `W/` and its quotes (up to the
/// next quote).
fn findEtag(raw: []const u8) []const u8 {
    var t = raw;
    if (t.len >= 2 and t[0] == 'W' and t[1] == '/') t = t[2..];
    if (t.len != 0 and t[0] == '"') {
        t = t[1..];
        if (std.mem.indexOfScalar(u8, t, '"')) |q| t = t[0..q];
    }
    return t;
}

/// `do_strings_match_strongly`: the response tag equals one in the list
/// as written; a weak or missing tag matches only `*`.
fn matchStrongly(raw: []const u8, list: []const u8) bool {
    const only_star = raw.len == 0 or (raw.len >= 2 and raw[0] == 'W' and raw[1] == '/');
    const etag = findEtag(raw);
    var it = select.tokens(list, ',');
    while (it.next()) |tag| {
        if (std.mem.eql(u8, tag, "*")) return true;
        if (only_star) continue;
        if (std.mem.eql(u8, tag, etag)) return true;
    }
    return false;
}

/// `do_strings_match_weakly`: both tags compared without `W/` and quotes.
fn matchWeakly(raw: []const u8, list: []const u8) bool {
    const etag = findEtag(raw);
    var it = select.tokens(list, ',');
    while (it.next()) |tag| {
        if (std.mem.eql(u8, tag, "*")) return true;
        if (std.mem.eql(u8, findEtag(tag), etag)) return true;
    }
    return false;
}

/// An IMF-fixdate (RFC 9110 5.6.7), as a Date field carries it.
pub fn formatDate(buf: *[29]u8, secs: i64) []const u8 {
    const days = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, secs)) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        days[@intCast(day.day % 7)], @as(u32, md.day_index) + 1, months[md.month.numeric() - 1],
        yd.year,                     ds.getHoursIntoDay(),       ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

const testing = std.testing;

test "etag matching, strong and weak" {
    try testing.expect(matchWeakly("\"abc\"", "\"x\", \"abc\""));
    try testing.expect(matchWeakly("W/\"abc\"", "\"abc\""));
    try testing.expect(matchWeakly("\"abc\"", "W/\"abc\""));
    try testing.expect(!matchWeakly("\"abc\"", "\"abd\""));
    try testing.expect(matchWeakly("\"abc\"", "*"));
    try testing.expect(matchStrongly("\"abc\"", "\"abc\""));
    try testing.expect(!matchStrongly("\"abc\"", "W/\"abc\""));
    try testing.expect(!matchStrongly("W/\"abc\"", "\"abc\""));
    try testing.expect(matchStrongly("W/\"abc\"", "*"));
    try testing.expect(!matchStrongly("", "\"\""));
}

test "conditionals" {
    const resp = [_]Field{
        .{ .name = "ETag", .value = "\"v1\"" },
        .{ .name = "Last-Modified", .value = "Mon, 05 Oct 2026 12:00:00 GMT" },
    };
    const t = 1791201600; // Last-Modified
    const f = struct {
        fn one(name: []const u8, value: []const u8) [1]Field {
            return .{.{ .name = name, .value = value }};
        }
    }.one;
    try testing.expectEqual(200, evaluate(&.{}, &resp, 200, t));
    try testing.expectEqual(304, evaluate(&f("If-None-Match", "\"v1\""), &resp, 200, t));
    try testing.expectEqual(200, evaluate(&f("If-None-Match", "\"v2\""), &resp, 200, t));
    try testing.expectEqual(304, evaluate(&f("If-Modified-Since", "Mon, 05 Oct 2026 12:00:00 GMT"), &resp, 200, t));
    try testing.expectEqual(200, evaluate(&f("If-Modified-Since", "Sun, 04 Oct 2026 12:00:00 GMT"), &resp, 200, t));
    try testing.expectEqual(200, evaluate(&f("If-Match", "\"v1\""), &resp, 200, t));
    try testing.expectEqual(412, evaluate(&f("If-Match", "\"v2\""), &resp, 200, t));
    try testing.expectEqual(412, evaluate(&f("If-Unmodified-Since", "Sun, 04 Oct 2026 12:00:00 GMT"), &resp, 200, t));
    try testing.expectEqual(404, evaluate(&f("If-Match", "\"v1\""), &resp, 404, t));
    try testing.expect(ifRangeValid(&f("If-Range", "\"v1\""), &resp));
    try testing.expect(!ifRangeValid(&f("If-Range", "W/\"v1\""), &resp));
    try testing.expect(ifRangeValid(&f("If-Range", "Mon, 05 Oct 2026 12:00:00 GMT"), &resp));
    try testing.expect(!ifRangeValid(&f("If-Range", "Mon, 05 Oct 2026 12:00:01 GMT"), &resp));
}

test "http dates" {
    var buf: [29]u8 = undefined;
    try testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", formatDate(&buf, 784111777));
    try testing.expectEqualStrings("Mon, 05 Oct 2026 12:00:00 GMT", formatDate(&buf, 1791201600));
}

test "matches ATS on the conditional cases in testdata/select_golden.txt" {
    // Made by tools/ats-httpinfo (selectq.cc on gen-select-cases.py).
    const golden = @embedFile("testdata/select_golden.txt");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var in_cond = false;
    var name: []const u8 = "";
    var request: std.ArrayList(Field) = .empty;
    var response: std.ArrayList(Field) = .empty;
    var received: i64 = 0;
    var status: u16 = 0;
    var cases: usize = 0;
    var failures: usize = 0;
    var lines = std.mem.splitScalar(u8, golden, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "cond ")) {
            in_cond = true;
            name = line;
            request.clearRetainingCapacity();
            response.clearRetainingCapacity();
        } else if (std.mem.startsWith(u8, line, "case ")) {
            in_cond = false;
        } else if (!in_cond) {
            continue;
        } else if (std.mem.startsWith(u8, line, "recv ")) {
            var it = std.mem.tokenizeScalar(u8, line[5..], ' ');
            received = try std.fmt.parseInt(i64, it.next().?, 10);
            status = try std.fmt.parseInt(u16, it.next().?, 10);
        } else if (line.len > 2 and (line[0] == 'c' or line[0] == 's') and line[1] == ' ') {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
            const value = if (tab < line.len) try unescape(arena, line[tab + 1 ..]) else "";
            try (if (line[0] == 'c') &request else &response).append(arena, .{ .name = line[2..tab], .value = value });
        } else if (std.mem.startsWith(u8, line, "=c ")) {
            cases += 1;
            var it = std.mem.tokenizeScalar(u8, line[3..], ' ');
            const want_status = try std.fmt.parseInt(u16, it.next().?, 10);
            const want_range = std.mem.eql(u8, it.next().?, "1");
            const got_status = evaluate(request.items, response.items, status, received);
            const got_range = ifRangeValid(request.items, response.items);
            if (got_status != want_status or got_range != want_range) {
                failures += 1;
                if (failures <= 20) std.debug.print("{s}: ATS {d} {}, cyclone {d} {}\n", .{ name, want_status, want_range, got_status, got_range });
            }
        }
    }
    try testing.expect(cases >= 200);
    try testing.expectEqual(@as(usize, 0), failures);
}

fn unescape(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try out.append(arena, switch (s[i]) {
                't' => '\t',
                'n' => '\n',
                else => s[i],
            });
        } else {
            try out.append(arena, s[i]);
        }
    }
    return out.items;
}
