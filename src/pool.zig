//! Pool caches one `Cache` per canonical repository root, refreshed when
//! HEAD changes. Safe for concurrent use.
//!
//! Designed to live for a long-running process (server, watcher, language
//! tooling) so many metadata queries against the same repo share one
//! `gitmeta.New` pass. HEAD invalidation runs on every `get` — one
//! `git rev-parse HEAD` per call (~3-5 ms) — so a `git commit` or
//! `git checkout` between calls is picked up without operator action.

const std = @import("std");
const gitmeta = @import("gitmeta.zig");
const Cache = gitmeta.Cache;
const Error = gitmeta.Error;
const Allocator = std.mem.Allocator;

/// Pool owns every `Cache` it builds and the canonical-root keys (duped
/// into `gpa`). Build with `init`, release everything with `deinit`.
/// Hold it by stable pointer (the embedded `Io` instance is referenced
/// by address).
pub const Pool = struct {
    gpa: Allocator,
    /// Backs the subprocess + lock I/O. Owned by the Pool.
    threaded: std.Io.Threaded,
    lock: std.Io.RwLock = .init,
    /// Keyed by canonical repo root (gpa-owned). Values are gpa-owned
    /// `*Cache`. A cache's `headSHA()` is the staleness token, so no
    /// separate sha copy is stored.
    entries: std.StringHashMapUnmanaged(*Cache) = .empty,

    /// Returns an empty Pool. Caches are built lazily on first `get`.
    pub fn init(gpa: Allocator) Pool {
        return .{ .gpa = gpa, .threaded = std.Io.Threaded.init(gpa, .{}) };
    }

    /// Frees every cached `Cache` and key, then the entry map and I/O.
    pub fn deinit(self: *Pool) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.*.deinit();
        }
        self.entries.deinit(self.gpa);
        self.threaded.deinit();
        self.* = undefined;
    }

    /// Returns a `Cache` for the git tree containing `root`. On a hit
    /// with matching HEAD the cached pointer is returned unchanged;
    /// otherwise (no entry, or HEAD moved) the cache is rebuilt via
    /// `gitmeta.New` and stored. Returns `null` for a non-git tree —
    /// same silent-skip contract as `New`.
    ///
    /// Cost on a hit: one `git rev-parse HEAD`. Cost on a miss: a full
    /// `New` pass, paid only after process start or a commit/checkout.
    pub fn get(self: *Pool, root: []const u8) Error!?*Cache {
        const io = self.threaded.io();

        // Resolve the canonical root up front — the same key `New` would
        // settle on — so /tmp/foo and /private/tmp/foo reach one entry.
        const canonical = (try gitmeta.revParseToplevel(self.gpa, io, root)) orelse return null;
        var canonical_to_free: ?[]u8 = canonical;
        defer if (canonical_to_free) |c| self.gpa.free(c);

        // Hit fast path: existing entry + HEAD-sha match → return it.
        self.lock.lockSharedUncancelable(io);
        const existing = self.entries.get(canonical);
        self.lock.unlockShared(io);
        if (existing) |cache| {
            if (try gitmeta.revParseHead(self.gpa, io, canonical)) |head| {
                defer self.gpa.free(head);
                if (std.mem.eql(u8, head, cache.headSHA())) return cache;
            }
            // HEAD moved or rev-parse failed → fall through to rebuild.
        }

        // Miss path: build fresh. Pass the ORIGINAL root (not canonical)
        // so the Cache's alt-root fallback picks up a symlinked path.
        const fresh = (try gitmeta.New(self.gpa, root)) orelse return null;
        errdefer fresh.deinit();

        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        // Re-check under the write lock: a racing builder may have stored
        // an entry since our read-lock peek. Without this the loser of
        // the race would leak its fresh build (the Go original relied on
        // GC here).
        const gop = try self.entries.getOrPut(self.gpa, canonical);
        if (gop.found_existing) {
            const current = gop.value_ptr.*;
            if (std.mem.eql(u8, current.headSHA(), fresh.headSHA())) {
                fresh.deinit(); // equivalent cache already stored
                return current;
            }
            // Stale entry → swap in the fresh cache, retire the old one.
            // The map keeps its existing key; our canonical copy is freed
            // by the defer above.
            current.deinit();
            gop.value_ptr.* = fresh;
            return fresh;
        }
        // New key: the map now references our canonical buffer, so hand
        // off ownership and stop the defer from freeing it.
        gop.key_ptr.* = canonical;
        gop.value_ptr.* = fresh;
        canonical_to_free = null;
        return fresh;
    }

    /// `get`-and-discard: pre-build the cache for `root` so the first
    /// real query doesn't pay the `New` cost. Same non-git-tree contract
    /// as `get`.
    pub fn warm(self: *Pool, root: []const u8) Error!void {
        _ = try self.get(root);
    }

    /// Number of cached entries. Exposed for tests and diagnostics.
    pub fn len(self: *Pool) usize {
        const io = self.threaded.io();
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.entries.count();
    }
};
