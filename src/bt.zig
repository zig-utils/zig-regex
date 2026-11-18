//! Bounded-backtracking programs: serialisable, allocation-free matching for
//! the patterns a Thompson `Program` cannot run.
//!
//! A `Program` (in `program.zig`) is linear-time but only covers regular
//! patterns. Backreferences, lookahead and lookbehind, atomic groups that
//! do not reduce to a plain group, and counted repeats too large to unroll
//! need a backtracking matcher. This module compiles them into a flat,
//! relocatable byte-code blob in the same spirit as `Program`:
//!
//! - one immutable, little-endian, checksummed blob, offsets instead of
//!   pointers, loadable in place (`load`) from borrowed memory after
//!   validating every index the matcher reads;
//! - a `Scratch` sized once, holding the capture slots, the loop counters
//!   and a fixed-capacity backtrack stack, so matching never allocates;
//! - an explicit stack and no recursion anywhere in the matcher;
//! - a per-search step budget (`Scratch.step_budget`, finite by default)
//!   that ends a search with `error.BudgetExceeded`, and a stack that ends
//!   one with `error.StackExhausted` when it is full. Neither is ever a "no
//!   match".
//!
//! Matching is PCRE's: the leftmost match, the first a backtracking engine
//! finds trying alternatives in order and honouring greedy, lazy and
//! possessive-by-atomicity choices. Counted repeats `x{m,n}` keep a counter
//! instead of `n` copies, so `x{50000,}` is a few instructions. A repeat of
//! a group stops when an iteration matches the empty string, as PCRE does.
//! Lookbehind bodies must have a bounded length (at most 65,535 bytes).
//!
//! Byte mode only (`CompileFlags.bytes`); ECMAScript mode, Unicode property
//! escapes and UTF-8 code-point classes return `error.UnsupportedByProgram`.
//! Results are spans (no capture groups).

const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");
const program = @import("program.zig");
const regex_mod = @import("regex.zig");

pub const Span = program.Span;
pub const LoadError = program.LoadError;

pub const BuildError = error{
    /// A construct this form does not support (see the module docs).
    UnsupportedByProgram,
    /// More instructions, counters or capture slots than a program holds.
    ProgramTooLarge,
    OutOfMemory,
};

pub const MatchError = error{
    /// The scratch was sized for smaller programs than this one.
    ScratchTooSmall,
    /// The search used up `Scratch.step_budget` before it could decide.
    BudgetExceeded,
    /// The backtrack stack filled before the search could decide.
    StackExhausted,
};

/// The magic bytes every backtracking-program blob starts with.
pub const magic = "ZRXB";
/// The blob layout version this build writes and reads.
pub const format_version: u16 = 1;

/// The step budget a scratch starts with: as `Regex`'s backtracker.
pub const default_step_budget: u64 = 10_000_000;
/// The backtrack stack a `Capacity` gets unless it names one (frames of 24
/// bytes, so 384 KiB).
pub const default_frames: u32 = 16 * 1024;

const max_instructions: u32 = 1 << 20;
const max_counters: u32 = 1 << 16;
const max_slots: u32 = 1 << 16;
const max_lookbehind: u32 = 65_535;
const unbounded: u32 = 0xFFFF_FFFF;
const unset: u64 = std.math.maxInt(u64);

// ---------------------------------------------------------------------------
// Instructions
//
// 20 bytes each: op u8, flags u8, two zero bytes, then a, b, c, d (u32).
//
//   set        a = byte set              consume one byte of the set
//   rep        a = set, b = min, c = max (unbounded = 0xFFFFFFFF),
//              flag lazy                 a run of bytes of the set
//   split      a, b                      try a, then b
//   jmp        a
//   save       a = slot                  slot = position
//   close      a = group                 the group's start = its pending
//                                        start (slot 3a+2), end = position
//   backref    a = group (slots 3a, 3a+1), flag fold
//   assert     a = Assertion, flag multiline
//   cinit      a = counter               count = 0, iteration start unset
//   cloop      a = counter, b = min, c = max, d = exit, flag lazy
//   cstart     a = counter               iteration start = position
//   cnext      a = counter, b = cloop pc count += 1, back to the loop
//   look       a = continuation, b = min, c = max (lookbehind lengths),
//              flags negate, behind      body follows, ends at look_end
//   look_end   a = look pc
//   atomic                               body follows, ends at atomic_end
//   atomic_end a = atomic pc
//   match

const Op = enum(u8) {
    set = 1,
    rep = 2,
    split = 3,
    jmp = 4,
    save = 5,
    backref = 6,
    assert = 7,
    cinit = 8,
    cloop = 9,
    cstart = 10,
    cnext = 11,
    look = 12,
    look_end = 13,
    atomic = 14,
    atomic_end = 15,
    match = 16,
    close = 17,
};

const flag_lazy: u8 = 1;
const flag_fold: u8 = 1;
const flag_multiline: u8 = 1;
const flag_negate: u8 = 1;
const flag_behind: u8 = 2;

const Inst = struct {
    op: Op,
    flags: u8 = 0,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    d: u32 = 0,
};

const inst_record: usize = 20;
const set_record: usize = 32;
const header_size: usize = 64;

// Header: 0 magic, 4 version u16, 6 header size u16, 8 total u32, 12 flags
// u32, 16 instruction count, 20 set count, 24 slot count, 28 counter count,
// 32 instructions offset, 36 sets offset, 40 first-byte set offset (0 when
// absent), 44 CRC-32 of the blob with this field zeroed, 48..64 zero.
const off_total = 8;
const off_flags = 12;
const off_insts_count = 16;
const off_sets_count = 20;
const off_slots = 24;
const off_counters = 28;
const off_insts = 32;
const off_sets = 36;
const off_first = 40;
const off_checksum = 44;
const off_reserved = 48;

const bf_first_bytes: u32 = 1 << 0;
const bf_known: u32 = (1 << 1) - 1;

inline fn readU32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

inline fn writeU32(buf: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], value, .little);
}

