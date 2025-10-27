const std = @import("std");

/// Zig Regex Library
///
/// A modern, performant regular expression library for Zig with zero external dependencies.
/// This library implements Thompson NFA construction for efficient pattern matching.
///
/// Example usage:
/// ```zig
/// const Regex = @import("regex").Regex;
/// const regex = try Regex.compile(allocator, "\\d+");
/// defer regex.deinit();
/// if (try regex.find("abc123")) |match| {
///     std.debug.print("Found: {s}\n", .{match.slice});
/// }
/// ```

// Public API exports
pub const Regex = @import("regex.zig").Regex;
pub const Match = @import("regex.zig").Match;
pub const RegexError = @import("errors.zig").RegexError;
pub const ErrorContext = @import("errors.zig").ErrorContext;
pub const ErrorHelper = @import("errors.zig").ErrorHelper;

// Performance and debugging
pub const Profiler = @import("profiling.zig").Profiler;
pub const ScopedTimer = @import("profiling.zig").ScopedTimer;

// Thread safety
pub const thread_safety = @import("thread_safety.zig");
pub const SharedRegex = @import("thread_safety.zig").SharedRegex(Regex);
pub const RegexCache = @import("thread_safety.zig").RegexCache(Regex);

// Builder API and pattern composition
pub const Builder = @import("builder.zig").Builder;
pub const Patterns = @import("builder.zig").Patterns;
pub const Composer = @import("builder.zig").Composer;

// Linting and analysis
pub const Lint = @import("lint.zig").Lint;
pub const ComplexityAnalyzer = @import("lint.zig").ComplexityAnalyzer;

// Macro system
pub const macros = @import("macros.zig");
pub const MacroRegistry = @import("macros.zig").MacroRegistry;
pub const CommonMacros = @import("macros.zig").CommonMacros;

// AST optimization and visualization
pub const ASTOptimizer = @import("ast_optimizer.zig").ASTOptimizer;
pub const PrettyPrinter = @import("pretty_print.zig").PrettyPrinter;
pub const ASTStats = @import("pretty_print.zig").ASTStats;

// NFA optimization and visualization
pub const NFAOptimizer = @import("nfa_optimizer.zig").NFAOptimizer;
pub const NFAVisualizer = @import("nfa_optimizer.zig").NFAVisualizer;

// C FFI
pub const c_api = @import("c_api.zig");

// Internal modules (for advanced users and debugging)
pub const common = @import("common.zig");
pub const parser = @import("parser.zig");
pub const compiler = @import("compiler.zig");
pub const optimizer = @import("optimizer.zig");
pub const debug = @import("debug.zig");
pub const profiling = @import("profiling.zig");

// Version information
pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

test {
    // Run all tests from imported modules
    std.testing.refAllDecls(@This());
}
