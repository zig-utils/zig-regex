//! Flat, relocatable regex programs and an allocation-free matcher.
//!
//! A `Program` is a compiled pattern laid out in one contiguous byte blob:
//! little-endian, offsets instead of pointers, nothing that refers outside the
//! blob. It is immutable once built, so one program can be shared read-only by
//! any number of threads.
//!
//! Matching state lives in a `Scratch`: the lazy DFA's transition cache, the
//! NFA simulation's thread lists and the closure stacks. A scratch is sized
//! once from a program (or from the largest of several, see `Capacity`) and
//! then reused for every match on its thread; no match ever allocates.
//!
//! Programs cover the patterns the Thompson engine runs: everything except
//! backreferences, general lookaround, atomic groups with more than one
//! possible match length and Unicode property escapes, which need a
//! backtracking engine (`regex.bt` compiles them into a serialisable,
//! budgeted backtracking program). `Program.fromRegex` reports those with
//! `error.UnsupportedByProgram`, as it does for a regex the backtracker got
//! only to order captures, alternatives or lazy repeats, or to scope inline
//! modifiers. `Program.compile` compiles for spans: it drops capture groups
//! and keeps lazy repeats and repeated alternations (`(?:ab|cd)+`, `a.+?b`)
//! on the Thompson route, so such patterns still become programs; in byte
//! mode it also builds inline modifiers (`(?i)`, `(?s:..)`, `(?-i:..)`,
//! `(?m:..)`) into the automaton. ECMAScript mode is unsupported. Matching
//! reports spans only (no capture groups).
//!
//! Every program has a `MatchKind`, chosen when it is built and stored in it:
//!
//! - `leftmost_longest` (the default): the leftmost match, extended as far as
//!   possible, the semantics of `Regex.find` on the Thompson engines.
//! - `leftmost_first`: the leftmost match, ended where a backtracking engine
//!   that tries alternatives in order and honours greedy and lazy repeats
//!   would end it, as PCRE2, Perl and YARA do (`a|ab` matches `a`, `a+?`
//!   matches one `a`).
//!
//! Both kinds agree on whether a match exists and where the leftmost one
//! starts; they differ only in its end.
//!
//! `Program.bytes` is the serialised program and `Program.load` reads one
//! back from borrowed memory (an mmapped file, say) without allocating, after
//! validating it.
//!
//! How a search runs: a lazy DFA built in the scratch scans forwards for the
//! end of the leftmost match. Its states are priority-ordered lists of NFA
//! states, RE2-style: for leftmost-first, a thread that accepts drops every
//! lower-priority thread; for leftmost-longest, threads are grouped by where
//! they started and an accepting group drops every later-starting group. A
//! second lazy DFA over the reversed program then runs backwards from that end
//! to the match start. Both passes are linear in what they read, so `find`,
//! `count` and the iterator never restart a scan at each candidate start.
//! `isMatch` needs no end and runs one unordered DFA. While no thread is
//! alive, the forward scans skip to the next position a match can start at
//! with a byte search (see `Prefilter`), assertions or not.
//!
//! When the DFA would need more states (or key memory) than the scratch
//! holds, it is reset and the current call finishes on an NFA simulation over
//! the same program, so a pattern whose DFA explodes still matches, in time
//! linear in the input.

const std = @import("std");
const compiler = @import("compiler.zig");
const common = @import("common.zig");
const ast = @import("ast.zig");
const simd = @import("literals/simd.zig");
const Regex = @import("regex.zig").Regex;

/// A match: `input[start..end]`.
pub const Span = struct {
    start: usize,
    end: usize,
};

/// Which end a program reports for the leftmost match (see the module docs).
pub const MatchKind = enum(u1) {
    /// The longest match at the leftmost start (POSIX, `Regex.find`).
    leftmost_longest = 0,
    /// The match a backtracking engine would report (PCRE2, Perl, YARA).
    leftmost_first = 1,
};

/// Options for building a program.
pub const BuildOptions = struct {
    match_kind: MatchKind = .leftmost_longest,
};

pub const BuildError = error{
    /// The pattern needs the backtracking engine, or ECMAScript semantics.
    UnsupportedByProgram,
    /// More NFA states than a program can address.
    ProgramTooLarge,
    OutOfMemory,
};

pub const LoadError = error{
    /// Shorter than the header, or than the length the header records.
    Truncated,
    /// Not a program blob.
    BadMagic,
    /// A blob layout this build does not read (for example one written by an
    /// older release: rebuild it from its pattern).
    UnsupportedVersion,
    /// The bytes do not match the recorded CRC-32: the blob was corrupted.
    ChecksumMismatch,
    /// The blob is well formed on the outside but inconsistent inside.
    InvalidProgram,
};

pub const MatchError = error{
    /// The scratch was sized for smaller programs than this one.
    ScratchTooSmall,
    /// The search used up `Scratch.step_budget` before it could decide. This
    /// is never a "no match": the input was not fully examined.
    BudgetExceeded,
};

/// The magic bytes every program blob starts with.
pub const magic = "ZRXP";
/// The blob layout version this build writes and reads. Version 2 added the
/// match kind, the reversed program and the prefilter; version 1 blobs are
/// refused with `error.UnsupportedVersion`.
pub const format_version: u16 = 2;

/// The empty-width assertions a program can contain.
pub const Assertion = enum(u8) {
    start_line = 0,
    end_line = 1,
    start_text = 2,
    end_text = 3,
    word_boundary = 4,
    non_word_boundary = 5,

    fn fromAnchor(anchor: ast.AnchorType) Assertion {
        return switch (anchor) {
            .start_line => .start_line,
            .end_line => .end_line,
            .start_text => .start_text,
            .end_text => .end_text,
            .word_boundary => .word_boundary,
            .non_word_boundary => .non_word_boundary,
        };
    }

    /// The same assertion seen by a scan running backwards: start and end
    /// trade places, word boundaries are symmetric.
    fn reversed(self: Assertion) Assertion {
        return switch (self) {
            .start_line => .end_line,
            .end_line => .start_line,
            .start_text => .end_text,
            .end_text => .start_text,
            .word_boundary, .non_word_boundary => self,
        };
    }

    fn bit(self: Assertion) u8 {
        return @as(u8, 1) << @intCast(@backingInt(self));
    }
};

// ---------------------------------------------------------------------------
// Blob layout (version 2)
//
//   header (96 bytes)
//     0  magic "ZRXP"           4  version u16       6  header size u16
//     8  total length u32      12  program flags u32
//    16  state count u32       20  edge count u32   24  byte-set count u32
//    28  start state u32       32  byte-class count u32
//    36  states offset u32     40  edges offset u32 44  byte sets offset u32
//    48  class map offset u32  52  first-byte set offset u32 (0 when absent)
//    56  CRC-32 of the blob with this field zeroed
//    60  longest match in bytes u32 (0xFFFFFFFF when unbounded)
//    64  reversed edge count u32
//    68  reversed states offset u32
//    72  reversed edges offset u32
//    76  prefilter anchor offset u32 (0xFFFFFFFF when there is none)
//    80  prefilter anchor byte count u8, then up to 3 anchor bytes
//    84  second anchor (verifies the first's candidates): offset u8 (0xFF
//        when there is none), byte count u8, up to 3 bytes
//    89  reserved, zero (7 bytes)
//   states       8 bytes each: first edge u32, edge count (bits 0..30) with
//                the accepting flag in bit 31
//   edges        8 bytes each: target state u32, op u32 (kind in bits 0..7,
//                argument above: a byte-set index or an `Assertion`)
//   byte sets    32-byte bitmaps
//   class map    256 bytes: the byte class of every byte value
//   first bytes  optional 32-byte bitmap of the bytes a match can start with
//   reversed states  (state count + 1) records, as states: the program with
//                every edge turned around and its assertions mirrored. The
//                extra last state is its start, with an epsilon edge to every
//                accepting state; the forward start state accepts.
//   reversed edges   as edges
//
// Every section is 8-byte aligned relative to the blob start; integers are
// read with explicit little-endian loads, so the blob itself may sit at any
// address.

const header_size: usize = 96;
const state_record: usize = 8;
const edge_record: usize = 8;
const set_record: usize = 32;

const off_magic = 0;
const off_version = 4;
const off_header_size = 6;
const off_total = 8;
const off_flags = 12;
const off_state_count = 16;
const off_edge_count = 20;
const off_set_count = 24;
const off_start = 28;
const off_class_count = 32;
const off_states = 36;
const off_edges = 40;
const off_sets = 44;
const off_classes = 48;
const off_first = 52;
const off_checksum = 56;
const off_max_len = 60;
const off_rev_edge_count = 64;
const off_rev_states = 68;
const off_rev_edges = 72;
const off_anchor_offset = 76;
const off_anchor_len = 80;
const off_anchor_bytes = 81;
const off_anchor2_offset = 84;
const off_anchor2_len = 85;
const off_anchor2_bytes = 86;
const off_reserved = 89;
const no_anchor2: u8 = 0xFF;

const unbounded_len: u32 = 0xFFFF_FFFF;
const no_anchor: u32 = 0xFFFF_FFFF;
/// The furthest into a match the prefilter anchor may sit.
const max_anchor_offset: u32 = 15;

const accepting_bit: u32 = 1 << 31;

const edge_epsilon: u8 = 0;
const edge_bytes: u8 = 1;
const edge_assert: u8 = 2;

// Program flags.
const pf_multiline: u32 = 1 << 0;
const pf_assert_start: u32 = 1 << 1; // some `\A` or `^`
const pf_assert_word: u32 = 1 << 2; // some `\b` or `\B`
const pf_assert_line_start: u32 = 1 << 3; // multiline `^`
const pf_first_bytes: u32 = 1 << 4;
const pf_bytes_mode: u32 = 1 << 5;
const pf_case_insensitive: u32 = 1 << 6;
const pf_leftmost_first: u32 = 1 << 7;
const pf_assert_end: u32 = 1 << 8; // some `\z` or `$`
const pf_assert_line_end: u32 = 1 << 9; // multiline `$`
const pf_known: u32 = (1 << 10) - 1;

/// Most NFA states a program may hold. State ids, edge indices and byte-set
/// indices are u32; the cap keeps every size computation far from overflow.
pub const max_program_states: u32 = 1 << 24;

inline fn readU32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

inline fn writeU32(buf: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], value, .little);
}

inline fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

fn checksumOf(blob: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(blob[0..off_checksum]);
    crc.update(&[_]u8{ 0, 0, 0, 0 });
    crc.update(blob[off_checksum + 4 ..]);
    return crc.final();
}

// Look-behind context bits a DFA state carries (the context on entry). For a
// backwards scan "behind" is the byte after the position.
const ctx_start: u8 = 1;
const ctx_prev_word: u8 = 2;
const ctx_prev_nl: u8 = 4;

/// One direction of a program: its states and edges.
const Graph = struct {
    states: []const u8,
    edges: []const u8,

    inline fn edgeRange(self: Graph, state: u32) struct { first: u32, count: u32 } {
        const base = @as(usize, state) * state_record;
        return .{
            .first = readU32(self.states, base),
            .count = readU32(self.states, base + 4) & ~accepting_bit,
        };
    }

    inline fn isAccepting(self: Graph, state: u32) bool {
        return readU32(self.states, @as(usize, state) * state_record + 4) & accepting_bit != 0;
    }

    inline fn edgeTarget(self: Graph, edge: u32) u32 {
        return readU32(self.edges, @as(usize, edge) * edge_record);
    }

    inline fn edgeOp(self: Graph, edge: u32) u32 {
        return readU32(self.edges, @as(usize, edge) * edge_record + 4);
    }
};

/// How the forward scans skip to the next position a match can start at,
/// chosen when a program is viewed from the bytes it stores.
const Prefilter = union(enum) {
    /// Every match is unconstrained or can be empty: step every byte.
    none,
    /// Some byte of every match, `offset` bytes from its start, is one of
    /// `bytes[0..len]`: a vector search for it, then the first byte and a
    /// second anchor (when there is one, `len2 > 0`) checked.
    anchor: struct { offset: u32, bytes: [3]u8, len: u8, offset2: u8, bytes2: [3]u8, len2: u8 },
    /// Membership in the first-byte set by nibble lookups (shufti), exact
    /// when the set has at most 8 distinct high-nibble rows.
    shufti: struct { lo: simd.V16, hi: simd.V16 },
    /// A byte-at-a-time scan of the first-byte bitmap.
    table,
};