inline fn setHas(set: *const [32]u8, b: u8) bool {
    return (set[b >> 3] >> @intCast(b & 7)) & 1 != 0;
}

inline fn setAdd(set: *[32]u8, b: u8) void {
    set[b >> 3] |= @as(u8, 1) << @intCast(b & 7);
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

// ---------------------------------------------------------------------------
// Program

/// A compiled backtracking program: a view over its blob.
pub const Program = struct {
    blob: []const u8,
    owned: bool,
    inst_count: u32,
    set_count: u32,
    slot_count: u32,
    counter_count: u32,
    insts: []const u8,
    sets: []const u8,
    first_bytes: ?*const [32]u8,
    /// The only byte a match can start with, when there is exactly one.
    first_byte: ?u8,
    checksum: u32,

    /// Compile `pattern` (byte mode, see the module docs).
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags: common.CompileFlags) !Program {
        if (!flags.bytes or flags.ecmascript) return error.UnsupportedByProgram;
        var tree = try regex_mod.parseTree(allocator, pattern, flags, null);
        defer tree.deinit();
        const blob = try build(allocator, &tree, flags);
        var p = view(blob);
        p.owned = true;
        return p;
    }

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.blob);
        self.* = undefined;
    }

    /// The serialised program (see `load`).
    pub fn bytes(self: *const Program) []const u8 {
        return self.blob;
    }

    /// A program over serialised bytes, borrowed without copying, after
    /// validating everything matching reads: header, layout, checksum, every
    /// instruction's opcode, jump targets, set, slot and counter indices, and
    /// the pairing of `look_end`/`atomic_end` with their openers.
    pub fn load(blob: []const u8) LoadError!Program {
        return view(try validate(blob));
    }

    pub fn dupe(self: *const Program, allocator: std.mem.Allocator) error{OutOfMemory}!Program {
        var copy = view(try allocator.dupe(u8, self.blob));
        copy.owned = true;
        return copy;
    }

    /// The sizes a scratch needs for this program, with the default stack.
    pub fn capacity(self: *const Program) Capacity {
        return .{ .slots = self.slot_count, .counters = self.counter_count };
    }

    pub fn isMatch(self: *const Program, scratch: *Scratch, input: []const u8) MatchError!bool {
        return (try self.findFrom(scratch, input, 0)) != null;
    }

    pub fn find(self: *const Program, scratch: *Scratch, input: []const u8) MatchError!?Span {
        return self.findFrom(scratch, input, 0);
    }

    /// The leftmost match starting at or after `start`; assertions and
    /// lookbehind see the whole input.
    pub fn findFrom(self: *const Program, scratch: *Scratch, input: []const u8, start: usize) MatchError!?Span {
        if (self.slot_count > scratch.capacity.slots or self.counter_count > scratch.capacity.counters)
            return error.ScratchTooSmall;
        scratch.steps = 0;
        if (start > input.len) return null;
        var pos = start;
        while (pos <= input.len) {
            if (self.first_bytes) |fb| {
                // Skip to a byte a match can start with, reading no further
                // than the budget allows.
                const from = pos;
                const limit = pos + @min(input.len - pos, scratch.step_budget - scratch.steps);
                if (self.first_byte) |b| {
                    pos = std.mem.indexOfScalarPos(u8, input[0..limit], pos, b) orelse limit;
                } else while (pos < limit and !setHas(fb, input[pos])) pos += 1;
                scratch.steps += pos - from;
                if (pos == limit and limit < input.len) return error.BudgetExceeded;
                if (pos == input.len) return null;
            }
            if (try scratch.run(self, input, pos)) |end| return .{ .start = pos, .end = end };
            pos += 1;
        }
        return null;
    }

    pub fn iterator(self: *const Program, scratch: *Scratch, input: []const u8) Iterator {
        return .{ .program = self, .scratch = scratch, .input = input };
    }

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

    pub fn count(self: *const Program, scratch: *Scratch, input: []const u8) MatchError!usize {
        var it = self.iterator(scratch, input);
        var n: usize = 0;
        while (try it.next()) |_| n += 1;
        return n;
    }

    /// Successive non-overlapping matches; after an empty match the next
    /// search starts one byte later.
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

    inline fn inst(self: *const Program, pc: u32) Inst {
        return decodeInst(self.insts[@as(usize, pc) * inst_record ..][0..inst_record]);
    }

    inline fn set(self: *const Program, index: u32) *const [32]u8 {
        return self.sets[@as(usize, index) * set_record ..][0..32];
    }
};

fn decodeInst(rec: *const [inst_record]u8) Inst {
    return .{
        .op = @fromBackingInt(@intCast(rec[0])),
        .flags = rec[1],
        .a = readU32(rec, 4),
        .b = readU32(rec, 8),
        .c = readU32(rec, 12),
        .d = readU32(rec, 16),
    };
}

fn view(blob: []const u8) Program {
    const flags = readU32(blob, off_flags);
    const inst_count = readU32(blob, off_insts_count);
    const set_count = readU32(blob, off_sets_count);
    var p: Program = .{
        .blob = blob,
        .owned = false,
        .inst_count = inst_count,
        .set_count = set_count,
        .slot_count = readU32(blob, off_slots),
        .counter_count = readU32(blob, off_counters),
        .insts = blob[readU32(blob, off_insts)..][0 .. @as(usize, inst_count) * inst_record],
        .sets = blob[readU32(blob, off_sets)..][0 .. @as(usize, set_count) * set_record],
        .first_bytes = if (flags & bf_first_bytes != 0) blob[readU32(blob, off_first)..][0..32] else null,
        .first_byte = null,
        .checksum = readU32(blob, off_checksum),
    };
    if (p.first_bytes) |fb| {
        var members: usize = 0;
        for (fb) |byte| members += @popCount(byte);
        if (members == 1) for (fb, 0..) |byte, k| {
            if (byte != 0) p.first_byte = @intCast(k * 8 + @ctz(byte));
        };
    }
    return p;
}

