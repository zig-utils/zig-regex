//! Flat, relocatable regex programs and an allocation-free matcher.
//!
//! A `Program` is a compiled pattern laid out in one contiguous byte blob:
//! little-endian, offsets instead of pointers, nothing that refers outside the
//! blob. It is immutable once built, so one program can be shared read-only by
//! any number of threads.
//!
//! Matching state lives in a `Scratch`: the lazy DFA's transition cache, the
//! NFA simulation's thread lists and the closure stack. A scratch is sized
//! once from a program (or from the largest of several, see `Capacity`) and
//! then reused for every match on its thread; no match ever allocates.
//!
//! Programs cover the patterns the Thompson engine runs: everything except
//! backreferences, general lookaround, lazy quantifiers outside ECMAScript
//! mode, scoped inline modifiers and Unicode property escapes, which need the
//! backtracking engine. `Program.fromRegex` reports those with
//! `error.UnsupportedByProgram`, as it does for a regex the backtracker got
//! only to order captures inside an alternation; `Program.compile` drops
//! capture groups first, so such patterns still become programs. ECMAScript
//! mode is also unsupported. Matching
//! reports spans only (no capture groups) with the same semantics as
//! `Regex.find`: the leftmost match, extended as far as possible.
//!
//! `Program.bytes` is the serialised program and `Program.load` reads one
//! back from borrowed memory (an mmapped file, say) without allocating, after
//! validating it.
//!
//! Matching runs a lazy DFA built in the scratch. When the DFA would need
//! more states than the scratch holds it is reset and the current call
//! finishes on an NFA simulation over the same program, so a pattern whose
//! DFA explodes still matches, in time linear in the input.

const std = @import("std");
const compiler = @import("compiler.zig");
const common = @import("common.zig");
const ast = @import("ast.zig");
const Regex = @import("regex.zig").Regex;

/// A match: `input[start..end]`.
pub const Span = struct {
    start: usize,
    end: usize,
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
    /// A blob layout this build does not read.
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
/// The blob layout version this build writes and reads.
pub const format_version: u16 = 1;

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

    fn bit(self: Assertion) u8 {
        return @as(u8, 1) << @intCast(@backingInt(self));
    }
};

// ---------------------------------------------------------------------------
// Blob layout
//
//   header (64 bytes)
//     0  magic "ZRXP"           4  version u16       6  header size u16
//     8  total length u32      12  program flags u32
//    16  state count u32       20  edge count u32   24  byte-set count u32
//    28  start state u32       32  byte-class count u32
//    36  states offset u32     40  edges offset u32 44  byte sets offset u32
//    48  class map offset u32  52  first-byte set offset u32 (0 when absent)
//    56  CRC-32 of the blob with this field zeroed
//    60  longest match in bytes u32 (0xFFFFFFFF when unbounded)
//   states       8 bytes each: first edge u32, edge count (bits 0..30) with
//                the accepting flag in bit 31
//   edges        8 bytes each: target state u32, op u32 (kind in bits 0..7,
//                argument above: a byte-set index or an `Assertion`)
//   byte sets    32-byte bitmaps
//   class map    256 bytes: the byte class of every byte value
//   first bytes  optional 32-byte bitmap of the bytes a match can start with
//
// Every section is 8-byte aligned relative to the blob start; integers are
// read with explicit little-endian loads, so the blob itself may sit at any
// address.

const header_size: usize = 64;
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

const unbounded_len: u32 = 0xFFFF_FFFF;

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
const pf_known: u32 = (1 << 7) - 1;

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

