const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Zig Regex Examples ===\n\n", .{});

    // Example 1: Simple literal matching
    {
        std.debug.print("Example 1: Literal matching\n", .{});
        var regex = try Regex.compile(allocator, "hello");
        defer regex.deinit();

        const matches = try regex.isMatch("hello");
        std.debug.print("  Does 'hello' match 'hello'? {}\n", .{matches});
        std.debug.print("\n", .{});
    }

    // Example 2: Alternation
    {
        std.debug.print("Example 2: Alternation (cat|dog)\n", .{});
        var regex = try Regex.compile(allocator, "cat|dog");
        defer regex.deinit();

        std.debug.print("  'cat' matches: {}\n", .{try regex.isMatch("cat")});
        std.debug.print("  'dog' matches: {}\n", .{try regex.isMatch("dog")});
        std.debug.print("  'bird' matches: {}\n", .{try regex.isMatch("bird")});
        std.debug.print("\n", .{});
    }

    // Example 3: Star quantifier
    {
        std.debug.print("Example 3: Star quantifier (a*)\n", .{});
        var regex = try Regex.compile(allocator, "a*");
        defer regex.deinit();

        std.debug.print("  '' matches: {}\n", .{try regex.isMatch("")});
        std.debug.print("  'a' matches: {}\n", .{try regex.isMatch("a")});
        std.debug.print("  'aaa' matches: {}\n", .{try regex.isMatch("aaa")});
        std.debug.print("\n", .{});
    }

    // Example 4: Finding matches
    {
        std.debug.print("Example 4: Finding matches\n", .{});
        var regex = try Regex.compile(allocator, "world");
        defer regex.deinit();

        if (try regex.find("hello world")) |match_result| {
            var mut_match = match_result;
            defer mut_match.deinit(allocator);
            std.debug.print("  Found '{s}' at position {d}-{d}\n", .{ match_result.slice, match_result.start, match_result.end });
        }
        std.debug.print("\n", .{});
    }

    // Example 5: Replace
    {
        std.debug.print("Example 5: Replace\n", .{});
        var regex = try Regex.compile(allocator, "world");
        defer regex.deinit();

        const result = try regex.replace(allocator, "hello world", "Zig");
        defer allocator.free(result);

        std.debug.print("  Replaced: '{s}'\n", .{result});
        std.debug.print("\n", .{});
    }

    std.debug.print("=== All examples completed successfully! ===\n\n", .{});
}
