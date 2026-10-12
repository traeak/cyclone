//! HTTP/1.1 transport for `service.zig`, on `std.http.Server`: keep-alive,
//! HEAD, and bodies pulled from the service's `BodyReader` straight into
//! the connection's output buffer.
//!
//! Routes (GET or HEAD; KEY is a cache key in hex, U a cache-key URL,
//! percent-encoded):
//!
//!   /v1/key?url=U                   {"input", "key"}
//!   /v1/lookup/KEY, ?url=U          the directory probe (cyc-lookup --json)
//!   /v1/object/KEY, ?url=U          the object report (cyc-doc object --json);
//!                                   &alt=N, &range=SPEC
//!   /v1/body/KEY, ?url=U            the body, with the stored response header;
//!                                   &alt=N; honours Range and If-Range
//!   /v1/stripes, /v1/stripes/S:B    stripe headers and geometry (cyc-doc stripe
//!                                   --json); &stats=1 adds directory statistics
//!   /v1/dir, /v1/dir/S:B            directory entries in use, one JSON line each,
//!                                   streamed; &segment=N &docs=1 &heads=1 &valid=1
//!
//! Without `alt`, the alternate is chosen as ATS would for this request's
//! own header fields.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const service = @import("service.zig");
const Field = @import("format/http.zig").Field;

pub const Options = struct {
    /// Log one line per request to stderr.
    access_log: bool = false,
};

const read_buffer_len = 16 * 1024;
const write_buffer_len = 64 * 1024;
const body_buffer_len = 64 * 1024;

/// Serves one connection until the client closes it or an error ends it.
/// Closes `stream`.
pub fn serveConnection(svc: *service.Service, io: Io, stream: net.Stream, options: Options) void {
    defer stream.close(io);
    const gpa = svc.cache.gpa;
    const buffers = gpa.alloc(u8, read_buffer_len + write_buffer_len + body_buffer_len) catch return;
    defer gpa.free(buffers);
    var in = stream.reader(io, buffers[0..read_buffer_len]);
    var out = stream.writer(io, buffers[read_buffer_len..][0..write_buffer_len]);
    const body_buffer = buffers[read_buffer_len + write_buffer_len ..];
    var server: std.http.Server = .init(&in.interface, &out.interface);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    while (true) {
        _ = arena_state.reset(.retain_capacity);
        var request = server.receiveHead() catch |err| {
            const status: ?[]const u8 = switch (err) {
                error.HttpHeadersOversize => "431 Request Header Fields Too Large",
                error.HttpHeadersInvalid => "400 Bad Request",
                else => null, // closed, or a read error: nothing to answer
            };
            if (status) |s| {
                out.interface.print("HTTP/1.1 {s}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n", .{s}) catch {};
                out.interface.flush() catch {};
            }
            return;
        };
        const keep_alive = handle(svc, io, arena_state.allocator(), &request, body_buffer, options) catch |err| {
            std.debug.print("cyclone-d: connection closed: {s}\n", .{@errorName(err)});
            return;
        };
        if (!keep_alive) return;
    }
}

/// Answers one request. Returns whether the connection may be reused.
fn handle(svc: *service.Service, io: Io, arena: std.mem.Allocator, request: *std.http.Server.Request, body_buffer: []u8, options: Options) !bool {
    const start = Io.Clock.awake.now(io);
    const method = request.head.method;
    const target = try arena.dupe(u8, request.head.target);
    const keep_alive = request.head.keep_alive;

    var resp: service.Response = undefined;
    if (method != .GET and method != .HEAD) {
        resp = try plain(arena, 405, "only GET and HEAD\n");
        resp.fields = &.{.{ .name = "Allow", .value = "GET, HEAD" }};
    } else switch (try route(arena, target, request)) {
        .request => |req| resp = try svc.handle(arena, req),
        .not_found => resp = try plain(arena, 404, help),
        .bad => |why| resp = try plain(arena, 400, why),
    }

    const len = resp.length() orelse 0;
    try send(arena, request, resp, body_buffer, keep_alive);
    if (options.access_log) {
        const us = start.durationTo(Io.Clock.awake.now(io)).toMicroseconds();
        std.debug.print("{s} {s} {d} {d} {d}us\n", .{ @tagName(method), target, resp.status, len, us });
    }
    return keep_alive;
}

