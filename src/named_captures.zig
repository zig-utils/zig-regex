const std = @import("std");

/// Named capture group support for regex patterns
/// Supports both Python-style (?P<name>...) and .NET-style (?<name>...)
pub const NamedCaptureRegistry = struct {
    allocator: std.mem.Allocator,
    /// Maps capture group names to indices
    name_to_index: std.StringHashMap(usize),
    /// Maps indices to names (for reverse lookup)
    index_to_name: std.AutoHashMap(usize, []const u8),
    next_index: usize,

    pub fn init(allocator: std.mem.Allocator) NamedCaptureRegistry {
        return .{
            .allocator = allocator,
            .name_to_index = std.StringHashMap(usize).init(allocator),
            .index_to_name = std.AutoHashMap(usize, []const u8).init(allocator),
            .next_index = 0,
        };
    }

    pub fn deinit(self: *NamedCaptureRegistry) void {
        // Free all stored names
        var name_it = self.name_to_index.keyIterator();
        while (name_it.next()) |name| {
            self.allocator.free(name.*);
        }
        self.name_to_index.deinit();
        self.index_to_name.deinit();
    }

    /// Register a new named capture group
    pub fn register(self: *NamedCaptureRegistry, name: []const u8) !usize {
        // Check if name already exists
        if (self.name_to_index.get(name)) |index| {
            return index;
        }

        // Allocate name and register
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const index = self.next_index;
        try self.name_to_index.put(name_copy, index);
        try self.index_to_name.put(index, name_copy);

        self.next_index += 1;
        return index;
    }

    /// Get the index for a named capture group
    pub fn getIndex(self: *const NamedCaptureRegistry, name: []const u8) ?usize {
        return self.name_to_index.get(name);
    }

    /// Get the name for a capture group index
    pub fn getName(self: *const NamedCaptureRegistry, index: usize) ?[]const u8 {
        return self.index_to_name.get(index);
    }

    /// Get total number of named captures
    pub fn count(self: *NamedCaptureRegistry) usize {
        return self.name_to_index.count();
    }
};

/// Extended Match type with named capture support
pub const NamedMatch = struct {
    /// The matched substring
    slice: []const u8,
    /// Start index
    start: usize,
    /// End index
    end: usize,
    /// Positional captures
    captures: []const []const u8,
    /// Named captures registry
    registry: ?*const NamedCaptureRegistry,

    /// Get a capture by name
    pub fn getCapture(self: NamedMatch, name: []const u8) ?[]const u8 {
        if (self.registry) |reg| {
            if (reg.getIndex(name)) |index| {
                if (index < self.captures.len) {
                    return self.captures[index];
                }
            }
        }
        return null;
    }

    /// Get a capture by index
    pub fn getCaptureByIndex(self: NamedMatch, index: usize) ?[]const u8 {
        if (index < self.captures.len) {
            return self.captures[index];
        }
        return null;
    }

    /// Check if a named capture exists
    pub fn hasCapture(self: NamedMatch, name: []const u8) bool {
        return self.getCapture(name) != null;
    }

    pub fn deinit(self: *NamedMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.captures);
    }
};

// Tests
test "named_captures: register and lookup" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    const year_idx = try registry.register("year");
    const month_idx = try registry.register("month");
    const day_idx = try registry.register("day");

    try std.testing.expectEqual(@as(usize, 0), year_idx);
    try std.testing.expectEqual(@as(usize, 1), month_idx);
    try std.testing.expectEqual(@as(usize, 2), day_idx);

    try std.testing.expectEqual(@as(usize, 0), registry.getIndex("year").?);
    try std.testing.expectEqual(@as(usize, 1), registry.getIndex("month").?);
    try std.testing.expectEqual(@as(usize, 2), registry.getIndex("day").?);

    try std.testing.expectEqualStrings("year", registry.getName(0).?);
    try std.testing.expectEqualStrings("month", registry.getName(1).?);
    try std.testing.expectEqualStrings("day", registry.getName(2).?);
}

test "named_captures: duplicate registration" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    const idx1 = try registry.register("test");
    const idx2 = try registry.register("test");

    try std.testing.expectEqual(idx1, idx2);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
}

test "named_captures: NamedMatch get capture" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    _ = try registry.register("year");
    _ = try registry.register("month");

    const captures = try allocator.dupe([]const u8, &[_][]const u8{ "2024", "03" });
    defer allocator.free(captures);

    const match = NamedMatch{
        .slice = "2024-03",
        .start = 0,
        .end = 7,
        .captures = captures,
        .registry = &registry,
    };

    try std.testing.expectEqualStrings("2024", match.getCapture("year").?);
    try std.testing.expectEqualStrings("03", match.getCapture("month").?);
    try std.testing.expect(match.getCapture("day") == null);
}

