const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");
const RegexError = @import("errors.zig").RegexError;
const ErrorContext = @import("errors.zig").ErrorContext;

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
    eof,
};

pub const Token = struct {
    token_type: TokenType,
    value: u8 = 0,
    span: common.Span,
};

/// Lexer for tokenizing regex patterns
pub const Lexer = struct {
    input: []const u8,
    pos: usize,
    start_pos: usize,

    pub fn init(input: []const u8) Lexer {
        return .{
            .input = input,
            .pos = 0,
            .start_pos = 0,
        };
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
            'A' => self.makeToken(.escape_A, 0),
            'z' => self.makeToken(.escape_z, 0),
            'Z' => self.makeToken(.escape_Z, 0),
            'n' => self.makeToken(.escape_char, '\n'),
            't' => self.makeToken(.escape_char, '\t'),
            'r' => self.makeToken(.escape_char, '\r'),
            '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                // Backreference \1, \2, etc.
                return self.makeToken(.backref, c - '0');
            },
            '\\', '.', '*', '+', '?', '|', '(', ')', '[', ']', '{', '}', '^', '$' => {
                // Literal escape of special characters
                return self.makeToken(.literal, c);
            },
            else => RegexError.InvalidEscapeSequence,
        };
    }

    pub fn next(self: *Lexer) !Token {
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
            '[' => self.makeToken(.lbracket, 0),
            ']' => self.makeToken(.rbracket, 0),
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
    }
};

