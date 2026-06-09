# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`gitmeta-zig` is a zero-dependency Zig library that resolves **per-file git metadata** (last-commit time/author/subject, first-seen, commit count, tracked/ignored status) by scanning a working tree once and answering per-path lookups in constant time. It shells out to the system `git` binary — no third-party deps. It is a port of the Go library [richardwooding/gitmeta](https://github.com/richardwooding/gitmeta); consult that repo for the original design notes.

## Commands

```sh
zig build                       # compile the module + example
zig build test                  # run all tests
zig build test --summary all    # tests with per-step summary
zig build example               # run the demo against this repo
zig fmt --check build.zig src examples   # formatting gate (CI enforces it)
zig fmt build.zig src examples           # auto-format
```

Targets **Zig 0.16.0** (pinned in `build.zig.zon` and CI). The 0.16 std library threads an explicit `std.Io` instance through subprocess, filesystem, and synchronization APIs — see Architecture. CI runs `zig fmt --check`, `zig build`, and `zig build test` via `mlugg/setup-zig@v2`.

Tests create throwaway git repos and make real commits, so a git identity must exist (CI sets a global one). Tests `return error.SkipZigTest` when no `git` binary is on PATH. Commit timestamps are pinned with `git commit --date=@<unix>` so multi-commit tests are deterministic without sleeping.

## Architecture

The whole design rests on **batching git invocations**. The naive approach — `git log -1 -- <path>` per file — is O(files) subprocesses. Instead `New` runs a fixed handful of git commands once and builds in-memory maps, making each subsequent `lookup`/`isTracked`/`isIgnored` a map read.

Source files:

- **`src/gitmeta.zig` — `Cache` + `New`**: the per-repo scan result. `New(gpa, root)` runs `rev-parse --show-toplevel`, `rev-parse HEAD`, two `ls-files` passes (tracked; others+ignored), and one `git log --name-only` pass. The log is parsed newest-first: the first appearance of a path fixes `last_commit_*`, every appearance overwrites `first_seen` (so the oldest wins) and bumps `commit_count`. Also holds `hasGitBinary` and the shared `runGit`/`revParseToplevel`/`revParseHead` helpers (the latter two are `pub` for the Pool).
- **`src/pool.zig` — `Pool`**: caches one `*Cache` per canonical repo root, keyed by `git rev-parse --show-toplevel`. `get` re-runs `rev-parse HEAD` every call and rebuilds only when HEAD moved. Concurrency-safe via `std.Io.RwLock`.
- **`src/testutil.zig`, `src/*_test.zig`**: test helpers and the ported test suite, pulled into the build by the `test {}` block in `gitmeta.zig`.

### Invariants that pervade the code

1. **`null` `Cache` means "no git data", not an error.** `New` returns `null` (not an error) when `root` isn't in a git tree or `git` is absent — the *common, expected* path for non-repo trees. This is the Zig analogue of the Go original's `(nil, nil)`. Hard errors (subprocess crash, OOM) return an `error`. An empty repo (init, no commits) yields a non-null cache with empty file metadata so tracked/ignored still answer.

2. **Arena-owned memory.** Each `Cache` owns a `std.heap.ArenaAllocator`; every string and hashmap entry lives in it, and `cache.deinit()` frees the whole arena and destroys the `*Cache`. Raw git stdout is allocated with the caller's `gpa` and freed after parsing, so only the kept strings (duped into the arena) persist for the cache's lifetime. Caches stored in a `Pool` are owned by the pool — callers must not deinit them.

3. **Dual-root path resolution for the macOS symlink case.** git canonicalizes `/tmp/...` to `/private/tmp/...`, but a caller's walk often emits the symlinked form. `Cache` stores both `repo_root` (git's canonical view) and `repo_root_alt` (the as-supplied absolute root, when it differs). `toRel` tries both prefixes — an alloc-free comparison — rather than paying a realpath stat per file. Keys throughout are repo-relative forward-slash paths (the form `ls-files` emits).

### 0.16 std notes (things that moved)

- Subprocess: `std.process.run(gpa, io, .{ .argv, .cwd })` needs an `io`; we build one with `std.Io.Threaded.init(gpa, .{})` and `threaded.io()`.
- Sync: `std.Io.RwLock` (use the `*Uncancelable` lock variants); `std.Thread.Mutex`/`RwLock` are gone.
- Allocator: `std.heap.DebugAllocator` (was `GeneralPurposeAllocator`).
- Filesystem/stdout moved under `std.Io` (`Io.Dir`, `Io.File`); tests use `std.testing.io` / `std.testing.tmpDir`.

## Non-goals

- Windows path handling (POSIX only — the Go original's `filepath.ToSlash` accommodation is dropped).
- `context.Context`-style cancellation (git subprocesses are short-lived).
