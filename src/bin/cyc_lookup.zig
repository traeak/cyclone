//! cyc-lookup: Locate a cache key in the cache volumes
//!
//! Not implemented yet; see PLAN.md, Phase 2.

const std = @import("std");
const cyclone = @import("cyclone");
const cli = cyclone.cli;

const usage =
    \\usage: cyc-lookup --span PATH... [--volume N] (--key HEX | --url URL)
    \\
    \\Locate a cache key in the cache volumes.
    \\
    \\options:
    \\
++ cli.Common.help;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var common: cli.Common = .{};
    var it: cli.ArgIterator = .init(args);
    while (it.next()) |arg| {
        if (cli.isHelp(arg)) {
            std.debug.print("{s}", .{usage});
            return;
        }
        if (try common.parse(init.arena.allocator(), arg, &it)) continue;
        cli.fatal("unknown argument '{s}'\n\n{s}", .{ arg, usage });
    }
    cli.fatal("cyc-lookup is not implemented yet", .{});
}
