const std = @import("std");
const Regex = @import("regex").Regex;

// Backreference Tests

test "backreference: simple capture group replacement" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "hello", "$1!");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello!", result);
}

test "backreference: swap two words" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+) (\\w+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "hello world", "$2 $1");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("world hello", result);
}

test "backreference: repeat capture" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "test", "$1-$1");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("test-test", result);
}

test "backreference: multiple captures" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\d+)-(\\d+)-(\\d+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "2025-10-26", "$3/$2/$1");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("26/10/2025", result);
}

test "backreference: escaped dollar sign" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\d+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "100", "$$$1");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("$100", result);
}

test "backreference: replaceAll with captures" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)@(\\w+)");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "user@example and admin@test", "$1 at $2");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("user at example and admin at test", result);
}

test "backreference: extract and format phone numbers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\d{3})-(\\d{3})-(\\d{4})");
    defer regex.deinit();

    const result = try regex.replace(allocator, "555-123-4567", "($1) $2-$3");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("(555) 123-4567", result);
}

test "backreference: reformat dates" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\d{4})-(\\d{2})-(\\d{2})");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "2025-10-26 and 2024-12-31", "$2/$3/$1");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("10/26/2025 and 12/31/2024", result);
}

test "backreference: wrap matches in tags" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "hello world", "<b>$1</b>");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("<b>hello</b> <b>world</b>", result);
}

test "backreference: invalid capture index" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)");
    defer regex.deinit();

    // Only one capture group, $2 should be treated as literal
    const result = try regex.replace(allocator, "test", "$1 $2");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("test $2", result);
}

test "backreference: nested captures" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "((\\w+)@(\\w+))");
    defer regex.deinit();

    const result = try regex.replace(allocator, "user@example.com", "Email: $1 (user=$2, domain=$3)");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Email: user@example (user=user, domain=example).com", result);
}

test "backreference: quote words" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\b(\\w+)\\b");
    defer regex.deinit();

    const result = try regex.replaceAll(allocator, "hello world", "'$1'");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("'hello' 'world'", result);
}

test "backreference: transform case context" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(Mr|Mrs|Ms) (\\w+)");
    defer regex.deinit();

    const result = try regex.replace(allocator, "Hello Mr Smith", "$1. $2");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello Mr. Smith", result);
}
