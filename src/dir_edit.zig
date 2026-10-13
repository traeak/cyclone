//! Changing a stripe's directory and writing it back, as ATS does.
//!
//! A `Directory` holds one whole copy in memory: header (with the segment
//! free lists), entries and footer, exactly as on disk. Entries are removed
//! with ports of `Directory::remove` and `Directory::delete_entry`
//! (CacheDir.cc, P_CacheDir.h), and the copy is written back the way ATS's
//! shutdown sync writes it (`StripeSM::shutdown`): `sync_serial` goes up by
//! one in header and footer, and the copy goes where that serial's parity
//! puts it (A for even, B for odd). That is the copy not in use, so until
//! the new one is complete the old one stays the one ATS chooses.
//!
//! Nothing here touches the content area: a removed entry's Doc stays where
//! it is until the cyclone buffer overwrites it, as after ATS's own remove.

const std = @import("std");
const Io = std.Io;
const dir_fmt = @import("format/dir.zig");
const stripe_fmt = @import("format/stripe.zig");
const Stripe = @import("stripe.zig").Stripe;

const Dir = dir_fmt.Dir;
const Slot = dir_fmt.Slot;
const Geometry = stripe_fmt.Geometry;
const Copy = stripe_fmt.Copy;
const HeaderFooter = stripe_fmt.HeaderFooter;

/// Offsets of fields written in a `StripeHeaderFooter`.
const sync_serial_offset = 52;
const dirty_offset = 60;

