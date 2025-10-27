const std = @import("std");

/// Regex macro system for pattern composition and reusability
/// Allows defining named patterns that can be referenced in other patterns
///
/// Example:
///   var macros = MacroRegistry.init(allocator);
///   try macros.define("digit", "[0-9]");
///   try macros.define("word", "[a-zA-Z]+");
///   const expanded = try macros.expand("${word} ${digit}+"); // -> "[a-zA-Z]+ [0-9]+"
pub const MacroRegistry = struct {
    allocator: std.mem.Allocator,
    macros: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) MacroRegistry {
        return .{
            .allocator = allocator,
            .macros = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *MacroRegistry) void {
        var it = self.macros.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.macros.deinit();
    }

    /// Define a macro pattern
    pub fn define(self: *MacroRegistry, name: []const u8, pattern: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const pattern_copy = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(pattern_copy);

        // Check if macro already exists and free old values
        if (self.macros.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }

        try self.macros.put(name_copy, pattern_copy);
    }

    /// Expand macros in a pattern string
    /// Macros are referenced as ${name}
    pub fn expand(self: *MacroRegistry, pattern: []const u8) ![]u8 {
        var result = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
        defer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < pattern.len) {
            // Check for macro reference
            if (i + 2 < pattern.len and pattern[i] == '$' and pattern[i + 1] == '{') {
                // Find closing brace
                var j = i + 2;
                while (j < pattern.len and pattern[j] != '}') : (j += 1) {}

                if (j < pattern.len) {
                    const macro_name = pattern[i + 2 .. j];

                    // Look up macro
                    if (self.macros.get(macro_name)) |macro_pattern| {
                        try result.appendSlice(self.allocator, macro_pattern);
                        i = j + 1;
                        continue;
                    } else {
                        // Macro not found, return error
                        return error.UndefinedMacro;
                    }
                }
            }

            // Regular character
            try result.append(self.allocator, pattern[i]);
            i += 1;
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Check if a macro is defined
    pub fn isDefined(self: *MacroRegistry, name: []const u8) bool {
        return self.macros.contains(name);
    }

    /// Get a macro's pattern (returns null if not defined)
    pub fn get(self: *MacroRegistry, name: []const u8) ?[]const u8 {
        return self.macros.get(name);
    }
};

/// Common predefined macros for convenience
pub const CommonMacros = struct {
    pub const digit = "[0-9]";
    pub const word = "[a-zA-Z]";
    pub const word_char = "[a-zA-Z0-9_]";
    pub const whitespace = "[ \\t\\r\\n]";
    pub const alpha = "[a-zA-Z]";
    pub const alnum = "[a-zA-Z0-9]";
    pub const hex = "[0-9a-fA-F]";
    pub const lower = "[a-z]";
    pub const upper = "[A-Z]";
    pub const email_local = "[a-zA-Z0-9._%+-]+";
    pub const email_domain = "[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}";
    pub const ipv4_octet = "(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)";
    pub const url_scheme = "https?";

    /// Load all common macros into a registry
    pub fn loadInto(registry: *MacroRegistry) !void {
        try registry.define("digit", digit);
        try registry.define("word", word);
        try registry.define("word_char", word_char);
        try registry.define("whitespace", whitespace);
        try registry.define("alpha", alpha);
        try registry.define("alnum", alnum);
        try registry.define("hex", hex);
        try registry.define("lower", lower);
        try registry.define("upper", upper);
        try registry.define("email_local", email_local);
        try registry.define("email_domain", email_domain);
        try registry.define("ipv4_octet", ipv4_octet);
        try registry.define("url_scheme", url_scheme);
    }
};

test "macros: basic define and expand" {
    const allocator = std.testing.allocator;
    var registry = MacroRegistry.init(allocator);
    defer registry.deinit();

    try registry.define("digit", "[0-9]");
    try registry.define("word", "[a-z]+");

    const expanded = try registry.expand("${digit}+ ${word}");
    defer allocator.free(expanded);

    try std.testing.expectEqualStrings("[0-9]+ [a-z]+", expanded);
}

test "macros: nested expansion" {
    const allocator = std.testing.allocator;
    var registry = MacroRegistry.init(allocator);
    defer registry.deinit();

    try registry.define("d", "[0-9]");
    try registry.define("num", "${d}+");

    // First expand
    const expanded1 = try registry.expand("${num}");
    defer allocator.free(expanded1);
    try std.testing.expectEqualStrings("${d}+", expanded1);

    // Need to expand again for nested
    const expanded2 = try registry.expand(expanded1);
    defer allocator.free(expanded2);
    try std.testing.expectEqualStrings("[0-9]+", expanded2);
}

test "macros: common macros" {
    const allocator = std.testing.allocator;
    var registry = MacroRegistry.init(allocator);
    defer registry.deinit();

    try CommonMacros.loadInto(&registry);

    const email_pattern = try registry.expand("${email_local}@${email_domain}");
    defer allocator.free(email_pattern);

    try std.testing.expect(email_pattern.len > 0);
}

test "macros: undefined macro error" {
    const allocator = std.testing.allocator;
    var registry = MacroRegistry.init(allocator);
    defer registry.deinit();

    const result = registry.expand("${undefined}");
    try std.testing.expectError(error.UndefinedMacro, result);
}

test "macros: redefine existing" {
    const allocator = std.testing.allocator;
    var registry = MacroRegistry.init(allocator);
    defer registry.deinit();

    try registry.define("x", "old");
    try registry.define("x", "new");

    const expanded = try registry.expand("${x}");
    defer allocator.free(expanded);

    try std.testing.expectEqualStrings("new", expanded);
}