// Edge case tests
test "named_captures: empty name" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    const idx = try registry.register("");
    try std.testing.expectEqual(@as(usize, 0), idx);
    try std.testing.expectEqual(@as(usize, 0), registry.getIndex("").?);
}

test "named_captures: special characters in names" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    // Test names with underscores, numbers, unicode
    _ = try registry.register("name_with_underscore");
    _ = try registry.register("name123");
    _ = try registry.register("name_123_test");

    try std.testing.expect(registry.getIndex("name_with_underscore") != null);
    try std.testing.expect(registry.getIndex("name123") != null);
    try std.testing.expect(registry.getIndex("name_123_test") != null);
}

test "named_captures: many captures" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    // Register 100 captures
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "capture_{d}", .{i});
        const idx = try registry.register(name);
        try std.testing.expectEqual(i, idx);
    }

    try std.testing.expectEqual(@as(usize, 100), registry.count());

    // Verify all lookups work
    i = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "capture_{d}", .{i});
        try std.testing.expectEqual(i, registry.getIndex(name).?);
    }
}

test "named_captures: NamedMatch without registry" {
    const allocator = std.testing.allocator;

    const captures = try allocator.dupe([]const u8, &[_][]const u8{ "test", "value" });
    defer allocator.free(captures);

    const match = NamedMatch{
        .slice = "test-value",
        .start = 0,
        .end = 10,
        .captures = captures,
        .registry = null, // No registry
    };

    // Should return null for any name
    try std.testing.expect(match.getCapture("anything") == null);
    try std.testing.expect(!match.hasCapture("anything"));

    // But getCaptureByIndex should still work
    try std.testing.expectEqualStrings("test", match.getCaptureByIndex(0).?);
    try std.testing.expectEqualStrings("value", match.getCaptureByIndex(1).?);
    try std.testing.expect(match.getCaptureByIndex(2) == null);
}

test "named_captures: boundary cases for indices" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    _ = try registry.register("first");
    _ = try registry.register("second");

    const captures = try allocator.dupe([]const u8, &[_][]const u8{"val1"});
    defer allocator.free(captures);

    const match = NamedMatch{
        .slice = "val1",
        .start = 0,
        .end = 4,
        .captures = captures,
        .registry = &registry,
    };

    // first exists and is in bounds
    try std.testing.expectEqualStrings("val1", match.getCapture("first").?);

    // second exists in registry but is out of bounds in captures array
    try std.testing.expect(match.getCapture("second") == null);
}

test "named_captures: case sensitivity" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    const idx1 = try registry.register("Name");
    const idx2 = try registry.register("name");
    const idx3 = try registry.register("NAME");

    // All should be different
    try std.testing.expect(idx1 != idx2);
    try std.testing.expect(idx2 != idx3);
    try std.testing.expect(idx1 != idx3);
    try std.testing.expectEqual(@as(usize, 3), registry.count());
}

test "named_captures: long names" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    // Test with a very long name (1000 characters)
    const long_name = try allocator.alloc(u8, 1000);
    defer allocator.free(long_name);
    @memset(long_name, 'a');

    const idx = try registry.register(long_name);
    try std.testing.expectEqual(@as(usize, 0), idx);

    const retrieved = registry.getName(0);
    try std.testing.expectEqual(@as(usize, 1000), retrieved.?.len);
}

test "named_captures: hasCapture convenience method" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    _ = try registry.register("exists");

    const captures = try allocator.dupe([]const u8, &[_][]const u8{"value"});
    defer allocator.free(captures);

    const match = NamedMatch{
        .slice = "value",
        .start = 0,
        .end = 5,
        .captures = captures,
        .registry = &registry,
    };

    try std.testing.expect(match.hasCapture("exists"));
    try std.testing.expect(!match.hasCapture("doesnt_exist"));
}

// Stress and integration tests
test "named_captures: stress test - register and lookup 1000 captures" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    // Register 1000 captures
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "capture_group_{d}", .{i});
        const idx = try registry.register(name);
        try std.testing.expectEqual(i, idx);
    }

    try std.testing.expectEqual(@as(usize, 1000), registry.count());

    // Verify all lookups work correctly
    i = 0;
    while (i < 1000) : (i += 1) {
        var buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "capture_group_{d}", .{i});
        try std.testing.expectEqual(i, registry.getIndex(name).?);
        try std.testing.expectEqualStrings(name, registry.getName(i).?);
    }
}

test "named_captures: memory stress - repeated register/deinit cycles" {
    const allocator = std.testing.allocator;

    var cycle: usize = 0;
    while (cycle < 10) : (cycle += 1) {
        var registry = NamedCaptureRegistry.init(allocator);

        var i: usize = 0;
        while (i < 100) : (i += 1) {
            var buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&buf, "name_{d}", .{i});
            _ = try registry.register(name);
        }

        try std.testing.expectEqual(@as(usize, 100), registry.count());
        registry.deinit();
    }
}

