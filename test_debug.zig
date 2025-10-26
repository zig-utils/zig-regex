const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test 1: Log levels
    std.debug.print("Test 1: Log levels\n", .{});
    {
        var regex = try Regex.compile(allocator, "\\[(INFO|WARN|ERROR|DEBUG)\\]");
        defer regex.deinit();

        const result = try regex.isMatch("[INFO] Application started");
        std.debug.print("  Result: {}\n", .{result});
    }

    // Test 2: Password min length
    std.debug.print("\nTest 2: Password min length\n", .{});
    {
        var regex = try Regex.compile(allocator, "^.{8,}$");
        defer regex.deinit();

        const result1 = try regex.isMatch("password123");
        const result2 = try regex.isMatch("short");
        std.debug.print("  'password123': {}\n", .{result1});
        std.debug.print("  'short': {}\n", .{result2});
    }

    // Test 3: Contains digit
    std.debug.print("\nTest 3: Contains digit\n", .{});
    {
        var regex = try Regex.compile(allocator, "\\d");
        defer regex.deinit();

        const result = try regex.isMatch("password1");
        std.debug.print("  Result: {}\n", .{result});
    }
}
