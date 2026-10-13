//! cyc-delete: remove objects from a cache, as ATS's own remove does.

const std = @import("std");
const Io = std.Io;
const cyclone = @import("cyclone");
const cli = cyclone.cli;
const Directory = cyclone.dir_edit.Directory;

const usage =
    \\usage: cyc-delete --span PATH... [options] KEY|URL...
    \\       cyc-delete --span PATH... [options] -        (keys or URLs from stdin)
    \\
    \\Remove objects from an ATS cache, as ATS's own remove does: each object's
    \\head entry (the one whose Doc has the key as first_key) is deleted from
    \\its stripe's directory. The object's data stays on disk, unreachable,
    \\until the cyclone buffer overwrites it.
    \\
    \\ATS MUST NOT BE RUNNING. This writes to the spans: each stripe with
    \\deletions gets its directory written to its other copy with the next sync
    \\serial, as ATS's shutdown sync does, so the copy in use stays intact until
    \\the new one is complete. It refuses to write a span another process has
    \\open.
    \\
    \\Output is one line per input:
    \\  KEY  STRIPE  removed N|not-found|error: ...  [URL]
    \\then one line per stripe written.
    \\
    \\options:
    \\
++ cli.Common.help ++
    \\  --volumes N,M,...   volumes of the host record, in order (as for cyc-lookup)
    \\  --dry-run           show what would be removed and written; write nothing
    \\  --shm-prefix NAME   proxy.config.cache.shm.name_prefix, to look for ATS's
    \\                      shared-memory directories (default: ats)
    \\
    \\Exit status: 0 when every input was handled (removed or not found), 1 when
    \\any failed, 2 on a usage error or when nothing could be written.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var common: cli.Common = .{};
    var volumes: ?[]const i32 = null;
    var dry_run = false;
    var shm_prefix: []const u8 = "ats";
    var inputs: std.ArrayList([]const u8) = .empty;

    var it: cli.ArgIterator = .init(args);
    var from_stdin = false;
    while (it.next()) |arg| {
        if (cli.isHelp(arg)) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (try common.parse(arena, arg, &it)) {
            continue;
        } else if (std.mem.eql(u8, arg, "--volumes")) {
            volumes = try cli.parseVolumes(arena, it.value(arg));
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--shm-prefix")) {
            shm_prefix = it.value(arg);
        } else if (std.mem.eql(u8, arg, "-")) {
            from_stdin = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            cli.fatal("unknown option '{s}'\n\n{s}", .{ arg, usage });
        } else {
            try inputs.append(arena, arg);
        }
    }
    if (common.spans.items.len == 0) cli.fatal("no --span given\n\n{s}", .{usage});
    if (inputs.items.len == 0 and !from_stdin) cli.fatal("nothing to delete\n\n{s}", .{usage});
    if (from_stdin) {
        var in_buf: [16 * 1024]u8 = undefined;
        var in_file: Io.File.Reader = .init(.stdin(), io, &in_buf);
        while (try in_file.interface.takeDelimiter('\n')) |line| {
            const text = std.mem.trim(u8, line, " \t\r");
            if (text.len != 0) try inputs.append(arena, try arena.dupe(u8, text));
        }
    }

    var out_buf: [8192]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_file.interface;

    if (!dry_run) try checkSafe(arena, io, common.spans.items, shm_prefix);

    const spans = try arena.alloc(cyclone.Span, common.spans.items.len);
    for (common.spans.items, spans) |arg, *s| {
        s.* = cyclone.Span.open(gpa, io, arg.path, .{ .seed = arg.seed, .skip = arg.skip }) catch |err|
            cli.fatal("{s}: {s}", .{ arg.path, @errorName(err) });
    }
    defer for (spans) |*s| s.close(gpa, io);
    var cache = cyclone.Cache.init(gpa, io, spans, common.cacheConfig(volumes)) catch |err| switch (err) {
        error.NoStripes => cli.fatal("no stripes{s}", .{if (volumes != null) " in the given --volumes" else ""}),
        else => return err,
    };
    defer cache.deinit();

    var deleter: cyclone.delete.Deleter = .{ .gpa = gpa, .io = io, .cache = &cache };
    defer deleter.deinit();

    var failed = false;
    for (inputs.items) |text| {
        const key = cli.parseKeyOrUrl(common.hash_type, text) catch {
            try out.print("-\t-\terror: not a key, and not a URL that parses\t{s}\n", .{text});
            failed = true;
            continue;
        };
        const r = deleter.delete(arena, &key) catch |err| {
            const ref = cache.home(&key);
            try out.print("{f}\t{d}:{d}\terror: {s}", .{ key, ref.span_index, ref.block_index, switch (err) {
                error.NoUsableDirectory => "the stripe has no usable directory",
                error.CorruptChain => "the key's directory bucket is corrupt; nothing removed",
                else => @errorName(err),
            } });
            try printUrl(out, &key, text);
            failed = true;
            continue;
        };
        try out.print("{f}\t{d}:{d}\t", .{ key, r.span_index, r.block_index });
        if (r.removed.len == 0) try out.writeAll("not-found") else try out.print("removed {d}", .{r.removed.len});
        if (r.stale != 0) try out.print(" ({d} stale left)", .{r.stale});
        try printUrl(out, &key, text);
    }

    // Every stripe's target copy is checked before anything is written.
    const dirs = deleter.dirs.values();
    const stripes = deleter.dirs.keys();
    const targets = try arena.alloc(cyclone.format.stripe.Copy, dirs.len);
    for (dirs, stripes, targets) |*d, s, *t| {
        if (d.deleted == 0) continue;
        t.* = d.syncTarget() catch cli.fatal("stripe {d}:{d}: copy {t} is in use with sync serial {d}, so the next sync would overwrite it; not writing anything", .{
            spanIndex(spans, s.span), s.block_index, d.source, d.header().sync_serial,
        });
    }

    for (dirs, stripes, targets) |*d, s, target| {
        if (d.deleted == 0) continue;
        const si = spanIndex(spans, s.span);
        const old = d.header().sync_serial;
        try out.print("stripe {d}:{d}\t{d} entries removed\tcopy {t} (serial {d}) -> copy {t} (serial {d})", .{
            si, s.block_index, d.deleted, d.source, old, target, old +% 1,
        });
        if (dry_run) {
            try out.writeAll("\tdry run: not written\n");
            continue;
        }
        try out.flush();
        d.prepareSync();
        writeCopy(io, s.span.path, d, target) catch |err|
            cli.fatal("\n{s}: writing the directory: {s}; copy {t} is still intact", .{ s.span.path, @errorName(err), d.source });
        verify(gpa, io, s, d, target) catch |err|
            cli.fatal("\n{s}: the directory written does not read back: {s}", .{ s.span.path, @errorName(err) });
        try out.writeAll("\twritten\n");
    }
    try out.flush();
    if (failed) std.process.exit(1);
}

