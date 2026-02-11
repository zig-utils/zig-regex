const std = @import("std");
const Io = std.Io;
const regex = @import("regex");

const usage_text =
    \\Usage: regex [options] <pattern> [input]
    \\
    \\A fast regex matching tool built with Zig.
    \\
    \\Arguments:
    \\  <pattern>    Regular expression pattern
    \\  [input]      Input text (reads from stdin if omitted)
    \\
    \\Options:
    \\  -g           Find all matches (global)
    \\  -i           Case-insensitive matching
    \\  -m           Multiline mode (^ and $ match line boundaries)
    \\  -r <repl>    Replace matches with <repl> ($0 = full match, $1-$9 = captures)
    \\  -v           Print version
    \\  -h           Print this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var case_insensitive = false;
    var multiline = false;
    var global = false;
    var replacement: ?[]const u8 = null;
    var pattern_str: ?[]const u8 = null;
    var input_str: ?[]const u8 = null;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_w.interface;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
                try stdout.print("regex {d}.{d}.{d}\n", .{ regex.version.major, regex.version.minor, regex.version.patch });
                try stdout.flush();
                return;
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                try stdout.writeAll(usage_text);
                try stdout.flush();
                return;
            } else if (std.mem.eql(u8, arg, "-i")) {
                case_insensitive = true;
            } else if (std.mem.eql(u8, arg, "-m")) {
                multiline = true;
            } else if (std.mem.eql(u8, arg, "-g")) {
                global = true;
            } else if (std.mem.eql(u8, arg, "-r")) {
                i += 1;
                if (i >= args.len) {
                    try stderr.writeAll("error: -r requires a replacement string\n");
                    try stderr.flush();
                    std.process.exit(1);
                }
                replacement = args[i];
            } else {
                try stderr.print("error: unknown option: {s}\n", .{arg});
                try stderr.flush();
                std.process.exit(1);
            }
        } else if (pattern_str == null) {
            pattern_str = arg;
        } else if (input_str == null) {
            input_str = arg;
        }
    }

    const pattern = pattern_str orelse {
        try stdout.writeAll(usage_text);
        try stdout.flush();
        return;
    };

    // Read input from stdin if not provided as argument
    var stdin_alloc: ?[]u8 = null;
    defer if (stdin_alloc) |buf| allocator.free(buf);

    const input: []const u8 = if (input_str) |s| s else blk: {
        var stdin_read_buf: [4096]u8 = undefined;
        var reader = Io.File.stdin().reader(io, &stdin_read_buf);
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = try reader.interface.readSliceShort(&chunk);
            if (n == 0) break;
            try result.appendSlice(allocator, chunk[0..n]);
        }
        stdin_alloc = try result.toOwnedSlice(allocator);
        break :blk stdin_alloc.?;
    };

    var re = regex.Regex.compileWithFlags(allocator, pattern, .{
        .case_insensitive = case_insensitive,
        .multiline = multiline,
    }) catch |err| {
        try stderr.print("error: invalid pattern: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    defer re.deinit();

    if (replacement) |repl| {
        const result = if (global)
            re.replaceAll(allocator, input, repl) catch |err| {
                try stderr.print("error: replace failed: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            }
        else
            re.replace(allocator, input, repl) catch |err| {
                try stderr.print("error: replace failed: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            };
        defer allocator.free(result);
        try stdout.writeAll(result);
        try stdout.writeAll("\n");
        try stdout.flush();
    } else if (global) {
        const matches = re.findAll(allocator, input) catch |err| {
            try stderr.print("error: match failed: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
        defer {
            for (matches) |*m| {
                var mut_m = m;
                mut_m.deinit(allocator);
            }
            allocator.free(matches);
        }
        if (matches.len == 0) std.process.exit(1);
        for (matches) |match| {
            try stdout.writeAll(match.slice);
            try stdout.writeAll("\n");
        }
        try stdout.flush();
    } else {
        if (re.find(input) catch |err| {
            try stderr.print("error: match failed: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        }) |match| {
            var mut_match = match;
            defer mut_match.deinit(allocator);
            try stdout.writeAll(match.slice);
            try stdout.writeAll("\n");
            try stdout.flush();
        } else {
            std.process.exit(1);
        }
    }
}
