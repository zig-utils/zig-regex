const std = @import("std");

/// Unicode codepoint
pub const Codepoint = u21;

/// Get the length in bytes of a UTF-8 encoded character from its first byte
pub fn utf8ByteSequenceLength(first_byte: u8) u3 {
    if (first_byte < 0b10000000) return 1;
    if (first_byte < 0b11100000) return 2;
    if (first_byte < 0b11110000) return 3;
    if (first_byte < 0b11111000) return 4;
    return 1; // Invalid UTF-8, treat as single byte
}

/// Decode a UTF-8 codepoint from a byte slice
/// Returns the codepoint and the number of bytes consumed
pub fn decodeUtf8(bytes: []const u8) !struct { codepoint: Codepoint, len: u3 } {
    if (bytes.len == 0) return error.InvalidUtf8;

    const first = bytes[0];
    const len = utf8ByteSequenceLength(first);

    if (bytes.len < len) return error.InvalidUtf8;

    const codepoint: Codepoint = switch (len) {
        1 => first,
        2 => blk: {
            if ((bytes[1] & 0b11000000) != 0b10000000) return error.InvalidUtf8;
            const cp = (@as(Codepoint, first & 0b00011111) << 6) | (bytes[1] & 0b00111111);
            break :blk cp;
        },
        3 => blk: {
            if ((bytes[1] & 0b11000000) != 0b10000000) return error.InvalidUtf8;
            if ((bytes[2] & 0b11000000) != 0b10000000) return error.InvalidUtf8;
            const cp = (@as(Codepoint, first & 0b00001111) << 12) |
                (@as(Codepoint, bytes[1] & 0b00111111) << 6) |
                (bytes[2] & 0b00111111);
            break :blk cp;
        },
        4 => blk: {
            if ((bytes[1] & 0b11000000) != 0b10000000) return error.InvalidUtf8;
            if ((bytes[2] & 0b11000000) != 0b10000000) return error.InvalidUtf8;
            if ((bytes[3] & 0b11000000) != 0b10000000) return error.InvalidUtf8;
            const cp = (@as(Codepoint, first & 0b00000111) << 18) |
                (@as(Codepoint, bytes[1] & 0b00111111) << 12) |
                (@as(Codepoint, bytes[2] & 0b00111111) << 6) |
                (bytes[3] & 0b00111111);
            break :blk cp;
        },
        else => return error.InvalidUtf8,
    };

    return .{ .codepoint = codepoint, .len = len };
}

/// Encode a codepoint to UTF-8 bytes
pub fn encodeUtf8(codepoint: Codepoint, buffer: []u8) !u3 {
    if (codepoint <= 0x7F) {
        if (buffer.len < 1) return error.BufferTooSmall;
        buffer[0] = @intCast(codepoint);
        return 1;
    } else if (codepoint <= 0x7FF) {
        if (buffer.len < 2) return error.BufferTooSmall;
        buffer[0] = @intCast(0b11000000 | (codepoint >> 6));
        buffer[1] = @intCast(0b10000000 | (codepoint & 0b00111111));
        return 2;
    } else if (codepoint <= 0xFFFF) {
        if (buffer.len < 3) return error.BufferTooSmall;
        buffer[0] = @intCast(0b11100000 | (codepoint >> 12));
        buffer[1] = @intCast(0b10000000 | ((codepoint >> 6) & 0b00111111));
        buffer[2] = @intCast(0b10000000 | (codepoint & 0b00111111));
        return 3;
    } else if (codepoint <= 0x10FFFF) {
        if (buffer.len < 4) return error.BufferTooSmall;
        buffer[0] = @intCast(0b11110000 | (codepoint >> 18));
        buffer[1] = @intCast(0b10000000 | ((codepoint >> 12) & 0b00111111));
        buffer[2] = @intCast(0b10000000 | ((codepoint >> 6) & 0b00111111));
        buffer[3] = @intCast(0b10000000 | (codepoint & 0b00111111));
        return 4;
    } else {
        return error.InvalidCodepoint;
    }
}

/// Unicode General Category
pub const GeneralCategory = enum {
    // Letters
    Lu, // Letter, uppercase
    Ll, // Letter, lowercase
    Lt, // Letter, titlecase
    Lm, // Letter, modifier
    Lo, // Letter, other

    // Marks
    Mn, // Mark, nonspacing
    Mc, // Mark, spacing combining
    Me, // Mark, enclosing

    // Numbers
    Nd, // Number, decimal digit
    Nl, // Number, letter
    No, // Number, other

    // Punctuation
    Pc, // Punctuation, connector
    Pd, // Punctuation, dash
    Ps, // Punctuation, open
    Pe, // Punctuation, close
    Pi, // Punctuation, initial quote
    Pf, // Punctuation, final quote
    Po, // Punctuation, other

    // Symbols
    Sm, // Symbol, math
    Sc, // Symbol, currency
    Sk, // Symbol, modifier
    So, // Symbol, other

    // Separators
    Zs, // Separator, space
    Zl, // Separator, line
    Zp, // Separator, paragraph

    // Other
    Cc, // Other, control
    Cf, // Other, format
    Cs, // Other, surrogate
    Co, // Other, private use
    Cn, // Other, not assigned
};

