//! Binary-safe Aho-Corasick automaton with pattern ids, optional ASCII case
//! folding and a relocatable serialised form.
//!
//! Patterns are arbitrary byte strings. Bytes are first mapped to equivalence
//! classes: every byte that occurs in some pattern gets its own class (ASCII
//! letters share one with their other case when folding), and every other
//! byte shares class 0. Two layouts exist:
//!
//! - dense: a full DFA, one row of `stride` (a power of two at least the class
//!   count) premultiplied `u32` targets per state, so a step is one load;
//! - sparse: per state a sorted class list, targets and a failure link, for
//!   automata too large to expand; the root and the shallowest states (where
//!   failure walks end most often) still get complete rows.
//!
//! States are numbered root first, then states with no output, then states
//! with output, so "is there a match here" is a single compare. Each state
//! keeps its own outputs (patterns equal to its full path) and a dictionary
//! link to the nearest proper suffix state that has outputs.

const std = @import("std");
const blob = @import("blob.zig");
const types = @import("types.zig");

const Pattern = types.Pattern;
const Match = types.Match;

pub const magic = "ZACA".*;
pub const format_version: u16 = 1;

pub const LoadError = blob.LoadError;

pub const BuildError = std.mem.Allocator.Error || error{
    /// No patterns at all.
    NoPatterns,
    /// An empty pattern matches everywhere; filter it out before building.
    EmptyPattern,
    /// More than 2^31 bytes of patterns or states.
    TooLarge,
};

pub const Layout = enum {
    /// Dense when the full DFA fits in `Options.dense_max_bytes`.
    auto,
    dense,
    sparse,
};

pub const Options = struct {
    /// Match ASCII letters regardless of case; every other byte matches exactly.
    ascii_case_insensitive: bool = false,
    layout: Layout = .auto,
    /// Size limit for choosing the dense layout under `.auto`.
    dense_max_bytes: usize = 8 << 20,
    /// Sparse layout: states up to this depth get complete rows, within
    /// `shallow_max_bytes`. The root always gets one.
    shallow_depth: u32 = 2,
    shallow_max_bytes: usize = 1 << 20,
};

const flag_nocase: u32 = 1;
const flag_dense: u32 = 2;
const no_state: u32 = std.math.maxInt(u32);
const max_states: u64 = 1 << 31;

const Header = extern struct {
    prefix: blob.Prefix,
    flags: u32,
    num_states: u32,
    num_classes: u32,
    stride_shift: u32,
    num_patterns: u32,
    /// States with ids at or above this one have output.
    match_min: u32,
    min_len: u32,
    max_len: u32,
    num_edges: u32,
    num_outputs: u32,
    /// Sparse only: number of complete rows of `num_classes` state ids.
    num_rows: u32,
    _pad: u32 = 0,
    /// `[256]u8` byte to class.
    classes_off: u64,
    /// Dense: `u32[num_states << stride_shift]` premultiplied targets.
    /// Sparse: `u32[num_rows * num_classes]` complete rows of state ids.
    trans_off: u64,
    /// Sparse only: `SparseState[num_states]`.
    sparse_off: u64,
    /// Sparse only: `u8[num_edges]` classes and `u32[num_edges]` targets.
    edge_class_off: u64,
    edge_target_off: u64,
    /// `StateInfo[num_states]`.
    info_off: u64,
    /// `u32[num_outputs]` pattern indices, grouped by state.
    outputs_off: u64,
    /// `PatternInfo[num_patterns]`.
    patterns_off: u64,
};

const SparseState = extern struct {
    fail: u32,
    edge_start: u32,
    edge_len: u32,
    /// Offset of this state's complete row in the row table (its row index
    /// times `num_classes`), or `no_state`. The root's row is at 0.
    row: u32,
};

const StateInfo = extern struct {
    depth: u32,
    out_start: u32,
    out_len: u32,
    /// Nearest proper suffix state with outputs, or `no_state`.
    dict: u32,
};

const PatternInfo = extern struct {
    id: u32,
    len: u32,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 128);
    std.debug.assert(@sizeOf(SparseState) == 16);
    std.debug.assert(@sizeOf(StateInfo) == 16);
    std.debug.assert(@sizeOf(PatternInfo) == 8);
}

/// Resumable position for `scanStream`: feed a stream in chunks and matches
/// spanning chunk boundaries are still reported, with stream offsets.
pub const Stream = struct {
    state: u32 = 0,
    offset: u64 = 0,
};