fn validate(input: []const u8) LoadError![]const u8 {
    if (input.len < 8) return error.Truncated;
    if (!std.mem.eql(u8, input[0..4], magic)) return error.BadMagic;
    if (std.mem.readInt(u16, input[4..6], .little) != format_version) return error.UnsupportedVersion;
    if (input.len < header_size) return error.Truncated;
    if (std.mem.readInt(u16, input[6..8], .little) != header_size) return error.InvalidProgram;
    const total = readU32(input, off_total);
    if (total < header_size) return error.InvalidProgram;
    if (total > input.len) return error.Truncated;
    const blob = input[0..total];
    if (readU32(blob, off_checksum) != checksumOf(blob)) return error.ChecksumMismatch;
    const flags = readU32(blob, off_flags);
    if (flags & ~bf_known != 0) return error.InvalidProgram;
    if (!std.mem.allEqual(u8, blob[off_reserved..header_size], 0)) return error.InvalidProgram;
    const inst_count: u64 = readU32(blob, off_insts_count);
    const set_count: u64 = readU32(blob, off_sets_count);
    const slot_count = readU32(blob, off_slots);
    const counter_count = readU32(blob, off_counters);
    if (inst_count == 0 or inst_count > max_instructions or slot_count > max_slots or counter_count > max_counters)
        return error.InvalidProgram;
    const insts_off: u64 = header_size;
    const sets_off = insts_off + inst_count * inst_record;
    const has_first = flags & bf_first_bytes != 0;
    const first_off: u64 = if (has_first) sets_off + set_count * set_record else 0;
    const expected = sets_off + set_count * set_record + @as(u64, if (has_first) 32 else 0);
    if (readU32(blob, off_insts) != insts_off or readU32(blob, off_sets) != sets_off or
        readU32(blob, off_first) != first_off or total != expected)
        return error.InvalidProgram;

    const insts = blob[@intCast(insts_off)..@intCast(sets_off)];
    const n: u32 = @intCast(inst_count);
    var pc: u32 = 0;
    while (pc < n) : (pc += 1) {
        const rec = insts[@as(usize, pc) * inst_record ..][0..inst_record];
        if (rec[2] != 0 or rec[3] != 0) return error.InvalidProgram;
        const op = std.enums.fromInt(Op, rec[0]) orelse return error.InvalidProgram;
        const i = decodeInst(rec);
        // Every instruction that falls through needs a next one; the last
        // must be `match`.
        if (pc == n - 1 and op != .match) return error.InvalidProgram;
        switch (op) {
            .set => if (i.a >= set_count) return error.InvalidProgram,
            .rep => if (i.a >= set_count or (i.c != unbounded and i.b > i.c)) return error.InvalidProgram,
            .split => if (i.a >= n or i.b >= n) return error.InvalidProgram,
            .jmp => if (i.a >= n) return error.InvalidProgram,
            .save => if (i.a >= slot_count) return error.InvalidProgram,
            .backref, .close => if (@as(u64, i.a) * 3 + 2 >= slot_count) return error.InvalidProgram,
            .assert => if (i.a > @backingInt(program.Assertion.non_word_boundary)) return error.InvalidProgram,
            .cinit, .cstart => if (i.a >= counter_count) return error.InvalidProgram,
            .cloop => if (i.a >= counter_count or i.d >= n or (i.c != unbounded and i.b > i.c)) return error.InvalidProgram,
            .cnext => if (i.a >= counter_count or i.b >= n) return error.InvalidProgram,
            .look => if (i.a >= n or i.b > i.c or i.c > max_lookbehind) return error.InvalidProgram,
            .look_end => if (i.a >= n or insts[@as(usize, i.a) * inst_record] != @backingInt(Op.look)) return error.InvalidProgram,
            .atomic, .match => {},
            .atomic_end => if (i.a >= n or insts[@as(usize, i.a) * inst_record] != @backingInt(Op.atomic)) return error.InvalidProgram,
        }
    }
    return blob;
}

// ---------------------------------------------------------------------------
// Compiling

