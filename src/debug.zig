const std = @import("std");
const ast = @import("ast.zig");
const compiler = @import("compiler.zig");
const optimizer = @import("optimizer.zig");

/// Debug output configuration
pub const DebugConfig = struct {
    /// Show AST structure
    show_ast: bool = false,

    /// Show NFA states and transitions
    show_nfa: bool = false,

    /// Show optimization info
    show_optimizations: bool = false,

    /// Show matching steps
    show_matching: bool = false,

    /// Use colors in output (ANSI colors)
    use_colors: bool = true,

    /// Maximum depth for AST visualization
    max_depth: usize = 10,
};

/// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const magenta = "\x1b[35m";
    const cyan = "\x1b[36m";
    const gray = "\x1b[90m";
};

/// Visualizer for AST and NFA structures
pub const Visualizer = struct {
    allocator: std.mem.Allocator,
    config: DebugConfig,
    writer: std.io.AnyWriter,

    pub fn init(allocator: std.mem.Allocator, config: DebugConfig, writer: std.io.AnyWriter) Visualizer {
        return .{
            .allocator = allocator,
            .config = config,
            .writer = writer,
        };
    }

    /// Visualize AST structure
    pub fn visualizeAST(self: *Visualizer, node: *ast.Node) !void {
        try self.writer.writeAll("\n");
        if (self.config.use_colors) {
            try self.writer.print("{s}=== AST Structure ==={s}\n", .{ Color.bold, Color.reset });
        } else {
            try self.writer.writeAll("=== AST Structure ===\n");
        }
        try self.printNode(node, 0, "");
        try self.writer.writeAll("\n");
    }

    fn printNode(self: *Visualizer, node: *ast.Node, depth: usize, prefix: []const u8) !void {
        if (depth > self.config.max_depth) {
            try self.writer.print("{s}...\n", .{prefix});
            return;
        }

        const node_color = if (self.config.use_colors) Color.cyan else "";
        const reset = if (self.config.use_colors) Color.reset else "";

        switch (node.node_type) {
            .literal => {
                try self.writer.print("{s}{s}Literal{s}: '{c}'\n", .{ prefix, node_color, reset, node.data.literal });
            },
            .any => {
                try self.writer.print("{s}{s}Any{s} (.)\n", .{ prefix, node_color, reset });
            },
            .concat => {
                try self.writer.print("{s}{s}Concat{s}\n", .{ prefix, node_color, reset });
                const new_prefix = try std.fmt.allocPrint(self.allocator, "{s}  ", .{prefix});
                defer self.allocator.free(new_prefix);
                try self.printNode(node.data.concat.left, depth + 1, new_prefix);
                try self.printNode(node.data.concat.right, depth + 1, new_prefix);
            },
            .alternation => {
                try self.writer.print("{s}{s}Alternation{s} (|)\n", .{ prefix, node_color, reset });
                const new_prefix = try std.fmt.allocPrint(self.allocator, "{s}  ", .{prefix});
                defer self.allocator.free(new_prefix);
                try self.printNode(node.data.alternation.left, depth + 1, new_prefix);
                try self.printNode(node.data.alternation.right, depth + 1, new_prefix);
            },
            .star => {
                const greedy_str = if (node.data.star.greedy) " (greedy)" else " (lazy)";
                try self.writer.print("{s}{s}Star{s} (*{s})\n", .{ prefix, node_color, reset, greedy_str });
                const new_prefix = try std.fmt.allocPrint(self.allocator, "{s}  ", .{prefix});
                defer self.allocator.free(new_prefix);
                try self.printNode(node.data.star.child, depth + 1, new_prefix);
            },
            .plus => {
                const greedy_str = if (node.data.plus.greedy) " (greedy)" else " (lazy)";
                try self.writer.print("{s}{s}Plus{s} (+{s})\n", .{ prefix, node_color, reset, greedy_str });
                const new_prefix = try std.fmt.allocPrint(self.allocator, "{s}  ", .{prefix});
                defer self.allocator.free(new_prefix);
                try self.printNode(node.data.plus.child, depth + 1, new_prefix);
            },
            .optional => {
                const greedy_str = if (node.data.optional.greedy) " (greedy)" else " (lazy)";
                try self.writer.print("{s}{s}Optional{s} (?{s})\n", .{ prefix, node_color, reset, greedy_str });
                const new_prefix = try std.fmt.allocPrint(self.allocator, "{s}  ", .{prefix});
                defer self.allocator.free(new_prefix);
                try self.printNode(node.data.optional.child, depth + 1, new_prefix);
            },
            .repeat => {
                const repeat = node.data.repeat;
                if (repeat.bounds.max) |max| {
                    try self.writer.print("{s}{s}Repeat{s} {{{d},{d}}}\n", .{ prefix, node_color, reset, repeat.bounds.min, max });
                } else {
                    try self.writer.print("{s}{s}Repeat{s} {{{d},}}\n", .{ prefix, node_color, reset, repeat.bounds.min });
                }
                const new_prefix = try std.fmt.allocPrint(self.allocator, "{s}  ", .{prefix});
                defer self.allocator.free(new_prefix);
                try self.printNode(repeat.child, depth + 1, new_prefix);
            },
            .group => {
                const group = node.data.group;
                if (group.capturing) {
                    try self.writer.print("{s}{s}Group{s} (capturing)\n", .{ prefix, node_color, reset });
                } else {
                    try self.writer.print("{s}{s}Group{s} (non-capturing)\n", .{ prefix, node_color, reset });
                }
                const new_prefix = try std.fmt.allocPrint(self.allocator, "{s}  ", .{prefix});
                defer self.allocator.free(new_prefix);
                try self.printNode(group.child, depth + 1, new_prefix);
            },
            .char_class => {
                const cc = node.data.char_class;
                if (cc.negated) {
                    try self.writer.print("{s}{s}CharClass{s} [^...] ({d} ranges)\n", .{ prefix, node_color, reset, cc.ranges.len });
                } else {
                    try self.writer.print("{s}{s}CharClass{s} [...] ({d} ranges)\n", .{ prefix, node_color, reset, cc.ranges.len });
                }
            },
            .anchor => {
                const anchor_str = switch (node.data.anchor) {
                    .start_line => "^",
                    .end_line => "$",
                    .word_boundary => "\\b",
                };
                try self.writer.print("{s}{s}Anchor{s}: {s}\n", .{ prefix, node_color, reset, anchor_str });
            },
            .empty => {
                try self.writer.print("{s}{s}Empty{s}\n", .{ prefix, node_color, reset });
            },
        }
    }

    /// Visualize NFA structure
    pub fn visualizeNFA(self: *Visualizer, nfa: *const compiler.NFA) !void {
        try self.writer.writeAll("\n");
        if (self.config.use_colors) {
            try self.writer.print("{s}=== NFA Structure ==={s}\n", .{ Color.bold, Color.reset });
        } else {
            try self.writer.writeAll("=== NFA Structure ===\n");
        }

        try self.writer.print("Start state: {d}\n", .{nfa.start});
        try self.writer.print("Accept state: {d}\n", .{nfa.accept});
        try self.writer.print("Total states: {d}\n\n", .{nfa.states.items.len});

        const state_color = if (self.config.use_colors) Color.green else "";
        const trans_color = if (self.config.use_colors) Color.yellow else "";
        const reset = if (self.config.use_colors) Color.reset else "";

        for (nfa.states.items, 0..) |state, i| {
            const is_start = i == nfa.start;
            const is_accept = i == nfa.accept;

            if (is_start and is_accept) {
                try self.writer.print("{s}State {d}{s} [START, ACCEPT]\n", .{ state_color, i, reset });
            } else if (is_start) {
                try self.writer.print("{s}State {d}{s} [START]\n", .{ state_color, i, reset });
            } else if (is_accept) {
                try self.writer.print("{s}State {d}{s} [ACCEPT]\n", .{ state_color, i, reset });
            } else {
                try self.writer.print("{s}State {d}{s}\n", .{ state_color, i, reset });
            }

            // Print transitions
            for (state.transitions.items) |trans| {
                try self.writer.print("  {s}→{s} State {d} ", .{ trans_color, reset, trans.target });

                switch (trans.condition) {
                    .char => |c| {
                        if (std.ascii.isPrint(c)) {
                            try self.writer.print("on '{c}'\n", .{c});
                        } else {
                            try self.writer.print("on 0x{x}\n", .{c});
                        }
                    },
                    .char_class => |cc| {
                        if (cc.negated) {
                            try self.writer.print("on [^...] ({d} ranges)\n", .{cc.ranges.len});
                        } else {
                            try self.writer.print("on [...] ({d} ranges)\n", .{cc.ranges.len});
                        }
                    },
                    .epsilon => {
                        try self.writer.print("on ε (epsilon)\n", .{});
                    },
                    .any => {
                        try self.writer.print("on . (any)\n", .{});
                    },
                    .anchor => |anchor| {
                        const anchor_str = switch (anchor) {
                            .start_line => "^",
                            .end_line => "$",
                            .word_boundary => "\\b",
                        };
                        try self.writer.print("on {s} (anchor)\n", .{anchor_str});
                    },
                    .capture_start => |group_id| {
                        try self.writer.print("on CAPTURE_START({d})\n", .{group_id});
                    },
                    .capture_end => |group_id| {
                        try self.writer.print("on CAPTURE_END({d})\n", .{group_id});
                    },
                }
            }

            if (state.transitions.items.len == 0) {
                try self.writer.writeAll("  (no transitions)\n");
            }
        }
        try self.writer.writeAll("\n");
    }

    /// Visualize optimization information
    pub fn visualizeOptimizations(self: *Visualizer, opt_info: *const optimizer.OptimizationInfo) !void {
        try self.writer.writeAll("\n");
        if (self.config.use_colors) {
            try self.writer.print("{s}=== Optimization Info ==={s}\n", .{ Color.bold, Color.reset });
        } else {
            try self.writer.writeAll("=== Optimization Info ===\n");
        }

        const check = if (self.config.use_colors) Color.green ++ "✓" ++ Color.reset else "[X]";
        const cross = if (self.config.use_colors) Color.red ++ "✗" ++ Color.reset else "[ ]";

        // Literal prefix
        if (opt_info.literal_prefix) |prefix| {
            try self.writer.print("{s} Literal prefix: \"{s}\"\n", .{ check, prefix });
        } else {
            try self.writer.print("{s} No literal prefix\n", .{cross});
        }

        // Anchors
        if (opt_info.anchored_start) {
            try self.writer.print("{s} Start-anchored (^)\n", .{check});
        } else {
            try self.writer.print("{s} Not start-anchored\n", .{cross});
        }

        if (opt_info.anchored_end) {
            try self.writer.print("{s} End-anchored ($)\n", .{check});
        } else {
            try self.writer.print("{s} Not end-anchored\n", .{cross});
        }

        // Length bounds
        try self.writer.print("\nLength bounds:\n", .{});
        try self.writer.print("  Min length: {d}\n", .{opt_info.min_length});
        if (opt_info.max_length) |max| {
            try self.writer.print("  Max length: {d}\n", .{max});
        } else {
            try self.writer.print("  Max length: unbounded\n", .{});
        }

        try self.writer.writeAll("\n");
    }

    /// Generate DOT graph for NFA (Graphviz format)
    pub fn generateDotGraph(self: *Visualizer, nfa: *const compiler.NFA, pattern: []const u8) !void {
        try self.writer.writeAll("digraph NFA {\n");
        try self.writer.writeAll("  rankdir=LR;\n");
        try self.writer.writeAll("  node [shape=circle];\n");
        try self.writer.print("  label=\"Pattern: {s}\";\n", .{pattern});
        try self.writer.writeAll("  labelloc=\"t\";\n\n");

        // Mark start and accept states with different shapes
        try self.writer.print("  {d} [shape=doublecircle, style=bold, label=\"{d}\\nSTART\"];\n", .{ nfa.start, nfa.start });
        try self.writer.print("  {d} [shape=doublecircle, label=\"{d}\\nACCEPT\"];\n", .{ nfa.accept, nfa.accept });

        // Add invisible start node
        try self.writer.writeAll("  start [shape=none, label=\"\"];\n");
        try self.writer.print("  start -> {d};\n\n", .{nfa.start});

        // Add transitions
        for (nfa.states.items, 0..) |state, from| {
            for (state.transitions.items) |trans| {
                const label = try self.getTransitionLabel(trans);
                defer self.allocator.free(label);

                const style = if (trans.condition == .epsilon) "dashed" else "solid";
                try self.writer.print("  {d} -> {d} [label=\"{s}\", style={s}];\n", .{ from, trans.target, label, style });
            }
        }

        try self.writer.writeAll("}\n");
    }

    fn getTransitionLabel(self: *Visualizer, trans: compiler.Transition) ![]const u8 {
        return switch (trans.condition) {
            .char => |c| blk: {
                if (std.ascii.isPrint(c)) {
                    break :blk try std.fmt.allocPrint(self.allocator, "{c}", .{c});
                } else {
                    break :blk try std.fmt.allocPrint(self.allocator, "\\\\x{x:0>2}", .{c});
                }
            },
            .char_class => |cc| blk: {
                if (cc.negated) {
                    break :blk try std.fmt.allocPrint(self.allocator, "[^...{d}]", .{cc.ranges.len});
                } else {
                    break :blk try std.fmt.allocPrint(self.allocator, "[...{d}]", .{cc.ranges.len});
                }
            },
            .epsilon => try std.fmt.allocPrint(self.allocator, "ε", .{}),
            .any => try std.fmt.allocPrint(self.allocator, ".", .{}),
            .anchor => |anchor| blk: {
                const str = switch (anchor) {
                    .start_line => "^",
                    .end_line => "$",
                    .word_boundary => "\\\\b",
                };
                break :blk try std.fmt.allocPrint(self.allocator, "{s}", .{str});
            },
            .capture_start => |id| try std.fmt.allocPrint(self.allocator, "CAP_START({d})", .{id}),
            .capture_end => |id| try std.fmt.allocPrint(self.allocator, "CAP_END({d})", .{id}),
        };
    }
};