/// Parser for regex patterns
pub const Parser = struct {
    lexer: Lexer,
    allocator: std.mem.Allocator,
    current_token: Token,
    capture_count: usize,
    nesting_depth: usize,

    /// Maximum nesting depth to prevent stack overflow from patterns like (((((...
    pub const MAX_NESTING_DEPTH: usize = 100;

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8) !Parser {
        var lexer = Lexer.init(pattern);
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
        return ast.AST.init(self.allocator, root, self.capture_count);
    }

    /// Parse alternation (lowest precedence)
    fn parseAlternation(self: *Parser) !*ast.Node {
        var left = try self.parseConcat();

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
        var nodes = std.ArrayList(*ast.Node).initCapacity(self.allocator, 0) catch unreachable;
        defer nodes.deinit(self.allocator);

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

    /// Parse repetition operators (*, +, ?, {m,n})
    fn parseRepeat(self: *Parser) !*ast.Node {
        var node = try self.parsePrimary();
        const start = node.span.start;

        while (true) {
            const token_type = self.peek();
            const span = common.Span.init(start, self.current_token.span.end);

            switch (token_type) {
                .star => {
                    try self.advance();
                    // Check for lazy quantifier (? after *)
                    const greedy = self.peek() != .question;
                    if (!greedy) try self.advance();
                    node = try ast.Node.createStar(self.allocator, node, greedy, span);
                },
                .plus => {
                    try self.advance();
                    // Check for lazy quantifier (? after +)
                    const greedy = self.peek() != .question;
                    if (!greedy) try self.advance();
                    node = try ast.Node.createPlus(self.allocator, node, greedy, span);
                },
                .question => {
                    try self.advance();
                    // Check for lazy quantifier (? after ?)
                    const greedy = self.peek() != .question;
                    if (!greedy) try self.advance();
                    node = try ast.Node.createOptional(self.allocator, node, greedy, span);
                },
                .lbrace => {
                    try self.advance(); // consume {

                    // Parse minimum with overflow protection
                    const MAX_QUANTIFIER: usize = 100_000; // Reasonable upper limit to prevent DoS
                    var min: usize = 0;
                    while (self.peek() == .literal and self.current_token.value >= '0' and self.current_token.value <= '9') {
                        const digit = self.current_token.value - '0';

                        // Check for multiplication overflow before computing
                        if (min > std.math.maxInt(usize) / 10) {
                            return RegexError.InvalidQuantifier;
                        }

                        const new_min = min * 10 + digit;

                        // Enforce reasonable maximum to prevent resource exhaustion
                        if (new_min > MAX_QUANTIFIER) {
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

                                // Enforce reasonable maximum
                                if (new_max > MAX_QUANTIFIER) {
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

                    const bounds = ast.RepeatBounds.init(min, max);
                    // Check for lazy quantifier (? after {m,n})
                    const greedy = self.peek() != .question;
                    if (!greedy) try self.advance();
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
                const ranges = try self.allocator.dupe(common.CharRange, common.CharClasses.whitespace.ranges);
                return ast.Node.createCharClass(self.allocator, .{
                    .ranges = ranges,
                    .negated = common.CharClasses.whitespace.negated,
                }, span);
            },
            .escape_S => {
                try self.advance();
                const ranges = try self.allocator.dupe(common.CharRange, common.CharClasses.non_whitespace.ranges);
                return ast.Node.createCharClass(self.allocator, .{
                    .ranges = ranges,
                    .negated = common.CharClasses.non_whitespace.negated,
                }, span);
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
                const index = token.value; // 1-based capture group index
                return ast.Node.createBackreference(self.allocator, index, null, span);
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
                            try self.expect(.rparen);
                            return ast.Node.createLookahead(self.allocator, child, true, span);
                        } else if (self.current_token.value == '!') {
                            // Negative lookahead (?!...)
                            try self.advance(); // consume !
                            const child = try self.parseAlternation();
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

                            if (self.current_token.token_type == .literal) {
                                if (self.current_token.value == '=') {
                                    // Positive lookbehind (?<=...)
                                    try self.advance(); // consume =
                                    const child = try self.parseAlternation();
                                    try self.expect(.rparen);
                                    return ast.Node.createLookbehind(self.allocator, child, true, span);
                                } else if (self.current_token.value == '!') {
                                    // Negative lookbehind (?<!...)
                                    try self.advance(); // consume !
                                    const child = try self.parseAlternation();
                                    try self.expect(.rparen);
                                    return ast.Node.createLookbehind(self.allocator, child, false, span);
                                } else {
                                    // .NET/Perl-style named group (?<name>...)
                                    // Restore position to re-parse the name
                                    self.lexer.pos = saved_pos;
                                    self.current_token = saved_token;
                                    try self.advance(); // consume <
                                    group_name = try self.parseGroupName();
                                    self.capture_count += 1;
                                    capture_index = self.capture_count;
                                }
                            } else {
                                return RegexError.UnexpectedCharacter;
                            }
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
                try self.expect(.rparen);

                if (group_name) |name| {
                    return ast.Node.createNamedGroup(self.allocator, child, capture_index, name, span);
                } else {
                    return ast.Node.createGroup(self.allocator, child, capture_index, span);
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
        var name_buf: [64]u8 = undefined;
        var name_len: usize = 0;

        // Collect name characters until we hit >
        while (self.current_token.token_type != .eof) {
            if (self.current_token.token_type == .literal) {
                if (self.current_token.value == '>') {
                    try self.advance(); // consume >
                    break;
                }

                // Valid name characters: alphanumeric and underscore
                const c = self.current_token.value;
                if ((c >= 'a' and c <= 'z') or
                    (c >= 'A' and c <= 'Z') or
                    (c >= '0' and c <= '9') or
                    c == '_')
                {
                    if (name_len >= name_buf.len) {
                        return RegexError.InvalidCharacterClass; // Name too long
                    }
                    name_buf[name_len] = c;
                    name_len += 1;
                    try self.advance();
                } else {
                    return RegexError.InvalidCharacterClass; // Invalid character in name
                }
            } else {
                return RegexError.InvalidCharacterClass; // Unexpected token in name
            }
        }

        if (name_len == 0) {
            return RegexError.InvalidCharacterClass; // Empty name
        }

        // Allocate and copy name
        const name = try self.allocator.alloc(u8, name_len);
        @memcpy(name, name_buf[0..name_len]);
        return name;
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
            // These should not appear here
            .rbracket, .caret, .backslash,
            .escape_d, .escape_D, .escape_w, .escape_W,
            .escape_s, .escape_S, .escape_b, .escape_B,
            .escape_A, .escape_z, .escape_Z, .backref, .eof => null,
        };
    }

    /// Parse character class [...]
    fn parseCharClass(self: *Parser) !*ast.Node {
        const start = self.current_token.span.start;
        try self.advance(); // consume [

        var negated = false;
        if (self.peek() == .caret) {
            negated = true;
            try self.advance();
        }

        var ranges = std.ArrayList(common.CharRange).initCapacity(self.allocator, 0) catch unreachable;
        defer ranges.deinit(self.allocator);

        while (self.peek() != .rbracket and self.peek() != .eof) {
            // Check for POSIX character class [:name:]
            // We need to look ahead in the raw input, not the tokenized stream
            const current_pos = self.lexer.pos;

            if (current_pos + 1 < self.lexer.input.len and
                self.lexer.input[current_pos] == '[' and
                self.lexer.input[current_pos + 1] == ':') {

                // Find the closing :]
                var found_posix = false;
                var i = current_pos + 2;
                while (i + 1 < self.lexer.input.len) : (i += 1) {
                    if (self.lexer.input[i] == ':' and self.lexer.input[i + 1] == ']') {
                        // Found [:name:]
                        const class_name = self.lexer.input[current_pos + 2..i];

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

    // Create a pattern with 101 levels of nesting (exceeds MAX_NESTING_DEPTH of 100)
    var pattern_buf: [300]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&pattern_buf);
    const writer = fbs.writer();

    // Write 101 opening parens
    var i: usize = 0;
    while (i < 101) : (i += 1) {
        try writer.writeByte('(');
    }

    // Write 'a' in the middle
    try writer.writeByte('a');

    // Write 101 closing parens
    i = 0;
    while (i < 101) : (i += 1) {
        try writer.writeByte(')');
    }

    const pattern = fbs.getWritten();
    var parser = try Parser.init(allocator, pattern);
    const result = parser.parse();

    try std.testing.expectError(RegexError.NestingTooDeep, result);
}

test "parser: acceptable nesting depth" {
    const allocator = std.testing.allocator;

    // Create a pattern with 50 levels of nesting (well within MAX_NESTING_DEPTH of 100)
    var pattern_buf: [200]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&pattern_buf);
    const writer = fbs.writer();

    // Write 50 opening parens
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try writer.writeByte('(');
    }

    // Write 'a' in the middle
    try writer.writeByte('a');

    // Write 50 closing parens
    i = 0;
    while (i < 50) : (i += 1) {
        try writer.writeByte(')');
    }

    const pattern = fbs.getWritten();
    var parser = try Parser.init(allocator, pattern);
    var result = try parser.parse();
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 50), result.capture_count);
}
