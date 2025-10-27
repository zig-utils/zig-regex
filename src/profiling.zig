const std = @import("std");

/// Performance profiling and metrics tracking for regex operations
pub const Profiler = struct {
    allocator: std.mem.Allocator,
    enabled: bool,
    metrics: Metrics,
    start_time: i64,

    pub const Metrics = struct {
        compilation_time_ns: u64 = 0,
        match_time_ns: u64 = 0,
        match_count: usize = 0,
        nfa_states_created: usize = 0,
        backtrack_count: usize = 0,
        optimization_hits: usize = 0,
        cache_hits: usize = 0,
        cache_misses: usize = 0,
        bytes_allocated: usize = 0,
        peak_memory: usize = 0,

        pub fn reset(self: *Metrics) void {
            self.* = Metrics{};
        }

        pub fn format(
            self: Metrics,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            try writer.writeAll("\n=== Regex Performance Metrics ===\n");
            try writer.print("Compilation time: {d}μs\n", .{self.compilation_time_ns / 1000});
            try writer.print("Match time: {d}μs\n", .{self.match_time_ns / 1000});
            try writer.print("Match count: {d}\n", .{self.match_count});
            try writer.print("NFA states: {d}\n", .{self.nfa_states_created});
            try writer.print("Backtrack count: {d}\n", .{self.backtrack_count});
            try writer.print("Optimization hits: {d}\n", .{self.optimization_hits});
            if (self.cache_hits + self.cache_misses > 0) {
                const hit_rate = @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(self.cache_hits + self.cache_misses)) * 100.0;
                try writer.print("Cache hit rate: {d:.1}%\n", .{hit_rate});
            }
            try writer.print("Memory allocated: {d} bytes\n", .{self.bytes_allocated});
            try writer.print("Peak memory: {d} bytes\n", .{self.peak_memory});
            try writer.writeAll("================================\n");
        }
    };

    pub fn init(allocator: std.mem.Allocator, enabled: bool) Profiler {
        const now: i64 = if (enabled) @intCast(std.time.nanoTimestamp()) else 0;
        return .{
            .allocator = allocator,
            .enabled = enabled,
            .metrics = Metrics{},
            .start_time = now,
        };
    }

    /// Start timing a compilation phase
    pub fn startCompilation(self: *Profiler) void {
        if (!self.enabled) return;
        self.start_time = @intCast(std.time.nanoTimestamp());
    }

    /// End timing a compilation phase
    pub fn endCompilation(self: *Profiler) void {
        if (!self.enabled) return;
        const now: i64 = @intCast(std.time.nanoTimestamp());
        const elapsed = @as(u64, @intCast(now - self.start_time));
        self.metrics.compilation_time_ns += elapsed;
    }

    /// Start timing a match operation
    pub fn startMatch(self: *Profiler) void {
        if (!self.enabled) return;
        self.start_time = @intCast(std.time.nanoTimestamp());
    }

    /// End timing a match operation
    pub fn endMatch(self: *Profiler) void {
        if (!self.enabled) return;
        const now: i64 = @intCast(std.time.nanoTimestamp());
        const elapsed = @as(u64, @intCast(now - self.start_time));
        self.metrics.match_time_ns += elapsed;
        self.metrics.match_count += 1;
    }

    /// Record NFA state creation
    pub fn recordStateCreation(self: *Profiler, count: usize) void {
        if (!self.enabled) return;
        self.metrics.nfa_states_created += count;
    }

    /// Record backtracking
    pub fn recordBacktrack(self: *Profiler) void {
        if (!self.enabled) return;
        self.metrics.backtrack_count += 1;
    }

    /// Record optimization hit (e.g., prefix match)
    pub fn recordOptimizationHit(self: *Profiler) void {
        if (!self.enabled) return;
        self.metrics.optimization_hits += 1;
    }

    /// Record cache hit
    pub fn recordCacheHit(self: *Profiler) void {
        if (!self.enabled) return;
        self.metrics.cache_hits += 1;
    }

    /// Record cache miss
    pub fn recordCacheMiss(self: *Profiler) void {
        if (!self.enabled) return;
        self.metrics.cache_misses += 1;
    }

    /// Record memory allocation
    pub fn recordAllocation(self: *Profiler, bytes: usize) void {
        if (!self.enabled) return;
        self.metrics.bytes_allocated += bytes;
        if (self.metrics.bytes_allocated > self.metrics.peak_memory) {
            self.metrics.peak_memory = self.metrics.bytes_allocated;
        }
    }

    /// Record memory deallocation
    pub fn recordDeallocation(self: *Profiler, bytes: usize) void {
        if (!self.enabled) return;
        if (bytes <= self.metrics.bytes_allocated) {
            self.metrics.bytes_allocated -= bytes;
        }
    }

    /// Get current metrics
    pub fn getMetrics(self: *const Profiler) Metrics {
        return self.metrics;
    }

    /// Reset all metrics
    pub fn reset(self: *Profiler) void {
        self.metrics.reset();
        const now: i64 = if (self.enabled) @intCast(std.time.nanoTimestamp()) else 0;
        self.start_time = now;
    }

    /// Print metrics to stderr
    pub fn printMetrics(self: *const Profiler) void {
        if (!self.enabled) return;
        std.debug.print("{any}", .{self.metrics});
    }
};

/// Scoped timer for automatic profiling
pub const ScopedTimer = struct {
    profiler: *Profiler,
    timer_type: TimerType,
    start: i64,

    pub const TimerType = enum {
        compilation,
        match,
    };

    pub fn init(profiler: *Profiler, timer_type: TimerType) ScopedTimer {
        const now: i64 = if (profiler.enabled) @intCast(std.time.nanoTimestamp()) else 0;
        return .{
            .profiler = profiler,
            .timer_type = timer_type,
            .start = now,
        };
    }

    pub fn deinit(self: *ScopedTimer) void {
        if (!self.profiler.enabled) return;
        const now: i64 = @intCast(std.time.nanoTimestamp());
        const elapsed = @as(u64, @intCast(now - self.start));
        switch (self.timer_type) {
            .compilation => self.profiler.metrics.compilation_time_ns += elapsed,
            .match => {
                self.profiler.metrics.match_time_ns += elapsed;
                self.profiler.metrics.match_count += 1;
            },
        }
    }
};

test "profiler basic operations" {
    const allocator = std.testing.allocator;
    var profiler = Profiler.init(allocator, true);

    profiler.startCompilation();
    // Do some work (just loop to consume time)
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = i * i;
    }
    profiler.endCompilation();

    profiler.recordStateCreation(5);
    profiler.recordBacktrack();
    profiler.recordOptimizationHit();

    const metrics = profiler.getMetrics();
    try std.testing.expectEqual(@as(usize, 5), metrics.nfa_states_created);
    try std.testing.expectEqual(@as(usize, 1), metrics.backtrack_count);
    try std.testing.expectEqual(@as(usize, 1), metrics.optimization_hits);
}

test "scoped timer" {
    const allocator = std.testing.allocator;
    var profiler = Profiler.init(allocator, true);

    {
        var timer = ScopedTimer.init(&profiler, .match);
        defer timer.deinit();
        // Do some work
        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            _ = i * i;
        }
    }

    const metrics = profiler.getMetrics();
    try std.testing.expectEqual(@as(usize, 1), metrics.match_count);
}
