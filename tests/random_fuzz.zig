//! Randomized differential fuzzer over a recursive pattern grammar.
//!
//! Generates valid patterns (literals, classes, `.`, groups, alternations,
//! greedy/lazy quantifiers, anchors) and random inputs, then asserts the same
//! engine self-consistency invariants as differential_fuzz.zig. This reaches
//! the backtracking and one-pass paths (lazy quantifiers, captures) that the
//! component fuzzer does not. Seeds are fixed, so any failure is reproducible
//! from the printed pattern/input.

const std = @import("std");
const Regex = @import("regex").Regex;

const alphabet = "abc123 \n.";

const Gen = struct {
    r: std.Random,
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn emit(self: *Gen, s: []const u8) void {
        for (s) |ch| {
            if (self.len >= self.buf.len) return;
            self.buf[self.len] = ch;
            self.len += 1;
        }
    }

    fn emitByte(self: *Gen, b: u8) void {
        if (self.len >= self.buf.len) return;
        self.buf[self.len] = b;
        self.len += 1;
    }

    fn literal(self: *Gen) void {
        const lits = "abc123";
        self.emitByte(lits[self.r.intRangeLessThan(usize, 0, lits.len)]);
    }

    fn klass(self: *Gen) void {
        const choices = [_][]const u8{ "\\w", "\\d", "\\s", "[a-c]", "[^a-c]", "[abc]", "\\W", "." };
        self.emit(choices[self.r.intRangeLessThan(usize, 0, choices.len)]);
    }

    fn quant(self: *Gen) void {
        switch (self.r.intRangeLessThan(u8, 0, 7)) {
            0 => {}, // none
            1 => self.emitByte('*'),
            2 => self.emitByte('+'),
            3 => self.emitByte('?'),
            4 => self.emit("{2}"),
            5 => self.emit("{1,3}"),
            else => self.emit("{0,2}"),
        }
        // Occasionally make it lazy.
        if (self.len > 0 and self.r.intRangeLessThan(u8, 0, 4) == 0) {
            const last = self.buf[self.len - 1];
            if (last == '*' or last == '+' or last == '?' or last == '}') self.emitByte('?');
        }
    }

    fn atom(self: *Gen, depth: u8) void {
        switch (self.r.intRangeLessThan(u8, 0, 10)) {
            0, 1, 2, 3 => self.literal(),
            4, 5, 6 => self.klass(),
            7, 8 => {
                if (depth == 0) {
                    self.literal();
                } else {
                    self.emitByte('(');
                    if (self.r.boolean()) self.emit("?:");
                    self.concat(depth - 1);
                    self.emitByte(')');
                }
            },
            else => self.literal(),
        }
        self.quant();
    }

    fn concat(self: *Gen, depth: u8) void {
        const n = self.r.intRangeAtMost(u8, 1, 3);
        var alts = self.r.intRangeAtMost(u8, 0, 2);
        var branch: u8 = 0;
        while (true) : (branch += 1) {
            var i: u8 = 0;
            while (i < n) : (i += 1) self.atom(depth);
            if (alts == 0) break;
            self.emitByte('|');
            alts -= 1;
        }
    }

    fn pattern(self: *Gen) []const u8 {
        self.len = 0;
        if (self.r.boolean()) self.emitByte('^');
        self.concat(2);
        if (self.r.boolean()) self.emitByte('$');
        return self.buf[0..self.len];
    }
};

fn randomInput(r: std.Random, buf: []u8) []const u8 {
    const n = r.intRangeAtMost(usize, 0, buf.len);
    for (0..n) |i| buf[i] = alphabet[r.intRangeLessThan(usize, 0, alphabet.len)];
    return buf[0..n];
}

fn checkConsistency(pattern: []const u8, input: []const u8, multiline: bool) !void {
    const allocator = std.testing.allocator;
    var re = Regex.compileWithFlags(allocator, pattern, .{ .multiline = multiline }) catch return;
    defer re.deinit();

    const n = re.count(input) catch return;
    const matches = re.findAll(allocator, input) catch return;
    defer {
        for (matches) |*m| {
            var mm = m;
            mm.deinit(allocator);
        }
        allocator.free(matches);
    }
    const is = re.isMatch(input) catch return;
    var first = re.find(input) catch return;
    defer if (first) |*f| f.deinit(allocator);

    if (n != matches.len or is != (first != null) or is != (matches.len > 0)) {
        std.debug.print(
            "INCONSISTENT pattern=\"{s}\" ml={} input=\"{s}\": count={d} findAll={d} isMatch={} find={}\n",
            .{ pattern, multiline, input, n, matches.len, is, first != null },
        );
        return error.Inconsistent;
    }
    if (first) |f| {
        if (matches.len > 0) {
            try std.testing.expectEqual(f.start, matches[0].start);
            try std.testing.expectEqual(f.end, matches[0].end);
        }
    }
    var prev_end: usize = 0;
    for (matches, 0..) |m, idx| {
        try std.testing.expect(m.start <= m.end and m.end <= input.len);
        try std.testing.expectEqualStrings(input[m.start..m.end], m.slice);
        if (idx > 0) try std.testing.expect(m.start >= prev_end);
        prev_end = m.end;
    }
}

test "random fuzz: grammar patterns vs engine invariants" {
    var gen = Gen{ .r = undefined };
    var input_buf: [40]u8 = undefined;

    // Several seeds for breadth; all fixed so failures reproduce.
    const seeds = [_]u64{ 0x1, 0xC0FFEE, 0xDEADBEEF, 0x5EED, 0xABCDEF };
    for (seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        gen.r = prng.random();
        var iter: usize = 0;
        while (iter < 1500) : (iter += 1) {
            const pat = gen.pattern();
            const input = randomInput(gen.r, &input_buf);
            const ml = gen.r.boolean();
            checkConsistency(pat, input, ml) catch |err| {
                std.debug.print("  (seed=0x{x} iter={d})\n", .{ seed, iter });
                return err;
            };
        }
    }
}
