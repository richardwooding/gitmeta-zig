//! gitmeta resolves per-file git metadata (last-commit time + author +
//! subject, first-seen, churn, tracked/ignored status) for a single
//! working tree by shelling out to the system `git` binary once per
//! scan.
//!
//! One `Cache` scans the entire repository up front (`git ls-files`,
//! `git ls-files --others --ignored`, and a single `git log` pass keyed
//! by HEAD), then answers per-path `lookup` / `isTracked` / `isIgnored`
//! in constant time. The batch architecture is dramatically cheaper
//! than per-file `git log -1 -- <path>` on any non-trivial repo — a
//! 10k-file tree with 5k commits costs one git invocation (~½ s), not
//! 10k (~100 s).
//!
//! `New` returns `null` (not an error) when the supplied root isn't
//! inside a git working tree, or when the `git` binary isn't on PATH —
//! callers MUST handle `null` and treat it as the "no git data; leave
//! fields at their zero values" signal rather than a hard failure. This
//! is the Zig analogue of the Go original's nil-`*Cache` contract. Hard
//! errors (a present-but-broken git: subprocess crash, OOM) surface as
//! a returned `error`. A `Pool` (pool.zig) caches one `Cache` per repo
//! across calls and re-validates on HEAD change.
//!
//! Ported from the Go library github.com/richardwooding/gitmeta.
//! POSIX (Linux/macOS) only — Windows path handling is out of scope.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pool = @import("pool.zig").Pool;

/// Errors a scan can surface. `GitCommandFailed` wraps a non-zero git
/// exit (the failing command's stderr is emitted via `std.log.debug`,
/// since Zig errors can't carry a payload).
pub const Error = error{GitCommandFailed} || Allocator.Error || std.process.RunError;

/// FileGitInfo carries the per-file metadata `Cache` resolves for every
/// tracked path. Times are Unix seconds (UTC); `0` means "unknown".
/// Zero values are meaningful: a fresh commit's `commit_count == 1` and
/// `first_seen == last_commit_time`. The string fields are owned by the
/// `Cache` that produced this value and live until `cache.deinit()`.
pub const FileGitInfo = struct {
    last_commit_time: i64 = 0,
    last_commit_author: []const u8 = "",
    last_commit_subject: []const u8 = "",
    first_seen: i64 = 0,
    commit_count: usize = 0,
};

