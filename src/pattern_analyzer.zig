const std = @import("std");
const ast = @import("ast.zig");
const RegexError = @import("errors.zig").RegexError;

/// Security risk level for a pattern
pub const RiskLevel = enum {
    safe, // No detected issues
    low, // Minor performance concerns
    medium, // Moderate performance impact
    high, // Severe performance impact
    critical, // Catastrophic backtracking likely

    pub fn toString(self: RiskLevel) []const u8 {
        return switch (self) {
            .safe => "Safe",
            .low => "Low",
            .medium => "Medium",
            .high => "High",
            .critical => "Critical",
        };
    }
};

/// Analysis result with detailed information
pub const AnalysisResult = struct {
    risk_level: RiskLevel,
    explosion_factor: f64, // Estimated complexity multiplier
    issues: []const []const u8, // List of detected issues
    recommendations: []const []const u8, // Suggested fixes
    can_use_thompson: bool, // Whether pattern can use Thompson NFA

    pub fn deinit(self: *AnalysisResult, allocator: std.mem.Allocator) void {
        for (self.issues) |issue| {
            allocator.free(issue);
        }
        allocator.free(self.issues);

        for (self.recommendations) |rec| {
            allocator.free(rec);
        }
        allocator.free(self.recommendations);
    }
};

/// Pattern analyzer for detecting security issues
pub const PatternAnalyzer = struct {
    allocator: std.mem.Allocator,
    issues: std.ArrayList([]const u8),
    recommendations: std.ArrayList([]const u8),
    explosion_factor: f64,
    can_use_thompson: bool,
    max_explosion_factor: f64,

    pub const DEFAULT_MAX_EXPLOSION_FACTOR: f64 = 1000.0;

    pub fn init(allocator: std.mem.Allocator) PatternAnalyzer {
        return .{
            .allocator = allocator,
            .issues = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            .recommendations = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            .explosion_factor = 1.0,
            .can_use_thompson = true,
            .max_explosion_factor = DEFAULT_MAX_EXPLOSION_FACTOR,
        };
    }

    pub fn deinit(self: *PatternAnalyzer) void {
        // Don't free individual strings - ownership transferred to AnalysisResult
        self.issues.deinit(self.allocator);
        self.recommendations.deinit(self.allocator);
    }

    /// Analyze an AST for security and performance issues
    pub fn analyze(self: *PatternAnalyzer, root: *ast.Node) !AnalysisResult {
        // Reset state
        self.explosion_factor = 1.0;
        self.can_use_thompson = true;

        // Perform analysis
        try self.analyzeNode(root, false);

        // Determine risk level
        const risk_level = self.calculateRiskLevel();

        // Create result
        const issues = try self.allocator.dupe([]const u8, self.issues.items);
        const recommendations = try self.allocator.dupe([]const u8, self.recommendations.items);

        return AnalysisResult{
            .risk_level = risk_level,
            .explosion_factor = self.explosion_factor,
            .issues = issues,
            .recommendations = recommendations,
            .can_use_thompson = self.can_use_thompson,
        };
    }

    fn calculateRiskLevel(self: *PatternAnalyzer) RiskLevel {
        if (self.explosion_factor >= 1000000.0) return .critical;
        if (self.explosion_factor >= 10000.0) return .high;
        if (self.explosion_factor >= 100.0) return .medium;
        if (self.explosion_factor >= 10.0) return .low;
        return .safe;
    }

    fn analyzeNode(self: *PatternAnalyzer, node: *ast.Node, inside_quantifier: bool) std.mem.Allocator.Error!void {
        switch (node.node_type) {
            .star, .plus, .optional, .repeat => {
                try self.analyzeQuantifier(node, inside_quantifier);
            },
            .alternation => {
                try self.analyzeAlternation(node);
            },
            .concat => {
                const concat = node.data.concat;
                try self.analyzeNode(concat.left, inside_quantifier);
                try self.analyzeNode(concat.right, inside_quantifier);
            },
            .group => {
                const group = node.data.group;
                try self.analyzeNode(group.child, inside_quantifier);
            },
            .lookahead, .lookbehind => {
                // Lookarounds require backtracking
                self.can_use_thompson = false;
                const lookaround = if (node.node_type == .lookahead) node.data.lookahead else node.data.lookbehind;
                try self.analyzeNode(lookaround.child, inside_quantifier);
            },
            .backref => {
                // Backreferences require backtracking
                self.can_use_thompson = false;
                try self.addIssue("Pattern contains backreference (requires backtracking)");
            },
            else => {},
        }
    }

    fn analyzeQuantifier(self: *PatternAnalyzer, node: *ast.Node, inside_quantifier: bool) std.mem.Allocator.Error!void {
        const child = switch (node.node_type) {
            .star => node.data.star.child,
            .plus => node.data.plus.child,
            .optional => node.data.optional.child,
            .repeat => node.data.repeat.child,
            else => unreachable,
        };

        // Check for nested quantifiers - CRITICAL ISSUE
        // This check needs to happen regardless of inside_quantifier flag
        // because we want to detect patterns like (a+)+ where the outer + is not yet inside a quantifier
        if (self.isQuantifier(child)) {
            // Direct nesting: a++, a+*, etc.
            self.explosion_factor *= 1000000.0;
            try self.addIssue("CRITICAL: Nested quantifiers detected (causes exponential backtracking)");
            try self.addRecommendation("Rewrite pattern to avoid nesting quantifiers inside quantifiers");
            try self.addRecommendation("Example: Replace (a+)+ with a+ (they match the same input)");
        } else if (self.containsQuantifier(child)) {
            // Child contains quantifier: (a+)+, (a*b+)*, etc.
            // Use lower penalty for simple atomic patterns like (?:\d+)+
            // These are less dangerous than true nested quantifiers like (a+)+
            if (self.isAtomicGroup(child)) {
                // Atomic patterns like character classes are less dangerous
                self.explosion_factor *= 100.0; // MEDIUM risk instead of CRITICAL
                try self.addIssue("MEDIUM: Quantifier on atomic group with quantifiers (potential for slow matching)");
                try self.addRecommendation("Consider simplifying if possible");
            } else {
                // True nested quantifiers are critical
                self.explosion_factor *= 1000000.0;
                try self.addIssue("CRITICAL: Nested quantifiers detected (quantifier on expression with quantifiers)");
                try self.addRecommendation("Flatten nested quantifiers");
                try self.addRecommendation("Example: Replace (a+)+ with a+");
            }
        }

        // Additional penalty if we're already inside a quantifier (triple+ nesting)
        if (inside_quantifier and self.containsQuantifier(child)) {
            self.explosion_factor *= 1000.0; // Extra penalty for triple nesting
        }

        // Analyze with quantifier context
        try self.analyzeNode(child, true);

        // Check if quantifier is greedy or lazy
        const greedy = switch (node.node_type) {
            .star => node.data.star.greedy,
            .plus => node.data.plus.greedy,
            .optional => node.data.optional.greedy,
            .repeat => node.data.repeat.greedy,
            else => true,
        };

        if (!greedy) {
            // Lazy quantifiers slightly increase complexity
            self.explosion_factor *= 1.5;
        }
    }

    fn analyzeAlternation(self: *PatternAnalyzer, node: *ast.Node) std.mem.Allocator.Error!void {
        const alternation = node.data.alternation;

        // Check for ambiguous alternation (overlapping branches)
        if (self.detectAmbiguousAlternation(alternation.left, alternation.right)) {
            self.explosion_factor *= 10000.0; // High risk - can cause significant backtracking
            try self.addIssue("HIGH: Ambiguous alternation detected (overlapping branches)");
            try self.addRecommendation("Ensure alternation branches don't overlap");
            try self.addRecommendation("Example: Replace (a|a)* with a*");
        }

        try self.analyzeNode(alternation.left, false);
        try self.analyzeNode(alternation.right, false);
    }

    fn isQuantifier(self: *PatternAnalyzer, node: *ast.Node) bool {
        _ = self;
        return switch (node.node_type) {
            .star, .plus, .optional, .repeat => true,
            else => false,
        };
    }

    fn containsQuantifier(self: *PatternAnalyzer, node: *ast.Node) bool {
        switch (node.node_type) {
            .star, .plus, .optional, .repeat => return true,
            .concat => {
                const concat = node.data.concat;
                return self.containsQuantifier(concat.left) or self.containsQuantifier(concat.right);
            },
            .alternation => {
                const alternation = node.data.alternation;
                return self.containsQuantifier(alternation.left) or self.containsQuantifier(alternation.right);
            },
            .group => {
                const group = node.data.group;
                return self.containsQuantifier(group.child);
            },
            else => return false,
        }
    }

    fn isAtomicGroup(self: *PatternAnalyzer, node: *ast.Node) bool {
        _ = self;
        // A group is "atomic" if it contains only simple patterns that don't create
        // excessive backtracking even when quantified
        if (node.node_type != .group) return false;

        const group = node.data.group;
        return isSafeToQuantify(group.child);
    }

    fn isSafeToQuantify(node: *ast.Node) bool {
        // Check if this pattern is reasonably safe to quantify
        // We want to allow (?:\d+)+, (?:/\w+)*, and (?:https?://)? but reject (a+)+
        return switch (node.node_type) {
            // Literals and char classes are safe
            .literal, .char_class, .any => true,
            // Quantifiers are safe if:
            // 1. Child is atomic (char_class or any) - allows (?:\d+)+
            // 2. OR it's optional (?) - allows (?:https?://)?
            .star, .plus, .optional, .repeat => {
                const child = getQuantifierChild(node);
                const is_optional = node.node_type == .optional;
                const has_atomic_child = child.node_type == .char_class or child.node_type == .any;
                return has_atomic_child or is_optional;
            },
            // Concat is safe if it either:
            // 1. Has literal anchor with quantified char class (/\w+)
            // 2. Or all parts are safe to quantify (https?://)
            .concat => {
                const concat = node.data.concat;
                const has_anchor = hasLiteralAnchor(concat.left, concat.right);
                const all_safe = isSafeToQuantify(concat.left) and isSafeToQuantify(concat.right);
                return has_anchor or all_safe;
            },
            // Groups, alternations, etc. are not safe
            else => false,
        };
    }

    fn hasLiteralAnchor(left: *ast.Node, right: *ast.Node) bool {
        // Check if concat has at least one literal to act as an anchor
        // Pattern like /\w+ has / as anchor, so (?:/\w+)* is safer than (a+)+
        const left_is_literal = left.node_type == .literal;
        const right_is_literal = right.node_type == .literal;
        const left_is_quantifier = isQuantifierNode(left);
        const right_is_quantifier = isQuantifierNode(right);

        // At least one side must be a literal, and at least one must be quantified char class/any
        if (left_is_literal and right_is_quantifier) {
            const child = getQuantifierChild(right);
            return child.node_type == .char_class or child.node_type == .any;
        }
        if (right_is_literal and left_is_quantifier) {
            const child = getQuantifierChild(left);
            return child.node_type == .char_class or child.node_type == .any;
        }
        return false;
    }

    fn isQuantifierNode(node: *ast.Node) bool {
        return switch (node.node_type) {
            .star, .plus, .optional, .repeat => true,
            else => false,
        };
    }

    fn getQuantifierChild(node: *ast.Node) *ast.Node {
        return switch (node.node_type) {
            .star => node.data.star.child,
            .plus => node.data.plus.child,
            .optional => node.data.optional.child,
            .repeat => node.data.repeat.child,
            else => unreachable,
        };
    }

    fn detectAmbiguousAlternation(self: *PatternAnalyzer, left: *ast.Node, right: *ast.Node) bool {
        // Check for identical branches: (a|a)
        if (self.nodesAreIdentical(left, right)) {
            return true;
        }

        // Check for one branch being a subset of another
        // This is a simplified check - full analysis would be more complex
        return false;
    }

    fn nodesAreIdentical(self: *PatternAnalyzer, left: *ast.Node, right: *ast.Node) bool {

        if (left.node_type != right.node_type) return false;

        return switch (left.node_type) {
            .literal => left.data.literal == right.data.literal,
            .any => true,
            .star => self.nodesAreIdentical(left.data.star.child, right.data.star.child),
            .plus => self.nodesAreIdentical(left.data.plus.child, right.data.plus.child),
            .optional => self.nodesAreIdentical(left.data.optional.child, right.data.optional.child),
            .concat => {
                const left_concat = left.data.concat;
                const right_concat = right.data.concat;
                return self.nodesAreIdentical(left_concat.left, right_concat.left) and
                       self.nodesAreIdentical(left_concat.right, right_concat.right);
            },
            else => false,
        };
    }

    fn addIssue(self: *PatternAnalyzer, issue: []const u8) !void {
        const owned = try self.allocator.dupe(u8, issue);
        try self.issues.append(self.allocator, owned);
    }

    fn addRecommendation(self: *PatternAnalyzer, rec: []const u8) !void {
        const owned = try self.allocator.dupe(u8, rec);
        try self.recommendations.append(self.allocator, owned);
    }
};

