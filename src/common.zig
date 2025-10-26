const std = @import("std");

/// Character type used throughout the library
pub const Char = u8;

/// Position in the input string
pub const Position = usize;

/// Represents a range of characters (for character classes)
pub const CharRange = struct {
    start: Char,
    end: Char,

    pub fn contains(self: CharRange, c: Char) bool {
        return c >= self.start and c <= self.end;
    }

    pub fn init(start: Char, end: Char) CharRange {
        return .{ .start = start, .end = end };
    }
};

/// Character class - represents a set of characters
pub const CharClass = struct {
    ranges: []const CharRange,
    negated: bool = false,

    pub fn matches(self: CharClass, c: Char) bool {
        var found = false;
        for (self.ranges) |range| {
            if (range.contains(c)) {
                found = true;
                break;
            }
        }
        return if (self.negated) !found else found;
    }
};

/// Regex compilation flags
pub const CompileFlags = packed struct {
    case_insensitive: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    extended: bool = false,
    unicode: bool = false,
};

/// Span in the source pattern (for error reporting)
pub const Span = struct {
    start: Position,
    end: Position,

    pub fn init(start: Position, end: Position) Span {
        return .{ .start = start, .end = end };
    }

    pub fn len(self: Span) usize {
        return self.end - self.start;
    }
};

/// Predefined character classes
pub const CharClasses = struct {
    /// Digits: [0-9]
    pub const digit = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('0', '9'),
        },
        .negated = false,
    };

    /// Non-digits: [^0-9]
    pub const non_digit = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('0', '9'),
        },
        .negated = true,
    };

    /// Word characters: [a-zA-Z0-9_]
    pub const word = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('a', 'z'),
            CharRange.init('A', 'Z'),
            CharRange.init('0', '9'),
            CharRange.init('_', '_'),
        },
        .negated = false,
    };

    /// Non-word characters: [^a-zA-Z0-9_]
    pub const non_word = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init('a', 'z'),
            CharRange.init('A', 'Z'),
            CharRange.init('0', '9'),
            CharRange.init('_', '_'),
        },
        .negated = true,
    };

    /// Whitespace: [ \t\n\r\f\v]
    pub const whitespace = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init(' ', ' '),
            CharRange.init('\t', '\t'),
            CharRange.init('\n', '\n'),
            CharRange.init('\r', '\r'),
            CharRange.init(0x0C, 0x0C), // \f
            CharRange.init(0x0B, 0x0B), // \v
        },
        .negated = false,
    };

    /// Non-whitespace: [^ \t\n\r\f\v]
    pub const non_whitespace = CharClass{
        .ranges = &[_]CharRange{
            CharRange.init(' ', ' '),
            CharRange.init('\t', '\t'),
            CharRange.init('\n', '\n'),
            CharRange.init('\r', '\r'),
            CharRange.init(0x0C, 0x0C), // \f
            CharRange.init(0x0B, 0x0B), // \v
        },
        .negated = true,
    };
};

test "char range contains" {
    const range = CharRange.init('a', 'z');
    try std.testing.expect(range.contains('a'));
    try std.testing.expect(range.contains('m'));
    try std.testing.expect(range.contains('z'));
    try std.testing.expect(!range.contains('A'));
    try std.testing.expect(!range.contains('0'));
}

test "char class matches" {
    const digit_class = CharClasses.digit;
    try std.testing.expect(digit_class.matches('0'));
    try std.testing.expect(digit_class.matches('5'));
    try std.testing.expect(digit_class.matches('9'));
    try std.testing.expect(!digit_class.matches('a'));

    const non_digit_class = CharClasses.non_digit;
    try std.testing.expect(!non_digit_class.matches('0'));
    try std.testing.expect(non_digit_class.matches('a'));
}

test "word char class" {
    const word_class = CharClasses.word;
    try std.testing.expect(word_class.matches('a'));
    try std.testing.expect(word_class.matches('Z'));
    try std.testing.expect(word_class.matches('5'));
    try std.testing.expect(word_class.matches('_'));
    try std.testing.expect(!word_class.matches(' '));
    try std.testing.expect(!word_class.matches('-'));
}

test "whitespace char class" {
    const ws_class = CharClasses.whitespace;
    try std.testing.expect(ws_class.matches(' '));
    try std.testing.expect(ws_class.matches('\t'));
    try std.testing.expect(ws_class.matches('\n'));
    try std.testing.expect(!ws_class.matches('a'));
}
