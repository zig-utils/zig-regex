const std = @import("std");
const parser = @import("parser.zig");
const Regex = @import("regex.zig").Regex;

/// Regex pattern analysis and linting tool
///
/// This module provides static analysis of regex patterns to detect:
/// - Performance issues (catastrophic backtracking)
/// - Complexity warnings
/// - Common mistakes
/// - Optimization opportunities
pub const Lint = struct {
    allocator: std.mem.Allocator,
    warnings: std.ArrayList(Warning),
    pattern: []const u8,

    pub const WarningLevel = enum {
        info,
        warning,
        error_level,
    };

    pub const WarningType = enum {
        catastrophic_backtracking,
        excessive_nesting,
        empty_alternation,
        redundant_quantifier,
        inefficient_pattern,
        ambiguous_pattern,
        complexity_warning,
        optimization_opportunity,
    };

    pub const Warning = struct {
        level: WarningLevel,
        type: WarningType,
        position: usize,
        message: []const u8,
        suggestion: ?[]const u8 = null,

        pub fn format(
            self: Warning,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            const level_str = switch (self.level) {
                .info => "ℹ️  Info",
                .warning => "⚠️  Warning",
                .error_level => "❌ Error",
            };

            try writer.print("{s} at position {d}: {s}\n", .{ level_str, self.position, self.message });
            if (self.suggestion) |sug| {
                try writer.print("   Suggestion: {s}\n", .{sug});
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8) Lint {
        return .{
            .allocator = allocator,
            .warnings = std.ArrayList(Warning){},
            .pattern = pattern,
        };
    }

    pub fn deinit(self: *Lint) void {
        for (self.warnings.items) |warning| {
            self.allocator.free(warning.message);
            if (warning.suggestion) |sug| {
                self.allocator.free(sug);
            }
        }
        self.warnings.deinit(self.allocator);
    }

    /// Run all linting checks on the pattern
    pub fn analyze(self: *Lint) !void {
        try self.checkCatastrophicBacktracking();
        try self.checkComplexity();
        try self.checkEmptyAlternations();
        try self.checkRedundantQuantifiers();
        try self.checkOptimizationOpportunities();
    }

    fn addWarning(
        self: *Lint,
        level: WarningLevel,
        warn_type: WarningType,
        position: usize,
        message: []const u8,
        suggestion: ?[]const u8,
    ) !void {
        const owned_message = try self.allocator.dupe(u8, message);
        const owned_suggestion = if (suggestion) |s| try self.allocator.dupe(u8, s) else null;

        try self.warnings.append(self.allocator, .{
            .level = level,
            .type = warn_type,
            .position = position,
            .message = owned_message,
            .suggestion = owned_suggestion,
        });
    }

    /// Check for patterns that may cause catastrophic backtracking
    fn checkCatastrophicBacktracking(self: *Lint) !void {
        // Look for nested quantifiers like (a+)+, (a*)*
        var i: usize = 0;
        while (i < self.pattern.len) : (i += 1) {
            if (i + 3 < self.pattern.len) {
                // Pattern like (.+)+ or (.*)*
                if (self.pattern[i] == '(' and
                    (self.pattern[i + 2] == '+' or self.pattern[i + 2] == '*') and
                    self.pattern[i + 3] == ')' and
                    i + 4 < self.pattern.len and
                    (self.pattern[i + 4] == '+' or self.pattern[i + 4] == '*'))
                {
                    try self.addWarning(
                        .error_level,
                        .catastrophic_backtracking,
                        i,
                        "Nested quantifiers can cause catastrophic backtracking",
                        "Use atomic groups or possessive quantifiers if available",
                    );
                }
            }

            // Check for alternations with overlapping patterns like (a|ab)
            if (self.pattern[i] == '|') {
                try self.addWarning(
                    .info,
                    .ambiguous_pattern,
                    i,
                    "Alternation detected - ensure branches don't overlap for best performance",
                    null,
                );
            }
        }
    }

    /// Check pattern complexity
    fn checkComplexity(self: *Lint) !void {
        var nesting_level: usize = 0;
        var max_nesting: usize = 0;
        var group_count: usize = 0;
        var quantifier_count: usize = 0;

        for (self.pattern, 0..) |c, i| {
            switch (c) {
                '(' => {
                    nesting_level += 1;
                    group_count += 1;
                    if (nesting_level > max_nesting) {
                        max_nesting = nesting_level;
                    }
                },
                ')' => {
                    if (nesting_level > 0) {
                        nesting_level -= 1;
                    }
                },
                '+', '*', '?' => {
                    quantifier_count += 1;
                },
                else => {},
            }

            if (max_nesting > 10) {
                try self.addWarning(
                    .warning,
                    .excessive_nesting,
                    i,
                    "Excessive nesting depth may impact performance",
                    "Consider simplifying the pattern or breaking it into multiple regexes",
                );
                break;
            }
        }

        if (group_count > 20) {
            try self.addWarning(
                .warning,
                .complexity_warning,
                0,
                "Pattern has many capturing groups which may impact performance",
                "Use non-capturing groups (?:...) where captures aren't needed",
            );
        }

        if (quantifier_count > 15) {
            try self.addWarning(
                .info,
                .complexity_warning,
                0,
                "Pattern has many quantifiers - ensure this complexity is necessary",
                null,
            );
        }
    }

    /// Check for empty alternations like (|foo) or (foo||bar)
    fn checkEmptyAlternations(self: *Lint) !void {
        for (self.pattern, 0..) |c, i| {
            if (c == '|') {
                // Check if preceded or followed by another |, (, or )
                const prev_empty = (i == 0 or self.pattern[i - 1] == '(' or self.pattern[i - 1] == '|');
                const next_empty = (i + 1 >= self.pattern.len or self.pattern[i + 1] == ')' or self.pattern[i + 1] == '|');

                if (prev_empty or next_empty) {
                    try self.addWarning(
                        .warning,
                        .empty_alternation,
                        i,
                        "Empty alternation branch detected",
                        "Remove empty branches or use optional groups",
                    );
                }
            }
        }
    }

    /// Check for redundant quantifiers like a+* or b**
    fn checkRedundantQuantifiers(self: *Lint) !void {
        var i: usize = 0;
        while (i < self.pattern.len - 1) : (i += 1) {
            const curr = self.pattern[i];
            const next = self.pattern[i + 1];

            if ((curr == '+' or curr == '*' or curr == '?') and
                (next == '+' or next == '*' or next == '?'))
            {
                try self.addWarning(
                    .warning,
                    .redundant_quantifier,
                    i,
                    "Redundant quantifiers detected",
                    "Simplify to a single quantifier",
                );
            }
        }
    }

    /// Suggest optimization opportunities
    fn checkOptimizationOpportunities(self: *Lint) !void {
        // Check for patterns that could use character classes
        if (std.mem.indexOf(u8, self.pattern, "(a|b|c|d|e|f)")) |pos| {
            try self.addWarning(
                .info,
                .optimization_opportunity,
                pos,
                "Alternation of single characters can be replaced with character class",
                "Use [abcdef] instead of (a|b|c|d|e|f)",
            );
        }

        // Check for .*word - suggest word boundary
        if (std.mem.indexOf(u8, self.pattern, ".*")) |pos| {
            try self.addWarning(
                .info,
                .optimization_opportunity,
                pos,
                "Pattern starts with .* which may be inefficient",
                "Consider using anchors or more specific patterns",
            );
        }

        // Check for patterns without anchors that might benefit from them
        if (self.pattern.len > 0 and self.pattern[0] != '^') {
            const has_leading_literal = self.pattern.len > 1 and
                std.ascii.isAlphanumeric(self.pattern[0]);

            if (has_leading_literal) {
                try self.addWarning(
                    .info,
                    .optimization_opportunity,
                    0,
                    "Pattern may benefit from anchor (^) if matching from start",
                    null,
                );
            }
        }
    }

    /// Get all warnings
    pub fn getWarnings(self: *const Lint) []const Warning {
        return self.warnings.items;
    }

    /// Check if pattern has any errors
    pub fn hasErrors(self: *const Lint) bool {
        for (self.warnings.items) |warning| {
            if (warning.level == .error_level) {
                return true;
            }
        }
        return false;
    }

    /// Print all warnings
    pub fn printWarnings(self: *const Lint) void {
        if (self.warnings.items.len == 0) {
            std.debug.print("✓ No issues found\n", .{});
            return;
        }

        std.debug.print("\n=== Regex Analysis Results ===\n", .{});
        std.debug.print("Pattern: \"{s}\"\n\n", .{self.pattern});

        for (self.warnings.items) |warning| {
            std.debug.print("{any}", .{warning});
        }

        std.debug.print("\nTotal: {d} issue(s) found\n", .{self.warnings.items.len});
    }
};

/// Pattern complexity analyzer
pub const ComplexityAnalyzer = struct {
    pub const Complexity = struct {
        pattern_length: usize,
        nesting_depth: usize,
        group_count: usize,
        quantifier_count: usize,
        alternation_count: usize,
        character_class_count: usize,
        complexity_score: usize,

        pub fn getLevel(self: Complexity) ComplexityLevel {
            if (self.complexity_score < 10) return .low;
            if (self.complexity_score < 25) return .medium;
            if (self.complexity_score < 50) return .high;
            return .very_high;
        }
    };

    pub const ComplexityLevel = enum {
        low,
        medium,
        high,
        very_high,
    };

    pub fn analyze(pattern: []const u8) Complexity {
        var nesting_depth: usize = 0;
        var max_nesting: usize = 0;
        var group_count: usize = 0;
        var quantifier_count: usize = 0;
        var alternation_count: usize = 0;
        var char_class_count: usize = 0;

        var i: usize = 0;
        while (i < pattern.len) : (i += 1) {
            switch (pattern[i]) {
                '(' => {
                    nesting_depth += 1;
                    group_count += 1;
                    if (nesting_depth > max_nesting) {
                        max_nesting = nesting_depth;
                    }
                },
                ')' => {
                    if (nesting_depth > 0) {
                        nesting_depth -= 1;
                    }
                },
                '+', '*', '?' => quantifier_count += 1,
                '|' => alternation_count += 1,
                '[' => char_class_count += 1,
                else => {},
            }
        }

        // Calculate complexity score
        const score = pattern.len / 10 +
            max_nesting * 5 +
            group_count * 2 +
            quantifier_count +
            alternation_count * 2 +
            char_class_count;

        return .{
            .pattern_length = pattern.len,
            .nesting_depth = max_nesting,
            .group_count = group_count,
            .quantifier_count = quantifier_count,
            .alternation_count = alternation_count,
            .character_class_count = char_class_count,
            .complexity_score = score,
        };
    }
};

test "lint catastrophic backtracking" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var lint = Lint.init(allocator, "(a+)+");
    defer lint.deinit();

    try lint.analyze();
    try testing.expect(lint.hasErrors());
}

test "complexity analyzer" {
    const simple = ComplexityAnalyzer.analyze("abc");
    try std.testing.expectEqual(ComplexityAnalyzer.ComplexityLevel.low, simple.getLevel());

    const complex = ComplexityAnalyzer.analyze("(((a+)+)+)|(((b*)*)*)|c{1,100}");
    try std.testing.expect(complex.complexity_score > 20);
}