/// An automaton viewing a blob. Copying it is cheap; searching never
/// allocates and never writes to the blob.
pub const AhoCorasick = struct {
    nocase: bool,
    dense: bool,
    num_classes: u32,
    stride_shift: u5,
    match_min: u32,
    min_len: u32,
    max_len: u32,
    classes: *const [256]u8,
    trans: []const u32,
    sparse: []const SparseState,
    edge_class: []const u8,
    edge_target: []const u32,
    info: []const StateInfo,
    outputs: []const u32,
    patterns: []const PatternInfo,

    pub const Owned = blob.Owned(AhoCorasick);

    pub fn build(gpa: std.mem.Allocator, patterns: []const Pattern, options: Options) BuildError!Owned {
        return Builder.run(gpa, patterns, options);
    }

    /// View a serialised automaton in place after checking every index in it,
    /// so a corrupt blob is rejected instead of misbehaving. Reads the whole
    /// blob once. `bytes` must start on an 8-byte boundary and stay alive and
    /// unchanged while the automaton is used.
    pub fn load(bytes: []const u8) LoadError!AhoCorasick {
        const self = try loadUnchecked(bytes);
        try self.validate();
        return self;
    }

    /// View a serialised automaton checking only the header and section
    /// bounds, without touching the sections. Only for blobs whose integrity
    /// is established otherwise (a verified signature or digest): a corrupt
    /// blob can make searches return wrong results or index out of bounds.
    pub fn loadUnchecked(bytes: []const u8) LoadError!AhoCorasick {
        const h, const b = try blob.readHeader(Header, bytes, magic, format_version);
        if (h.flags & ~(flag_nocase | flag_dense) != 0) return error.Corrupt;
        const n = h.num_states;
        if (n == 0 or n > max_states) return error.Corrupt;
        if (h.num_classes == 0 or h.num_classes > 256) return error.Corrupt;
        if (h.stride_shift > 8) return error.Corrupt;
        if (h.match_min == 0 or h.match_min > n) return error.Corrupt;
        if (h.num_patterns == 0) return error.Corrupt;
        const dense = h.flags & flag_dense != 0;
        if (!dense and (h.num_rows == 0 or h.num_rows > n)) return error.Corrupt;
        if (dense) {
            const stride = @as(u64, 1) << @intCast(h.stride_shift);
            if (stride < h.num_classes) return error.Corrupt;
            if (@as(u64, n) * stride > std.math.maxInt(u32) + 1) return error.Corrupt;
        }
        const classes = try blob.section([256]u8, b, h.classes_off, 1);
        return .{
            .nocase = h.flags & flag_nocase != 0,
            .dense = dense,
            .num_classes = h.num_classes,
            .stride_shift = @intCast(h.stride_shift),
            .match_min = h.match_min,
            .min_len = h.min_len,
            .max_len = h.max_len,
            .classes = &classes[0],
            .trans = try blob.section(u32, b, h.trans_off, if (dense) @as(u64, n) << @intCast(h.stride_shift) else @as(u64, h.num_rows) * h.num_classes),
            .sparse = if (dense) &.{} else try blob.section(SparseState, b, h.sparse_off, n),
            .edge_class = if (dense) &.{} else try blob.section(u8, b, h.edge_class_off, h.num_edges),
            .edge_target = if (dense) &.{} else try blob.section(u32, b, h.edge_target_off, h.num_edges),
            .info = try blob.section(StateInfo, b, h.info_off, n),
            .outputs = try blob.section(u32, b, h.outputs_off, h.num_outputs),
            .patterns = try blob.section(PatternInfo, b, h.patterns_off, h.num_patterns),
        };
    }

    fn validate(self: *const AhoCorasick) LoadError!void {
        const n: u32 = @intCast(self.info.len);
        for (self.classes) |c| if (c >= self.num_classes) return error.Corrupt;
        var min_len: u32 = std.math.maxInt(u32);
        var max_len: u32 = 0;
        for (self.patterns) |p| {
            if (p.len == 0) return error.Corrupt;
            min_len = @min(min_len, p.len);
            max_len = @max(max_len, p.len);
        }
        if (min_len != self.min_len or max_len != self.max_len) return error.Corrupt;
        if (self.info[0].depth != 0) return error.Corrupt;
        for (self.info, 0..) |s, i| {
            if (@as(u64, s.out_start) + s.out_len > self.outputs.len) return error.Corrupt;
            for (self.outputs[s.out_start..][0..s.out_len]) |pi| {
                if (pi >= self.patterns.len or self.patterns[pi].len != s.depth) return error.Corrupt;
            }
            // A dictionary link points strictly shallower, so chains end.
            if (s.dict != no_state and (s.dict >= n or self.info[s.dict].depth >= s.depth or
                self.info[s.dict].out_len == 0)) return error.Corrupt;
            const has_output = s.out_len != 0 or s.dict != no_state;
            if (has_output != (i >= self.match_min)) return error.Corrupt;
        }
        if (self.dense) {
            const shift = self.stride_shift;
            for (self.trans) |t| {
                if (t & ((@as(u32, 1) << shift) - 1) != 0 or (t >> shift) >= n) return error.Corrupt;
            }
        } else {
            for (self.trans) |t| if (t >= n) return error.Corrupt;
            for (self.edge_target) |t| if (t >= n) return error.Corrupt;
            if (self.sparse[0].row != 0) return error.Corrupt;
            for (self.sparse, 0..) |s, i| {
                if (s.row != no_state and (s.row % self.num_classes != 0 or s.row >= self.trans.len)) return error.Corrupt;
                if (@as(u64, s.edge_start) + s.edge_len > self.edge_class.len) return error.Corrupt;
                if (s.fail >= n) return error.Corrupt;
                // A failure link points strictly shallower (root to itself),
                // so the failure walk always ends at the root.
                if (i != 0 and self.info[s.fail].depth >= self.info[i].depth) return error.Corrupt;
                const cls = self.edge_class[s.edge_start..][0..s.edge_len];
                for (cls, 0..) |c, k| {
                    if (c >= self.num_classes) return error.Corrupt;
                    if (k > 0 and cls[k - 1] >= c) return error.Corrupt;
                }
            }
        }
    }

    pub fn patternCount(self: *const AhoCorasick) usize {
        return self.patterns.len;
    }

    /// True when any pattern occurs in `haystack`.
    pub fn isMatch(self: *const AhoCorasick, haystack: []const u8) bool {
        if (self.dense) return self.isMatchImpl(true, haystack);
        return self.isMatchImpl(false, haystack);
    }

    fn isMatchImpl(self: *const AhoCorasick, comptime dense: bool, haystack: []const u8) bool {
        const threshold = self.matchThreshold(dense);
        var s: u32 = 0;
        for (haystack) |b| {
            s = self.next(dense, s, b);
            if (s >= threshold) return true;
        }
        return false;
    }

    /// Report every occurrence of every pattern, overlapping ones included.
    /// Matches come in ascending end order; at one end, longest first, then
    /// in pattern order. `onMatch` returns false to stop; `scanAll` then
    /// returns false.
    pub fn scanAll(
        self: *const AhoCorasick,
        haystack: []const u8,
        context: anytype,
        comptime onMatch: fn (@TypeOf(context), Match) bool,
    ) bool {
        var st: Stream = .{};
        return self.scanStream(&st, haystack, context, onMatch);
    }

    /// `scanAll` over a stream fed in chunks. Positions in reported matches
    /// are stream offsets. When `onMatch` stops the scan, `stream` is left
    /// after the byte that produced the stopping match.
    pub fn scanStream(
        self: *const AhoCorasick,
        stream: *Stream,
        chunk: []const u8,
        context: anytype,
        comptime onMatch: fn (@TypeOf(context), Match) bool,
    ) bool {
        if (self.dense) return self.scanImpl(true, stream, chunk, context, onMatch);
        return self.scanImpl(false, stream, chunk, context, onMatch);
    }

    fn scanImpl(
        self: *const AhoCorasick,
        comptime dense: bool,
        stream: *Stream,
        chunk: []const u8,
        context: anytype,
        comptime onMatch: fn (@TypeOf(context), Match) bool,
    ) bool {
        const threshold = self.matchThreshold(dense);
        var s = stream.state;
        for (chunk, 0..) |b, i| {
            s = self.next(dense, s, b);
            if (s >= threshold) {
                const end: usize = @intCast(stream.offset + i + 1);
                var st = self.index(dense, s);
                while (st != no_state) {
                    const inf = self.info[st];
                    for (self.outputs[inf.out_start..][0..inf.out_len]) |pi| {
                        const m: Match = .{ .pattern = self.patterns[pi].id, .start = end - inf.depth, .end = end };
                        if (!onMatch(context, m)) {
                            stream.state = s;
                            stream.offset += i + 1;
                            return false;
                        }
                    }
                    st = inf.dict;
                }
            }
        }
        stream.state = s;
        stream.offset += chunk.len;
        return true;
    }

    /// The leftmost-longest match starting at or after `from`: the smallest
    /// start, then the longest pattern there, then the first such pattern.
    pub fn findLeftmostLongest(self: *const AhoCorasick, haystack: []const u8, from: usize) ?Match {
        if (self.dense) return self.leftmostLongestImpl(true, haystack, from);
        return self.leftmostLongestImpl(false, haystack, from);
    }

    fn leftmostLongestImpl(self: *const AhoCorasick, comptime dense: bool, hay: []const u8, from: usize) ?Match {
        const threshold = self.matchThreshold(dense);
        var s: u32 = 0;
        var best: ?Match = null;
        var i = from;
        while (i < hay.len) {
            s = self.next(dense, s, hay[i]);
            i += 1;
            if (best) |m| {
                // Every live partial match is a suffix no longer than the
                // current depth, so none can start at or before `m.start`.
                if (i - self.info[self.index(dense, s)].depth > m.start) return m;
            }
            if (s >= threshold) {
                var st = self.index(dense, s);
                if (self.info[st].out_len == 0) st = self.info[st].dict;
                const inf = self.info[st];
                const start = i - inf.depth;
                // A later end at the same start is a longer match.
                if (best == null or start <= best.?.start) {
                    const pi = self.outputs[inf.out_start];
                    best = .{ .pattern = self.patterns[pi].id, .start = start, .end = i };
                }
            }
        }
        return best;
    }

    /// Iterate non-overlapping leftmost-longest matches, each search resuming
    /// at the previous match's end.
    pub fn iterator(self: *const AhoCorasick, haystack: []const u8) Iterator {
        return .{ .ac = self, .haystack = haystack };
    }

    pub const Iterator = struct {
        ac: *const AhoCorasick,
        haystack: []const u8,
        pos: usize = 0,

        pub fn next(it: *Iterator) ?Match {
            const m = it.ac.findLeftmostLongest(it.haystack, it.pos) orelse {
                it.pos = it.haystack.len;
                return null;
            };
            it.pos = m.end;
            return m;
        }
    };

    inline fn matchThreshold(self: *const AhoCorasick, comptime dense: bool) u32 {
        return if (dense) self.match_min << self.stride_shift else self.match_min;
    }

    inline fn index(self: *const AhoCorasick, comptime dense: bool, s: u32) u32 {
        return if (dense) s >> self.stride_shift else s;
    }

    inline fn next(self: *const AhoCorasick, comptime dense: bool, s: u32, byte: u8) u32 {
        const c = self.classes[byte];
        if (dense) return self.trans[s + c];
        var cur = s;
        while (true) {
            // The root is the most common state; skip loading its record.
            if (cur == 0) return self.trans[c];
            const rec = self.sparse[cur];
            if (rec.row != no_state) return self.trans[rec.row + c];
            const cls = self.edge_class[rec.edge_start..][0..rec.edge_len];
            for (cls, 0..) |e, k| {
                if (e == c) return self.edge_target[rec.edge_start + k];
            }
            cur = rec.fail;
        }
    }
};