const Builder = struct {
    allocator: std.mem.Allocator,
    flags: common.CompileFlags,
    insts: std.ArrayList(Inst) = .empty,
    sets: std.ArrayList([32]u8) = .empty,
    set_ids: std.AutoHashMapUnmanaged([32]u8, u32) = .empty,
    /// Capture index (1-based) to slot pair, for groups a backreference uses.
    pairs: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    names: std.StringHashMapUnmanaged(usize) = .empty,
    counters: u32 = 0,
    modes: Modes,

    const Modes = struct { i: bool, m: bool, s: bool };

    fn deinit(self: *Builder) void {
        self.insts.deinit(self.allocator);
        self.sets.deinit(self.allocator);
        self.set_ids.deinit(self.allocator);
        self.pairs.deinit(self.allocator);
        self.names.deinit(self.allocator);
    }

    fn emit(self: *Builder, i: Inst) !u32 {
        if (self.insts.items.len >= max_instructions - 1) return error.ProgramTooLarge;
        try self.insts.append(self.allocator, i);
        return @intCast(self.insts.items.len - 1);
    }

    fn pc(self: *const Builder) u32 {
        return @intCast(self.insts.items.len);
    }

    fn setId(self: *Builder, s: [32]u8) !u32 {
        const entry = try self.set_ids.getOrPut(self.allocator, s);
        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(self.sets.items.len);
            try self.sets.append(self.allocator, s);
        }
        return entry.value_ptr.*;
    }

    /// The bytes a single-byte atom accepts under the current modes, or null
    /// for any other node.
    fn atomSet(self: *const Builder, node: *ast.Node) ?[32]u8 {
        var s: [32]u8 = @splat(0);
        switch (node.node_type) {
            .literal => {
                const c = node.data.literal;
                setAdd(&s, c);
                if (self.modes.i and std.ascii.isAlphabetic(c)) {
                    setAdd(&s, std.ascii.toLower(c));
                    setAdd(&s, std.ascii.toUpper(c));
                }
            },
            .char_class => {
                const cc = node.data.char_class;
                for (0..256) |b| {
                    const byte: u8 = @intCast(b);
                    if (if (self.modes.i) cc.matchesCI(byte) else cc.matches(byte)) setAdd(&s, byte);
                }
            },
            .any => for (0..256) |b| {
                if (self.modes.s or b != '\n') setAdd(&s, @intCast(b));
            },
            else => return null,
        }
        return s;
    }

    /// Give every group a backreference names its slot pair.
    fn collectBackrefs(self: *Builder, root: *ast.Node) !void {
        var stack: std.ArrayList(*ast.Node) = .empty;
        defer stack.deinit(self.allocator);
        // Names first, so a reference before its group resolves.
        try stack.append(self.allocator, root);
        while (stack.pop()) |node| {
            if (node.node_type == .group) {
                const g = node.data.group;
                if (g.name) |name| if (g.capture_index) |index| {
                    const entry = try self.names.getOrPut(self.allocator, name);
                    if (!entry.found_existing) entry.value_ptr.* = index;
                };
            }
            try pushChildren(self.allocator, &stack, node);
        }
        try stack.append(self.allocator, root);
        while (stack.pop()) |node| {
            if (node.node_type == .backref) {
                const index = try self.resolve(node.data.backref);
                const entry = try self.pairs.getOrPut(self.allocator, index);
                if (!entry.found_existing) {
                    if (self.pairs.count() * 3 > max_slots) return error.ProgramTooLarge;
                    entry.value_ptr.* = @intCast(self.pairs.count() - 1);
                }
            }
            try pushChildren(self.allocator, &stack, node);
        }
    }

    fn resolve(self: *const Builder, backref: ast.Node.Backreference) !usize {
        if (backref.name) |name| return self.names.get(name) orelse error.UnsupportedByProgram;
        if (backref.index == 0) return error.UnsupportedByProgram;
        return backref.index;
    }

    fn compileNode(self: *Builder, root: *ast.Node) BuildError!void {
        var node = root;
        // Sequences are walked along their spine (no recursion per element).
        while (node.node_type == .concat) {
            const step = ast.spine(node);
            try self.compileNode(step.side);
            node = step.next;
        }
        switch (node.node_type) {
            .concat => unreachable,
            .literal, .char_class, .any => _ = try self.emit(.{ .op = .set, .a = try self.setId(self.atomSet(node).?) }),
            .empty => {},
            .anchor => {
                const a: program.Assertion = switch (node.data.anchor) {
                    .start_line => .start_line,
                    .end_line => .end_line,
                    .start_text => .start_text,
                    .end_text => .end_text,
                    .word_boundary => .word_boundary,
                    .non_word_boundary => .non_word_boundary,
                };
                _ = try self.emit(.{ .op = .assert, .a = @backingInt(a), .flags = if (self.modes.m) flag_multiline else 0 });
            },
            .alternation => try self.compileAlternation(node),
            .group => {
                const g = node.data.group;
                const saved = self.modes;
                defer self.modes = saved;
                if (g.mod) |mod| {
                    if (mod.i) |on| self.modes.i = on;
                    if (mod.m) |on| self.modes.m = on;
                    if (mod.s) |on| self.modes.s = on;
                }
                const pair: ?u32 = if (g.capture_index) |index| self.pairs.get(index) else null;
                // The start waits in a pending slot until the group closes:
                // a backreference inside the group (`(a|b\1)+`) still sees
                // the previous iteration's capture, as in PCRE.
                if (pair) |p| _ = try self.emit(.{ .op = .save, .a = 3 * p + 2 });
                if (g.atomic) {
                    const open = try self.emit(.{ .op = .atomic });
                    try self.compileNode(g.child);
                    _ = try self.emit(.{ .op = .atomic_end, .a = open });
                } else try self.compileNode(g.child);
                if (pair) |p| _ = try self.emit(.{ .op = .close, .a = p });
            },
            .star, .plus, .optional, .repeat => {
                const child = ast.onlyChild(node).?;
                const min: usize, const max: ?usize, const greedy: bool = switch (node.node_type) {
                    .star => .{ 0, null, node.data.star.greedy },
                    .plus => .{ 1, null, node.data.plus.greedy },
                    .optional => .{ 0, 1, node.data.optional.greedy },
                    .repeat => .{ node.data.repeat.bounds.min, node.data.repeat.bounds.max, node.data.repeat.greedy },
                    else => unreachable,
                };
                try self.compileRepeat(child, min, max, greedy);
            },
            .lookahead, .lookbehind => {
                const a = if (node.node_type == .lookahead) node.data.lookahead else node.data.lookbehind;
                var flags: u8 = if (a.positive) 0 else flag_negate;
                var lo: u32 = 0;
                var hi: u32 = 0;
                if (node.node_type == .lookbehind) {
                    flags |= flag_behind;
                    const len = lengthRange(a.child) orelse return error.UnsupportedByProgram;
                    if (len.max > max_lookbehind) return error.UnsupportedByProgram;
                    lo = @intCast(len.min);
                    hi = @intCast(len.max);
                }
                const open = try self.emit(.{ .op = .look, .flags = flags, .b = lo, .c = hi });
                try self.compileNode(a.child);
                _ = try self.emit(.{ .op = .look_end, .a = open });
                self.insts.items[open].a = self.pc();
            },
            .backref => {
                const index = try self.resolve(node.data.backref);
                _ = try self.emit(.{ .op = .backref, .a = self.pairs.get(index).?, .flags = if (self.modes.i) flag_fold else 0 });
            },
            .class_set, .unicode_property => return error.UnsupportedByProgram,
        }
    }

    fn compileAlternation(self: *Builder, root: *ast.Node) BuildError!void {
        // The branches in source order: the parser nests alternations to
        // the left, so collect the spine first.
        var branches: std.ArrayList(*ast.Node) = .empty;
        defer branches.deinit(self.allocator);
        var node = root;
        while (node.node_type == .alternation) {
            try branches.append(self.allocator, node.data.alternation.right);
            node = node.data.alternation.left;
        }
        try branches.append(self.allocator, node);
        std.mem.reverse(*ast.Node, branches.items);
        var exits: std.ArrayList(u32) = .empty;
        defer exits.deinit(self.allocator);
        for (branches.items, 0..) |branch, k| {
            if (k + 1 < branches.items.len) {
                const split = try self.emit(.{ .op = .split });
                self.insts.items[split].a = self.pc();
                try self.compileNode(branch);
                try exits.append(self.allocator, try self.emit(.{ .op = .jmp }));
                self.insts.items[split].b = self.pc();
            } else try self.compileNode(branch);
        }
        for (exits.items) |j| self.insts.items[j].a = self.pc();
    }

    fn compileRepeat(self: *Builder, child: *ast.Node, min: usize, max: ?usize, greedy: bool) BuildError!void {
        if (max) |m| if (m == 0) return;
        if (min > unbounded - 1) return error.ProgramTooLarge;
        if (max) |m| if (m > unbounded - 1) return error.ProgramTooLarge;
        const lazy: u8 = if (greedy) 0 else flag_lazy;
        if (self.atomSet(child)) |s| {
            _ = try self.emit(.{ .op = .rep, .flags = lazy, .a = try self.setId(s), .b = @intCast(min), .c = if (max) |m| @intCast(m) else unbounded });
            return;
        }
        if (min == 1 and max != null and max.? == 1) return self.compileNode(child);
        if (min == 0 and max != null and max.? == 1) {
            const split = try self.emit(.{ .op = .split });
            const body = self.pc();
            try self.compileNode(child);
            const after = self.pc();
            self.insts.items[split].a = if (greedy) body else after;
            self.insts.items[split].b = if (greedy) after else body;
            return;
        }
        if (self.counters == max_counters) return error.ProgramTooLarge;
        const c = self.counters;
        self.counters += 1;
        _ = try self.emit(.{ .op = .cinit, .a = c });
        const loop = try self.emit(.{ .op = .cloop, .flags = lazy, .a = c, .b = @intCast(min), .c = if (max) |m| @intCast(m) else unbounded });
        _ = try self.emit(.{ .op = .cstart, .a = c });
        try self.compileNode(child);
        _ = try self.emit(.{ .op = .cnext, .a = c, .b = loop });
        self.insts.items[loop].d = self.pc();
    }
};

