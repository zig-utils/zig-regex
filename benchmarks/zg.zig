//! `zg` — a minimal ripgrep-style grep built on zig-regex, used to reproduce
//! the issue #10 benchmark (multi-file corpus and single large file) head to
//! head against `rg`.
//!
//! Usage: zg [-c] [-i] [-m] <pattern> <path...>
//!   -c  count matching lines per file (like `rg -c`)
//!   -i  case-insensitive
//!   -m  multiline (^/$ match line boundaries) — default for line grep anyway
//!   env ZG_THREADS=N  pin the worker count (like ripgrep's `-j`)
//!
//! The walk is ripgrep-shaped: a pool of workers pulls *directories* off a shared
//! queue; each worker reads its directory's entries in batches, matches the
//! contained files inline (opened `openat`-relative to the dir, read with raw
//! `std.posix` to skip the threaded-`Io` per-call bookkeeping), and pushes only
//! subdirectories back on the queue. So the queue lock is touched ~once per
//! directory rather than once per file, and the steady state allocates nothing
//! per file. Each worker reuses one `Regex.Matcher` (its lazy DFA built once).
//! The pool defaults to the performance-core count (see `defaultWorkerCount`).
//! Dotfiles/dotdirs (`.git`, …) and binary files (NUL in the first 1 KiB) are
//! skipped.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const regex = @import("regex");
const Regex = regex.Regex;

/// Number of *performance* CPUs the OS exposes, or null if it doesn't.
/// On heterogeneous-core machines (Apple Silicon's P+E cores) an I/O-bound
/// parallel walk peaks around the performance-core count — the slower efficiency
/// cores become the critical path and add queue contention past that point, so
/// using every logical core is actually slower than using the fast ones. On a
/// homogeneous machine `hw.perflevel0.logicalcpu` equals the total, so this is a
/// no-op there.
fn performanceCoreCount() ?usize {
    if (builtin.os.tag != .macos) return null;
    var n: c_int = 0;
    var len: usize = @sizeOf(c_int);
    if (std.c.sysctlbyname("hw.perflevel0.logicalcpu", &n, &len, null, 0) != 0) return null;
    if (n <= 0) return null;
    return @intCast(n);
}

/// Default worker count for a directory walk: the performance cores when the OS
/// distinguishes them, else all logical cores, capped to a sane maximum.
fn defaultWorkerCount() usize {
    const logical = std.Thread.getCpuCount() catch 1;
    const cores = performanceCoreCount() orelse logical;
    return @max(@min(cores, 16), 1);
}

const Options = struct {
    count_only: bool = false,
    case_insensitive: bool = false,
    multiline: bool = false,
};

const Item = struct { path: []const u8, is_dir: bool };

