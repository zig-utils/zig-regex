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

const gc_data = @import("unicode_gc_data.zig");

/// Get the Unicode General Category for a codepoint, via a binary search over
/// the generated `UnicodeData.txt` range table. Code points outside every
/// listed range are unassigned (`Cn`).
pub fn getGeneralCategory(cp: Codepoint) GeneralCategory {
    const ranges = gc_data.gc_ranges;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.start) {
            hi = mid;
        } else if (cp > r.end) {
            lo = mid + 1;
        } else {
            return r.cat;
        }
    }
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
    Letter,
    L,
    Cased_Letter,
    LC,
    Lowercase_Letter,
    Ll,
    Uppercase_Letter,
    Lu,
    Titlecase_Letter,
    Lt,
    Modifier_Letter,
    Lm,
    Other_Letter,
    Lo,

    Mark,
    M,
    Nonspacing_Mark,
    Mn,
    Spacing_Mark,
    Mc,
    Enclosing_Mark,
    Me,

    Number,
    N,
    Decimal_Number,
    Nd,
    Letter_Number,
    Nl,
    Other_Number,
    No,

    Punctuation,
    P,
    Connector_Punctuation,
    Pc,
    Dash_Punctuation,
    Pd,
    Open_Punctuation,
    Ps,
    Close_Punctuation,
    Pe,
    Initial_Punctuation,
    Pi,
    Final_Punctuation,
    Pf,
    Other_Punctuation,
    Po,

    Symbol,
    S,
    Math_Symbol,
    Sm,
    Currency_Symbol,
    Sc,
    Modifier_Symbol,
    Sk,
    Other_Symbol,
    So,

    Separator,
    Z,
    Space_Separator,
    Zs,
    Line_Separator,
    Zl,
    Paragraph_Separator,
    Zp,

    Other,
    C,
    Control,
    Cc,
    Format,
    Cf,
    Surrogate,
    Cs,
    Private_Use,
    Co,
    Not_Assigned,
    Cn,

    pub fn fromString(s: []const u8) ?UnicodeProperty {
        const map = std.StaticStringMap(UnicodeProperty).initComptime(.{
            .{ "Letter", .Letter },                     .{ "L", .L },
            .{ "Cased_Letter", .Cased_Letter },         .{ "LC", .LC },
            .{ "Lowercase_Letter", .Lowercase_Letter }, .{ "Ll", .Ll },
            .{ "Uppercase_Letter", .Uppercase_Letter }, .{ "Lu", .Lu },
            .{ "Titlecase_Letter", .Titlecase_Letter }, .{ "Lt", .Lt },
            .{ "Modifier_Letter", .Modifier_Letter },   .{ "Lm", .Lm },
            .{ "Other_Letter", .Other_Letter },         .{ "Lo", .Lo },
            .{ "Mark", .Mark },                         .{ "M", .M },
            .{ "Combining_Mark", .Mark },               .{ "Nonspacing_Mark", .Nonspacing_Mark },
            .{ "Mn", .Mn },                             .{ "Spacing_Mark", .Spacing_Mark },
            .{ "Mc", .Mc },                             .{ "Enclosing_Mark", .Enclosing_Mark },
            .{ "Me", .Me },                             .{ "Number", .Number },
            .{ "N", .N },                               .{ "Decimal_Number", .Decimal_Number },
            .{ "Nd", .Nd },                             .{ "digit", .Decimal_Number },
            .{ "Letter_Number", .Letter_Number },       .{ "Nl", .Nl },
            .{ "Other_Number", .Other_Number },         .{ "No", .No },
            .{ "Punctuation", .Punctuation },           .{ "P", .P },
            .{ "punct", .Punctuation },                 .{ "Connector_Punctuation", .Connector_Punctuation },
            .{ "Pc", .Pc },                             .{ "Dash_Punctuation", .Dash_Punctuation },
            .{ "Pd", .Pd },                             .{ "Open_Punctuation", .Open_Punctuation },
            .{ "Ps", .Ps },                             .{ "Close_Punctuation", .Close_Punctuation },
            .{ "Pe", .Pe },                             .{ "Initial_Punctuation", .Initial_Punctuation },
            .{ "Pi", .Pi },                             .{ "Final_Punctuation", .Final_Punctuation },
            .{ "Pf", .Pf },                             .{ "Other_Punctuation", .Other_Punctuation },
            .{ "Po", .Po },                             .{ "Symbol", .Symbol },
            .{ "S", .S },                               .{ "Math_Symbol", .Math_Symbol },
            .{ "Sm", .Sm },                             .{ "Currency_Symbol", .Currency_Symbol },
            .{ "Sc", .Sc },                             .{ "Modifier_Symbol", .Modifier_Symbol },
            .{ "Sk", .Sk },                             .{ "Other_Symbol", .Other_Symbol },
            .{ "So", .So },                             .{ "Separator", .Separator },
            .{ "Z", .Z },                               .{ "Space_Separator", .Space_Separator },
            .{ "Zs", .Zs },                             .{ "Line_Separator", .Line_Separator },
            .{ "Zl", .Zl },                             .{ "Paragraph_Separator", .Paragraph_Separator },
            .{ "Zp", .Zp },                             .{ "Other", .Other },
            .{ "C", .C },                               .{ "Control", .Control },
            .{ "Cc", .Cc },                             .{ "cntrl", .Cc },
            .{ "Format", .Format },                     .{ "Cf", .Cf },
            .{ "Surrogate", .Surrogate },               .{ "Cs", .Cs },
            .{ "Private_Use", .Private_Use },           .{ "Co", .Co },
            .{ "Unassigned", .Not_Assigned },           .{ "Cn", .Cn },
        });
        return map.get(s);
    }
};