fn pushChildren(allocator: std.mem.Allocator, stack: *std.ArrayList(*ast.Node), node: *ast.Node) !void {
    switch (node.node_type) {
        .concat => try stack.appendSlice(allocator, &.{ node.data.concat.right, node.data.concat.left }),
        .alternation => try stack.appendSlice(allocator, &.{ node.data.alternation.right, node.data.alternation.left }),
        else => if (ast.onlyChild(node)) |child| try stack.append(allocator, child),
    }
}

const LengthRange = struct { min: usize, max: usize };

/// The shortest and longest match of `node` in bytes (byte mode), or null
/// when unbounded or unknown (a backreference).
fn lengthRange(node: *ast.Node) ?LengthRange {
    const cap = max_lookbehind + 1;
    switch (node.node_type) {
        .literal, .char_class, .any => return .{ .min = 1, .max = 1 },
        .anchor, .empty, .lookahead, .lookbehind => return .{ .min = 0, .max = 0 },
        .group => return lengthRange(node.data.group.child),
        .concat => {
            var total: LengthRange = .{ .min = 0, .max = 0 };
            var current = node;
            while (true) {
                const part, const next = if (current.node_type == .concat) blk: {
                    const step = ast.spine(current);
                    break :blk .{ step.side, @as(?*ast.Node, step.next) };
                } else .{ current, @as(?*ast.Node, null) };
                const r = lengthRange(part) orelse return null;
                total.min = @min(total.min + r.min, cap);
                total.max = @min(total.max + r.max, cap);
                current = next orelse return total;
            }
        },
        .alternation => {
            var out: ?LengthRange = null;
            var current = node;
            while (true) {
                const part, const next = if (current.node_type == .alternation) blk: {
                    const step = ast.spine(current);
                    break :blk .{ step.side, @as(?*ast.Node, step.next) };
                } else .{ current, @as(?*ast.Node, null) };
                const r = lengthRange(part) orelse return null;
                out = if (out) |o| .{ .min = @min(o.min, r.min), .max = @max(o.max, r.max) } else r;
                current = next orelse return out;
            }
        },
        .star, .plus, .optional, .repeat => {
            const r = lengthRange(ast.onlyChild(node).?) orelse return null;
            const min: usize, const max: ?usize = switch (node.node_type) {
                .star => .{ 0, null },
                .plus => .{ 1, null },
                .optional => .{ 0, 1 },
                .repeat => .{ node.data.repeat.bounds.min, node.data.repeat.bounds.max },
                else => unreachable,
            };
            const hi = max orelse return if (r.max == 0) LengthRange{ .min = 0, .max = 0 } else null;
            return .{ .min = @min(r.min * min, cap), .max = @min(r.max * hi, cap) };
        },
        .backref, .class_set, .unicode_property => return null,
    }
}

