//! `zg` — a minimal ripgrep-style grep built on zig-regex, used to reproduce
//! the issue #10 benchmark (multi-file corpus and single large file) head to
//! head against `rg`.
//!
//! Usage: zg [-c] [-i] [-m] <pattern> <path...>
//!   -c  count matching lines per file (like `rg -c`)
//!   -i  case-insensitive
//!   -m  multiline (^/$ match line boundaries) — default for line grep anyway
//!
//! Directory traversal and matching share one per-CPU worker pool: the work
//! queue holds tagged items (a directory to expand or a file to search), so the
//! walk runs in parallel and overlaps matching, like ripgrep's parallel walker.
//! Dotfiles/dotdirs (`.git`, …) and binary files (NUL in the first 8 KiB) are
//! skipped.
const std = @import("std");
const Io = std.Io;
const regex = @import("regex");
const Regex = regex.Regex;

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
            std.Thread.yield() catch std.atomic.spinLoopHint();
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
        // Reused read buffer for small files (avoids per-file mmap/munmap).
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        while (self.queue.pop()) |item| {
            if (item.is_dir) self.expandDir(item.path) else self.matchFile(&m, &buf, item.path) catch {};
            self.queue.complete();
        }
    }

    fn expandDir(self: *Worker, path: []const u8) void {
        var dir = Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.name.len > 0 and entry.name[0] == '.') continue; // skip hidden
            const child = std.fs.path.join(self.allocator, &.{ path, entry.name }) catch continue;
            switch (entry.kind) {
                .directory => self.queue.push(child, true),
                .file => self.queue.push(child, false),
                else => {},
            }
        }
    }

    // Files at/below this size are read into the reused buffer; larger files are
    // memory-mapped (mmap setup amortizes over a big sequential scan).
    const MMAP_THRESHOLD = 256 * 1024;

    fn matchFile(self: *Worker, m: *Regex.Matcher, buf: *std.ArrayList(u8), path: []const u8) !void {
        var file = Io.Dir.cwd().openFile(self.io, path, .{ .allow_directory = false }) catch return;
        defer file.close(self.io);
        const st = file.stat(self.io) catch return;
        const size: usize = @intCast(st.size);
        if (size == 0) return;

        var mapped: ?MappedFile = null;
        defer if (mapped) |mm| {
            if (mm.len != 0) std.posix.munmap(mm);
        };
        const data: []const u8 = if (size > MMAP_THRESHOLD) blk: {
            const mm = std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0) catch return;
            std.posix.madvise(mm.ptr, mm.len, std.posix.MADV.SEQUENTIAL) catch {};
            mapped = mm;
            break :blk mm;
        } else blk: {
            buf.clearRetainingCapacity();
            buf.ensureTotalCapacity(self.allocator, size) catch return;
            buf.items.len = size;
            const n = file.readPositionalAll(self.io, buf.items[0..size], 0) catch return;
            break :blk buf.items[0..n];
        };
        if (data.len == 0) return;
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
    const cpu = std.Thread.getCpuCount() catch 1;
    const pool = @max(@min(cpu, 16), 1);
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
