//! `zg` — a minimal ripgrep-style grep built on zig-regex, used to reproduce
//! the issue #10 benchmark (multi-file corpus and single large file) head to
//! head against `rg`.
//!
//! Usage: zg [-c] [-i] [-m] <pattern> <path...>
//!   -c  count matching lines per file (like `rg -c`)
//!   -i  case-insensitive
//!   -m  multiline (^/$ match line boundaries) — default for line grep anyway
//!
//! Walks directories recursively (skipping dotfiles/dotdirs like `.git`, and
//! binary files containing NUL), then matches files in parallel across CPUs.
const std = @import("std");
const Io = std.Io;
const regex = @import("regex");
const Regex = regex.Regex;

const Options = struct {
    count_only: bool = false,
    case_insensitive: bool = false,
    multiline: bool = false,
};

const FileList = std.ArrayList([]const u8);

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

const Worker = struct {
    re: *const Regex,
    opts: Options,
    files: []const []const u8,
    next_index: *std.atomic.Value(usize),
    out: std.ArrayList(u8),
    total_count: usize = 0,
    allocator: std.mem.Allocator,
    io: Io,
    show_path: bool,

    fn run(self: *Worker) void {
        while (true) {
            const idx = self.next_index.fetchAdd(1, .monotonic);
            if (idx >= self.files.len) break;
            self.processFile(self.files[idx]) catch {};
        }
    }

    fn processFile(self: *Worker, path: []const u8) !void {
        const data = mapFile(self.io, path) catch return;
        defer unmapFile(data);
        if (data.len == 0) return;
        // Binary detection: NUL in the first 8 KiB (matches ripgrep's heuristic
        // closely enough for the benchmark corpus).
        const probe = data[0..@min(data.len, 8 * 1024)];
        if (std.mem.indexOfScalar(u8, probe, 0) != null) return;

        if (self.opts.count_only) {
            const n = try self.re.countMatchingLines(data);
            if (n > 0) {
                self.total_count += n;
                try self.out.print(self.allocator, "{s}:{d}\n", .{ path, n });
            }
            return;
        }

        // Drive the engine's whole-buffer matching-line scan (shares the literal
        // and required-literal prefilters with the count path), emitting each
        // matching line directly into the per-thread output buffer.
        var sink = LineSink{
            .out = &self.out,
            .allocator = self.allocator,
            .data = data,
            .path = path,
            .show_path = self.show_path,
        };
        try self.re.forMatchingLines(data, &sink, LineSink.emit);
        self.total_count += sink.count;
    }
};

const MappedFile = []align(std.heap.page_size_min) const u8;

fn mapFile(io: Io, path: []const u8) !MappedFile {
    var file = try Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    const st = try file.stat(io);
    const size: usize = @intCast(st.size);
    if (size == 0) return &[_]u8{};
    const mem = try std.posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    std.posix.madvise(mem.ptr, mem.len, std.posix.MADV.SEQUENTIAL) catch {};
    return mem;
}

fn unmapFile(data: MappedFile) void {
    if (data.len == 0) return;
    std.posix.munmap(data);
}

fn collectFiles(
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    files: *FileList,
    walked_dir: *bool,
) !void {
    // A single path that is a file: add directly.
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch {
        // Not a directory — assume a regular file.
        try files.append(allocator, try allocator.dupe(u8, root));
        return;
    };
    walked_dir.* = true;
    defer dir.close(io);

    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        // Skip hidden files/dirs (don't descend into them).
        if (entry.basename.len > 0 and entry.basename[0] == '.') continue;
        switch (entry.kind) {
            .directory => try walker.enter(io, entry),
            .file => {
                const joined = try std.fs.path.join(allocator, &.{ root, entry.path });
                try files.append(allocator, joined);
            },
            else => {},
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var opts = Options{};
    var pattern: ?[]const u8 = null;
    var paths: FileList = .empty;

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

    var re = try Regex.compileWithFlags(allocator, pat, .{
        .case_insensitive = opts.case_insensitive,
        .multiline = opts.multiline,
    });
    defer re.deinit();

    // Gather the full file list (single-threaded directory walk).
    var files: FileList = .empty;
    var walked_dir = false;
    for (paths.items) |p| try collectFiles(arena, io, p, &files, &walked_dir);
    // Match ripgrep: prefix `path:` only when more than one file is searched or
    // a directory was traversed; a single explicit file prints bare lines.
    const show_path = walked_dir or files.items.len > 1;

    // Process files in parallel across CPUs.
    const cpu = std.Thread.getCpuCount() catch 1;
    const nthreads = @min(@max(cpu, 1), 16);
    var next_index = std.atomic.Value(usize).init(0);

    const workers = try arena.alloc(Worker, nthreads);
    for (workers) |*w| w.* = .{
        .re = &re,
        .opts = opts,
        .files = files.items,
        .next_index = &next_index,
        .out = .empty,
        .allocator = allocator,
        .io = io,
        .show_path = show_path,
    };

    var threads = try arena.alloc(?std.Thread, nthreads);
    for (workers, 0..) |*w, t| threads[t] = std.Thread.spawn(.{}, Worker.run, .{w}) catch blk: {
        w.run();
        break :blk null;
    };
    for (threads) |maybe_t| if (maybe_t) |th| th.join();

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
