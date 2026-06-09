//! Shared test helpers: throwaway git repos backed by `std.testing.tmpDir`,
//! plus a non-git scratch dir created outside the project tree (so
//! `git rev-parse` can't climb up to gitmeta-zig's own repository).
//!
//! Only ever compiled into the test build (pulled in via the test blocks
//! in gitmeta.zig), so referencing `std.testing.io` / `.allocator` here
//! is safe.

const std = @import("std");
const gitmeta = @import("gitmeta.zig");

pub const io = std.testing.io;
pub const gpa = std.testing.allocator;

/// A fresh git repo in a `std.testing.tmpDir`, with a deterministic
/// identity so commits don't depend on the runner's git config.
pub const Repo = struct {
    tmp: std.testing.TmpDir,
    /// Absolute, as-supplied root (pre-symlink-resolution) — the form a
    /// caller's walk would emit. Lookups build paths under this.
    root: []u8,

    pub fn init() !Repo {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        const root = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });

        var self = Repo{ .tmp = tmp, .root = root };
        try self.run(&.{ "git", "init", "-q", "-b", "main" });
        try self.run(&.{ "git", "config", "user.email", "test@example.com" });
        try self.run(&.{ "git", "config", "user.name", "Test User" });
        try self.run(&.{ "git", "config", "commit.gpgsign", "false" });
        return self;
    }

    pub fn deinit(self: *Repo) void {
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    /// Runs a git command inside the repo (cwd = the tmpdir handle) and
    /// fails the test on a non-zero exit.
    pub fn run(self: *Repo, argv: []const []const u8) !void {
        const res = try std.process.run(gpa, io, .{
            .argv = argv,
            .cwd = .{ .dir = self.tmp.dir },
        });
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        switch (res.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("git failed (exit {d}): {s}\n", .{ code, res.stderr });
                return error.GitCommandFailed;
            },
            else => return error.GitCommandFailed,
        }
    }

    pub fn writeFile(self: *Repo, rel: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = rel, .data = data });
    }

    pub fn writeAndCommit(self: *Repo, rel: []const u8, data: []const u8, msg: []const u8) !void {
        try self.writeFile(rel, data);
        try self.run(&.{ "git", "add", rel });
        try self.run(&.{ "git", "commit", "-q", "-m", msg });
    }

    /// Like `writeAndCommit` but pins the author date (which `%at`
    /// reports) to `unix_ts`, so tests get distinct, deterministic commit
    /// timestamps without sleeping.
    pub fn writeAndCommitAt(self: *Repo, rel: []const u8, data: []const u8, msg: []const u8, unix_ts: i64) !void {
        try self.writeFile(rel, data);
        try self.run(&.{ "git", "add", rel });
        const date = try std.fmt.allocPrint(gpa, "--date=@{d}", .{unix_ts});
        defer gpa.free(date);
        try self.run(&.{ "git", "commit", "-q", "-m", msg, date });
    }

    /// Absolute path under the repo root for a relative path. Caller frees.
    pub fn path(self: *Repo, rel: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.root, rel });
    }
};

/// A scratch directory under the OS temp location (outside the project
/// repo) with no `.git`, so `New` sees a genuinely non-git tree.
pub const NonGitDir = struct {
    abs: []u8,

    pub fn init() !NonGitDir {
        const base = "/tmp"; // outside the project tree, never a git repo
        var rnd: [12]u8 = undefined;
        io.random(&rnd);
        var name: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &rnd);
        const abs = try std.fs.path.join(gpa, &.{ base, "gitmeta-zig-test", &name });
        // sub_path is absolute, so the cwd handle is ignored by openat.
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, abs, .{});
        dir.close(io);
        return .{ .abs = abs };
    }

    pub fn deinit(self: *NonGitDir) void {
        std.Io.Dir.cwd().deleteTree(io, self.abs) catch {};
        gpa.free(self.abs);
    }
};

/// Skip the calling test when git isn't on PATH.
pub fn requireGit() !void {
    if (!gitmeta.hasGitBinary(gpa)) return error.SkipZigTest;
}
