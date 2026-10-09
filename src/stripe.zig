//! An open stripe: geometry, both directory copies' headers and footers,
//! and the copy ATS would use.

const std = @import("std");
const Io = std.Io;
const fmt = @import("format/stripe.zig");
const span_mod = @import("span.zig");
const span_fmt = @import("format/span.zig");
const Span = span_mod.Span;
const StripeBlock = span_mod.StripeBlock;
const Issue = span_mod.Issue;

pub const Geometry = fmt.Geometry;
pub const HeaderFooter = fmt.HeaderFooter;
pub const Copy = fmt.Copy;

/// Header and footer of one directory copy. Null when the bytes could not
/// be read (past the end of the span).
pub const CopyInfo = struct {
    header: ?HeaderFooter,
    footer: ?HeaderFooter,

    /// Header and footer both present with the stripe magic.
    pub fn magicOk(c: CopyInfo) bool {
        const h = c.header orelse return false;
        const f = c.footer orelse return false;
        return h.magic == fmt.stripe_magic and f.magic == fmt.stripe_magic;
    }
};

pub const Stripe = struct {
    span: *const Span,
    /// Index of this stripe's block in `span.blocks`.
    block_index: usize,
    block: StripeBlock,
    avg_obj_size: u32,
    geometry: Geometry,
    copies: [2]CopyInfo,
    /// The copy ATS would use, or null if it would clear the stripe.
    chosen: ?Copy,
    /// `freelist[segments]` of the chosen copy: head entry of each
    /// segment's free list. Empty when no copy is usable.
    freelist: []u16,

    /// Reads the stripe's directory headers and footers. Fails only on I/O
    /// errors; an unusable stripe opens with `chosen == null`.
    pub fn open(gpa: std.mem.Allocator, io: Io, span: *const Span, block_index: usize, avg_obj_size: u32) !Stripe {
        const block = span.blocks[block_index];
        const g = Geometry.compute(block.offset, block.byteLen(), avg_obj_size);

        var copies: [2]CopyInfo = undefined;
        for (&copies, [_]Copy{ .a, .b }) |*c, which| {
            c.* = .{
                .header = try readHeaderFooter(io, span, g.copyOffset(which)),
                .footer = try readHeaderFooter(io, span, g.footerOffset(which)),
            };
        }

        var chosen: ?Copy = null;
        if (copies[0].header != null and copies[0].footer != null and copies[1].header != null and copies[1].footer != null) {
            chosen = fmt.chooseCopy(copies[0].header.?.sync_serial, copies[0].footer.?.sync_serial, copies[1].header.?.sync_serial, copies[1].footer.?.sync_serial);
        }
        if (chosen) |c| {
            const info = copies[@intFromEnum(c)];
            if (!info.header.?.usable() or info.footer.?.magic != fmt.stripe_magic) chosen = null;
        }

        var freelist: []u16 = &.{};
        if (chosen) |c| {
            const raw = try gpa.alloc(u8, g.segments * 2);
            defer gpa.free(raw);
            if (try span.file.readPositionalAll(io, raw, g.copyOffset(c) + fmt.freelist_offset) != raw.len) return error.Truncated;
            freelist = try gpa.alloc(u16, g.segments);
            for (freelist, 0..) |*f, i| f.* = std.mem.readInt(u16, raw[i * 2 ..][0..2], .little);
        }

        return .{
            .span = span,
            .block_index = block_index,
            .block = block,
            .avg_obj_size = avg_obj_size,
            .geometry = g,
            .copies = copies,
            .chosen = chosen,
            .freelist = freelist,
        };
    }

    pub fn close(self: *Stripe, gpa: std.mem.Allocator) void {
        gpa.free(self.freelist);
        self.* = undefined;
    }

    /// Header of the copy in use.
    pub fn header(self: *const Stripe) ?HeaderFooter {
        const c = self.chosen orelse return null;
        return self.copies[@intFromEnum(c)].header;
    }

    /// The text ATS hashes to place this stripe.
    pub fn hashText(self: *const Stripe, w: *Io.Writer) Io.Writer.Error!void {
        try self.span.stripeHashText(w, self.block);
    }

    /// Consistency checks on the chosen header.
    pub fn check(self: *const Stripe, arena: std.mem.Allocator) ![]Issue {
        var issues: std.ArrayList(Issue) = .empty;
        const add = struct {
            fn f(list: *std.ArrayList(Issue), a: std.mem.Allocator, sev: Issue.Severity, comptime f_: []const u8, args: anytype) !void {
                try list.append(a, .{ .severity = sev, .message = try std.fmt.allocPrint(a, f_, args) });
            }
        }.f;

        const g = self.geometry;
        const a_header_ok = if (self.copies[0].header) |h| h.magic == fmt.stripe_magic else false;
        if (!self.copies[0].magicOk() and !self.copies[1].magicOk()) {
            if (a_header_ok) {
                try add(&issues, arena, .warning, "header magic found but no footer where avg_obj_size {d} puts it; the volume's avg_obj_size is probably different (see the suggestion below)", .{self.avg_obj_size});
            } else {
                try add(&issues, arena, .warning, "no stripe header magic: this stripe was never initialized, or it was cleared", .{});
            }
            return issues.items;
        }
        const h = self.header() orelse {
            try add(&issues, arena, .warning, "no usable directory copy (sync serials disagree, or the version is unsupported); ATS would clear this stripe", .{});
            return issues.items;
        };

        if (h.version.major != fmt.db_version.major or h.version.minor > fmt.db_version.minor)
            try add(&issues, arena, .note, "cache DB version {f}; cyclone targets {f}", .{ h.version, fmt.db_version });
        const end = g.skip + g.len;
        if (h.write_pos < g.start or h.write_pos > end)
            try add(&issues, arena, .warning, "write_pos {d} is outside the content area [{d}, {d})", .{ h.write_pos, g.start, end });
        if (h.agg_pos < g.start or h.agg_pos > end)
            try add(&issues, arena, .note, "agg_pos {d} is outside the content area", .{h.agg_pos});
        if (h.phase > 1)
            try add(&issues, arena, .warning, "phase is {d}, expected 0 or 1", .{h.phase});
        if (h.sector_size == 0 or h.sector_size > span_fmt.store_block_size or !std.math.isPowerOfTwo(h.sector_size))
            try add(&issues, arena, .warning, "sector_size {d} is not a power of two up to 8192", .{h.sector_size});
        // Not checked: `dirty` (the shutdown sync writes it still set) and
        // `generation` (ATS master never sets it, so it stays 0).
        const per_segment = g.buckets * fmt.dir_depth;
        for (self.freelist, 0..) |head, s| {
            if (head >= per_segment)
                try add(&issues, arena, .warning, "segment {d}: freelist head {d} is past the segment's {d} entries", .{ s, head, per_segment });
        }
        return issues.items;
    }
};