fn printUrl(out: *Io.Writer, key: *const cyclone.CacheKey, text: []const u8) !void {
    var buf: [128]u8 = undefined;
    const hex = std.fmt.bufPrint(&buf, "{f}", .{key.*}) catch "";
    if (!std.mem.eql(u8, hex, text)) try out.print("\t{s}", .{text});
    try out.writeByte('\n');
}

fn spanIndex(spans: []const cyclone.Span, span: *const cyclone.Span) usize {
    for (spans, 0..) |*s, i| if (s == span) return i;
    unreachable;
}

/// Refuses to go on while another process has a span open, and warns about
/// ATS shared-memory directories, which a restart would use instead of the
/// directory written here.
fn checkSafe(arena: std.mem.Allocator, io: Io, spans: []const cli.SpanArg, shm_prefix: []const u8) !void {
    var unreadable: usize = 0;
    for (spans) |s| {
        const o = cyclone.guard.openers(arena, io, s.path) catch |err|
            cli.fatal("{s}: cannot check which processes have it open: {s}", .{ s.path, @errorName(err) });
        if (o.found.len != 0) {
            for (o.found) |p| std.debug.print("cyc: {s} is open in process {d} ({s})\n", .{ s.path, p.pid, p.name });
            cli.fatal("stop ATS (and anything else using the spans) before deleting", .{});
        }
        unreadable = @max(unreadable, o.unreadable);
    }
    if (unreadable != 0)
        std.debug.print("cyc: note: could not see the open files of {d} processes (other users'); run as root to check them too\n", .{unreadable});
    const shm = try cyclone.guard.shmSegments(arena, io, shm_prefix);
    if (shm.len != 0) {
        std.debug.print("cyc: warning: /dev/shm has {d} ATS shared-memory segment(s) ({s}-*). With\n" ++
            "     proxy.config.cache.shm.enabled, ATS restarts from those instead of the\n" ++
            "     directory on disk, and these deletions would be undone. Remove them\n" ++
            "     before starting ATS.\n", .{ shm.len, shm_prefix });
    }
}

fn writeCopy(io: Io, path: []const u8, d: *const Directory, target: cyclone.format.stripe.Copy) !void {
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try d.write(io, file, target);
}

/// Opens the stripe again from disk: ATS must now choose the copy written,
/// and it must hold exactly what was meant to be written.
fn verify(gpa: std.mem.Allocator, io: Io, s: *const cyclone.Stripe, d: *const Directory, target: cyclone.format.stripe.Copy) !void {
    var again = try cyclone.Stripe.open(gpa, io, s.span, s.block_index, s.avg_obj_size);
    defer again.close(gpa);
    if (again.chosen != target) return error.OtherCopyChosen;
    var back = try Directory.read(gpa, io, &again);
    defer back.deinit(gpa);
    if (!std.mem.eql(u8, back.raw, d.raw)) return error.ContentDiffers;
}