/// Get the Unicode General Category for a codepoint
/// This is a simplified implementation covering common ranges
pub fn getGeneralCategory(cp: Codepoint) GeneralCategory {
    // ASCII fast path
    if (cp < 0x80) {
        if (cp >= 'A' and cp <= 'Z') return .Lu;
        if (cp >= 'a' and cp <= 'z') return .Ll;
        if (cp >= '0' and cp <= '9') return .Nd;
        if (cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r') return .Zs;
        if (cp <= 0x1F or cp == 0x7F) return .Cc;
        // Punctuation and symbols
        if ((cp >= 0x21 and cp <= 0x2F) or (cp >= 0x3A and cp <= 0x40) or
            (cp >= 0x5B and cp <= 0x60) or (cp >= 0x7B and cp <= 0x7E))
        {
            // Simplified: treat all as punctuation
            return .Po;
        }
        return .Cn;
    }

    // Latin-1 Supplement (0x80-0xFF)
    if (cp <= 0xFF) {
        if (cp >= 0xC0 and cp <= 0xD6) return .Lu;
        if (cp >= 0xD8 and cp <= 0xDE) return .Lu;
        if (cp >= 0xE0 and cp <= 0xF6) return .Ll;
        if (cp >= 0xF8 and cp <= 0xFF) return .Ll;
        if (cp >= 0x80 and cp <= 0x9F) return .Cc;
        if (cp == 0xA0) return .Zs;
        return .Po; // Simplified for other Latin-1 symbols
    }

    // Basic Multilingual Plane (BMP) ranges
    // This is a simplified categorization
    if (cp >= 0x0100 and cp <= 0x017F) return .Ll; // Latin Extended-A (simplified)
    if (cp >= 0x0180 and cp <= 0x024F) return .Ll; // Latin Extended-B (simplified)
    if (cp >= 0x0370 and cp <= 0x03FF) return .Ll; // Greek (simplified)
    if (cp >= 0x0400 and cp <= 0x04FF) return .Ll; // Cyrillic (simplified)
    if (cp >= 0x0600 and cp <= 0x06FF) return .Lo; // Arabic
    if (cp >= 0x4E00 and cp <= 0x9FFF) return .Lo; // CJK Unified Ideographs
    if (cp >= 0xAC00 and cp <= 0xD7AF) return .Lo; // Hangul Syllables

    // Default to unassigned for anything else
    return .Cn;
}

/// Check if a codepoint is in a Unicode category
pub fn isInCategory(cp: Codepoint, category: GeneralCategory) bool {
    return getGeneralCategory(cp) == category;
}

/// Check if a codepoint is a letter
pub fn isLetter(cp: Codepoint) bool {
    const cat = getGeneralCategory(cp);
    return cat == .Lu or cat == .Ll or cat == .Lt or cat == .Lm or cat == .Lo;
}

/// Check if a codepoint is a decimal digit
pub fn isDigit(cp: Codepoint) bool {
    return getGeneralCategory(cp) == .Nd;
}

/// Check if a codepoint is alphanumeric
pub fn isAlphanumeric(cp: Codepoint) bool {
    return isLetter(cp) or isDigit(cp);
}

/// Check if a codepoint is whitespace
pub fn isWhitespace(cp: Codepoint) bool {
    const cat = getGeneralCategory(cp);
    return cat == .Zs or cat == .Zl or cat == .Zp or
        cp == '\t' or cp == '\n' or cp == '\r' or cp == 0x0B or cp == 0x0C;
}

test "UTF-8 decoding" {
    // ASCII
    const ascii = try decodeUtf8("a");
    try std.testing.expectEqual(@as(Codepoint, 'a'), ascii.codepoint);
    try std.testing.expectEqual(@as(u3, 1), ascii.len);

    // 2-byte (é = U+00E9)
    const two_byte = try decodeUtf8("é");
    try std.testing.expectEqual(@as(Codepoint, 0x00E9), two_byte.codepoint);
    try std.testing.expectEqual(@as(u3, 2), two_byte.len);

    // 3-byte (€ = U+20AC)
    const three_byte = try decodeUtf8("€");
    try std.testing.expectEqual(@as(Codepoint, 0x20AC), three_byte.codepoint);
    try std.testing.expectEqual(@as(u3, 3), three_byte.len);

    // 4-byte (𝕳 = U+1D573)
    const four_byte = try decodeUtf8("𝕳");
    try std.testing.expectEqual(@as(Codepoint, 0x1D573), four_byte.codepoint);
    try std.testing.expectEqual(@as(u3, 4), four_byte.len);
}

test "UTF-8 encoding" {
    var buffer: [4]u8 = undefined;

    // ASCII
    const len1 = try encodeUtf8('a', &buffer);
    try std.testing.expectEqual(@as(u3, 1), len1);
    try std.testing.expectEqualStrings("a", buffer[0..len1]);

    // 2-byte
    const len2 = try encodeUtf8(0x00E9, &buffer);
    try std.testing.expectEqual(@as(u3, 2), len2);
    try std.testing.expectEqualStrings("é", buffer[0..len2]);

    // 3-byte
    const len3 = try encodeUtf8(0x20AC, &buffer);
    try std.testing.expectEqual(@as(u3, 3), len3);
    try std.testing.expectEqualStrings("€", buffer[0..len3]);

    // 4-byte
    const len4 = try encodeUtf8(0x1D573, &buffer);
    try std.testing.expectEqual(@as(u3, 4), len4);
    try std.testing.expectEqualStrings("𝕳", buffer[0..len4]);
}

/// Unicode property names for \p{Property} matching
pub const UnicodeProperty = enum {
    // General categories (short & long forms)
    Letter, L,
    Lowercase_Letter, Ll,
    Uppercase_Letter, Lu,
    Titlecase_Letter, Lt,
    Modifier_Letter, Lm,
    Other_Letter, Lo,

    Mark, M,
    Nonspacing_Mark, Mn,
    Spacing_Mark, Mc,
    Enclosing_Mark, Me,

    Number, N,
    Decimal_Number, Nd,
    Letter_Number, Nl,
    Other_Number, No,

    Punctuation, P,
    Connector_Punctuation, Pc,
    Dash_Punctuation, Pd,
    Open_Punctuation, Ps,
    Close_Punctuation, Pe,
    Initial_Punctuation, Pi,
    Final_Punctuation, Pf,
    Other_Punctuation, Po,

    Symbol, S,
    Math_Symbol, Sm,
    Currency_Symbol, Sc,
    Modifier_Symbol, Sk,
    Other_Symbol, So,

    Separator, Z,
    Space_Separator, Zs,
    Line_Separator, Zl,
    Paragraph_Separator, Zp,

    Other, C,
    Control, Cc,
    Format, Cf,
    Surrogate, Cs,
    Private_Use, Co,
    Not_Assigned, Cn,

    pub fn fromString(s: []const u8) ?UnicodeProperty {
        const map = std.ComptimeStringMap(UnicodeProperty, .{
            .{ "Letter", .Letter }, .{ "L", .L },
            .{ "Lowercase_Letter", .Lowercase_Letter }, .{ "Ll", .Ll },
            .{ "Uppercase_Letter", .Uppercase_Letter }, .{ "Lu", .Lu },
            .{ "Number", .Number }, .{ "N", .N },
            .{ "Decimal_Number", .Decimal_Number }, .{ "Nd", .Nd },
            .{ "Punctuation", .Punctuation }, .{ "P", .P },
            .{ "Symbol", .Symbol }, .{ "S", .S },
            .{ "Separator", .Separator }, .{ "Z", .Z },
            .{ "Space_Separator", .Space_Separator }, .{ "Zs", .Zs },
            .{ "Control", .Control }, .{ "Cc", .Cc },
        });
        return map.get(s);
    }
};

/// Check if codepoint matches a Unicode property
pub fn matchesProperty(cp: Codepoint, property: UnicodeProperty) bool {
    return switch (property) {
        .Letter, .L => isLetter(cp),
        .Lowercase_Letter, .Ll => isInCategory(cp, .Ll),
        .Uppercase_Letter, .Lu => isInCategory(cp, .Lu),
        .Number, .N => isDigit(cp),
        .Decimal_Number, .Nd => isInCategory(cp, .Nd),
        .Punctuation, .P => blk: {
            const cat = getGeneralCategory(cp);
            break :blk cat == .Pc or cat == .Pd or cat == .Ps or
                cat == .Pe or cat == .Pi or cat == .Pf or cat == .Po;
        },
        .Space_Separator, .Zs => isInCategory(cp, .Zs),
        .Control, .Cc => isInCategory(cp, .Cc),
        else => false,
    };
}

test "Unicode categories" {
    try std.testing.expect(isLetter('a'));
    try std.testing.expect(isLetter('Z'));
    try std.testing.expect(isLetter('é'));
    try std.testing.expect(!isLetter('5'));

    try std.testing.expect(isDigit('0'));
    try std.testing.expect(isDigit('9'));
    try std.testing.expect(!isDigit('a'));

    try std.testing.expect(isWhitespace(' '));
    try std.testing.expect(isWhitespace('\t'));
    try std.testing.expect(isWhitespace('\n'));
    try std.testing.expect(!isWhitespace('a'));
}

test "Unicode property matching" {
    try std.testing.expect(matchesProperty('a', .Letter));
    try std.testing.expect(matchesProperty('A', .Uppercase_Letter));
    try std.testing.expect(matchesProperty('5', .Number));
    try std.testing.expect(matchesProperty(' ', .Space_Separator));
    try std.testing.expect(!matchesProperty('a', .Number));
}