/// Check if codepoint matches a Unicode General_Category property (a single
/// category like `Lu`, or a super-category like `L`/`N`/`P`/…).
pub fn matchesProperty(cp: Codepoint, property: UnicodeProperty) bool {
    return matchesCategory(getGeneralCategory(cp), property);
}

fn matchesCategory(c: GeneralCategory, property: UnicodeProperty) bool {
    return switch (property) {
        .Letter, .L => c == .Lu or c == .Ll or c == .Lt or c == .Lm or c == .Lo,
        .Cased_Letter, .LC => c == .Lu or c == .Ll or c == .Lt,
        .Lowercase_Letter, .Ll => c == .Ll,
        .Uppercase_Letter, .Lu => c == .Lu,
        .Titlecase_Letter, .Lt => c == .Lt,
        .Modifier_Letter, .Lm => c == .Lm,
        .Other_Letter, .Lo => c == .Lo,
        .Mark, .M => c == .Mn or c == .Mc or c == .Me,
        .Nonspacing_Mark, .Mn => c == .Mn,
        .Spacing_Mark, .Mc => c == .Mc,
        .Enclosing_Mark, .Me => c == .Me,
        .Number, .N => c == .Nd or c == .Nl or c == .No,
        .Decimal_Number, .Nd => c == .Nd,
        .Letter_Number, .Nl => c == .Nl,
        .Other_Number, .No => c == .No,
        .Punctuation, .P => c == .Pc or c == .Pd or c == .Ps or c == .Pe or c == .Pi or c == .Pf or c == .Po,
        .Connector_Punctuation, .Pc => c == .Pc,
        .Dash_Punctuation, .Pd => c == .Pd,
        .Open_Punctuation, .Ps => c == .Ps,
        .Close_Punctuation, .Pe => c == .Pe,
        .Initial_Punctuation, .Pi => c == .Pi,
        .Final_Punctuation, .Pf => c == .Pf,
        .Other_Punctuation, .Po => c == .Po,
        .Symbol, .S => c == .Sm or c == .Sc or c == .Sk or c == .So,
        .Math_Symbol, .Sm => c == .Sm,
        .Currency_Symbol, .Sc => c == .Sc,
        .Modifier_Symbol, .Sk => c == .Sk,
        .Other_Symbol, .So => c == .So,
        .Separator, .Z => c == .Zs or c == .Zl or c == .Zp,
        .Space_Separator, .Zs => c == .Zs,
        .Line_Separator, .Zl => c == .Zl,
        .Paragraph_Separator, .Zp => c == .Zp,
        .Other, .C => c == .Cc or c == .Cf or c == .Cs or c == .Co or c == .Cn,
        .Control, .Cc => c == .Cc,
        .Format, .Cf => c == .Cf,
        .Surrogate, .Cs => c == .Cs,
        .Private_Use, .Co => c == .Co,
        .Not_Assigned, .Cn => c == .Cn,
    };
}