/// Cache is the per-repository scan result. Build via `New`; consult via
/// `lookup` / `isTracked` / `isIgnored`. Effectively immutable after
/// construction and safe for concurrent reads. All owned memory lives in
/// an internal arena freed wholesale by `deinit`.
pub const Cache = struct {
    /// Backs every string and map this Cache owns. Freed by `deinit`.
    arena: std.heap.ArenaAllocator,

    /// Git's canonical view of the working-tree root (the output of
    /// `git rev-parse --show-toplevel`). On macOS this is the realpath
    /// form (e.g. /private/tmp/...), which can differ from the
    /// symlinked /tmp/... form a caller might pass.
    repo_root: []const u8 = "",

    /// The as-supplied absolute root, pre-symlink-resolution, when it
    /// differs from `repo_root` (the macOS /tmp ↔ /private/tmp case);
    /// otherwise empty. `toRel` tries it as a fallback prefix so callers
    /// can pass walk-derived paths without resolving symlinks first.
    repo_root_alt: []const u8 = "",

    /// HEAD commit SHA at scan time; "" for a freshly-init'd empty repo.
    head_sha: []const u8 = "",

    /// Keyed by repo-relative forward-slash path (the form `ls-files`
    /// emits). `lookup` callers pass an absolute path; conversion
    /// happens inside.
    files: std.StringHashMapUnmanaged(FileGitInfo) = .empty,

    /// Set membership. `tracked`: path is in the git index. `ignored`:
    /// path is matched by an ignore rule and not in the index.
    tracked: std.StringHashMapUnmanaged(void) = .empty,
    ignored: std.StringHashMapUnmanaged(void) = .empty,

    /// Frees all memory owned by the Cache and destroys it. After this
    /// the pointer is invalid. Capture the backing allocator before
    /// tearing down the arena (the arena owns the only reference to it).
    pub fn deinit(self: *Cache) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self);
    }

    /// The repository's top-level absolute directory (git's canonical
    /// `rev-parse --show-toplevel`). Exposed so callers can rebase a
    /// walk root against it.
    pub fn repoRoot(self: *const Cache) []const u8 {
        return self.repo_root;
    }

    /// The HEAD commit SHA current when the Cache was built. Useful for
    /// invalidation when results are persisted across processes.
    pub fn headSHA(self: *const Cache) []const u8 {
        return self.head_sha;
    }

    /// Returns git metadata for `abs_path`, or `null` when it isn't
    /// tracked by git in this working tree (untracked, ignored, or
    /// outside the repo). Leave git fields at their zero values then.
    pub fn lookup(self: *const Cache, abs_path: []const u8) ?FileGitInfo {
        const rel = self.toRel(abs_path) orelse return null;
        return self.files.get(rel);
    }

    /// Boolean-only form of `lookup`: true when `abs_path` is in git's
    /// index for this working tree.
    pub fn isTracked(self: *const Cache, abs_path: []const u8) bool {
        const rel = self.toRel(abs_path) orelse return false;
        return self.tracked.contains(rel);
    }

    /// True when `abs_path` is matched by a git ignore rule but not in
    /// the index. Tracked files are never reported as ignored, matching
    /// git's own `check-ignore` semantics.
    pub fn isIgnored(self: *const Cache, abs_path: []const u8) bool {
        const rel = self.toRel(abs_path) orelse return false;
        return self.ignored.contains(rel);
    }

    /// Converts `abs_path` to a forward-slash repo-relative key, or
    /// `null` when it isn't inside the repo (such paths can't have git
    /// metadata for THIS cache). Tries `repo_root` first (git's
    /// canonical view) then `repo_root_alt` (the as-supplied root) to
    /// cover the macOS /tmp ↔ /private/tmp symlink case — one alloc-free
    /// comparison rather than a realpath stat per lookup.
    fn toRel(self: *const Cache, abs_path: []const u8) ?[]const u8 {
        if (abs_path.len == 0) return null;
        if (relUnder(self.repo_root, abs_path)) |rel| return rel;
        if (self.repo_root_alt.len != 0) {
            if (relUnder(self.repo_root_alt, abs_path)) |rel| return rel;
        }
        return null;
    }
};

/// Inner prefix check: returns the portion of `abs_path` below `base`,
/// or `null` when `abs_path` isn't under `base`. POSIX-only: keys are
/// already forward-slash (the form `ls-files` emits).
fn relUnder(base: []const u8, abs_path: []const u8) ?[]const u8 {
    if (base.len == 0) return null;
    if (!std.mem.startsWith(u8, abs_path, base)) return null;
    if (abs_path.len == base.len) return ""; // exactly the root
    if (abs_path[base.len] != '/') return null; // sibling, not a child
    return abs_path[base.len + 1 ..];
}

/// Scans the git working tree containing `root` and returns a `*Cache`
/// the caller owns (free with `cache.deinit()`). Returns `null` when
/// `root` is not inside any git working tree, or the `git` binary is
/// absent — the silent-skip path callers treat as "no git data".
/// Returns an `error` only on hard failures (subprocess crash, OOM).
///
/// After the initial rev-parse, the scan runs three git invocations in
/// sequence (two ls-files passes and one log pass).
pub fn New(gpa: Allocator, root: []const u8) Error!?*Cache {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Not a git repo (or git not on PATH) → silent skip, like the Go
    // original's (nil, nil).
    const top_raw = runGit(gpa, io, root, &.{ "git", "rev-parse", "--show-toplevel" }) catch return null;
    defer gpa.free(top_raw);
    const canonical = std.mem.trim(u8, top_raw, " \t\r\n");
    if (canonical.len == 0) return null;

    const cache = try gpa.create(Cache);
    cache.* = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer cache.deinit();
    const a = cache.arena.allocator();

    cache.repo_root = try a.dupe(u8, canonical);
    cache.repo_root_alt = try altRoot(a, root, cache.repo_root);

    // HEAD missing (empty repo, freshly init'd) — still a valid tree but
    // no commits to walk. Build an empty cache so isTracked/isIgnored
    // still answer.
    const head_raw = runGit(gpa, io, cache.repo_root, &.{ "git", "rev-parse", "HEAD" }) catch {
        try fillTrackedIgnored(cache, gpa, io);
        return cache;
    };
    defer gpa.free(head_raw);
    cache.head_sha = try a.dupe(u8, std.mem.trim(u8, head_raw, " \t\r\n"));

    try fillTrackedIgnored(cache, gpa, io);
    try fillLog(cache, gpa, io);
    return cache;
}

