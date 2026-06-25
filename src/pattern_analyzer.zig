const std = @import("std");
const ast = @import("ast.zig");
const common = @import("common.zig");
const unicode = @import("unicode.zig");
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
            .issues = .empty,
            .recommendations = .empty,
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
        if (self.isQuantifier(child) and self.isUnboundedQuant(child)) {
            // Direct nesting of UNBOUNDED quantifiers: (a+)+, (a*)*, etc.
            // catastrophic backtracking. A bounded inner (`a{3,8}`, `a?`) under
            // any outer is at worst polynomial, so it falls through below.
            self.explosion_factor *= 1000000.0;
            try self.addIssue("CRITICAL: Nested quantifiers detected (causes exponential backtracking)");
            try self.addRecommendation("Rewrite pattern to avoid nesting quantifiers inside quantifiers");
            try self.addRecommendation("Example: Replace (a+)+ with a+ (they match the same input)");
        } else if (self.containsQuantifier(child) and !self.containsUnboundedQuantifier(child)) {
            // The child only contains BOUNDED quantifiers (`{m,n}`/`?`): even an
            // unbounded outer can drive at most polynomial work, not exponential
            // (e.g. `(-[a-z0-9]{3,8})*` from BCP-47 locale validation). Safe.
            self.explosion_factor *= 2.0;
        } else if (self.containsQuantifier(child)) {
            // Child contains quantifier: (a+)+, (a*b+)*, etc.
            // Use lower penalty for simple atomic patterns like (?:\d+)+
            // These are less dangerous than true nested quantifiers like (a+)+
            //
            // Bounded outer quantifiers (`?`, small `{n,m}`) cannot drive
            // exponential backtracking even when their child contains a
            // quantifier — the outer can match at most a fixed number of
            // times. Patterns like `(seq2-([a-z]+))?` were previously
            // (and incorrectly) rejected as PatternTooComplex; they're
            // safe. See zig-utils/zig-regex#3.
            if (self.outerIsBounded(node)) {
                // Mild bump only — bounded by a small constant.
                self.explosion_factor *= 2.0;
            } else if (self.leadingLiteral(child)) {
                // The repeated body begins with a fixed literal/char-class
                // delimiter (e.g. `(-keyword)+`, `(ab+)*`): each iteration must
                // start at that atom, so the partition is unambiguous and the
                // match is linear — not the exponential `(a+)+` shape. Common in
                // BCP-47 locale / URL grammars. Negligible bump — these are
                // common and safe, and a large grammar stacks many of them, so
                // the per-group factor must stay near 1 to avoid a false
                // cumulative CRITICAL.
                self.explosion_factor *= 1.5;
            } else if (hasFixedEnd(child)) {
                // Likewise, a required trailing delimiter (e.g.
                // `((a+)?(b+)?c)*`) gives each iteration a fixed endpoint.
                self.explosion_factor *= 1.5;
            } else if (self.isAtomicGroup(child)) {
                // Atomic patterns like character classes are less dangerous
                self.explosion_factor *= 1.5;
            } else {
                // True nested quantifiers are critical
                self.explosion_factor *= 1000000.0;
                try self.addIssue("CRITICAL: Nested quantifiers detected (quantifier on expression with quantifiers)");
                try self.addRecommendation("Flatten nested quantifiers");
                try self.addRecommendation("Example: Replace (a+)+ with a+");
            }
        }

        // Additional penalty for triple+ nesting — but only when the inner is a
        // genuinely-dangerous unbounded, non-delimited quantifier. Deeply but
        // safely nested grammars (delimited or bounded, e.g. BCP-47) must not be
        // penalised into a false CRITICAL.
        if (inside_quantifier and self.containsUnboundedQuantifier(child) and !self.leadingLiteral(child)) {
            self.explosion_factor *= 1000.0;
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

    /// True when the outer quantifier on `node` is bounded by a small
    /// constant — i.e. `?` (0..1), or a `{n,m}` repeat with a small `m`.
    /// Bounded outers can't drive exponential backtracking even when they
    /// wrap a quantifier-bearing child, so the analyser skips the
    /// "nested quantifier" critical penalty for them.
    fn outerIsBounded(self: *PatternAnalyzer, node: *ast.Node) bool {
        _ = self;
        return switch (node.node_type) {
            .optional => true,
            .repeat => blk: {
                const r = node.data.repeat;
                const max = r.bounds.max orelse break :blk false;
                // 10 is generous — patterns with `{0,10}` outers have
                // a fixed small number of paths regardless of inner shape.
                break :blk max <= 10;
            },
            else => false,
        };
    }

    /// Whether `node` is itself an *unbounded* quantifier (`*`, `+`, or a
    /// `{m,}` repeat with no upper bound) — the only kind that can drive
    /// exponential backtracking when nested. A `?` or `{m,n}` is bounded.
    fn isUnboundedQuant(self: *PatternAnalyzer, node: *ast.Node) bool {
        _ = self;
        return switch (node.node_type) {
            .star, .plus => true,
            .repeat => node.data.repeat.bounds.max == null,
            else => false,
        };
    }

    /// Whether `node`'s leftmost matchable atom is a fixed literal / char-class
    /// / anchor — i.e. every match must begin there. When a repeated group's
    /// body has such a leading anchor, its iterations are delimited and cannot
    /// overlap, so even nested unbounded quantifiers inside match in linear time
    /// (no catastrophic backtracking).
    fn leadingLiteral(self: *PatternAnalyzer, node: *ast.Node) bool {
        return switch (node.node_type) {
            .literal, .char_class, .class_set, .unicode_property, .anchor => true,
            .group => self.leadingLiteral(node.data.group.child),
            .concat => self.leadingLiteral(node.data.concat.left),
            else => false,
        };
    }

    /// Whether `node`'s subtree contains any unbounded quantifier.
    fn containsUnboundedQuantifier(self: *PatternAnalyzer, node: *ast.Node) bool {
        if (self.isUnboundedQuant(node)) return true;
        switch (node.node_type) {
            .star => return self.containsUnboundedQuantifier(node.data.star.child),
            .plus => return self.containsUnboundedQuantifier(node.data.plus.child),
            .optional => return self.containsUnboundedQuantifier(node.data.optional.child),
            .repeat => return self.containsUnboundedQuantifier(node.data.repeat.child),
            .concat => return self.containsUnboundedQuantifier(node.data.concat.left) or
                self.containsUnboundedQuantifier(node.data.concat.right),
            .alternation => return self.containsUnboundedQuantifier(node.data.alternation.left) or
                self.containsUnboundedQuantifier(node.data.alternation.right),
            .group => return self.containsUnboundedQuantifier(node.data.group.child),
            else => return false,
        }
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
                const has_delimited_prefix = hasDelimitedQuantifierPrefix(concat.left, concat.right);
                const all_safe = isSafeToQuantify(concat.left) and isSafeToQuantify(concat.right);
                return has_anchor or has_delimited_prefix or all_safe;
            },
            .alternation => {
                const alt = node.data.alternation;
                return startsDisjoint(alt.left, alt.right) and
                    (hasFixedStart(alt.left) or isSafeToQuantify(alt.left)) and
                    (hasFixedStart(alt.right) or isSafeToQuantify(alt.right));
            },
            // A group is transparent for backtracking analysis — it's exactly as
            // safe to quantify as its body (e.g. `(?:[A-Za-z_]|x)+`). Without this
            // the analyser conservatively rejected any quantified group whose body
            // wasn't a bare atom, producing false CRITICALs on real grammars
            // (the XML attribute matcher in the regression suite).
            .group => isSafeToQuantify(node.data.group.child),
            // Assertions, etc. are not safe
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

    fn hasFixedStart(node: *ast.Node) bool {
        return switch (node.node_type) {
            .literal, .char_class, .class_set, .unicode_property, .anchor => true,
            .group => hasFixedStart(node.data.group.child),
            .concat => hasFixedStart(node.data.concat.left),
            // An alternation begins at a fixed atom iff every branch does
            // (e.g. `[A-Za-z_]|"` — each branch starts with a literal/class).
            .alternation => hasFixedStart(node.data.alternation.left) and
                hasFixedStart(node.data.alternation.right),
            else => false,
        };
    }

    fn hasFixedEnd(node: *ast.Node) bool {
        return switch (node.node_type) {
            .literal, .char_class, .class_set, .unicode_property, .anchor => true,
            .group => hasFixedEnd(node.data.group.child),
            .concat => hasFixedEnd(node.data.concat.right),
            else => false,
        };
    }

    fn hasDelimitedQuantifierPrefix(left: *ast.Node, right: *ast.Node) bool {
        const delimiter = quantifiedAtom(left) orelse return false;
        return startsDisjointFromAtom(right, delimiter);
    }

    /// The single fixed atom (`literal` / `char_class` / `class_set`) repeated by
    /// `node` when `node` is a quantifier over such an atom (e.g. the `[ \t]` of
    /// `[ \t]+`), else null. This is the delimiter whose disjointness from the
    /// rest of the body makes a repeated group safe.
    fn quantifiedAtom(node: *ast.Node) ?*ast.Node {
        if (!isQuantifierNode(node)) return null;
        const child = getQuantifierChild(node);
        return switch (child.node_type) {
            .literal, .char_class, .class_set, .unicode_property => child,
            else => null,
        };
    }

    /// Whether every byte that `node` can begin with is rejected by the atom
    /// `delimiter` — i.e. the body that follows a `delimiter+` prefix can never
    /// start with a delimiter byte, so iterations can't overlap.
    fn startsDisjointFromAtom(node: *ast.Node, delimiter: *ast.Node) bool {
        return switch (node.node_type) {
            .literal, .char_class, .class_set, .unicode_property, .any => atomsDisjoint(node, delimiter),
            .group => startsDisjointFromAtom(node.data.group.child, delimiter),
            .concat => startsDisjointFromAtom(node.data.concat.left, delimiter),
            .alternation => startsDisjointFromAtom(node.data.alternation.left, delimiter) and
                startsDisjointFromAtom(node.data.alternation.right, delimiter),
            .star, .plus, .optional, .repeat => startsDisjointFromAtom(getQuantifierChild(node), delimiter),
            else => false,
        };
    }

    /// Whether two fixed atoms share no byte (handles `literal`, `char_class`,
    /// `class_set`, and `.` — `.` is treated as matching everything, so it
    /// overlaps any atom).
    fn atomsDisjoint(a: *ast.Node, b: *ast.Node) bool {
        var c: u16 = 0;
        while (c <= 255) : (c += 1) {
            const byte: u8 = @intCast(c);
            if (atomMatchesByte(a, byte) and atomMatchesByte(b, byte)) return false;
        }
        return true;
    }

    /// Whether a single fixed atom node matches `byte`.
    fn atomMatchesByte(node: *ast.Node, byte: u8) bool {
        return switch (node.node_type) {
            .literal => node.data.literal == byte,
            .char_class => node.data.char_class.matches(byte),
            .class_set => node.data.class_set.matches(byte, false),
            .unicode_property => unicodePropMatchesByte(node, byte),
            .any => true,
            else => false,
        };
    }

    /// Whether a `\p{…}` atom can match (or begin a UTF-8 sequence that matches)
    /// `byte`. Exact for ASCII (the byte *is* the code point); conservative for
    /// non-ASCII, since any UTF-8 lead byte might begin a matching code point —
    /// so disjointness is only ever claimed against ASCII delimiters (the common
    /// case: whitespace, quotes, punctuation), never falsely.
    fn unicodePropMatchesByte(node: *ast.Node, byte: u8) bool {
        if (byte >= 0x80) return true;
        const up = node.data.unicode_property;
        return unicode.matchesSpec(byte, up.spec) != up.negated;
    }

    fn startsDisjoint(left: *ast.Node, right: *ast.Node) bool {
        var c: u16 = 0;
        while (c <= 255) : (c += 1) {
            const byte: u8 = @intCast(c);
            if (canStartWith(left, byte) and canStartWith(right, byte)) return false;
        }
        return true;
    }

    fn canStartWith(node: *ast.Node, byte: u8) bool {
        return switch (node.node_type) {
            .literal => node.data.literal == byte,
            .char_class => node.data.char_class.matches(byte),
            .class_set => node.data.class_set.matches(byte, false),
            .unicode_property => unicodePropMatchesByte(node, byte),
            .any => true,
            .group => canStartWith(node.data.group.child, byte),
            .concat => canStartWith(node.data.concat.left, byte),
            .alternation => canStartWith(node.data.alternation.left, byte) or
                canStartWith(node.data.alternation.right, byte),
            .star, .plus, .optional, .repeat => canStartWith(getQuantifierChild(node), byte),
            else => false,
        };
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
        var has_critical = false;
        for (result.issues) |issue| {
            if (std.mem.startsWith(u8, issue, "CRITICAL:")) {
                has_critical = true;
                break;
            }
        }
        if (!has_critical) return;
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

    // This should not be critical
    try std.testing.expect(result.risk_level != .critical);
}

test "analyzer: bounded outer optional with inner quantifier is not critical (#3)" {
    // Regression for zig-utils/zig-regex#3:
    // `seq1-(seq2-([a-zA-Z0-9]+))?` was being rejected as PatternTooComplex
    // because the outer `?` wraps a group that contains the inner `+`.
    // An outer `?` matches at most once — it cannot drive exponential
    // backtracking — so this should compile fine.
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    var p = try parser.Parser.init(allocator, "seq1-(seq2-([a-zA-Z0-9]+))?");
    var tree = try p.parse();
    defer tree.deinit();

    var result = try analyzePattern(allocator, tree.root);
    defer result.deinit(allocator);

    try std.testing.expect(result.risk_level != .critical);
    try std.testing.expect(result.risk_level != .high);

    // And the validate path should accept it under any non-trivial limit.
    try analyzeAndValidate(allocator, tree.root, .medium);
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

    // Should not be critical
    try std.testing.expect(result.risk_level != .critical);
}

test "analyzer: class-set delimited quantifier prefix is not critical" {
    // Bracket classes parse to `.class_set`, which the safety heuristics used to
    // ignore — so a delimited repeated group whose delimiter is a class set
    // (`([ \t]+...)*`, the XML attribute matcher) was wrongly rejected as
    // PatternTooComplex even though the whitespace delimiter is disjoint from the
    // body and the iterations therefore can't overlap.
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    const patterns = [_][]const u8{
        // leading class-set delimiter (`[ \t\n\r]+`) disjoint from the body
        "([ \\n\\t\\r]+([A-Za-z_:]|[^\\x00-\\x7F])([A-Za-z0-9_:.-]|[^\\x00-\\x7F])*)*",
        // disjoint alternation of class-set / quoted-string branches
        "([A-Za-z_:]+|\"[^\"]*\"|'[^']*')*",
    };
    for (patterns) |pattern| {
        var p = try parser.Parser.init(allocator, pattern);
        var tree = try p.parse();
        defer tree.deinit();
        var result = try analyzePattern(allocator, tree.root);
        defer result.deinit(allocator);
        try std.testing.expect(result.risk_level != .critical);
        try analyzeAndValidate(allocator, tree.root, .high);
    }
}

test "analyzer: unicode-property delimited quantifier is not critical" {
    // `\p{…}` parses to `.unicode_property`, another atom the safety heuristics
    // used to ignore — so delimited repeats over Unicode properties were wrongly
    // rejected. These are genuinely safe (each iteration begins at a fixed atom
    // disjoint from the body), so they must compile.
    const allocator = std.testing.allocator;
    const parser = @import("parser.zig");

    const safe = [_][]const u8{
        "([ \\t]+\\p{L}+)*", // whitespace-delimited property run
        "(\\p{Lu}\\p{Ll}*)*", // each iteration starts at an uppercase letter
    };
    for (safe) |pattern| {
        var p = try parser.Parser.init(allocator, pattern);
        var tree = try p.parse();
        defer tree.deinit();
        var result = try analyzePattern(allocator, tree.root);
        defer result.deinit(allocator);
        try std.testing.expect(result.risk_level != .critical);
        try analyzeAndValidate(allocator, tree.root, .high);
    }

    // ...but genuinely catastrophic property nesting stays critical.
    for ([_][]const u8{ "(\\p{L}*)*", "(\\p{L}+|\\p{N}+)*" }) |pattern| {
        var p = try parser.Parser.init(allocator, pattern);
        var tree = try p.parse();
        defer tree.deinit();
        var result = try analyzePattern(allocator, tree.root);
        defer result.deinit(allocator);
        try std.testing.expectEqual(RiskLevel.critical, result.risk_level);
    }
}