/// A compiled pattern in its flat form. The struct is a view over `blob`;
/// building a program allocates the blob, which `deinit` frees. A program
/// from `load` borrows the caller's bytes and has nothing to free.
pub const Program = struct {
    blob: []const u8,
    /// Whether `deinit` frees `blob` (false for `load`ed programs).
    owned: bool,
    flags: u32,
    state_count: u32,
    edge_count: u32,
    set_count: u32,
    start: u32,
    class_count: u32,
    fwd: Graph,
    /// The reversed program; its start state is `state_count`.
    rev: Graph,
    sets: []const u8,
    classes: *const [256]u8,
    first_bytes: ?*const [32]u8,
    prefilter: Prefilter,
    /// The longest match in bytes, or null when matches are unbounded.
    max_len: ?u32,
    checksum: u32,
    /// The look-behind context bits this program's assertions can observe,
    /// scanning forwards and backwards.
    ctx_mask: u8,
    rev_ctx_mask: u8,
    /// One byte of each byte class: every byte of a class behaves alike.
    class_rep: [256]u8,

    /// Compile `pattern` and flatten it into a leftmost-longest program (see
    /// `compileWithOptions`).
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags) !Program {
        return compileWithOptions(allocator, pattern, flags, .{});
    }

    /// Compile `pattern` and flatten it into a program. Programs report
    /// spans only, so groups are compiled as non-capturing (see
    /// `Regex.compileWithoutCaptures`): an alternation of capture groups,
    /// which `Regex` hands to the backtracker to order its captures, still
    /// becomes a program, and so do lazy repeats and repeated alternations,
    /// whose order a leftmost-first program honours.
    pub fn compileWithOptions(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags, options: BuildOptions) !Program {
        var re = try Regex.compileWithoutCaptures(allocator, pattern, flags);
        defer re.deinit();
        return fromRegexWithOptions(allocator, &re, options);
    }

    /// Flatten a compiled regex into a leftmost-longest program. The regex is
    /// not retained.
    pub fn fromRegex(allocator: std.mem.Allocator, re: *const Regex) BuildError!Program {
        return fromRegexWithOptions(allocator, re, .{});
    }

    /// Flatten a compiled regex into a program. The regex is not retained.
    pub fn fromRegexWithOptions(allocator: std.mem.Allocator, re: *const Regex, options: BuildOptions) BuildError!Program {
        const blob = try build(allocator, re, options);
        var program = view(blob);
        program.owned = true;
        return program;
    }

    /// Free a program built by `compile`, `fromRegex` or `dupe`. Does nothing
    /// for a program from `load`, whose bytes belong to the caller.
    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.blob);
        self.* = undefined;
    }

    /// The serialised program: write these bytes anywhere (a file, a
    /// database section) and `load` them later. They are position
    /// independent, little-endian, versioned and checksummed, and they keep
    /// the match kind.
    pub fn bytes(self: *const Program) []const u8 {
        return self.blob;
    }

    /// The match kind the program was built with.
    pub fn matchKind(self: *const Program) MatchKind {
        return if (self.flags & pf_leftmost_first != 0) .leftmost_first else .leftmost_longest;
    }

    /// A program over serialised bytes, without allocating or copying: the
    /// result borrows `blob` (for example an mmapped region), which must
    /// outlive it and stay unchanged. `blob` may extend past the program; the
    /// header records its length, and `bytes().len` reports it.
    ///
    /// Everything memory safety depends on is validated: header, section
    /// layout, every state's edge range, every edge's target and argument in
    /// both directions, and the byte-class map against each byte set and
    /// assertion. A CRC-32 over the whole program rejects accidental
    /// corruption. The blob may sit at any address: all reads are explicit
    /// little-endian loads.
    pub fn load(blob: []const u8) LoadError!Program {
        const program_bytes = try validate(blob);
        return view(program_bytes);
    }

    /// An owned copy of this program (for example of a `load`ed one).
    pub fn dupe(self: *const Program, allocator: std.mem.Allocator) error{OutOfMemory}!Program {
        var copy = view(try allocator.dupe(u8, self.blob));
        copy.owned = true;
        return copy;
    }

    /// The sizes a scratch needs to match this program. `states` counts the
    /// reversed program's extra start state.
    pub fn capacity(self: *const Program) Capacity {
        return .{ .states = self.state_count + 1, .classes = self.class_count };
    }

    /// Whether `pattern` matches anywhere in `input`.
    pub fn isMatch(self: *const Program, scratch: *Scratch, input: []const u8) MatchError!bool {
        try scratch.bind(self);
        scratch.steps = 0;
        const found = scratch.dfaEarliestEnd(self, input, 0) catch |err| switch (err) {
            error.DfaFull => {
                scratch.resetDfa();
                return (try scratch.nfaFind(self, input, 0, true)) != null;
            },
            error.BudgetExceeded => return error.BudgetExceeded,
        };
        return found != null;
    }

    /// The leftmost match in `input`, ended according to the match kind.
    pub fn find(self: *const Program, scratch: *Scratch, input: []const u8) MatchError!?Span {
        return self.findFrom(scratch, input, 0);
    }

    /// The leftmost match starting at or after `start`. Assertions still see
    /// the whole input, so `^` and `\b` at `start` look at `input[start - 1]`.
    pub fn findFrom(self: *const Program, scratch: *Scratch, input: []const u8, start: usize) MatchError!?Span {
        try scratch.bind(self);
        scratch.steps = 0;
        if (start > input.len) return null;
        return scratch.dfaFind(self, input, start) catch |err| switch (err) {
            error.DfaFull => {
                scratch.resetDfa();
                return scratch.nfaFind(self, input, start, false);
            },
            error.BudgetExceeded => return error.BudgetExceeded,
        };
    }

    /// Successive non-overlapping matches, as `Regex.findAll` reports them:
    /// after an empty match the next search starts one byte later.
    pub fn iterator(self: *const Program, scratch: *Scratch, input: []const u8) Iterator {
        return .{ .program = self, .scratch = scratch, .input = input };
    }

    /// Write every non-overlapping match into `out` and return how many there
    /// are. Fails with `error.NoSpaceLeft` rather than dropping matches when
    /// `out` is too short; `iterator` walks any number of matches.
    pub fn findAll(self: *const Program, scratch: *Scratch, input: []const u8, out: []Span) (MatchError || error{NoSpaceLeft})!usize {
        var it = self.iterator(scratch, input);
        var n: usize = 0;
        while (try it.next()) |m| {
            if (n == out.len) return error.NoSpaceLeft;
            out[n] = m;
            n += 1;
        }
        return n;
    }

    /// The number of non-overlapping matches.
    pub fn count(self: *const Program, scratch: *Scratch, input: []const u8) MatchError!usize {
        var it = self.iterator(scratch, input);
        var n: usize = 0;
        while (try it.next()) |_| n += 1;
        return n;
    }

    pub const Iterator = struct {
        program: *const Program,
        scratch: *Scratch,
        input: []const u8,
        pos: usize = 0,
        done: bool = false,

        pub fn next(self: *Iterator) MatchError!?Span {
            if (self.done or self.pos > self.input.len) return null;
            const m = (try self.program.findFrom(self.scratch, self.input, self.pos)) orelse {
                self.done = true;
                return null;
            };
            self.pos = if (m.end > m.start) m.end else m.end + 1;
            return m;
        }
    };

    // -- blob accessors ------------------------------------------------------

    inline fn setHas(self: *const Program, set: u32, b: u8) bool {
        const byte = self.sets[@as(usize, set) * set_record + (b >> 3)];
        return (byte >> @intCast(b & 7)) & 1 != 0;
    }

    inline fn hasPrefilter(self: *const Program) bool {
        return self.prefilter != .none;
    }

    /// The first position at or after `pos` where a match can start, or
    /// `input.len` when there is none. Only for programs with a prefilter.
    fn nextCandidate(self: *const Program, input: []const u8, pos: usize) usize {
        switch (self.prefilter) {
            .none => return pos,
            .anchor => |a| {
                const fb = self.first_bytes.?;
                var q = pos + a.offset;
                while (q < input.len) {
                    q = switch (a.len) {
                        1 => std.mem.indexOfScalarPos(u8, input, q, a.bytes[0]),
                        2 => indexOfAny(2, input, q, a.bytes[0..2].*),
                        else => indexOfAny(3, input, q, a.bytes),
                    } orelse return input.len;
                    const p = q - a.offset;
                    if ((a.offset == 0 or byteSetHas(fb, input[p])) and
                        (a.len2 == 0 or (p + a.offset2 < input.len and anyOf(a.bytes2[0..a.len2], input[p + a.offset2]))))
                        return p;
                    q += 1;
                }
                return input.len;
            },
            .shufti => |s| return shuftiScan(s.lo, s.hi, input, pos),
            .table => {
                const fb = self.first_bytes.?;
                var i = pos;
                while (i < input.len and !byteSetHas(fb, input[i])) i += 1;
                return i;
            },
        }
    }

    /// The look-behind context at `pos` for a forward scan.
    fn contextAt(self: *const Program, input: []const u8, pos: usize) u8 {
        var ctx: u8 = 0;
        if (pos == 0) {
            ctx |= ctx_start;
        } else {
            const prev = input[pos - 1];
            if (isWordByte(prev)) ctx |= ctx_prev_word;
            if (prev == '\n') ctx |= ctx_prev_nl;
        }
        return ctx & self.ctx_mask;
    }

    /// The context at `pos` for a backward scan: what lies after it.
    fn reverseContextAt(self: *const Program, input: []const u8, pos: usize) u8 {
        var ctx: u8 = 0;
        if (pos == input.len) {
            ctx |= ctx_start;
        } else {
            const next = input[pos];
            if (isWordByte(next)) ctx |= ctx_prev_word;
            if (next == '\n') ctx |= ctx_prev_nl;
        }
        return ctx & self.rev_ctx_mask;
    }

    /// The context after consuming byte `b`, restricted to `mask`.
    fn contextAfter(b: u8, mask: u8) u8 {
        var ctx: u8 = 0;
        if (isWordByte(b)) ctx |= ctx_prev_word;
        if (b == '\n') ctx |= ctx_prev_nl;
        return ctx & mask;
    }

    /// The assertions that hold between context `ctx` and the symbol about to
    /// be read: byte class `sym`, or end of input when `sym == class_count`.
    /// The same rule serves both directions, since the reversed program's
    /// assertions are mirrored.
    fn assertionsHolding(self: *const Program, ctx: u8, sym: u32) u8 {
        const multiline = self.flags & pf_multiline != 0;
        const eof = sym == self.class_count;
        const next = if (eof) 0 else self.class_rep[sym];
        var held: u8 = 0;
        if (ctx & ctx_start != 0) held |= Assertion.start_text.bit() | Assertion.start_line.bit();
        if (multiline and ctx & ctx_prev_nl != 0) held |= Assertion.start_line.bit();
        if (eof) {
            held |= Assertion.end_text.bit() | Assertion.end_line.bit();
        } else if (multiline and next == '\n') {
            held |= Assertion.end_line.bit();
        }
        const prev_word = ctx & ctx_prev_word != 0;
        const next_word = !eof and isWordByte(next);
        held |= if (prev_word != next_word) Assertion.word_boundary.bit() else Assertion.non_word_boundary.bit();
        return held;
    }

    /// Whether `assertion` holds at `pos`, read straight from the input.
    fn assertionAt(self: *const Program, assertion: Assertion, input: []const u8, pos: usize) bool {
        const multiline = self.flags & pf_multiline != 0;
        return switch (assertion) {
            .start_text => pos == 0,
            .end_text => pos == input.len,
            .start_line => pos == 0 or (multiline and input[pos - 1] == '\n'),
            .end_line => pos == input.len or (multiline and input[pos] == '\n'),
            .word_boundary, .non_word_boundary => blk: {
                const before = pos > 0 and isWordByte(input[pos - 1]);
                const after = pos < input.len and isWordByte(input[pos]);
                break :blk (before != after) == (assertion == .word_boundary);
            },
        };
    }
};

