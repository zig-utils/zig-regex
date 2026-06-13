//! One-pass capture matcher for "disjoint-boundary atom sequence" patterns.
//!
//! Many capture patterns are a concatenation of atoms — `(\w+)@(\w+)`,
//! `(\d+)-(\d+)`, `([a-z]+)([0-9]+)`, `(foo)(\d+)` — where each variable-length
//! atom's byte set is disjoint from whatever follows it. For those, greedy
//! left-to-right matching is provably correct (no backtracking is ever needed:
//! a `+`/`{m,n}` run stops exactly where the next atom must begin), and capture
//! group boundaries are just the positions between atoms.
//!
//! This engine matches such patterns deterministically with a single byte walk
//! per atom and no NFA thread simulation — fast capture extraction. It is built
//! only when the pattern provably fits the shape (see `build`); everything else
//! returns null and the caller uses the NFA. Output is a `vm.MatchResult`, so it
//! is a drop-in replacement for `vm.matchAt` on eligible patterns.
//!
//! Restrictions (any failure => null => NFA fallback):
//!   - Thompson-eligible only: no backreferences, lookaround.
//!   - No alternation, no anchors (^ $ \b), no case-insensitive.
//!   - Atoms are a single base (literal / char-class / `.`) with an optional
//!     greedy quantifier (`+`, `*`, `?`, `{m,n}`); `{0,0}` is rejected.
//!   - Quantifiers wrap only a base, never a group.
//!   - Every variable-length atom's byte set is disjoint from the next atom's —
//!     this is what makes greedy matching unambiguous even for nullable atoms.

const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");
const vm = @import("vm.zig");

