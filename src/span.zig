//! An open span: the device or file, its `DiskHeader` and stripe blocks.

const std = @import("std");
const Io = std.Io;
const fmt = @import("format/span.zig");

pub const StripeBlock = fmt.StripeBlock;
pub const DiskHeader = fmt.DiskHeader;

pub const OpenOptions = struct {
    /// Byte offset of the `DiskHeader`. When null, try `start_pos` (8 KB),
    /// then each store block up to `max_probe`, as a device alignment
    /// would move it.
    skip: ?u64 = null,
    max_probe: u64 = 1024 * 1024,
    /// The name ATS hashed for this span's stripes: storage.yaml
    /// `hash_seed` if set, otherwise the span path exactly as configured.
    /// Defaults to the path given to `open`.
    seed: ?[]const u8 = null,
};

pub const OpenError = error{
    /// No `DiskHeader` magic at `skip` (or anywhere probed).
    NoDiskHeader,
    /// More stripe blocks than a span this size can hold.
    CorruptHeader,
    /// Span is shorter than its header.
    Truncated,
} || Io.File.OpenError || Io.File.StatError || Io.File.ReadPositionalError || std.mem.Allocator.Error || error{Unexpected};

pub const Span = struct {
    path: []const u8,
    seed: []const u8,
    file: Io.File,
    /// Total bytes of the device or file.
    size: u64,
    /// Byte offset of the `DiskHeader`.
    skip: u64,
    header: DiskHeader,
    /// All `vol_info[]` entries, free and used, in header order.
    blocks: []StripeBlock,

    /// Opens `path` read-only and reads its header. `path` and
    /// `opts.seed` must outlive the span.
    pub fn open(gpa: std.mem.Allocator, io: Io, path: []const u8, opts: OpenOptions) OpenError!Span {
        const file = try Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const size = try spanSize(io, file);

        var header_buf: [fmt.header_fixed_len]u8 = undefined;
        const skip, const header = blk: {
            if (opts.skip) |skip| {
                const h = try readHeader(io, file, size, skip, &header_buf) orelse return error.NoDiskHeader;
                break :blk .{ skip, h };
            }
            var skip: u64 = fmt.start_pos;
            while (skip <= opts.max_probe) : (skip += fmt.store_block_size) {
                if (try readHeader(io, file, size, skip, &header_buf)) |h| break :blk .{ skip, h };
            }
            return error.NoDiskHeader;
        };

        // ATS sizes the header for one stripe block per 128 MB of span.
        const max_blocks = (size -| skip) / fmt.stripe_block_size + 1;
        if (header.num_diskvol_blks > max_blocks) return error.CorruptHeader;

        const raw = try gpa.alloc(u8, header.num_diskvol_blks * fmt.stripe_block_len);
        defer gpa.free(raw);
        if (try file.readPositionalAll(io, raw, skip + fmt.header_fixed_len) != raw.len) return error.Truncated;

        const blocks = try gpa.alloc(StripeBlock, header.num_diskvol_blks);
        for (blocks, 0..) |*b, i| b.* = .decode(raw[i * fmt.stripe_block_len ..][0..fmt.stripe_block_len]);

        return .{
            .path = path,
            .seed = opts.seed orelse path,
            .file = file,
            .size = size,
            .skip = skip,
            .header = header,
            .blocks = blocks,
        };
    }

    pub fn close(self: *Span, gpa: std.mem.Allocator, io: Io) void {
        gpa.free(self.blocks);
        self.file.close(io);
        self.* = undefined;
    }

    /// Where ATS puts the first stripe: just past the header, rounded up to
    /// a store block (CacheDisk::open). ATS sizes the header for the most
    /// stripe blocks the span could ever hold, not for how many it has.
    pub fn dataStart(self: *const Span) u64 {
        const len = fmt.expectedBlocks(self.size, self.skip) * fmt.store_block_size;
        var start = self.skip;
        // Same successive approximation as CacheDisk::open.
        for (0..3) |_| {
            const l = len - (start - self.skip);
            const header_len: u64 = if (l < fmt.stripe_block_size)
                fmt.header_fixed_len + fmt.stripe_block_len
            else
                fmt.header_fixed_len + fmt.stripe_block_len + (l / fmt.stripe_block_size - 1) * fmt.stripe_block_len;
            start = self.skip + header_len;
        }
        return std.mem.alignForward(u64, start, fmt.store_block_size);
    }

    /// The text ATS hashes to place this stripe (`Stripe::_init_hash_text`):
    /// "<seed> <offset>:<len in store blocks>".
    pub fn stripeHashText(self: *const Span, w: *Io.Writer, block: StripeBlock) Io.Writer.Error!void {
        try w.print("{s} {d}:{d}", .{ self.seed, block.offset, block.len });
    }

    /// Stripe blocks in use, in header order. For one volume this is the
    /// order ATS adds them to the volume (Cache::open).
    pub fn usedBlocks(self: *const Span) UsedIterator {
        return .{ .blocks = self.blocks };
    }

    pub const UsedIterator = struct {
        blocks: []const StripeBlock,
        index: usize = 0,

        pub fn next(it: *UsedIterator) ?StripeBlock {
            while (it.index < it.blocks.len) {
                defer it.index += 1;
                if (!it.blocks[it.index].free) return it.blocks[it.index];
            }
            return null;
        }
    };

    /// Consistency checks. Problems ATS itself would act on are warnings;
    /// anything else odd is a note.
    pub fn check(self: *const Span, arena: std.mem.Allocator) ![]Issue {
        var issues: std.ArrayList(Issue) = .empty;
        const add = struct {
            fn f(list: *std.ArrayList(Issue), a: std.mem.Allocator, sev: Issue.Severity, comptime f_: []const u8, args: anytype) !void {
                try list.append(a, .{ .severity = sev, .message = try std.fmt.allocPrint(a, f_, args) });
            }
        }.f;

        if (self.seed.ptr == self.path.ptr and !std.fs.path.isAbsolute(self.path))
            try add(&issues, arena, .note, "hash text uses the relative path '{s}'; ATS hashed the path as written in storage.yaml, so pass --seed if they differ", .{self.path});

        const want = fmt.expectedBlocks(self.size, self.skip);
        if (self.header.num_blocks != want) {
            if (self.header.num_blocks + fmt.blocksDelta32(self.skip) == want) {
                try add(&issues, arena, .note, "num_blocks {d} uses the ATS 3.2 count; ATS accepts it", .{self.header.num_blocks});
            } else {
                try add(&issues, arena, .warning, "num_blocks {d} does not match span size ({d} expected); ATS would clear this span", .{ self.header.num_blocks, want });
            }
        }

        var used: u32 = 0;
        var free: u32 = 0;
        const data_start = self.dataStart();
        for (self.blocks, 0..) |b, i| {
            if (b.free) free += 1 else used += 1;
            if (b.offset % fmt.store_block_size != 0)
                try add(&issues, arena, .warning, "block {d}: offset {d} is not store-block aligned", .{ i, b.offset });
            if (b.offset < data_start)
                try add(&issues, arena, .warning, "block {d}: offset {d} overlaps the span header (data starts at {d})", .{ i, b.offset, data_start });
            if (b.end() > self.size)
                try add(&issues, arena, .warning, "block {d}: ends at {d}, past the end of the span ({d})", .{ i, b.end(), self.size });
            if (b.len == 0)
                try add(&issues, arena, .warning, "block {d}: zero length", .{i});
            if (!b.free and b.type != .http)
                try add(&issues, arena, .note, "block {d}: cache type {d} is not HTTP", .{ i, @intFromEnum(b.type) });
            for (self.blocks[0..i], 0..) |o, j| {
                if (b.offset < o.end() and o.offset < b.end())
                    try add(&issues, arena, .warning, "block {d} overlaps block {d}", .{ i, j });
            }
        }
        if (used != self.header.num_used)
            try add(&issues, arena, .note, "num_used is {d} but {d} blocks are in use", .{ self.header.num_used, used });
        if (free != self.header.num_free)
            try add(&issues, arena, .note, "num_free is {d} but {d} blocks are free", .{ self.header.num_free, free });
        return issues.items;
    }
};