/// True when the `git` executable is runnable. Lets CLI callers warn up
/// front rather than silently producing empty metadata.
pub fn hasGitBinary(gpa: Allocator) bool {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const out = runGit(gpa, io, ".", &.{ "git", "--version" }) catch return false;
    gpa.free(out);
    return true;
}

/// Resolves git's canonical toplevel for `root` (the key `Pool` uses),
/// or `null` when `root` isn't inside a git tree / git is absent. The
/// returned slice is owned by `gpa`. Shares the caller's `io` so the
/// Pool doesn't spin up a thread pool per probe.
pub fn revParseToplevel(gpa: Allocator, io: std.Io, root: []const u8) Allocator.Error!?[]u8 {
    const raw = runGit(gpa, io, root, &.{ "git", "rev-parse", "--show-toplevel" }) catch return null;
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try gpa.dupe(u8, trimmed);
}

/// Resolves HEAD's SHA for `root`, or `null` when there's no HEAD (empty
/// repo) or git fails. The returned slice is owned by `gpa`. Used by
/// `Pool` for staleness checks.
pub fn revParseHead(gpa: Allocator, io: std.Io, root: []const u8) Allocator.Error!?[]u8 {
    const raw = runGit(gpa, io, root, &.{ "git", "rev-parse", "HEAD" }) catch return null;
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try gpa.dupe(u8, trimmed);
}

/// Returns the as-supplied root as an absolute path duped into `a` when
/// it differs from git's canonical view (the macOS /tmp → /private/tmp
/// symlink case), else "". Only handles an already-absolute `root`; a
/// relative root gets no alt fallback (callers pass absolute walk
/// roots, matching the Go original's filepath.Walk usage).
fn altRoot(a: Allocator, root: []const u8, canonical: []const u8) Allocator.Error![]const u8 {
    if (!std.fs.path.isAbsolute(root)) return "";
    var cleaned = root;
    while (cleaned.len > 1 and cleaned[cleaned.len - 1] == '/') cleaned = cleaned[0 .. cleaned.len - 1];
    if (std.mem.eql(u8, cleaned, canonical)) return "";
    return a.dupe(u8, cleaned);
}

fn fillTrackedIgnored(cache: *Cache, gpa: Allocator, io: std.Io) Error!void {
    const a = cache.arena.allocator();

    const tracked_raw = try runGit(gpa, io, cache.repo_root, &.{ "git", "ls-files", "-z" });
    defer gpa.free(tracked_raw);
    try fillSet(&cache.tracked, a, tracked_raw);

    // Ignored detection doesn't need a HEAD, so it runs for empty repos
    // too. A failure here degrades to "no ignored data" rather than
    // failing the whole scan.
    const ignored_raw = runGit(gpa, io, cache.repo_root, &.{ "git", "ls-files", "--others", "--ignored", "--exclude-standard", "-z" }) catch return;
    defer gpa.free(ignored_raw);
    try fillSet(&cache.ignored, a, ignored_raw);
}

/// Splits NUL-delimited git output (`-z`) into the given set, duping
/// each key into the arena and discarding the trailing empty record git
/// always emits.
fn fillSet(set: *std.StringHashMapUnmanaged(void), a: Allocator, raw: []const u8) Allocator.Error!void {
    if (raw.len == 0) return;
    var it = std.mem.splitScalar(u8, raw, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const key = try a.dupe(u8, entry);
        try set.put(a, key, {});
    }
}

