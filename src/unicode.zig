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
            // Reject overlong encodings: 2-byte sequences must encode values >= 0x80
            if (cp < 0x80) return error.InvalidUtf8;
            break :blk cp;
        },
        3 => blk: {
            if ((bytes[1] & 0b11000000) != 0b10000000) return error.InvalidUtf8;
            if ((bytes[2] & 0b11000000) != 0b10000000) return error.InvalidUtf8;
            const cp = (@as(Codepoint, first & 0b00001111) << 12) |
                (@as(Codepoint, bytes[1] & 0b00111111) << 6) |
                (bytes[2] & 0b00111111);
            // Reject overlong encodings: 3-byte sequences must encode values >= 0x800
            if (cp < 0x800) return error.InvalidUtf8;
            // Reject surrogates (0xD800-0xDFFF) - not valid Unicode scalar values
            if (cp >= 0xD800 and cp <= 0xDFFF) return error.InvalidUtf8;
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
            // Reject overlong encodings: 4-byte sequences must encode values >= 0x10000
            if (cp < 0x10000) return error.InvalidUtf8;
            // Reject values beyond valid Unicode range
            if (cp > 0x10FFFF) return error.InvalidUtf8;
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
        const map = std.StaticStringMap(UnicodeProperty).initComptime(.{
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

// Edge case tests
test "unicode: invalid UTF-8 sequences" {
    // Truncated multi-byte sequence
    const truncated = [_]u8{ 0xC3 }; // Should be 2 bytes but only 1
    try std.testing.expectError(error.InvalidUtf8, decodeUtf8(&truncated));

    // Invalid continuation byte
    const invalid_cont = [_]u8{ 0xC3, 0x00 }; // Second byte should be 10xxxxxx
    try std.testing.expectError(error.InvalidUtf8, decodeUtf8(&invalid_cont));

    // Empty input
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectError(error.InvalidUtf8, decodeUtf8(empty));
}

test "unicode: encode buffer too small" {
    var buffer: [1]u8 = undefined;

    // Try to encode 2-byte character into 1-byte buffer
    try std.testing.expectError(error.BufferTooSmall, encodeUtf8(0x00E9, &buffer));

    // Try to encode 4-byte character into 1-byte buffer
    try std.testing.expectError(error.BufferTooSmall, encodeUtf8(0x1D573, &buffer));
}

test "unicode: invalid codepoints" {
    var buffer: [4]u8 = undefined;

    // Codepoint beyond valid Unicode range (> U+10FFFF)
    try std.testing.expectError(error.InvalidCodepoint, encodeUtf8(0x110000, &buffer));
    try std.testing.expectError(error.InvalidCodepoint, encodeUtf8(0x1FFFFF, &buffer));
}

test "unicode: boundary codepoints" {
    var buffer: [4]u8 = undefined;

    // Test boundary at 1-byte/2-byte (U+007F, U+0080)
    const len1 = try encodeUtf8(0x7F, &buffer);
    try std.testing.expectEqual(@as(u3, 1), len1);

    const len2 = try encodeUtf8(0x80, &buffer);
    try std.testing.expectEqual(@as(u3, 2), len2);

    // Test boundary at 2-byte/3-byte (U+07FF, U+0800)
    const len2b = try encodeUtf8(0x7FF, &buffer);
    try std.testing.expectEqual(@as(u3, 2), len2b);

    const len3 = try encodeUtf8(0x800, &buffer);
    try std.testing.expectEqual(@as(u3, 3), len3);

    // Test boundary at 3-byte/4-byte (U+FFFF, U+10000)
    const len3b = try encodeUtf8(0xFFFF, &buffer);
    try std.testing.expectEqual(@as(u3, 3), len3b);

    const len4 = try encodeUtf8(0x10000, &buffer);
    try std.testing.expectEqual(@as(u3, 4), len4);

    // Test maximum valid codepoint (U+10FFFF)
    const len_max = try encodeUtf8(0x10FFFF, &buffer);
    try std.testing.expectEqual(@as(u3, 4), len_max);
}

test "unicode: round-trip encoding/decoding" {
    var buffer: [4]u8 = undefined;

    // Test various codepoints can be encoded and decoded back
    const test_codepoints = [_]Codepoint{
        0x0000, 0x007F,        // ASCII boundaries
        0x0080, 0x07FF,        // 2-byte boundaries
        0x0800, 0xFFFF,        // 3-byte boundaries
        0x10000, 0x10FFFF,     // 4-byte boundaries
        'a', 'Z', '0', '9',    // Common ASCII
        0x00E9, 0x20AC,        // Common non-ASCII
    };

    for (test_codepoints) |cp| {
        const len = try encodeUtf8(cp, &buffer);
        const decoded = try decodeUtf8(buffer[0..len]);
        try std.testing.expectEqual(cp, decoded.codepoint);
        try std.testing.expectEqual(len, decoded.len);
    }
}

test "unicode: category boundary cases" {
    // Test boundaries between categories
    try std.testing.expectEqual(GeneralCategory.Lu, getGeneralCategory('A'));
    try std.testing.expectEqual(GeneralCategory.Lu, getGeneralCategory('Z'));
    try std.testing.expectEqual(GeneralCategory.Ll, getGeneralCategory('a'));
    try std.testing.expectEqual(GeneralCategory.Ll, getGeneralCategory('z'));
    try std.testing.expectEqual(GeneralCategory.Nd, getGeneralCategory('0'));
    try std.testing.expectEqual(GeneralCategory.Nd, getGeneralCategory('9'));

    // Control characters
    try std.testing.expectEqual(GeneralCategory.Cc, getGeneralCategory(0x00));
    try std.testing.expectEqual(GeneralCategory.Cc, getGeneralCategory(0x1F));
    try std.testing.expectEqual(GeneralCategory.Cc, getGeneralCategory(0x7F));

    // Latin-1 boundaries
    try std.testing.expectEqual(GeneralCategory.Lu, getGeneralCategory(0xC0));
    try std.testing.expectEqual(GeneralCategory.Lu, getGeneralCategory(0xD6));
    try std.testing.expectEqual(GeneralCategory.Ll, getGeneralCategory(0xE0));
    try std.testing.expectEqual(GeneralCategory.Ll, getGeneralCategory(0xF6));

    // Default to unassigned for unmapped ranges
    try std.testing.expectEqual(GeneralCategory.Cn, getGeneralCategory(0xFFFE));
}

test "unicode: property matching edge cases" {
    // Test null character
    try std.testing.expect(!matchesProperty(0x00, .Letter));
    try std.testing.expect(matchesProperty(0x00, .Control));

    // Test DEL character
    try std.testing.expect(!matchesProperty(0x7F, .Letter));
    try std.testing.expect(matchesProperty(0x7F, .Control));

    // Test non-breaking space
    try std.testing.expect(matchesProperty(0xA0, .Space_Separator));
    try std.testing.expect(!matchesProperty(0xA0, .Letter));

    // Test punctuation
    try std.testing.expect(matchesProperty('!', .Punctuation));
    try std.testing.expect(matchesProperty('.', .Punctuation));
    try std.testing.expect(matchesProperty(',', .Punctuation));
    try std.testing.expect(!matchesProperty('a', .Punctuation));

    // Test that unmapped properties return false
    try std.testing.expect(!matchesProperty('a', .Other_Letter));
    try std.testing.expect(!matchesProperty('5', .Letter_Number));
}

test "unicode: whitespace variations" {
    // Standard whitespace
    try std.testing.expect(isWhitespace(' '));
    try std.testing.expect(isWhitespace('\t'));
    try std.testing.expect(isWhitespace('\n'));
    try std.testing.expect(isWhitespace('\r'));
    try std.testing.expect(isWhitespace(0x0B)); // VT
    try std.testing.expect(isWhitespace(0x0C)); // FF

    // Non-breaking space
    try std.testing.expect(isWhitespace(0xA0));

    // Not whitespace
    try std.testing.expect(!isWhitespace('a'));
    try std.testing.expect(!isWhitespace('0'));
    try std.testing.expect(!isWhitespace(0x00));
}

test "unicode: alphanumeric edge cases" {
    // Alphanumeric
    try std.testing.expect(isAlphanumeric('a'));
    try std.testing.expect(isAlphanumeric('Z'));
    try std.testing.expect(isAlphanumeric('0'));
    try std.testing.expect(isAlphanumeric('9'));
    try std.testing.expect(isAlphanumeric('é'));

    // Not alphanumeric
    try std.testing.expect(!isAlphanumeric(' '));
    try std.testing.expect(!isAlphanumeric('!'));
    try std.testing.expect(!isAlphanumeric('.'));
    try std.testing.expect(!isAlphanumeric(0x00));
    try std.testing.expect(!isAlphanumeric(0x7F));
}

test "unicode: property fromString edge cases" {
    // Valid short forms
    try std.testing.expect(UnicodeProperty.fromString("L") != null);
    try std.testing.expect(UnicodeProperty.fromString("N") != null);
    try std.testing.expect(UnicodeProperty.fromString("P") != null);

    // Valid long forms
    try std.testing.expect(UnicodeProperty.fromString("Letter") != null);
    try std.testing.expect(UnicodeProperty.fromString("Number") != null);
    try std.testing.expect(UnicodeProperty.fromString("Punctuation") != null);

    // Invalid/unmapped properties
    try std.testing.expect(UnicodeProperty.fromString("InvalidProperty") == null);
    try std.testing.expect(UnicodeProperty.fromString("") == null);
    try std.testing.expect(UnicodeProperty.fromString("XYZ") == null);

    // Case sensitivity
    try std.testing.expect(UnicodeProperty.fromString("letter") == null); // lowercase
    try std.testing.expect(UnicodeProperty.fromString("LETTER") == null); // uppercase
}

test "unicode: CJK and extended ranges" {
    // CJK Unified Ideographs (simplified to Lo category)
    try std.testing.expectEqual(GeneralCategory.Lo, getGeneralCategory(0x4E00));
    try std.testing.expectEqual(GeneralCategory.Lo, getGeneralCategory(0x9FFF));
    try std.testing.expect(matchesProperty(0x4E00, .Letter));

    // Hangul Syllables
    try std.testing.expectEqual(GeneralCategory.Lo, getGeneralCategory(0xAC00));
    try std.testing.expectEqual(GeneralCategory.Lo, getGeneralCategory(0xD7AF));
    try std.testing.expect(matchesProperty(0xAC00, .Letter));

    // Arabic
    try std.testing.expectEqual(GeneralCategory.Lo, getGeneralCategory(0x0600));
    try std.testing.expect(matchesProperty(0x0600, .Letter));
}

// Stress and integration tests
test "unicode: stress test - encode/decode 10000 random codepoints" {
    var buffer: [4]u8 = undefined;

    // Test a wide range of codepoints
    var cp: Codepoint = 0;
    var count: usize = 0;
    while (count < 10000) : (count += 1) {
        // Skip surrogate range (0xD800-0xDFFF)
        if (cp >= 0xD800 and cp <= 0xDFFF) {
            cp = 0xE000;
        }
        if (cp > 0x10FFFF) break;

        const len = try encodeUtf8(cp, &buffer);
        const decoded = try decodeUtf8(buffer[0..len]);
        try std.testing.expectEqual(cp, decoded.codepoint);
        try std.testing.expectEqual(len, decoded.len);

        cp += 53; // Prime number for better distribution
    }
}

test "unicode: all ASCII characters encode/decode correctly" {
    var buffer: [4]u8 = undefined;

    var i: u8 = 0;
    while (true) {
        const len = try encodeUtf8(i, &buffer);
        try std.testing.expectEqual(@as(u3, 1), len);
        const decoded = try decodeUtf8(buffer[0..len]);
        try std.testing.expectEqual(@as(Codepoint, i), decoded.codepoint);

        if (i == 127) break;
        i += 1;
    }
}

test "unicode: consecutive invalid UTF-8 bytes" {
    // Invalid continuation bytes (0xC0 is a 2-byte lead but 0xC0 is not a valid continuation)
    const invalid2 = [_]u8{ 0xC0, 0xC0 };
    try std.testing.expectError(error.InvalidUtf8, decodeUtf8(&invalid2));

    // Invalid 3-byte sequence - second byte invalid
    const invalid3 = [_]u8{ 0xE0, 0xFF, 0xFF };
    try std.testing.expectError(error.InvalidUtf8, decodeUtf8(&invalid3));

    // Invalid 4-byte sequence - second byte invalid
    const invalid4 = [_]u8{ 0xF0, 0x00, 0x80, 0x80 };
    try std.testing.expectError(error.InvalidUtf8, decodeUtf8(&invalid4));
}

test "unicode: overlong encoding rejection" {
    // Overlong encodings are security vulnerabilities and must be rejected
    // RFC 3629 requires shortest form encoding

    // 2-byte overlong for NULL (0x00)
    const overlong2 = [_]u8{ 0xC0, 0x80 };
    try std.testing.expectError(error.InvalidUtf8, decodeUtf8(&overlong2));

    // 2-byte overlong for 'A' (0x41)
    const overlong2b = [_]u8{ 0xC1, 0x81 };
    try std.testing.expectError(error.InvalidUtf8, decodeUtf8(&overlong2b));

    // 3-byte overlong for 'A' (0x41)
    const overlong3 = [_]u8{ 0xE0, 0x81, 0x81 };
    try std.testing.expectError(error.InvalidUtf8, decodeUtf8(&overlong3));

    // 4-byte overlong for 'A' (0x41)
    const overlong4 = [_]u8{ 0xF0, 0x80, 0x81, 0x81 };
    try std.testing.expectError(error.InvalidUtf8, decodeUtf8(&overlong4));

    // 3-byte overlong for 0xFF (should be 2-byte)
    const overlong3b = [_]u8{ 0xE0, 0x83, 0xBF };
    try std.testing.expectError(error.InvalidUtf8, decodeUtf8(&overlong3b));
}

test "unicode: surrogate pair rejection" {
    // UTF-8 should never contain surrogate pairs (0xD800-0xDFFF)
    // These are only used in UTF-16 encoding

    // 0xD800 encoded as 3-byte UTF-8 (invalid)
    const surrogate1 = [_]u8{ 0xED, 0xA0, 0x80 };
    try std.testing.expectError(error.InvalidUtf8, decodeUtf8(&surrogate1));

    // 0xDFFF encoded as 3-byte UTF-8 (invalid)
    const surrogate2 = [_]u8{ 0xED, 0xBF, 0xBF };
    try std.testing.expectError(error.InvalidUtf8, decodeUtf8(&surrogate2));

    // Just before surrogate range (0xD7FF) should be valid
    const valid_before = [_]u8{ 0xED, 0x9F, 0xBF };
    const result1 = try decodeUtf8(&valid_before);
    try std.testing.expectEqual(@as(Codepoint, 0xD7FF), result1.codepoint);

    // Just after surrogate range (0xE000) should be valid
    const valid_after = [_]u8{ 0xEE, 0x80, 0x80 };
    const result2 = try decodeUtf8(&valid_after);
    try std.testing.expectEqual(@as(Codepoint, 0xE000), result2.codepoint);
}

test "unicode: category consistency across ranges" {
    // All uppercase ASCII should be Lu
    var i: Codepoint = 'A';
    while (i <= 'Z') : (i += 1) {
        try std.testing.expectEqual(GeneralCategory.Lu, getGeneralCategory(i));
        try std.testing.expect(isLetter(i));
        try std.testing.expect(!isDigit(i));
    }

    // All lowercase ASCII should be Ll
    i = 'a';
    while (i <= 'z') : (i += 1) {
        try std.testing.expectEqual(GeneralCategory.Ll, getGeneralCategory(i));
        try std.testing.expect(isLetter(i));
        try std.testing.expect(!isDigit(i));
    }

    // All digits should be Nd
    i = '0';
    while (i <= '9') : (i += 1) {
        try std.testing.expectEqual(GeneralCategory.Nd, getGeneralCategory(i));
        try std.testing.expect(isDigit(i));
        try std.testing.expect(!isLetter(i));
    }
}

test "unicode: property matching consistency" {
    // Letter property should include both uppercase and lowercase
    try std.testing.expect(matchesProperty('A', .Letter));
    try std.testing.expect(matchesProperty('a', .Letter));
    try std.testing.expect(matchesProperty('Z', .Letter));
    try std.testing.expect(matchesProperty('z', .Letter));

    // But not digits or punctuation
    try std.testing.expect(!matchesProperty('0', .Letter));
    try std.testing.expect(!matchesProperty('!', .Letter));

    // Number property should include all digits
    var i: Codepoint = '0';
    while (i <= '9') : (i += 1) {
        try std.testing.expect(matchesProperty(i, .Number));
    }
}

test "unicode: encode to exact size buffers" {
    // 1-byte codepoint in 1-byte buffer
    var buf1: [1]u8 = undefined;
    const len1 = try encodeUtf8('a', &buf1);
    try std.testing.expectEqual(@as(u3, 1), len1);

    // 2-byte codepoint in 2-byte buffer
    var buf2: [2]u8 = undefined;
    const len2 = try encodeUtf8(0xE9, &buf2);
    try std.testing.expectEqual(@as(u3, 2), len2);

    // 3-byte codepoint in 3-byte buffer
    var buf3: [3]u8 = undefined;
    const len3 = try encodeUtf8(0x20AC, &buf3);
    try std.testing.expectEqual(@as(u3, 3), len3);

    // 4-byte codepoint in 4-byte buffer
    var buf4: [4]u8 = undefined;
    const len4 = try encodeUtf8(0x1D573, &buf4);
    try std.testing.expectEqual(@as(u3, 4), len4);
}

test "unicode: byte sequence length for all UTF-8 lead bytes" {
    // ASCII range (0x00-0x7F) -> 1 byte
    try std.testing.expectEqual(@as(u3, 1), utf8ByteSequenceLength(0x00));
    try std.testing.expectEqual(@as(u3, 1), utf8ByteSequenceLength(0x7F));

    // 2-byte lead (0xC0-0xDF) -> 2 bytes
    try std.testing.expectEqual(@as(u3, 2), utf8ByteSequenceLength(0xC0));
    try std.testing.expectEqual(@as(u3, 2), utf8ByteSequenceLength(0xDF));

    // 3-byte lead (0xE0-0xEF) -> 3 bytes
    try std.testing.expectEqual(@as(u3, 3), utf8ByteSequenceLength(0xE0));
    try std.testing.expectEqual(@as(u3, 3), utf8ByteSequenceLength(0xEF));

    // 4-byte lead (0xF0-0xF7) -> 4 bytes
    try std.testing.expectEqual(@as(u3, 4), utf8ByteSequenceLength(0xF0));
    try std.testing.expectEqual(@as(u3, 4), utf8ByteSequenceLength(0xF7));

    // Invalid bytes -> 1 (fallback)
    try std.testing.expectEqual(@as(u3, 1), utf8ByteSequenceLength(0xFF));
}

test "unicode: whitespace categorization comprehensive" {
    // Standard whitespace characters
    const whitespace_chars = [_]Codepoint{ ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0xA0 };

    for (whitespace_chars) |ws| {
        try std.testing.expect(isWhitespace(ws));
        try std.testing.expect(!isAlphanumeric(ws));
        try std.testing.expect(!isDigit(ws));
        try std.testing.expect(!isLetter(ws));
    }
}

test "unicode: zero codepoint handling" {
    var buffer: [4]u8 = undefined;

    // Encode NULL codepoint
    const len = try encodeUtf8(0, &buffer);
    try std.testing.expectEqual(@as(u3, 1), len);
    try std.testing.expectEqual(@as(u8, 0), buffer[0]);

    // Decode NULL codepoint
    const decoded = try decodeUtf8(buffer[0..len]);
    try std.testing.expectEqual(@as(Codepoint, 0), decoded.codepoint);

    // NULL is a control character
    try std.testing.expectEqual(GeneralCategory.Cc, getGeneralCategory(0));
    try std.testing.expect(matchesProperty(0, .Control));
}