const Builder = struct {
    const Edge = struct { parent: u32, class: u8, child: u32 };
    const Out = struct { node: u32, pattern: u32 };

    fn run(gpa: std.mem.Allocator, patterns: []const Pattern, options: Options) BuildError!AhoCorasick.Owned {
        if (patterns.len == 0) return error.NoPatterns;
        if (patterns.len >= max_states) return error.TooLarge;
        const nocase = options.ascii_case_insensitive;
        var total: u64 = 0;
        var min_len: usize = std.math.maxInt(usize);
        var max_len: usize = 0;
        var used: [256]bool = @splat(false);
        for (patterns) |p| {
            if (p.bytes.len == 0) return error.EmptyPattern;
            total += p.bytes.len;
            min_len = @min(min_len, p.bytes.len);
            max_len = @max(max_len, p.bytes.len);
            for (p.bytes) |b| used[if (nocase) types.fold(b) else b] = true;
        }
        if (total + 1 > max_states) return error.TooLarge;

        // Byte classes: class 0 for bytes no pattern uses (when there are
        // any), then one class per used byte in ascending order.
        var classes: [256]u8 = undefined;
        var num_classes: u32 = 0;
        {
            var rep_class: [256]u16 = undefined;
            var any_unused = false;
            for (0..256) |b| {
                if (!used[if (nocase) types.fold(@intCast(b)) else b]) any_unused = true;
            }
            num_classes = @intFromBool(any_unused);
            for (0..256) |b| {
                if (used[b] and (!nocase or types.fold(@intCast(b)) == b)) {
                    rep_class[b] = @intCast(num_classes);
                    num_classes += 1;
                }
            }
            for (0..256) |b| {
                const rep = if (nocase) types.fold(@intCast(b)) else b;
                classes[b] = if (used[rep]) @intCast(rep_class[rep]) else 0;
            }
        }

        // Trie.
        var depth: std.ArrayList(u32) = .empty;
        defer depth.deinit(gpa);
        var edges: std.ArrayList(Edge) = .empty;
        defer edges.deinit(gpa);
        var outs: std.ArrayList(Out) = .empty;
        defer outs.deinit(gpa);
        var goto: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer goto.deinit(gpa);
        try depth.append(gpa, 0);
        try outs.ensureTotalCapacity(gpa, patterns.len);
        for (patterns, 0..) |p, pi| {
            var s: u32 = 0;
            for (p.bytes) |b| {
                const c = classes[b];
                const gop = try goto.getOrPut(gpa, key(s, c));
                if (!gop.found_existing) {
                    const child: u32 = @intCast(depth.items.len);
                    try depth.append(gpa, depth.items[s] + 1);
                    try edges.append(gpa, .{ .parent = s, .class = c, .child = child });
                    gop.value_ptr.* = child;
                }
                s = gop.value_ptr.*;
            }
            outs.appendAssumeCapacity(.{ .node = s, .pattern = @intCast(pi) });
        }
        const n: u32 = @intCast(depth.items.len);

        std.mem.sort(Edge, edges.items, {}, struct {
            fn lt(_: void, a: Edge, b: Edge) bool {
                if (a.parent != b.parent) return a.parent < b.parent;
                return a.class < b.class;
            }
        }.lt);
        std.mem.sort(Out, outs.items, {}, struct {
            fn lt(_: void, a: Out, b: Out) bool {
                if (a.node != b.node) return a.node < b.node;
                return a.pattern < b.pattern;
            }
        }.lt);
        const child_start = try gpa.alloc(u32, n + 1);
        defer gpa.free(child_start);
        @memset(child_start, 0);
        for (edges.items) |e| child_start[e.parent + 1] += 1;
        for (1..n + 1) |i| child_start[i] += child_start[i - 1];
        const out_start = try gpa.alloc(u32, n + 1);
        defer gpa.free(out_start);
        @memset(out_start, 0);
        for (outs.items) |o| out_start[o.node + 1] += 1;
        for (1..n + 1) |i| out_start[i] += out_start[i - 1];

        // Breadth-first order, failure links and dictionary links.
        const order = try gpa.alloc(u32, n);
        defer gpa.free(order);
        const fail = try gpa.alloc(u32, n);
        defer gpa.free(fail);
        const dict = try gpa.alloc(u32, n);
        defer gpa.free(dict);
        order[0] = 0;
        fail[0] = 0;
        dict[0] = no_state;
        var tail: usize = 1;
        for (0..n) |qi| {
            const u = order[qi];
            for (edges.items[child_start[u]..child_start[u + 1]]) |e| {
                const v = e.child;
                order[tail] = v;
                tail += 1;
                var f: u32 = 0;
                if (u != 0) {
                    var x = fail[u];
                    while (true) {
                        if (goto.get(key(x, e.class))) |t| {
                            f = t;
                            break;
                        }
                        if (x == 0) break;
                        x = fail[x];
                    }
                }
                fail[v] = f;
                dict[v] = if (out_start[f + 1] > out_start[f]) f else dict[f];
            }
        }
        std.debug.assert(tail == n);

        // Renumber: root, states without output, states with output.
        const new_id = try gpa.alloc(u32, n);
        defer gpa.free(new_id);
        var next_id: u32 = 1;
        new_id[0] = 0;
        for (order[1..]) |u| {
            if (!hasOutput(u, out_start, dict)) {
                new_id[u] = next_id;
                next_id += 1;
            }
        }
        const match_min = next_id;
        for (order[1..]) |u| {
            if (hasOutput(u, out_start, dict)) {
                new_id[u] = next_id;
                next_id += 1;
            }
        }
        const old_of = try gpa.alloc(u32, n);
        defer gpa.free(old_of);
        for (0..n) |u| old_of[new_id[u]] = @intCast(u);

        const stride_shift: u5 = @intCast(std.math.log2_int_ceil(u32, @max(num_classes, 1)));
        const dense_bytes = (@as(u64, n) << stride_shift) * 4;
        const dense_fits = (@as(u64, n) << stride_shift) <= @as(u64, std.math.maxInt(u32)) + 1;
        const dense = switch (options.layout) {
            .dense => if (dense_fits) true else return error.TooLarge,
            .sparse => false,
            .auto => dense_fits and dense_bytes <= options.dense_max_bytes,
        };

        var layout = blob.Layout.init(Header);
        const classes_off = layout.reserve([256]u8, 1);
        // Sparse: complete rows for a breadth-first prefix of the shallow
        // states. A failure link points earlier in breadth-first order, so a
        // state's failure state always has a row when the state has one.
        var num_rows: u32 = 0;
        if (!dense) {
            // Row offsets are u32 and `no_state` stays out of range.
            const max_rows = (std.math.maxInt(u32) - 1) / num_classes;
            const budget = @min(max_rows, @max(1, options.shallow_max_bytes / (@as(usize, num_classes) * 4)));
            for (order) |u| {
                if (num_rows == budget or (u != 0 and depth.items[u] > options.shallow_depth)) break;
                num_rows += 1;
            }
        }
        const trans_len: usize = if (dense) @intCast(@as(u64, n) << stride_shift) else @as(usize, num_rows) * num_classes;
        const trans_off = layout.reserve(u32, trans_len);
        const num_edges: usize = if (dense) 0 else edges.items.len;
        const sparse_off = if (dense) 0 else layout.reserve(SparseState, n);
        const edge_class_off = if (dense) 0 else layout.reserve(u8, num_edges);
        const edge_target_off = if (dense) 0 else layout.reserve(u32, num_edges);
        const info_off = layout.reserve(StateInfo, n);
        const outputs_off = layout.reserve(u32, outs.items.len);
        const patterns_off = layout.reserve(PatternInfo, patterns.len);
        const bytes = try blob.allocBlob(gpa, layout.total());
        errdefer gpa.free(bytes);

        const h: *Header = @ptrCast(bytes.ptr);
        h.* = .{
            .prefix = .{
                .magic = magic,
                .version = format_version,
                .header_size = @sizeOf(Header),
                .total_len = bytes.len,
            },
            .flags = (if (nocase) flag_nocase else 0) | (if (dense) flag_dense else 0),
            .num_states = n,
            .num_classes = num_classes,
            .stride_shift = stride_shift,
            .num_patterns = @intCast(patterns.len),
            .match_min = match_min,
            .min_len = @intCast(min_len),
            .max_len = @intCast(max_len),
            .num_edges = @intCast(num_edges),
            .num_outputs = @intCast(outs.items.len),
            .num_rows = num_rows,
            .classes_off = classes_off,
            .trans_off = trans_off,
            .sparse_off = sparse_off,
            .edge_class_off = edge_class_off,
            .edge_target_off = edge_target_off,
            .info_off = info_off,
            .outputs_off = outputs_off,
            .patterns_off = patterns_off,
        };
        blob.sectionMut([256]u8, bytes, classes_off, 1)[0] = classes;

        const pinfo = blob.sectionMut(PatternInfo, bytes, patterns_off, patterns.len);
        for (patterns, pinfo) |p, *d| d.* = .{ .id = p.id, .len = @intCast(p.bytes.len) };

        const info = blob.sectionMut(StateInfo, bytes, info_off, n);
        const outputs = blob.sectionMut(u32, bytes, outputs_off, outs.items.len);
        var out_cursor: u32 = 0;
        for (0..n) |id| {
            const u = old_of[id];
            const own = outs.items[out_start[u]..out_start[u + 1]];
            for (own, 0..) |o, k| outputs[out_cursor + k] = o.pattern;
            info[id] = .{
                .depth = depth.items[u],
                .out_start = out_cursor,
                .out_len = @intCast(own.len),
                .dict = if (dict[u] == no_state) no_state else new_id[dict[u]],
            };
            out_cursor += @intCast(own.len);
        }

        const trans = blob.sectionMut(u32, bytes, trans_off, trans_len);
        if (dense) {
            // Breadth-first, so the failure state's row is complete before
            // it is copied.
            const stride = @as(usize, 1) << stride_shift;
            for (order) |u| {
                const row = trans[@as(usize, new_id[u]) * stride ..][0..stride];
                if (u == 0) {
                    @memset(row, 0);
                } else {
                    @memcpy(row, trans[@as(usize, new_id[fail[u]]) * stride ..][0..stride]);
                }
                for (edges.items[child_start[u]..child_start[u + 1]]) |e| {
                    row[e.class] = new_id[e.child] << stride_shift;
                }
            }
        } else {
            // Rows are numbered in breadth-first order, so row r belongs to
            // `order[r]`; `row_of` maps the other way.
            const row_of = try gpa.alloc(u32, n);
            defer gpa.free(row_of);
            @memset(row_of, no_state);
            for (order[0..num_rows], 0..) |u, r| {
                row_of[u] = @intCast(r);
                const row = trans[r * num_classes ..][0..num_classes];
                if (u == 0) {
                    @memset(row, 0);
                } else {
                    @memcpy(row, trans[@as(usize, row_of[fail[u]]) * num_classes ..][0..num_classes]);
                }
                for (edges.items[child_start[u]..child_start[u + 1]]) |e| row[e.class] = new_id[e.child];
            }
            const sparse = blob.sectionMut(SparseState, bytes, sparse_off, n);
            const edge_class = blob.sectionMut(u8, bytes, edge_class_off, num_edges);
            const edge_target = blob.sectionMut(u32, bytes, edge_target_off, num_edges);
            var cursor: u32 = 0;
            for (0..n) |id| {
                const u = old_of[id];
                const kids = edges.items[child_start[u]..child_start[u + 1]];
                sparse[id] = .{
                    .fail = new_id[fail[u]],
                    .edge_start = cursor,
                    .edge_len = if (row_of[u] != no_state) 0 else @intCast(kids.len),
                    .row = if (row_of[u] == no_state) no_state else row_of[u] * num_classes,
                };
                if (row_of[u] != no_state) continue;
                for (kids, 0..) |e, k| {
                    edge_class[cursor + k] = e.class;
                    edge_target[cursor + k] = new_id[e.child];
                }
                cursor += @intCast(kids.len);
            }
        }

        const view = AhoCorasick.loadUnchecked(bytes) catch unreachable;
        if (std.debug.runtime_safety) view.validate() catch unreachable;
        return .{ .bytes = bytes, .view = view };
    }

    inline fn key(state: u32, class: u8) u64 {
        return (@as(u64, state) << 8) | class;
    }

    fn hasOutput(u: u32, out_start: []const u32, dict: []const u32) bool {
        return out_start[u + 1] > out_start[u] or dict[u] != no_state;
    }
};

