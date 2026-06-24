const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");
const unicode = @import("unicode.zig");
const prop_data = @import("unicode_prop_data.zig");
const rgi_data = @import("rgi_emoji_data.zig");
const RegexError = @import("errors.zig").RegexError;
const ErrorContext = @import("errors.zig").ErrorContext;

const MAX_SAFE_QUANTIFIER: usize = 9_007_199_254_740_991;

/// Token types for lexical analysis
pub const TokenType = enum {
    literal,
    dot, // .
    star, // *
    plus, // +
    question, // ?
    pipe, // |
    lparen, // (
    rparen, // )
    lbracket, // [
    rbracket, // ]
    lbrace, // {
    rbrace, // }
    caret, // ^
    dollar, // $
    backslash, // \
    escape_d, // \d
    escape_D, // \D
    escape_w, // \w
    escape_W, // \W
    escape_s, // \s
    escape_S, // \S
    escape_b, // \b
    escape_B, // \B
    escape_A, // \A - start of text
    escape_z, // \z - end of text
    escape_Z, // \Z - end of text (before final newline)
    escape_char, // \n, \t, etc.
    backref, // \1, \2, etc.
    escape_p, // \p{...} — Unicode property (value = @intFromEnum(property))
    escape_P, // \P{...} — negated Unicode property
    eof,
};

pub const Token = struct {
    token_type: TokenType,
    value: u8 = 0,
    index: usize = 0,
    name: ?[]const u8 = null,
    /// For `escape_p`/`escape_P`: either a resolved code-point property operand
    /// or, for `/v` properties of strings, a raw property name in `name`.
    prop: ?unicode.PropSpec = null,
    span: common.Span,
};

fn isStringPropertyName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Emoji_Keycap_Sequence") or
        std.mem.eql(u8, name, "RGI_Emoji_Tag_Sequence") or
        std.mem.eql(u8, name, "RGI_Emoji_Modifier_Sequence") or
        std.mem.eql(u8, name, "RGI_Emoji_Flag_Sequence") or
        std.mem.eql(u8, name, "RGI_Emoji_ZWJ_Sequence") or
        std.mem.eql(u8, name, "RGI_Emoji") or
        std.mem.eql(u8, name, "Basic_Emoji");
}

/// Lexer for tokenizing regex patterns
pub const Lexer = struct {
    input: []const u8,
    pos: usize,
    start_pos: usize,
    /// UTF-8 continuation bytes queued by a multi-byte escape (`\u{...}`,
    /// `\uHHHH`): the engine matches byte-by-byte over UTF-8 input, so a code
    /// point above U+007F is emitted as its UTF-8 byte sequence — the first byte
    /// is returned immediately and the rest are drained here on later `next()`s.
    pending: [3]u8 = undefined,
    pending_len: u8 = 0,
    pending_pos: u8 = 0,
    /// `x` (extended/verbose) mode: unescaped whitespace and `#`-to-end-of-line
    /// comments are ignored outside character classes. Toggled by the parser
    /// for global flags and scoped `(?x:...)` groups.
    extended: bool = false,
    /// Whether the lexer is currently between `[` and `]`. In `x` mode
    /// whitespace inside a class is literal, so skipping is suppressed here.
    in_class: bool = false,
    /// ECMAScript `u`/`v` mode forbids Annex B identity/octal escape fallbacks.
    unicode_strict: bool = false,
    /// Whether the pattern contains at least one named capture group `(?<name>…)`
    /// — the `[+NamedCaptureGroups]` grammar parameter (pre-scanned by the
    /// parser). When set (or in `u`/`v` mode) `\k` must be a `\k<name>` named
    /// backreference; otherwise a lone `\k` is the identity escape (Annex B).
    has_named_groups: bool = false,

    pub fn init(input: []const u8) Lexer {
        return .{
            .input = input,
            .pos = 0,
            .start_pos = 0,
        };
    }

    /// In `x` mode, advance past unescaped whitespace and `#` line comments.
    fn skipExtended(self: *Lexer) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            switch (c) {
                ' ', '\t', '\n', '\r', 0x0B, 0x0C => self.pos += 1,
                '#' => {
                    // Comment runs to the next newline (or end of input).
                    while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                        self.pos += 1;
                    }
                },
                else => return,
            }
        }
    }

    fn peek(self: *Lexer) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn advance(self: *Lexer) ?u8 {
        if (self.pos >= self.input.len) return null;
        const c = self.input[self.pos];
        self.pos += 1;
        return c;
    }

    fn makeToken(self: *Lexer, token_type: TokenType, value: u8) Token {
        return .{
            .token_type = token_type,
            .value = value,
            .span = common.Span.init(self.start_pos, self.pos),
        };
    }

    fn parseEscape(self: *Lexer) !Token {
        // We've already consumed the backslash
        const c = self.advance() orelse return RegexError.UnexpectedEndOfPattern;

        return switch (c) {
            'd' => self.makeToken(.escape_d, 0),
            'D' => self.makeToken(.escape_D, 0),
            'w' => self.makeToken(.escape_w, 0),
            'W' => self.makeToken(.escape_W, 0),
            's' => self.makeToken(.escape_s, 0),
            'S' => self.makeToken(.escape_S, 0),
            'b' => self.makeToken(.escape_b, 0),
            'B' => self.makeToken(.escape_B, 0),
            'A' => if (self.unicode_strict) RegexError.InvalidEscapeSequence else self.makeToken(.escape_A, 0),
            'z' => if (self.unicode_strict) RegexError.InvalidEscapeSequence else self.makeToken(.escape_z, 0),
            'Z' => if (self.unicode_strict) RegexError.InvalidEscapeSequence else self.makeToken(.escape_Z, 0),
            'n' => self.makeToken(.escape_char, '\n'),
            't' => self.makeToken(.escape_char, '\t'),
            'r' => self.makeToken(.escape_char, '\r'),
            '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                // DecimalEscape: collect the whole decimal integer so `\10`
                // can resolve to capture group 10 when enough groups exist.
                var index: usize = c - '0';
                while (self.peek()) |p| {
                    if (!std.ascii.isDigit(p)) break;
                    _ = self.advance();
                    index = index * 10 + (p - '0');
                }
                var tok = self.makeToken(.backref, 0);
                tok.index = index;
                return tok;
            },
            'k' => {
                // ECMAScript named backreference `\k<name>` — recognized only with
                // `[+NamedCaptureGroups]` or in `u`/`v` mode; otherwise a lone `\k`
                // is the identity escape (literal `k`) under Annex B.
                if (self.has_named_groups or self.unicode_strict) {
                    if (self.peek() != '<') return RegexError.InvalidEscapeSequence;
                    _ = self.advance();
                    const name_start = self.pos;
                    while (self.peek()) |p| {
                        if (p == '>') {
                            const name = self.input[name_start..self.pos];
                            _ = self.advance();
                            if (name.len == 0) return RegexError.InvalidEscapeSequence;
                            var tok = self.makeToken(.backref, 0);
                            tok.name = name;
                            return tok;
                        }
                        _ = self.advance();
                    }
                    return RegexError.UnexpectedEndOfPattern;
                }
                return self.makeToken(.literal, 'k');
            },
            'f' => self.makeToken(.escape_char, 0x0C), // form feed
            'v' => self.makeToken(.escape_char, 0x0B), // vertical tab
            '0' => {
                // `\0` is valid in Unicode mode only when it is not followed by
                // another decimal digit. `\00` etc. are legacy octal escapes.
                if (self.unicode_strict) if (self.peek()) |following| {
                    if (std.ascii.isDigit(following)) return RegexError.InvalidEscapeSequence;
                };
                return self.makeToken(.escape_char, 0x00);
            },
            'x' => try self.parseHexEscape(), // \xHH → one byte
            'c' => blk: {
                // \cX control escape: the control letter's code mod 32.
                const x = self.peek() orelse break :blk RegexError.InvalidEscapeSequence;
                if (std.ascii.isAlphabetic(x)) {
                    _ = self.advance();
                    break :blk self.makeToken(.escape_char, x % 32);
                }
                if (self.unicode_strict) break :blk RegexError.InvalidEscapeSequence;
                break :blk self.makeToken(.literal, 'c'); // not a control letter: literal 'c'
            },
            'u' => try self.parseUnicodeEscape(), // \uHHHH or \u{...} → UTF-8 byte(s)
            'p' => self.parsePropertyEscape(false),
            'P' => self.parsePropertyEscape(true),
            '\\', '.', '*', '+', '?', '|', '(', ')', '[', ']', '{', '}', '^', '$', '/' => {
                // Literal escape of special characters
                return self.makeToken(.literal, c);
            },
            // IdentityEscape (Annex B / non-Unicode): an unrecognized `\X` matches
            // the literal `X` rather than being a syntax error, matching how web
            // JavaScript engines treat e.g. `\-`, `\ `, `\<`.
            else => {
                if (self.unicode_strict) return RegexError.InvalidEscapeSequence;
                return self.makeToken(.literal, c);
            },
        };
    }

    /// `\xHH`: two hex digits → that code point's UTF-8 bytes (`\x` with fewer
    /// than two hex digits is an IdentityEscape of `x`, per Annex B).
    /// `\p{Name}` / `\P{Name}` — a Unicode property escape. Resolves a
    /// General_Category name (short or long, optionally `gc=Name`) to the
    /// `UnicodeProperty` enum and emits its ordinal in the token value. Without a
    /// `{...}` body, `\p` is an IdentityEscape of `p` (non-Unicode mode). An
    /// unknown / unsupported property name is a syntax error.
    fn parsePropertyEscape(self: *Lexer, negated: bool) !Token {
        if (self.peek() != '{') {
            if (self.unicode_strict) return RegexError.InvalidEscapeSequence;
            return self.makeToken(.literal, if (negated) 'P' else 'p');
        }
        _ = self.advance(); // consume '{'
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '}') break;
            _ = self.advance();
        }
        if (self.peek() != '}') return RegexError.InvalidEscapeSequence;
        const body = self.input[start..self.pos];
        _ = self.advance(); // consume '}'
        // `\p{Name}` is a lone binary-property/General_Category value;
        // `\p{lhs=rhs}` selects gc/General_Category, sc/Script, or
        // scx/Script_Extensions.
        var lhs: ?[]const u8 = null;
        var name = body;
        var complement = negated;
        if (std.mem.indexOfScalar(u8, body, '=')) |eq_i| {
            lhs = body[0..eq_i];
            name = body[eq_i + 1 ..];
        }
        if (lhs == null and name.len > 0 and name[0] == '^') {
            complement = !complement;
            name = name[1..];
            if (name.len == 0) return RegexError.InvalidEscapeSequence;
        }
        var tok = self.makeToken(if (complement) .escape_P else .escape_p, 0);
        if (unicode.resolveProperty(lhs, name, self.unicode_strict)) |spec| {
            tok.prop = spec;
        } else if (lhs == null and !complement and isStringPropertyName(name)) {
            tok.name = name;
        } else {
            return RegexError.InvalidEscapeSequence;
        }
        return tok;
    }

    fn parseHexEscape(self: *Lexer) !Token {
        const save = self.pos;
        const h1 = self.peekHex(0);
        const h2 = self.peekHex(1);
        if (h1 != null and h2 != null) {
            self.pos += 2;
            return self.emitCodepoint(h1.? * 16 + h2.?);
        }
        self.pos = save;
        if (self.unicode_strict) return RegexError.InvalidEscapeSequence;
        return self.makeToken(.literal, 'x');
    }

    /// `\uHHHH` or `\u{H...}`: a code point, emitted as its UTF-8 bytes (the
    /// first byte is returned; continuation bytes are queued in `pending`). A
    /// malformed escape is an IdentityEscape of `u`.
    fn parseUnicodeEscape(self: *Lexer) !Token {
        const save = self.pos;
        var cp: u32 = 0;
        if (self.peek() == '{') {
            self.pos += 1; // consume '{'
            var n: usize = 0;
            while (self.peekHex(0)) |d| {
                cp = cp * 16 + d;
                self.pos += 1;
                n += 1;
                if (cp > 0x10FFFF) break;
            }
            if (n == 0 or self.peek() != '}' or cp > 0x10FFFF) {
                self.pos = save;
                if (self.unicode_strict) return RegexError.InvalidEscapeSequence;
                return self.makeToken(.literal, 'u');
            }
            self.pos += 1; // consume '}'
        } else {
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                const d = self.peekHex(i) orelse {
                    self.pos = save;
                    if (self.unicode_strict) return RegexError.InvalidEscapeSequence;
                    return self.makeToken(.literal, 'u');
                };
                cp = cp * 16 + d;
            }
            self.pos += 4;
        }
        if (self.unicode_strict and cp >= 0xD800 and cp <= 0xDBFF) {
            if (self.peekSurrogatePairLow()) |lo| {
                self.pos += 6;
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            }
        }
        return self.emitCodepoint(@intCast(cp));
    }

    fn peekSurrogatePairLow(self: *Lexer) ?u32 {
        if (self.pos + 6 > self.input.len) return null;
        if (self.input[self.pos] != '\\' or self.input[self.pos + 1] != 'u') return null;
        var cp: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const d = self.peekHex(2 + i) orelse return null;
            cp = cp * 16 + d;
        }
        return if (cp >= 0xDC00 and cp <= 0xDFFF) cp else null;
    }

    /// The hex value of the digit at `self.pos + offset`, or null.
    fn peekHex(self: *Lexer, offset: usize) ?u8 {
        if (self.pos + offset >= self.input.len) return null;
        return switch (self.input[self.pos + offset]) {
            '0'...'9' => |d| d - '0',
            'a'...'f' => |d| d - 'a' + 10,
            'A'...'F' => |d| d - 'A' + 10,
            else => null,
        };
    }

    /// Encode `cp` to UTF-8/WTF-8, return its first byte as a literal token, and
    /// queue any continuation bytes (drained by subsequent `next()` calls).
    fn emitCodepoint(self: *Lexer, cp: u21) Token {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch n: {
            if (cp >= 0xD800 and cp <= 0xDFFF) {
                buf[0] = @intCast(0xE0 | (cp >> 12));
                buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                buf[2] = @intCast(0x80 | (cp & 0x3F));
                break :n 3;
            }
            return self.makeToken(.literal, 'u');
        };
        self.pending_len = 0;
        self.pending_pos = 0;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            self.pending[self.pending_len] = buf[i];
            self.pending_len += 1;
        }
        return self.makeToken(.literal, buf[0]);
    }

    pub fn next(self: *Lexer) !Token {
        // Drain any queued UTF-8 continuation bytes from a multi-byte escape.
        if (self.pending_pos < self.pending_len) {
            const b = self.pending[self.pending_pos];
            self.pending_pos += 1;
            return Token{ .token_type = .literal, .value = b, .span = common.Span.init(self.start_pos, self.pos) };
        }
        // In `x` mode, ignore unescaped whitespace and `#` comments — but never
        // inside a character class, where whitespace is literal.
        if (self.extended and !self.in_class) self.skipExtended();
        self.start_pos = self.pos;

        const c = self.advance() orelse {
            return self.makeToken(.eof, 0);
        };

        return switch (c) {
            '.' => self.makeToken(.dot, 0),
            '*' => self.makeToken(.star, 0),
            '+' => self.makeToken(.plus, 0),
            '?' => self.makeToken(.question, 0),
            '|' => self.makeToken(.pipe, 0),
            '(' => self.makeToken(.lparen, 0),
            ')' => self.makeToken(.rparen, 0),
            '[' => blk: {
                self.in_class = true;
                break :blk self.makeToken(.lbracket, 0);
            },
            ']' => blk: {
                self.in_class = false;
                break :blk self.makeToken(.rbracket, 0);
            },
            '{' => self.makeToken(.lbrace, 0),
            '}' => self.makeToken(.rbrace, 0),
            '^' => self.makeToken(.caret, 0),
            '$' => self.makeToken(.dollar, 0),
            '\\' => try self.parseEscape(),
            else => self.makeToken(.literal, c),
        };
    }

    pub fn reset(self: *Lexer) void {
        self.pos = 0;
        self.start_pos = 0;
        self.pending_len = 0;
        self.pending_pos = 0;
        self.in_class = false;
    }
};

