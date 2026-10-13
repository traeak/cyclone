//! The service's operations, independent of the transport: a `Request`
//! names an operation and its inputs, and `Service.handle` answers with a
//! `Response` whose body is either bytes (JSON) or a `Source` the transport
//! pulls from as fast as it can send: an object's body (`BodyReader`), or a
//! directory scan as JSON lines. HTTP/1.1 is the first
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
const dir = @import("dir.zig");
const Stripe = @import("stripe.zig").Stripe;
const hash = @import("hash.zig");
const conditional = @import("conditional.zig");

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
    /// Each stripe's headers, geometry and copy in use (as `cyc-doc stripe
    /// --json`), with directory statistics if asked for.
    stripes,
    /// The directory entries in use, one JSON line each (as `cyc-doc dir
    /// --entries --json`), streamed.
    dir,
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
    /// `stripes`, `dir`: only this stripe (span index, block index).
    stripe: ?[2]usize = null,
    /// `stripes`: walk each directory for statistics.
    stats: bool = false,
    /// `dir`: only this segment of each stripe.
    segment: ?u64 = null,
    /// `dir`: read each entry's Doc (one read per entry).
    docs: bool = false,
    /// `dir`: only head entries.
    heads_only: bool = false,
    /// `dir`: only entries ATS would trust.
    valid_only: bool = false,
};

/// A body the transport pulls from.
pub const Source = struct {
    ptr: *anyopaque,
    readFn: *const fn (ptr: *anyopaque, dest: []u8) anyerror!usize,
    /// The total length, or null when it is not known up front.
    len: ?u64,

    /// Fills up to `dest.len` bytes; 0 at the end.
    pub fn read(s: Source, dest: []u8) !usize {
        return s.readFn(s.ptr, dest);
    }

    fn ofBody(r: *object.BodyReader) Source {
        const read_body = struct {
            fn read(ptr: *anyopaque, dest: []u8) anyerror!usize {
                const br: *object.BodyReader = @ptrCast(@alignCast(ptr));
                return br.read(dest);
            }
        }.read;
        return .{ .ptr = r, .readFn = read_body, .len = r.remaining() };
    }
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
        stream: Source,
    };

    /// The body length, if known up front.
    pub fn length(r: *const Response) ?u64 {
        return switch (r.body) {
            .empty => 0,
            .bytes => |b| b.len,
            .stream => |s| s.len,
        };
    }
};

