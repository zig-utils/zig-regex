const std = @import("std");
const Regex = @import("regex").Regex;
const SharedRegex = @import("regex").SharedRegex;
const RegexCache = @import("regex").RegexCache;
const testing = std.testing;

// Test data shared across threads
const TestData = struct {
    regex: *const Regex,
    success_count: std.atomic.Value(usize),
    error_count: std.atomic.Value(usize),
    test_inputs: []const []const u8,
};

fn workerThread(data: *TestData) void {
    for (data.test_inputs) |input| {
        if (data.regex.isMatch(input)) |matches| {
            if (matches) {
                _ = data.success_count.fetchAdd(1, .monotonic);
            }
        } else |_| {
            _ = data.error_count.fetchAdd(1, .monotonic);
        }
    }
}

test "concurrent matching with same regex" {
    const allocator = testing.allocator;

    // Compile a regex once
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    // Test inputs
    const test_inputs = [_][]const u8{
        "test123",
        "456test",
        "no numbers",
        "789",
        "abc",
    };

    // Create shared test data
    var test_data = TestData{
        .regex = &regex,
        .success_count = std.atomic.Value(usize).init(0),
        .error_count = std.atomic.Value(usize).init(0),
        .test_inputs = &test_inputs,
    };

    // Launch multiple threads
    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, workerThread, .{&test_data});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Verify results
    const total_matches = test_data.success_count.load(.monotonic);
    const total_errors = test_data.error_count.load(.monotonic);

    // Each thread processes all inputs, 3 out of 5 have numbers
    try testing.expectEqual(@as(usize, 0), total_errors);
    try testing.expectEqual(@as(usize, thread_count * 3), total_matches);
}

test "concurrent find operations" {
    const allocator = testing.allocator;

    var regex = try Regex.compile(allocator, "[0-9]+");
    defer regex.deinit();

    const Worker = struct {
        fn run(r: *const Regex, result: *std.atomic.Value(usize)) void {
            var found = false;
            if (r.find("abc123def")) |match_opt| {
                if (match_opt) |match| {
                    // Check if we found "123"
                    if (std.mem.eql(u8, match.slice, "123")) {
                        found = true;
                    }
                }
            } else |_| {}

            if (found) {
                _ = result.fetchAdd(1, .monotonic);
            }
        }
    };

    var success_count = std.atomic.Value(usize).init(0);

    const thread_count = 8;
    var threads: [thread_count]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &regex, &success_count });
    }

    for (threads) |thread| {
        thread.join();
    }

    // All threads should find the match
    try testing.expectEqual(@as(usize, thread_count), success_count.load(.monotonic));
}

test "SharedRegex reference counting" {
    const allocator = testing.allocator;

    var shared = try SharedRegex.init(allocator, "test");
    defer shared.deinit();

    // Acquire multiple references
    const ref1 = shared.acquire();
    const ref2 = shared.acquire();
    const ref3 = shared.acquire();

    // Use the regex
    const input = "test string";
    try testing.expect(try ref1.regex().isMatch(input));
    try testing.expect(try ref2.regex().isMatch(input));
    try testing.expect(try ref3.regex().isMatch(input));

    // Release references
    ref3.release();
    ref2.release();
    ref1.release();
}

test "SharedRegex concurrent access" {
    const allocator = testing.allocator;

    var shared = try SharedRegex.init(allocator, "\\d+");
    defer shared.deinit();

    const Worker = struct {
        fn run(s: *SharedRegex, counter: *std.atomic.Value(usize)) void {
            const ref = s.acquire();
            defer ref.release();

            const input = "count 42 items";
            if (ref.regex().isMatch(input)) |has_match| {
                if (has_match) {
                    _ = counter.fetchAdd(1, .monotonic);
                }
            } else |_| {}
        }
    };

    var counter = std.atomic.Value(usize).init(0);
    const thread_count = 10;
    var threads: [thread_count]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ shared, &counter });
    }

    for (threads) |thread| {
        thread.join();
    }

    try testing.expectEqual(@as(usize, thread_count), counter.load(.monotonic));
}

test "RegexCache basic operations" {
    const allocator = testing.allocator;

    var cache = RegexCache.init(allocator);
    defer cache.deinit();

    // Get and cache a pattern
    const regex1 = try cache.get("\\d+");
    try testing.expect(try regex1.isMatch("123"));

    // Get the same pattern again (should be cached)
    const regex2 = try cache.get("\\d+");
    try testing.expectEqual(regex1, regex2);

    // Get a different pattern
    const regex3 = try cache.get("[a-z]+");
    try testing.expect(try regex3.isMatch("abc"));
    try testing.expect(regex1 != regex3);
}

test "thread-safe allocator with concurrent matching" {
    // Use thread-safe allocator for concurrent access
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "test");
    defer regex.deinit();

    const Worker = struct {
        fn run(r: *const Regex, alloc: std.mem.Allocator) void {
            // Each thread does multiple matches with its own operations
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                _ = r.isMatch("test string") catch unreachable;
            }
            _ = alloc;
        }
    };

    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &regex, allocator });
    }

    for (threads) |thread| {
        thread.join();
    }
}

test "concurrent matching different patterns" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Compile multiple patterns
    var regex1 = try Regex.compile(allocator, "\\d+");
    defer regex1.deinit();

    var regex2 = try Regex.compile(allocator, "[a-z]+");
    defer regex2.deinit();

    var regex3 = try Regex.compile(allocator, "test");
    defer regex3.deinit();

    const Worker = struct {
        fn run(r1: *const Regex, r2: *const Regex, r3: *const Regex, results: *std.atomic.Value(usize)) void {
            const test_string = "test 123 abc";

            var count: usize = 0;
            if (r1.isMatch(test_string)) |m| {
                if (m) count += 1;
            } else |_| {}
            if (r2.isMatch(test_string)) |m| {
                if (m) count += 1;
            } else |_| {}
            if (r3.isMatch(test_string)) |m| {
                if (m) count += 1;
            } else |_| {}

            _ = results.fetchAdd(count, .monotonic);
        }
    };

    var results = std.atomic.Value(usize).init(0);
    const thread_count = 5;
    var threads: [thread_count]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &regex1, &regex2, &regex3, &results });
    }

    for (threads) |thread| {
        thread.join();
    }

    // Each thread should find 3 matches (one per pattern)
    try testing.expectEqual(@as(usize, thread_count * 3), results.load(.monotonic));
}

test "stress test: many threads many matches" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "test");
    defer regex.deinit();

    const Worker = struct {
        fn run(r: *const Regex, counter: *std.atomic.Value(usize)) void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                if (r.isMatch("this is a test string")) |matches| {
                    if (matches) {
                        _ = counter.fetchAdd(1, .monotonic);
                    }
                } else |_| {}
            }
        }
    };

    var counter = std.atomic.Value(usize).init(0);
    const thread_count = 16;
    var threads: [thread_count]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &regex, &counter });
    }

    for (threads) |thread| {
        thread.join();
    }

    // All threads should successfully match
    try testing.expectEqual(@as(usize, thread_count * 1000), counter.load(.monotonic));
}