pub const Directory = struct {
    geometry: Geometry,
    /// The copy the directory was read from (the one ATS uses).
    source: Copy,
    /// The whole copy: `geometry.dirLen()` bytes.
    raw: []u8,
    /// Entries deleted so far.
    deleted: u64 = 0,

    /// Reads the copy ATS would use.
    pub fn read(gpa: std.mem.Allocator, io: Io, stripe: *const Stripe) !Directory {
        const copy = stripe.chosen orelse return error.NoUsableDirectory;
        const g = stripe.geometry;
        const raw = try gpa.alloc(u8, @intCast(g.dirLen()));
        errdefer gpa.free(raw);
        if (try stripe.span.file.readPositionalAll(io, raw, g.copyOffset(copy)) != raw.len) return error.Truncated;
        return .{ .geometry = g, .source = copy, .raw = raw };
    }

    pub fn deinit(self: *Directory, gpa: std.mem.Allocator) void {
        gpa.free(self.raw);
        self.* = undefined;
    }

    pub fn header(self: *const Directory) HeaderFooter {
        return .decode(self.raw[0..stripe_fmt.header_footer_len]);
    }

    pub fn footer(self: *const Directory) HeaderFooter {
        return .decode(self.raw[self.footerStart()..][0..stripe_fmt.header_footer_len]);
    }

    fn footerStart(self: *const Directory) usize {
        return @intCast(self.geometry.dirLen() - self.geometry.footerLen());
    }

    fn segmentEntries(self: *const Directory) u64 {
        return self.geometry.buckets * dir_fmt.depth;
    }

    fn entryBytes(self: *const Directory, s: u64, i: u64) *[dir_fmt.entry_len]u8 {
        const at = self.geometry.headerLen() + (s * self.segmentEntries() + i) * dir_fmt.entry_len;
        return self.raw[@intCast(at)..][0..dir_fmt.entry_len];
    }

    pub fn entry(self: *const Directory, s: u64, i: u64) Dir {
        return .decode(self.entryBytes(s, i));
    }

    fn put(self: *Directory, s: u64, i: u64, d: Dir) void {
        d.encode(self.entryBytes(s, i));
    }

    /// Head of segment `s`'s free list (`header->freelist[s]`).
    pub fn freelistHead(self: *const Directory, s: u64) u16 {
        return std.mem.readInt(u16, self.raw[@intCast(stripe_fmt.freelist_offset + s * 2)..][0..2], .little);
    }

    fn setFreelistHead(self: *Directory, s: u64, i: u16) void {
        std.mem.writeInt(u16, self.raw[@intCast(stripe_fmt.freelist_offset + s * 2)..][0..2], i, .little);
    }

    /// `Directory::max_bucket_depth`: longer chains are corrupt.
    fn maxBucketDepth(self: *const Directory) u64 {
        return (dir_fmt.depth - 1) * self.geometry.buckets + 1;
    }

    /// `Directory::remove`: deletes the first entry in `slot`'s bucket with
    /// the slot's tag and directory offset `offset` (`Dir.offset()`).
    /// Returns whether there was one. ATS repairs a looping chain here
    /// (`bucket_loop_fix`); this refuses instead.
    pub fn remove(self: *Directory, slot: Slot, offset: u64) error{CorruptChain}!bool {
        const s = slot.segment;
        const head: u16 = @intCast(slot.bucket * dir_fmt.depth);
        if (self.entry(s, head).isEmpty()) return false;
        var e: u16 = head;
        var p: ?u16 = null;
        var steps: u64 = 0;
        while (true) {
            steps += 1;
            if (steps > self.maxBucketDepth() or e >= self.segmentEntries()) return error.CorruptChain;
            const d = self.entry(s, e);
            if (d.tag() == slot.tag and d.offset() == offset) {
                self.deleteEntry(s, e, p);
                return true;
            }
            if (d.next() == 0) return false;
            p = e;
            e = d.next();
        }
    }

    /// `Directory::delete_entry`: unlinks entry `e` (whose predecessor in
    /// the chain is `p`) and puts it on the segment's free list. A bucket's
    /// head cannot move, so deleting a head with a successor copies the
    /// successor into the head and deletes the successor instead.
    fn deleteEntry(self: *Directory, s: u64, e: u16, p: ?u16) void {
        const no = self.entry(s, e).next();
        if (p) |pi| {
            self.deleted += 1;
            const fo = self.freelistHead(s);
            var pd = self.entry(s, pi);
            pd.setNext(no);
            self.put(s, pi, pd);
            var ed: Dir = .empty;
            ed.setNext(fo);
            self.put(s, e, ed);
            if (fo != 0) {
                var f = self.entry(s, fo);
                f.setPrev(e);
                self.put(s, fo, f);
            }
            self.setFreelistHead(s, e);
        } else if (no != 0) {
            self.put(s, e, self.entry(s, no));
            self.deleteEntry(s, no, e);
        } else {
            self.deleted += 1;
            self.put(s, e, .empty);
        }
    }

    /// The copy a sync writes: where the next `sync_serial` puts it. An
    /// error when that is the copy in use, which happens only if ATS chose
    /// a copy against the serials' parity; writing it would leave no good
    /// copy if the write were cut short.
    pub fn syncTarget(self: *const Directory) error{WouldOverwriteCopyInUse}!Copy {
        const target: Copy = if ((self.header().sync_serial +% 1) & 1 == 1) .b else .a;
        if (target == self.source) return error.WouldOverwriteCopyInUse;
        return target;
    }

    /// Sets up the copy as `StripeSM::shutdown` writes it: `sync_serial`
    /// one higher in header and footer, and `dirty` set, as
    /// `delete_entry` leaves it.
    pub fn prepareSync(self: *Directory) void {
        const serial = self.header().sync_serial +% 1;
        std.mem.writeInt(u32, self.raw[sync_serial_offset..][0..4], serial, .little);
        std.mem.writeInt(u32, self.raw[self.footerStart() + sync_serial_offset ..][0..4], serial, .little);
        std.mem.writeInt(u32, self.raw[dirty_offset..][0..4], 1, .little);
    }

    /// Writes the copy at `target`: header and entries, then (once those
    /// are on the device) the footer, so a copy with a matching footer is
    /// whole. `file` must be the span, open for writing.
    pub fn write(self: *const Directory, io: Io, file: Io.File, target: Copy) !void {
        const off = self.geometry.copyOffset(target);
        const split = self.footerStart();
        try file.writePositionalAll(io, self.raw[0..split], off);
        try file.sync(io);
        try file.writePositionalAll(io, self.raw[split..], off + split);
        try file.sync(io);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A directory of one segment of 4 buckets (16 entries), all free but the
/// bucket heads, as ATS initializes one.
fn testDirectory(raw: []u8) Directory {
    const g: Geometry = .{ .skip = 0, .len = 0, .segments = 1, .buckets = 4, .start = 0 };
    @memset(raw, 0);
    var d: Directory = .{ .geometry = g, .source = .a, .raw = raw[0..@intCast(g.dirLen())] };
    // Free list 1 -> 2 -> 3 -> 5 -> ... (every row but the heads).
    var prev: u16 = 0;
    for (1..16) |i| {
        if (i % dir_fmt.depth == 0) continue;
        var e: Dir = .empty;
        e.setPrev(prev);
        if (prev != 0) {
            var p = d.entry(0, prev);
            p.setNext(@intCast(i));
            d.put(0, prev, p);
        } else d.setFreelistHead(0, @intCast(i));
        d.put(0, i, e);
        prev = @intCast(i);
    }
    return d;
}

fn entryAt(offset: u64, tag: u12, next: u16) Dir {
    return .{ .w = .{ @truncate(offset), @as(u16, @truncate(offset >> 16)) & 0xff, tag, next, @truncate(offset >> 24) } };
}

/// Takes entries off the free list, as `freelist_pop` does.
fn pop(d: *Directory) u16 {
    const e = d.freelistHead(0);
    const n = d.entry(0, e).next();
    d.setFreelistHead(0, n);
    if (n != 0) {
        var nd = d.entry(0, n);
        nd.setPrev(0);
        d.put(0, n, nd);
    }
    return e;
}

/// Free list as a slice, checking each back link.
fn freeList(d: *const Directory, buf: []u16) ![]u16 {
    var n: usize = 0;
    var prev: u16 = 0;
    var e = d.freelistHead(0);
    while (e != 0) : (n += 1) {
        const x = d.entry(0, e);
        try testing.expect(x.isEmpty());
        try testing.expectEqual(prev, x.prev());
        buf[n] = e;
        prev = e;
        e = x.next();
    }
    return buf[0..n];
}

test "remove a chain's middle, its head, and a bucket's only entry" {
    var raw: [3 * 8192 + 16 * 10]u8 = undefined;
    var d = testDirectory(&raw);
    // Bucket 0: 0 -> a -> b, all tag 7; bucket 1: head only.
    const a = pop(&d);
    const b = pop(&d);
    d.put(0, 0, entryAt(100, 7, a));
    d.put(0, a, entryAt(200, 7, b));
    d.put(0, b, entryAt(300, 7, 0));
    d.put(0, 4, entryAt(400, 9, 0));

    const s0: Slot = .{ .segment = 0, .bucket = 0, .tag = 7 };
    try testing.expect(!try d.remove(s0, 999)); // no such offset
    try testing.expect(!try d.remove(.{ .segment = 0, .bucket = 0, .tag = 8 }, 200)); // tag differs

    // Middle: 0 -> b, and a heads the free list.
    try testing.expect(try d.remove(s0, 200));
    try testing.expectEqual(b, d.entry(0, 0).next());
    var buf: [16]u16 = undefined;
    try testing.expectEqual(a, (try freeList(&d, &buf))[0]);

    // Head with a successor: b's entry moves into the head; b is freed.
    try testing.expect(try d.remove(s0, 100));
    try testing.expectEqual(300, d.entry(0, 0).offset());
    try testing.expectEqual(0, d.entry(0, 0).next());
    const free = try freeList(&d, &buf);
    try testing.expectEqual(b, free[0]);
    try testing.expectEqual(a, free[1]);
    try testing.expectEqual(12, free.len); // 16 entries - 4 heads

    // The bucket's only entry: the head is cleared, not freed.
    try testing.expect(try d.remove(.{ .segment = 0, .bucket = 1, .tag = 9 }, 400));
    try testing.expect(d.entry(0, 4).isEmpty());
    try testing.expectEqual(12, (try freeList(&d, &buf)).len);
    try testing.expectEqual(3, d.deleted);
}

test "a looping chain is refused" {
    var raw: [3 * 8192 + 16 * 10]u8 = undefined;
    var d = testDirectory(&raw);
    const a = pop(&d);
    d.put(0, 0, entryAt(100, 7, a));
    d.put(0, a, entryAt(200, 7, 0 + a)); // points at itself
    try testing.expectError(error.CorruptChain, d.remove(.{ .segment = 0, .bucket = 0, .tag = 7 }, 999));
}

test "sync goes to the other copy with the next serial" {
    var raw: [3 * 8192 + 16 * 10]u8 = undefined;
    var d = testDirectory(&raw);
    std.mem.writeInt(u32, d.raw[sync_serial_offset..][0..4], 6, .little);
    try testing.expectEqual(Copy.b, try d.syncTarget());
    d.prepareSync();
    try testing.expectEqual(7, d.header().sync_serial);
    try testing.expectEqual(7, d.footer().sync_serial);
    try testing.expectEqual(1, d.header().dirty);
    // Copy B in use with an odd serial: the next one goes to A.
    d.source = .b;
    try testing.expectEqual(Copy.a, try d.syncTarget());
    // B in use with an even serial: the sync would land on it.
    std.mem.writeInt(u32, d.raw[sync_serial_offset..][0..4], 8, .little);
    try testing.expectError(error.WouldOverwriteCopyInUse, d.syncTarget());
}
