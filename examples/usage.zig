//! Tiny demo: scan the current working tree once, then answer a per-file
//! lookup. Run with `zig build example`. (Prints to stderr via
//! std.debug.print to stay independent of the I/O setup.)

const std = @import("std");
const gitmeta = @import("gitmeta");

pub fn main() !void {
    var debug = std.heap.DebugAllocator(.{}){};
    defer _ = debug.deinit();
    const gpa = debug.allocator();

    const cache = (try gitmeta.New(gpa, ".")) orelse {
        std.debug.print(".: not a git working tree (or git not on PATH)\n", .{});
        return;
    };
    defer cache.deinit();

    std.debug.print("repo root: {s}\nHEAD: {s}\n\n", .{ cache.repoRoot(), cache.headSHA() });

    const sample = try std.fs.path.join(gpa, &.{ cache.repoRoot(), "build.zig" });
    defer gpa.free(sample);
    if (cache.lookup(sample)) |info| {
        std.debug.print(
            "build.zig — last commit @{d} by {s}: {s} ({d} commits)\n",
            .{ info.last_commit_time, info.last_commit_author, info.last_commit_subject, info.commit_count },
        );
    } else {
        std.debug.print("build.zig — no git metadata (untracked?)\n", .{});
    }
}
