const std = @import("std");
const Regex = @import("regex").Regex;

// Tests for named capture groups (?P<name>...) and (?<name>...)

test "named group: Python style (?P<name>...)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?P<word>\\w+)");
    defer regex.deinit();

    if (try regex.find("hello")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        try std.testing.expectEqualStrings("hello", match.slice);

        // Access by index
        try std.testing.expectEqual(@as(usize, 1), match.captures.len);
        try std.testing.expectEqualStrings("hello", match.captures[0]);

        // Access by name
        const capture_index = regex.getCaptureIndex("word");
        try std.testing.expect(capture_index != null);
        try std.testing.expectEqual(@as(usize, 1), capture_index.?);

        const named_capture = regex.getNamedCapture(&match, "word");
        try std.testing.expect(named_capture != null);
        try std.testing.expectEqualStrings("hello", named_capture.?);
    } else {
        return error.TestExpectedMatch;
    }
}

test "named group: .NET/Perl style (?<name>...)" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?<digit>\\d+)");
    defer regex.deinit();

    if (try regex.find("123")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        try std.testing.expectEqualStrings("123", match.slice);

        const named_capture = regex.getNamedCapture(&match, "digit");
        try std.testing.expect(named_capture != null);
        try std.testing.expectEqualStrings("123", named_capture.?);
    } else {
        return error.TestExpectedMatch;
    }
}

test "named group: multiple named groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?P<year>\\d{4})-(?P<month>\\d{2})-(?P<day>\\d{2})");
    defer regex.deinit();

    if (try regex.find("2025-10-27")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        try std.testing.expectEqualStrings("2025-10-27", match.slice);

        const year = regex.getNamedCapture(&match, "year");
        const month = regex.getNamedCapture(&match, "month");
        const day = regex.getNamedCapture(&match, "day");

        try std.testing.expect(year != null);
        try std.testing.expect(month != null);
        try std.testing.expect(day != null);

        try std.testing.expectEqualStrings("2025", year.?);
        try std.testing.expectEqualStrings("10", month.?);
        try std.testing.expectEqualStrings("27", day.?);
    } else {
        return error.TestExpectedMatch;
    }
}

test "named group: mixed with numbered groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(\\w+)@(?P<domain>\\w+\\.\\w+)");
    defer regex.deinit();

    if (try regex.find("user@example.com")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        // First group is numbered
        try std.testing.expectEqualStrings("user", match.captures[0]);

        // Second group is named
        const domain = regex.getNamedCapture(&match, "domain");
        try std.testing.expect(domain != null);
        try std.testing.expectEqualStrings("example.com", domain.?);
    } else {
        return error.TestExpectedMatch;
    }
}

test "named group: non-existent name returns null" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?P<word>\\w+)");
    defer regex.deinit();

    if (try regex.find("hello")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        const nonexistent = regex.getNamedCapture(&match, "nonexistent");
        try std.testing.expect(nonexistent == null);

        const index = regex.getCaptureIndex("nonexistent");
        try std.testing.expect(index == null);
    } else {
        return error.TestExpectedMatch;
    }
}

test "named group: with alternation" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?P<protocol>http|https)://(?P<host>[^/]+)");
    defer regex.deinit();

    if (try regex.find("https://example.com")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        const protocol = regex.getNamedCapture(&match, "protocol");
        const host = regex.getNamedCapture(&match, "host");

        try std.testing.expect(protocol != null);
        try std.testing.expect(host != null);

        try std.testing.expectEqualStrings("https", protocol.?);
        try std.testing.expectEqualStrings("example.com", host.?);
    } else {
        return error.TestExpectedMatch;
    }
}

