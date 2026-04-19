const std = @import("std");
const Regex = @import("regex").Regex;
const Profiler = @import("regex").Profiler;
const ScopedTimer = @import("regex").ScopedTimer;

pub fn main(init: std.process.Init) !void {
    std.debug.print("\n=== Regex Profiling Examples ===\n\n", .{});

    // Example 1: Basic profiling
    {
        std.debug.print("───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 1: Basic profiling\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        var profiler = Profiler.init(init.gpa, init.io, true);

        // Profile compilation
        profiler.startCompilation(init.io);
        var regex = try Regex.compile(init.gpa, "hello.*world");
        profiler.endCompilation(init.io);
        defer regex.deinit();

        // Profile multiple matches
        const test_inputs = [_][]const u8{
            "hello world",
            "hello beautiful world",
            "hello there world",
            "goodbye world",
        };

        for (test_inputs) |input| {
            profiler.startMatch(init.io);
            _ = try regex.isMatch(input);
            profiler.endMatch(init.io);
        }

        std.debug.print("\n", .{});
        profiler.printMetrics();
    }

    // Example 2: Scoped timers
    {
        std.debug.print("\n───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 2: Scoped timers\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        var profiler = Profiler.init(init.gpa, init.io, true);

        {
            var timer = ScopedTimer.init(&profiler, init.io, .compilation);
            defer timer.deinit(init.io);

            var regex = try Regex.compile(init.gpa, "[a-z]+@[a-z]+\\.[a-z]+");
            regex.deinit();
        }

        std.debug.print("\n", .{});
        profiler.printMetrics();
    }

    // Example 3: Comparing pattern performance
    {
        std.debug.print("\n───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 3: Pattern performance comparison\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        const patterns = [_][]const u8{
            "hello", // Literal - should have prefix optimization
            ".*hello", // No prefix - slower
            "hello.*world", // Prefix optimization
        };

        const test_text = ("some random text " ** 10) ++ "hello world";

        for (patterns) |pattern| {
            var profiler = Profiler.init(init.gpa, init.io, true);

            std.debug.print("\nPattern: \"{s}\"\n", .{pattern});

            var regex = try Regex.compile(init.gpa, pattern);
            defer regex.deinit();

            // Run multiple matches
            const iterations = 1000;
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                profiler.startMatch(init.io);
                _ = try regex.isMatch(test_text);
                profiler.endMatch(init.io);
            }

            const metrics = profiler.getMetrics();
            // TODO: figure out if this is correct
            const avg_ns = @divTrunc(metrics.match_time_ns, iterations);
            std.debug.print("Average match time: {d}μs ({d} iterations)\n", .{ @divTrunc(avg_ns, 1000), iterations });
        }
    }

    // Example 4: Memory tracking
    {
        std.debug.print("\n───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 4: Memory tracking\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        var profiler = Profiler.init(init.gpa, init.io, true);

        const complex_pattern = "(a|b)+c(d|e)*f";
        std.debug.print("Pattern: \"{s}\"\n", .{complex_pattern});

        var regex = try Regex.compile(init.gpa, complex_pattern);
        defer regex.deinit();

        // Simulate memory tracking (in real implementation, this would be integrated)
        profiler.recordAllocation(1024); // Simulated allocation
        profiler.recordStateCreation(10);

        std.debug.print("\n", .{});
        profiler.printMetrics();
    }

    // Example 5: Performance regression detection
    {
        std.debug.print("\n───────────────────────────────────────────────\n", .{});
        std.debug.print("Example 5: Performance regression detection\n", .{});
        std.debug.print("───────────────────────────────────────────────\n", .{});

        const baseline_pattern = "hello";
        const test_pattern = "hello";

        // Baseline
        var baseline_profiler = Profiler.init(init.gpa, init.io, true);
        {
            var regex = try Regex.compile(init.gpa, baseline_pattern);
            defer regex.deinit();

            var i: usize = 0;
            while (i < 100) : (i += 1) {
                baseline_profiler.startMatch(init.io);
                _ = try regex.isMatch("hello world");
                baseline_profiler.endMatch(init.io);
            }
        }

        // Test
        var test_profiler = Profiler.init(init.gpa, init.io, true);
        {
            var regex = try Regex.compile(init.gpa, test_pattern);
            defer regex.deinit();

            var i: usize = 0;
            while (i < 100) : (i += 1) {
                test_profiler.startMatch(init.io);
                _ = try regex.isMatch("hello world");
                test_profiler.endMatch(init.io);
            }
        }

        const baseline_time = baseline_profiler.getMetrics().match_time_ns;
        const test_time = test_profiler.getMetrics().match_time_ns;
        const diff_percent = @as(f64, @floatFromInt(test_time)) / @as(f64, @floatFromInt(baseline_time)) * 100.0 - 100.0;

        std.debug.print("\nBaseline time: {d}μs\n", .{@divTrunc(baseline_time, 1000)});
        std.debug.print("Test time: {d}μs\n", .{@divTrunc(test_time, 1000)});
        std.debug.print("Difference: {d:.1}%\n", .{diff_percent});

        if (diff_percent > 10.0) {
            std.debug.print("⚠️  Performance regression detected!\n", .{});
        } else {
            std.debug.print("✓ Performance within acceptable range\n", .{});
        }
    }

    std.debug.print("\n=== All profiling examples completed ===\n\n", .{});
}