inline fn anyOf(set: []const u8, b: u8) bool {
    for (set) |c| if (c == b) return true;
    return false;
}

/// The first index at or after `pos` whose byte is one of `needles`.
fn indexOfAny(comptime n: usize, hay: []const u8, pos: usize, needles: [n]u8) ?usize {
    const L = comptime std.simd.suggestVectorLength(u8) orelse 16;
    const V = @Vector(L, u8);
    var i = pos;
    while (i + L <= hay.len) : (i += L) {
        const chunk: V = hay[i..][0..L].*;
        var hit = chunk == @as(V, @splat(needles[0]));
        inline for (needles[1..]) |b| hit = hit | (chunk == @as(V, @splat(b)));
        const mask: @Int(.unsigned, L) = @bitCast(hit);
        if (mask != 0) return i + @ctz(mask);
    }
    while (i < hay.len) : (i += 1) {
        inline for (needles) |b| if (hay[i] == b) return i;
    }
    return null;
}

/// The first index at or after `pos` whose byte passes the shufti test
/// (`lo[b & 15] & hi[b >> 4] != 0`), or `hay.len`.
fn shuftiScan(lo: simd.V16, hi: simd.V16, hay: []const u8, pos: usize) usize {
    const lo_t: [16]u8 = lo;
    const hi_t: [16]u8 = hi;
    var i = pos;
    if (simd.has_shuffle) {
        const fifteen: simd.V16 = @splat(15);
        const four: @Vector(16, u3) = @splat(4);
        while (i + 16 <= hay.len) : (i += 16) {
            const chunk: simd.V16 = hay[i..][0..16].*;
            const l = simd.lookup16(lo, chunk & fifteen);
            const h = simd.lookup16(hi, chunk >> four);
            const mask = simd.nonzeroMask(16, l & h);
            if (mask != 0) return i + @ctz(mask);
        }
    }
    while (i < hay.len) : (i += 1) {
        const b = hay[i];
        if (lo_t[b & 15] & hi_t[b >> 4] != 0) return i;
    }
    return hay.len;
}

/// Approximate relative frequency of each byte in mixed text, HTTP and
/// executable data, used only to rank prefilter anchors.
fn byteWeight(b: u8) u32 {
    return switch (b) {
        0x00 => 120,
        0xff => 30,
        ' ' => 80,
        'e' => 50,
        't', 'a', 'o', 'i', 'n', 's', 'r' => 32,
        'h', 'l', 'd', 'c', 'u' => 20,
        'm', 'f', 'p', 'g', 'w', 'y', 'b' => 12,
        'v', 'k' => 6,
        'x', 'j', 'q', 'z' => 2,
        'A'...'Z' => 6,
        '0'...'9' => 10,
        '\n', '\r', '\t' => 12,
        '.', ',', '/', '=', '&', '-', '_', ':', '%', '"', '\'', '(', ')', ';', '<', '>' => 6,
        0x01...0x08, 0x90, 0xcc, 0x80 => 8,
        0x7f...0x7f => 2,
        else => if (b < 0x20) 3 else if (b < 0x80) 3 else 2,
    };
}

/// Read the header of a blob this module built (or validated) and return the
/// program view.
fn view(blob: []const u8) Program {
    const flags = readU32(blob, off_flags);
    const state_count = readU32(blob, off_state_count);
    const edge_count = readU32(blob, off_edge_count);
    const set_count = readU32(blob, off_set_count);
    const rev_edge_count = readU32(blob, off_rev_edge_count);
    const sets_off = readU32(blob, off_sets);
    const classes_off = readU32(blob, off_classes);
    const first_off = readU32(blob, off_first);
    var program = Program{
        .blob = blob,
        .owned = false,
        .flags = flags,
        .state_count = state_count,
        .edge_count = edge_count,
        .set_count = set_count,
        .start = readU32(blob, off_start),
        .class_count = readU32(blob, off_class_count),
        .fwd = .{
            .states = blob[readU32(blob, off_states)..][0 .. @as(usize, state_count) * state_record],
            .edges = blob[readU32(blob, off_edges)..][0 .. @as(usize, edge_count) * edge_record],
        },
        .rev = .{
            .states = blob[readU32(blob, off_rev_states)..][0 .. (@as(usize, state_count) + 1) * state_record],
            .edges = blob[readU32(blob, off_rev_edges)..][0 .. @as(usize, rev_edge_count) * edge_record],
        },
        .sets = blob[sets_off..][0 .. @as(usize, set_count) * set_record],
        .classes = blob[classes_off..][0..256],
        .first_bytes = if (flags & pf_first_bytes != 0) blob[first_off..][0..32] else null,
        .prefilter = .none,
        .max_len = if (readU32(blob, off_max_len) == unbounded_len) null else readU32(blob, off_max_len),
        .checksum = readU32(blob, off_checksum),
        .ctx_mask = 0,
        .rev_ctx_mask = 0,
        .class_rep = undefined,
    };
    if (flags & pf_assert_start != 0) program.ctx_mask |= ctx_start;
    if (flags & pf_assert_word != 0) program.ctx_mask |= ctx_prev_word;
    if (flags & pf_assert_line_start != 0) program.ctx_mask |= ctx_prev_nl;
    if (flags & pf_assert_end != 0) program.rev_ctx_mask |= ctx_start;
    if (flags & pf_assert_word != 0) program.rev_ctx_mask |= ctx_prev_word;
    if (flags & pf_assert_line_end != 0) program.rev_ctx_mask |= ctx_prev_nl;
    var b: usize = 256;
    while (b > 0) {
        b -= 1;
        program.class_rep[program.classes[b]] = @intCast(b);
    }
    program.prefilter = choosePrefilter(blob, program.first_bytes);
    return program;
}

/// Pick the forward scans' skip strategy from what the blob stores.
fn choosePrefilter(blob: []const u8, first_bytes: ?*const [32]u8) Prefilter {
    const fb = first_bytes orelse return .none;
    const anchor_offset = readU32(blob, off_anchor_offset);
    if (anchor_offset != no_anchor) {
        var a: @FieldType(Prefilter, "anchor") = .{
            .offset = anchor_offset,
            .bytes = undefined,
            .len = blob[off_anchor_len],
            .offset2 = blob[off_anchor2_offset],
            .bytes2 = undefined,
            .len2 = if (blob[off_anchor2_offset] == no_anchor2) 0 else blob[off_anchor2_len],
        };
        @memcpy(&a.bytes, blob[off_anchor_bytes..][0..3]);
        @memcpy(&a.bytes2, blob[off_anchor2_bytes..][0..3]);
        return .{ .anchor = a };
    }
    // Without a selective anchor, skipping pays only while candidates are
    // rare: past about one byte in five, stepping the DFA is as fast.
    var weight: u32 = 0;
    var total: u32 = 0;
    for (0..256) |i| {
        total += byteWeight(@intCast(i));
        if (byteSetHas(fb, @intCast(i))) weight += byteWeight(@intCast(i));
    }
    if (weight * 5 > total) return .none;
    // Shufti: one bit per distinct row of low nibbles, at most 8 rows.
    var rows: [8]u16 = undefined;
    var row_count: usize = 0;
    var lo: [16]u8 = @splat(0);
    var hi: [16]u8 = @splat(0);
    for (0..16) |h| {
        var row: u16 = 0;
        for (0..16) |l| {
            if (byteSetHas(fb, @intCast(h * 16 + l))) row |= @as(u16, 1) << @intCast(l);
        }
        if (row == 0) continue;
        const slot = for (rows[0..row_count], 0..) |r, k| {
            if (r == row) break k;
        } else blk: {
            if (row_count == rows.len) return .table;
            rows[row_count] = row;
            row_count += 1;
            break :blk row_count - 1;
        };
        const bit = @as(u8, 1) << @intCast(slot);
        hi[h] |= bit;
        for (0..16) |l| {
            if (row & (@as(u16, 1) << @intCast(l)) != 0) lo[l] |= bit;
        }
    }
    if (!simd.has_shuffle) return .table;
    return .{ .shufti = .{ .lo = lo, .hi = hi } };
}

/// Check a serialised program and return exactly its bytes. See `load`.
fn validate(input: []const u8) LoadError![]const u8 {
    if (input.len < 8) return error.Truncated;
    if (!std.mem.eql(u8, input[off_magic..][0..4], magic)) return error.BadMagic;
    if (std.mem.readInt(u16, input[off_version..][0..2], .little) != format_version) return error.UnsupportedVersion;
    if (input.len < header_size) return error.Truncated;
    if (std.mem.readInt(u16, input[off_header_size..][0..2], .little) != header_size) return error.InvalidProgram;
    const total = readU32(input, off_total);
    if (total < header_size) return error.InvalidProgram;
    if (total > input.len) return error.Truncated;
    const blob = input[0..total];
    if (readU32(blob, off_checksum) != checksumOf(blob)) return error.ChecksumMismatch;

    const flags = readU32(blob, off_flags);
    if (flags & ~pf_known != 0) return error.InvalidProgram;
    const state_count: u64 = readU32(blob, off_state_count);
    const edge_count: u64 = readU32(blob, off_edge_count);
    const set_count: u64 = readU32(blob, off_set_count);
    const rev_edge_count: u64 = readU32(blob, off_rev_edge_count);
    const start = readU32(blob, off_start);
    const class_count = readU32(blob, off_class_count);
    if (state_count == 0 or state_count > max_program_states) return error.InvalidProgram;
    if (start >= state_count) return error.InvalidProgram;
    if (class_count == 0 or class_count > 256) return error.InvalidProgram;
    if (!std.mem.allEqual(u8, blob[off_reserved..header_size], 0)) return error.InvalidProgram;

    // The sections sit back to back in a fixed order; anything else (gaps,
    // overlaps, a section past the end) is rejected.
    const states_off: u64 = header_size;
    const edges_off = states_off + state_count * state_record;
    const sets_off = edges_off + edge_count * edge_record;
    const classes_off = sets_off + set_count * set_record;
    const has_first = flags & pf_first_bytes != 0;
    const first_off: u64 = if (has_first) classes_off + 256 else 0;
    const rev_states_off = classes_off + 256 + @as(u64, if (has_first) set_record else 0);
    const rev_edges_off = rev_states_off + (state_count + 1) * state_record;
    const expected_total = rev_edges_off + rev_edge_count * edge_record;
    if (readU32(blob, off_states) != states_off or readU32(blob, off_edges) != edges_off or
        readU32(blob, off_sets) != sets_off or readU32(blob, off_classes) != classes_off or
        readU32(blob, off_first) != first_off or readU32(blob, off_rev_states) != rev_states_off or
        readU32(blob, off_rev_edges) != rev_edges_off or total != expected_total)
        return error.InvalidProgram;

    // The prefilter anchor: offset and byte count in range, unused bytes zero,
    // and present only with a first-byte set (which verifies its candidates).
    const anchor_offset = readU32(blob, off_anchor_offset);
    const anchor_len = blob[off_anchor_len];
    const anchor2_offset = blob[off_anchor2_offset];
    const anchor2_len = blob[off_anchor2_len];
    if (anchor_offset == no_anchor) {
        if (anchor_len != 0 or !std.mem.allEqual(u8, blob[off_anchor_bytes..][0..3], 0)) return error.InvalidProgram;
    } else {
        if (!has_first or anchor_offset > max_anchor_offset or anchor_len == 0 or anchor_len > 3) return error.InvalidProgram;
        if (!std.mem.allEqual(u8, blob[off_anchor_bytes + anchor_len .. off_anchor_bytes + 3], 0)) return error.InvalidProgram;
    }
    if (anchor2_offset == no_anchor2) {
        if (anchor2_len != 0 or !std.mem.allEqual(u8, blob[off_anchor2_bytes..][0..3], 0)) return error.InvalidProgram;
    } else {
        if (anchor_offset == no_anchor or anchor2_offset > max_anchor_offset or anchor2_len == 0 or anchor2_len > 3) return error.InvalidProgram;
        if (!std.mem.allEqual(u8, blob[off_anchor2_bytes + anchor2_len .. off_anchor2_bytes + 3], 0)) return error.InvalidProgram;
    }

    const sets = blob[@intCast(sets_off)..@intCast(classes_off)];
    const classes = blob[@intCast(classes_off)..][0..256];

    // Both directions: edge ranges, then every edge's target, kind and
    // argument, and the assertion flags they imply.
    const fwd = Graph{
        .states = blob[@intCast(states_off)..@intCast(edges_off)],
        .edges = blob[@intCast(edges_off)..@intCast(sets_off)],
    };
    const rev = Graph{
        .states = blob[@intCast(rev_states_off)..@intCast(rev_edges_off)],
        .edges = blob[@intCast(rev_edges_off)..@intCast(expected_total)],
    };
    const fwd_implied = try validateGraph(fwd, state_count, edge_count, set_count, flags, false);
    const rev_implied = try validateGraph(rev, state_count + 1, rev_edge_count, set_count, flags, true);
    const assert_flags = pf_assert_start | pf_assert_word | pf_assert_line_start | pf_assert_end | pf_assert_line_end;
    if (flags & assert_flags != fwd_implied or rev_implied != fwd_implied) return error.InvalidProgram;

    // Byte classes: every class used, and every byte of a class alike for
    // every byte set and every assertion the program observes, which is what
    // lets the DFA test one representative byte per class.
    var rep: [256]u16 = @splat(0xFFFF);
    for (classes, 0..) |class, b| {
        if (class >= class_count) return error.InvalidProgram;
        if (rep[class] == 0xFFFF) rep[class] = @intCast(b);
    }
    for (rep[0..class_count]) |r| if (r == 0xFFFF) return error.InvalidProgram;
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        const r: u8 = @intCast(rep[classes[b]]);
        if (flags & pf_assert_word != 0 and isWordByte(@intCast(b)) != isWordByte(r)) return error.InvalidProgram;
        if (flags & pf_multiline != 0 and (b == '\n') != (r == '\n')) return error.InvalidProgram;
        var set: u64 = 0;
        while (set < set_count) : (set += 1) {
            const row = sets[@intCast(set * set_record)..][0..set_record];
            if (byteSetHas(row, @intCast(b)) != byteSetHas(row, r)) return error.InvalidProgram;
        }
    }
    return blob;
}