fn build(allocator: std.mem.Allocator, tree: *ast.AST, flags: common.CompileFlags) BuildError![]u8 {
    var b = Builder{
        .allocator = allocator,
        .flags = flags,
        .modes = .{ .i = flags.case_insensitive, .m = flags.multiline, .s = flags.dot_all },
    };
    defer b.deinit();
    try b.collectBackrefs(tree.root);
    try b.compileNode(tree.root);
    _ = try b.emit(.{ .op = .match });
    const first = try firstBytes(allocator, b.insts.items, b.sets.items);

    const n = b.insts.items.len;
    const sets_off = header_size + n * inst_record;
    const first_off = sets_off + b.sets.items.len * set_record;
    const total = first_off + if (first != null) @as(usize, 32) else 0;
    if (total > std.math.maxInt(u32)) return error.ProgramTooLarge;
    const blob = try allocator.alloc(u8, total);
    errdefer allocator.free(blob);
    @memset(blob, 0);
    @memcpy(blob[0..4], magic);
    std.mem.writeInt(u16, blob[4..6], format_version, .little);
    std.mem.writeInt(u16, blob[6..8], header_size, .little);
    writeU32(blob, off_total, @intCast(total));
    writeU32(blob, off_flags, if (first != null) bf_first_bytes else 0);
    writeU32(blob, off_insts_count, @intCast(n));
    writeU32(blob, off_sets_count, @intCast(b.sets.items.len));
    writeU32(blob, off_slots, @intCast(b.pairs.count() * 3));
    writeU32(blob, off_counters, b.counters);
    writeU32(blob, off_insts, header_size);
    writeU32(blob, off_sets, @intCast(sets_off));
    writeU32(blob, off_first, if (first != null) @intCast(first_off) else 0);
    for (b.insts.items, 0..) |i, k| {
        const rec = blob[header_size + k * inst_record ..][0..inst_record];
        rec[0] = @backingInt(i.op);
        rec[1] = i.flags;
        writeU32(rec, 4, i.a);
        writeU32(rec, 8, i.b);
        writeU32(rec, 12, i.c);
        writeU32(rec, 16, i.d);
    }
    for (b.sets.items, 0..) |*s, k| @memcpy(blob[sets_off + k * set_record ..][0..32], s);
    if (first) |f| @memcpy(blob[first_off..][0..32], &f);
    writeU32(blob, off_checksum, checksumOf(blob));
    return blob;
}

/// The bytes a match can start with, following the code from its start
/// (assertions and lookarounds taken to pass, which only widens the set),
/// or null when a match can be empty, can start with a backreference, or
/// can start with any byte.
fn firstBytes(allocator: std.mem.Allocator, insts: []const Inst, sets: []const [32]u8) !?[32]u8 {
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(allocator, insts.len);
    defer seen.deinit(allocator);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(allocator);
    var out: [32]u8 = @splat(0);
    try work.append(allocator, 0);
    while (work.pop()) |pc| {
        if (seen.isSet(pc)) continue;
        seen.set(pc);
        const i = insts[pc];
        switch (i.op) {
            .set => for (&out, sets[i.a]) |*o, s| {
                o.* |= s;
            },
            .rep => {
                for (&out, sets[i.a]) |*o, s| o.* |= s;
                if (i.b == 0) try work.append(allocator, pc + 1);
            },
            .split => try work.appendSlice(allocator, &.{ i.a, i.b }),
            .jmp => try work.append(allocator, i.a),
            .save, .close, .assert, .cinit, .cstart, .atomic, .atomic_end, .look_end => try work.append(allocator, pc + 1),
            // The exit is reachable even with a minimum: the body's
            // iterations may all match empty.
            .cloop => try work.appendSlice(allocator, &.{ pc + 1, i.d }),
            .cnext => try work.append(allocator, i.b),
            .look => try work.append(allocator, i.a),
            .backref, .match => return null,
        }
    }
    if (std.mem.allEqual(u8, &out, 0xFF)) return null;
    return out;
}

// ---------------------------------------------------------------------------
// Scratch and matching

/// The sizes a `Scratch` is built for; `max` combines programs.
pub const Capacity = struct {
    slots: u32,
    counters: u32,
    /// Backtrack-stack frames (24 bytes each).
    frames: u32 = default_frames,

    pub fn max(a: Capacity, b: Capacity) Capacity {
        return .{ .slots = @max(a.slots, b.slots), .counters = @max(a.counters, b.counters), .frames = @max(a.frames, b.frames) };
    }
};

const FrameKind = enum(u32) {
    choice,
    undo_slot,
    undo_count,
    undo_start,
    rep_greedy,
    rep_lazy,
    look,
    behind,
    atomic,

    fn isUndo(self: FrameKind) bool {
        return self == .undo_slot or self == .undo_count or self == .undo_start;
    }
};

const Frame = struct {
    kind: FrameKind,
    a: u32,
    b: u64,
    c: u64,
};

const Counter = struct { count: u64, start: u64 };