const help =
    \\cyclone-d: read-only access to an ATS cache
    \\
    \\  GET /v1/key?url=U
    \\  GET /v1/lookup/KEY        or ?url=U
    \\  GET /v1/object/KEY        or ?url=U    [&alt=N] [&range=SPEC]
    \\  GET /v1/body/KEY          or ?url=U    [&alt=N]    (Range, If-Range)
    \\  GET /v1/stripes[/S:B]     [?stats=1]
    \\  GET /v1/dir[/S:B]         [?segment=N] [&docs=1] [&heads=1] [&valid=1]   (JSON lines)
    \\
    \\KEY is a cache key in hex; U a cache-key URL, percent-encoded. Without alt,
    \\the alternate is chosen as ATS would for this request's header fields.
    \\
;

const Routed = union(enum) {
    request: service.Request,
    not_found,
    /// A bad query parameter.
    bad: []const u8,
};

/// Maps a request target to a service request.
fn route(arena: std.mem.Allocator, target: []const u8, request: *std.http.Server.Request) !Routed {
    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. q orelse target.len];
    const query = if (q) |i| target[i + 1 ..] else "";

    const scans = [_]struct { []const u8, service.Op }{ .{ "/v1/stripes", .stripes }, .{ "/v1/dir", .dir } };
    for (scans) |o| {
        if (!std.mem.startsWith(u8, path, o[0])) continue;
        const rest = path[o[0].len..];
        var req: service.Request = .{ .op = o[1], .target = "" };
        if (rest.len > 1 and rest[0] == '/') {
            req.stripe = parseStripe(rest[1..]) orelse
                return .{ .bad = try std.fmt.allocPrint(arena, "bad stripe '{s}': want SPAN:BLOCK, as /v1/stripes lists them\n", .{rest[1..]}) };
        } else if (rest.len != 0) {
            continue;
        }
        var params = std.mem.splitScalar(u8, query, '&');
        while (params.next()) |p| {
            if (p.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, p, '=') orelse p.len;
            const name = p[0..eq];
            const value = if (eq < p.len) p[eq + 1 ..] else "";
            if (std.mem.eql(u8, name, "segment")) {
                req.segment = std.fmt.parseInt(u64, value, 10) catch
                    return .{ .bad = try std.fmt.allocPrint(arena, "bad segment '{s}'\n", .{value}) };
                continue;
            }
            const flag = if (std.mem.eql(u8, name, "stats"))
                &req.stats
            else if (std.mem.eql(u8, name, "docs"))
                &req.docs
            else if (std.mem.eql(u8, name, "heads"))
                &req.heads_only
            else if (std.mem.eql(u8, name, "valid"))
                &req.valid_only
            else
                return .{ .bad = try std.fmt.allocPrint(arena, "unknown parameter '{s}'\n", .{name}) };
            flag.* = parseFlag(value) orelse
                return .{ .bad = try std.fmt.allocPrint(arena, "bad {s} '{s}': want 1 or 0\n", .{ name, value }) };
        }
        return .{ .request = req };
    }

    const ops = [_]struct { []const u8, service.Op }{
        .{ "/v1/key", .key },       .{ "/v1/lookup", .lookup },
        .{ "/v1/object", .object }, .{ "/v1/body", .body },
    };
    for (ops) |o| {
        const prefix = o[0];
        if (!std.mem.startsWith(u8, path, prefix)) continue;
        const rest = path[prefix.len..];
        var req: service.Request = .{ .op = o[1], .target = "" };
        if (rest.len > 1 and rest[0] == '/' and o[1] != .key) {
            req.target = try percentDecode(arena, rest[1..]);
            req.key_only = true;
        } else if (rest.len != 0) {
            continue;
        }
        var params = std.mem.splitScalar(u8, query, '&');
        while (params.next()) |p| {
            const eq = std.mem.indexOfScalar(u8, p, '=') orelse p.len;
            const name = p[0..eq];
            const value = try percentDecode(arena, if (eq < p.len) p[eq + 1 ..] else "");
            if (std.mem.eql(u8, name, "url")) {
                req.target = value;
                req.key_only = false;
            } else if (std.mem.eql(u8, name, "alt")) {
                req.alt = std.fmt.parseInt(usize, value, 10) catch
                    return .{ .bad = try std.fmt.allocPrint(arena, "bad alt '{s}': want an alternate index\n", .{value}) };
            } else if (std.mem.eql(u8, name, "range")) {
                req.range = value;
            }
        }
        var fields: std.ArrayList(Field) = .empty;
        var it = request.iterateHeaders();
        while (it.next()) |h| try fields.append(arena, .{ .name = try arena.dupe(u8, h.name), .value = try arena.dupe(u8, h.value) });
        req.fields = fields.items;
        if (req.target.len == 0) return .{ .bad = "no KEY in the path and no url parameter\n" };
        return .{ .request = req };
    }
    return .not_found;
}