/// Analyze a pattern and return whether it's safe to compile
pub fn analyzePattern(allocator: std.mem.Allocator, root: *ast.Node) !AnalysisResult {
    var analyzer = PatternAnalyzer.init(allocator);
    defer analyzer.deinit();
    return try analyzer.analyze(root);
}

/// Analyze and reject if risk is too high
pub fn analyzeAndValidate(allocator: std.mem.Allocator, root: *ast.Node, max_risk: RiskLevel) !void {
    var result = try analyzePattern(allocator, root);
    defer result.deinit(allocator);

    // Check if risk exceeds maximum (reject if risk >= max)
    const risk_value = @intFromEnum(result.risk_level);
    const max_value = @intFromEnum(max_risk);

    if (risk_value > max_value) {
        // Pattern is too dangerous - reject it
        return RegexError.PatternTooComplex;
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "analyzer: safe pattern" {
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "abc");
    var tree = try p.parse();
    defer tree.deinit();

    var result = try analyzePattern(allocator, tree.root);
    defer result.deinit(allocator);

    try std.testing.expectEqual(RiskLevel.safe, result.risk_level);
    try std.testing.expect(result.can_use_thompson);
}

test "analyzer: nested quantifiers (a+)+" {
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "(a+)+");
    var tree = try p.parse();
    defer tree.deinit();

    var result = try analyzePattern(allocator, tree.root);
    defer result.deinit(allocator);

    std.debug.print("\n(a+)+ Risk level: {}\n", .{result.risk_level});
    std.debug.print("Explosion factor: {d:.2}\n", .{result.explosion_factor});
    std.debug.print("Issues: {}\n", .{result.issues.len});
    for (result.issues) |issue| {
        std.debug.print("  - {s}\n", .{issue});
    }

    try std.testing.expectEqual(RiskLevel.critical, result.risk_level);
    try std.testing.expect(result.issues.len > 0);
    try std.testing.expect(result.explosion_factor >= 1000000.0);
}