// ===== Script / Script_Extensions / binary properties (Unicode 17.0.0) =======

const prop_data = @import("unicode_prop_data.zig");

/// Like `decodeUtf8` but also accepts a lone surrogate encoded as 3-byte WTF-8
/// (`0xED 0xA0–0xBF 0x80–0xBF`). A `/u` regex classifies a lone surrogate as its
/// own code point (e.g. `\P{L}` matches one), and `String.fromCodePoint(0xD800)`
/// produces exactly that encoding, so property matching must decode it.
pub fn decodeUtf8Lenient(bytes: []const u8) ?struct { codepoint: Codepoint, len: u3 } {
    if (decodeUtf8(bytes)) |d| {
        return .{ .codepoint = d.codepoint, .len = d.len };
    } else |_| {}
    if (bytes.len >= 3 and bytes[0] == 0xED and (bytes[1] & 0xC0) == 0x80 and (bytes[2] & 0xC0) == 0x80) {
        const cp = (@as(Codepoint, bytes[0] & 0x0F) << 12) |
            (@as(Codepoint, bytes[1] & 0x3F) << 6) |
            (bytes[2] & 0x3F);
        if (cp >= 0xD800 and cp <= 0xDFFF) return .{ .codepoint = cp, .len = 3 };
    }
    return null;
}

/// A resolved `\p{...}` operand: a General_Category, a Script, a
/// Script_Extensions, or a binary property.
pub const PropSpec = union(enum) {
    gc: UnicodeProperty,
    script: u16,
    script_extensions: u16,
    binary: prop_data.BinaryProp,
};

/// Resolve a `\p{lhs=rhs}` (or lone `\p{name}`) operand to a PropSpec, matching
/// the spec's UnicodeMatchProperty / LoneUnicodePropertyNameOrValue. `lhs` is
/// null for the lone form.
pub fn resolveProperty(lhs: ?[]const u8, name: []const u8, strict_aliases: bool) ?PropSpec {
    if (lhs) |l| {
        if (eqi(l, "gc") or eqi(l, "General_Category"))
            return if (unicodePropertyFromString(name)) |p| .{ .gc = p } else null;
        if (eqi(l, "sc") or eqi(l, "Script"))
            return if (scriptIdFromString(name)) |id| .{ .script = id } else null;
        if (eqi(l, "scx") or eqi(l, "Script_Extensions"))
            return if (scriptIdFromString(name)) |id| .{ .script_extensions = id } else null;
        if (!strict_aliases) {
            if (looseEquals(l, "General_Category"))
                return if (unicodePropertyFromStringLoose(name)) |p| .{ .gc = p } else null;
            if (looseEquals(l, "Script"))
                return if (scriptIdFromStringLoose(name)) |id| .{ .script = id } else null;
            if (looseEquals(l, "Script_Extensions"))
                return if (scriptIdFromStringLoose(name)) |id| .{ .script_extensions = id } else null;
        }
        return null;
    }
    // Lone form: a binary property name, a General_Category value, or a script
    // shorthand. Use Script_Extensions for bare scripts, which matches common
    // PCRE/Rust-regex behavior and handles shared/inherited marks naturally.
    if (binaryPropertyFromString(name)) |bp| return .{ .binary = bp };
    if (unicodePropertyFromString(name)) |p| return .{ .gc = p };
    if (scriptIdFromString(name)) |id| return .{ .script_extensions = id };
    if (!strict_aliases) {
        if (binaryPropertyFromStringLoose(name)) |bp| return .{ .binary = bp };
        if (unicodePropertyFromStringLoose(name)) |p| return .{ .gc = p };
        if (scriptIdFromStringLoose(name)) |id| return .{ .script_extensions = id };
    }
    return null;
}