const Segment = struct {
    table: [256]bool,
    min: usize,
    max: ?usize, // null = unbounded
    /// True when the atom can match a variable number of bytes (max != min).
    variable: bool,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    segs: []Segment,
    num_groups: usize,
    /// For group g (0-based): the segment index before which it starts, and the
    /// segment index after which it ends. Both always lie within the sequence,
    /// so a group always participates when the overall match succeeds.
    group_start_before: []usize,
    group_end_after: []usize,

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.segs);
        self.allocator.free(self.group_start_before);
        self.allocator.free(self.group_end_after);
        self.allocator.destroy(self);
    }

    /// Match anchored at `start`, returning the (longest, and only) match or null.
    /// Captures are allocated like `vm.matchAt` (caller frees `result.captures`).
    pub fn matchAt(self: *const Plan, allocator: std.mem.Allocator, input: []const u8, start: usize) !?vm.MatchResult {
        var caps = try allocator.alloc(vm.Capture, self.num_groups);
        errdefer allocator.free(caps);
        for (caps) |*c| c.* = .{ .start = 0, .end = 0, .text = "", .matched = false };

        var pos = start;
        for (self.segs, 0..) |seg, i| {
            // Group starts at this boundary.
            for (0..self.num_groups) |g| {
                if (self.group_start_before[g] == i) caps[g].start = pos;
            }
            // Greedy consume.
            const mx = seg.max orelse std.math.maxInt(usize);
            var cnt: usize = 0;
            while (pos < input.len and seg.table[input[pos]] and cnt < mx) : (pos += 1) cnt += 1;
            if (cnt < seg.min) {
                allocator.free(caps);
                return null;
            }
            // Group ends after this segment.
            for (0..self.num_groups) |g| {
                if (self.group_end_after[g] == i) {
                    caps[g].end = pos;
                    caps[g].text = input[caps[g].start..pos];
                    caps[g].matched = true;
                }
            }
        }
        return vm.MatchResult{ .start = start, .end = pos, .captures = caps };
    }

    /// Match end at `start` without building captures — for count/isMatch.
    pub fn matchEndAt(self: *const Plan, input: []const u8, start: usize) ?usize {
        var pos = start;
        for (self.segs) |seg| {
            const mx = seg.max orelse std.math.maxInt(usize);
            var cnt: usize = 0;
            while (pos < input.len and seg.table[input[pos]] and cnt < mx) : (pos += 1) cnt += 1;
            if (cnt < seg.min) return null;
        }
        return pos;
    }

    /// Next start position to try after a failed `matchAt(scan)`. When the first
    /// atom is unbounded (`+`/`*`), a failure means no start within its current
    /// run can match (every such start consumes the same run — by disjointness
    /// the next atom can't begin inside it — and hits the same later failure), so
    /// skip past the whole run. Otherwise advance by one. Always makes progress.
    pub fn nextScan(self: *const Plan, input: []const u8, scan: usize) usize {
        if (self.segs[0].max == null) {
            const t0 = &self.segs[0].table;
            var s = scan;
            while (s < input.len and t0[input[s]]) s += 1;
            if (s > scan) return s;
        }
        return scan + 1;
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    flags: common.CompileFlags,
    segs: std.ArrayList(Segment),
    starts: std.ArrayList(usize), // group_start_before, indexed by group-1
    ends: std.ArrayList(usize), // group_end_after, indexed by group-1
    num_groups: usize,

    /// Append the base table for a literal / char-class / any node, or return
    /// false if `node` isn't a base.
    fn baseTable(self: *Builder, node: *ast.Node, table: *[256]bool) bool {
        @memset(table, false);
        switch (node.node_type) {
            .literal => table[node.data.literal] = true,
            .char_class => {
                const cc = node.data.char_class;
                var b: usize = 0;
                while (b < 256) : (b += 1) {
                    if (cc.matches(@intCast(b))) table[b] = true;
                }
            },
            .any => {
                var b: usize = 0;
                while (b < 256) : (b += 1) table[b] = if (self.flags.dot_all) true else b != '\n';
            },
            else => return false,
        }
        return true;
    }

    fn pushSegment(self: *Builder, table: [256]bool, min: usize, max: ?usize) !void {
        try self.segs.append(self.allocator, .{
            .table = table,
            .min = min,
            .max = max,
            .variable = (max == null) or (max.? != min),
        });
    }

    /// Flatten `node` into segments + capture markers. Returns false if the node
    /// is not part of the supported shape.
    fn flatten(self: *Builder, node: *ast.Node) !bool {
        var table: [256]bool = undefined;
        switch (node.node_type) {
            .literal, .char_class, .any => {
                _ = self.baseTable(node, &table);
                try self.pushSegment(table, 1, 1);
                return true;
            },
            .plus => {
                if (!node.data.plus.greedy) return false;
                if (!self.baseTable(node.data.plus.child, &table)) return false;
                try self.pushSegment(table, 1, null);
                return true;
            },
            .star => {
                if (!node.data.star.greedy) return false;
                if (!self.baseTable(node.data.star.child, &table)) return false;
                try self.pushSegment(table, 0, null);
                return true;
            },
            .optional => {
                if (!node.data.optional.greedy) return false;
                if (!self.baseTable(node.data.optional.child, &table)) return false;
                try self.pushSegment(table, 0, 1);
                return true;
            },
            .repeat => {
                const r = node.data.repeat;
                if (!r.greedy) return false;
                if (r.bounds.max) |mx| {
                    if (mx == 0) return false; // {0,0} matches nothing useful
                }
                if (!self.baseTable(r.child, &table)) return false;
                try self.pushSegment(table, r.bounds.min, r.bounds.max);
                return true;
            },
            .concat => {
                if (!try self.flatten(node.data.concat.left)) return false;
                return try self.flatten(node.data.concat.right);
            },
            .group => {
                const grp = node.data.group;
                if (grp.mod != null) return false; // inline-flag group
                if (grp.capture_index) |idx| {
                    // 1-based capture index -> 0-based group slot.
                    if (idx == 0 or idx > self.num_groups) return false;
                    self.starts.items[idx - 1] = self.segs.items.len;
                    if (!try self.flatten(grp.child)) return false;
                    self.ends.items[idx - 1] = self.segs.items.len - 1;
                    return true;
                } else {
                    return try self.flatten(grp.child);
                }
            },
            else => return false, // alternation, anchor, backref, lookaround, ...
        }
    }
};

