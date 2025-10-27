const std = @import("std");
const Regex = @import("regex.zig").Regex;
const RegexError = @import("errors.zig").RegexError;

/// Type-safe regex builder API for constructing patterns programmatically.
///
/// This builder provides a fluent interface for creating regex patterns without
/// dealing with raw regex syntax, reducing errors and improving code readability.
///
/// Example:
/// ```zig
/// var builder = try Builder.init(allocator);
/// defer builder.deinit();
///
/// try builder
///     .literal("hello")
///     .oneOrMore()
///     .whitespace()
///     .digit()
///     .repeatExact(3);
///
/// const regex = try builder.compile();
/// defer regex.deinit();
/// ```
pub const Builder = struct {
    allocator: std.mem.Allocator,
    parts: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .parts = std.ArrayList([]const u8){},
        };
    }

    pub fn deinit(self: *Builder) void {
        for (self.parts.items) |part| {
            self.allocator.free(part);
        }
        self.parts.deinit(self.allocator);
    }

    /// Add a literal string to the pattern (escaped automatically)
    pub fn literal(self: *Builder, text: []const u8) !*Builder {
        const escaped = try escapeLiteral(self.allocator, text);
        try self.parts.append(self.allocator, escaped);
        return self;
    }

    /// Match any single character
    pub fn any(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, "."));
        return self;
    }

    /// Match a single digit [0-9]
    pub fn digit(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, "\\d"));
        return self;
    }

    /// Match a single word character [a-zA-Z0-9_]
    pub fn word(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, "\\w"));
        return self;
    }

    /// Match a whitespace character
    pub fn whitespace(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, "\\s"));
        return self;
    }

    /// Match start of line
    pub fn startOfLine(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, "^"));
        return self;
    }

    /// Match end of line
    pub fn endOfLine(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, "$"));
        return self;
    }

    /// Match word boundary
    pub fn wordBoundary(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, "\\b"));
        return self;
    }

    /// Match one or more of the previous element (+)
    pub fn oneOrMore(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, "+"));
        return self;
    }

    /// Match zero or more of the previous element (*)
    pub fn zeroOrMore(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, "*"));
        return self;
    }

    /// Match zero or one of the previous element (?)
    pub fn optional(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, "?"));
        return self;
    }

    /// Match exactly n repetitions
    pub fn repeatExact(self: *Builder, n: usize) !*Builder {
        const part = try std.fmt.allocPrint(self.allocator, "{{{d}}}", .{n});
        try self.parts.append(self.allocator, part);
        return self;
    }

    /// Match at least n repetitions
    pub fn repeatAtLeast(self: *Builder, n: usize) !*Builder {
        const part = try std.fmt.allocPrint(self.allocator, "{{{d},}}", .{n});
        try self.parts.append(self.allocator, part);
        return self;
    }

    /// Match between min and max repetitions
    pub fn repeatRange(self: *Builder, min: usize, max: usize) !*Builder {
        const part = try std.fmt.allocPrint(self.allocator, "{{{d},{d}}}", .{ min, max });
        try self.parts.append(self.allocator, part);
        return self;
    }

    /// Start a capturing group
    pub fn startGroup(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, "("));
        return self;
    }

    /// End a capturing group
    pub fn endGroup(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, ")"));
        return self;
    }

    /// Start a non-capturing group
    pub fn startNonCapturingGroup(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, "(?:"));
        return self;
    }

    /// Add an alternation (|)
    pub fn or_(self: *Builder) !*Builder {
        try self.parts.append(self.allocator, try self.allocator.dupe(u8, "|"));
        return self;
    }

    /// Add a character class
    pub fn charClass(self: *Builder, chars: []const u8) !*Builder {
        const part = try std.fmt.allocPrint(self.allocator, "[{s}]", .{chars});
        try self.parts.append(self.allocator, part);
        return self;
    }

    /// Add a negated character class
    pub fn notCharClass(self: *Builder, chars: []const u8) !*Builder {
        const part = try std.fmt.allocPrint(self.allocator, "[^{s}]", .{chars});
        try self.parts.append(self.allocator, part);
        return self;
    }

    /// Add a character range
    pub fn charRange(self: *Builder, start: u8, end: u8) !*Builder {
        const part = try std.fmt.allocPrint(self.allocator, "[{c}-{c}]", .{ start, end });
        try self.parts.append(self.allocator, part);
        return self;
    }

    /// Build the final pattern string
    pub fn build(self: *const Builder) ![]const u8 {
        var total_len: usize = 0;
        for (self.parts.items) |part| {
            total_len += part.len;
        }

        const result = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (self.parts.items) |part| {
            @memcpy(result[pos .. pos + part.len], part);
            pos += part.len;
        }

        return result;
    }

    /// Build and compile the pattern into a Regex
    pub fn compile(self: *const Builder) !Regex {
        const pattern = try self.build();
        defer self.allocator.free(pattern);
        return try Regex.compile(self.allocator, pattern);
    }
};