fn readHeaderFooter(io: Io, span: *const Span, offset: u64) !?HeaderFooter {
    var buf: [fmt.header_footer_len]u8 = undefined;
    if (offset + buf.len > span.size) return null;
    if (try span.file.readPositionalAll(io, &buf, offset) != buf.len) return null;
    return HeaderFooter.decode(&buf);
}

/// A geometry that fits a directory length found on disk, and the range of
/// `avg_obj_size` values that produce it.
pub const Candidate = struct {
    avg_min: u32,
    avg_max: u32,
    segments: u64,
    buckets: u64,
};

pub const Diagnosis = struct {
    /// Directory copy length implied by where the footer was found.
    dir_len: u64,
    candidates: []Candidate,
};

/// When the footer is not where `avg_obj_size` says, look for it: scan the
/// stripe in store-block steps for a block that matches header A's magic,
/// serial and create time. Its position gives the directory length, which
/// narrows down `avg_obj_size`. Returns null if header A is not valid or no
/// footer is found.
pub fn diagnoseGeometry(gpa: std.mem.Allocator, io: Io, span: *const Span, block: StripeBlock) !?Diagnosis {
    const a = try readHeaderFooter(io, span, block.offset) orelse return null;
    if (a.magic != fmt.stripe_magic) return null;

    const store = span_fmt.store_block_size;
    // A directory never takes more than 1/8 of a stripe with sane
    // avg_obj_size values; cap the scan so huge stripes stay quick.
    const limit = @min(block.byteLen() / 8, 256 * 1024 * 1024);
    var chunk = try gpa.alloc(u8, 4 * 1024 * 1024);
    defer gpa.free(chunk);

    var pos: u64 = 2 * store; // smallest copy: header + entries + footer
    const found: u64 = scan: while (pos < limit) {
        const n = try span.file.readPositionalAll(io, chunk, block.offset + pos);
        if (n < fmt.header_footer_len) return null;
        var off: usize = 0;
        while (off + fmt.header_footer_len <= n) : (off += store) {
            const f = HeaderFooter.decode(chunk[off..][0..fmt.header_footer_len]);
            if (f.magic == fmt.stripe_magic and f.sync_serial == a.sync_serial and f.create_time == a.create_time)
                break :scan pos + off;
        }
        pos += n / store * store;
    } else return null;

    const dir_len = found + store;
    var candidates: std.ArrayList(Candidate) = .empty;
    errdefer candidates.deinit(gpa);
    // Directory size shrinks as avg_obj_size grows (nearly monotonic), so
    // binary-search the edges of the matching range, then sweep it with a
    // margin to catch any small wiggles from the three-pass sizing.
    const min_avg: u32 = 64;
    const max_avg: u32 = 4 * 1024 * 1024;
    const dirLenAt = struct {
        fn f(blk: StripeBlock, avg_size: u32) u64 {
            return Geometry.compute(blk.offset, blk.byteLen(), avg_size).dirLen();
        }
    }.f;
    var lo = min_avg; // first avg with dirLen <= dir_len
    var hi = max_avg;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (dirLenAt(block, mid) <= dir_len) hi = mid else lo = mid + 1;
    }
    var top = lo; // last avg with dirLen >= dir_len
    hi = max_avg;
    while (top < hi) {
        const mid = top + (hi - top + 1) / 2;
        if (dirLenAt(block, mid) >= dir_len) top = mid else hi = mid - 1;
    }
    const margin = 1024;
    var avg: u32 = @max(min_avg, lo -| margin);
    while (avg <= @min(max_avg, top + margin)) : (avg += 1) {
        const g = Geometry.compute(block.offset, block.byteLen(), avg);
        if (g.dirLen() != dir_len) continue;
        if (candidates.items.len != 0) {
            const last = &candidates.items[candidates.items.len - 1];
            if (last.segments == g.segments and last.buckets == g.buckets and last.avg_max + 1 == avg) {
                last.avg_max = avg;
                continue;
            }
        }
        try candidates.append(gpa, .{ .avg_min = avg, .avg_max = avg, .segments = g.segments, .buckets = g.buckets });
    }
    return .{ .dir_len = dir_len, .candidates = try candidates.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Writes a span with one 128 MB stripe whose copies have the given sync
/// serials, laid out for `avg_obj_size` 8000.
fn writeTestStripe(io: Io, dir: Io.Dir, name: []const u8, serials: [4]u32) !Geometry {
    const size: u64 = 160 * 1024 * 1024;
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    try file.setLength(io, size);

    var dh: [span_fmt.header_fixed_len + span_fmt.stripe_block_len]u8 = @splat(0);
    std.mem.writeInt(u32, dh[0..4], span_fmt.disk_header_magic, .little);
    std.mem.writeInt(u32, dh[4..8], 1, .little);
    std.mem.writeInt(u32, dh[12..16], 1, .little);
    std.mem.writeInt(u32, dh[16..20], 1, .little);
    std.mem.writeInt(u64, dh[24..32], span_fmt.expectedBlocks(size, 8192), .little);
    std.mem.writeInt(u64, dh[32..40], 16384, .little);
    std.mem.writeInt(u64, dh[40..48], 16384, .little); // 128 MB
    std.mem.writeInt(i32, dh[48..52], 1, .little);
    std.mem.writeInt(u32, dh[52..56], 1, .little);
    try file.writePositionalAll(io, &dh, 8192);

    const g = Geometry.compute(16384, 128 * 1024 * 1024, fmt.default_avg_obj_size);
    const spots = [_]u64{ g.copyOffset(.a), g.footerOffset(.a), g.copyOffset(.b), g.footerOffset(.b) };
    for (spots, serials) |off, serial| {
        var hf: [fmt.header_footer_len]u8 = @splat(0);
        std.mem.writeInt(u32, hf[0..4], fmt.stripe_magic, .little);
        std.mem.writeInt(u16, hf[4..6], 24, .little);
        std.mem.writeInt(u16, hf[6..8], 3, .little);
        std.mem.writeInt(i64, hf[8..16], 1700000000, .little);
        std.mem.writeInt(i64, hf[16..24], @intCast(g.start), .little);
        std.mem.writeInt(i64, hf[32..40], @intCast(g.start), .little);
        std.mem.writeInt(u32, hf[52..56], serial, .little);
        std.mem.writeInt(u32, hf[64..68], 4096, .little);
        std.mem.writeInt(u16, hf[72..74], 4181 * 4, .little); // freelist[0]
        try file.writePositionalAll(io, &hf, off);
    }
    return g;
}

test "open a stripe and choose its directory copy" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const g = try writeTestStripe(io, tmp.dir, "s.db", .{ 3, 3, 2, 2 });
    const path = try tmp.dir.realPathFileAlloc(io, "s.db", testing.allocator);
    defer testing.allocator.free(path);

    var span = try Span.open(testing.allocator, io, path, .{});
    defer span.close(testing.allocator, io);
    var stripe = try Stripe.open(testing.allocator, io, &span, 0, fmt.default_avg_obj_size);
    defer stripe.close(testing.allocator);

    try testing.expectEqual(Copy.a, stripe.chosen.?);
    try testing.expectEqual(3, stripe.header().?.sync_serial);
    try testing.expectEqualSlices(u16, &.{4181 * 4}, stripe.freelist);
    try testing.expectEqual(g.start, stripe.geometry.start);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(0, (try stripe.check(arena.allocator())).len);
}