// Look-behind context bits a DFA state carries (the context on entry).
const ctx_start: u8 = 1;
const ctx_prev_word: u8 = 2;
const ctx_prev_nl: u8 = 4;

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
    states: []const u8,
    edges: []const u8,
    sets: []const u8,
    classes: *const [256]u8,
    first_bytes: ?*const [32]u8,
    /// The only byte a match can start with, when there is exactly one.
    first_byte: ?u8,
    /// The longest match in bytes, or null when matches are unbounded.
    max_len: ?u32,
    checksum: u32,
    /// The look-behind context bits this program's assertions can observe.
    ctx_mask: u8,
    /// One byte of each byte class: every byte of a class behaves alike.
    class_rep: [256]u8,

    /// Compile `pattern` and flatten it into a program. Programs report
    /// spans only, so groups are compiled as non-capturing (see
    /// `Regex.compileWithoutCaptures`): an alternation of capture groups,
    /// which `Regex` hands to the backtracker to order its captures, still
    /// becomes a program.
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags) !Program {
        var re = try Regex.compileWithoutCaptures(allocator, pattern, flags);
        defer re.deinit();
        return fromRegex(allocator, &re);
    }

    /// Flatten a compiled regex into a program. The regex is not retained.
    pub fn fromRegex(allocator: std.mem.Allocator, re: *const Regex) BuildError!Program {
        const blob = try build(allocator, re);
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
    /// independent, little-endian, versioned and checksummed.
    pub fn bytes(self: *const Program) []const u8 {
        return self.blob;
    }

    /// A program over serialised bytes, without allocating or copying: the
    /// result borrows `blob` (for example an mmapped region), which must
    /// outlive it and stay unchanged. `blob` may extend past the program; the
    /// header records its length, and `bytes().len` reports it.
    ///
    /// Everything memory safety depends on is validated: header, section
    /// layout, every state's edge range, every edge's target and argument,
    /// and the byte-class map against each byte set and assertion. A CRC-32
    /// over the whole program rejects accidental corruption. The blob may sit
    /// at any address: all reads are explicit little-endian loads.
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

    /// The sizes a scratch needs to match this program.
    pub fn capacity(self: *const Program) Capacity {
        return .{ .states = self.state_count, .classes = self.class_count };
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

    /// The leftmost match in `input`, extended as far as possible.
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

    /// Successive non-overlapping matches, as `Regex.findAll` reports them.
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

    inline fn edgeRange(self: *const Program, state: u32) struct { first: u32, count: u32 } {
        const base = @as(usize, state) * state_record;
        return .{
            .first = readU32(self.states, base),
            .count = readU32(self.states, base + 4) & ~accepting_bit,
        };
    }

    inline fn isAccepting(self: *const Program, state: u32) bool {
        return readU32(self.states, @as(usize, state) * state_record + 4) & accepting_bit != 0;
    }

    inline fn edgeTarget(self: *const Program, edge: u32) u32 {
        return readU32(self.edges, @as(usize, edge) * edge_record);
    }

    inline fn edgeOp(self: *const Program, edge: u32) u32 {
        return readU32(self.edges, @as(usize, edge) * edge_record + 4);
    }

    inline fn setHas(self: *const Program, set: u32, b: u8) bool {
        const byte = self.sets[@as(usize, set) * set_record + (b >> 3)];
        return (byte >> @intCast(b & 7)) & 1 != 0;
    }

    /// The first position at or after `pos` whose byte can start a match, or
    /// `input.len`. Only for programs with a first-byte set.
    fn nextCandidate(self: *const Program, input: []const u8, pos: usize) usize {
        if (self.first_byte) |b| return std.mem.indexOfScalarPos(u8, input, pos, b) orelse input.len;
        const fb = self.first_bytes.?;
        var i = pos;
        while (i < input.len and !byteSetHas(fb, input[i])) i += 1;
        return i;
    }

    /// The look-behind context at `pos`, as a DFA state records it.
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

    /// The context after consuming byte `b`.
    fn contextAfter(self: *const Program, b: u8) u8 {
        var ctx: u8 = 0;
        if (isWordByte(b)) ctx |= ctx_prev_word;
        if (b == '\n') ctx |= ctx_prev_nl;
        return ctx & self.ctx_mask;
    }

    /// The assertions that hold between context `ctx` and the symbol about to
    /// be read: byte class `sym`, or end of input when `sym == class_count`.
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

/// Read the header of a blob this module built and return the program view.
fn view(blob: []const u8) Program {
    const flags = readU32(blob, off_flags);
    const state_count = readU32(blob, off_state_count);
    const edge_count = readU32(blob, off_edge_count);
    const set_count = readU32(blob, off_set_count);
    const states_off = readU32(blob, off_states);
    const edges_off = readU32(blob, off_edges);
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
        .states = blob[states_off..][0 .. @as(usize, state_count) * state_record],
        .edges = blob[edges_off..][0 .. @as(usize, edge_count) * edge_record],
        .sets = blob[sets_off..][0 .. @as(usize, set_count) * set_record],
        .classes = blob[classes_off..][0..256],
        .first_bytes = if (flags & pf_first_bytes != 0) blob[first_off..][0..32] else null,
        .first_byte = null,
        .max_len = if (readU32(blob, off_max_len) == unbounded_len) null else readU32(blob, off_max_len),
        .checksum = readU32(blob, off_checksum),
        .ctx_mask = 0,
        .class_rep = undefined,
    };
    if (flags & pf_assert_start != 0) program.ctx_mask |= ctx_start;
    if (flags & pf_assert_word != 0) program.ctx_mask |= ctx_prev_word;
    if (flags & pf_assert_line_start != 0) program.ctx_mask |= ctx_prev_nl;
    var b: usize = 256;
    while (b > 0) {
        b -= 1;
        program.class_rep[program.classes[b]] = @intCast(b);
    }
    if (program.first_bytes) |fb| {
        var count: usize = 0;
        for (fb) |byte| count += @popCount(byte);
        if (count == 1) {
            for (fb, 0..) |byte, i| {
                if (byte != 0) program.first_byte = @intCast(i * 8 + @ctz(byte));
            }
        }
    }
    return program;
}

/// Check a serialised program and return exactly its bytes. See `load`.
fn validate(input: []const u8) LoadError![]const u8 {
    if (input.len < header_size) return error.Truncated;
    if (!std.mem.eql(u8, input[off_magic..][0..4], magic)) return error.BadMagic;
    if (std.mem.readInt(u16, input[off_version..][0..2], .little) != format_version) return error.UnsupportedVersion;
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
    const start = readU32(blob, off_start);
    const class_count = readU32(blob, off_class_count);
    if (state_count == 0 or state_count > max_program_states) return error.InvalidProgram;
    if (start >= state_count) return error.InvalidProgram;
    if (class_count == 0 or class_count > 256) return error.InvalidProgram;

    // The sections sit back to back in a fixed order; anything else (gaps,
    // overlaps, a section past the end) is rejected.
    const states_off: u64 = header_size;
    const edges_off = states_off + state_count * state_record;
    const sets_off = edges_off + edge_count * edge_record;
    const classes_off = sets_off + set_count * set_record;
    const has_first = flags & pf_first_bytes != 0;
    const first_off: u64 = if (has_first) classes_off + 256 else 0;
    const expected_total = classes_off + 256 + @as(u64, if (has_first) set_record else 0);
    if (readU32(blob, off_states) != states_off or readU32(blob, off_edges) != edges_off or
        readU32(blob, off_sets) != sets_off or readU32(blob, off_classes) != classes_off or
        readU32(blob, off_first) != first_off or total != expected_total)
        return error.InvalidProgram;

    const states = blob[@intCast(states_off)..@intCast(edges_off)];
    const edges = blob[@intCast(edges_off)..@intCast(sets_off)];
    const sets = blob[@intCast(sets_off)..@intCast(classes_off)];
    const classes = blob[@intCast(classes_off)..][0..256];

    var i: u64 = 0;
    while (i < state_count) : (i += 1) {
        const first: u64 = readU32(states, @intCast(i * state_record));
        const count: u64 = readU32(states, @intCast(i * state_record + 4)) & ~accepting_bit;
        if (first + count > edge_count) return error.InvalidProgram;
    }

    // Edges, and the assertion flags they imply.
    var implied: u32 = 0;
    i = 0;
    while (i < edge_count) : (i += 1) {
        const target = readU32(edges, @intCast(i * edge_record));
        const op = readU32(edges, @intCast(i * edge_record + 4));
        if (target >= state_count) return error.InvalidProgram;
        const arg = op >> 8;
        switch (@as(u8, @truncate(op))) {
            edge_epsilon => if (arg != 0) return error.InvalidProgram,
            edge_bytes => if (arg >= set_count) return error.InvalidProgram,
            edge_assert => {
                if (arg > @backingInt(Assertion.non_word_boundary)) return error.InvalidProgram;
                switch (@as(Assertion, @fromBackingInt(@intCast(arg)))) {
                    .start_text => implied |= pf_assert_start,
                    .start_line => {
                        implied |= pf_assert_start;
                        if (flags & pf_multiline != 0) implied |= pf_assert_line_start;
                    },
                    .word_boundary, .non_word_boundary => implied |= pf_assert_word,
                    .end_line, .end_text => {},
                }
            },
            else => return error.InvalidProgram,
        }
    }
    const assert_flags = pf_assert_start | pf_assert_word | pf_assert_line_start;
    if (flags & assert_flags != implied) return error.InvalidProgram;

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

fn build(allocator: std.mem.Allocator, re: *const Regex) BuildError![]u8 {
    if (re.engine_type != .thompson_nfa or re.flags.ecmascript or re.nfa.has_literal_assertions)
        return error.UnsupportedByProgram;
    const nfa = &re.nfa;
    const n = nfa.states.items.len;
    if (n == 0 or n > max_program_states) return error.ProgramTooLarge;

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

    for (nfa.states.items, 0..) |state, i| {
        const first = edges.items.len;
        for (state.transitions.items) |t| {
            if (t.to >= n) return error.UnsupportedByProgram;
            const to: u32 = @intCast(t.to);
            switch (t.transition_type) {
                .epsilon => try edges.append(allocator, .{ to, edge_epsilon }),
                .anchor => {
                    const assertion = Assertion.fromAnchor(t.data.anchor);
                    switch (assertion) {
                        .start_text => flags |= pf_assert_start,
                        .start_line => {
                            flags |= pf_assert_start;
                            if (re.flags.multiline) flags |= pf_assert_line_start;
                        },
                        .word_boundary, .non_word_boundary => flags |= pf_assert_word,
                        .end_line, .end_text => {},
                    }
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

    const first_bytes = try firstBytes(allocator, @intCast(nfa.start_state), sets.items, edges.items, states);
    const max_len = try longestMatch(allocator, @intCast(nfa.start_state), edges.items, states);
    if (first_bytes != null) flags |= pf_first_bytes;

    const states_off = header_size;
    const edges_off = states_off + n * state_record;
    const sets_off = edges_off + edges.items.len * edge_record;
    const classes_off = sets_off + sets.items.len * set_record;
    const first_off = classes_off + 256;
    const total = first_off + if (first_bytes != null) set_record else 0;
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
    writeU32(blob, off_start, @intCast(nfa.start_state));
    writeU32(blob, off_class_count, class_count);
    writeU32(blob, off_states, @intCast(states_off));
    writeU32(blob, off_edges, @intCast(edges_off));
    writeU32(blob, off_sets, @intCast(sets_off));
    writeU32(blob, off_classes, @intCast(classes_off));
    writeU32(blob, off_first, if (first_bytes != null) @intCast(first_off) else 0);
    writeU32(blob, off_max_len, max_len orelse unbounded_len);
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

// ---------------------------------------------------------------------------
// Scratch

/// The sizes a `Scratch` is built for. A scratch can match any program whose
/// state and byte-class counts fit, so one scratch per thread can serve many
/// programs: size it with `max` over their capacities.
pub const Capacity = struct {
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
/// The largest DFA state cap: transition entries keep state ids in 30 bits.
pub const max_dfa_states: u32 = (1 << 30) - 1;

const trans_uncomputed: u32 = 0xFFFF_FFFF;
const trans_dead: u32 = 1 << 31;
const trans_accept: u32 = 1 << 30;
const trans_index: u32 = trans_accept - 1;

const mode_anchored: u32 = 0;
const mode_unanchored: u32 = 1;

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
///     36 N + 4 D (C + 1) + 4 D (W + 1) + 4 H + 12 W + 8 bytes,
///
/// where W = ceil(N / 32) and H, the DFA hash table, is the smallest power of
/// two that is at least 16 and at least 2 D. With D = 256 that is at most
/// `36 N + 1024 (C + W + 2) + 12 W + 2056` bytes; see `boundFor`.
pub const Scratch = struct {
    capacity: Capacity,
    dfa_cap: u32,
    /// The most steps one search may take, or null for no limit. A step is
    /// one byte the DFA reads (or skips while looking for a match start), or
    /// one unit of NFA work: a thread visited by a closure or advanced over a
    /// byte, including the closures that build a DFA state. The budget
    /// applies to each `isMatch`, `find` and `findFrom` call, and to each
    /// match an iterator, `findAll` or `count` looks for. A search that would
    /// exceed it fails with `error.BudgetExceeded`, never with "no match".
    step_budget: ?u64 = null,
    /// The steps the last search took (at most `step_budget`).
    steps: u64 = 0,
    /// Row stride of the transition table: the largest class count plus the
    /// end-of-input column.
    stride: u32,
    words: u32,
    key_words: u32,
    hash_mask: u32,

    trans: []u32,
    keys: []u32,
    hash: []u32,
    set_a: []u32,
    set_b: []u32,
    start_closure: []u32,
    stack: []u32,
    lists: [2]ThreadList,

    dfa_len: u32 = 0,
    start_cache: [16]u32 = @splat(trans_uncomputed),
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
        const d: usize = capacity.dfa_states;
        const w = (n + 31) / 32;
        var h: usize = 16;
        while (h < 2 * d) h *= 2;
        return 36 * n + 4 * d * (c + 1) + 4 * d * (w + 1) + 4 * h + 12 * w + 8;
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
        trans: usize,
        keys: usize,
        hash: usize,
        sets: usize,
        stack: usize,
        list_ids: usize,
        list_sparse: usize,
        list_starts: usize,
        total: usize,
        stride: u32,
        words: u32,
        key_words: u32,
        hash_len: u32,
    };

    fn layout(capacity: Capacity) Layout {
        const dfa_cap: u32 = @min(capacity.dfa_states, max_dfa_states);
        const states: usize = @max(capacity.states, 1);
        const stride: u32 = @max(capacity.classes, 1) + 1;
        const words: u32 = @intCast((states + 31) / 32);
        const key_words = words + 1;
        var hash_len: u32 = 16;
        while (hash_len < dfa_cap * 2) hash_len *= 2;
        var l: Layout = undefined;
        l.stride = stride;
        l.words = words;
        l.key_words = key_words;
        l.hash_len = hash_len;
        // u64 arrays first so every later u32 array stays aligned.
        var off: usize = 0;
        l.list_starts = off;
        off += 2 * states * 8;
        l.trans = off;
        off += @as(usize, dfa_cap) * stride * 4;
        l.keys = off;
        off += @as(usize, dfa_cap) * key_words * 4;
        l.hash = off;
        off += @as(usize, hash_len) * 4;
        l.sets = off;
        off += 3 * @as(usize, words) * 4;
        l.stack = off;
        off += states * 4;
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
        const sets = u32s.at(memory, l.sets, 3 * @as(usize, l.words));
        var scratch = Scratch{
            .capacity = capacity,
            .dfa_cap = dfa_cap,
            .stride = l.stride,
            .words = l.words,
            .key_words = l.key_words,
            .hash_mask = l.hash_len - 1,
            .trans = u32s.at(memory, l.trans, @as(usize, dfa_cap) * l.stride),
            .keys = u32s.at(memory, l.keys, @as(usize, dfa_cap) * l.key_words),
            .hash = u32s.at(memory, l.hash, l.hash_len),
            .set_a = sets[0..l.words],
            .set_b = sets[l.words .. 2 * l.words],
            .start_closure = sets[2 * l.words ..],
            .stack = u32s.at(memory, l.stack, states),
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
        @memset(self.hash, 0);
        self.start_cache = @splat(trans_uncomputed);
    }

    /// Point the scratch at `program`, dropping a DFA cached for another one.
    fn bind(self: *Scratch, program: *const Program) MatchError!void {
        if (program.state_count > self.capacity.states or program.class_count > self.capacity.classes)
            return error.ScratchTooSmall;
        if (self.bound_ptr == @intFromPtr(program.blob.ptr) and self.bound_len == program.blob.len and
            self.bound_checksum == program.checksum) return;
        self.resetDfa();
        self.bound_ptr = @intFromPtr(program.blob.ptr);
        self.bound_len = program.blob.len;
        self.bound_checksum = program.checksum;
        self.bound_words = (program.state_count + 31) / 32;
        // The epsilon closure of the start state seeds every DFA start state
        // and is re-added after each byte by the unanchored search DFA.
        const closure = self.start_closure[0..self.bound_words];
        @memset(closure, 0);
        bitSet(closure, program.start);
        _ = self.closeOver(program, closure, 0);
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
    fn closeOver(self: *Scratch, program: *const Program, set: []u32, held: u8) u64 {
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
            const range = program.edgeRange(state);
            var e = range.first;
            while (e < range.first + range.count) : (e += 1) {
                const op = program.edgeOp(e);
                const kind: u8 = @truncate(op);
                const follow = switch (kind) {
                    edge_epsilon => true,
                    edge_assert => held & (@as(u8, 1) << @intCast(op >> 8)) != 0,
                    else => false,
                };
                if (!follow) continue;
                const to = program.edgeTarget(e);
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

    fn keyOf(self: *const Scratch, index: u32) []u32 {
        const base = @as(usize, index) * self.key_words;
        return self.keys[base..][0 .. self.bound_words + 1];
    }

    fn hashKey(set: []const u32, tag: u32) u32 {
        var h: u32 = 2166136261;
        for (set) |w| h = (h ^ w) *% 16777619;
        h = (h ^ tag) *% 16777619;
        return h ^ (h >> 15);
    }

    /// The DFA state for (`set`, `tag`), created when new.
    fn intern(self: *Scratch, set: []const u32, tag: u32) DfaError!u32 {
        var slot = hashKey(set, tag) & self.hash_mask;
        while (true) : (slot = (slot + 1) & self.hash_mask) {
            const entry = self.hash[slot];
            if (entry == 0) break;
            const key = self.keyOf(entry - 1);
            if (key[set.len] == tag and std.mem.eql(u32, key[0..set.len], set)) return entry - 1;
        }
        if (self.dfa_len == self.dfa_cap) return error.DfaFull;
        const index = self.dfa_len;
        self.dfa_len += 1;
        const key = self.keyOf(index);
        @memcpy(key[0..set.len], set);
        key[set.len] = tag;
        @memset(self.trans[@as(usize, index) * self.stride ..][0..self.stride], trans_uncomputed);
        self.hash[slot] = index + 1;
        return index;
    }

    fn startState(self: *Scratch, mode: u32, ctx: u8) DfaError!u32 {
        const slot = mode * 8 + ctx;
        if (self.start_cache[slot] != trans_uncomputed) return self.start_cache[slot];
        const index = try self.intern(self.start_closure[0..self.bound_words], (mode << 8) | ctx);
        self.start_cache[slot] = index;
        return index;
    }

    /// Compute the transition of DFA state `index` on symbol `sym`.
    fn computeTransition(self: *Scratch, program: *const Program, index: u32, sym: u32) DfaError!u32 {
        const words = self.bound_words;
        const key = self.keyOf(index);
        const tag = key[words];
        const ctx: u8 = @truncate(tag);
        const mode = tag >> 8;
        const current = self.set_a[0..words];
        @memcpy(current, key[0..words]);
        var work = self.closeOver(program, current, program.assertionsHolding(ctx, sym));

        var accept = false;
        for (current, 0..) |word, wi| {
            var w = word;
            while (w != 0) : (w &= w - 1) {
                if (program.isAccepting(@intCast(wi * 32 + @ctz(w)))) {
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
                const range = program.edgeRange(state);
                var e = range.first;
                while (e < range.first + range.count) : (e += 1) {
                    const op = program.edgeOp(e);
                    if (@as(u8, @truncate(op)) != edge_bytes) continue;
                    if (!program.setHas(op >> 8, b)) continue;
                    bitSet(next, program.edgeTarget(e));
                    any = true;
                }
            }
        }
        if (any) work += self.closeOver(program, next, 0);
        try self.charge(work);
        if (mode == mode_unanchored) {
            for (next, self.start_closure[0..words]) |*w, s| w.* |= s;
            any = true;
        }
        if (!any) return trans_dead | accept_bit;
        const target = try self.intern(next, (mode << 8) | program.contextAfter(b));
        return target | accept_bit;
    }

    inline fn transition(self: *Scratch, program: *const Program, index: u32, sym: u32) DfaError!u32 {
        const slot = @as(usize, index) * self.stride + sym;
        const cached = self.trans[slot];
        if (cached != trans_uncomputed) return cached;
        const computed = try self.computeTransition(program, index, sym);
        self.trans[slot] = computed;
        return computed;
    }

    /// The smallest end of any match starting at or after `from`, or null.
    fn dfaEarliestEnd(self: *Scratch, program: *const Program, input: []const u8, from: usize) DfaError!?usize {
        var state = try self.startState(mode_unanchored, program.contextAt(input, from));
        const classes = program.classes;
        const stride = self.stride;
        // Without assertions, the unanchored start state loops to itself on
        // every byte that cannot start a match, so a run of such bytes is
        // skipped with a byte search instead of one transition per byte.
        const skip_state: u32 = if (program.first_bytes != null and program.ctx_mask == 0) state else trans_uncomputed;
        // The budget caps how far this scan may read, so the loop itself pays
        // nothing for it. Bytes before `counted` are already in `steps`.
        var limit = from + @min(input.len - from, self.allowance());
        var counted = from;
        var i = from;
        while (i < limit) : (i += 1) {
            if (state == skip_state) {
                i = program.nextCandidate(input[0..limit], i);
                if (i == limit) break;
            }
            var t = self.trans[@as(usize, state) * stride + classes[input[i]]];
            if (t >= trans_accept) {
                if (t == trans_uncomputed) {
                    self.steps += i - counted;
                    counted = i;
                    t = try self.computeTransition(program, state, classes[input[i]]);
                    self.trans[@as(usize, state) * stride + classes[input[i]]] = t;
                    limit = i + @min(input.len - i, self.allowance());
                }
                if (t & trans_accept != 0) return self.scanned(i - counted, i);
                if (t & trans_dead != 0) return self.scanned(i + 1 - counted, null);
            }
            state = t;
        }
        self.steps += limit - counted;
        if (limit < input.len) return error.BudgetExceeded;
        const t = try self.transition(program, state, program.class_count);
        return if (t & trans_accept != 0) input.len else null;
    }

    /// Account for `n` bytes a DFA scan read (already within its allowance).
    inline fn scanned(self: *Scratch, n: usize, result: ?usize) ?usize {
        self.steps += n;
        return result;
    }

    /// The end of the longest match starting exactly at `start`, or null.
    fn dfaLongest(self: *Scratch, program: *const Program, input: []const u8, start: usize) DfaError!?usize {
        var state = try self.startState(mode_anchored, program.contextAt(input, start));
        const classes = program.classes;
        const stride = self.stride;
        var limit = start + @min(input.len - start, self.allowance());
        var counted = start;
        var last: ?usize = null;
        var i = start;
        while (i < limit) : (i += 1) {
            var t = self.trans[@as(usize, state) * stride + classes[input[i]]];
            if (t >= trans_accept) {
                if (t == trans_uncomputed) {
                    self.steps += i - counted;
                    counted = i;
                    t = try self.computeTransition(program, state, classes[input[i]]);
                    self.trans[@as(usize, state) * stride + classes[input[i]]] = t;
                    limit = i + @min(input.len - i, self.allowance());
                }
                if (t & trans_accept != 0) last = i;
                if (t & trans_dead != 0) return self.scanned(i + 1 - counted, last);
            }
            state = t & trans_index;
        }
        self.steps += limit - counted;
        if (limit < input.len) return error.BudgetExceeded;
        const t = try self.transition(program, state, program.class_count);
        if (t & trans_accept != 0) last = input.len;
        return last;
    }

    /// Leftmost-longest search on the DFA: the unanchored DFA finds the
    /// earliest end of any match, then anchored runs from each candidate start
    /// find the leftmost one. That start is at most the earliest end, and for
    /// a bounded pattern at least the earliest end minus the longest match.
    fn dfaFind(self: *Scratch, program: *const Program, input: []const u8, from: usize) DfaError!?Span {
        const earliest = (try self.dfaEarliestEnd(program, input, from)) orelse return null;
        // A match ending at `earliest` starts within `max_len` bytes of it,
        // and no match starts before that one: it would end earlier.
        var start = from;
        if (program.max_len) |len| {
            if (earliest - from > len) start = earliest - len;
        }
        while (start <= input.len) : (start += 1) {
            if (program.first_bytes != null) {
                const candidate = program.nextCandidate(input, start);
                try self.charge(candidate - start);
                start = candidate;
                if (start == input.len) return null;
            }
            if (try self.dfaLongest(program, input, start)) |end| return .{ .start = start, .end = end };
        }
        return null;
    }

    // -- NFA simulation -------------------------------------------------------

    /// Add `state` and its closure at `pos` to `list`, all with `start`. A
    /// state already present keeps the earlier thread: lists are ordered by
    /// start, so the first arrival has the smaller start.
    fn addThread(self: *Scratch, program: *const Program, list: *ThreadList, state: u32, start: u64, input: []const u8, pos: usize) error{BudgetExceeded}!void {
        if (list.contains(state)) return;
        list.add(state, start);
        var top: usize = 1;
        self.stack[0] = state;
        while (top > 0) {
            top -= 1;
            try self.charge(1);
            const s = self.stack[top];
            const range = program.edgeRange(s);
            var e = range.first;
            while (e < range.first + range.count) : (e += 1) {
                const op = program.edgeOp(e);
                const follow = switch (@as(u8, @truncate(op))) {
                    edge_epsilon => true,
                    edge_assert => program.assertionAt(@fromBackingInt(@intCast(op >> 8)), input, pos),
                    else => false,
                };
                if (!follow) continue;
                const to = program.edgeTarget(e);
                if (list.contains(to)) continue;
                list.add(to, start);
                self.stack[top] = to;
                top += 1;
            }
        }
    }

    /// Leftmost-longest search by NFA simulation in one pass: each thread
    /// remembers where its match started, and once a match is known no later
    /// start is seeded. With `first_only`, any match ends the search.
    fn nfaFind(self: *Scratch, program: *const Program, input: []const u8, from: usize, first_only: bool) error{BudgetExceeded}!?Span {
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
                if (!program.isAccepting(current.ids[k])) continue;
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
                const range = program.edgeRange(state);
                var e = range.first;
                while (e < range.first + range.count) : (e += 1) {
                    const op = program.edgeOp(e);
                    if (@as(u8, @truncate(op)) != edge_bytes) continue;
                    if (!program.setHas(op >> 8, b)) continue;
                    try self.addThread(program, next, program.edgeTarget(e), current.starts[k], input, pos + 1);
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

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Program);
    std.testing.refAllDecls(Scratch);
}