const testing = std.testing;
const naive = @import("naive.zig");

fn collect(list: *std.ArrayList(Match), m: Match) bool {
    list.append(testing.allocator, m) catch return false;
    return true;
}

fn checkAgainstNaive(gpa: std.mem.Allocator, pats: []const Pattern, hay: []const u8, options: Options) !void {
    var ac = try AhoCorasick.build(gpa, pats, options);
    defer ac.deinit(gpa);
    try checkBuilt(gpa, &ac.view, pats, hay);
}

fn checkBuilt(gpa: std.mem.Allocator, ac: *const AhoCorasick, pats: []const Pattern, hay: []const u8) !void {
    const topts: types.Options = .{ .ascii_case_insensitive = ac.nocase };

    const want_all = try naive.allMatches(gpa, pats, hay, topts);
    defer gpa.free(want_all);
    var got: std.ArrayList(Match) = .empty;
    defer got.deinit(gpa);
    try testing.expect(ac.scanAll(hay, &got, collect));
    std.mem.sort(Match, got.items, {}, naive.lessThan);
    try testing.expectEqualSlices(Match, want_all, got.items);
    try testing.expectEqual(want_all.len != 0, ac.isMatch(hay));

    const want_ll = try naive.leftmostLongest(gpa, pats, hay, topts);
    defer gpa.free(want_ll);
    got.clearRetainingCapacity();
    var it = ac.iterator(hay);
    while (it.next()) |m| try got.append(gpa, m);
    try testing.expectEqualSlices(Match, want_ll, got.items);
}