/// Pattern analyzer that provides insights about regex patterns
pub const PatternAnalyzer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PatternAnalyzer {
        return .{ .allocator = allocator };
    }

    /// Analyze a pattern and return insights
    pub fn analyze(self: *PatternAnalyzer, pattern: []const u8, tree: *ast.AST, opt_info: *const optimizer.OptimizationInfo) !PatternAnalysis {
        var analysis = PatternAnalysis{
            .pattern = pattern,
            .complexity = self.calculateComplexity(tree.root),
            .can_match_empty = self.canMatchEmpty(tree.root),
            .is_finite = opt_info.max_length != null,
            .warnings = try std.ArrayList([]const u8).initCapacity(self.allocator, 0),
            .suggestions = try std.ArrayList([]const u8).initCapacity(self.allocator, 0),
            .allocator = self.allocator,
        };

        // Check for common issues
        try self.detectIssues(tree.root, &analysis);

        return analysis;
    }

    fn calculateComplexity(self: *PatternAnalyzer, node: *ast.Node) usize {
        return switch (node.node_type) {
            .literal, .any, .anchor, .empty => 1,
            .char_class => 2,
            .concat => blk: {
                const left = self.calculateComplexity(node.data.concat.left);
                const right = self.calculateComplexity(node.data.concat.right);
                break :blk left + right;
            },
            .alternation => blk: {
                const left = self.calculateComplexity(node.data.alternation.left);
                const right = self.calculateComplexity(node.data.alternation.right);
                break :blk left + right + 1;
            },
            .star, .plus => blk: {
                const child = switch (node.node_type) {
                    .star => self.calculateComplexity(node.data.star.child),
                    .plus => self.calculateComplexity(node.data.plus.child),
                    else => unreachable,
                };
                break :blk child * 3; // Quantifiers add complexity
            },
            .optional => self.calculateComplexity(node.data.optional.child) + 1,
            .repeat => blk: {
                const child = self.calculateComplexity(node.data.repeat.child);
                const max = node.data.repeat.bounds.max orelse 10;
                break :blk child * max;
            },
            .group => self.calculateComplexity(node.data.group.child),
            .lookahead, .lookbehind => blk: {
                const child = switch (node.node_type) {
                    .lookahead => self.calculateComplexity(node.data.lookahead.child),
                    .lookbehind => self.calculateComplexity(node.data.lookbehind.child),
                    else => unreachable,
                };
                break :blk child * 5; // Assertions add significant complexity
            },
            .backref => 5, // Backreferences are complex
        };
    }

    fn canMatchEmpty(self: *PatternAnalyzer, node: *ast.Node) bool {
        return switch (node.node_type) {
            .literal, .any, .char_class, .backref => false,
            .empty, .anchor, .lookahead, .lookbehind => true,
            .concat => blk: {
                const left = self.canMatchEmpty(node.data.concat.left);
                const right = self.canMatchEmpty(node.data.concat.right);
                break :blk left and right;
            },
            .alternation => blk: {
                const left = self.canMatchEmpty(node.data.alternation.left);
                const right = self.canMatchEmpty(node.data.alternation.right);
                break :blk left or right;
            },
            .star, .optional => true,
            .plus => self.canMatchEmpty(node.data.plus.child),
            .repeat => blk: {
                if (node.data.repeat.bounds.min == 0) break :blk true;
                break :blk self.canMatchEmpty(node.data.repeat.child);
            },
            .group => self.canMatchEmpty(node.data.group.child),
        };
    }

    fn detectIssues(self: *PatternAnalyzer, node: *ast.Node, analysis: *PatternAnalysis) !void {
        switch (node.node_type) {
            .star => {
                // Check for nested quantifiers
                if (self.hasQuantifier(node.data.star.child)) {
                    try analysis.warnings.append(self.allocator, "Nested quantifiers detected - may cause performance issues");
                }
            },
            .plus => {
                if (self.hasQuantifier(node.data.plus.child)) {
                    try analysis.warnings.append(self.allocator, "Nested quantifiers detected - may cause performance issues");
                }
            },
            .alternation => {
                // Recursively check both branches
                try self.detectIssues(node.data.alternation.left, analysis);
                try self.detectIssues(node.data.alternation.right, analysis);
            },
            .concat => {
                try self.detectIssues(node.data.concat.left, analysis);
                try self.detectIssues(node.data.concat.right, analysis);
            },
            .group => {
                try self.detectIssues(node.data.group.child, analysis);
            },
            else => {},
        }
    }

    fn hasQuantifier(self: *PatternAnalyzer, node: *ast.Node) bool {
        _ = self;
        return switch (node.node_type) {
            .star, .plus, .optional, .repeat => true,
            else => false,
        };
    }
};

pub const PatternAnalysis = struct {
    pattern: []const u8,
    complexity: usize,
    can_match_empty: bool,
    is_finite: bool,
    warnings: std.ArrayList([]const u8),
    suggestions: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PatternAnalysis) void {
        self.warnings.deinit(self.allocator);
        self.suggestions.deinit(self.allocator);
    }
};