test "named group: with quantifiers" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?P<tag><[^>]+>)(?P<content>.*)");
    defer regex.deinit();

    if (try regex.find("<div>hello world</div>")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        const tag = regex.getNamedCapture(&match, "tag");
        const content = regex.getNamedCapture(&match, "content");

        try std.testing.expect(tag != null);
        try std.testing.expect(content != null);

        try std.testing.expectEqualStrings("<div>", tag.?);
        try std.testing.expectEqualStrings("hello world</div>", content.?);
    } else {
        return error.TestExpectedMatch;
    }
}

test "named group: nested groups" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?P<outer>(inner))");
    defer regex.deinit();

    if (try regex.find("inner")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        // Outer named group
        const outer = regex.getNamedCapture(&match, "outer");
        try std.testing.expect(outer != null);
        try std.testing.expectEqualStrings("inner", outer.?);

        // Inner unnamed group (index 0 is outer, index 1 is inner)
        try std.testing.expectEqual(@as(usize, 2), match.captures.len);
        try std.testing.expectEqualStrings("inner", match.captures[0]); // outer
        try std.testing.expectEqualStrings("inner", match.captures[1]); // inner
    } else {
        return error.TestExpectedMatch;
    }
}

test "named group: with non-capturing group" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?:prefix-)?(?P<name>\\w+)");
    defer regex.deinit();

    if (try regex.find("prefix-test")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        // Non-capturing group doesn't create a capture
        try std.testing.expectEqual(@as(usize, 1), match.captures.len);

        const name = regex.getNamedCapture(&match, "name");
        try std.testing.expect(name != null);
        try std.testing.expectEqualStrings("test", name.?);
    } else {
        return error.TestExpectedMatch;
    }
}

test "named group: email parser example" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?P<user>[^@]+)@(?P<domain>[^@]+)");
    defer regex.deinit();

    if (try regex.find("john.doe@example.com")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        const user = regex.getNamedCapture(&match, "user");
        const domain = regex.getNamedCapture(&match, "domain");

        try std.testing.expect(user != null);
        try std.testing.expect(domain != null);

        try std.testing.expectEqualStrings("john.doe", user.?);
        try std.testing.expectEqualStrings("example.com", domain.?);
    } else {
        return error.TestExpectedMatch;
    }
}

test "named group: IP address parser" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?P<a>\\d+)\\.(?P<b>\\d+)\\.(?P<c>\\d+)\\.(?P<d>\\d+)");
    defer regex.deinit();

    if (try regex.find("192.168.1.1")) |match| {
        var mut_match = match;
        defer mut_match.deinit(allocator);

        const a = regex.getNamedCapture(&match, "a");
        const b = regex.getNamedCapture(&match, "b");
        const c = regex.getNamedCapture(&match, "c");
        const d = regex.getNamedCapture(&match, "d");

        try std.testing.expect(a != null);
        try std.testing.expect(b != null);
        try std.testing.expect(c != null);
        try std.testing.expect(d != null);

        try std.testing.expectEqualStrings("192", a.?);
        try std.testing.expectEqualStrings("168", b.?);
        try std.testing.expectEqualStrings("1", c.?);
        try std.testing.expectEqualStrings("1", d.?);
    } else {
        return error.TestExpectedMatch;
    }
}

test "named group: findAll preserves names" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "(?P<num>\\d+)");
    defer regex.deinit();

    var matches = try regex.findAll(allocator, "123 456 789");
    defer {
        for (matches) |*m| {
            var mut_match = m.*;
            mut_match.deinit(allocator);
        }
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 3), matches.len);

    // Each match should have the named capture
    for (matches) |match| {
        const num = regex.getNamedCapture(&match, "num");
        try std.testing.expect(num != null);
    }

    const num1 = regex.getNamedCapture(&matches[0], "num");
    const num2 = regex.getNamedCapture(&matches[1], "num");
    const num3 = regex.getNamedCapture(&matches[2], "num");

    try std.testing.expectEqualStrings("123", num1.?);
    try std.testing.expectEqualStrings("456", num2.?);
    try std.testing.expectEqualStrings("789", num3.?);
}