fn eqi(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn looseChar(c: u8) ?u8 {
    if (std.ascii.isAlphanumeric(c)) return std.ascii.toLower(c);
    return switch (c) {
        '_', '-', ' ' => null,
        else => c,
    };
}

fn looseEquals(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (true) {
        while (ai < a.len and looseChar(a[ai]) == null) ai += 1;
        while (bi < b.len and looseChar(b[bi]) == null) bi += 1;
        if (ai >= a.len or bi >= b.len) return ai >= a.len and bi >= b.len;
        const ac = looseChar(a[ai]) orelse unreachable;
        const bc = looseChar(b[bi]) orelse unreachable;
        if (ac != bc) return false;
        ai += 1;
        bi += 1;
    }
}

fn unicodePropertyFromString(name: []const u8) ?UnicodeProperty {
    return UnicodeProperty.fromString(name);
}

fn unicodePropertyFromStringLoose(name: []const u8) ?UnicodeProperty {
    if (unicodePropertyFromString(name)) |p| return p;
    const info = @typeInfo(UnicodeProperty).@"enum";
    if (@hasField(@TypeOf(info), "field_names")) {
        inline for (info.field_names) |field_name| {
            if (looseEquals(name, field_name)) return @field(UnicodeProperty, field_name);
        }
    } else {
        inline for (info.fields) |field| {
            if (looseEquals(name, field.name)) return @field(UnicodeProperty, field.name);
        }
    }
    return null;
}

fn binaryPropertyFromString(name: []const u8) ?prop_data.BinaryProp {
    return prop_data.binaryFromName(name);
}

fn binaryPropertyFromStringLoose(name: []const u8) ?prop_data.BinaryProp {
    if (binaryPropertyFromString(name)) |bp| return bp;
    const info = @typeInfo(prop_data.BinaryProp).@"enum";
    if (@hasField(@TypeOf(info), "field_names")) {
        inline for (info.field_names) |field_name| {
            if (looseEquals(name, field_name)) return @field(prop_data.BinaryProp, field_name);
        }
    } else {
        inline for (info.fields) |field| {
            if (looseEquals(name, field.name)) return @field(prop_data.BinaryProp, field.name);
        }
    }
    return null;
}

fn canonicalAliasFromLoose(name: []const u8, buf: *[128]u8) ?[]const u8 {
    var out: usize = 0;
    var word_start = true;
    var saw_sep = false;
    for (name) |c| {
        if (c == '_' or c == '-' or c == ' ') {
            saw_sep = out > 0;
            word_start = true;
            continue;
        }
        if (!std.ascii.isAlphanumeric(c)) return null;
        if (saw_sep) {
            if (out >= buf.len) return null;
            buf[out] = '_';
            out += 1;
            saw_sep = false;
        }
        if (out >= buf.len) return null;
        buf[out] = if (word_start) std.ascii.toUpper(c) else std.ascii.toLower(c);
        out += 1;
        word_start = false;
    }
    return buf[0..out];
}

fn scriptIdFromString(name: []const u8) ?u16 {
    return prop_data.scriptId(name);
}

fn scriptIdFromStringLoose(name: []const u8) ?u16 {
    if (prop_data.scriptId(name)) |id| return id;
    var canonical_buf: [128]u8 = undefined;
    if (canonicalAliasFromLoose(name, &canonical_buf)) |canonical| {
        if (prop_data.scriptId(canonical)) |id| return id;
    }
    return null;
}

/// The Script value of a codepoint (Unknown when not in any explicit range).
pub fn scriptOf(cp: Codepoint) u16 {
    const ranges = prop_data.sc_ranges;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.lo) hi = mid else if (cp > r.hi) lo = mid + 1 else return r.sc;
    }
    return prop_data.unknown_script;
}

fn matchScriptExtensions(cp: Codepoint, sc: u16) bool {
    const ranges = prop_data.scx_ranges;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else {
            for (prop_data.scx_pool[r.start .. r.start + r.len]) |id| if (id == sc) return true;
            return false;
        }
    }
    // Codepoints not listed in ScriptExtensions inherit Script_Extensions = { Script }.
    return scriptOf(cp) == sc;
}

fn inRanges(cp: Codepoint, ranges: []const prop_data.R) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.lo) hi = mid else if (cp > r.hi) lo = mid + 1 else return true;
    }
    return false;
}

