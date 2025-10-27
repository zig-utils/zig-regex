const std = @import("std");
const Regex = @import("regex").Regex;
const SharedRegex = @import("regex").SharedRegex;
const RegexCache = @import("regex").RegexCache;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Regex Thread Safety Examples ===\n\n", .{});

    // Example 1: Basic concurrent matching
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 1: Basic concurrent matching\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        // Compile once
        var regex = try Regex.compile(allocator, "\\d+");
        defer regex.deinit();

        const Worker = struct {
            fn run(r: *const Regex, thread_id: usize, results: *std.atomic.Value(usize)) void {
                const inputs = [_][]const u8{
                    "thread test 123",
                    "456 items",
                    "no numbers here",
                };

                var matches: usize = 0;
                for (inputs) |input| {
                    if (r.isMatch(input)) |has_match| {
                        if (has_match) matches += 1;
                    } else |_| {}
                }

                std.debug.print("Thread {d}: Found {d} matches\n", .{ thread_id, matches });
                _ = results.fetchAdd(matches, .monotonic);
            }
        };

        var results = std.atomic.Value(usize).init(0);
        const thread_count = 4;
        var threads: [thread_count]std.Thread = undefined;

        std.debug.print("Launching {d} concurrent threads...\n", .{thread_count});

        for (&threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &regex, i, &results });
        }

        for (threads) |thread| {
            thread.join();
        }

        std.debug.print("Total matches across all threads: {d}\n\n", .{results.load(.monotonic)});
    }

    // Example 2: SharedRegex with reference counting
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 2: SharedRegex with reference counting\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        var shared = try SharedRegex.init(allocator, "test");
        defer shared.deinit();

        const Worker = struct {
            fn run(s: *SharedRegex, thread_id: usize) void {
                // Acquire a reference
                const ref = s.acquire();
                defer ref.release();

                std.debug.print("Thread {d}: Acquired reference\n", .{thread_id});

                if (ref.regex().isMatch("this is a test")) |matches| {
                    if (matches) {
                        std.debug.print("Thread {d}: Pattern matched!\n", .{thread_id});
                    }
                } else |_| {}
            }
        };

        const thread_count = 3;
        var threads: [thread_count]std.Thread = undefined;

        for (&threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{ shared, i });
        }

        for (threads) |thread| {
            thread.join();
        }

        std.debug.print("All threads completed, references released\n\n", .{});
    }

    // Example 3: Thread-local regex cache
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 3: Thread-local regex cache\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        const Worker = struct {
            fn run(alloc: std.mem.Allocator, thread_id: usize) void {
                // Each thread gets its own cache
                var cache = RegexCache.init(alloc);
                defer cache.deinit();

                std.debug.print("Thread {d}: Created local cache\n", .{thread_id});

                // First access - compiles and caches
                if (cache.get("\\d+")) |regex1| {
                    _ = regex1.isMatch("123") catch {};
                } else |_| {}

                // Second access - retrieves from cache
                if (cache.get("\\d+")) |regex2| {
                    _ = regex2.isMatch("456") catch {};
                } else |_| {}

                std.debug.print("Thread {d}: Used cached regex efficiently\n", .{thread_id});
            }
        };

        const thread_count = 3;
        var threads: [thread_count]std.Thread = undefined;

        for (&threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{ allocator, i });
        }

        for (threads) |thread| {
            thread.join();
        }

        std.debug.print("\n", .{});
    }

    // Example 4: Concurrent pattern matching performance
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 4: Performance with concurrent matching\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        var regex = try Regex.compile(allocator, "test");
        defer regex.deinit();

        const Worker = struct {
            fn run(r: *const Regex) usize {
                const start = std.time.nanoTimestamp();

                var count: usize = 0;
                var i: usize = 0;
                while (i < 10000) : (i += 1) {
                    if (r.isMatch("this is a test string")) |matches| {
                        if (matches) count += 1;
                    } else |_| {}
                }

                const end = std.time.nanoTimestamp();
                const elapsed_ms = @as(u64, @intCast(end - start)) / 1_000_000;
                return elapsed_ms;
            }
        };

        // Sequential baseline
        const sequential_time = Worker.run(&regex);
        std.debug.print("Sequential: 10,000 matches in {d}ms\n", .{sequential_time});

        // Parallel execution
        const thread_count = 4;
        var threads: [thread_count]std.Thread = undefined;
        var times: [thread_count]usize = undefined;

        const ParallelWorker = struct {
            fn run(r: *const Regex, time_ptr: *usize) void {
                time_ptr.* = Worker.run(r);
            }
        };

        const parallel_start = std.time.nanoTimestamp();

        for (&threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, ParallelWorker.run, .{ &regex, &times[i] });
        }

        for (threads) |thread| {
            thread.join();
        }

        const parallel_end = std.time.nanoTimestamp();
        const total_parallel = @as(u64, @intCast(parallel_end - parallel_start)) / 1_000_000;

        std.debug.print("Parallel ({d} threads): 40,000 matches in {d}ms\n", .{ thread_count, total_parallel });
        std.debug.print("Individual thread times: ", .{});
        for (times, 0..) |time, i| {
            std.debug.print("{d}ms", .{time});
            if (i < times.len - 1) std.debug.print(", ", .{});
        }
        std.debug.print("\n\n", .{});
    }

    // Example 5: Multiple patterns, multiple threads
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 5: Multiple patterns with concurrent access\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        var email_regex = try Regex.compile(allocator, "[a-z]+@[a-z]+\\.[a-z]+");
        defer email_regex.deinit();

        var phone_regex = try Regex.compile(allocator, "\\d{3}-\\d{4}");
        defer phone_regex.deinit();

        var url_regex = try Regex.compile(allocator, "https?://");
        defer url_regex.deinit();

        const Worker = struct {
            fn run(
                email: *const Regex,
                phone: *const Regex,
                url: *const Regex,
                thread_id: usize,
            ) void {
                const test_data = "Contact: user@example.com, 555-1234, https://example.com";

                var found_items: usize = 0;
                if (email.isMatch(test_data)) |m| {
                    if (m) found_items += 1;
                } else |_| {}
                if (phone.isMatch(test_data)) |m| {
                    if (m) found_items += 1;
                } else |_| {}
                if (url.isMatch(test_data)) |m| {
                    if (m) found_items += 1;
                } else |_| {}

                std.debug.print("Thread {d}: Found {d}/3 patterns\n", .{ thread_id, found_items });
            }
        };

        const thread_count = 5;
        var threads: [thread_count]std.Thread = undefined;

        for (&threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &email_regex, &phone_regex, &url_regex, i });
        }

        for (threads) |thread| {
            thread.join();
        }

        std.debug.print("\n", .{});
    }

    // Example 6: Thread safety guarantees demonstration
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 6: Thread safety guarantees\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        std.debug.print("\nThread Safety Guarantees:\n", .{});
        std.debug.print("✓ Compiled Regex is immutable and thread-safe\n", .{});
        std.debug.print("✓ Each match operation creates thread-local VM state\n", .{});
        std.debug.print("✓ No locks or synchronization needed for concurrent reads\n", .{});
        std.debug.print("✓ Multiple threads can match simultaneously\n", .{});
        std.debug.print("✓ SharedRegex provides reference counting for lifetime management\n", .{});
        std.debug.print("✓ RegexCache provides thread-local pattern caching\n", .{});

        std.debug.print("\nBest Practices:\n", .{});
        std.debug.print("• Compile patterns once, use from multiple threads\n", .{});
        std.debug.print("• Use thread-safe allocators for concurrent operations\n", .{});
        std.debug.print("• No mutex needed for read-only Regex access\n", .{});
        std.debug.print("• Avoid calling deinit() while other threads are using the Regex\n", .{});
        std.debug.print("\n", .{});
    }

    std.debug.print("=== All thread safety examples completed ===\n\n", .{});
}