/// Check one direction's states and edges; returns the assertion flags its
/// edges imply, in forward terms (a reversed edge is mirrored back).
fn validateGraph(g: Graph, state_count: u64, edge_count: u64, set_count: u64, flags: u32, reversed: bool) LoadError!u32 {
    var i: u64 = 0;
    while (i < state_count) : (i += 1) {
        const first: u64 = readU32(g.states, @intCast(i * state_record));
        const count: u64 = readU32(g.states, @intCast(i * state_record + 4)) & ~accepting_bit;
        if (first + count > edge_count) return error.InvalidProgram;
    }
    var implied: u32 = 0;
    i = 0;
    while (i < edge_count) : (i += 1) {
        const target = readU32(g.edges, @intCast(i * edge_record));
        const op = readU32(g.edges, @intCast(i * edge_record + 4));
        if (target >= state_count) return error.InvalidProgram;
        const arg = op >> 8;
        switch (@as(u8, @truncate(op))) {
            edge_epsilon => if (arg != 0) return error.InvalidProgram,
            edge_bytes => if (arg >= set_count) return error.InvalidProgram,
            edge_assert => {
                if (arg > @backingInt(Assertion.non_word_boundary)) return error.InvalidProgram;
                var assertion: Assertion = @fromBackingInt(@intCast(arg));
                if (reversed) assertion = assertion.reversed();
                implied |= assertionFlags(assertion, flags & pf_multiline != 0);
            },
            else => return error.InvalidProgram,
        }
    }
    return implied;
}

/// The program flags an assertion edge implies.
fn assertionFlags(assertion: Assertion, multiline: bool) u32 {
    return switch (assertion) {
        .start_text => pf_assert_start,
        .start_line => pf_assert_start | if (multiline) pf_assert_line_start else 0,
        .end_text => pf_assert_end,
        .end_line => pf_assert_end | if (multiline) pf_assert_line_end else 0,
        .word_boundary, .non_word_boundary => pf_assert_word,
    };
}

// ---------------------------------------------------------------------------
// Building

const ByteSet = [32]u8;

fn byteSetAdd(set: *ByteSet, b: u8) void {
    set[b >> 3] |= @as(u8, 1) << @intCast(b & 7);
}

fn byteSetHas(set: *const ByteSet, b: u8) bool {
    return (set[b >> 3] >> @intCast(b & 7)) & 1 != 0;
}

/// The bytes a consuming NFA transition accepts, with the matching-time flags
/// (case folding, `dot_all`) applied exactly as the NFA VM applies them.
fn transitionBytes(t: compiler.Transition, flags: common.CompileFlags) ByteSet {
    var set: ByteSet = @splat(0);
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        const c: u8 = @intCast(b);
        const hit = switch (t.transition_type) {
            .char => if (flags.case_insensitive)
                std.ascii.toLower(t.data.char) == std.ascii.toLower(c)
            else
                t.data.char == c,
            .char_class => if (flags.case_insensitive)
                t.data.char_class.matchesCI(c)
            else
                t.data.char_class.matches(c),
            .any => flags.dot_all or c != '\n',
            .epsilon, .anchor, .literal_assertion => unreachable,
        };
        if (hit) byteSetAdd(&set, c);
    }
    return set;
}

fn build(allocator: std.mem.Allocator, re: *const Regex, options: BuildOptions) BuildError![]u8 {
    if (re.engine_type != .thompson_nfa or re.flags.ecmascript or re.nfa.has_literal_assertions)
        return error.UnsupportedByProgram;
    const nfa = &re.nfa;
    const n = nfa.states.items.len;
    if (n == 0 or n >= max_program_states) return error.ProgramTooLarge;

    var sets: std.ArrayList(ByteSet) = .empty;
    defer sets.deinit(allocator);
    var set_ids = std.AutoHashMap(ByteSet, u32).init(allocator);
    defer set_ids.deinit();
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(allocator);
    var states = try allocator.alloc([2]u32, n);
    defer allocator.free(states);

    var flags: u32 = 0;
    if (re.flags.multiline) flags |= pf_multiline;
    if (re.flags.bytes) flags |= pf_bytes_mode;
    if (re.flags.case_insensitive) flags |= pf_case_insensitive;
    if (options.match_kind == .leftmost_first) flags |= pf_leftmost_first;

    for (nfa.states.items, 0..) |state, i| {
        const first = edges.items.len;
        for (state.transitions.items) |t| {
            if (t.to >= n) return error.UnsupportedByProgram;
            const to: u32 = @intCast(t.to);
            switch (t.transition_type) {
                .epsilon => try edges.append(allocator, .{ to, edge_epsilon }),
                .anchor => {
                    const assertion = Assertion.fromAnchor(t.data.anchor);
                    flags |= assertionFlags(assertion, re.flags.multiline);
                    try edges.append(allocator, .{ to, edge_assert | (@as(u32, @backingInt(assertion)) << 8) });
                },
                .char, .char_class, .any => {
                    const set = transitionBytes(t, re.flags);
                    const entry = try set_ids.getOrPut(set);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = @intCast(sets.items.len);
                        try sets.append(allocator, set);
                    }
                    try edges.append(allocator, .{ to, edge_bytes | (entry.value_ptr.* << 8) });
                },
                .literal_assertion => return error.UnsupportedByProgram,
            }
        }
        const edge_count = edges.items.len - first;
        if (edges.items.len >= max_program_states * 16) return error.ProgramTooLarge;
        states[i] = .{ @intCast(first), @as(u32, @intCast(edge_count)) | (if (state.is_accepting) accepting_bit else 0) };
    }

    // The reversed program: every edge turned around, assertions mirrored,
    // and a new start state (index n) leading to every accepting state.
    var accepting: usize = 0;
    for (states) |s| accepting += @intFromBool(s[1] & accepting_bit != 0);
    const rev_edge_count = edges.items.len + accepting;
    const rev_states = try allocator.alloc([2]u32, n + 1);
    defer allocator.free(rev_states);
    const rev_edges = try allocator.alloc([2]u32, rev_edge_count);
    defer allocator.free(rev_edges);
    {
        // Count each state's incoming edges, lay the ranges out, then fill.
        const fill = try allocator.alloc(u32, n + 1);
        defer allocator.free(fill);
        @memset(fill, 0);
        for (edges.items) |e| fill[e[0]] += 1;
        fill[n] = @intCast(accepting);
        var at: u32 = 0;
        for (rev_states, fill, 0..) |*rs, *f, i| {
            const accept_here: u32 = if (i == nfa.start_state) accepting_bit else 0;
            rs.* = .{ at, f.* | accept_here };
            at += f.*;
            f.* = rs[0];
        }
        for (states, 0..) |s, from| {
            const first = s[0];
            const count = s[1] & ~accepting_bit;
            for (edges.items[first .. first + count]) |e| {
                var op = e[1];
                if (@as(u8, @truncate(op)) == edge_assert) {
                    const a: Assertion = @fromBackingInt(@intCast(op >> 8));
                    op = edge_assert | (@as(u32, @backingInt(a.reversed())) << 8);
                }
                rev_edges[fill[e[0]]] = .{ @intCast(from), op };
                fill[e[0]] += 1;
            }
            if (s[1] & accepting_bit != 0) {
                rev_edges[fill[n]] = .{ @intCast(from), edge_epsilon };
                fill[n] += 1;
            }
        }
    }

    // Byte classes: bytes no byte set, and no assertion, can tell apart.
    var class_of: [256]u8 = @splat(0);
    var class_count: u32 = 1;
    for (sets.items) |*set| class_count = refineClasses(&class_of, set);
    if (flags & pf_assert_word != 0) {
        var word: ByteSet = @splat(0);
        var b: usize = 0;
        while (b < 256) : (b += 1) if (isWordByte(@intCast(b))) byteSetAdd(&word, @intCast(b));
        class_count = refineClasses(&class_of, &word);
    }
    if (flags & pf_multiline != 0) {
        var newline: ByteSet = @splat(0);
        byteSetAdd(&newline, '\n');
        class_count = refineClasses(&class_of, &newline);
    }

    const start: u32 = @intCast(nfa.start_state);
    const first_bytes = try firstBytes(allocator, start, sets.items, edges.items, states);
    const max_len = try longestMatch(allocator, start, edges.items, states);
    const anchors = if (first_bytes != null) try chooseAnchors(allocator, start, sets.items, edges.items, states) else Anchors{};
    if (first_bytes != null) flags |= pf_first_bytes;

    const states_off = header_size;
    const edges_off = states_off + n * state_record;
    const sets_off = edges_off + edges.items.len * edge_record;
    const classes_off = sets_off + sets.items.len * set_record;
    const first_off = classes_off + 256;
    const rev_states_off = first_off + if (first_bytes != null) set_record else 0;
    const rev_edges_off = rev_states_off + (n + 1) * state_record;
    const total = rev_edges_off + rev_edge_count * edge_record;
    if (total > std.math.maxInt(u32)) return error.ProgramTooLarge;

    const blob = try allocator.alloc(u8, total);
    errdefer allocator.free(blob);
    @memset(blob, 0);
    @memcpy(blob[off_magic..][0..4], magic);
    std.mem.writeInt(u16, blob[off_version..][0..2], format_version, .little);
    std.mem.writeInt(u16, blob[off_header_size..][0..2], header_size, .little);
    writeU32(blob, off_total, @intCast(total));
    writeU32(blob, off_flags, flags);
    writeU32(blob, off_state_count, @intCast(n));
    writeU32(blob, off_edge_count, @intCast(edges.items.len));
    writeU32(blob, off_set_count, @intCast(sets.items.len));
    writeU32(blob, off_start, start);
    writeU32(blob, off_class_count, class_count);
    writeU32(blob, off_states, @intCast(states_off));
    writeU32(blob, off_edges, @intCast(edges_off));
    writeU32(blob, off_sets, @intCast(sets_off));
    writeU32(blob, off_classes, @intCast(classes_off));
    writeU32(blob, off_first, if (first_bytes != null) @intCast(first_off) else 0);
    writeU32(blob, off_max_len, max_len orelse unbounded_len);
    writeU32(blob, off_rev_edge_count, @intCast(rev_edge_count));
    writeU32(blob, off_rev_states, @intCast(rev_states_off));
    writeU32(blob, off_rev_edges, @intCast(rev_edges_off));
    if (anchors.first) |a| {
        writeU32(blob, off_anchor_offset, a.offset);
        blob[off_anchor_len] = a.len;
        @memcpy(blob[off_anchor_bytes..][0..3], &a.bytes);
    } else {
        writeU32(blob, off_anchor_offset, no_anchor);
    }
    if (anchors.second) |a| {
        blob[off_anchor2_offset] = @intCast(a.offset);
        blob[off_anchor2_len] = a.len;
        @memcpy(blob[off_anchor2_bytes..][0..3], &a.bytes);
    } else {
        blob[off_anchor2_offset] = no_anchor2;
    }
    for (states, 0..) |s, i| {
        writeU32(blob, states_off + i * state_record, s[0]);
        writeU32(blob, states_off + i * state_record + 4, s[1]);
    }
    for (edges.items, 0..) |e, i| {
        writeU32(blob, edges_off + i * edge_record, e[0]);
        writeU32(blob, edges_off + i * edge_record + 4, e[1]);
    }
    for (sets.items, 0..) |*set, i| @memcpy(blob[sets_off + i * set_record ..][0..set_record], set);
    @memcpy(blob[classes_off..][0..256], &class_of);
    if (first_bytes) |fb| @memcpy(blob[first_off..][0..set_record], &fb);
    for (rev_states, 0..) |s, i| {
        writeU32(blob, rev_states_off + i * state_record, s[0]);
        writeU32(blob, rev_states_off + i * state_record + 4, s[1]);
    }
    for (rev_edges, 0..) |e, i| {
        writeU32(blob, rev_edges_off + i * edge_record, e[0]);
        writeU32(blob, rev_edges_off + i * edge_record + 4, e[1]);
    }
    writeU32(blob, off_checksum, checksumOf(blob));
    return blob;
}