fn matchBinary(cp: Codepoint, bp: prop_data.BinaryProp) bool {
    return switch (bp) {
        .ASCII => cp <= 0x7F,
        .Any => true,
        .Assigned => getGeneralCategory(cp) != .Cn,
        else => inRanges(cp, prop_data.binaryRanges(bp)),
    };
}

/// ECMAScript IdentifierStart for RegExp group names: Unicode ID_Start plus
/// `$` and `_` (both allowed by IdentifierName but not by Unicode ID_Start).
pub fn isIdentifierStart(cp: Codepoint) bool {
    return cp == '$' or cp == '_' or matchBinary(cp, .ID_Start);
}

/// ECMAScript IdentifierContinue for RegExp group names: Unicode ID_Continue
/// plus `$`, U+200C ZERO WIDTH NON-JOINER, and U+200D ZERO WIDTH JOINER.
pub fn isIdentifierContinue(cp: Codepoint) bool {
    return cp == '$' or cp == 0x200C or cp == 0x200D or matchBinary(cp, .ID_Continue);
}

/// Match a codepoint against any resolved `\p{...}` operand.
pub fn matchesSpec(cp: Codepoint, spec: PropSpec) bool {
    return switch (spec) {
        .gc => |p| matchesProperty(cp, p),
        .script => |id| scriptOf(cp) == id,
        .script_extensions => |id| matchScriptExtensions(cp, id),
        .binary => |bp| matchBinary(cp, bp),
    };
}

/// Stateful property matcher for repeated scans. Generated Test262 property
/// escape tests feed code points in ascending order, so reusing the current
/// Unicode range avoids doing a fresh binary search for every code point.
pub const SpecMatcher = struct {
    spec: PropSpec,
    gc_idx: usize = 0,
    sc_idx: usize = 0,
    scx_idx: usize = 0,
    binary_idx: usize = 0,

    pub fn init(spec: PropSpec) SpecMatcher {
        return .{ .spec = spec };
    }

    pub fn matches(self: *SpecMatcher, cp: Codepoint) bool {
        return switch (self.spec) {
            .gc => |p| matchesCategory(self.generalCategoryOf(cp), p),
            .script => |id| self.scriptOf(cp) == id,
            .script_extensions => |id| self.matchScriptExtensions(cp, id),
            .binary => |bp| self.matchBinary(cp, bp),
        };
    }

    fn generalCategoryOf(self: *SpecMatcher, cp: Codepoint) GeneralCategory {
        const ranges = &gc_data.gc_ranges;
        if (cachedGcRangeIndex(ranges, &self.gc_idx, cp)) |idx| return ranges[idx].cat;
        return .Cn;
    }

    fn scriptOf(self: *SpecMatcher, cp: Codepoint) u16 {
        const ranges = &prop_data.sc_ranges;
        if (cachedScRangeIndex(ranges, &self.sc_idx, cp)) |idx| return ranges[idx].sc;
        return prop_data.unknown_script;
    }

    fn matchScriptExtensions(self: *SpecMatcher, cp: Codepoint, sc: u16) bool {
        const ranges = &prop_data.scx_ranges;
        if (cachedScxRangeIndex(ranges, &self.scx_idx, cp)) |idx| {
            const r = ranges[idx];
            for (prop_data.scx_pool[r.start .. r.start + r.len]) |id| if (id == sc) return true;
            return false;
        }
        return self.scriptOf(cp) == sc;
    }

    fn matchBinary(self: *SpecMatcher, cp: Codepoint, bp: prop_data.BinaryProp) bool {
        return switch (bp) {
            .ASCII => cp <= 0x7F,
            .Any => true,
            .Assigned => self.generalCategoryOf(cp) != .Cn,
            else => cachedBinaryRangeContains(prop_data.binaryRanges(bp), &self.binary_idx, cp),
        };
    }
};

fn cachedGcRangeIndex(ranges: []const gc_data.GcRange, idx: *usize, cp: Codepoint) ?usize {
    if (cachedRangeIndexStartEnd(ranges, idx, cp)) |i| return i;
    return null;
}

fn cachedScRangeIndex(ranges: []const prop_data.ScRange, idx: *usize, cp: Codepoint) ?usize {
    if (cachedRangeIndexLoHi(prop_data.ScRange, ranges, idx, cp)) |i| return i;
    return null;
}

