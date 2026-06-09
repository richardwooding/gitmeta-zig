const std = @import("std");
const testing = std.testing;
const gitmeta = @import("gitmeta.zig");
const tu = @import("testutil.zig");
const gpa = tu.gpa;

test "New: single commit populates lookup" {
    try tu.requireGit();
    var repo = try tu.Repo.init();
    defer repo.deinit();
    try repo.writeAndCommit("hello.txt", "hi\n", "Add hello");

    const cache = (try gitmeta.New(gpa, repo.root)) orelse return error.UnexpectedNull;
    defer cache.deinit();

    try testing.expect(cache.repoRoot().len != 0);
    try testing.expect(cache.headSHA().len != 0);

    const abs = try repo.path("hello.txt");
    defer gpa.free(abs);
    const info = cache.lookup(abs) orelse return error.LookupFailed;

    try testing.expectEqual(@as(usize, 1), info.commit_count);
    try testing.expectEqualStrings("Test User", info.last_commit_author);
    try testing.expectEqualStrings("Add hello", info.last_commit_subject);
    try testing.expect(info.last_commit_time != 0);
    try testing.expectEqual(info.last_commit_time, info.first_seen); // single commit
}

test "New: multiple commits accumulate" {
    try tu.requireGit();
    var repo = try tu.Repo.init();
    defer repo.deinit();

    // Deterministic, distinct author dates (what %at reports) so we don't
    // depend on wall-clock sleeps.
    try repo.writeAndCommitAt("doc.md", "v1\n", "Initial draft", 1_000_000_000);
    try repo.writeAndCommitAt("doc.md", "v2\n", "Edit pass", 1_000_000_060);
    try repo.writeAndCommitAt("doc.md", "v3\n", "Final pass", 1_000_000_120);

    const cache = (try gitmeta.New(gpa, repo.root)) orelse return error.UnexpectedNull;
    defer cache.deinit();

    const abs = try repo.path("doc.md");
    defer gpa.free(abs);
    const info = cache.lookup(abs) orelse return error.LookupFailed;

    try testing.expectEqual(@as(usize, 3), info.commit_count);
    try testing.expectEqualStrings("Final pass", info.last_commit_subject);
    try testing.expect(info.first_seen < info.last_commit_time);
}

test "New: non-git tree returns null" {
    try tu.requireGit();
    var dir = try tu.NonGitDir.init();
    defer dir.deinit();

    const cache = try gitmeta.New(gpa, dir.abs);
    try testing.expect(cache == null);
}

test "isTracked: only for indexed files" {
    try tu.requireGit();
    var repo = try tu.Repo.init();
    defer repo.deinit();
    try repo.writeAndCommit("tracked.txt", "in\n", "Add tracked");
    try repo.writeFile("untracked.txt", "out\n");

    const cache = (try gitmeta.New(gpa, repo.root)) orelse return error.UnexpectedNull;
    defer cache.deinit();

    const tracked = try repo.path("tracked.txt");
    defer gpa.free(tracked);
    const untracked = try repo.path("untracked.txt");
    defer gpa.free(untracked);

    try testing.expect(cache.isTracked(tracked));
    try testing.expect(!cache.isTracked(untracked));
}

test "isIgnored: matches gitignore but not the indexed gitignore" {
    try tu.requireGit();
    var repo = try tu.Repo.init();
    defer repo.deinit();
    try repo.writeFile(".gitignore", "*.log\n");
    try repo.run(&.{ "git", "add", ".gitignore" });
    try repo.run(&.{ "git", "commit", "-q", "-m", "Add gitignore" });
    try repo.writeFile("build.log", "noise\n");

    const cache = (try gitmeta.New(gpa, repo.root)) orelse return error.UnexpectedNull;
    defer cache.deinit();

    const log = try repo.path("build.log");
    defer gpa.free(log);
    const ignore = try repo.path(".gitignore");
    defer gpa.free(ignore);

    try testing.expect(cache.isIgnored(log));
    try testing.expect(!cache.isIgnored(ignore)); // it's in the index
}

test "lookup: path outside repo returns null" {
    try tu.requireGit();
    var repo = try tu.Repo.init();
    defer repo.deinit();
    try repo.writeAndCommit("in.txt", "x\n", "Add");

    const cache = (try gitmeta.New(gpa, repo.root)) orelse return error.UnexpectedNull;
    defer cache.deinit();

    try testing.expect(cache.lookup("/some/other/place/in.txt") == null);
}
