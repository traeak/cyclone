//! Command line helpers shared by the cyc-* tools.

const std = @import("std");
const HashType = @import("hash.zig").HashType;

/// Walks argv one option at a time.
pub const ArgIterator = struct {
    args: []const [:0]const u8,
    index: usize = 1,

    pub fn init(args: []const [:0]const u8) ArgIterator {
        return .{ .args = args };
    }

    pub fn next(self: *ArgIterator) ?[:0]const u8 {
        if (self.index >= self.args.len) return null;
        defer self.index += 1;
        return self.args[self.index];
    }

    /// The value that follows `flag`; exits with a usage error when missing.
    pub fn value(self: *ArgIterator, flag: []const u8) [:0]const u8 {
        return self.next() orelse fatal("{s} needs a value", .{flag});
    }
};

/// One `--span` and the options that follow it.
pub const SpanArg = struct {
    path: []const u8,
    /// `--seed`: storage.yaml `hash_seed`, or the path as ATS was configured
    /// with it, when that differs from `path`.
    seed: ?[]const u8 = null,
    /// `--skip`: byte offset of the span header, when not found by probing.
    skip: ?u64 = null,
};

/// Options every tool accepts.
pub const Common = struct {
    hash_type: HashType = .default,
    /// Spans in the order ATS was configured with them.
    spans: std.ArrayList(SpanArg) = .empty,

    pub const hash_help =
        \\  --hash md5|sha256   cache key hash; ATS does not record it on disk (default: md5)
        \\
    ;
    pub const span_help =
        \\  --span PATH         cache span, repeatable, in storage.yaml order
        \\    --seed TEXT       name ATS hashed for this span: storage.yaml hash_seed, or
        \\                      the configured path if PATH differs (default: PATH)
        \\    --skip BYTES      span header offset (default: probe from 8192)
        \\
    ;
    pub const help = hash_help ++ span_help;

    /// Handles `arg` if it is a common option. Returns false otherwise.
    pub fn parse(self: *Common, gpa: std.mem.Allocator, arg: []const u8, it: *ArgIterator) !bool {
        if (std.mem.eql(u8, arg, "--hash")) {
            const name = it.value(arg);
            self.hash_type = HashType.parse(name) orelse fatal("unknown hash type '{s}'", .{name});
        } else if (std.mem.eql(u8, arg, "--span")) {
            try self.spans.append(gpa, .{ .path = it.value(arg) });
        } else if (std.mem.eql(u8, arg, "--seed")) {
            self.lastSpan(arg).seed = it.value(arg);
        } else if (std.mem.eql(u8, arg, "--skip")) {
            const text = it.value(arg);
            self.lastSpan(arg).skip = std.fmt.parseInt(u64, text, 0) catch fatal("bad --skip '{s}'", .{text});
        } else {
            return false;
        }
        return true;
    }

    fn lastSpan(self: *Common, flag: []const u8) *SpanArg {
        if (self.spans.items.len == 0) fatal("{s} must follow a --span", .{flag});
        return &self.spans.items[self.spans.items.len - 1];
    }
};

/// Prints `cyc: <message>` to stderr and exits with status 2.
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cyc: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

test ArgIterator {
    const argv = [_][:0]const u8{ "cyc-key", "--hash", "sha256", "--span", "a.db", "--seed", "/dev/sdb", "--skip", "0x4000", "--span", "b.db" };
    var it: ArgIterator = .init(&argv);
    var common: Common = .{};
    defer common.spans.deinit(std.testing.allocator);
    while (it.next()) |arg| {
        try std.testing.expect(try common.parse(std.testing.allocator, arg, &it));
    }
    try std.testing.expectEqual(HashType.sha256, common.hash_type);
    try std.testing.expectEqualStrings("a.db", common.spans.items[0].path);
    try std.testing.expectEqualStrings("/dev/sdb", common.spans.items[0].seed.?);
    try std.testing.expectEqual(0x4000, common.spans.items[0].skip.?);
    try std.testing.expectEqual(null, common.spans.items[1].seed);
}
