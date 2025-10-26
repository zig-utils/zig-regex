const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Zig Regex Library v{d}.{d}.{d}\n", .{ regex.version.major, regex.version.minor, regex.version.patch });
    std.debug.print("Status: Early Development (Phase 1)\n\n", .{});

    // Example usage (will work once implemented)
    std.debug.print("Example (not yet functional):\n", .{});
    std.debug.print("  const pattern = try Regex.compile(allocator, \"\\\\d+\");\n", .{});
    std.debug.print("  defer pattern.deinit();\n", .{});
    std.debug.print("  if (try pattern.find(\"hello123\")) |match| {{\n", .{});
    std.debug.print("    std.debug.print(\"Found: {{s}}\\n\", .{{match.slice}});\n", .{});
    std.debug.print("  }}\n\n", .{});

    // Test basic compilation
    var pattern = try regex.Regex.compile(allocator, "test");
    defer pattern.deinit();

    std.debug.print("Successfully compiled pattern: \"{s}\"\n", .{pattern.pattern});
    std.debug.print("\nSee TODO.md for the complete development roadmap.\n", .{});
}