test "named_captures: interleaved operations" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    // Interleave registrations and lookups
    _ = try registry.register("first");
    try std.testing.expectEqual(@as(usize, 0), registry.getIndex("first").?);

    _ = try registry.register("second");
    try std.testing.expectEqual(@as(usize, 1), registry.getIndex("second").?);
    try std.testing.expectEqual(@as(usize, 0), registry.getIndex("first").?);

    _ = try registry.register("third");
    try std.testing.expectEqual(@as(usize, 2), registry.getIndex("third").?);
    try std.testing.expectEqual(@as(usize, 1), registry.getIndex("second").?);

    // Verify getName works for all
    try std.testing.expectEqualStrings("first", registry.getName(0).?);
    try std.testing.expectEqualStrings("second", registry.getName(1).?);
    try std.testing.expectEqualStrings("third", registry.getName(2).?);
}

test "named_captures: NamedMatch with empty captures array" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    _ = try registry.register("test");

    const captures = try allocator.dupe([]const u8, &[_][]const u8{});
    defer allocator.free(captures);

    const match = NamedMatch{
        .slice = "",
        .start = 0,
        .end = 0,
        .captures = captures,
        .registry = &registry,
    };

    // Should return null since captures array is empty
    try std.testing.expect(match.getCapture("test") == null);
    try std.testing.expect(!match.hasCapture("test"));
}

test "named_captures: multiple NamedMatch instances with same registry" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    _ = try registry.register("year");
    _ = try registry.register("month");

    // Create first match
    const captures1 = try allocator.dupe([]const u8, &[_][]const u8{ "2024", "03" });
    defer allocator.free(captures1);
    const match1 = NamedMatch{
        .slice = "2024-03",
        .start = 0,
        .end = 7,
        .captures = captures1,
        .registry = &registry,
    };

    // Create second match with different values
    const captures2 = try allocator.dupe([]const u8, &[_][]const u8{ "2023", "12" });
    defer allocator.free(captures2);
    const match2 = NamedMatch{
        .slice = "2023-12",
        .start = 0,
        .end = 7,
        .captures = captures2,
        .registry = &registry,
    };

    // Both should work independently
    try std.testing.expectEqualStrings("2024", match1.getCapture("year").?);
    try std.testing.expectEqualStrings("03", match1.getCapture("month").?);
    try std.testing.expectEqualStrings("2023", match2.getCapture("year").?);
    try std.testing.expectEqualStrings("12", match2.getCapture("month").?);
}

test "named_captures: getCaptureByIndex edge cases" {
    const allocator = std.testing.allocator;

    const captures = try allocator.dupe([]const u8, &[_][]const u8{ "a", "b", "c" });
    defer allocator.free(captures);

    const match = NamedMatch{
        .slice = "abc",
        .start = 0,
        .end = 3,
        .captures = captures,
        .registry = null,
    };

    // Valid indices
    try std.testing.expectEqualStrings("a", match.getCaptureByIndex(0).?);
    try std.testing.expectEqualStrings("b", match.getCaptureByIndex(1).?);
    try std.testing.expectEqualStrings("c", match.getCaptureByIndex(2).?);

    // Out of bounds
    try std.testing.expect(match.getCaptureByIndex(3) == null);
    try std.testing.expect(match.getCaptureByIndex(100) == null);
}

test "named_captures: registration collision - same name multiple times" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    const idx1 = try registry.register("duplicate");
    const idx2 = try registry.register("duplicate");
    const idx3 = try registry.register("duplicate");

    // All should return the same index
    try std.testing.expectEqual(idx1, idx2);
    try std.testing.expectEqual(idx2, idx3);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
}

test "named_captures: getName with invalid index" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    _ = try registry.register("only_one");

    // Valid index
    try std.testing.expect(registry.getName(0) != null);

    // Invalid indices
    try std.testing.expect(registry.getName(1) == null);
    try std.testing.expect(registry.getName(100) == null);
    try std.testing.expect(registry.getName(999999) == null);
}

test "named_captures: names with similar prefixes" {
    const allocator = std.testing.allocator;
    var registry = NamedCaptureRegistry.init(allocator);
    defer registry.deinit();

    _ = try registry.register("test");
    _ = try registry.register("test_");
    _ = try registry.register("test_1");
    _ = try registry.register("test_123");

    // All should be distinct
    try std.testing.expectEqual(@as(usize, 4), registry.count());
    try std.testing.expect(registry.getIndex("test").? != registry.getIndex("test_").?);
    try std.testing.expect(registry.getIndex("test_").? != registry.getIndex("test_1").?);
    try std.testing.expect(registry.getIndex("test_1").? != registry.getIndex("test_123").?);
}