/// Split every byte class by membership in `set`; returns the class count.
/// Class ids are numbered in order of their smallest byte.
fn refineClasses(class_of: *[256]u8, set: *const ByteSet) u32 {
    var remap: [512]u16 = @splat(0xFFFF);
    var next: u16 = 0;
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        const key = @as(usize, class_of[b]) * 2 + @intFromBool(byteSetHas(set, @intCast(b)));
        if (remap[key] == 0xFFFF) {
            remap[key] = next;
            next += 1;
        }
        class_of[b] = @intCast(remap[key]);
    }
    return next;
}

/// The most bytes any match can consume, or null when a cycle through a
/// consuming edge makes matches unbounded. Only states reachable from the
/// start count; the longest path is found by a depth-first walk that also
/// detects cycles.
fn longestMatch(allocator: std.mem.Allocator, start: u32, edges: []const [2]u32, states: []const [2]u32) !?u32 {
    const Mark = enum(u8) { unvisited, active, done };
    const marks = try allocator.alloc(Mark, states.len);
    defer allocator.free(marks);
    @memset(marks, .unvisited);
    const best = try allocator.alloc(u32, states.len);
    defer allocator.free(best);
    @memset(best, 0);
    const Frame = struct { state: u32, next_edge: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .state = start, .next_edge = states[start][0] });
    marks[start] = .active;
    while (stack.items.len > 0) {
        const frame = &stack.items[stack.items.len - 1];
        const first = states[frame.state][0];
        const end = first + (states[frame.state][1] & ~accepting_bit);
        if (frame.next_edge == end) {
            // Every successor is finished: the longest path from here is
            // the best over its edges.
            var longest: u32 = 0;
            for (edges[first..end]) |edge| {
                const step: u32 = @intFromBool(@as(u8, @truncate(edge[1])) == edge_bytes);
                const total = @as(u64, best[edge[0]]) + step;
                if (total >= unbounded_len) return null;
                longest = @max(longest, @as(u32, @intCast(total)));
            }
            best[frame.state] = longest;
            marks[frame.state] = .done;
            _ = stack.pop();
            continue;
        }
        const target = edges[frame.next_edge][0];
        frame.next_edge += 1;
        switch (marks[target]) {
            .done => {},
            // A cycle. Epsilon-only cycles do not lengthen a match, but
            // telling them apart costs more than this bound is worth.
            .active => return null,
            .unvisited => {
                marks[target] = .active;
                try stack.append(allocator, .{ .state = target, .next_edge = states[target][0] });
            },
        }
    }
    return best[start];
}

/// The bytes a non-empty match can start with, or null when a match can be
/// empty or start with any byte. Assertions are taken to hold, which only
/// makes the set larger.
fn firstBytes(allocator: std.mem.Allocator, start: u32, sets: []const ByteSet, edges: []const [2]u32, states: []const [2]u32) !?ByteSet {
    const visited = try allocator.alloc(bool, states.len);
    defer allocator.free(visited);
    @memset(visited, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, start);
    visited[start] = true;
    var result: ByteSet = @splat(0);
    while (stack.pop()) |state| {
        if (states[state][1] & accepting_bit != 0) return null;
        const first = states[state][0];
        const count = states[state][1] & ~accepting_bit;
        for (edges[first .. first + count]) |edge| {
            switch (@as(u8, @truncate(edge[1]))) {
                edge_bytes => {
                    for (&result, sets[edge[1] >> 8]) |*r, b| r.* |= b;
                },
                else => if (!visited[edge[0]]) {
                    visited[edge[0]] = true;
                    try stack.append(allocator, edge[0]);
                },
            }
        }
    }
    if (std.mem.allEqual(u8, &result, 0xFF)) return null;
    return result;
}

const Anchor = struct { offset: u32, bytes: [3]u8, len: u8 };
const Anchors = struct { first: ?Anchor = null, second: ?Anchor = null };

/// The most selective small byte set at a fixed offset into every match: for
/// offsets 0 to `max_anchor_offset`, the bytes any match can have there
/// (layer by layer through the NFA, assertions taken to hold, which only
/// makes each set larger), stopping where a match could already have ended.
/// The set of at most 3 bytes with the lowest `byteWeight` total is the
/// anchor the prefilter searches for; the runner-up verifies its candidates.
fn chooseAnchors(allocator: std.mem.Allocator, start: u32, sets: []const ByteSet, edges: []const [2]u32, states: []const [2]u32) !Anchors {
    var layer = try std.DynamicBitSetUnmanaged.initEmpty(allocator, states.len);
    defer layer.deinit(allocator);
    var next = try std.DynamicBitSetUnmanaged.initEmpty(allocator, states.len);
    defer next.deinit(allocator);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(allocator);

    layer.set(start);
    var best: Anchors = .{};
    var best_weight: u32 = std.math.maxInt(u32);
    var second_weight: u32 = std.math.maxInt(u32);
    var offset: u32 = 0;
    while (offset <= max_anchor_offset) : (offset += 1) {
        // Close the layer over epsilon and assertion edges.
        stack.clearRetainingCapacity();
        var it = layer.iterator(.{});
        while (it.next()) |s| try stack.append(allocator, @intCast(s));
        while (stack.pop()) |s| {
            const first = states[s][0];
            const count = states[s][1] & ~accepting_bit;
            for (edges[first .. first + count]) |e| {
                if (@as(u8, @truncate(e[1])) == edge_bytes or layer.isSet(e[0])) continue;
                layer.set(e[0]);
                try stack.append(allocator, e[0]);
            }
        }
        // The bytes at this offset, and the states after them.
        var here: ByteSet = @splat(0);
        next.unsetAll();
        it = layer.iterator(.{});
        while (it.next()) |s| {
            if (states[s][1] & accepting_bit != 0) return best;
            const first = states[s][0];
            const count = states[s][1] & ~accepting_bit;
            for (edges[first .. first + count]) |e| {
                if (@as(u8, @truncate(e[1])) != edge_bytes) continue;
                for (&here, sets[e[1] >> 8]) |*h, b| h.* |= b;
                next.set(e[0]);
            }
        }
        var members: [3]u8 = undefined;
        var size: usize = 0;
        var weight: u32 = 0;
        for (0..256) |i| {
            if (!byteSetHas(&here, @intCast(i))) continue;
            if (size == members.len) {
                size += 1;
                break;
            }
            members[size] = @intCast(i);
            size += 1;
            weight += byteWeight(@intCast(i));
        }
        if (size == 0) return best;
        if (size <= members.len and weight < second_weight) {
            var here_anchor: Anchor = .{ .offset = offset, .bytes = .{ 0, 0, 0 }, .len = @intCast(size) };
            @memcpy(here_anchor.bytes[0..size], members[0..size]);
            if (weight < best_weight) {
                best.second = best.first;
                second_weight = best_weight;
                best.first = here_anchor;
                best_weight = weight;
            } else {
                best.second = here_anchor;
                second_weight = weight;
            }
        }
        std.mem.swap(std.DynamicBitSetUnmanaged, &layer, &next);
    }
    return best;
}

// ---------------------------------------------------------------------------
// Scratch

/// The sizes a `Scratch` is built for. A scratch can match any program whose
/// state and byte-class counts fit, so one scratch per thread can serve many
/// programs: size it with `max` over their capacities.
pub const Capacity = struct {
    /// Program states, the reversed program's extra start state included
    /// (`Program.capacity` counts it).
    states: u32,
    classes: u32,
    /// The most lazy-DFA states the scratch caches. A search that needs more
    /// resets the cache and finishes on the NFA simulation, so a small cap
    /// bounds memory without failing any match. Zero disables the DFA.
    dfa_states: u32 = default_dfa_states,

    pub fn max(a: Capacity, b: Capacity) Capacity {
        return .{
            .states = @max(a.states, b.states),
            .classes = @max(a.classes, b.classes),
            .dfa_states = @max(a.dfa_states, b.dfa_states),
        };
    }
};

/// The DFA state cap a `Capacity` gets unless it names one.
pub const default_dfa_states: u32 = 1024;
/// The largest DFA state cap: transition entries keep a target's table row
/// offset (its index times the row stride, at most 257) in 29 bits.
pub const max_dfa_states: u32 = ((1 << 29) - 1) / 257;

const trans_uncomputed: u32 = 0xFFFF_FFFF;
const trans_dead: u32 = 1 << 31;
const trans_accept: u32 = 1 << 30;
/// The target is a start state of a search with a prefilter: no thread is
/// alive, so the scan may skip to the next candidate.
const trans_start: u32 = 1 << 29;
/// The target's row in the transition table (its index times the stride),
/// so a scan's next lookup needs no multiply.
const trans_row: u32 = trans_start - 1;

// DFA state kinds, kept in a state's key tag.
/// Unordered and unanchored, for `isMatch`: does any match end here?
const mode_search: u32 = 0;
/// Priority-ordered and unanchored, for the end of the leftmost match.
const mode_forward: u32 = 1;
/// Unordered and anchored at a match end, over the reversed program.
const mode_reverse: u32 = 2;
const mode_count = 3;

/// Key tag bits: mode in bits 8 and up, "a match was seen" in bit 4, the
/// look-behind context in bits 0..2.
const tag_matched: u32 = 1 << 4;

/// In a leftmost-longest forward state, marks the first NFA state of each
/// group of threads that started at the same position.
const group_bit: u32 = 1 << 31;

/// Key arena words per cached DFA state on top of a bitset key's.
const arena_slack_per_state: usize = 8;

const ThreadList = struct {
    ids: []u32,
    starts: []u64,
    sparse: []u32,
    len: u32 = 0,

    inline fn contains(self: *const ThreadList, id: u32) bool {
        const slot = self.sparse[id];
        return slot < self.len and self.ids[slot] == id;
    }

    inline fn add(self: *ThreadList, id: u32, start: u64) void {
        self.sparse[id] = self.len;
        self.ids[self.len] = id;
        self.starts[self.len] = start;
        self.len += 1;
    }
};

