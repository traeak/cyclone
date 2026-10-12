//! The service's operations, independent of the transport: a `Request`
//! names an operation and its inputs, and `Service.handle` answers with a
//! `Response` whose body is either bytes (JSON) or a `BodyReader` the
//! transport pulls from as fast as it can send. HTTP/1.1 is the first
//! transport (`http_server.zig`); HTTP/2 would map the same pulls onto its
//! flow-control window.
//!
//! The cache is read as it is on disk: nothing else may write the spans
//! while the service runs.

const std = @import("std");
const Io = std.Io;
const Cache = @import("cache.zig").Cache;
const CacheKey = @import("key.zig").CacheKey;
const url_mod = @import("url.zig");
const http = @import("format/http.zig");
const Field = http.Field;
const object = @import("object.zig");
const report = @import("report.zig");
const select = @import("select.zig");

pub const Op = enum {
    /// The cache key of a cache-key URL.
    key,
    /// Where a key is in the directory, each tag match checked against its
    /// Doc (as `cyc-lookup --json`).
    lookup,
    /// An object's head, alternates, the chosen alternate's fragments and
    /// any problem (as `cyc-doc object --json`).
    object,
    /// The chosen alternate's body, with its stored response header.
    body,
};

pub const Request = struct {
    op: Op,
    /// A key in hex, or (unless `key_only`) a cache-key URL.
    target: []const u8,
    /// `target` must be a key in hex.
    key_only: bool = false,
    /// The alternate to read; null chooses one as ATS would for a GET with
    /// `fields`.
    alt: ?usize = null,
    /// The caller's request header fields: they choose the alternate, and
    /// for `body` carry Range and If-Range.
    fields: []const Field = &.{},
    /// `object`: a range to report on, as in an HTTP Range header.
    range: ?[]const u8 = null,
};

pub const Response = struct {
    status: u16,
    reason: ?[]const u8 = null,
    /// Header fields besides the length.
    fields: []const Field = &.{},
    body: Body = .empty,

    pub const Body = union(enum) {
        empty,
        bytes: []const u8,
        /// Exactly `reader.remaining()` bytes.
        stream: *object.BodyReader,
    };

    pub fn length(r: *const Response) u64 {
        return switch (r.body) {
            .empty => 0,
            .bytes => |b| b.len,
            .stream => |s| s.remaining(),
        };
    }
};

pub const Service = struct {
    cache: *Cache,
    select_config: select.Config = .{},

    /// Answers `req`. Everything the response points to, including a body
    /// stream, is allocated with `arena`, which must outlive the response.
    pub fn handle(svc: *Service, arena: std.mem.Allocator, req: Request) !Response {
        const hash_type = svc.cache.config.hash_type;
        const key = parseKey(hash_type, req.target, req.key_only) orelse return if (req.key_only)
            jsonError(arena, 400, "'{s}' is not a cache key ({d} hex digits)", .{ req.target, hash_type.keyLen() * 2 })
        else
            jsonError(arena, 400, "'{s}' is not a key, and not a cache-key URL that parses", .{req.target});
        return switch (req.op) {
            .key => json(arena, 200, .{ .input = req.target, .key = try std.fmt.allocPrint(arena, "{f}", .{key}) }),
            .lookup => json(arena, 200, try report.lookup(arena, svc.cache, &key, req.target, null)),
            .object => svc.objectInfo(arena, req, &key),
            .body => svc.body(arena, req, &key),
        };
    }

    fn query(svc: *Service, req: Request, range: ?object.RangeSpec) report.ObjectQuery {
        return .{
            .alt = req.alt orelse 0,
            .select = req.alt == null,
            .request = req.fields,
            .select_config = svc.select_config,
            .now = Io.Clock.real.now(svc.cache.io).toSeconds(),
            .range = range,
        };
    }

    fn objectInfo(svc: *Service, arena: std.mem.Allocator, req: Request, key: *const CacheKey) !Response {
        var range: ?object.RangeSpec = null;
        if (req.range) |text| range = object.RangeSpec.parse(text) catch
            return jsonError(arena, 400, "bad range '{s}': want FIRST-LAST, FIRST- or -SUFFIX (one range)", .{text});
        const res = try report.readObject(arena, svc.cache, key, req.target, svc.query(req, range));
        return json(arena, 200, res.report);
    }

    fn body(svc: *Service, arena: std.mem.Allocator, req: Request, key: *const CacheKey) !Response {
        // A Range this cannot serve (several ranges, bad syntax) is ignored,
        // as RFC 9110 allows: the whole body is sent.
        var range: ?object.RangeSpec = null;
        if (first(req.fields, "Range")) |text| range = object.RangeSpec.parse(text) catch null;

        const res = try arena.create(report.ObjectResult);
        res.* = try report.readObject(arena, svc.cache, key, req.target, svc.query(req, range));
        const r = &res.report;
        switch (res.outcome) {
            .read => {},
            .miss => return jsonErrorCache(arena, 404, "miss", r),
            .no_match => return jsonErrorCache(arena, 404, "no-match", r),
            .no_such_alternate => return jsonErrorCache(arena, 404, "no-such-alternate", r),
            .bad_head, .bad_chain => return jsonErrorCache(arena, 500, "error", r),
            .unsatisfiable => {
                // The range applies only to a stored 200 that If-Range lets
                // through; otherwise this is the whole body.
                if (!rangeApplies(&res.head.?, r, req.fields)) return svc.wholeBody(arena, req, key, res);
                const size = report.objectSize(&res.head.?, r.selected orelse 0);
                const fields = try arena.alloc(Field, 3);
                fields[0] = .{ .name = "Content-Range", .value = try std.fmt.allocPrint(arena, "bytes */{d}", .{size}) };
                fields[1] = json_type[0];
                fields[2] = .{ .name = "X-Cyclone-Cache", .value = "hit" };
                return .{ .status = 416, .fields = fields, .body = .{ .bytes = try stringify(arena, .{ .@"error" = r.error_message.? }) } };
            },
        }
        if (range != null and !rangeApplies(&res.head.?, r, req.fields)) return svc.wholeBody(arena, req, key, res);
        return bodyResponse(arena, svc.cache, res, range != null);
    }

    /// Reads the alternate already chosen again, without the range.
    fn wholeBody(svc: *Service, arena: std.mem.Allocator, req: Request, key: *const CacheKey, res: *report.ObjectResult) !Response {
        var q = svc.query(req, null);
        q.alt = res.report.selected orelse 0;
        q.select = false;
        res.* = try report.readObject(arena, svc.cache, key, req.target, q);
        if (res.outcome != .read) return jsonErrorCache(arena, 500, "error", &res.report);
        return bodyResponse(arena, svc.cache, res, false);
    }
};

