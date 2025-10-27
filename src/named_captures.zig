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