test "torn copy A falls back to B" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try writeTestStripe(io, tmp.dir, "s.db", .{ 4, 3, 2, 2 });
    const path = try tmp.dir.realPathFileAlloc(io, "s.db", testing.allocator);
    defer testing.allocator.free(path);

    var span = try Span.open(testing.allocator, io, path, .{});
    defer span.close(testing.allocator, io);
    var stripe = try Stripe.open(testing.allocator, io, &span, 0, fmt.default_avg_obj_size);
    defer stripe.close(testing.allocator);
    try testing.expectEqual(Copy.b, stripe.chosen.?);
}

test "wrong avg_obj_size: no copy, and the footer scan finds the real size" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const g = try writeTestStripe(io, tmp.dir, "s.db", .{ 3, 3, 2, 2 });
    const path = try tmp.dir.realPathFileAlloc(io, "s.db", testing.allocator);
    defer testing.allocator.free(path);

    var span = try Span.open(testing.allocator, io, path, .{});
    defer span.close(testing.allocator, io);
    var stripe = try Stripe.open(testing.allocator, io, &span, 0, 32000);
    defer stripe.close(testing.allocator);
    try testing.expectEqual(null, stripe.chosen);

    const d = (try diagnoseGeometry(testing.allocator, io, &span, span.blocks[0])).?;
    defer testing.allocator.free(d.candidates);
    try testing.expectEqual(g.dirLen(), d.dir_len);
    const first = d.candidates[0].avg_min;
    const last = d.candidates[d.candidates.len - 1].avg_max;
    try testing.expect(first <= fmt.default_avg_obj_size and fmt.default_avg_obj_size <= last);
}