test "aho-corasick reports ids, positions and binary bytes" {
    const pats = [_]Pattern{
        .{ .bytes = "he", .id = 7 },
        .{ .bytes = "she", .id = 8 },
        .{ .bytes = "his", .id = 9 },
        .{ .bytes = "hers", .id = 10 },
        .{ .bytes = "\x00\xff", .id = 11 },
    };
    for ([_]Layout{ .dense, .sparse }) |layout| {
        try checkAgainstNaive(testing.allocator, &pats, "ushers\x00\xff\x00\xffhis", .{ .layout = layout });
        try checkAgainstNaive(testing.allocator, &pats, "USHERS\x00\xffHiS", .{ .layout = layout, .ascii_case_insensitive = true });
    }
    var ac = try AhoCorasick.build(testing.allocator, &pats, .{});
    defer ac.deinit(testing.allocator);
    const m = ac.view.findLeftmostLongest("ushers", 0).?;
    try testing.expectEqual(Match{ .pattern = 8, .start = 1, .end = 4 }, m);
}

test "aho-corasick rejects bad pattern sets" {
    try testing.expectError(error.NoPatterns, AhoCorasick.build(testing.allocator, &.{}, .{}));
    try testing.expectError(error.EmptyPattern, AhoCorasick.build(testing.allocator, &.{.{ .bytes = "", .id = 0 }}, .{}));
}