/// Whether a Range may be applied: the stored response is a 200, and any
/// If-Range matches its strong ETag or its Last-Modified exactly.
fn rangeApplies(head: *const object.Head, r: *const report.ObjectReport, fields: []const Field) bool {
    if (head.alternates.len == 0) return true;
    const resp = head.alternates[r.selected orelse return false].response orelse return false;
    if (resp.status != 200) return false;
    const if_range = first(fields, "If-Range") orelse return true;
    if (resp.get("ETag")) |etag| {
        if (!std.mem.startsWith(u8, etag, "W/") and std.mem.eql(u8, etag, if_range)) return true;
    }
    if (resp.get("Last-Modified")) |lm| return std.mem.eql(u8, lm, if_range);
    return false;
}

/// Hop-by-hop fields and those the transport sets: not copied from the
/// stored response.
const not_copied = [_][]const u8{
    "Connection",     "Keep-Alive",    "Proxy-Connection", "Transfer-Encoding", "TE", "Trailer", "Upgrade",
    "Content-Length", "Content-Range",
};

fn bodyResponse(arena: std.mem.Allocator, cache: *Cache, res: *report.ObjectResult, ranged: bool) !Response {
    const r = &res.report;
    const head = &res.head.?;
    const c = res.chain.?;
    if (!c.complete) return jsonErrorCache(arena, 404, "incomplete", r);

    var fields: std.ArrayList(Field) = .empty;
    var status: u16 = 200;
    var reason: ?[]const u8 = null;
    if (c.alternate) |i| if (head.alternates[i].response) |resp| {
        status = @intCast(@max(0, resp.status));
        reason = resp.reason;
        for (resp.fields) |f| {
            const skip = for (not_copied) |n| {
                if (std.ascii.eqlIgnoreCase(f.name, n)) break true;
            } else false;
            if (!skip) try fields.append(arena, f);
        }
    };
    if (ranged) {
        status = 206;
        reason = "Partial Content";
        try fields.append(arena, .{
            .name = "Content-Range",
            .value = try std.fmt.allocPrint(arena, "bytes {d}-{d}/{d}", .{ c.range.start, c.range.end - 1, c.object_size }),
        });
    }
    try fields.append(arena, .{ .name = "X-Cyclone-Cache", .value = "hit" });
    try fields.append(arena, .{ .name = "X-Cyclone-Key", .value = r.key });
    if (c.alternate) |i| try fields.append(arena, .{ .name = "X-Cyclone-Alternate", .value = try std.fmt.allocPrint(arena, "{d}", .{i}) });

    const reader = try arena.create(object.BodyReader);
    reader.* = .init(cache, head, c);
    return .{ .status = status, .reason = reason, .fields = fields.items, .body = .{ .stream = reader } };
}

fn parseKey(hash_type: @import("hash.zig").HashType, text: []const u8, key_only: bool) ?CacheKey {
    if (text.len == hash_type.keyLen() * 2) {
        if (CacheKey.parseHex(hash_type, text)) |k| return k else |_| {}
    }
    if (key_only) return null;
    return url_mod.cacheKey(text, hash_type, .{}) catch null;
}

fn first(fields: []const Field, name: []const u8) ?[]const u8 {
    for (fields) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value;
    return null;
}

fn stringify(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.written();
}

const json_type = [_]Field{.{ .name = "Content-Type", .value = "application/json" }};

fn json(arena: std.mem.Allocator, status: u16, value: anytype) !Response {
    return .{ .status = status, .fields = &json_type, .body = .{ .bytes = try stringify(arena, value) } };
}

fn jsonError(arena: std.mem.Allocator, status: u16, comptime fmt: []const u8, args: anytype) !Response {
    return json(arena, status, .{ .@"error" = try std.fmt.allocPrint(arena, fmt, args) });
}

/// A body request that cannot be served from the cache: the object report
/// says why, and X-Cyclone-Cache names the reason.
fn jsonErrorCache(arena: std.mem.Allocator, status: u16, why: []const u8, r: *const report.ObjectReport) !Response {
    const fields = try arena.alloc(Field, 2);
    fields[0] = json_type[0];
    fields[1] = .{ .name = "X-Cyclone-Cache", .value = why };
    return .{ .status = status, .fields = fields, .body = .{ .bytes = try stringify(arena, r.*) } };
}
