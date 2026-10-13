//! Checks before writing to a span: no other process may have it open, and
//! ATS's shared-memory directories (which a restart would use instead of
//! the directory on disk) should not exist. Linux only: both look in /proc
//! and /dev/shm.

const std = @import("std");
const Io = std.Io;

pub const Opener = struct {
    pid: u32,
    /// The process name (`/proc/PID/comm`).
    name: []const u8,
};

pub const Openers = struct {
    found: []const Opener,
    /// Processes whose open files could not be read (another user's,
    /// without privilege): any of them might have the span open.
    unreadable: usize,
};

/// Other processes with `path` open, found by following each process's
/// `/proc/PID/fd` links and comparing them with `path`'s real path.
pub fn openers(arena: std.mem.Allocator, io: Io, path: []const u8) !Openers {
    const cwd = Io.Dir.cwd();
    const real = try cwd.realPathFileAlloc(io, path, arena);
    const self_pid: u32 = @intCast(std.os.linux.getpid());

    var found: std.ArrayList(Opener) = .empty;
    var unreadable: usize = 0;
    var proc = try cwd.openDir(io, "/proc", .{ .iterate = true });
    defer proc.close(io);
    var procs = proc.iterate();
    while (try procs.next(io)) |p| {
        const pid = std.fmt.parseInt(u32, p.name, 10) catch continue;
        if (pid == self_pid) continue;
        var path_buf: [64]u8 = undefined;
        const fd_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/fd", .{pid});
        var fds = cwd.openDir(io, fd_path, .{ .iterate = true }) catch {
            unreadable += 1;
            continue;
        };
        defer fds.close(io);
        var it = fds.iterate();
        while (it.next(io) catch null) |f| {
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = fds.readLink(io, f.name, &link_buf) catch continue;
            if (!std.mem.eql(u8, link_buf[0..n], real)) continue;
            try found.append(arena, .{ .pid = pid, .name = processName(arena, io, pid) });
            break;
        }
    }
    return .{ .found = found.items, .unreadable = unreadable };
}

fn processName(arena: std.mem.Allocator, io: Io, pid: u32) []const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return "?";
    // /proc files report size 0, so read until the end rather than by size.
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return "?";
    defer file.close(io);
    var buf: [64]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    const text = reader.interface.allocRemaining(arena, .limited(256)) catch return "?";
    return std.mem.trimEnd(u8, text, "\n");
}

/// Names in /dev/shm that ATS's shared-memory directories would use
/// (`proxy.config.cache.shm.name_prefix`, default "ats", then "-").
pub fn shmSegments(arena: std.mem.Allocator, io: Io, prefix: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var shm = Io.Dir.cwd().openDir(io, "/dev/shm", .{ .iterate = true }) catch return names.items;
    defer shm.close(io);
    var it = shm.iterate();
    while (try it.next(io)) |e| {
        if (e.name.len > prefix.len and std.mem.startsWith(u8, e.name, prefix) and e.name[prefix.len] == '-')
            try names.append(arena, try arena.dupe(u8, e.name));
    }
    return names.items;
}

test "finds a process holding a file open" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "span.db", .{});
    defer f.close(io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const path = try tmp.dir.realPathFileAlloc(io, "span.db", arena.allocator());
    // Only this process has it open, and it does not count itself.
    const o = try openers(arena.allocator(), io, path);
    try std.testing.expectEqual(0, o.found.len);
}