/// A small spinlock — Zig 0.16's blocking Mutex/Condition live on the Io async
/// model, which doesn't compose with raw `std.Thread`, so a tiny atomic lock is
/// the simplest portable primitive here. Critical sections are O(1).
const SpinLock = struct {
    state: std.atomic.Value(u32) = .init(0),
    fn lock(self: *SpinLock) void {
        while (self.state.swap(1, .acquire) != 0) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

/// MPMC queue of work items with a pending counter for distributed termination:
/// `pending` tracks items enqueued but not yet fully processed (expanding a
/// directory enqueues its children *before* that directory is marked complete),
/// so when it reaches zero no further work can appear and the queue closes.
const WorkQueue = struct {
    lock: SpinLock = .{},
    items: std.ArrayList(Item) = .empty,
    head: usize = 0,
    pending: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    allocator: std.mem.Allocator,

    fn push(self: *WorkQueue, path: []const u8, is_dir: bool) void {
        _ = self.pending.fetchAdd(1, .monotonic);
        self.lock.lock();
        self.items.append(self.allocator, .{ .path = path, .is_dir = is_dir }) catch {};
        self.lock.unlock();
    }

    fn pop(self: *WorkQueue) ?Item {
        // Idle backoff: spin on the CPU (no syscall) for a while before yielding,
        // so workers that briefly out-run the producer don't storm `sched_yield`.
        // With directory-granular work items the queue rarely empties mid-walk, so
        // this path is hot only at the very start and the very end of a run.
        var spins: u32 = 0;
        while (true) {
            self.lock.lock();
            if (self.head < self.items.items.len) {
                const it = self.items.items[self.head];
                self.head += 1;
                self.lock.unlock();
                return it;
            }
            self.lock.unlock();
            if (self.done.load(.acquire)) return null;
            spins +%= 1;
            if (spins & 63 == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
    }

    /// Mark one popped item finished; closes the queue when the last one drains.
    fn complete(self: *WorkQueue) void {
        if (self.pending.fetchSub(1, .acq_rel) == 1) self.done.store(true, .release);
    }
};

const LineSink = struct {
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    data: []const u8,
    path: []const u8,
    show_path: bool,
    count: usize = 0,

    fn emit(self: *LineSink, ls: usize, le: usize) anyerror!void {
        self.count += 1;
        const line = self.data[ls..le];
        const extra = (if (self.show_path) self.path.len + 1 else 0) + line.len + 1;
        try self.out.ensureUnusedCapacity(self.allocator, extra);
        if (self.show_path) {
            self.out.appendSliceAssumeCapacity(self.path);
            self.out.appendAssumeCapacity(':');
        }
        self.out.appendSliceAssumeCapacity(line);
        self.out.appendAssumeCapacity('\n');
    }
};

const MappedFile = []align(std.heap.page_size_min) const u8;

const Worker = struct {
    re: *const Regex,
    opts: Options,
    queue: *WorkQueue,
    out: std.ArrayList(u8),
    total_count: usize = 0,
    allocator: std.mem.Allocator,
    io: Io,
    show_path: bool,

    fn run(self: *Worker) void {
        // One Matcher per worker: its lazy search DFA is built once and reused
        // across every file this worker handles, instead of rebuilt per file.
        var m = self.re.matcher();
        defer m.deinit();
        // Reused buffers, one set per worker: `buf` holds a small file's bytes,
        // `pathbuf` builds the `dir/name` display path. Neither is freed between
        // files, so the steady-state walk allocates nothing per file.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var pathbuf: std.ArrayList(u8) = .empty;
        defer pathbuf.deinit(self.allocator);
        while (self.queue.pop()) |item| {
            if (item.is_dir)
                self.processDir(&m, &buf, &pathbuf, item.path)
            else
                self.matchSeedFile(&m, &buf, item.path) catch {};
            self.queue.complete();
        }
    }

    /// Expand one directory: each contained file is opened (via `openat` relative
    /// to this dir's handle) and matched *inline on this thread* — only
    /// subdirectories go back on the shared queue. This is ripgrep's parallel
    /// walker shape: parallelism granularity is the directory, so the queue (and
    /// its lock) is touched ~once per directory instead of once per file, and the
    /// thousands of per-file path joins / queue ops disappear.
    // Directory iteration buffers. `Io.Dir.Iterator` reads one entry per `Io`
    // vtable call (22k dispatches + cancellation bookkeeping over the whole
    // tree) through a 2 KiB dirent buffer. The lower-level `Reader` instead
    // returns a whole batch of entries per call out of a larger buffer, so the
    // per-entry dispatch and most `getdirentries` syscalls disappear.
    const DIR_BUF = 32 * 1024;
    const DIR_ENTRIES = 256;

    fn processDir(self: *Worker, m: *Regex.Matcher, buf: *std.ArrayList(u8), pathbuf: *std.ArrayList(u8), dir_path: []const u8) void {
        defer self.allocator.free(dir_path);
        var dir = Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var dirbuf: [DIR_BUF]u8 align(@alignOf(usize)) = undefined;
        var entries: [DIR_ENTRIES]Io.Dir.Entry = undefined;
        var reader = Io.Dir.Reader.init(dir, &dirbuf);
        while (true) {
            const n = reader.read(self.io, &entries) catch break;
            // Every `Entry.name` in this batch references `dirbuf` and stays valid
            // until the next `read`, so the whole batch is processed here first.
            for (entries[0..n]) |entry| {
                if (entry.name.len > 0 and entry.name[0] == '.') continue; // skip hidden
                switch (entry.kind) {
                    // Only subdirectories are queued; their paths must outlive
                    // this frame, so they are heap-allocated (≈one per directory,
                    // freed when that directory is later expanded).
                    .directory => {
                        const child = std.fs.path.join(self.allocator, &.{ dir_path, entry.name }) catch continue;
                        self.queue.push(child, true);
                    },
                    .file => self.matchFileAt(m, buf, pathbuf, dir, dir_path, entry.name) catch {},
                    else => {},
                }
            }
            if (n == 0 or reader.state == .finished) break;
        }
    }

    // Files at/below this size are read into the reused buffer; larger files are
    // memory-mapped (mmap setup amortizes over a big sequential scan).
    const MMAP_THRESHOLD = 256 * 1024;

    /// Read a file's bytes into `buf` (small files) or an mmap (large files).
    /// Returns the data slice, or null on any I/O error. Uses raw `std.posix`
    /// syscalls rather than the `Io` interface: the threaded `Io` wraps every
    /// read/open in iovec marshalling + per-call cancellation bookkeeping +
    /// vtable dispatch, which over a 20k-file walk is pure overhead on the hot
    /// path. A single `read` covers a small file in one syscall — a short read
    /// from a regular file is EOF, so there is no second "confirm EOF" read.
    fn readFileData(self: *Worker, fd: std.posix.fd_t, buf: *std.ArrayList(u8), mapped: *?MappedFile) !?[]const u8 {
        buf.clearRetainingCapacity();
        buf.ensureTotalCapacity(self.allocator, MMAP_THRESHOLD) catch return null;
        buf.items.len = MMAP_THRESHOLD;
        const first = std.posix.read(fd, buf.items[0..MMAP_THRESHOLD]) catch return null;
        if (first < MMAP_THRESHOLD) return buf.items[0..first];
        // Buffer filled — the file may be larger, so fall back to a stat-sized
        // mmap (amortized over the big sequential scan). This `fstat` runs only
        // for the rare file at/over the threshold, not on the small-file hot path.
        var st: std.c.Stat = undefined;
        if (std.c.fstat(fd, &st) != 0) return null;
        const size: usize = @intCast(st.size);
        if (size <= MMAP_THRESHOLD) return buf.items[0..first];
        const mm = std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return null;
        std.posix.madvise(mm.ptr, mm.len, std.posix.MADV.SEQUENTIAL) catch {};
        mapped.* = mm;
        return mm;
    }

    const O_RDONLY: std.posix.O = .{ .ACCMODE = .RDONLY };

    /// Match a single file discovered during the walk. Opened with `openat`
    /// relative to its parent dir's fd, so the kernel resolves only the leaf name
    /// rather than re-walking the whole path from the cwd on every one of the
    /// ~20k files.
    fn matchFileAt(self: *Worker, m: *Regex.Matcher, buf: *std.ArrayList(u8), pathbuf: *std.ArrayList(u8), dir: Io.Dir, dir_path: []const u8, name: []const u8) !void {
        const fd = std.posix.openat(dir.handle, name, O_RDONLY, 0) catch return;
        defer _ = std.c.close(fd);
        var mapped: ?MappedFile = null;
        defer if (mapped) |mm| {
            if (mm.len != 0) std.posix.munmap(mm);
        };
        const data = (try self.readFileData(fd, buf, &mapped)) orelse return;
        if (data.len == 0) return;
        const path = if (self.show_path) try buildPath(pathbuf, self.allocator, dir_path, name) else name;
        try self.matchData(m, data, path);
    }

    /// Match an explicit file argument (e.g. the single-large-file benchmark),
    /// opened from the cwd by its given path.
    fn matchSeedFile(self: *Worker, m: *Regex.Matcher, buf: *std.ArrayList(u8), path: []const u8) !void {
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, O_RDONLY, 0) catch return;
        defer _ = std.c.close(fd);
        var mapped: ?MappedFile = null;
        defer if (mapped) |mm| {
            if (mm.len != 0) std.posix.munmap(mm);
        };
        const data = (try self.readFileData(fd, buf, &mapped)) orelse return;
        if (data.len == 0) return;
        try self.matchData(m, data, path);
    }

    /// Build `dir_path/name` into the reused per-worker path buffer.
    fn buildPath(pathbuf: *std.ArrayList(u8), allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) ![]const u8 {
        pathbuf.clearRetainingCapacity();
        try pathbuf.ensureUnusedCapacity(allocator, dir_path.len + 1 + name.len);
        pathbuf.appendSliceAssumeCapacity(dir_path);
        pathbuf.appendAssumeCapacity('/');
        pathbuf.appendSliceAssumeCapacity(name);
        return pathbuf.items;
    }

    /// Binary-skip + run the matcher over one file's bytes. Shared by the walked
    /// and the explicit-file paths.
    fn matchData(self: *Worker, m: *Regex.Matcher, data: []const u8, path: []const u8) !void {
        // Binary detection: NUL in the first 1 KiB (binaries carry NUL in their
        // header; a small window avoids re-scanning most of every small text
        // file, which is then scanned again by the matcher).
        const probe = data[0..@min(data.len, 1024)];
        if (std.mem.indexOfScalar(u8, probe, 0) != null) return;

        if (self.opts.count_only) {
            const n = try m.countMatchingLines(data);
            if (n > 0) {
                self.total_count += n;
                try self.out.print(self.allocator, "{s}:{d}\n", .{ path, n });
            }
            return;
        }

        // The engine's whole-buffer matching-line scan shares the literal and
        // required-literal prefilters with the count path and emits each matching
        // line directly into the per-thread output buffer.
        var sink = LineSink{
            .out = &self.out,
            .allocator = self.allocator,
            .data = data,
            .path = path,
            .show_path = self.show_path,
        };
        try m.forMatchingLines(data, &sink, LineSink.emit);
        self.total_count += sink.count;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var opts = Options{};
    var pattern: ?[]const u8 = null;
    var paths: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len >= 2 and arg[0] == '-') {
            for (arg[1..]) |c| switch (c) {
                'c' => opts.count_only = true,
                'i' => opts.case_insensitive = true,
                'm' => opts.multiline = true,
                else => {},
            };
        } else if (pattern == null) {
            pattern = arg;
        } else {
            try paths.append(arena, arg);
        }
    }

    const pat = pattern orelse {
        var stderr_buf: [256]u8 = undefined;
        var stderr_w = Io.File.stderr().writer(io, &stderr_buf);
        try stderr_w.interface.writeAll("usage: zg [-c] [-i] [-m] <pattern> <path...>\n");
        try stderr_w.interface.flush();
        std.process.exit(2);
    };
    if (paths.items.len == 0) try paths.append(arena, ".");

    var re = try Regex.compileWithFlags(allocator, pat, .{
        .case_insensitive = opts.case_insensitive,
        .multiline = opts.multiline,
    });
    defer re.deinit();

    var queue = WorkQueue{ .allocator = allocator };

    // Seed the queue with the root paths (file vs directory decides the prefix).
    var any_dir = false;
    var file_seeds: usize = 0;
    for (paths.items) |p| {
        if (Io.Dir.cwd().openDir(io, p, .{ .iterate = true })) |d| {
            var dd = d;
            dd.close(io);
            queue.push(try allocator.dupe(u8, p), true);
            any_dir = true;
        } else |_| {
            queue.push(try allocator.dupe(u8, p), false);
            file_seeds += 1;
        }
    }
    // Match ripgrep: prefix `path:` only when more than one file is searched or
    // a directory was traversed; a single explicit file prints bare lines.
    const show_path = any_dir or paths.items.len > 1;

    // A directory seed can fan out to thousands of files, so use the whole pool;
    // but a fixed set of plain files needs at most one worker each — spawning the
    // full pool would leave idle workers spin-waiting and stealing CPU from the
    // few that have work (notably the single-large-file case).
    // `ZG_THREADS` pins the worker count (for benchmarking, like ripgrep's `-j`);
    // otherwise default to the performance cores (see `defaultWorkerCount`).
    const pool: usize = if (std.c.getenv("ZG_THREADS")) |s|
        @max(std.fmt.parseInt(usize, std.mem.span(s), 10) catch defaultWorkerCount(), 1)
    else
        defaultWorkerCount();
    const nthreads = if (any_dir) pool else @max(@min(pool, file_seeds), 1);

    const workers = try arena.alloc(Worker, nthreads);
    for (workers) |*w| w.* = .{
        .re = &re,
        .opts = opts,
        .queue = &queue,
        .out = .empty,
        .allocator = allocator,
        .io = io,
        .show_path = show_path,
    };

    if (nthreads == 1) {
        // Single worker (e.g. one file): run inline — no thread-spawn overhead,
        // which is a meaningful fraction of wall time for fast patterns.
        workers[0].run();
    } else {
        var threads = try arena.alloc(?std.Thread, nthreads);
        for (workers, 0..) |*w, t| threads[t] = std.Thread.spawn(.{}, Worker.run, .{w}) catch null;
        // Any worker that failed to spawn runs inline.
        for (workers, 0..) |*w, t| if (threads[t] == null) w.run();
        for (threads) |maybe_t| if (maybe_t) |th| th.join();
    }

    // Emit results.
    var stdout_buf: [256 * 1024]u8 = undefined;
    var stdout_w = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;
    var total: usize = 0;
    for (workers) |*w| {
        total += w.total_count;
        try stdout.writeAll(w.out.items);
    }
    try stdout.flush();
    if (total == 0) std.process.exit(1);
}