/// Mutable matching state for one thread. Create it once, reuse it for every
/// match: matching never allocates.
///
/// Memory: `bytesNeeded` is exact. For a capacity of N states, C byte
/// classes and a DFA cap of D states it is at most
///
///     56 N + 4 D (C + 1) + 4 D (W + 9) + 4 H + 16 W + 40 bytes,
///
/// where W = ceil(N / 32) and H, the DFA hash table, is the smallest power of
/// two that is at least 16 and at least 2 D. With D = 256 that is at most
/// `56 N + 1024 (C + W + 10) + 16 W + 2088` bytes; see `boundFor`.
pub const Scratch = struct {
    capacity: Capacity,
    dfa_cap: u32,
    /// The most steps one search may take, or null for no limit. A step is
    /// one byte a DFA reads (forwards or backwards) or skips while looking
    /// for a match start, or one unit of NFA work: a thread visited by a
    /// closure or advanced over a byte, including the closures that build a
    /// DFA state. The budget applies to each `isMatch`, `find` and
    /// `findFrom` call, and to each match an iterator, `findAll` or `count`
    /// looks for. A search that would exceed it fails with
    /// `error.BudgetExceeded`, never with "no match".
    step_budget: ?u64 = null,
    /// The steps the last search took (at most `step_budget`).
    steps: u64 = 0,
    /// Row stride of the transition table: the largest class count plus the
    /// end-of-input column.
    stride: u32,
    words: u32,
    hash_mask: u32,

    trans: []u32,
    /// Where each DFA state's key starts in `arena`: tag, payload length,
    /// payload (a bitset, or an ordered list of NFA states).
    key_off: []u32,
    arena: []u32,
    hash: []u32,
    set_a: []u32,
    set_b: []u32,
    fwd_closure: []u32,
    rev_closure: []u32,
    /// Depth-first frames (state, next edge) for ordered closures, and the
    /// plain stack of unordered ones.
    stack: []u32,
    olist: []u32,
    onext: []u32,
    lists: [2]ThreadList,

    dfa_len: u32 = 0,
    arena_used: u32 = 0,
    start_cache: [mode_count * 8]u32 = @splat(trans_uncomputed),
    /// Identity of the program the cached DFA belongs to.
    bound_len: usize = 0,
    bound_ptr: usize = 0,
    bound_checksum: u32 = 0,
    /// Bitset words the bound program uses (at most `words`).
    bound_words: u32 = 0,

    memory: []align(8) u8,
    owns_memory: bool,

    /// The bytes `initBuffer` needs for `capacity`.
    pub fn bytesNeeded(capacity: Capacity) usize {
        return layout(capacity).total;
    }

    /// The documented upper bound on `bytesNeeded` (see the type's docs).
    pub fn boundFor(capacity: Capacity) usize {
        const n: usize = @max(capacity.states, 1);
        const c: usize = @max(capacity.classes, 1);
        const d: usize = @min(capacity.dfa_states, max_dfa_states);
        const w = (n + 31) / 32;
        var h: usize = 16;
        while (h < 2 * d) h *= 2;
        return 56 * n + 4 * d * (c + 1) + 4 * d * (w + 9) + 4 * h + 16 * w + 40;
    }

    /// A scratch for `program` (and any program whose capacity fits).
    pub fn init(allocator: std.mem.Allocator, program: *const Program) !Scratch {
        return initCapacity(allocator, program.capacity());
    }

    /// A scratch for every program whose capacity fits within `capacity`.
    pub fn initCapacity(allocator: std.mem.Allocator, capacity: Capacity) !Scratch {
        const memory = try allocator.alignedAlloc(u8, .@"8", bytesNeeded(capacity));
        var scratch = carve(memory, capacity);
        scratch.owns_memory = true;
        return scratch;
    }

    /// A scratch in caller memory (at least `bytesNeeded(capacity)` bytes).
    /// `deinit` is not needed and must not be called.
    pub fn initBuffer(buffer: []align(8) u8, capacity: Capacity) error{BufferTooSmall}!Scratch {
        if (buffer.len < bytesNeeded(capacity)) return error.BufferTooSmall;
        return carve(buffer, capacity);
    }

    /// Free a scratch made by `init` or `initCapacity`.
    pub fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        std.debug.assert(self.owns_memory);
        allocator.free(self.memory);
        self.* = undefined;
    }

    /// Forget the cached DFA (it is rebuilt lazily).
    pub fn reset(self: *Scratch) void {
        self.resetDfa();
        self.bound_len = 0;
        self.bound_ptr = 0;
        self.bound_checksum = 0;
    }

    const Layout = struct {
        list_starts: usize,
        trans: usize,
        key_off: usize,
        arena: usize,
        arena_words: usize,
        hash: usize,
        sets: usize,
        stack: usize,
        olists: usize,
        list_ids: usize,
        list_sparse: usize,
        total: usize,
        stride: u32,
        words: u32,
        hash_len: u32,
    };

    fn layout(capacity: Capacity) Layout {
        const dfa_cap: usize = @min(capacity.dfa_states, max_dfa_states);
        const states: usize = @max(capacity.states, 1);
        const stride: u32 = @max(capacity.classes, 1) + 1;
        const words: u32 = @intCast((states + 31) / 32);
        var hash_len: u32 = 16;
        while (hash_len < dfa_cap * 2) hash_len *= 2;
        var l: Layout = undefined;
        l.stride = stride;
        l.words = words;
        l.hash_len = hash_len;
        // Enough key memory for a bitset key per state with room to spare
        // for ordered keys, and always for two keys of every NFA state, so
        // a reset cache can make progress.
        l.arena_words = dfa_cap * (words + arena_slack_per_state) + 2 * (states + 3);
        // u64 arrays first so every later u32 array stays aligned.
        var off: usize = 0;
        l.list_starts = off;
        off += 2 * states * 8;
        l.trans = off;
        off += dfa_cap * stride * 4;
        l.key_off = off;
        off += dfa_cap * 4;
        l.arena = off;
        off += l.arena_words * 4;
        l.hash = off;
        off += @as(usize, hash_len) * 4;
        l.sets = off;
        off += 4 * @as(usize, words) * 4;
        l.stack = off;
        off += 2 * states * 4;
        l.olists = off;
        off += 2 * (states + 1) * 4;
        l.list_ids = off;
        off += 2 * states * 4;
        l.list_sparse = off;
        off += 2 * states * 4;
        l.total = std.mem.alignForward(usize, off, 8);
        return l;
    }

    fn carve(memory: []align(8) u8, capacity: Capacity) Scratch {
        const l = layout(capacity);
        const dfa_cap: u32 = @min(capacity.dfa_states, max_dfa_states);
        const states: usize = @max(capacity.states, 1);
        const u32s = struct {
            fn at(mem: []align(8) u8, off: usize, len: usize) []u32 {
                const ptr: [*]u32 = @ptrCast(@alignCast(mem.ptr + off));
                return ptr[0..len];
            }
        };
        const starts_ptr: [*]u64 = @ptrCast(@alignCast(memory.ptr + l.list_starts));
        const ids = u32s.at(memory, l.list_ids, 2 * states);
        const sparse = u32s.at(memory, l.list_sparse, 2 * states);
        @memset(sparse, 0);
        const sets = u32s.at(memory, l.sets, 4 * @as(usize, l.words));
        const olists = u32s.at(memory, l.olists, 2 * (states + 1));
        var scratch = Scratch{
            .capacity = capacity,
            .dfa_cap = dfa_cap,
            .stride = l.stride,
            .words = l.words,
            .hash_mask = l.hash_len - 1,
            .trans = u32s.at(memory, l.trans, @as(usize, dfa_cap) * l.stride),
            .key_off = u32s.at(memory, l.key_off, dfa_cap),
            .arena = u32s.at(memory, l.arena, l.arena_words),
            .hash = u32s.at(memory, l.hash, l.hash_len),
            .set_a = sets[0..l.words],
            .set_b = sets[l.words .. 2 * l.words],
            .fwd_closure = sets[2 * l.words .. 3 * l.words],
            .rev_closure = sets[3 * l.words ..],
            .stack = u32s.at(memory, l.stack, 2 * states),
            .olist = olists[0 .. states + 1],
            .onext = olists[states + 1 ..],
            .lists = .{
                .{ .ids = ids[0..states], .starts = starts_ptr[0..states], .sparse = sparse[0..states] },
                .{ .ids = ids[states..], .starts = starts_ptr[states .. 2 * states], .sparse = sparse[states..] },
            },
            .memory = memory,
            .owns_memory = false,
        };
        scratch.resetDfa();
        return scratch;
    }

    fn resetDfa(self: *Scratch) void {
        self.dfa_len = 0;
        self.arena_used = 0;
        @memset(self.hash, 0);
        self.start_cache = @splat(trans_uncomputed);
    }

    /// Point the scratch at `program`, dropping a DFA cached for another one.
    fn bind(self: *Scratch, program: *const Program) MatchError!void {
        if (program.state_count + 1 > self.capacity.states or program.class_count > self.capacity.classes)
            return error.ScratchTooSmall;
        if (self.bound_ptr == @intFromPtr(program.blob.ptr) and self.bound_len == program.blob.len and
            self.bound_checksum == program.checksum) return;
        self.resetDfa();
        self.bound_ptr = @intFromPtr(program.blob.ptr);
        self.bound_len = program.blob.len;
        self.bound_checksum = program.checksum;
        self.bound_words = (program.state_count + 1 + 31) / 32;
        // The epsilon closures of the start states seed the unordered DFA
        // states; the search DFA re-adds its own after every byte.
        const fwd = self.fwd_closure[0..self.bound_words];
        @memset(fwd, 0);
        bitSet(fwd, program.start);
        _ = self.closeOver(program.fwd, fwd, 0);
        const rev = self.rev_closure[0..self.bound_words];
        @memset(rev, 0);
        bitSet(rev, program.state_count);
        _ = self.closeOver(program.rev, rev, 0);
    }

    // -- bitsets --------------------------------------------------------------

    inline fn bitSet(set: []u32, id: u32) void {
        set[id >> 5] |= @as(u32, 1) << @intCast(id & 31);
    }

    inline fn bitHas(set: []const u32, id: u32) bool {
        return (set[id >> 5] >> @intCast(id & 31)) & 1 != 0;
    }

    /// Add to `set` every state reachable from its members through epsilon
    /// edges and through assertions in the `held` mask. Returns the states
    /// visited, the work done.
    fn closeOver(self: *Scratch, g: Graph, set: []u32, held: u8) u64 {
        var visited: u64 = 0;
        var top: usize = 0;
        for (set, 0..) |word, wi| {
            var w = word;
            while (w != 0) : (w &= w - 1) {
                self.stack[top] = @intCast(wi * 32 + @ctz(w));
                top += 1;
            }
        }
        while (top > 0) {
            top -= 1;
            visited += 1;
            const state = self.stack[top];
            const range = g.edgeRange(state);
            var e = range.first;
            while (e < range.first + range.count) : (e += 1) {
                const op = g.edgeOp(e);
                const kind: u8 = @truncate(op);
                const follow = switch (kind) {
                    edge_epsilon => true,
                    edge_assert => held & (@as(u8, 1) << @intCast(op >> 8)) != 0,
                    else => false,
                };
                if (!follow) continue;
                const to = g.edgeTarget(e);
                if (bitHas(set, to)) continue;
                bitSet(set, to);
                self.stack[top] = to;
                top += 1;
            }
        }
        return visited;
    }

    // -- lazy DFA ---------------------------------------------------------------

    const DfaError = error{ DfaFull, BudgetExceeded };

    /// Steps left in this search's budget.
    inline fn allowance(self: *const Scratch) u64 {
        const budget = self.step_budget orelse return std.math.maxInt(u64);
        return budget - self.steps;
    }

    /// Spend `n` steps, or fail without spending them when the budget is short.
    inline fn charge(self: *Scratch, n: u64) error{BudgetExceeded}!void {
        if (n > self.allowance()) return error.BudgetExceeded;
        self.steps += n;
    }

    /// The furthest a scan from `i` may read, bounded by the budget.
    inline fn scanLimit(self: *const Scratch, input_len: usize, i: usize) usize {
        return i + @min(input_len - i, self.allowance());
    }

    const Key = struct { tag: u32, payload: []const u32 };

    inline fn keyOf(self: *const Scratch, index: u32) Key {
        const off = self.key_off[index];
        return .{ .tag = self.arena[off], .payload = self.arena[off + 2 ..][0..self.arena[off + 1]] };
    }

    fn hashKey(payload: []const u32, tag: u32) u32 {
        var h: u32 = 2166136261;
        for (payload) |w| h = (h ^ w) *% 16777619;
        h = (h ^ tag) *% 16777619;
        return h ^ (h >> 15);
    }

    /// The DFA state for (`payload`, `tag`), created when new.
    fn intern(self: *Scratch, payload: []const u32, tag: u32) DfaError!u32 {
        var slot = hashKey(payload, tag) & self.hash_mask;
        while (true) : (slot = (slot + 1) & self.hash_mask) {
            const entry = self.hash[slot];
            if (entry == 0) break;
            const key = self.keyOf(entry - 1);
            if (key.tag == tag and std.mem.eql(u32, key.payload, payload)) return entry - 1;
        }
        if (self.dfa_len == self.dfa_cap) return error.DfaFull;
        const need = payload.len + 2;
        if (need > self.arena.len - self.arena_used) return error.DfaFull;
        const index = self.dfa_len;
        self.dfa_len += 1;
        const off = self.arena_used;
        self.arena_used += @intCast(need);
        self.arena[off] = tag;
        self.arena[off + 1] = @intCast(payload.len);
        @memcpy(self.arena[off + 2 ..][0..payload.len], payload);
        self.key_off[index] = off;
        @memset(self.trans[@as(usize, index) * self.stride ..][0..self.stride], trans_uncomputed);
        self.hash[slot] = index + 1;
        return index;
    }

    /// The row of the start state for `mode` and look-behind `ctx`.
    fn startState(self: *Scratch, program: *const Program, mode: u32, ctx: u8) DfaError!u32 {
        const slot = mode * 8 + ctx;
        if (self.start_cache[slot] != trans_uncomputed) return self.start_cache[slot];
        const tag = (mode << 8) | ctx;
        const index = switch (mode) {
            mode_search => try self.intern(self.fwd_closure[0..self.bound_words], tag),
            mode_reverse => try self.intern(self.rev_closure[0..self.bound_words], tag),
            else => blk: {
                const longest = program.flags & pf_leftmost_first == 0;
                const seed = [1]u32{program.start | if (longest) group_bit else 0};
                break :blk try self.intern(&seed, tag);
            },
        };
        self.start_cache[slot] = index * self.stride;
        return index * self.stride;
    }

    /// Compute the transition of the DFA state at table row `row` on symbol
    /// `sym`.
    fn computeTransition(self: *Scratch, program: *const Program, row: u32, sym: u32) DfaError!u32 {
        const index = row / self.stride;
        const mode = self.keyOf(index).tag >> 8;
        return switch (mode) {
            mode_forward => self.computeOrdered(program, index, sym),
            mode_reverse => self.computeSet(program, program.rev, program.rev_ctx_mask, index, sym),
            else => self.computeSet(program, program.fwd, program.ctx_mask, index, sym),
        };
    }

    /// An unordered state: close its NFA-state set at this boundary, note
    /// whether it accepts, then move it over the byte (re-seeding the start
    /// in search mode).
    fn computeSet(self: *Scratch, program: *const Program, g: Graph, ctx_mask: u8, index: u32, sym: u32) DfaError!u32 {
        const words = self.bound_words;
        const key = self.keyOf(index);
        const ctx: u8 = @truncate(key.tag & 7);
        const mode = key.tag >> 8;
        const current = self.set_a[0..words];
        @memcpy(current, key.payload);
        var work = self.closeOver(g, current, program.assertionsHolding(ctx, sym));

        var accept = false;
        for (current, 0..) |word, wi| {
            var w = word;
            while (w != 0) : (w &= w - 1) {
                if (g.isAccepting(@intCast(wi * 32 + @ctz(w)))) {
                    accept = true;
                    break;
                }
            }
            if (accept) break;
        }
        const accept_bit: u32 = if (accept) trans_accept else 0;
        if (sym == program.class_count) {
            try self.charge(work);
            return trans_dead | accept_bit;
        }

        const b = program.class_rep[sym];
        const next = self.set_b[0..words];
        @memset(next, 0);
        var any = false;
        for (current, 0..) |word, wi| {
            var w = word;
            while (w != 0) : (w &= w - 1) {
                const state: u32 = @intCast(wi * 32 + @ctz(w));
                work += 1;
                const range = g.edgeRange(state);
                var e = range.first;
                while (e < range.first + range.count) : (e += 1) {
                    const op = g.edgeOp(e);
                    if (@as(u8, @truncate(op)) != edge_bytes) continue;
                    if (!program.setHas(op >> 8, b)) continue;
                    bitSet(next, g.edgeTarget(e));
                    any = true;
                }
            }
        }
        if (any) work += self.closeOver(g, next, 0);
        try self.charge(work);
        var start_bit: u32 = 0;
        if (mode == mode_search) {
            for (next, self.fwd_closure[0..words]) |*w, s| w.* |= s;
            any = true;
            if (program.hasPrefilter() and std.mem.eql(u32, next, self.fwd_closure[0..words])) start_bit = trans_start;
        }
        if (!any) return trans_dead | accept_bit;
        const target = try self.intern(next, (mode << 8) | Program.contextAfter(b, ctx_mask));
        return target * self.stride | accept_bit | start_bit;
    }

    /// A priority-ordered forward state. Its key lists the NFA states its
    /// threads resume at, highest priority first; under leftmost-longest the
    /// list is split into groups of threads that started at the same
    /// position (`group_bit` marks each group's first state), earliest start
    /// first. The step closes the list depth-first in edge order (the
    /// compiler emits the preferred edge first; a state belongs to the first
    /// path that reaches it), then finds the first accepting state:
    /// leftmost-first drops every state after it, leftmost-longest every
    /// later group. Survivors move over the byte in order, and until a match
    /// is seen a new lowest-priority thread starts at the next position.
    fn computeOrdered(self: *Scratch, program: *const Program, index: u32, sym: u32) DfaError!u32 {
        const g = program.fwd;
        const words = self.bound_words;
        const key = self.keyOf(index);
        const ctx: u8 = @truncate(key.tag & 7);
        const matched = key.tag & tag_matched != 0;
        const longest = program.flags & pf_leftmost_first == 0;
        const held = program.assertionsHolding(ctx, sym);

        // The closure, in priority order.
        const visited = self.set_a[0..words];
        @memset(visited, 0);
        const list = self.olist;
        var len: u32 = 0;
        var group: u32 = 0;
        var last_group: u32 = std.math.maxInt(u32);
        for (key.payload) |entry| {
            if (entry & group_bit != 0) group += 1;
            const seed = entry & ~group_bit;
            if (bitHas(visited, seed)) continue;
            bitSet(visited, seed);
            list[len] = seed | if (group != last_group) group_bit else 0;
            last_group = group;
            len += 1;
            var top: usize = 1;
            self.stack[0] = seed;
            self.stack[1] = g.edgeRange(seed).first;
            while (top > 0) {
                const frame = 2 * (top - 1);
                const s = self.stack[frame];
                const e = self.stack[frame + 1];
                const range = g.edgeRange(s);
                if (e == range.first + range.count) {
                    top -= 1;
                    continue;
                }
                self.stack[frame + 1] = e + 1;
                const op = g.edgeOp(e);
                const follow = switch (@as(u8, @truncate(op))) {
                    edge_epsilon => true,
                    edge_assert => held & (@as(u8, 1) << @intCast(op >> 8)) != 0,
                    else => false,
                };
                if (!follow) continue;
                const t = g.edgeTarget(e);
                if (bitHas(visited, t)) continue;
                bitSet(visited, t);
                list[len] = t;
                len += 1;
                self.stack[2 * top] = t;
                self.stack[2 * top + 1] = g.edgeRange(t).first;
                top += 1;
            }
        }
        var work: u64 = len;
        if (!longest) {
            for (list[0..len]) |*entry| entry.* &= ~group_bit;
        }

        // The first accepting state ends the list (or its group).
        var accept = false;
        var k: u32 = 0;
        while (k < len) : (k += 1) {
            if (g.isAccepting(list[k] & ~group_bit)) {
                accept = true;
                var cut = k + 1;
                if (longest) {
                    while (cut < len and list[cut] & group_bit == 0) cut += 1;
                }
                len = cut;
                break;
            }
        }
        const accept_bit: u32 = if (accept) trans_accept else 0;
        if (sym == program.class_count) {
            try self.charge(work);
            return trans_dead | accept_bit;
        }

        // Move the survivors over the byte, first arrival kept.
        const b = program.class_rep[sym];
        const seen = self.set_b[0..words];
        @memset(seen, 0);
        const next = self.onext;
        var n: u32 = 0;
        var src_group: u32 = 0;
        var emitted_group: u32 = std.math.maxInt(u32);
        for (list[0..len]) |entry| {
            if (entry & group_bit != 0) src_group += 1;
            const s = entry & ~group_bit;
            work += 1;
            const range = g.edgeRange(s);
            var e = range.first;
            while (e < range.first + range.count) : (e += 1) {
                const op = g.edgeOp(e);
                if (@as(u8, @truncate(op)) != edge_bytes) continue;
                if (!program.setHas(op >> 8, b)) continue;
                const t = g.edgeTarget(e);
                if (bitHas(seen, t)) continue;
                bitSet(seen, t);
                next[n] = t | if (longest and src_group != emitted_group) group_bit else 0;
                emitted_group = src_group;
                n += 1;
            }
        }
        const now_matched = matched or accept;
        // A match starting later cannot be leftmost once one is seen.
        if (!now_matched and !bitHas(seen, program.start)) {
            next[n] = program.start | if (longest) group_bit else 0;
            n += 1;
        }
        try self.charge(work);
        if (n == 0) return trans_dead | accept_bit;
        if (longest) sortGroups(next[0..n]);
        const tag = (mode_forward << 8) | (if (now_matched) tag_matched else 0) | Program.contextAfter(b, program.ctx_mask);
        const target = try self.intern(next[0..n], tag);
        const start_bit: u32 = if (!now_matched and n == 1 and program.hasPrefilter()) trans_start else 0;
        return target * self.stride | accept_bit | start_bit;
    }

    /// Sort each group of a leftmost-longest list by state id: a group is a
    /// set, so one canonical order keeps equal states from multiplying.
    fn sortGroups(list: []u32) void {
        var i: usize = 0;
        while (i < list.len) {
            var j = i + 1;
            while (j < list.len and list[j] & group_bit == 0) j += 1;
            list[i] &= ~group_bit;
            std.sort.pdq(u32, list[i..j], {}, std.sort.asc(u32));
            list[i] |= group_bit;
            i = j;
        }
    }

    inline fn transition(self: *Scratch, program: *const Program, row: u32, sym: u32) DfaError!u32 {
        const slot = @as(usize, row) + sym;
        const cached = self.trans[slot];
        if (cached != trans_uncomputed) return cached;
        const computed = try self.computeTransition(program, row, sym);
        self.trans[slot] = computed;
        return computed;
    }

    /// The first position at or after `i` where a match can start (see
    /// `Program.nextCandidate`), charging the bytes skipped.
    fn skip(self: *Scratch, program: *const Program, input: []const u8, i: usize) error{BudgetExceeded}!usize {
        const limit = self.scanLimit(input.len, i);
        const candidate = program.nextCandidate(input[0..limit], i);
        self.steps += candidate - i;
        if (candidate == limit and limit < input.len) return error.BudgetExceeded;
        return candidate;
    }

    /// A forward scan from `from` in `mode` (search or forward): the end of
    /// the leftmost match for the forward DFA, or the first match end seen
    /// for the search DFA (`stop_at_accept`). While no thread is alive the
    /// scan skips to the next candidate start. `live_from` receives the last
    /// position where no thread was alive, which no match found starts
    /// before.
    fn forwardScan(self: *Scratch, program: *const Program, input: []const u8, from: usize, mode: u32, stop_at_accept: bool, live_from: *usize) DfaError!?usize {
        const classes = program.classes;
        var i = from;
        if (program.hasPrefilter()) i = try self.skip(program, input, i);
        live_from.* = i;
        var state = try self.startState(program, mode, program.contextAt(input, i));
        // The budget caps how far this scan may read, so the loop itself pays
        // nothing for it. Bytes before `counted` are already in `steps`.
        var limit = self.scanLimit(input.len, i);
        var counted = i;
        var last: ?usize = null;
        const trans = self.trans;
        while (i < limit) {
            // A plain transition is the next row as is: no flag to mask off.
            var t = trans[@as(usize, state) + classes[input[i]]];
            if (t >= trans_start) {
                if (t == trans_uncomputed) {
                    self.steps += i - counted;
                    counted = i;
                    t = try self.computeTransition(program, state, classes[input[i]]);
                    trans[@as(usize, state) + classes[input[i]]] = t;
                    limit = self.scanLimit(input.len, i);
                }
                if (t & trans_accept != 0) {
                    last = i;
                    if (stop_at_accept) return self.scanned(i - counted, i);
                }
                if (t & trans_dead != 0) return self.scanned(i + 1 - counted, last);
                if (t & trans_start != 0) {
                    // No thread survives this byte: skip ahead.
                    self.steps += i + 1 - counted;
                    const next = try self.skip(program, input, i + 1);
                    // The target is the start state for the context after
                    // this byte, which is also right after a skip when
                    // assertions see no context.
                    state = if (next == i + 1 or program.ctx_mask == 0)
                        t & trans_row
                    else
                        try self.startState(program, mode, program.contextAt(input, next));
                    i = next;
                    live_from.* = i;
                    counted = i;
                    limit = self.scanLimit(input.len, i);
                    continue;
                }
                t &= trans_row;
            }
            state = t;
            i += 1;
        }
        self.steps += limit - counted;
        if (limit < input.len) return error.BudgetExceeded;
        const t = try self.transition(program, state, program.class_count);
        if (t & trans_accept != 0) last = input.len;
        return last;
    }

    /// Account for `n` bytes a DFA scan read (already within its allowance).
    inline fn scanned(self: *Scratch, n: usize, result: ?usize) ?usize {
        self.steps += n;
        return result;
    }

    /// The smallest end of any match starting at or after `from`, or null.
    fn dfaEarliestEnd(self: *Scratch, program: *const Program, input: []const u8, from: usize) DfaError!?usize {
        var live_from: usize = undefined;
        return self.forwardScan(program, input, from, mode_search, true, &live_from);
    }

    /// The start of the leftmost match that ends at `end`, by running the
    /// reversed program backwards from `end`: the furthest position, not
    /// before `from`, where it accepts. No match ending at `end` starts
    /// earlier than the leftmost match does, so that is its start.
    fn dfaReverseStart(self: *Scratch, program: *const Program, input: []const u8, end: usize, from: usize) DfaError!usize {
        const classes = program.classes;
        var state = try self.startState(program, mode_reverse, program.reverseContextAt(input, end));
        const stop = end - @min(end - from, self.allowance());
        var best: ?usize = null;
        var i = end;
        while (true) {
            const sym: u32 = if (i == 0) program.class_count else classes[input[i - 1]];
            const t = try self.transition(program, state, sym);
            if (t & trans_accept != 0) best = i;
            if (i == from or t & trans_dead != 0) break;
            if (i == stop) {
                self.steps += end - i;
                return error.BudgetExceeded;
            }
            state = t & trans_row;
            i -= 1;
        }
        self.steps += end - i;
        // A consistent program always accepts here; a forged one must not
        // break the span's order.
        return best orelse end;
    }

    /// The leftmost match at or after `from`: its end from the ordered
    /// forward DFA, then its start from the reversed program, which need not
    /// look back past the last position the forward scan had no thread
    /// alive (with a prefilter, the candidate it skipped to).
    fn dfaFind(self: *Scratch, program: *const Program, input: []const u8, from: usize) DfaError!?Span {
        var live_from: usize = from;
        const end = (try self.forwardScan(program, input, from, mode_forward, false, &live_from)) orelse return null;
        return .{ .start = try self.dfaReverseStart(program, input, end, live_from), .end = end };
    }

    // -- NFA simulation -------------------------------------------------------

    /// Add `state` and its closure at `pos` to `list`, all with `start`. A
    /// state already present keeps the earlier thread: lists are ordered by
    /// start, so the first arrival has the smaller start.
    fn addThread(self: *Scratch, program: *const Program, list: *ThreadList, state: u32, start: u64, input: []const u8, pos: usize) error{BudgetExceeded}!void {
        const g = program.fwd;
        if (list.contains(state)) return;
        list.add(state, start);
        var top: usize = 1;
        self.stack[0] = state;
        while (top > 0) {
            top -= 1;
            try self.charge(1);
            const s = self.stack[top];
            const range = g.edgeRange(s);
            var e = range.first;
            while (e < range.first + range.count) : (e += 1) {
                const op = g.edgeOp(e);
                const follow = switch (@as(u8, @truncate(op))) {
                    edge_epsilon => true,
                    edge_assert => program.assertionAt(@fromBackingInt(@intCast(op >> 8)), input, pos),
                    else => false,
                };
                if (!follow) continue;
                const to = g.edgeTarget(e);
                if (list.contains(to)) continue;
                list.add(to, start);
                self.stack[top] = to;
                top += 1;
            }
        }
    }

    /// `addThread` in priority order: the closure depth-first in edge order,
    /// each state listed when first reached (Pike VM order).
    fn addThreadOrdered(self: *Scratch, program: *const Program, list: *ThreadList, state: u32, start: u64, input: []const u8, pos: usize) error{BudgetExceeded}!void {
        const g = program.fwd;
        if (list.contains(state)) return;
        try self.charge(1);
        list.add(state, start);
        var top: usize = 1;
        self.stack[0] = state;
        self.stack[1] = g.edgeRange(state).first;
        while (top > 0) {
            const frame = 2 * (top - 1);
            const s = self.stack[frame];
            const e = self.stack[frame + 1];
            const range = g.edgeRange(s);
            if (e == range.first + range.count) {
                top -= 1;
                continue;
            }
            self.stack[frame + 1] = e + 1;
            const op = g.edgeOp(e);
            const follow = switch (@as(u8, @truncate(op))) {
                edge_epsilon => true,
                edge_assert => program.assertionAt(@fromBackingInt(@intCast(op >> 8)), input, pos),
                else => false,
            };
            if (!follow) continue;
            const to = g.edgeTarget(e);
            if (list.contains(to)) continue;
            try self.charge(1);
            list.add(to, start);
            self.stack[2 * top] = to;
            self.stack[2 * top + 1] = g.edgeRange(to).first;
            top += 1;
        }
    }

    /// Search by NFA simulation in one pass, for the program's match kind:
    /// each thread remembers where its match started, and once a match is
    /// known no later start is seeded. With `first_only`, any match ends the
    /// search.
    fn nfaFind(self: *Scratch, program: *const Program, input: []const u8, from: usize, first_only: bool) error{BudgetExceeded}!?Span {
        if (!first_only and program.flags & pf_leftmost_first != 0) return self.nfaFindFirst(program, input, from);
        const g = program.fwd;
        var current = &self.lists[0];
        var next = &self.lists[1];
        current.len = 0;
        var best: ?Span = null;
        var pos = from;
        while (true) {
            if (best == null) try self.addThread(program, current, program.start, pos, input, pos);
            // The first accepting thread has the smallest start among them.
            var k: u32 = 0;
            while (k < current.len) : (k += 1) {
                if (!g.isAccepting(current.ids[k])) continue;
                const start: usize = @intCast(current.starts[k]);
                if (best == null or start < best.?.start or (start == best.?.start and pos > best.?.end))
                    best = .{ .start = start, .end = pos };
                if (first_only) return best;
                // Threads that started later can only find a later match.
                var keep = k + 1;
                while (keep < current.len and current.starts[keep] <= start) keep += 1;
                current.len = keep;
                break;
            }
            if (pos == input.len or current.len == 0) break;
            const b = input[pos];
            next.len = 0;
            k = 0;
            try self.charge(current.len);
            while (k < current.len) : (k += 1) {
                const state = current.ids[k];
                const range = g.edgeRange(state);
                var e = range.first;
                while (e < range.first + range.count) : (e += 1) {
                    const op = g.edgeOp(e);
                    if (@as(u8, @truncate(op)) != edge_bytes) continue;
                    if (!program.setHas(op >> 8, b)) continue;
                    try self.addThread(program, next, g.edgeTarget(e), current.starts[k], input, pos + 1);
                }
            }
            std.mem.swap(*ThreadList, &current, &next);
            pos += 1;
            if (best != null and current.len == 0) break;
        }
        return best;
    }

    /// Leftmost-first search by Pike VM: threads stay in priority order (an
    /// earlier start first, then edge order), and the first accepting thread
    /// drops every thread after it; only higher-priority threads keep
    /// running, so a later accept always outranks the one it replaces.
    fn nfaFindFirst(self: *Scratch, program: *const Program, input: []const u8, from: usize) error{BudgetExceeded}!?Span {
        const g = program.fwd;
        var current = &self.lists[0];
        var next = &self.lists[1];
        current.len = 0;
        var best: ?Span = null;
        var pos = from;
        while (true) {
            if (best == null) try self.addThreadOrdered(program, current, program.start, pos, input, pos);
            var k: u32 = 0;
            while (k < current.len) : (k += 1) {
                if (!g.isAccepting(current.ids[k])) continue;
                best = .{ .start = @intCast(current.starts[k]), .end = pos };
                current.len = k + 1;
                break;
            }
            if (pos == input.len or current.len == 0) break;
            const b = input[pos];
            next.len = 0;
            try self.charge(current.len);
            k = 0;
            while (k < current.len) : (k += 1) {
                const range = g.edgeRange(current.ids[k]);
                var e = range.first;
                while (e < range.first + range.count) : (e += 1) {
                    const op = g.edgeOp(e);
                    if (@as(u8, @truncate(op)) != edge_bytes) continue;
                    if (!program.setHas(op >> 8, b)) continue;
                    try self.addThreadOrdered(program, next, g.edgeTarget(e), current.starts[k], input, pos + 1);
                }
            }
            std.mem.swap(*ThreadList, &current, &next);
            pos += 1;
            if (best != null and current.len == 0) break;
        }
        return best;
    }
};