/// Mutable matching state for one thread: capture slots, counters and the
/// backtrack stack. `bytesNeeded` is exact: 8 S + 16 C + 24 F bytes (S is
/// three slots per backreferenced group).
pub const Scratch = struct {
    capacity: Capacity,
    /// The most steps one search may take; a step is one instruction run,
    /// one byte a repeat, backreference or start-position scan reads, or one
    /// frame popped while backtracking. Exceeding it fails the search with
    /// `error.BudgetExceeded`. It is finite by default: a backtracking
    /// search can take exponential time.
    step_budget: u64 = default_step_budget,
    /// The steps the last search took.
    steps: u64 = 0,
    slots: []u64,
    counters: []Counter,
    frames: []Frame,
    memory: []align(8) u8,
    owns_memory: bool,

    pub fn bytesNeeded(capacity: Capacity) usize {
        return @as(usize, capacity.slots) * 8 + @as(usize, capacity.counters) * @sizeOf(Counter) + @as(usize, capacity.frames) * @sizeOf(Frame);
    }

    pub fn init(allocator: std.mem.Allocator, p: *const Program) !Scratch {
        return initCapacity(allocator, p.capacity());
    }

    pub fn initCapacity(allocator: std.mem.Allocator, capacity: Capacity) !Scratch {
        const memory = try allocator.alignedAlloc(u8, .@"8", bytesNeeded(capacity));
        var s = carve(memory, capacity);
        s.owns_memory = true;
        return s;
    }

    /// A scratch in caller memory; `deinit` must not be called.
    pub fn initBuffer(buffer: []align(8) u8, capacity: Capacity) error{BufferTooSmall}!Scratch {
        if (buffer.len < bytesNeeded(capacity)) return error.BufferTooSmall;
        return carve(buffer, capacity);
    }

    pub fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        std.debug.assert(self.owns_memory);
        allocator.free(self.memory);
        self.* = undefined;
    }

    fn carve(memory: []align(8) u8, capacity: Capacity) Scratch {
        const slots_len = @as(usize, capacity.slots);
        const counters_len = @as(usize, capacity.counters);
        const slots_ptr: [*]u64 = @ptrCast(memory.ptr);
        const counters_ptr: [*]Counter = @ptrCast(@alignCast(memory.ptr + slots_len * 8));
        const frames_ptr: [*]Frame = @ptrCast(@alignCast(memory.ptr + slots_len * 8 + counters_len * @sizeOf(Counter)));
        return .{
            .capacity = capacity,
            .slots = slots_ptr[0..slots_len],
            .counters = counters_ptr[0..counters_len],
            .frames = frames_ptr[0..capacity.frames],
            .memory = memory,
            .owns_memory = false,
        };
    }

    inline fn charge(self: *Scratch, n: u64) error{BudgetExceeded}!void {
        if (n > self.step_budget - self.steps) return error.BudgetExceeded;
        self.steps += n;
    }

    inline fn push(self: *Scratch, sp: *usize, frame: Frame) error{StackExhausted}!void {
        if (sp.* == self.frames.len) return error.StackExhausted;
        self.frames[sp.*] = frame;
        sp.* += 1;
    }

    /// Remove every frame above `marker`, and the marker, except the undo
    /// records, which later backtracking still needs.
    fn cut(self: *Scratch, sp: *usize, marker: usize) void {
        var w = marker;
        for (self.frames[marker + 1 .. sp.*]) |f| {
            if (f.kind.isUndo()) {
                self.frames[w] = f;
                w += 1;
            }
        }
        sp.* = w;
    }

    fn findMarker(self: *const Scratch, sp: usize, kind: FrameKind, pc: u32) ?usize {
        var k = sp;
        while (k > 0) {
            k -= 1;
            if (self.frames[k].kind == kind and self.frames[k].a == pc) return k;
        }
        return null;
    }

    /// The end of the match `p` finds starting exactly at `start`, or null.
    fn run(self: *Scratch, p: *const Program, input: []const u8, start: usize) MatchError!?usize {
        @memset(self.slots[0..p.slot_count], unset);
        var sp: usize = 0;
        var pc: u32 = 0;
        var pos: usize = start;
        while (true) {
            try self.charge(1);
            const i = p.inst(pc);
            const ok: bool = switch (i.op) {
                .set => blk: {
                    if (pos < input.len and setHas(p.set(i.a), input[pos])) {
                        pos += 1;
                        pc += 1;
                        break :blk true;
                    }
                    break :blk false;
                },
                .rep => blk: {
                    const s = p.set(i.a);
                    const max: usize = if (i.c == unbounded) input.len - pos else @min(i.c, input.len - pos);
                    if (i.flags & flag_lazy == 0) {
                        var n: usize = 0;
                        while (n < max and setHas(s, input[pos + n])) n += 1;
                        try self.charge(n);
                        if (n < i.b) break :blk false;
                        if (n > i.b) try self.push(&sp, .{ .kind = .rep_greedy, .a = pc, .b = pos + n, .c = pos + i.b });
                        pos += n;
                    } else {
                        if (i.b > max) break :blk false;
                        var n: usize = 0;
                        while (n < i.b and setHas(s, input[pos + n])) n += 1;
                        try self.charge(n);
                        if (n < i.b) break :blk false;
                        if (max > i.b) try self.push(&sp, .{ .kind = .rep_lazy, .a = pc, .b = pos + i.b, .c = pos + max });
                        pos += i.b;
                    }
                    pc += 1;
                    break :blk true;
                },
                .split => blk: {
                    try self.push(&sp, .{ .kind = .choice, .a = i.b, .b = pos, .c = 0 });
                    pc = i.a;
                    break :blk true;
                },
                .jmp => blk: {
                    pc = i.a;
                    break :blk true;
                },
                .save => blk: {
                    try self.push(&sp, .{ .kind = .undo_slot, .a = i.a, .b = self.slots[i.a], .c = 0 });
                    self.slots[i.a] = pos;
                    pc += 1;
                    break :blk true;
                },
                .close => blk: {
                    const base = 3 * i.a;
                    try self.push(&sp, .{ .kind = .undo_slot, .a = base, .b = self.slots[base], .c = 0 });
                    try self.push(&sp, .{ .kind = .undo_slot, .a = base + 1, .b = self.slots[base + 1], .c = 0 });
                    self.slots[base] = self.slots[base + 2];
                    self.slots[base + 1] = pos;
                    pc += 1;
                    break :blk true;
                },
                .backref => blk: {
                    const s = self.slots[3 * i.a];
                    const e = self.slots[3 * i.a + 1];
                    if (s == unset or e == unset or e < s) break :blk false;
                    const len: usize = @intCast(e - s);
                    if (len > input.len - pos) break :blk false;
                    try self.charge(len);
                    const want = input[@intCast(s)..@intCast(e)];
                    const got = input[pos..][0..len];
                    const same = if (i.flags & flag_fold != 0) std.ascii.eqlIgnoreCase(want, got) else std.mem.eql(u8, want, got);
                    if (!same) break :blk false;
                    pos += len;
                    pc += 1;
                    break :blk true;
                },
                .assert => blk: {
                    if (!assertionAt(@fromBackingInt(@intCast(i.a)), i.flags & flag_multiline != 0, input, pos)) break :blk false;
                    pc += 1;
                    break :blk true;
                },
                .cinit => blk: {
                    const c = &self.counters[i.a];
                    try self.push(&sp, .{ .kind = .undo_count, .a = i.a, .b = c.count, .c = 0 });
                    try self.push(&sp, .{ .kind = .undo_start, .a = i.a, .b = c.start, .c = 0 });
                    c.* = .{ .count = 0, .start = unset };
                    pc += 1;
                    break :blk true;
                },
                .cloop => blk: {
                    const c = self.counters[i.a];
                    // An iteration that matched empty ends the loop once the
                    // minimum is met (PCRE): it could only repeat forever.
                    if (c.count >= i.b and c.start == pos) {
                        pc = i.d;
                    } else if (c.count < i.b) {
                        pc += 1;
                    } else if (i.c != unbounded and c.count >= i.c) {
                        pc = i.d;
                    } else if (i.flags & flag_lazy == 0) {
                        try self.push(&sp, .{ .kind = .choice, .a = i.d, .b = pos, .c = 0 });
                        pc += 1;
                    } else {
                        try self.push(&sp, .{ .kind = .choice, .a = pc + 1, .b = pos, .c = 0 });
                        pc = i.d;
                    }
                    break :blk true;
                },
                .cstart => blk: {
                    const c = &self.counters[i.a];
                    try self.push(&sp, .{ .kind = .undo_start, .a = i.a, .b = c.start, .c = 0 });
                    c.start = pos;
                    pc += 1;
                    break :blk true;
                },
                .cnext => blk: {
                    const c = &self.counters[i.a];
                    try self.push(&sp, .{ .kind = .undo_count, .a = i.a, .b = c.count, .c = 0 });
                    c.count += 1;
                    pc = i.b;
                    break :blk true;
                },
                .look => blk: {
                    try self.push(&sp, .{ .kind = .look, .a = pc, .b = pos, .c = 0 });
                    if (i.flags & flag_behind != 0) {
                        if (i.b > pos) break :blk false;
                        try self.push(&sp, .{ .kind = .behind, .a = pc, .b = i.b, .c = pos });
                        pos -= i.b;
                    }
                    pc += 1;
                    break :blk true;
                },
                .look_end => blk: {
                    const m = self.findMarker(sp, .look, i.a) orelse break :blk false;
                    const saved: usize = @intCast(self.frames[m].b);
                    const open = p.inst(i.a);
                    // A lookbehind body must end where the assertion stands.
                    if (open.flags & flag_behind != 0 and pos != saved) break :blk false;
                    self.cut(&sp, m);
                    if (open.flags & flag_negate != 0) break :blk false;
                    pos = saved;
                    pc = open.a;
                    break :blk true;
                },
                .atomic => blk: {
                    try self.push(&sp, .{ .kind = .atomic, .a = pc, .b = 0, .c = 0 });
                    pc += 1;
                    break :blk true;
                },
                .atomic_end => blk: {
                    if (self.findMarker(sp, .atomic, i.a)) |m| self.cut(&sp, m);
                    pc += 1;
                    break :blk true;
                },
                .match => return pos,
            };
            if (ok) continue;
            // Backtrack to the most recent choice that still has one.
            resume_loop: while (true) {
                if (sp == 0) return null;
                sp -= 1;
                const f = self.frames[sp];
                try self.charge(1);
                switch (f.kind) {
                    .choice => {
                        pc = f.a;
                        pos = @intCast(f.b);
                        break :resume_loop;
                    },
                    .undo_slot => self.slots[f.a] = f.b,
                    .undo_count => self.counters[f.a].count = f.b,
                    .undo_start => self.counters[f.a].start = f.b,
                    .rep_greedy => {
                        // Give back one byte; the frame stays while more can go.
                        const next = f.b - 1;
                        if (next > f.c) {
                            self.frames[sp].b = next;
                            sp += 1;
                        }
                        pos = @intCast(next);
                        pc = f.a + 1;
                        break :resume_loop;
                    },
                    .rep_lazy => {
                        // Take one more byte, if the set and the bound allow.
                        const at: usize = @intCast(f.b);
                        if (at < input.len and setHas(p.set(p.inst(f.a).a), input[at])) {
                            const next = at + 1;
                            if (next < f.c) {
                                self.frames[sp].b = next;
                                sp += 1;
                            }
                            pos = next;
                            pc = f.a + 1;
                            break :resume_loop;
                        }
                    },
                    .look => {
                        // The body has no match: a negative assertion holds.
                        const open = p.inst(f.a);
                        if (open.flags & flag_negate != 0) {
                            pos = @intCast(f.b);
                            pc = open.a;
                            break :resume_loop;
                        }
                    },
                    .behind => {
                        // Try the body from one byte further back.
                        const open = p.inst(f.a);
                        const len = f.b + 1;
                        if (len <= open.c and len <= f.c) {
                            self.frames[sp].b = len;
                            sp += 1;
                            pos = @intCast(f.c - len);
                            pc = f.a + 1;
                            break :resume_loop;
                        }
                    },
                    .atomic => {},
                }
            }
        }
    }
};