pub const Issue = struct {
    severity: Severity,
    message: []const u8,

    pub const Severity = enum { note, warning };
};

/// Reads and decodes the fixed header at `skip`; null if the magic is wrong.
fn readHeader(io: Io, file: Io.File, size: u64, skip: u64, buf: *[fmt.header_fixed_len]u8) !?DiskHeader {
    if (skip + buf.len > size) return null;
    if (try file.readPositionalAll(io, buf, skip) != buf.len) return null;
    const h = DiskHeader.decode(buf);
    return if (h.magic == fmt.disk_header_magic) h else null;
}

/// Size in bytes of a regular file or a block device.
fn spanSize(io: Io, file: Io.File) !u64 {
    const st = try file.stat(io);
    if (st.kind != .block_device) return st.size;
    if (@import("builtin").os.tag != .linux) return error.Unexpected;
    const linux = std.os.linux;
    // BLKGETSIZE64 = _IOR(0x12, 114, u64)
    const blkgetsize64 = linux.IOCTL.IOR(0x12, 114, u64);
    var size: u64 = 0;
    return switch (linux.errno(linux.ioctl(file.handle, blkgetsize64, @intFromPtr(&size)))) {
        .SUCCESS => size,
        else => error.Unexpected,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Writes a span image with one used and one free stripe block.
fn writeTestSpan(io: Io, dir: Io.Dir, name: []const u8, size: u64, skip: u64) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    try file.setLength(io, size);

    var b: [fmt.header_fixed_len + 2 * fmt.stripe_block_len]u8 = @splat(0);
    std.mem.writeInt(u32, b[0..4], fmt.disk_header_magic, .little);
    std.mem.writeInt(u32, b[4..8], 1, .little); // num_volumes
    std.mem.writeInt(u32, b[8..12], 1, .little); // num_free
    std.mem.writeInt(u32, b[12..16], 1, .little); // num_used
    std.mem.writeInt(u32, b[16..20], 2, .little); // num_diskvol_blks
    std.mem.writeInt(u64, b[24..32], fmt.expectedBlocks(size, skip), .little);

    const used = b[32..56];
    std.mem.writeInt(u64, used[0..8], skip + 8192, .little);
    std.mem.writeInt(u64, used[8..16], 16384, .little); // 128 MB
    std.mem.writeInt(i32, used[16..20], 1, .little);
    std.mem.writeInt(u32, used[20..24], 1, .little); // http
    const free = b[56..80];
    std.mem.writeInt(u64, free[0..8], skip + 8192 + 16384 * 8192, .little);
    std.mem.writeInt(u64, free[8..16], 100, .little);
    std.mem.writeInt(u32, free[20..24], 0b1000, .little);
    try file.writePositionalAll(io, &b, skip);
}

test "open a span image" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const size = 256 * 1024 * 1024;
    try writeTestSpan(io, tmp.dir, "span.db", size, 8192);
    const path = try tmp.dir.realPathFileAlloc(io, "span.db", testing.allocator);
    defer testing.allocator.free(path);

    var span = try Span.open(testing.allocator, io, path, .{});
    defer span.close(testing.allocator, io);

    try testing.expectEqual(size, span.size);
    try testing.expectEqual(8192, span.skip);
    try testing.expectEqual(2, span.blocks.len);
    try testing.expectEqual(16384, span.dataStart());

    var it = span.usedBlocks();
    const first = it.next().?;
    try testing.expectEqual(1, first.number);
    try testing.expectEqual(null, it.next());

    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try span.stripeHashText(&w, first);
    try testing.expect(std.mem.endsWith(u8, w.buffered(), " 16384:16384"));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const issues = try span.check(arena.allocator());
    try testing.expectEqual(0, issues.len);
}

test "probe a moved header and reject non-spans" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestSpan(io, tmp.dir, "moved.db", 256 * 1024 * 1024, 16384);
    const moved = try tmp.dir.realPathFileAlloc(io, "moved.db", testing.allocator);
    defer testing.allocator.free(moved);
    var span = try Span.open(testing.allocator, io, moved, .{});
    defer span.close(testing.allocator, io);
    try testing.expectEqual(16384, span.skip);
    try testing.expectError(error.NoDiskHeader, Span.open(testing.allocator, io, moved, .{ .skip = 8192 }));

    const empty = try tmp.dir.createFile(io, "empty.db", .{});
    try empty.setLength(io, 4 * 1024 * 1024);
    empty.close(io);
    const empty_path = try tmp.dir.realPathFileAlloc(io, "empty.db", testing.allocator);
    defer testing.allocator.free(empty_path);
    try testing.expectError(error.NoDiskHeader, Span.open(testing.allocator, io, empty_path, .{}));
}