test "analyzer: nested stars (a*)*" {
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "(a*)*");
    var tree = try p.parse();
    defer tree.deinit();

    var result = try analyzePattern(allocator, tree.root);
    defer result.deinit(allocator);

    try std.testing.expectEqual(RiskLevel.critical, result.risk_level);
}

test "analyzer: ambiguous alternation (a|a)*" {
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "(a|a)*");
    var tree = try p.parse();
    defer tree.deinit();

    var result = try analyzePattern(allocator, tree.root);
    defer result.deinit(allocator);

    try std.testing.expectEqual(RiskLevel.high, result.risk_level);
}

test "analyzer: backreference" {
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "(a)\\1");
    var tree = try p.parse();
    defer tree.deinit();

    var result = try analyzePattern(allocator, tree.root);
    defer result.deinit(allocator);

    try std.testing.expect(!result.can_use_thompson);
    try std.testing.expect(result.issues.len > 0);
}

test "analyzer: validation rejects critical risk" {
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "(a+)+");
    var tree = try p.parse();
    defer tree.deinit();

    // Should reject critical risk when max is high
    const result = analyzeAndValidate(allocator, tree.root, .high);
    try std.testing.expectError(RegexError.PatternTooComplex, result);
}

test "analyzer: validation accepts safe pattern" {
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "abc+");
    var tree = try p.parse();
    defer tree.deinit();

    // Should accept safe pattern
    try analyzeAndValidate(allocator, tree.root, .medium);
}