/// Escape special regex characters in a literal string
fn escapeLiteral(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const special_chars = ".^$*+?()[]{|\\";
    var count: usize = 0;

    // Count how many characters need escaping
    for (text) |c| {
        if (std.mem.indexOfScalar(u8, special_chars, c) != null) {
            count += 1;
        }
    }

    if (count == 0) {
        return try allocator.dupe(u8, text);
    }

    // Allocate space for escaped string
    const result = try allocator.alloc(u8, text.len + count);
    var i: usize = 0;

    for (text) |c| {
        if (std.mem.indexOfScalar(u8, special_chars, c) != null) {
            result[i] = '\\';
            i += 1;
            result[i] = c;
            i += 1;
        } else {
            result[i] = c;
            i += 1;
        }
    }

    return result;
}

/// Predefined regex patterns (macros) for common use cases
pub const Patterns = struct {
    /// Email pattern (simplified)
    pub fn email(allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}");
    }

    /// URL pattern (http/https)
    pub fn url(allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "https?://[a-zA-Z0-9.-]+(?:/[a-zA-Z0-9._~:/?#\\[\\]@!$&'()*+,;=-]*)?");
    }

    /// IPv4 address pattern
    pub fn ipv4(allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)");
    }

    /// Phone number (US format)
    pub fn phoneUS(allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "\\(?\\d{3}\\)?[-.\\s]?\\d{3}[-.\\s]?\\d{4}");
    }

    /// Date (YYYY-MM-DD)
    pub fn dateISO(allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "\\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])");
    }

    /// Time (HH:MM:SS or HH:MM)
    pub fn time24(allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "(?:[01][0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9])?");
    }

    /// Hexadecimal color code
    pub fn hexColor(allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "#(?:[0-9a-fA-F]{3}){1,2}");
    }

    /// Credit card number (basic validation)
    pub fn creditCard(allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "\\d{4}[-.\\s]?\\d{4}[-.\\s]?\\d{4}[-.\\s]?\\d{4}");
    }

    /// UUID/GUID
    pub fn uuid(allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}");
    }

    /// Positive integer
    pub fn integer(allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "[0-9]+");
    }

    /// Decimal number (with optional decimal part)
    pub fn decimal(allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "[0-9]+(?:\\.[0-9]+)?");
    }

    /// Identifier (variable name: letters, digits, underscore)
    pub fn identifier(allocator: std.mem.Allocator) ![]const u8 {
        return try allocator.dupe(u8, "[a-zA-Z_][a-zA-Z0-9_]*");
    }
};

/// Pattern composer for combining multiple patterns
pub const Composer = struct {
    allocator: std.mem.Allocator,
    patterns: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) Composer {
        return .{
            .allocator = allocator,
            .patterns = std.ArrayList([]const u8){},
        };
    }

    pub fn deinit(self: *Composer) void {
        for (self.patterns.items) |pattern| {
            self.allocator.free(pattern);
        }
        self.patterns.deinit(self.allocator);
    }

    /// Add a pattern to the composition
    pub fn add(self: *Composer, pattern: []const u8) !*Composer {
        try self.patterns.append(self.allocator, try self.allocator.dupe(u8, pattern));
        return self;
    }

    /// Compose patterns with alternation (OR)
    pub fn alternatives(self: *const Composer) ![]const u8 {
        if (self.patterns.items.len == 0) {
            return error.EmptyPattern;
        }

        var total_len: usize = 0;
        for (self.patterns.items) |p| {
            total_len += p.len + 1; // +1 for '|'
        }
        total_len -= 1; // Remove last '|'

        const result = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;

        for (self.patterns.items, 0..) |p, i| {
            @memcpy(result[pos .. pos + p.len], p);
            pos += p.len;
            if (i < self.patterns.items.len - 1) {
                result[pos] = '|';
                pos += 1;
            }
        }

        return result;
    }

    /// Compose patterns with concatenation
    pub fn sequence(self: *const Composer) ![]const u8 {
        if (self.patterns.items.len == 0) {
            return error.EmptyPattern;
        }

        var total_len: usize = 0;
        for (self.patterns.items) |p| {
            total_len += p.len;
        }

        const result = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;

        for (self.patterns.items) |p| {
            @memcpy(result[pos .. pos + p.len], p);
            pos += p.len;
        }

        return result;
    }

    /// Wrap the composition in a group
    pub fn group(self: *const Composer) ![]const u8 {
        const inner = try self.sequence();
        defer self.allocator.free(inner);

        const result = try std.fmt.allocPrint(self.allocator, "({s})", .{inner});
        return result;
    }
};

test "builder basic usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    _ = try builder.literal("test");
    const pattern = try builder.build();
    defer allocator.free(pattern);

    try testing.expectEqualStrings("test", pattern);
}

test "builder with quantifiers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();

    _ = try builder.digit();
    _ = try builder.repeatExact(3);

    const pattern = try builder.build();
    defer allocator.free(pattern);

    try testing.expectEqualStrings("\\d{3}", pattern);
}

test "escape literal" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const escaped = try escapeLiteral(allocator, "hello.world");
    defer allocator.free(escaped);

    try testing.expectEqualStrings("hello\\.world", escaped);
}

test "composer alternatives" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var composer = Composer.init(allocator);
    defer composer.deinit();

    _ = try composer.add("foo");
    _ = try composer.add("bar");
    _ = try composer.add("baz");

    const pattern = try composer.alternatives();
    defer allocator.free(pattern);

    try testing.expectEqualStrings("foo|bar|baz", pattern);
}