pub const Service = struct {
    cache: *Cache,
    select_config: select.Config = .{},

    /// Answers `req`. Everything the response points to, including a body
    /// stream, is allocated with `arena`, which must outlive the response.
    pub fn handle(svc: *Service, arena: std.mem.Allocator, req: Request) !Response {
        switch (req.op) {
            .stripes => return svc.stripes(arena, req),
            .dir => return svc.dirScan(arena, req),
            else => {},
        }
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
            .stripes, .dir => unreachable,
        };
    }

    /// The stripes `req` names: all of them, or `req.stripe`. Null when
    /// that stripe does not exist.
    fn targets(svc: *Service, arena: std.mem.Allocator, req: Request) !?[]const [2]usize {
        var list: std.ArrayList([2]usize) = .empty;
        for (svc.cache.spans, 0..) |span, si| {
            for (span.blocks, 0..) |b, bi| {
                if (b.free) continue;
                if (req.stripe) |want| if (want[0] != si or want[1] != bi) continue;
                try list.append(arena, .{ si, bi });
            }
        }
        if (req.stripe != null and list.items.len == 0) return null;
        return list.items;
    }

    fn stripes(svc: *Service, arena: std.mem.Allocator, req: Request) !Response {
        const cache = svc.cache;
        const list = try svc.targets(arena, req) orelse return noSuchStripe(arena, req.stripe.?);
        const reports = try arena.alloc(report.StripeReport, list.len);
        var buf: []u8 = &.{};
        for (list, reports) |t, *r| {
            const s = try cache.stripe(t[0], t[1]);
            r.* = try report.stripeReport(cache.gpa, cache.io, arena, t[0], s);
            if (req.stats and s.chosen != null) {
                if (s.entries == null and buf.len < dir.Segment.byteLen(s)) buf = try arena.alloc(u8, dir.Segment.byteLen(s));
                r.dir_stats = try report.dirStats(cache.gpa, cache.io, s, buf);
            }
        }
        if (req.stripe != null) return json(arena, 200, reports[0]);
        return json(arena, 200, reports);
    }

    fn dirScan(svc: *Service, arena: std.mem.Allocator, req: Request) !Response {
        const cache = svc.cache;
        const list = try svc.targets(arena, req) orelse return noSuchStripe(arena, req.stripe.?);
        var buf_len: usize = 0;
        for (list) |t| {
            const s = try cache.stripe(t[0], t[1]);
            if (req.stripe != null and s.chosen == null)
                return jsonError(arena, 404, "stripe {d}:{d} has no usable directory", .{ t[0], t[1] });
            if (req.segment) |seg| if (req.stripe != null and seg >= s.geometry.segments)
                return jsonError(arena, 404, "no segment {d}; stripe {d}:{d} has {d}", .{ seg, t[0], t[1], s.geometry.segments });
            if (s.chosen != null and s.entries == null) buf_len = @max(buf_len, dir.Segment.byteLen(s));
        }
        const scan = try arena.create(DirScan);
        scan.* = .{
            .cache = cache,
            .hash_type = cache.config.hash_type,
            .targets = list,
            .segment_only = req.segment,
            .docs = req.docs,
            .heads_only = req.heads_only,
            .valid_only = req.valid_only,
            .seg_buf = try arena.alloc(u8, buf_len),
        };
        const fields = try arena.alloc(Field, 1);
        fields[0] = .{ .name = "Content-Type", .value = "application/x-ndjson" };
        return .{ .status = 200, .fields = fields, .body = .{ .stream = .{ .ptr = scan, .readFn = DirScan.read, .len = null } } };
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
        switch (res.outcome) {
            .read, .unsatisfiable => {},
            .miss => return jsonErrorCache(arena, 404, "miss", &res.report),
            .no_match => return jsonErrorCache(arena, 404, "no-match", &res.report),
            .no_such_alternate => return jsonErrorCache(arena, 404, "no-such-alternate", &res.report),
            .bad_head, .bad_chain => return jsonErrorCache(arena, 500, "error", &res.report),
        }

        // As ATS answers from the cache (`build_response_from_cache`): the
        // conditionals first, then a range, only on a stored 200 that
        // If-Range lets through.
        const stored = storedResponse(&res.head.?, res.report.selected);
        const code = conditional.evaluate(req.fields, stored.fields, stored.status, stored.received);
        const ranged = range != null and code == 200 and conditional.ifRangeValid(req.fields, stored.fields);
        if (range != null and !ranged) {
            try svc.reread(arena, req, key, res);
            if (res.outcome != .read) return jsonErrorCache(arena, 500, "error", &res.report);
        }
        if (res.outcome == .unsatisfiable) {
            const size = report.objectSize(&res.head.?, res.report.selected orelse 0);
            const fields = try arena.alloc(Field, 3);
            fields[0] = .{ .name = "Content-Range", .value = try std.fmt.allocPrint(arena, "bytes */{d}", .{size}) };
            fields[1] = json_type[0];
            fields[2] = .{ .name = "X-Cyclone-Cache", .value = "hit" };
            return .{ .status = 416, .fields = fields, .body = .{ .bytes = try stringify(arena, .{ .@"error" = res.report.error_message.? }) } };
        }
        // What ATS could not read, it would not answer from the cache.
        if (!res.chain.?.complete) return jsonErrorCache(arena, 404, "incomplete", &res.report);
        switch (code) {
            304 => return notModified(arena, svc.cache.io, res, stored.fields),
            412 => {
                const fields = try arena.alloc(Field, 2);
                fields[0] = json_type[0];
                fields[1] = .{ .name = "X-Cyclone-Cache", .value = "hit" };
                return .{ .status = 412, .fields = fields, .body = .{ .bytes = try stringify(arena, .{ .@"error" = "a precondition (If-Match or If-Unmodified-Since) failed against the cached response" }) } };
            },
            else => return bodyResponse(arena, svc.cache, res, ranged),
        }
    }

    /// Reads the alternate already chosen again, without the range.
    fn reread(svc: *Service, arena: std.mem.Allocator, req: Request, key: *const CacheKey, res: *report.ObjectResult) !void {
        var q = svc.query(req, null);
        q.alt = res.report.selected orelse 0;
        q.select = false;
        res.* = try report.readObject(arena, svc.cache, key, req.target, q);
    }
};