fn assertionAt(assertion: program.Assertion, multiline: bool, input: []const u8, pos: usize) bool {
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

test "bt: backreference, lookaround, atomic and a large counted repeat" {
    const gpa = std.testing.allocator;
    const Case = struct { pattern: []const u8, input: []const u8, want: ?[2]usize };
    const cases = [_]Case{
        .{ .pattern = "(a|b)\\1", .input = "xabba", .want = .{ 2, 4 } },
        .{ .pattern = "(?P<n>ab)c(?P=n)", .input = "xabcabd", .want = .{ 1, 6 } },
        .{ .pattern = "a(?=b)", .input = "acab", .want = .{ 2, 3 } },
        .{ .pattern = "a(?!b)", .input = "abac", .want = .{ 2, 3 } },
        .{ .pattern = "(?<=x)a", .input = "aaxa", .want = .{ 3, 4 } },
        .{ .pattern = "(?<!x)a", .input = "xaa", .want = .{ 2, 3 } },
        .{ .pattern = "(?>a+)a", .input = "aaaa", .want = null },
        .{ .pattern = "(?>a|ab)c", .input = "abc", .want = null },
        .{ .pattern = "(?:ab){3,}", .input = "ababababx", .want = .{ 0, 8 } },
        .{ .pattern = "x{5000,}", .input = "y", .want = null },
    };
    for (cases) |c| {
        var p = try Program.compile(gpa, c.pattern, .{ .bytes = true });
        defer p.deinit(gpa);
        var s = try Scratch.init(gpa, &p);
        defer s.deinit(gpa);
        const got = try p.find(&s, c.input);
        errdefer std.debug.print("{s} on {s}: {any}\n", .{ c.pattern, c.input, got });
        if (c.want) |w| {
            try std.testing.expectEqual(w[0], got.?.start);
            try std.testing.expectEqual(w[1], got.?.end);
        } else try std.testing.expect(got == null);
    }
}

test {
    std.testing.refAllDecls(@This());
}