/// Whether `c` can begin an inline-modifier flag run after `(?` — one of the
/// recognized flag letters (i/m/s plus local x/U) or the `-` that starts the
/// unset group. ECMAScript inline modifiers do not include `u`.
fn isInlineFlagStart(c: u8) bool {
    return switch (c) {
        'i', 'm', 's', 'x', 'U', '-' => true,
        else => false,
    };
}

/// Parser for regex patterns
pub const Parser = struct {
    lexer: Lexer,
    allocator: std.mem.Allocator,
    current_token: Token,
    capture_count: usize,
    nesting_depth: usize,
    /// The `v` flag: parse character classes with set notation.
    unicode_sets: bool = false,
    /// The `u` flag: ordinary character classes match code points instead of
    /// bytes, while keeping non-`v` class syntax.
    unicode: bool = false,
    /// Current `x` (extended/verbose) state. Kept in sync with `lexer.extended`;
    /// pushed/popped around `(?x:...)` / `(?-x:...)` scopes.
    extended: bool = false,
    /// Current `U` state: when set, quantifier greediness is swapped (so `a+`
    /// is lazy and `a+?` is greedy) for the duration of the scope.
    swap_greedy: bool = false,
    /// ECMAScript-conformance mode (the engine is hosting a JS RegExp). Disables
    /// the PCRE/Perl extensions ECMAScript does not have: standalone inline
    /// modifiers `(?ims)` (only the scoped `(?ims:…)` / `(?ims-i:…)` colon form
    /// is valid), and modifier flags spelled with unicode escapes `(?i:…)`.
    ecmascript: bool = false,

    /// Maximum nesting depth to prevent stack overflow from patterns like (((((...
    pub const MAX_NESTING_DEPTH: usize = 512;

    /// Pre-scan for `(?<name>…)` (the `[+NamedCaptureGroups]` decision), skipping
    /// `\`-escapes, character classes, and the `(?<=`/`(?<!` lookbehinds.
    fn scanForNamedGroups(pattern: []const u8) bool {
        var i: usize = 0;
        var in_class = false;
        while (i < pattern.len) : (i += 1) {
            const c = pattern[i];
            if (c == '\\') {
                i += 1; // skip the escaped character
                continue;
            }
            if (in_class) {
                if (c == ']') in_class = false;
                continue;
            }
            if (c == '[') {
                in_class = true;
            } else if (c == '(' and i + 2 < pattern.len and pattern[i + 1] == '?' and pattern[i + 2] == '<') {
                const after = if (i + 3 < pattern.len) pattern[i + 3] else 0;
                if (after != '=' and after != '!') return true; // not a lookbehind
            }
        }
        return false;
    }

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8) !Parser {
        var lexer = Lexer.init(pattern);
        lexer.has_named_groups = scanForNamedGroups(pattern);
        const first_token = try lexer.next();
        return .{
            .lexer = lexer,
            .allocator = allocator,
            .current_token = first_token,
            .capture_count = 0,
            .nesting_depth = 0,
        };
    }

    fn advance(self: *Parser) !void {
        self.current_token = try self.lexer.next();
    }

    fn peek(self: *Parser) TokenType {
        return self.current_token.token_type;
    }

    fn expect(self: *Parser, expected: TokenType) !void {
        if (self.current_token.token_type != expected) {
            return RegexError.UnexpectedCharacter;
        }
        try self.advance();
    }

    /// Parse the entire regex pattern
    pub fn parse(self: *Parser) !ast.AST {
        const root = try self.parseAlternation();
        errdefer root.destroy(self.allocator);

        // Verify all input was consumed
        if (self.peek() != .eof) {
            return switch (self.peek()) {
                .rparen => RegexError.UnmatchedParenthesis,
                .rbracket => RegexError.UnmatchedBracket,
                else => RegexError.UnexpectedCharacter,
            };
        }
        if (self.unicode or self.unicode_sets) try self.validateUnicodeBackrefs(root);
        // A `\k<name>` named backreference must resolve to a defined group when
        // the pattern has named groups or is in `u`/`v` mode.
        if (self.lexer.has_named_groups or self.unicode or self.unicode_sets)
            try self.validateNamedBackrefs(root);
        try self.validateDuplicateGroupNames(root);

        return ast.AST.init(self.allocator, root, self.capture_count);
    }

    fn cloneNameSet(
        self: *Parser,
        src: *const std.StringHashMapUnmanaged(void),
    ) !std.StringHashMapUnmanaged(void) {
        var dst: std.StringHashMapUnmanaged(void) = .empty;
        var it = src.iterator();
        while (it.next()) |entry| {
            try dst.put(self.allocator, entry.key_ptr.*, {});
        }
        return dst;
    }

    fn validateDuplicateGroupNames(self: *Parser, root: *ast.Node) !void {
        var names: std.StringHashMapUnmanaged(void) = .empty;
        defer names.deinit(self.allocator);
        try self.validateDuplicateGroupNamesBranch(root, &names);
    }

    fn validateDuplicateGroupNamesBranch(
        self: *Parser,
        node: *ast.Node,
        names: *std.StringHashMapUnmanaged(void),
    ) !void {
        switch (node.data) {
            .group => |group| {
                if (group.name) |name| {
                    if (names.contains(name)) return RegexError.DuplicateGroupName;
                    try names.put(self.allocator, name, {});
                }
                try self.validateDuplicateGroupNamesBranch(group.child, names);
            },
            .concat => |concat| {
                try self.validateDuplicateGroupNamesBranch(concat.left, names);
                try self.validateDuplicateGroupNamesBranch(concat.right, names);
            },
            .alternation => |alt| {
                var left_names = try self.cloneNameSet(names);
                defer left_names.deinit(self.allocator);
                var right_names = try self.cloneNameSet(names);
                defer right_names.deinit(self.allocator);
                try self.validateDuplicateGroupNamesBranch(alt.left, &left_names);
                try self.validateDuplicateGroupNamesBranch(alt.right, &right_names);
            },
            .star, .plus, .optional => |quant| try self.validateDuplicateGroupNamesBranch(quant.child, names),
            .repeat => |repeat| try self.validateDuplicateGroupNamesBranch(repeat.child, names),
            .lookahead, .lookbehind => |assertion| try self.validateDuplicateGroupNamesBranch(assertion.child, names),
            else => {},
        }
    }

    /// Collect every defined capture-group name from the AST into `names`.
    fn collectGroupNames(
        self: *Parser,
        node: *ast.Node,
        names: *std.StringHashMapUnmanaged(void),
    ) std.mem.Allocator.Error!void {
        switch (node.data) {
            .group => |group| {
                if (group.name) |name| try names.put(self.allocator, name, {});
                try self.collectGroupNames(group.child, names);
            },
            .concat => |concat| {
                try self.collectGroupNames(concat.left, names);
                try self.collectGroupNames(concat.right, names);
            },
            .alternation => |alt| {
                try self.collectGroupNames(alt.left, names);
                try self.collectGroupNames(alt.right, names);
            },
            .star, .plus, .optional => |quant| try self.collectGroupNames(quant.child, names),
            .repeat => |repeat| try self.collectGroupNames(repeat.child, names),
            .lookahead, .lookbehind => |assertion| try self.collectGroupNames(assertion.child, names),
            else => {},
        }
    }

    fn validateNamedBackrefs(self: *Parser, root: *ast.Node) !void {
        var names: std.StringHashMapUnmanaged(void) = .empty;
        defer names.deinit(self.allocator);
        try self.collectGroupNames(root, &names);
        try self.checkNamedBackrefs(root, &names);
    }

    fn checkNamedBackrefs(
        self: *Parser,
        node: *ast.Node,
        names: *const std.StringHashMapUnmanaged(void),
    ) RegexError!void {
        switch (node.data) {
            .concat => |concat| {
                try self.checkNamedBackrefs(concat.left, names);
                try self.checkNamedBackrefs(concat.right, names);
            },
            .alternation => |alt| {
                try self.checkNamedBackrefs(alt.left, names);
                try self.checkNamedBackrefs(alt.right, names);
            },
            .star, .plus, .optional => |quant| try self.checkNamedBackrefs(quant.child, names),
            .repeat => |repeat| try self.checkNamedBackrefs(repeat.child, names),
            .group => |group| try self.checkNamedBackrefs(group.child, names),
            .lookahead, .lookbehind => |assertion| try self.checkNamedBackrefs(assertion.child, names),
            .backref => |backref| {
                if (backref.name) |nm| {
                    if (!names.contains(nm)) return RegexError.InvalidBackreference;
                }
            },
            else => {},
        }
    }

    fn validateUnicodeBackrefs(self: *Parser, node: *ast.Node) RegexError!void {
        switch (node.data) {
            .concat => |concat| {
                try self.validateUnicodeBackrefs(concat.left);
                try self.validateUnicodeBackrefs(concat.right);
            },
            .alternation => |alt| {
                try self.validateUnicodeBackrefs(alt.left);
                try self.validateUnicodeBackrefs(alt.right);
            },
            .star, .plus, .optional => |quant| try self.validateUnicodeBackrefs(quant.child),
            .repeat => |repeat| try self.validateUnicodeBackrefs(repeat.child),
            .group => |group| try self.validateUnicodeBackrefs(group.child),
            .lookahead, .lookbehind => |assertion| try self.validateUnicodeBackrefs(assertion.child),
            .backref => |backref| {
                if (backref.name == null and (backref.index == 0 or backref.index > self.capture_count))
                    return RegexError.InvalidBackreference;
            },
            else => {},
        }
    }

    /// Parse alternation (lowest precedence)
    fn parseAlternation(self: *Parser) !*ast.Node {
        var left = try self.parseConcat();
        errdefer left.destroy(self.allocator);

        while (self.peek() == .pipe) {
            const start = self.current_token.span.start;
            try self.advance(); // consume |
            const right = try self.parseConcat();
            const span = common.Span.init(start, self.current_token.span.end);
            left = try ast.Node.createAlternation(self.allocator, left, right, span);
        }

        return left;
    }

    /// Parse concatenation
    fn parseConcat(self: *Parser) !*ast.Node {
        var nodes: std.ArrayList(*ast.Node) = .empty;
        defer nodes.deinit(self.allocator);
        errdefer {
            for (nodes.items) |n| {
                n.destroy(self.allocator);
            }
        }

        while (true) {
            const token_type = self.peek();
            if (token_type == .pipe or token_type == .rparen or token_type == .eof) {
                break;
            }

            const node = try self.parseRepeat();
            try nodes.append(self.allocator, node);
        }

        if (nodes.items.len == 0) {
            return ast.Node.createEmpty(self.allocator, common.Span.init(self.lexer.pos, self.lexer.pos));
        }

        if (nodes.items.len == 1) {
            return nodes.items[0];
        }

        // Build right-associative concatenation tree
        var result = nodes.items[nodes.items.len - 1];
        var i = nodes.items.len - 1;
        while (i > 0) {
            i -= 1;
            const left = nodes.items[i];
            const span = common.Span.init(left.span.start, result.span.end);
            result = try ast.Node.createConcat(self.allocator, left, result, span);
        }

        return result;
    }

    /// Set the parse-time flag state (`x` extended, `U` swap-greedy), keeping
    /// the lexer's view of extended mode in sync. Used to push and restore the
    /// flag scope around `(?x:...)` / `(?U:...)` and their standalone forms.
    fn setParseFlags(self: *Parser, extended: bool, swap_greedy: bool) void {
        self.extended = extended;
        self.lexer.extended = extended;
        self.swap_greedy = swap_greedy;
    }

    /// Determine a quantifier's greediness, consuming a trailing lazy `?` if
    /// present. Under `U` (swap-greedy) the default and lazy senses are flipped.
    fn quantifierGreedy(self: *Parser) !bool {
        const explicit_lazy = self.peek() == .question;
        if (explicit_lazy) try self.advance();
        return if (self.swap_greedy) explicit_lazy else !explicit_lazy;
    }

    fn isQuantifierNode(node: *ast.Node) bool {
        return switch (node.node_type) {
            .star, .plus, .optional, .repeat => true,
            else => false,
        };
    }

    fn checkQuantifierTarget(self: *Parser, node: *ast.Node) RegexError!void {
        if (isQuantifierNode(node)) return RegexError.InvalidQuantifier;
        // Lookbehind is never a QuantifiableAssertion in any mode; lookahead is
        // only quantifiable in Annex B (non-unicode) web-compat mode.
        switch (node.node_type) {
            .lookbehind => return RegexError.InvalidQuantifier,
            .lookahead => if (self.unicode or self.unicode_sets) return RegexError.InvalidQuantifier,
            else => {},
        }
    }

    /// Parse repetition operators (*, +, ?, {m,n})
    fn parseRepeat(self: *Parser) !*ast.Node {
        var node = try self.parsePrimary();
        errdefer node.destroy(self.allocator);
        const start = node.span.start;

        while (true) {
            const token_type = self.peek();
            const span = common.Span.init(start, self.current_token.span.end);

            switch (token_type) {
                .star => {
                    try self.checkQuantifierTarget(node);
                    try self.advance();
                    // Check for lazy quantifier (? after *)
                    const greedy = try self.quantifierGreedy();
                    node = try ast.Node.createStar(self.allocator, node, greedy, span);
                },
                .plus => {
                    try self.checkQuantifierTarget(node);
                    try self.advance();
                    // Check for lazy quantifier (? after +)
                    const greedy = try self.quantifierGreedy();
                    node = try ast.Node.createPlus(self.allocator, node, greedy, span);
                },
                .question => {
                    try self.checkQuantifierTarget(node);
                    try self.advance();
                    // Check for lazy quantifier (? after ?)
                    const greedy = try self.quantifierGreedy();
                    node = try ast.Node.createOptional(self.allocator, node, greedy, span);
                },
                .lbrace => {
                    try self.checkQuantifierTarget(node);
                    try self.advance(); // consume {

                    // Parse minimum with overflow protection
                    var min: usize = 0;
                    while (self.peek() == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                        const digit = self.current_token.value - '0';

                        // Check for multiplication overflow before computing
                        if (min > std.math.maxInt(usize) / 10) {
                            return RegexError.InvalidQuantifier;
                        }

                        const new_min = min * 10 + digit;

                        if (new_min > MAX_SAFE_QUANTIFIER) {
                            return RegexError.InvalidQuantifier;
                        }

                        min = new_min;
                        try self.advance();
                    }

                    var max: ?usize = min; // Default: exactly min times

                    // Check for comma (range syntax)
                    if (self.peek() == .literal and self.current_token.value == ',') {
                        try self.advance(); // consume ,

                        // Check if there's a max value
                        if (self.peek() == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                            max = 0;
                            while (self.peek() == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                                const digit = self.current_token.value - '0';

                                // Check for multiplication overflow
                                if (max.? > std.math.maxInt(usize) / 10) {
                                    return RegexError.InvalidQuantifier;
                                }

                                const new_max = max.? * 10 + digit;

                                if (new_max > MAX_SAFE_QUANTIFIER) {
                                    return RegexError.InvalidQuantifier;
                                }

                                max = new_max;
                                try self.advance();
                            }
                        } else {
                            // {m,} means m or more (unbounded)
                            max = null;
                        }
                    }

                    try self.expect(.rbrace);

                    // Validate min <= max
                    if (max) |max_val| {
                        if (min > max_val) {
                            return RegexError.InvalidQuantifier;
                        }
                    }

                    const bounds = ast.RepeatBounds.init(min, max);
                    // Check for lazy quantifier (? after {m,n})
                    const greedy = try self.quantifierGreedy();
                    node = try ast.Node.createRepeat(self.allocator, node, bounds, greedy, span);
                },
                else => break,
            }
        }

        return node;
    }

    /// Parse primary expressions (literals, groups, character classes)
    fn parsePrimary(self: *Parser) RegexError!*ast.Node {
        const token = self.current_token;
        const span = token.span;

        switch (token.token_type) {
            .literal => {
                try self.advance();
                return ast.Node.createLiteral(self.allocator, token.value, span);
            },
            .dot => {
                try self.advance();
                return ast.Node.createAny(self.allocator, span);
            },
            .caret => {
                try self.advance();
                return ast.Node.createAnchor(self.allocator, .start_line, span);
            },
            .dollar => {
                try self.advance();
                return ast.Node.createAnchor(self.allocator, .end_line, span);
            },
            .escape_d => {
                try self.advance();
                // Duplicate ranges from static predefined class so AST can own them
                const ranges = try self.allocator.dupe(common.CharRange, common.CharClasses.digit.ranges);
                return ast.Node.createCharClass(self.allocator, .{
                    .ranges = ranges,
                    .negated = common.CharClasses.digit.negated,
                }, span);
            },
            .escape_D => {
                try self.advance();
                const ranges = try self.allocator.dupe(common.CharRange, common.CharClasses.non_digit.ranges);
                return ast.Node.createCharClass(self.allocator, .{
                    .ranges = ranges,
                    .negated = common.CharClasses.non_digit.negated,
                }, span);
            },
            .escape_w => {
                try self.advance();
                const ranges = try self.allocator.dupe(common.CharRange, common.CharClasses.word.ranges);
                return ast.Node.createCharClass(self.allocator, .{
                    .ranges = ranges,
                    .negated = common.CharClasses.word.negated,
                }, span);
            },
            .escape_W => {
                try self.advance();
                const ranges = try self.allocator.dupe(common.CharRange, common.CharClasses.non_word.ranges);
                return ast.Node.createCharClass(self.allocator, .{
                    .ranges = ranges,
                    .negated = common.CharClasses.non_word.negated,
                }, span);
            },
            .escape_s => {
                try self.advance();
                return self.createBuiltinClassSet('s', span);
            },
            .escape_S => {
                try self.advance();
                return self.createBuiltinClassSet('S', span);
            },
            .escape_b => {
                try self.advance();
                return ast.Node.createAnchor(self.allocator, .word_boundary, span);
            },
            .escape_B => {
                try self.advance();
                return ast.Node.createAnchor(self.allocator, .non_word_boundary, span);
            },
            .escape_A => {
                try self.advance();
                return ast.Node.createAnchor(self.allocator, .start_text, span);
            },
            .escape_z, .escape_Z => {
                try self.advance();
                return ast.Node.createAnchor(self.allocator, .end_text, span);
            },
            .escape_char => {
                try self.advance();
                return ast.Node.createLiteral(self.allocator, token.value, span);
            },
            .backref => {
                try self.advance();
                const name = if (token.name) |n| try self.normalizeGroupName(n) else null;
                errdefer if (name) |n| self.allocator.free(n);
                const index = token.index; // 1-based capture group index; 0 for named-only references
                return ast.Node.createBackreference(self.allocator, index, name, span);
            },
            .escape_p, .escape_P => {
                try self.advance();
                if (token.prop) |prop| {
                    return ast.Node.createUnicodeProperty(self.allocator, prop, token.token_type == .escape_P, span);
                }
                if (token.token_type == .escape_P) return RegexError.UnexpectedCharacter;
                if (!self.unicode_sets) return RegexError.InvalidEscapeSequence;
                const name = token.name orelse return RegexError.InvalidEscapeSequence;
                return self.stringPropertyNode(name, span);
            },
            .lparen => {
                // SECURITY: Check nesting depth to prevent stack overflow
                self.nesting_depth += 1;
                if (self.nesting_depth > MAX_NESTING_DEPTH) {
                    return RegexError.NestingTooDeep;
                }
                defer self.nesting_depth -= 1;

                try self.advance(); // consume (

                // Check for group extensions (?...)
                var capture_index: ?usize = null;
                var group_name: ?[]const u8 = null;
                // Inline-modifier groups early-return below; regular/named/`(?:`
                // groups carry no flag delta.
                const group_mod: ?ast.Node.FlagDelta = null;

                if (self.current_token.token_type == .question) {
                    try self.advance(); // consume ?

                    // Check what follows the ?
                    if (self.current_token.token_type == .literal) {
                        if (self.current_token.value == ':') {
                            // Non-capturing group (?:...)
                            try self.advance(); // consume :
                            // capture_index remains null
                        } else if (self.current_token.value == '=') {
                            // Positive lookahead (?=...)
                            try self.advance(); // consume =
                            const child = try self.parseAlternation();
                            errdefer child.destroy(self.allocator);
                            try self.expect(.rparen);
                            return ast.Node.createLookahead(self.allocator, child, true, span);
                        } else if (self.current_token.value == '!') {
                            // Negative lookahead (?!...)
                            try self.advance(); // consume !
                            const child = try self.parseAlternation();
                            errdefer child.destroy(self.allocator);
                            try self.expect(.rparen);
                            return ast.Node.createLookahead(self.allocator, child, false, span);
                        } else if (self.current_token.value == 'P') {
                            // Python-style named group (?P<name>...)
                            try self.advance(); // consume P
                            if (self.current_token.token_type != .literal or self.current_token.value != '<') {
                                return RegexError.UnexpectedCharacter;
                            }
                            try self.advance(); // consume <
                            group_name = try self.parseGroupName();
                            self.capture_count += 1;
                            capture_index = self.capture_count;
                        } else if (self.current_token.value == '<') {
                            // Check if it's lookbehind or named group
                            // Need to peek ahead to distinguish (?<=...) from (?<name>...)
                            const saved_pos = self.lexer.pos;
                            const saved_token = self.current_token;
                            try self.advance(); // consume <

                            if (self.current_token.token_type == .literal and self.current_token.value == '=') {
                                // Positive lookbehind (?<=...)
                                try self.advance(); // consume =
                                const child = try self.parseAlternation();
                                errdefer child.destroy(self.allocator);
                                try self.expect(.rparen);
                                return ast.Node.createLookbehind(self.allocator, child, true, span);
                            } else if (self.current_token.token_type == .literal and self.current_token.value == '!') {
                                // Negative lookbehind (?<!...)
                                try self.advance(); // consume !
                                const child = try self.parseAlternation();
                                errdefer child.destroy(self.allocator);
                                try self.expect(.rparen);
                                return ast.Node.createLookbehind(self.allocator, child, false, span);
                            } else {
                                // .NET/Perl-style named group (?<name>...)
                                // Restore position to re-parse the name.
                                self.lexer.pos = saved_pos;
                                self.current_token = saved_token;
                                try self.advance(); // consume <
                                group_name = try self.parseGroupName();
                                self.capture_count += 1;
                                capture_index = self.capture_count;
                            }
                        } else if (isInlineFlagStart(self.current_token.value)) {
                            // Inline modifiers: `(?imsxU-imsxU:...)` scopes a
                            // group body; `(?imsxU-imsxU)` (no body) scopes the
                            // rest of the enclosing sequence. The ECMAScript
                            // match-time flags i/m/s become a FlagDelta on the
                            // group; local parse-time flags x (extended) and U
                            // (swap-greedy) are applied to the parser/lexer.
                            var mod = ast.Node.FlagDelta{};
                            var new_extended = self.extended;
                            var new_swap_greedy = self.swap_greedy;
                            var removing = false;
                            var standalone = false;
                            // Early errors: a flag may not repeat within, or appear
                            // in both, the add and remove groups (and only the
                            // recognized flags i/m/s/x/U are permitted — any
                            // other code point is a syntax error).
                            var add_mask: u5 = 0;
                            var remove_mask: u5 = 0;
                            while (true) {
                                if (self.peek() == .rparen) {
                                    standalone = true;
                                    break;
                                }
                                if (self.current_token.token_type != .literal) return RegexError.UnexpectedCharacter;
                                // ECMAScript: a modifier flag must be a literal
                                // source character, not a `\u…` escape that
                                // resolves to "i"/"m"/"s".
                                if (self.ecmascript and self.current_token.span.start < self.lexer.input.len and
                                    self.lexer.input[self.current_token.span.start] == '\\')
                                    return RegexError.UnexpectedCharacter;
                                const v = self.current_token.value;
                                if (v == ':') {
                                    // Stop here WITHOUT consuming `:` — the parse-
                                    // time flags are applied below so the first body
                                    // token lexes under them.
                                    break;
                                } else if (v == '-') {
                                    if (removing) return RegexError.UnexpectedCharacter;
                                    removing = true;
                                    try self.advance();
                                } else {
                                    const bit: u5 = switch (v) {
                                        'i' => 1 << 0,
                                        'm' => 1 << 1,
                                        's' => 1 << 2,
                                        'x' => 1 << 3,
                                        'U' => 1 << 4,
                                        else => return RegexError.UnexpectedCharacter,
                                    };
                                    const side = if (removing) &remove_mask else &add_mask;
                                    if (side.* & bit != 0) return RegexError.UnexpectedCharacter; // repeated flag
                                    side.* |= bit;
                                    if (add_mask & remove_mask != 0) return RegexError.UnexpectedCharacter; // added and removed
                                    const on = !removing;
                                    switch (v) {
                                        'i' => mod.i = on,
                                        'm' => mod.m = on,
                                        's' => mod.s = on,
                                        'x' => new_extended = on,
                                        'U' => new_swap_greedy = on,
                                        else => unreachable,
                                    }
                                    try self.advance();
                                }
                            }
                            if (removing and add_mask == 0 and remove_mask == 0) return RegexError.UnexpectedCharacter;

                            // Push the parse-time flag scope; restore on all exits.
                            const saved_extended = self.extended;
                            const saved_swap_greedy = self.swap_greedy;
                            self.setParseFlags(new_extended, new_swap_greedy);

                            if (standalone) {
                                // ECMAScript has no standalone `(?ims)` directive —
                                // only the scoped `(?ims:…)` / `(?ims-i:…)` colon
                                // form. A modifier group without a colon body is a
                                // syntax error.
                                if (self.ecmascript) {
                                    self.setParseFlags(saved_extended, saved_swap_greedy);
                                    return RegexError.UnexpectedCharacter;
                                }
                                // `(?...)` directive: close its paren, then wrap the
                                // remainder of the current alternative. Parse-time
                                // flags apply to that remainder, then are restored
                                // so siblings of the enclosing group are unaffected.
                                self.expect(.rparen) catch |e| {
                                    self.setParseFlags(saved_extended, saved_swap_greedy);
                                    return e;
                                };
                                const body = self.parseConcat() catch |e| {
                                    self.setParseFlags(saved_extended, saved_swap_greedy);
                                    return e;
                                };
                                self.setParseFlags(saved_extended, saved_swap_greedy);
                                const node = try ast.Node.createGroup(self.allocator, body, null, span);
                                if (mod.any()) node.data.group.mod = mod;
                                return node;
                            }

                            // Scoped group `(?...:body)`: consume `:` (now under the
                            // new lexer.extended), parse the body, restore, close.
                            self.advance() catch |e| {
                                self.setParseFlags(saved_extended, saved_swap_greedy);
                                return e;
                            };
                            const body = self.parseAlternation() catch |e| {
                                self.setParseFlags(saved_extended, saved_swap_greedy);
                                return e;
                            };
                            self.setParseFlags(saved_extended, saved_swap_greedy);
                            errdefer body.destroy(self.allocator);
                            try self.expect(.rparen);
                            const node = try ast.Node.createGroup(self.allocator, body, null, span);
                            if (mod.any()) node.data.group.mod = mod;
                            return node;
                        } else {
                            // Unknown group extension
                            return RegexError.UnexpectedCharacter;
                        }
                    } else {
                        // Invalid syntax after (?
                        return RegexError.UnexpectedCharacter;
                    }
                } else {
                    // Regular capturing group - assign capture index BEFORE parsing child
                    self.capture_count += 1;
                    capture_index = self.capture_count;
                }

                const child = try self.parseAlternation();
                errdefer child.destroy(self.allocator);
                try self.expect(.rparen);

                if (group_name) |name| {
                    return ast.Node.createNamedGroup(self.allocator, child, capture_index, name, span);
                } else {
                    const node = try ast.Node.createGroup(self.allocator, child, capture_index, span);
                    node.data.group.mod = group_mod;
                    return node;
                }
            },
            .lbracket => {
                return try self.parseCharClass();
            },
            else => {
                return RegexError.UnexpectedCharacter;
            },
        }
    }

    /// Parse group name from (?P<name>...) or (?<name>...)
    /// Expects current token to be first character of name
    /// Consumes tokens until > is found
    fn parseGroupName(self: *Parser) ![]const u8 {
        const start = self.current_token.span.start;
        var end = start;
        while (end < self.lexer.input.len and self.lexer.input[end] != '>') : (end += 1) {}
        if (end >= self.lexer.input.len) return RegexError.UnexpectedEndOfPattern;

        const name = try self.normalizeGroupName(self.lexer.input[start..end]);
        self.lexer.pos = end + 1;
        self.lexer.pending_len = 0;
        self.lexer.pending_pos = 0;
        try self.advance();
        return name;
    }

    fn normalizeGroupName(self: *Parser, raw: []const u8) ![]const u8 {
        if (raw.len == 0) return RegexError.InvalidCharacterClass;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var i: usize = 0;
        var first = true;
        while (i < raw.len) {
            const cp = try readGroupNameCodepoint(raw, &i);
            if (first) {
                if (!unicode.isIdentifierStart(cp)) return RegexError.InvalidCharacterClass;
                first = false;
            } else if (!unicode.isIdentifierContinue(cp)) {
                return RegexError.InvalidCharacterClass;
            }

            var buf: [4]u8 = undefined;
            const len = unicode.encodeUtf8(cp, &buf) catch return RegexError.InvalidCharacterClass;
            try out.appendSlice(self.allocator, buf[0..len]);
        }

        if (first) return RegexError.InvalidCharacterClass;
        return out.toOwnedSlice(self.allocator);
    }

    fn readGroupNameCodepoint(raw: []const u8, i: *usize) !unicode.Codepoint {
        if (raw[i.*] == '\\') return readGroupNameEscape(raw, i);
        const dec = unicode.decodeUtf8Lenient(raw[i.*..]) orelse return RegexError.InvalidCharacterClass;
        i.* += dec.len;
        if (dec.codepoint >= 0xD800 and dec.codepoint <= 0xDBFF) {
            const save = i.*;
            const lo = if (i.* < raw.len and raw[i.*] == '\\')
                readGroupNameEscape(raw, i) catch blk: {
                    i.* = save;
                    break :blk 0;
                }
            else if (i.* < raw.len) blk: {
                const next = unicode.decodeUtf8Lenient(raw[i.*..]) orelse break :blk 0;
                i.* += next.len;
                break :blk next.codepoint;
            } else 0;

            if (lo >= 0xDC00 and lo <= 0xDFFF)
                return @intCast(0x10000 + ((dec.codepoint - 0xD800) << 10) + (lo - 0xDC00));
            i.* = save;
        }
        if (dec.codepoint >= 0xD800 and dec.codepoint <= 0xDFFF) return RegexError.InvalidEscapeSequence;
        return dec.codepoint;
    }

    fn readGroupNameEscape(raw: []const u8, i: *usize) !unicode.Codepoint {
        if (i.* + 1 >= raw.len or raw[i.* + 1] != 'u') return RegexError.InvalidEscapeSequence;
        i.* += 2;
        const cp = try readUnicodeEscapeCodepoint(raw, i);
        if (cp >= 0xD800 and cp <= 0xDBFF) {
            const save = i.*;
            if (i.* + 2 <= raw.len and raw[i.*] == '\\' and raw[i.* + 1] == 'u') {
                i.* += 2;
                const lo = try readUnicodeEscapeCodepoint(raw, i);
                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                    return @intCast(0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00));
                }
            }
            i.* = save;
        }
        if (cp >= 0xD800 and cp <= 0xDFFF) return RegexError.InvalidEscapeSequence;
        return @intCast(cp);
    }

    fn readUnicodeEscapeCodepoint(raw: []const u8, i: *usize) !u32 {
        var cp: u32 = 0;
        if (i.* < raw.len and raw[i.*] == '{') {
            i.* += 1;
            var n: usize = 0;
            while (i.* < raw.len) : (i.* += 1) {
                const d = hexValue(raw[i.*]) orelse break;
                cp = cp * 16 + d;
                n += 1;
                if (cp > 0x10FFFF) return RegexError.InvalidEscapeSequence;
            }
            if (n == 0 or i.* >= raw.len or raw[i.*] != '}') return RegexError.InvalidEscapeSequence;
            i.* += 1;
            return cp;
        }

        var n: usize = 0;
        while (n < 4) : (n += 1) {
            if (i.* + n >= raw.len) return RegexError.InvalidEscapeSequence;
            const d = hexValue(raw[i.* + n]) orelse return RegexError.InvalidEscapeSequence;
            cp = cp * 16 + d;
        }
        i.* += 4;
        return cp;
    }

    fn hexValue(c: u8) ?u8 {
        return switch (c) {
            '0'...'9' => |d| d - '0',
            'a'...'f' => |d| d - 'a' + 10,
            'A'...'F' => |d| d - 'A' + 10,
            else => null,
        };
    }

    /// Get POSIX character class by name
    fn getPosixClass(self: *Parser, name: []const u8) !common.CharClass {
        _ = self;
        if (std.mem.eql(u8, name, "alnum")) return common.CharClasses.posix_alnum;
        if (std.mem.eql(u8, name, "alpha")) return common.CharClasses.posix_alpha;
        if (std.mem.eql(u8, name, "blank")) return common.CharClasses.posix_blank;
        if (std.mem.eql(u8, name, "cntrl")) return common.CharClasses.posix_cntrl;
        if (std.mem.eql(u8, name, "digit")) return common.CharClasses.posix_digit;
        if (std.mem.eql(u8, name, "graph")) return common.CharClasses.posix_graph;
        if (std.mem.eql(u8, name, "lower")) return common.CharClasses.posix_lower;
        if (std.mem.eql(u8, name, "print")) return common.CharClasses.posix_print;
        if (std.mem.eql(u8, name, "punct")) return common.CharClasses.posix_punct;
        if (std.mem.eql(u8, name, "space")) return common.CharClasses.posix_space;
        if (std.mem.eql(u8, name, "upper")) return common.CharClasses.posix_upper;
        if (std.mem.eql(u8, name, "xdigit")) return common.CharClasses.posix_xdigit;
        return RegexError.InvalidCharacterClass;
    }

    /// Get literal character from token (special chars are literal inside [...])
    fn getCharClassChar(self: *Parser) ?u8 {
        return switch (self.current_token.token_type) {
            .literal => self.current_token.value,
            .escape_char => self.current_token.value,
            // Inside character class, special chars are treated as literals
            .dot => '.',
            .star => '*',
            .plus => '+',
            .question => '?',
            .pipe => '|',
            .lparen => '(',
            .rparen => ')',
            .lbrace => '{',
            .rbrace => '}',
            .dollar => '$',
            .lbracket => '[', // Allow [ as literal (for non-POSIX cases)
            .escape_b => 0x08, // Inside a class, \b is backspace, not a word boundary.
            // These should not appear here
            .rbracket, .caret, .backslash, .escape_d, .escape_D, .escape_w, .escape_W, .escape_s, .escape_S, .escape_B, .escape_A, .escape_z, .escape_Z, .backref, .escape_p, .escape_P, .eof => null,
        };
    }

    /// Parse character class [...]
    /// Append a shorthand class's ranges into a character-class range list. A
    /// non-negated class contributes its ranges directly; a negated one (`\D`,
    /// `\S`, `\W`) contributes the complement over the byte range [0, 255].
    fn appendClassRanges(self: *Parser, ranges: *std.ArrayList(common.CharRange), cc: common.CharClass) !void {
        if (!cc.negated) {
            for (cc.ranges) |r| try ranges.append(self.allocator, r);
            return;
        }
        // Sort a copy of the source ranges, then emit the gaps over [0, 255].
        var tmp: [16]common.CharRange = undefined;
        const n = @min(cc.ranges.len, tmp.len);
        @memcpy(tmp[0..n], cc.ranges[0..n]);
        std.mem.sort(common.CharRange, tmp[0..n], {}, struct {
            fn lt(_: void, a: common.CharRange, b: common.CharRange) bool {
                return a.start < b.start;
            }
        }.lt);
        var next: u16 = 0;
        for (tmp[0..n]) |r| {
            if (r.start > next) try ranges.append(self.allocator, common.CharRange.init(@intCast(next), @intCast(r.start - 1)));
            if (@as(u16, r.end) + 1 > next) next = @as(u16, r.end) + 1;
        }
        if (next <= 255) try ranges.append(self.allocator, common.CharRange.init(@intCast(next), 255));
    }

    // ===== `/v` (unicodeSets) character classes ============================
    // Parsed directly from raw input so code-point operands and the set
    // operators `&&`/`--` are representable. Supports ranges, \d\w\s and their
    // negations, \p{...}/\P{...}, nested [...] classes, union, intersection and
    // difference. `\q{...}` string literals and string-valued properties are not
    // handled (those patterns raise a syntax error).

    fn classHex(input: []const u8, i: *usize, n: usize) ?u21 {
        if (i.* + n > input.len) return null;
        var cp: u21 = 0;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const d = std.fmt.charToDigit(input[i.* + k], 16) catch return null;
            cp = cp * 16 + d;
        }
        i.* += n;
        return cp;
    }

    /// Read one code point at `i`, resolving escapes. Returns null if the next
    /// token isn't a plain character (i.e. it's `]`, `[`, or a class escape that
    /// the operand parser handles).
    fn isClassIdentityEscape(c: u8) bool {
        return switch (c) {
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/', '-' => true,
            else => false,
        };
    }

    fn readClassCp(input: []const u8, i: *usize, unicode_strict: bool) RegexError!?u21 {
        if (i.* >= input.len) return null;
        const c = input[i.*];
        if (c == ']' or c == '[') return null;
        if (c == '\\') {
            if (i.* + 1 >= input.len) return RegexError.InvalidEscapeSequence;
            const e = input[i.* + 1];
            switch (e) {
                'd', 'D', 'w', 'W', 's', 'S', 'p', 'P', 'q' => return null, // operand-level escapes
                'n' => {
                    i.* += 2;
                    return '\n';
                },
                'r' => {
                    i.* += 2;
                    return '\r';
                },
                't' => {
                    i.* += 2;
                    return '\t';
                },
                'f' => {
                    i.* += 2;
                    return 0x0C;
                },
                'v' => {
                    i.* += 2;
                    return 0x0B;
                },
                '0' => {
                    if (unicode_strict and i.* + 2 < input.len and std.ascii.isDigit(input[i.* + 2]))
                        return RegexError.InvalidEscapeSequence;
                    i.* += 2;
                    return 0;
                },
                '1'...'9' => {
                    if (unicode_strict) return RegexError.InvalidEscapeSequence;
                    i.* += 2;
                    return e;
                },
                'b' => {
                    i.* += 2;
                    return 0x08;
                },
                'c' => {
                    if (i.* + 2 < input.len and std.ascii.isAlphabetic(input[i.* + 2])) {
                        const x = input[i.* + 2];
                        i.* += 3;
                        return x % 32;
                    }
                    if (unicode_strict) return RegexError.InvalidEscapeSequence;
                    i.* += 2;
                    return 'c';
                },
                'x' => {
                    i.* += 2;
                    return classHex(input, i, 2) orelse return RegexError.InvalidEscapeSequence;
                },
                'u' => {
                    i.* += 2;
                    if (i.* < input.len and input[i.*] == '{') {
                        i.* += 1;
                        var cp: u21 = 0;
                        var any = false;
                        while (i.* < input.len and input[i.*] != '}') : (i.* += 1) {
                            const d = std.fmt.charToDigit(input[i.*], 16) catch return RegexError.InvalidEscapeSequence;
                            cp = @intCast(@as(u32, cp) * 16 + d);
                            any = true;
                        }
                        if (!any or i.* >= input.len) return RegexError.InvalidEscapeSequence;
                        i.* += 1; // consume }
                        return cp;
                    }
                    return classHex(input, i, 4) orelse return RegexError.InvalidEscapeSequence;
                },
                else => {
                    // Identity escape of a syntax character.
                    if (unicode_strict and !isClassIdentityEscape(e))
                        return RegexError.InvalidEscapeSequence;
                    i.* += 2;
                    return e;
                },
            }
        }
        const dec = unicode.decodeUtf8Lenient(input[i.*..]) orelse {
            i.* += 1;
            return c;
        };
        i.* += dec.len;
        return dec.codepoint;
    }

    fn appendEcmaWhitespaceItems(self: *Parser, items: *std.ArrayList(ast.Node.ClassItem)) !void {
        for ([_]ast.Node.CpRange{
            .{ .lo = 0x0009, .hi = 0x000D },
            .{ .lo = 0x0020, .hi = 0x0020 },
            .{ .lo = 0x00A0, .hi = 0x00A0 },
            .{ .lo = 0x1680, .hi = 0x1680 },
            .{ .lo = 0x2000, .hi = 0x200A },
            .{ .lo = 0x2028, .hi = 0x2029 },
            .{ .lo = 0x202F, .hi = 0x202F },
            .{ .lo = 0x205F, .hi = 0x205F },
            .{ .lo = 0x3000, .hi = 0x3000 },
            .{ .lo = 0xFEFF, .hi = 0xFEFF },
        }) |range| {
            try items.append(self.allocator, .{ .range = range });
        }
    }

    fn buildBuiltinClassSet(self: *Parser, kind: u8) RegexError!*ast.Node.ClassSet {
        var items: std.ArrayList(ast.Node.ClassItem) = .empty;
        errdefer items.deinit(self.allocator);

        const lower = std.ascii.toLower(kind);
        const negated = std.ascii.isUpper(kind);
        if (lower == 'd') {
            try items.append(self.allocator, .{ .range = .{ .lo = '0', .hi = '9' } });
        } else if (lower == 'w') {
            try items.append(self.allocator, .{ .range = .{ .lo = '0', .hi = '9' } });
            try items.append(self.allocator, .{ .range = .{ .lo = 'A', .hi = 'Z' } });
            try items.append(self.allocator, .{ .range = .{ .lo = 'a', .hi = 'z' } });
            try items.append(self.allocator, .{ .range = .{ .lo = '_', .hi = '_' } });
        } else { // 's'
            try self.appendEcmaWhitespaceItems(&items);
        }

        const set = try self.allocator.create(ast.Node.ClassSet);
        set.* = .{ .op = .union_, .negated = negated, .items = try items.toOwnedSlice(self.allocator) };
        return set;
    }

    fn createBuiltinClassSet(self: *Parser, kind: u8, span: common.Span) RegexError!*ast.Node {
        return ast.Node.createClassSet(self.allocator, try self.buildBuiltinClassSet(kind), span);
    }

    /// A `\d\w\s` (and negations) shorthand as a nested set of code-point ranges.
    fn builtinClassItem(self: *Parser, kind: u8) RegexError!ast.Node.ClassItem {
        const set = try self.buildBuiltinClassSet(kind);
        return .{ .nested = set };
    }

    fn byteClassItem(self: *Parser, cc: common.CharClass) RegexError!ast.Node.ClassItem {
        var items: std.ArrayList(ast.Node.ClassItem) = .empty;
        for (cc.ranges) |r| {
            try items.append(self.allocator, .{ .range = .{ .lo = r.start, .hi = r.end } });
        }
        const set = try self.allocator.create(ast.Node.ClassSet);
        set.* = .{ .op = .union_, .negated = cc.negated, .items = try items.toOwnedSlice(self.allocator) };
        return .{ .nested = set };
    }

    fn destroyClassSet(self: *Parser, set: *ast.Node.ClassSet) void {
        for (set.items) |item| self.destroyClassItem(item);
        self.allocator.free(set.items);
        self.allocator.destroy(set);
    }

    fn destroyClassItem(self: *Parser, item: ast.Node.ClassItem) void {
        switch (item) {
            .nested => |set| self.destroyClassSet(set),
            .string => |s| self.allocator.free(s),
            .range, .property => {},
        }
    }

    /// The set of strings for a `/v` property-of-strings, or null for an ordinary
    /// (code-point) property. Compact rule-derived string properties live here;
    /// full RGI_Emoji/ZWJ needs a dedicated generated sequence table.
    fn stringPropertyItem(self: *Parser, name: []const u8) RegexError!?ast.Node.ClassItem {
        var items: std.ArrayList(ast.Node.ClassItem) = .empty;
        if (std.mem.eql(u8, name, "Emoji_Keycap_Sequence")) {
            try self.appendKeycapStrings(&items);
        } else if (std.mem.eql(u8, name, "RGI_Emoji_Tag_Sequence")) {
            try self.appendStringItem(&items, &.{ 0x1F3F4, 0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F });
            try self.appendStringItem(&items, &.{ 0x1F3F4, 0xE0067, 0xE0062, 0xE0073, 0xE0063, 0xE0074, 0xE007F });
            try self.appendStringItem(&items, &.{ 0x1F3F4, 0xE0067, 0xE0062, 0xE0077, 0xE006C, 0xE0073, 0xE007F });
        } else if (std.mem.eql(u8, name, "RGI_Emoji_Modifier_Sequence")) {
            try self.appendModifierSequenceStrings(&items);
        } else if (std.mem.eql(u8, name, "RGI_Emoji_Flag_Sequence")) {
            try self.appendFlagSequenceStrings(&items);
        } else if (std.mem.eql(u8, name, "RGI_Emoji_ZWJ_Sequence")) {
            try self.appendZwjSequenceStrings(&items);
        } else if (std.mem.eql(u8, name, "RGI_Emoji")) {
            try self.appendRgiEmojiStrings(&items);
        } else if (std.mem.eql(u8, name, "Basic_Emoji")) {
            try self.appendBasicEmojiStrings(&items);
        } else {
            return null;
        }
        const set = try self.allocator.create(ast.Node.ClassSet);
        set.* = .{ .op = .union_, .items = try items.toOwnedSlice(self.allocator) };
        return .{ .nested = set };
    }

    fn appendStringItem(self: *Parser, items: *std.ArrayList(ast.Node.ClassItem), cps: []const u21) RegexError!void {
        const s = try self.allocator.dupe(u21, cps);
        try items.append(self.allocator, .{ .string = s });
    }

    fn appendKeycapStrings(self: *Parser, items: *std.ArrayList(ast.Node.ClassItem)) RegexError!void {
        for ([_]u21{ '#', '*', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' }) |b| {
            try self.appendStringItem(items, &.{ b, 0xFE0F, 0x20E3 });
        }
    }

    fn appendModifierSequenceStrings(self: *Parser, items: *std.ArrayList(ast.Node.ClassItem)) RegexError!void {
        for (prop_data.binaryRanges(.Emoji_Modifier_Base)) |r| {
            var cp: u21 = r.lo;
            while (cp <= r.hi) : (cp += 1) {
                var modifier: u21 = 0x1F3FB;
                while (modifier <= 0x1F3FF) : (modifier += 1) {
                    try self.appendStringItem(items, &.{ cp, modifier });
                }
            }
        }
    }

    fn appendFlagSequenceStrings(self: *Parser, items: *std.ArrayList(ast.Node.ClassItem)) RegexError!void {
        const regions = [_][2]u8{
            .{ 'A', 'C' }, .{ 'A', 'D' }, .{ 'A', 'E' }, .{ 'A', 'F' }, .{ 'A', 'G' }, .{ 'A', 'I' }, .{ 'A', 'L' }, .{ 'A', 'M' }, .{ 'A', 'O' }, .{ 'A', 'Q' }, .{ 'A', 'R' }, .{ 'A', 'S' },
            .{ 'A', 'T' }, .{ 'A', 'U' }, .{ 'A', 'W' }, .{ 'A', 'X' }, .{ 'A', 'Z' }, .{ 'B', 'A' }, .{ 'B', 'B' }, .{ 'B', 'D' }, .{ 'B', 'E' }, .{ 'B', 'F' }, .{ 'B', 'G' }, .{ 'B', 'H' },
            .{ 'B', 'I' }, .{ 'B', 'J' }, .{ 'B', 'L' }, .{ 'B', 'M' }, .{ 'B', 'N' }, .{ 'B', 'O' }, .{ 'B', 'Q' }, .{ 'B', 'R' }, .{ 'B', 'S' }, .{ 'B', 'T' }, .{ 'B', 'V' }, .{ 'B', 'W' },
            .{ 'B', 'Y' }, .{ 'B', 'Z' }, .{ 'C', 'A' }, .{ 'C', 'C' }, .{ 'C', 'D' }, .{ 'C', 'F' }, .{ 'C', 'G' }, .{ 'C', 'H' }, .{ 'C', 'I' }, .{ 'C', 'K' }, .{ 'C', 'L' }, .{ 'C', 'M' },
            .{ 'C', 'N' }, .{ 'C', 'O' }, .{ 'C', 'P' }, .{ 'C', 'Q' }, .{ 'C', 'R' }, .{ 'C', 'U' }, .{ 'C', 'V' }, .{ 'C', 'W' }, .{ 'C', 'X' }, .{ 'C', 'Y' }, .{ 'C', 'Z' }, .{ 'D', 'E' },
            .{ 'D', 'G' }, .{ 'D', 'J' }, .{ 'D', 'K' }, .{ 'D', 'M' }, .{ 'D', 'O' }, .{ 'D', 'Z' }, .{ 'E', 'A' }, .{ 'E', 'C' }, .{ 'E', 'E' }, .{ 'E', 'G' }, .{ 'E', 'H' }, .{ 'E', 'R' },
            .{ 'E', 'S' }, .{ 'E', 'T' }, .{ 'E', 'U' }, .{ 'F', 'I' }, .{ 'F', 'J' }, .{ 'F', 'K' }, .{ 'F', 'M' }, .{ 'F', 'O' }, .{ 'F', 'R' }, .{ 'G', 'A' }, .{ 'G', 'B' }, .{ 'G', 'D' },
            .{ 'G', 'E' }, .{ 'G', 'F' }, .{ 'G', 'G' }, .{ 'G', 'H' }, .{ 'G', 'I' }, .{ 'G', 'L' }, .{ 'G', 'M' }, .{ 'G', 'N' }, .{ 'G', 'P' }, .{ 'G', 'Q' }, .{ 'G', 'R' }, .{ 'G', 'S' },
            .{ 'G', 'T' }, .{ 'G', 'U' }, .{ 'G', 'W' }, .{ 'G', 'Y' }, .{ 'H', 'K' }, .{ 'H', 'M' }, .{ 'H', 'N' }, .{ 'H', 'R' }, .{ 'H', 'T' }, .{ 'H', 'U' }, .{ 'I', 'C' }, .{ 'I', 'D' },
            .{ 'I', 'E' }, .{ 'I', 'L' }, .{ 'I', 'M' }, .{ 'I', 'N' }, .{ 'I', 'O' }, .{ 'I', 'Q' }, .{ 'I', 'R' }, .{ 'I', 'S' }, .{ 'I', 'T' }, .{ 'J', 'E' }, .{ 'J', 'M' }, .{ 'J', 'O' },
            .{ 'J', 'P' }, .{ 'K', 'E' }, .{ 'K', 'G' }, .{ 'K', 'H' }, .{ 'K', 'I' }, .{ 'K', 'M' }, .{ 'K', 'N' }, .{ 'K', 'P' }, .{ 'K', 'R' }, .{ 'K', 'W' }, .{ 'K', 'Y' }, .{ 'K', 'Z' },
            .{ 'L', 'A' }, .{ 'L', 'B' }, .{ 'L', 'C' }, .{ 'L', 'I' }, .{ 'L', 'K' }, .{ 'L', 'R' }, .{ 'L', 'S' }, .{ 'L', 'T' }, .{ 'L', 'U' }, .{ 'L', 'V' }, .{ 'L', 'Y' }, .{ 'M', 'A' },
            .{ 'M', 'C' }, .{ 'M', 'D' }, .{ 'M', 'E' }, .{ 'M', 'F' }, .{ 'M', 'G' }, .{ 'M', 'H' }, .{ 'M', 'K' }, .{ 'M', 'L' }, .{ 'M', 'M' }, .{ 'M', 'N' }, .{ 'M', 'O' }, .{ 'M', 'P' },
            .{ 'M', 'Q' }, .{ 'M', 'R' }, .{ 'M', 'S' }, .{ 'M', 'T' }, .{ 'M', 'U' }, .{ 'M', 'V' }, .{ 'M', 'W' }, .{ 'M', 'X' }, .{ 'M', 'Y' }, .{ 'M', 'Z' }, .{ 'N', 'A' }, .{ 'N', 'C' },
            .{ 'N', 'E' }, .{ 'N', 'F' }, .{ 'N', 'G' }, .{ 'N', 'I' }, .{ 'N', 'L' }, .{ 'N', 'O' }, .{ 'N', 'P' }, .{ 'N', 'R' }, .{ 'N', 'U' }, .{ 'N', 'Z' }, .{ 'O', 'M' }, .{ 'P', 'A' },
            .{ 'P', 'E' }, .{ 'P', 'F' }, .{ 'P', 'G' }, .{ 'P', 'H' }, .{ 'P', 'K' }, .{ 'P', 'L' }, .{ 'P', 'M' }, .{ 'P', 'N' }, .{ 'P', 'R' }, .{ 'P', 'S' }, .{ 'P', 'T' }, .{ 'P', 'W' },
            .{ 'P', 'Y' }, .{ 'Q', 'A' }, .{ 'R', 'E' }, .{ 'R', 'O' }, .{ 'R', 'S' }, .{ 'R', 'U' }, .{ 'R', 'W' }, .{ 'S', 'A' }, .{ 'S', 'B' }, .{ 'S', 'C' }, .{ 'S', 'D' }, .{ 'S', 'E' },
            .{ 'S', 'G' }, .{ 'S', 'H' }, .{ 'S', 'I' }, .{ 'S', 'J' }, .{ 'S', 'K' }, .{ 'S', 'L' }, .{ 'S', 'M' }, .{ 'S', 'N' }, .{ 'S', 'O' }, .{ 'S', 'R' }, .{ 'S', 'S' }, .{ 'S', 'T' },
            .{ 'S', 'V' }, .{ 'S', 'X' }, .{ 'S', 'Y' }, .{ 'S', 'Z' }, .{ 'T', 'A' }, .{ 'T', 'C' }, .{ 'T', 'D' }, .{ 'T', 'F' }, .{ 'T', 'G' }, .{ 'T', 'H' }, .{ 'T', 'J' }, .{ 'T', 'K' },
            .{ 'T', 'L' }, .{ 'T', 'M' }, .{ 'T', 'N' }, .{ 'T', 'O' }, .{ 'T', 'R' }, .{ 'T', 'T' }, .{ 'T', 'V' }, .{ 'T', 'W' }, .{ 'T', 'Z' }, .{ 'U', 'A' }, .{ 'U', 'G' }, .{ 'U', 'M' },
            .{ 'U', 'N' }, .{ 'U', 'S' }, .{ 'U', 'Y' }, .{ 'U', 'Z' }, .{ 'V', 'A' }, .{ 'V', 'C' }, .{ 'V', 'E' }, .{ 'V', 'G' }, .{ 'V', 'I' }, .{ 'V', 'N' }, .{ 'V', 'U' }, .{ 'W', 'F' },
            .{ 'W', 'S' }, .{ 'X', 'K' }, .{ 'Y', 'E' }, .{ 'Y', 'T' }, .{ 'Z', 'A' }, .{ 'Z', 'M' }, .{ 'Z', 'W' },
        };
        for (regions) |region| {
            try self.appendStringItem(items, &.{
                0x1F1E6 + @as(u21, region[0] - 'A'),
                0x1F1E6 + @as(u21, region[1] - 'A'),
            });
        }
    }

    fn appendZwjSequenceStrings(self: *Parser, items: *std.ArrayList(ast.Node.ClassItem)) RegexError!void {
        for (rgi_data.zwj_sequences) |seq| {
            try self.appendStringItem(items, seq);
        }
    }

    fn appendRgiEmojiStrings(self: *Parser, items: *std.ArrayList(ast.Node.ClassItem)) RegexError!void {
        try self.appendBasicEmojiStrings(items);
        try self.appendKeycapStrings(items);
        try self.appendModifierSequenceStrings(items);
        try self.appendFlagSequenceStrings(items);
        try self.appendStringItem(items, &.{ 0x1F3F4, 0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F });
        try self.appendStringItem(items, &.{ 0x1F3F4, 0xE0067, 0xE0062, 0xE0073, 0xE0063, 0xE0074, 0xE007F });
        try self.appendStringItem(items, &.{ 0x1F3F4, 0xE0067, 0xE0062, 0xE0077, 0xE006C, 0xE0073, 0xE007F });
        try self.appendZwjSequenceStrings(items);
    }

    fn appendBasicEmojiStrings(self: *Parser, items: *std.ArrayList(ast.Node.ClassItem)) RegexError!void {
        for (prop_data.binaryRanges(.Emoji_Presentation)) |r| {
            var cp: u21 = r.lo;
            while (cp <= r.hi) : (cp += 1) {
                try self.appendStringItem(items, &.{cp});
            }
        }
        for (prop_data.binaryRanges(.Emoji)) |r| {
            var cp: u21 = r.lo;
            while (cp <= r.hi) : (cp += 1) {
                if (unicode.matchesSpec(cp, .{ .binary = .Emoji_Presentation })) continue;
                try self.appendStringItem(items, &.{ cp, 0xFE0F });
            }
        }
    }

    fn stringPropertyNode(self: *Parser, name: []const u8, span: common.Span) RegexError!*ast.Node {
        const item = (try self.stringPropertyItem(name)) orelse return RegexError.InvalidEscapeSequence;
        const set = switch (item) {
            .nested => |nested| nested,
            else => blk: {
                const items = try self.allocator.alloc(ast.Node.ClassItem, 1);
                items[0] = item;
                const nested = try self.allocator.create(ast.Node.ClassSet);
                nested.* = .{ .op = .union_, .items = items };
                break :blk nested;
            },
        };
        return ast.Node.createClassSet(self.allocator, set, span);
    }

    /// Parse one `\p{...}`/`\P{...}` property escape as a class item.
    fn propertyClassItem(self: *Parser, input: []const u8, i: *usize) RegexError!ast.Node.ClassItem {
        var neg = input[i.* + 1] == 'P';
        i.* += 2; // consume \p
        if (i.* >= input.len or input[i.*] != '{') return RegexError.InvalidEscapeSequence;
        i.* += 1;
        const begin = i.*;
        while (i.* < input.len and input[i.*] != '}') i.* += 1;
        if (i.* >= input.len) return RegexError.InvalidEscapeSequence;
        const body = input[begin..i.*];
        i.* += 1; // consume }
        var lhs: ?[]const u8 = null;
        var name = body;
        if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
            lhs = body[0..eq];
            name = body[eq + 1 ..];
        }
        if (lhs == null and name.len > 0 and name[0] == '^') {
            neg = !neg;
            name = name[1..];
            if (name.len == 0) return RegexError.InvalidEscapeSequence;
        }
        if (lhs == null) if (try self.stringPropertyItem(name)) |item| {
            // A property of strings can't be complemented (`\P{...}`).
            if (neg) return RegexError.UnexpectedCharacter;
            return item;
        };
        const spec = unicode.resolveProperty(lhs, name, self.unicode or self.unicode_sets) orelse return RegexError.InvalidEscapeSequence;
        return .{ .property = .{ .spec = spec, .negated = neg } };
    }

    /// Parse a `\q{a|bc|...}` string disjunction into a union of string items.
    fn parseQItem(self: *Parser, input: []const u8, i: *usize) RegexError!ast.Node.ClassItem {
        i.* += 2; // consume \q
        if (i.* >= input.len or input[i.*] != '{') return RegexError.InvalidEscapeSequence;
        i.* += 1; // consume {
        var alts: std.ArrayList(ast.Node.ClassItem) = .empty;
        while (true) {
            var cps: std.ArrayList(u21) = .empty;
            while (i.* < input.len and input[i.*] != '|' and input[i.*] != '}') {
                const cp = (try readClassCp(input, i, true)) orelse return RegexError.UnexpectedCharacter;
                try cps.append(self.allocator, cp);
            }
            try alts.append(self.allocator, .{ .string = try cps.toOwnedSlice(self.allocator) });
            if (i.* >= input.len) return RegexError.InvalidCharacterClass;
            if (input[i.*] == '}') {
                i.* += 1; // consume }
                break;
            }
            i.* += 1; // consume |
        }
        const set = try self.allocator.create(ast.Node.ClassSet);
        set.* = .{ .op = .union_, .items = try alts.toOwnedSlice(self.allocator) };
        return .{ .nested = set };
    }

    /// Parse one operand of a set expression (a range/char, escape, property, or
    /// nested class).
    fn isClassSetSyntaxChar(c: u8) bool {
        return switch (c) {
            '(', ')', '{', '}', '/', '-', '|' => true,
            else => false,
        };
    }

    fn isClassSetReservedDoublePunctuator(c: u8) bool {
        return switch (c) {
            '!', '#', '$', '%', '&', '*', '+', ',', '.', ':', ';', '<', '=', '>', '?', '@', '`', '~', '^' => true,
            else => false,
        };
    }

    fn classItemMayContainString(item: ast.Node.ClassItem) bool {
        return switch (item) {
            .string => true,
            .nested => |set| classSetMayContainString(set),
            .range, .property => false,
        };
    }

    fn classSetMayContainString(set: *const ast.Node.ClassSet) bool {
        for (set.items) |item| {
            if (classItemMayContainString(item)) return true;
        }
        return false;
    }

    fn parseSetOperand(self: *Parser, input: []const u8, i: *usize) RegexError!ast.Node.ClassItem {
        const c = input[i.*];
        if (c == '[') {
            i.* += 1;
            const nested = try self.parseSetExpr(input, i);
            if (i.* >= input.len or input[i.*] != ']') return RegexError.InvalidCharacterClass;
            i.* += 1; // consume ]
            return .{ .nested = nested };
        }
        if (c == '\\' and i.* + 1 < input.len) {
            const e = input[i.* + 1];
            switch (e) {
                'd', 'D', 'w', 'W', 's', 'S' => {
                    i.* += 2;
                    return self.builtinClassItem(e);
                },
                'p', 'P' => return self.propertyClassItem(input, i),
                'q' => return self.parseQItem(input, i),
                else => {},
            }
        }
        if (isClassSetSyntaxChar(c)) return RegexError.UnexpectedCharacter;
        if (i.* + 1 < input.len and input[i.* + 1] == c and isClassSetReservedDoublePunctuator(c))
            return RegexError.UnexpectedCharacter;
        const lo = (try readClassCp(input, i, true)) orelse return RegexError.InvalidCharacterClass;
        // A range `lo-hi`, but only when `-` is followed by a real character (a
        // double `-` is the difference operator, a trailing `-` is a literal).
        if (i.* < input.len and input[i.*] == '-' and i.* + 1 < input.len and
            input[i.* + 1] != '-' and input[i.* + 1] != ']')
        {
            i.* += 1; // consume -
            const hi = (try readClassCp(input, i, true)) orelse return RegexError.InvalidCharacterClass;
            if (hi < lo) return RegexError.InvalidCharacterClass;
            return .{ .range = .{ .lo = lo, .hi = hi } };
        }
        return .{ .range = .{ .lo = lo, .hi = lo } };
    }

    fn parseSetExpr(self: *Parser, input: []const u8, i: *usize) RegexError!*ast.Node.ClassSet {
        var negated = false;
        if (i.* < input.len and input[i.*] == '^') {
            negated = true;
            i.* += 1;
        }
        var items: std.ArrayList(ast.Node.ClassItem) = .empty;
        errdefer {
            for (items.items) |item| self.destroyClassItem(item);
            items.deinit(self.allocator);
        }
        var op: ast.Node.ClassOp = .union_;
        const first = try self.parseSetOperand(input, i);
        try items.append(self.allocator, first);

        // Determine the operator from what follows the first operand.
        if (i.* + 1 < input.len and input[i.*] == '&' and input[i.* + 1] == '&') {
            op = .intersection;
        } else if (i.* + 1 < input.len and input[i.*] == '-' and input[i.* + 1] == '-') {
            op = .difference;
        }

        if (op == .union_) {
            while (i.* < input.len and input[i.*] != ']') {
                try items.append(self.allocator, try self.parseSetOperand(input, i));
            }
        } else {
            const sep: u8 = if (op == .intersection) '&' else '-';
            while (i.* + 1 < input.len and input[i.*] == sep and input[i.* + 1] == sep) {
                i.* += 2; // consume operator
                try items.append(self.allocator, try self.parseSetOperand(input, i));
            }
        }

        if (negated) {
            for (items.items) |item| {
                if (classItemMayContainString(item)) return RegexError.UnexpectedCharacter;
            }
        }

        const set = try self.allocator.create(ast.Node.ClassSet);
        set.* = .{ .op = op, .negated = negated, .items = try items.toOwnedSlice(self.allocator) };
        return set;
    }

    fn parseClassSetV(self: *Parser) RegexError!*ast.Node {
        const input = self.lexer.input;
        const open = self.current_token.span.start; // position of '['
        var i: usize = open + 1;
        const set = try self.parseSetExpr(input, &i);
        if (i >= input.len or input[i] != ']') return RegexError.InvalidCharacterClass;
        i += 1; // consume ]
        // Resync the lexer to just past the class and re-read the next token.
        self.lexer.pos = i;
        self.lexer.pending_len = 0;
        self.lexer.pending_pos = 0;
        self.current_token = try self.lexer.next();
        return ast.Node.createClassSet(self.allocator, set, common.Span.init(open, i));
    }

    fn parseUnicodeClassAtom(self: *Parser, input: []const u8, i: *usize, unicode_strict: bool) RegexError!ast.Node.ClassItem {
        if (i.* < input.len and input[i.*] == '[' and i.* + 1 < input.len and input[i.* + 1] == ':') {
            var end = i.* + 2;
            while (end + 1 < input.len and !(input[end] == ':' and input[end + 1] == ']')) : (end += 1) {}
            if (end + 1 >= input.len) return RegexError.InvalidCharacterClass;
            const item = try self.byteClassItem(try self.getPosixClass(input[i.* + 2 .. end]));
            i.* = end + 2;
            return item;
        }

        if (i.* < input.len and input[i.*] == '\\' and i.* + 1 < input.len) {
            const e = input[i.* + 1];
            switch (e) {
                'd', 'D', 'w', 'W', 's', 'S' => {
                    i.* += 2;
                    return self.builtinClassItem(e);
                },
                'p', 'P' => return self.propertyClassItem(input, i),
                else => {},
            }
        }

        const cp = (try readClassCp(input, i, unicode_strict)) orelse return RegexError.InvalidCharacterClass;
        return .{ .range = .{ .lo = cp, .hi = cp } };
    }

    fn parseUnicodeCharClass(self: *Parser) RegexError!*ast.Node {
        const input = self.lexer.input;
        const open = self.current_token.span.start;
        var i: usize = open + 1;

        var negated = false;
        if (i < input.len and input[i] == '^') {
            negated = true;
            i += 1;
        }

        var items: std.ArrayList(ast.Node.ClassItem) = .empty;
        errdefer {
            for (items.items) |item| self.destroyClassItem(item);
            items.deinit(self.allocator);
        }

        while (i < input.len and input[i] != ']') {
            const item = try self.parseUnicodeClassAtom(input, &i, self.unicode or self.unicode_sets);
            if (i < input.len and input[i] == '-' and i + 1 < input.len and input[i + 1] != ']') {
                switch (item) {
                    .range => |lo| if (lo.lo == lo.hi) {
                        i += 1;
                        const hi_item = try self.parseUnicodeClassAtom(input, &i, self.unicode or self.unicode_sets);
                        switch (hi_item) {
                            .range => |hi| if (hi.lo == hi.hi) {
                                if (hi.lo < lo.lo) return RegexError.InvalidCharacterClass;
                                try items.append(self.allocator, .{ .range = .{ .lo = lo.lo, .hi = hi.lo } });
                                continue;
                            } else return RegexError.InvalidCharacterClass,
                            else => {
                                self.destroyClassItem(hi_item);
                                return RegexError.InvalidCharacterClass;
                            },
                        }
                    } else {},
                    else => {
                        self.destroyClassItem(item);
                        return RegexError.InvalidCharacterClass;
                    },
                }
            }
            try items.append(self.allocator, item);
        }

        if (i >= input.len or input[i] != ']') return RegexError.InvalidCharacterClass;
        i += 1;

        const set = try self.allocator.create(ast.Node.ClassSet);
        set.* = .{ .op = .union_, .negated = negated, .items = try items.toOwnedSlice(self.allocator) };

        self.lexer.pos = i;
        self.lexer.pending_len = 0;
        self.lexer.pending_pos = 0;
        self.current_token = try self.lexer.next();
        return ast.Node.createClassSet(self.allocator, set, common.Span.init(open, i));
    }

    fn currentClassContainsPropertyEscape(self: *Parser) bool {
        const input = self.lexer.input;
        var i = self.current_token.span.start + 1;
        while (i < input.len and input[i] != ']') : (i += 1) {
            if (input[i] == '\\' and i + 1 < input.len) {
                const e = input[i + 1];
                if (e == 'p' or e == 'P') return true;
                i += 1;
            }
        }
        return false;
    }

    fn currentClassNeedsCodepoints(self: *Parser) bool {
        const input = self.lexer.input;
        var i = self.current_token.span.start + 1;
        while (i < input.len) : (i += 1) {
            if (input[i] == ']') return false;
            if (input[i] >= 0x80) return true;
            if (input[i] == '\\' and i + 1 < input.len) {
                const e = input[i + 1];
                if (e == 'u' or e == 'x') return true;
                i += 1;
            }
        }
        return false;
    }

    fn parseCharClass(self: *Parser) !*ast.Node {
        // With the `v` flag, classes use set notation; parse from the raw input
        // (the byte-token stream can't represent code-point operands/operators).
        if (self.unicode_sets) return self.parseClassSetV();
        if (self.unicode) return self.parseUnicodeCharClass();
        if (self.currentClassContainsPropertyEscape()) return self.parseUnicodeCharClass();
        if (self.currentClassNeedsCodepoints()) return self.parseUnicodeCharClass();
        const start = self.current_token.span.start;
        try self.advance(); // consume [

        var negated = false;
        if (self.peek() == .caret) {
            negated = true;
            try self.advance();
        }

        var ranges: std.ArrayList(common.CharRange) = .empty;
        defer ranges.deinit(self.allocator);

        while (self.peek() != .rbracket and self.peek() != .eof) {
            // A `\d`/`\D`/`\w`/`\W`/`\s`/`\S` shorthand inside a class expands to
            // its character ranges (a negated shorthand contributes the complement
            // over the byte range).
            const shorthand: ?common.CharClass = switch (self.peek()) {
                .escape_d => common.CharClasses.digit,
                .escape_D => common.CharClasses.non_digit,
                .escape_w => common.CharClasses.word,
                .escape_W => common.CharClasses.non_word,
                .escape_s => common.CharClasses.whitespace,
                .escape_S => common.CharClasses.non_whitespace,
                else => null,
            };
            if (shorthand) |cc| {
                try self.appendClassRanges(&ranges, cc);
                try self.advance();
                continue;
            }
            // Check for POSIX character class [:name:]
            // We need to look ahead in the raw input, not the tokenized stream
            const current_pos = self.current_token.span.start;

            if (current_pos + 1 < self.lexer.input.len and
                self.lexer.input[current_pos] == '[' and
                self.lexer.input[current_pos + 1] == ':')
            {

                // Find the closing :]
                var found_posix = false;
                var i = current_pos + 2;
                while (i + 1 < self.lexer.input.len) : (i += 1) {
                    if (self.lexer.input[i] == ':' and self.lexer.input[i + 1] == ']') {
                        // Found [:name:]
                        const class_name = self.lexer.input[current_pos + 2 .. i];

                        // Skip to the character AFTER ':]' which should be the outer ']' or more chars
                        // We want the lexer to be positioned so that the NEXT token read will be correct
                        self.lexer.pos = i + 2; // Position after ':]'
                        // Since we're in the middle of parseCharClass, manually get next token
                        // This will be either ']' (end of class) or another character
                        self.current_token = try self.lexer.next();

                        // Add the POSIX class ranges
                        const posix_class = try self.getPosixClass(class_name);
                        for (posix_class.ranges) |range| {
                            try ranges.append(self.allocator, range);
                        }
                        found_posix = true;
                        break;
                    }
                }

                if (found_posix) {
                    continue; // Successfully parsed POSIX class, continue to next iteration
                }

                // Not a complete POSIX class, fall through to treat [ as literal
            }

            const first_char = self.getCharClassChar() orelse {
                return RegexError.InvalidCharacterClass;
            };
            try self.advance();

            // Check for range (a-z)
            // '-' is only a range operator if there's a character after it
            if (self.peek() == .literal and self.current_token.value == '-') {
                // Look ahead to see if there's another character (not ])
                const saved_pos = self.lexer.pos;
                try self.advance(); // consume -

                if (self.peek() == .rbracket or self.peek() == .eof) {
                    // '-' at end of class, treat both first_char and '-' as literals
                    try ranges.append(self.allocator, common.CharRange.init(first_char, first_char));
                    try ranges.append(self.allocator, common.CharRange.init('-', '-'));
                } else {
                    // It's a range
                    const second_char = self.getCharClassChar() orelse {
                        // Not a valid char, backtrack and treat '-' as literal
                        self.lexer.pos = saved_pos;
                        try ranges.append(self.allocator, common.CharRange.init(first_char, first_char));
                        continue;
                    };
                    try self.advance();

                    // NonemptyClassRanges: a range whose start code point is
                    // greater than its end (e.g. `[d-G]`/`[z-a]`) is a SyntaxError
                    // in every mode (not an Annex B exception). This parser is
                    // byte-based, so a `\u`/multibyte escape expands to several
                    // bytes whose individual order is not the code-point order —
                    // only flag ranges whose BOTH bounds are single ASCII bytes
                    // (< 0x80), where byte order is code-point order. (A reversed
                    // multibyte range is rare and unreliable to detect by byte.)
                    if (first_char < 0x80 and second_char < 0x80 and first_char > second_char)
                        return RegexError.InvalidCharacterClass;
                    try ranges.append(self.allocator, common.CharRange.init(first_char, second_char));
                }
            } else {
                // Single character
                try ranges.append(self.allocator, common.CharRange.init(first_char, first_char));
            }
        }

        try self.expect(.rbracket);

        const char_class = common.CharClass{
            .ranges = try ranges.toOwnedSlice(self.allocator),
            .negated = negated,
        };

        const span = common.Span.init(start, self.current_token.span.end);
        return ast.Node.createCharClass(self.allocator, char_class, span);
    }
};

