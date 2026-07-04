# gitmeta-zig

[![CI](https://github.com/richardwooding/gitmeta-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/richardwooding/gitmeta-zig/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Zig 0.16](https://img.shields.io/badge/Zig-0.16.0-f7a41d.svg)](https://ziglang.org/)

**Website:** [richardwooding.github.io/gitmeta-zig](https://richardwooding.github.io/gitmeta-zig/)

Fast **per-file git metadata** for Zig — last-commit time / author / subject,
first-seen, commit count (churn), and tracked / ignored status — resolved by
scanning a working tree **once** and answering per-path lookups in constant
time. **Zero dependencies** (shells out to the system `git` binary).

The batch design is the point: one `Cache` runs `git ls-files` + a single
`git log` pass up front, so a 10k-file / 5k-commit repo costs **one** git
invocation (~½ s) instead of 10k `git log -1 -- <path>` calls (~100 s).

This is a Zig port of the Go library
[richardwooding/gitmeta](https://github.com/richardwooding/gitmeta).

## Install

```sh
zig fetch --save git+https://github.com/richardwooding/gitmeta-zig
```

Then wire the module into your `build.zig`:

```zig
const gitmeta = b.dependency("gitmeta", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("gitmeta", gitmeta.module("gitmeta"));
```

## One-shot Cache

```zig
const gitmeta = @import("gitmeta");

// Returns null when `root` isn't a git working tree (or git isn't on PATH) —
// treat that as "no git data", not an error. Hard failures return an error.
const cache = (try gitmeta.New(gpa, "/path/to/repo")) orelse return;
defer cache.deinit();

if (cache.lookup("/path/to/repo/main.zig")) |info| {
    std.debug.print("{d} {s} {d}\n", .{
        info.last_commit_time, // unix seconds, UTC
        info.last_commit_author,
        info.commit_count,
    });
}

_ = cache.isTracked(path); // bool
_ = cache.isIgnored(path); // bool
```

`lookup` returns a `FileGitInfo`:

```zig
pub const FileGitInfo = struct {
    last_commit_time: i64,            // unix seconds (UTC); 0 = unknown
    last_commit_author: []const u8,
    last_commit_subject: []const u8,
    first_seen: i64,
    commit_count: usize,              // churn proxy
};
```

The string fields are owned by the `Cache` and live until `cache.deinit()`.

Why git rather than filesystem mtimes? A fresh clone sets every file's mtime to
checkout time — so "recently changed" / "hot file" questions need git history,
not the filesystem.

## Pool — reuse across calls

A `Pool` keeps one `Cache` per repo and **re-validates on HEAD change**, so
repeated lookups over an unchanging tree don't re-scan. Ideal for a
long-running process (server, watcher, language tooling) that answers many
git-metadata queries. Safe for concurrent use.

```zig
var pool = gitmeta.Pool.init(gpa);
defer pool.deinit();

const cache = (try pool.get(root)) orelse return; // built once, refreshed when HEAD moves
// `cache` is owned by the pool — do NOT deinit it yourself.
```

## Try it

```sh
zig build example   # scans this repo and prints metadata for build.zig
zig build test      # runs the test suite (creates throwaway git repos)
```

## Requirements

- **Zig 0.16.0**, zero third-party dependencies.
- The system **`git`** binary on `PATH` (`gitmeta.hasGitBinary(gpa)` reports its
  presence; `New` returns `null` when git is absent or the path isn't a working
  tree).
- POSIX (Linux / macOS). Windows path handling is out of scope.

## Differences from the Go original

- No `context.Context` — git subprocesses are short-lived, so `New` takes just
  `(allocator, root)`.
- Times are `i64` Unix seconds (UTC) rather than a `time.Time`.
- The Go nil-`*Cache` contract becomes an optional return: `New` yields
  `?*Cache`, and `null` is the "no git data" signal.

## License

MIT — see [LICENSE](LICENSE).