fn cachedScxRangeIndex(ranges: []const prop_data.ScxRange, idx: *usize, cp: Codepoint) ?usize {
    if (cachedRangeIndexLoHi(prop_data.ScxRange, ranges, idx, cp)) |i| return i;
    return null;
}

fn cachedBinaryRangeContains(ranges: []const prop_data.R, idx: *usize, cp: Codepoint) bool {
    return cachedRangeIndexLoHi(prop_data.R, ranges, idx, cp) != null;
}

fn cachedRangeIndexStartEnd(ranges: []const gc_data.GcRange, idx: *usize, cp: Codepoint) ?usize {
    if (ranges.len == 0) return null;
    if (idx.* >= ranges.len) idx.* = ranges.len - 1;
    var i = idx.*;
    const cur = ranges[i];
    if (cp >= cur.start and cp <= cur.end) return i;
    if (cp < cur.start) {
        if (i == 0) return null;
        const prev = ranges[i - 1];
        if (cp > prev.end) return null;
        if (cp >= prev.start) {
            idx.* = i - 1;
            return i - 1;
        }
    }
    if (cp > cur.end) {
        while (i + 1 < ranges.len and cp > ranges[i].end) i += 1;
        idx.* = i;
        const r = ranges[i];
        return if (cp >= r.start and cp <= r.end) i else null;
    }
    return binaryGcRangeIndex(ranges, idx, cp);
}

fn cachedRangeIndexLoHi(comptime Range: type, ranges: []const Range, idx: *usize, cp: Codepoint) ?usize {
    if (ranges.len == 0) return null;
    if (idx.* >= ranges.len) idx.* = ranges.len - 1;
    var i = idx.*;
    const cur = ranges[i];
    if (cp >= cur.lo and cp <= cur.hi) return i;
    if (cp < cur.lo) {
        if (i == 0) return null;
        const prev = ranges[i - 1];
        if (cp > prev.hi) return null;
        if (cp >= prev.lo) {
            idx.* = i - 1;
            return i - 1;
        }
    }
    if (cp > cur.hi) {
        while (i + 1 < ranges.len and cp > ranges[i].hi) i += 1;
        idx.* = i;
        const r = ranges[i];
        return if (cp >= r.lo and cp <= r.hi) i else null;
    }
    return binaryLoHiRangeIndex(Range, ranges, idx, cp);
}

fn binaryGcRangeIndex(ranges: []const gc_data.GcRange, idx: *usize, cp: Codepoint) ?usize {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.start) {
            hi = mid;
        } else if (cp > r.end) {
            lo = mid + 1;
        } else {
            idx.* = mid;
            return mid;
        }
    }
    idx.* = @min(lo, ranges.len - 1);
    return null;
}

fn binaryLoHiRangeIndex(comptime Range: type, ranges: []const Range, idx: *usize, cp: Codepoint) ?usize {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else {
            idx.* = mid;
            return mid;
        }
    }
    idx.* = @min(lo, ranges.len - 1);
    return null;
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
    const truncated = [_]u8{0xC3}; // Should be 2 bytes but only 1
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
        0x0000, 0x007F, // ASCII boundaries
        0x0080, 0x07FF, // 2-byte boundaries
        0x0800, 0xFFFF, // 3-byte boundaries
        0x10000, 0x10FFFF, // 4-byte boundaries
        'a', 'Z', '0', '9', // Common ASCII
        0x00E9, 0x20AC, // Common non-ASCII
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

    // Hangul Syllables (block runs U+AC00..U+D7A3; U+D7A4..U+D7AF are unassigned)
    try std.testing.expectEqual(GeneralCategory.Lo, getGeneralCategory(0xAC00));
    try std.testing.expectEqual(GeneralCategory.Lo, getGeneralCategory(0xD7A3));
    try std.testing.expect(matchesProperty(0xAC00, .Letter));

    // Arabic (U+0600 is the ARABIC NUMBER SIGN, a format char; use a real letter)
    try std.testing.expectEqual(GeneralCategory.Lo, getGeneralCategory(0x0627)); // ARABIC LETTER ALEF
    try std.testing.expect(matchesProperty(0x0627, .Letter));
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