test "analyzer: complex URL pattern - part" {
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    const pattern = "(?:/\\w+)*";
    var p = try parser.Parser.init(allocator, pattern);
    var tree = try p.parse();
    defer tree.deinit();

    var result = try analyzePattern(allocator, tree.root);
    defer result.deinit(allocator);

    std.debug.print("\nPattern: {s}\n", .{pattern});
    std.debug.print("Risk level: {}\n", .{result.risk_level});
    std.debug.print("Explosion factor: {d:.2}\n", .{result.explosion_factor});
    std.debug.print("\nIssues ({}):\n", .{result.issues.len});
    for (result.issues) |issue| {
        std.debug.print("  - {s}\n", .{issue});
    }

    // This should not be critical
    try std.testing.expect(result.risk_level != .critical);
}

test "analyzer: full URL pattern" {
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    const pattern = "(?:https?://)?([a-z]+)(?:/\\w+)*";
    var p = try parser.Parser.init(allocator, pattern);
    var tree = try p.parse();
    defer tree.deinit();

    var result = try analyzePattern(allocator, tree.root);
    defer result.deinit(allocator);

    std.debug.print("\nFull pattern: {s}\n", .{pattern});
    std.debug.print("Risk level: {}\n", .{result.risk_level});
    std.debug.print("Explosion factor: {d:.2}\n", .{result.explosion_factor});
    std.debug.print("\nIssues ({}):\n", .{result.issues.len});
    for (result.issues) |issue| {
        std.debug.print("  - {s}\n", .{issue});
    }

    // Should not be critical
    try std.testing.expect(result.risk_level != .critical);
}