test "aho-corasick exhaustive over a two-byte alphabet" {
    // Every set of patterns of length 1 and 2 over {0x00, 0xff}, against
    // every haystack of length up to 5 over the same bytes. tests/literals.zig
    // runs the same sweep to length 10.
    const strings = [_][]const u8{ "\x00", "\xff", "\x00\x00", "\x00\xff", "\xff\x00", "\xff\xff" };
    var pats: [strings.len]Pattern = undefined;
    var hay: [5]u8 = undefined;
    for (1..(1 << strings.len)) |set| {
        var n: usize = 0;
        for (strings, 0..) |s, i| {
            if (set & (@as(usize, 1) << @intCast(i)) != 0) {
                pats[n] = .{ .bytes = s, .id = @intCast(i) };
                n += 1;
            }
        }
        for ([_]Layout{ .dense, .sparse }) |layout| {
            var ac = try AhoCorasick.build(testing.allocator, pats[0..n], .{ .layout = layout });
            defer ac.deinit(testing.allocator);
            for (0..hay.len + 1) |len| {
                for (0..(@as(usize, 1) << @intCast(len))) |bits| {
                    for (0..len) |k| hay[k] = if (bits & (@as(usize, 1) << @intCast(k)) != 0) 0xff else 0x00;
                    try checkBuilt(testing.allocator, &ac.view, pats[0..n], hay[0..len]);
                }
            }
        }
    }
}