test "lexer basic tokens" {
    var lexer = Lexer.init("a*b+c?");

    const t1 = try lexer.next();
    try std.testing.expectEqual(TokenType.literal, t1.token_type);
    try std.testing.expectEqual(@as(u8, 'a'), t1.value);

    const t2 = try lexer.next();
    try std.testing.expectEqual(TokenType.star, t2.token_type);

    const t3 = try lexer.next();
    try std.testing.expectEqual(TokenType.literal, t3.token_type);
    try std.testing.expectEqual(@as(u8, 'b'), t3.value);

    const t4 = try lexer.next();
    try std.testing.expectEqual(TokenType.plus, t4.token_type);

    const t5 = try lexer.next();
    try std.testing.expectEqual(TokenType.literal, t5.token_type);

    const t6 = try lexer.next();
    try std.testing.expectEqual(TokenType.question, t6.token_type);
}

test "lexer escape sequences" {
    var lexer = Lexer.init("\\d\\w\\s\\n");

    const t1 = try lexer.next();
    try std.testing.expectEqual(TokenType.escape_d, t1.token_type);

    const t2 = try lexer.next();
    try std.testing.expectEqual(TokenType.escape_w, t2.token_type);

    const t3 = try lexer.next();
    try std.testing.expectEqual(TokenType.escape_s, t3.token_type);

    const t4 = try lexer.next();
    try std.testing.expectEqual(TokenType.escape_char, t4.token_type);
    try std.testing.expectEqual(@as(u8, '\n'), t4.value);
}