/// SPAN:BLOCK, both 0-based.
fn parseStripe(text: []const u8) ?[2]usize {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    return .{
        std.fmt.parseInt(usize, text[0..colon], 10) catch return null,
        std.fmt.parseInt(usize, text[colon + 1 ..], 10) catch return null,
    };
}

/// A flag parameter: present without a value, 1 or true; or 0 or false.
fn parseFlag(value: []const u8) ?bool {
    if (value.len == 0 or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false")) return false;
    return null;
}

/// Decodes `%XX`; leaves `+` alone, since cache-key URLs may contain it.
fn percentDecode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                out[n] = b;
                n += 1;
                i += 2;
                continue;
            } else |_| {}
        }
        out[n] = s[i];
        n += 1;
    }
    return out[0..n];
}

fn plain(arena: std.mem.Allocator, status: u16, text: []const u8) !service.Response {
    _ = arena;
    return .{ .status = status, .body = .{ .bytes = text } };
}

fn send(arena: std.mem.Allocator, request: *std.http.Server.Request, resp: service.Response, body_buffer: []u8, keep_alive: bool) !void {
    const status: std.http.Status = @fromBackingInt(@intCast(resp.status));
    const headers = try arena.alloc(std.http.Header, resp.fields.len);
    for (resp.fields, headers) |f, *h| h.* = .{ .name = f.name, .value = f.value };
    const respond_options: std.http.Server.Request.RespondOptions = .{
        .status = status,
        .reason = resp.reason,
        .keep_alive = keep_alive,
        .extra_headers = headers,
    };
    switch (resp.body) {
        .empty => try request.respond("", respond_options),
        .bytes => |b| try request.respond(b, respond_options),
        .stream => |body| {
            // An unknown length goes chunked.
            var bw = try request.respondStreaming(body_buffer, .{
                .content_length = body.len,
                .respond_options = respond_options,
            });
            if (bw.isEliding()) {
                // HEAD: the writer counts a known length off without
                // sending, and nothing is read.
                if (body.len) |len| try bw.writer.splatByteAll(0, @intCast(len));
            } else {
                // Pull straight into the body writer's buffer.
                var sent: u64 = 0;
                while (true) {
                    const dest = try bw.writer.writableSliceGreedy(1);
                    const n = try body.read(dest);
                    if (n == 0) break;
                    bw.writer.advance(n);
                    sent += n;
                }
                if (body.len) |len| if (sent != len) return error.Truncated;
            }
            try bw.end();
        },
    }
}

test "percent decoding" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("http://h/p?a=1&b=2", try percentDecode(a, "http%3A%2F%2Fh%2Fp%3Fa%3D1%26b%3D2"));
    try std.testing.expectEqualStrings("a+b%zz%4", try percentDecode(a, "a+b%zz%4"));
}