/// Parses one `git log --name-only` pass. Walk format per commit:
///
///     COMMIT\t<sha>\t<unix-time>\t<author>\t<subject>\n
///     <path>\n
///     <path>\n
///     \n
///
/// Commits arrive newest-first (git's default order). For each path:
///   - FIRST sighting  → fixes last_commit_{time,author,subject}
///   - every sighting  → overwrites first_seen (oldest wins) + bumps count
fn fillLog(cache: *Cache, gpa: Allocator, io: std.Io) Error!void {
    const raw = try runGit(gpa, io, cache.repo_root, &.{
        "git",          "log",
        "--name-only",  "--format=COMMIT\t%H\t%at\t%an\t%s",
        "--no-renames", "HEAD",
    });
    defer gpa.free(raw);

    const a = cache.arena.allocator();
    var cur_time: i64 = 0;
    var cur_author: []const u8 = "";
    var cur_subject: []const u8 = "";
    var have_commit = false;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "COMMIT\t")) {
            const c = parseCommitLine(line["COMMIT\t".len..]) orelse continue;
            cur_time = c.time;
            cur_author = c.author;
            cur_subject = c.subject;
            have_commit = true;
            continue;
        }
        if (!have_commit) continue; // defensive; shouldn't happen

        const gop = try cache.files.getOrPut(a, line);
        if (!gop.found_existing) {
            // First (newest) sighting fixes last-commit fields. Dup the
            // key and author/subject into the arena; older sightings
            // need no allocation. NOTE: getOrPut keyed on the borrowed
            // `line`; overwrite key_ptr with an owned copy immediately.
            gop.key_ptr.* = try a.dupe(u8, line);
            gop.value_ptr.* = .{
                .last_commit_time = cur_time,
                .last_commit_author = try a.dupe(u8, cur_author),
                .last_commit_subject = try a.dupe(u8, cur_subject),
                .first_seen = cur_time,
                .commit_count = 0,
            };
        }
        gop.value_ptr.first_seen = cur_time;
        gop.value_ptr.commit_count += 1;
    }
}

const CommitLine = struct { time: i64, author: []const u8, subject: []const u8 };

/// Parses `<sha>\t<unix-time>\t<author>\t<subject>` (the part after the
/// "COMMIT\t" tag). Subject keeps any embedded tabs, matching the Go
/// original's SplitN(..., 4). Returns null if malformed or the time
/// doesn't parse.
fn parseCommitLine(rest: []const u8) ?CommitLine {
    const t1 = std.mem.indexOfScalar(u8, rest, '\t') orelse return null;
    const after_sha = rest[t1 + 1 ..];
    const t2 = std.mem.indexOfScalar(u8, after_sha, '\t') orelse return null;
    const ts_str = after_sha[0..t2];
    const after_ts = after_sha[t2 + 1 ..];
    const t3 = std.mem.indexOfScalar(u8, after_ts, '\t') orelse return null;
    const author = after_ts[0..t3];
    const subject = after_ts[t3 + 1 ..];
    const time = std.fmt.parseInt(i64, ts_str, 10) catch return null;
    return .{ .time = time, .author = author, .subject = subject };
}

/// Shells out to git in `root` (via the run options' cwd). Returns
/// stdout (owned by `gpa`; caller frees) on a zero exit; otherwise
/// frees stdout, logs stderr, and returns `error.GitCommandFailed`.
fn runGit(gpa: Allocator, io: std.Io, root: []const u8, argv: []const []const u8) Error![]u8 {
    const res = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = root },
    });
    defer gpa.free(res.stderr);
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.log.debug("gitmeta: git command failed: {s}", .{std.mem.trim(u8, res.stderr, " \t\r\n")});
        gpa.free(res.stdout);
        return error.GitCommandFailed;
    }
    return res.stdout;
}

test {
    _ = @import("gitmeta_test.zig");
    _ = @import("pool_test.zig");
}