test "parser simple literal" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "abc");
    var result = try parser.parse();
    defer result.deinit();

    try std.testing.expectEqual(ast.NodeType.concat, result.root.node_type);
}

test "parser alternation" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "a|b");
    var result = try parser.parse();
    defer result.deinit();

    try std.testing.expectEqual(ast.NodeType.alternation, result.root.node_type);
}

test "parser star" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "a*");
    var result = try parser.parse();
    defer result.deinit();

    try std.testing.expectEqual(ast.NodeType.star, result.root.node_type);
}

test "parser group" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "(ab)");
    var result = try parser.parse();
    defer result.deinit();

    try std.testing.expectEqual(ast.NodeType.group, result.root.node_type);
    try std.testing.expectEqual(@as(usize, 1), result.capture_count);
}

// Temporarily disabled - POSIX parsing needs redesign
// test "POSIX character class parsing" {
//     const allocator = std.testing.allocator;
//     var parser = try Parser.init(allocator, "[[:alpha:]]");
//     var tree = try parser.parse();
//     defer tree.deinit();
//
//     try std.testing.expectEqual(ast.NodeType.char_class, tree.root.node_type);
// }

test "parser: nesting depth limit" {
    const allocator = std.testing.allocator;

    // Create a pattern with 513 levels of nesting (exceeds MAX_NESTING_DEPTH of 512)
    var pattern_buf: [1100]u8 = undefined;
    var pos: usize = 0;

    // Write 513 opening parens
    for (0..513) |_| {
        pattern_buf[pos] = '(';
        pos += 1;
    }

    // Write 'a' in the middle
    pattern_buf[pos] = 'a';
    pos += 1;

    // Write 513 closing parens
    for (0..513) |_| {
        pattern_buf[pos] = ')';
        pos += 1;
    }

    const pattern = pattern_buf[0..pos];
    var parser = try Parser.init(allocator, pattern);
    const result = parser.parse();

    try std.testing.expectError(RegexError.NestingTooDeep, result);
}

test "parser: acceptable nesting depth" {
    const allocator = std.testing.allocator;

    // Create a pattern with 200 levels of nesting (well within MAX_NESTING_DEPTH of 512)
    var pattern_buf: [500]u8 = undefined;
    var pos: usize = 0;

    // Write 200 opening parens
    for (0..200) |_| {
        pattern_buf[pos] = '(';
        pos += 1;
    }

    // Write 'a' in the middle
    pattern_buf[pos] = 'a';
    pos += 1;

    // Write 200 closing parens
    for (0..200) |_| {
        pattern_buf[pos] = ')';
        pos += 1;
    }

    const pattern = pattern_buf[0..pos];
    var parser = try Parser.init(allocator, pattern);
    var result = try parser.parse();
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 200), result.capture_count);
}