/// Build a one-pass plan for `root`, or null if the pattern isn't eligible.
/// `num_groups` is the capture count.
pub fn build(allocator: std.mem.Allocator, root: *ast.Node, num_groups: usize, flags: common.CompileFlags) !?*Plan {
    if (flags.case_insensitive) return null;
    if (flags.unicode or flags.unicode_sets) return null;
    if (num_groups == 0) return null; // capture-free patterns use the DFA path

    var b = Builder{
        .allocator = allocator,
        .flags = flags,
        .segs = .empty,
        .starts = .empty,
        .ends = .empty,
        .num_groups = num_groups,
    };
    defer b.segs.deinit(allocator);
    defer b.starts.deinit(allocator);
    defer b.ends.deinit(allocator);

    // Sentinel-fill marker arrays; every group must get assigned during flatten.
    try b.starts.appendNTimes(allocator, std.math.maxInt(usize), num_groups);
    try b.ends.appendNTimes(allocator, std.math.maxInt(usize), num_groups);

    if (!(try b.flatten(root))) return null;
    if (b.segs.items.len == 0) return null;

    // Every group must have been assigned a start and end within the sequence.
    for (b.starts.items) |s| {
        if (s == std.math.maxInt(usize)) return null;
    }
    for (b.ends.items) |e| {
        if (e == std.math.maxInt(usize)) return null;
    }

    // Disjoint-boundary check: a variable-length atom's byte set must be disjoint
    // from the next atom's, so greedy matching never has to give bytes back.
    for (b.segs.items, 0..) |seg, i| {
        if (!seg.variable) continue;
        if (i + 1 >= b.segs.items.len) continue; // last atom: greedy to end is fine
        const next = b.segs.items[i + 1];
        var byte: usize = 0;
        while (byte < 256) : (byte += 1) {
            if (seg.table[byte] and next.table[byte]) return null; // overlap -> ambiguous
        }
    }

    const plan = try allocator.create(Plan);
    errdefer allocator.destroy(plan);
    plan.* = .{
        .allocator = allocator,
        .segs = try b.segs.toOwnedSlice(allocator),
        .num_groups = num_groups,
        .group_start_before = try b.starts.toOwnedSlice(allocator),
        .group_end_after = try b.ends.toOwnedSlice(allocator),
    };
    return plan;
}

const parser = @import("parser.zig");
const compiler = @import("compiler.zig");

fn capEq(a: ?vm.MatchResult, b: ?vm.MatchResult) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const x = a.?;
    const y = b.?;
    if (x.start != y.start or x.end != y.end) return false;
    if (x.captures.len != y.captures.len) return false;
    for (x.captures, y.captures) |cx, cy| {
        if (cx.matched != cy.matched) return false;
        if (cx.matched and (cx.start != cy.start or cx.end != cy.end)) return false;
    }
    return true;
}

// The one-pass plan must agree with the NFA (vm.matchAt) on the match bounds and
// every capture group, at every start position, for eligible patterns. This is
// the safety net: if the plan or its eligibility is ever wrong, this fails.
test "onepass: differential vs NFA across patterns/inputs/positions" {
    const allocator = std.testing.allocator;
    const patterns = [_][]const u8{
        "(\\w+)@(\\w+)", "(\\d+)-(\\d+)",   "([a-z]+)([0-9]+)",
        "(foo)([0-9]+)", "(a+)(b+)",        "(\\w+):(\\d+)",
        "x(\\d+)y",      "([A-Z])([a-z]+)", "(\\d{2,4})-(\\d+)",
        "(ab+)(c)",      "(\\d+)\\.(\\d+)",
        // nullable atoms (still disjoint-bounded)
        "(\\w*)@(\\w*)",
        "(\\d*)-(\\d+)", "(a?)(b+)",        "(x*)(y*)",
        "(\\w*)",        "(-?)(\\d+)",
    };
    const inputs = [_][]const u8{
        "",                 "a",             "ab12",
        "foo@bar baz@qux",  "12-34 5-6 78-", "aaabbb ab x",
        "Hello World abC1", "v1.2.33 9.9",   "x123y x4 xy y9y",
        "a1b2c3 word 99",   "::: 1:2 ab:cd", "ab12c abbc abc",
    };
    var tested: usize = 0;
    for (patterns) |pat| {
        var p = try parser.Parser.init(allocator, pat);
        var tree = try p.parse();
        defer tree.deinit();

        const plan = (try build(allocator, tree.root, tree.capture_count, .{})) orelse continue;
        defer plan.deinit();

        var comp = compiler.Compiler.init(allocator);
        defer comp.deinit();
        const nfa = try comp.compile(&tree);
        var v = vm.VM.init(allocator, nfa, tree.capture_count, .{});
        defer v.deinit();

        for (inputs) |inp| {
            var s: usize = 0;
            while (s <= inp.len) : (s += 1) {
                var pr = try plan.matchAt(allocator, inp, s);
                defer if (pr) |*r| r.deinit(allocator);
                var nr = try v.matchAt(inp, s);
                defer if (nr) |*r| r.deinit(allocator);
                if (!capEq(pr, nr)) {
                    std.debug.print("MISMATCH pat={s} input={s} pos={d}\n", .{ pat, inp, s });
                    return error.OnePassMismatch;
                }
                tested += 1;
            }
        }
    }
    try std.testing.expect(tested > 0);
}
