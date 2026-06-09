const std = @import("std");
const testing = std.testing;
const gitmeta = @import("gitmeta.zig");
const tu = @import("testutil.zig");
const gpa = tu.gpa;

fn seededRepo() !tu.Repo {
    var repo = try tu.Repo.init();
    errdefer repo.deinit();
    try repo.writeAndCommit("a.md", "# a\n", "Add a");
    return repo;
}

test "Pool: get reuses cache for unchanged HEAD" {
    try tu.requireGit();
    var repo = try seededRepo();
    defer repo.deinit();

    var pool = gitmeta.Pool.init(gpa);
    defer pool.deinit();

    const c1 = (try pool.get(repo.root)) orelse return error.UnexpectedNull;
    const c2 = (try pool.get(repo.root)) orelse return error.UnexpectedNull;
    try testing.expectEqual(c1, c2); // same pointer, no rebuild
    try testing.expectEqual(@as(usize, 1), pool.len());
}

test "Pool: HEAD change rebuilds" {
    try tu.requireGit();
    var repo = try seededRepo();
    defer repo.deinit();

    var pool = gitmeta.Pool.init(gpa);
    defer pool.deinit();

    const c1 = (try pool.get(repo.root)) orelse return error.UnexpectedNull;
    const first_head = try gpa.dupe(u8, c1.headSHA());
    defer gpa.free(first_head);

    try repo.writeAndCommit("b.md", "# b\n", "Add b");

    const c2 = (try pool.get(repo.root)) orelse return error.UnexpectedNull;
    try testing.expect(c1 != c2); // rebuilt
    try testing.expect(!std.mem.eql(u8, c2.headSHA(), first_head));

    const b = try repo.path("b.md");
    defer gpa.free(b);
    try testing.expect(c2.lookup(b) != null);
    try testing.expectEqual(@as(usize, 1), pool.len());
}

test "Pool: concurrent get is race-free" {
    try tu.requireGit();
    var repo = try seededRepo();
    defer repo.deinit();

    var pool = gitmeta.Pool.init(gpa);
    defer pool.deinit();

    const n = 8;
    const Worker = struct {
        fn run(p: *gitmeta.Pool, root: []const u8, out: *?*gitmeta.Cache) void {
            out.* = p.get(root) catch null;
        }
    };
    var threads: [n]std.Thread = undefined;
    var results: [n]?*gitmeta.Cache = .{null} ** n;
    for (0..n) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{ &pool, repo.root, &results[i] });
    }
    for (0..n) |i| threads[i].join();

    for (results) |r| try testing.expect(r != null);
    // Racing first-builders may transiently differ, but exactly one entry
    // survives.
    try testing.expectEqual(@as(usize, 1), pool.len());
}

test "Pool: non-git tree returns null, stores nothing" {
    try tu.requireGit();
    var dir = try tu.NonGitDir.init();
    defer dir.deinit();

    var pool = gitmeta.Pool.init(gpa);
    defer pool.deinit();

    const c = try pool.get(dir.abs);
    try testing.expect(c == null);
    try testing.expectEqual(@as(usize, 0), pool.len());
}

test "Pool: warm primes the cache" {
    try tu.requireGit();
    var repo = try seededRepo();
    defer repo.deinit();

    var pool = gitmeta.Pool.init(gpa);
    defer pool.deinit();

    try pool.warm(repo.root);
    try testing.expectEqual(@as(usize, 1), pool.len());

    const c = (try pool.get(repo.root)) orelse return error.UnexpectedNull;
    try testing.expect(c.headSHA().len != 0);
}
