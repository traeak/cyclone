//! Deleting objects from a cache, as ATS's `Cache::remove` does
//! (`CacheVC::removeEvent` in CacheVC.cc): probe the key's bucket, and
//! remove the valid entry whose Doc has the key as its `first_key` (the
//! object's head). The object's other fragments keep their entries, as
//! after ATS's own remove: nothing can reach them without the head, and
//! the cyclone buffer reclaims them in time.
//!
//! ATS removes one entry per call. Here every valid head entry for the key
//! is removed, as repeating ATS's remove until it misses would. Entries ATS
//! no longer trusts (`dir_valid`) are left, as ATS leaves them to its next
//! probe or cleanup.
//!
//! Changes collect in a `Directory` per stripe; nothing is written until
//! the caller syncs them (see `dir_edit.zig`).

const std = @import("std");
const Io = std.Io;
const CacheKey = @import("key.zig").CacheKey;
const Cache = @import("cache.zig").Cache;
const Stripe = @import("stripe.zig").Stripe;
const Directory = @import("dir_edit.zig").Directory;

pub const Removed = struct {
    /// Entry index within the segment.
    index: u16,
    /// Byte offset in the span of the Doc it pointed at.
    offset: u64,
};

pub const Result = struct {
    span_index: usize,
    block_index: usize,
    removed: []const Removed,
    /// Entries for the key that ATS no longer trusts: left as they are.
    stale: usize,
};

pub const Deleter = struct {
    gpa: std.mem.Allocator,
    io: Io,
    cache: *Cache,
    /// The directories changed so far, by stripe.
    dirs: std.AutoArrayHashMapUnmanaged(*Stripe, Directory) = .empty,

    pub fn deinit(self: *Deleter) void {
        for (self.dirs.values()) |*d| d.deinit(self.gpa);
        self.dirs.deinit(self.gpa);
        self.* = undefined;
    }

    /// Removes `key`'s head entries from its stripe's directory in memory.
    pub fn delete(self: *Deleter, arena: std.mem.Allocator, key: *const CacheKey) !Result {
        const ref = self.cache.home(key);
        const s = try self.cache.stripe(ref.span_index, ref.block_index);
        const probe = try self.cache.probe(arena, s, key);
        if (probe.chain_error != null) return error.CorruptChain;
        var removed: std.ArrayList(Removed) = .empty;
        var stale: usize = 0;
        for (probe.candidates) |c| {
            if (c.verdict != .first_key) continue;
            if (!c.valid) {
                stale += 1;
                continue;
            }
            const d = try self.directory(s);
            if (try d.remove(probe.slot, c.dir.offset())) try removed.append(arena, .{ .index = c.index, .offset = c.offset });
        }
        return .{ .span_index = ref.span_index, .block_index = ref.block_index, .removed = removed.items, .stale = stale };
    }

    fn directory(self: *Deleter, s: *Stripe) !*Directory {
        const gop = try self.dirs.getOrPut(self.gpa, s);
        if (!gop.found_existing) {
            gop.value_ptr.* = Directory.read(self.gpa, self.io, s) catch |err| {
                _ = self.dirs.swapRemove(s);
                return err;
            };
        }
        return gop.value_ptr;
    }
};
