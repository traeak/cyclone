const std = @import("std");

/// Command line tools. Each one is a thin front end over the `cyclone` module.
const tools = [_]struct { name: []const u8, src: []const u8, desc: []const u8 }{
    .{ .name = "cyc-key", .src = "src/bin/cyc_key.zig", .desc = "Make an ATS cache key from a cache-key URL" },
    .{ .name = "cyc-doc", .src = "src/bin/cyc_doc.zig", .desc = "Read a whole cached object" },
    .{ .name = "cyc-lookup", .src = "src/bin/cyc_lookup.zig", .desc = "Locate a cache key in the cache volumes" },
    .{ .name = "cyclone-d", .src = "src/bin/cyclone_d.zig", .desc = "Serve lookups and objects over HTTP/1.1" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("cyclone", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    for (tools) |tool| {
        const exe = b.addExecutable(.{
            .name = tool.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(tool.src),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "cyclone", .module = mod }},
            }),
        });
        b.installArtifact(exe);

        // `zig build cyc-key -- ARGS` builds and runs one tool.
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();
        b.step(tool.name, tool.desc).dependOn(&run_cmd.step);

        const exe_tests = b.addTest(.{ .root_module = exe.root_module });
        test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    }
}