test "program: smoke" {
    var program = try Program.compile(std.testing.allocator, "b+c", .{});
    defer program.deinit(std.testing.allocator);
    var scratch = try Scratch.init(std.testing.allocator, &program);
    defer scratch.deinit(std.testing.allocator);
    try std.testing.expect(try program.isMatch(&scratch, "abbbc"));
    const m = (try program.find(&scratch, "abbbcd")).?;
    try std.testing.expectEqual(@as(usize, 1), m.start);
    try std.testing.expectEqual(@as(usize, 5), m.end);
    try std.testing.expect(!try program.isMatch(&scratch, "abbb"));
}

test "program: leftmost-first smoke" {
    const gpa = std.testing.allocator;
    var program = try Program.compileWithOptions(gpa, "a|ab", .{}, .{ .match_kind = .leftmost_first });
    defer program.deinit(gpa);
    try std.testing.expectEqual(MatchKind.leftmost_first, program.matchKind());
    var scratch = try Scratch.init(gpa, &program);
    defer scratch.deinit(gpa);
    const m = (try program.find(&scratch, "xab")).?;
    try std.testing.expectEqual(@as(usize, 1), m.start);
    try std.testing.expectEqual(@as(usize, 2), m.end);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Program);
    std.testing.refAllDecls(Scratch);
}
