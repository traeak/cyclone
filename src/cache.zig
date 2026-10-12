//! A cache as ATS sees it: its spans, the stripe assignment table, and
//! lookups of keys in stripe directories confirmed against their Docs.

const std = @import("std");
const Io = std.Io;
const hash = @import("hash.zig");
const CacheKey = @import("key.zig").CacheKey;
const Span = @import("span.zig").Span;
const Stripe = @import("stripe.zig").Stripe;
const stripe_fmt = @import("format/stripe.zig");
const assign = @import("assign.zig");
const dir = @import("dir.zig");
const doc = @import("doc.zig");

pub const Config = struct {
    hash_type: hash.HashType = .default,
    /// proxy.config.cache.min_average_object_size.
    avg_obj_size: u32 = stripe_fmt.default_avg_obj_size,
    /// storage.yaml per-volume avg_obj_size.
    volume_avg_obj_size: []const VolumeSize = &.{},
    /// The host record's volumes, in order; null for all of them in the
    /// order ATS finds them (see `assign.collectStripes`).
    volumes: ?[]const i32 = null,

    pub const VolumeSize = struct { volume: i32, size: u32 };

    pub fn avgObjSize(c: Config, volume: i32) u32 {
        for (c.volume_avg_obj_size) |v| if (v.volume == volume) return v.size;
        return c.avg_obj_size;
    }
};

/// A tag-matched directory entry and what its Doc says.
pub const Candidate = struct {
    /// Entry index within the segment.
    index: u16,
    dir: dir.Dir,
    /// Byte offset of the fragment in the span.
    offset: u64,
    /// Whether ATS would trust the entry (`dir_valid`).
    valid: bool,
    /// Null when the Doc could not be read.
    verdict: ?doc.Verdict = null,
    doc: ?doc.Doc = null,
    read_error: ?anyerror = null,
};

/// Everything a probe of one key in one stripe saw.
pub const Probe = struct {
    slot: dir.Slot,
    /// Entries walked in the bucket's chain.
    chain_length: u64 = 0,
    chain_error: ?dir.ChainError = null,
    candidates: []Candidate = &.{},

    /// The first valid candidate whose Doc has the key as `want`, which is
    /// the one ATS would read (`Directory::probe` order).
    pub fn hit(p: Probe, want: Want) ?Candidate {
        for (p.candidates) |c| {
            if (c.valid and c.verdict == want.verdict()) return c;
        }
        return null;
    }

    /// The first candidate of any validity whose Doc has the key as `want`.
    pub fn anyMatch(p: Probe, want: Want) ?Candidate {
        for (p.candidates) |c| if (c.verdict == want.verdict()) return c;
        return null;
    }
};

/// Which Doc key a lookup must match.
pub const Want = enum {
    /// An object's head: the key is the Doc's `first_key`.
    head,
    /// A data fragment: the key is the Doc's own `key`.
    fragment,

    fn verdict(w: Want) doc.Verdict {
        return switch (w) {
            .head => .first_key,
            .fragment => .key,
        };
    }
};

pub const Cache = struct {
    gpa: std.mem.Allocator,
    io: Io,
    spans: []const Span,
    config: Config,
    stripes: []const assign.StripeRef,
    table: assign.Table,
    /// Stripes opened so far, by span and block index. Heap-allocated so
    /// pointers stay put.
    open: std.AutoHashMapUnmanaged([2]usize, *Stripe) = .empty,
    /// Guards `open`, so tasks can share the cache. Everything else is
    /// read-only once opened, and reads are positional.
    mutex: Io.Mutex = .init,

    /// `spans` must stay open, in configuration order, for the cache's life.
    pub fn init(gpa: std.mem.Allocator, io: Io, spans: []const Span, config: Config) !Cache {
        const refs = try assign.collectStripes(gpa, spans, config.volumes, config.hash_type);
        errdefer gpa.free(refs);
        if (refs.len == 0) return error.NoStripes;
        const table = try assign.Table.build(gpa, refs);
        return .{ .gpa = gpa, .io = io, .spans = spans, .config = config, .stripes = refs, .table = table };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.open.valueIterator();
        while (it.next()) |s| {
            s.*.close(self.gpa);
            self.gpa.destroy(s.*);
        }
        self.open.deinit(self.gpa);
        self.table.deinit(self.gpa);
        self.gpa.free(self.stripes);
        self.* = undefined;
    }

    /// Stripe block `block_index` of span `span_index`, opened on first use.
    pub fn stripe(self: *Cache, span_index: usize, block_index: usize) !*Stripe {
        if (span_index >= self.spans.len) return error.NoSuchStripe;
        const span = &self.spans[span_index];
        if (block_index >= span.blocks.len or span.blocks[block_index].free) return error.NoSuchStripe;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const gop = try self.open.getOrPut(self.gpa, .{ span_index, block_index });
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = self.open.remove(.{ span_index, block_index });
        const s = try self.gpa.create(Stripe);
        errdefer self.gpa.destroy(s);
        s.* = try Stripe.open(self.gpa, self.io, span, block_index, self.config.avgObjSize(span.blocks[block_index].number));
        gop.value_ptr.* = s;
        return s;
    }

    /// Opens every stripe of every span, as a long-running reader wants to
    /// up front. Returns how many have no usable directory.
    pub fn openAll(self: *Cache) !usize {
        var unusable: usize = 0;
        for (self.spans, 0..) |span, si| {
            for (span.blocks, 0..) |b, bi| {
                if (b.free) continue;
                const s = try self.stripe(si, bi);
                if (s.chosen == null) unusable += 1;
            }
        }
        return unusable;
    }

    /// The table entry for the stripe ATS stores `key`'s object in.
    pub fn home(self: *const Cache, key: *const CacheKey) *const assign.StripeRef {
        return self.table.stripeFor(key);
    }

    pub fn homeStripe(self: *Cache, key: *const CacheKey) !*Stripe {
        const ref = self.home(key);
        return self.stripe(ref.span_index, ref.block_index);
    }

    /// Walks `key`'s bucket in `s` and checks every tag match against its
    /// Doc. Candidates are allocated with `arena`.
    pub fn probe(self: *Cache, arena: std.mem.Allocator, s: *const Stripe, key: *const CacheKey) !Probe {
        if (s.chosen == null) return error.NoUsableDirectory;
        const slot = dir.Slot.of(key, s.geometry.segments, s.geometry.buckets);
        var p: Probe = .{ .slot = slot };
        var candidates: std.ArrayList(Candidate) = .empty;
        var chain = try dir.DiskChain.init(self.io, s, slot.segment, slot.bucket);
        while (try chain.next()) |link| {
            p.chain_length += 1;
            const d = link.dir;
            if (d.isEmpty() or d.tag() != slot.tag) continue;
            var c: Candidate = .{
                .index = link.index,
                .dir = d,
                .offset = dir.contentOffset(s, d),
                .valid = dir.entryValid(s, d),
            };
            if (doc.readHeader(self.io, s.span.file, self.config.hash_type, c.offset)) |h| {
                c.doc = h;
                c.verdict = doc.check(h, d, key);
            } else |err| {
                c.read_error = err;
            }
            try candidates.append(arena, c);
        }
        p.chain_error = chain.err;
        p.candidates = candidates.items;
        return p;
    }

    /// The Doc ATS would read for `key` in `s`, or null for a miss.
    pub fn find(self: *Cache, s: *const Stripe, key: *const CacheKey, want: Want) !?Candidate {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        return (try self.probe(arena.allocator(), s, key)).hit(want);
    }
};