/// Streams directory entries as JSON lines, one stripe, segment and bucket
/// after another. Allocates nothing per entry: each line is written into
/// `line`, and segments come from memory or are read into `seg_buf`.
const DirScan = struct {
    cache: *Cache,
    hash_type: hash.HashType,
    targets: []const [2]usize,
    segment_only: ?u64,
    docs: bool,
    heads_only: bool,
    valid_only: bool,
    seg_buf: []u8,

    /// Index into `targets` of the stripe being scanned.
    t: usize = 0,
    /// Segments of that stripe handed out so far.
    segs_done: u64 = 0,
    stripe: ?*Stripe = null,
    seg: ?dir.Segment = null,
    /// The next bucket of `seg` to walk.
    bucket: u64 = 0,
    chain: ?dir.ChainIterator = null,
    chain_bucket: u64 = 0,
    line: [2048]u8 = undefined,
    line_len: usize = 0,
    line_pos: usize = 0,

    fn read(ptr: *anyopaque, dest: []u8) anyerror!usize {
        const self: *DirScan = @ptrCast(@alignCast(ptr));
        while (self.line_pos == self.line_len) {
            if (!try self.nextLine()) return 0;
        }
        const n = @min(dest.len, self.line_len - self.line_pos);
        @memcpy(dest[0..n], self.line[self.line_pos..][0..n]);
        self.line_pos += n;
        return n;
    }

    /// Writes the next entry into `line`; false at the end.
    fn nextLine(self: *DirScan) !bool {
        while (true) {
            if (self.chain) |*it| {
                if (it.next()) |link| {
                    const s = self.stripe.?;
                    if (link.dir.isEmpty()) continue;
                    if (self.heads_only and !link.dir.head()) continue;
                    if (self.valid_only and !dir.entryValid(s, link.dir)) continue;
                    const e = try report.dirEntry(self.cache.io, s, self.hash_type, self.targets[self.t][0], self.seg.?.index, self.chain_bucket, link, self.docs);
                    var w: Io.Writer = .fixed(&self.line);
                    try std.json.Stringify.value(e, .{}, &w);
                    try w.writeByte('\n');
                    self.line_len = w.end;
                    self.line_pos = 0;
                    return true;
                }
                self.chain = null;
            }
            if (self.seg) |*seg| {
                if (self.bucket < seg.buckets) {
                    self.chain = seg.chain(self.bucket);
                    self.chain_bucket = self.bucket;
                    self.bucket += 1;
                    continue;
                }
                self.seg = null;
            }
            if (!try self.nextSegment()) return false;
        }
    }

    fn nextSegment(self: *DirScan) !bool {
        while (self.t < self.targets.len) {
            const t = self.targets[self.t];
            const s = try self.cache.stripe(t[0], t[1]);
            const segments = s.geometry.segments;
            var index: ?u64 = null;
            if (s.chosen != null) {
                if (self.segment_only) |only| {
                    if (self.segs_done == 0 and only < segments) index = only;
                } else if (self.segs_done < segments) {
                    index = self.segs_done;
                }
            }
            if (index) |i| {
                self.segs_done += 1;
                self.stripe = s;
                self.seg = try dir.Segment.get(self.cache.io, s, i, self.seg_buf);
                self.bucket = 0;
                return true;
            }
            self.t += 1;
            self.segs_done = 0;
        }
        return false;
    }
};

fn noSuchStripe(arena: std.mem.Allocator, which: [2]usize) !Response {
    return jsonError(arena, 404, "no stripe {d}:{d} (see /v1/stripes)", .{ which[0], which[1] });
}

const Stored = struct {
    fields: []const Field,
    status: u16,
    /// When ATS received the response (seconds).
    received: i64,
};

/// The stored response of alternate `alt` (a non-HTTP object: none, 200).
fn storedResponse(head: *const object.Head, alt: ?usize) Stored {
    const i = alt orelse return .{ .fields = &.{}, .status = 200, .received = 0 };
    const a = head.alternates[i];
    const resp = a.response orelse return .{ .fields = &.{}, .status = 200, .received = a.response_received_time };
    return .{ .fields = resp.fields, .status = @intCast(@max(0, resp.status)), .received = a.response_received_time };
}

/// A 304 as ATS builds it: a new Date, and the stored ETag,
/// Content-Location, Expires, Cache-Control and Vary (duplicates joined).
fn notModified(arena: std.mem.Allocator, io: Io, res: *report.ObjectResult, stored: []const Field) !Response {
    var fields: std.ArrayList(Field) = .empty;
    const date = try arena.create([29]u8);
    try fields.append(arena, .{ .name = "Date", .value = conditional.formatDate(date, Io.Clock.real.now(io).toSeconds()) });
    for (conditional.not_modified_fields) |name| {
        var value: std.ArrayList(u8) = .empty;
        var found = false;
        for (stored) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) {
            if (found) try value.appendSlice(arena, ", ");
            try value.appendSlice(arena, f.value);
            found = true;
        };
        if (found) try fields.append(arena, .{ .name = name, .value = value.items });
    }
    try fields.append(arena, .{ .name = "X-Cyclone-Cache", .value = "hit" });
    try fields.append(arena, .{ .name = "X-Cyclone-Key", .value = res.report.key });
    if (res.report.selected) |i| try fields.append(arena, .{ .name = "X-Cyclone-Alternate", .value = try std.fmt.allocPrint(arena, "{d}", .{i}) });
    return .{ .status = 304, .reason = "Not Modified", .fields = fields.items };
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
    return .{ .status = status, .reason = reason, .fields = fields.items, .body = .{ .stream = .ofBody(reader) } };
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