test "aho-corasick serialised copy matches identically" {
    const pats = [_]Pattern{ .{ .bytes = "abc", .id = 1 }, .{ .bytes = "bc", .id = 2 }, .{ .bytes = "\xff", .id = 3 } };
    for ([_]Layout{ .dense, .sparse }) |layout| {
        var ac = try AhoCorasick.build(testing.allocator, &pats, .{ .layout = layout });
        defer ac.deinit(testing.allocator);
        const copy = try blob.dupeAligned(testing.allocator, ac.bytes);
        defer testing.allocator.free(copy);
        const v = try AhoCorasick.load(copy);
        try testing.expectEqual(layout == .dense, v.dense);
        const hay = "zabc\xffbcabc";
        var a: std.ArrayList(Match) = .empty;
        defer a.deinit(testing.allocator);
        var b: std.ArrayList(Match) = .empty;
        defer b.deinit(testing.allocator);
        _ = ac.view.scanAll(hay, &a, collect);
        _ = v.scanAll(hay, &b, collect);
        try testing.expectEqualSlices(Match, a.items, b.items);
    }
}

test "aho-corasick load rejects corrupt blobs" {
    const pats = [_]Pattern{ .{ .bytes = "abc", .id = 1 }, .{ .bytes = "bcd", .id = 2 } };
    var ac = try AhoCorasick.build(testing.allocator, &pats, .{ .layout = .sparse });
    defer ac.deinit(testing.allocator);
    const copy = try blob.dupeAligned(testing.allocator, ac.bytes);
    defer testing.allocator.free(copy);
    const h: *Header = @ptrCast(copy.ptr);
    // Point a failure link at a deeper state: the walk could loop forever.
    const sparse = blob.sectionMut(SparseState, copy, h.sparse_off, h.num_states);
    const info = blob.sectionMut(StateInfo, copy, h.info_off, h.num_states);
    var deepest: u32 = 0;
    for (info, 0..) |s, i| {
        if (s.depth > info[deepest].depth) deepest = @intCast(i);
    }
    sparse[deepest].fail = deepest;
    try testing.expectError(error.Corrupt, AhoCorasick.load(copy));
    try testing.expectError(error.Truncated, AhoCorasick.load(copy[0 .. copy.len - 8]));
}
