const std = @import("std");

/// Thread safety documentation and guarantees for the regex library.
///
/// # Thread Safety Overview
///
/// This regex library provides the following thread safety guarantees:
///
/// ## Compiled Regex Patterns (Regex struct)
///
/// - **Thread-safe for concurrent reads**: Once a `Regex` is compiled, it can be safely
///   shared and used concurrently by multiple threads for matching operations.
/// - **Immutable after compilation**: The `Regex` struct and its underlying NFA are
///   immutable after `compile()` returns, making them inherently thread-safe.
/// - **No internal synchronization needed**: Since the compiled pattern is read-only,
///   no locks or atomic operations are required.
///
/// ## Matching Operations
///
/// - **Thread-local VM state**: Each call to `isMatch()`, `find()`, or `findAll()`
///   creates a new VM instance with its own thread-local state.
/// - **No shared mutable state**: The VM allocates its own temporary data structures
///   (thread lists, capture buffers) which are not shared between threads.
/// - **Safe concurrent matching**: Multiple threads can call match operations on the
///   same `Regex` instance simultaneously without any synchronization.
///
/// ## Memory Management
///
/// - **Allocator thread safety**: Users must ensure their allocator is thread-safe
///   if using the same allocator across multiple threads. For concurrent usage,
///   consider using thread-local allocators or a thread-safe allocator like
///   `std.heap.ThreadSafeAllocator`.
/// - **No internal caching**: The library does not maintain any match result caches
///   or memoization that would require synchronization.
///
/// ## Example Usage
///
/// ```zig
/// const std = @import("std");
/// const Regex = @import("regex").Regex;
///
/// // Compile once, use from multiple threads
/// var gpa = std.heap.GeneralPurposeAllocator(.{}){};
/// const allocator = gpa.allocator();
///
/// const regex = try Regex.compile(allocator, "\\d+");
/// defer regex.deinit();
///
/// // Thread 1
/// const match1 = try regex.find("abc123"); // Safe
///
/// // Thread 2 (concurrent with Thread 1)
/// const match2 = try regex.find("xyz789"); // Safe
/// ```
///
/// ## Best Practices
///
/// 1. **Compile once, match many**: Compile regex patterns once and reuse them
///    across threads for best performance.
/// 2. **Use thread-safe allocators**: When matching from multiple threads, use
///    a thread-safe allocator or give each thread its own allocator.
/// 3. **No mutex needed**: You do not need to protect `Regex` instances with
///    mutexes for concurrent read access.
/// 4. **Avoid deinit during use**: Do not call `deinit()` on a `Regex` while
///    other threads may be using it. Ensure all matching operations complete
///    before cleanup.
///
/// ## Thread Safety Guarantees Summary
///
/// | Operation | Thread Safety | Notes |
/// |-----------|---------------|-------|
/// | `Regex.compile()` | Not thread-safe | Creates new instance |
/// | `regex.deinit()` | Not thread-safe | Mutates and frees |
/// | `regex.isMatch()` | Thread-safe | Read-only, thread-local VM |
/// | `regex.find()` | Thread-safe | Read-only, thread-local VM |
/// | `regex.findAll()` | Thread-safe | Read-only, thread-local VM |
/// | `regex.replace()` | Thread-safe | Read-only regex, new output |
/// | `regex.replaceAll()` | Thread-safe | Read-only regex, new output |
///
pub const ThreadSafety = struct {
    // Marker to indicate this module is for documentation only
};

/// Thread-safe wrapper for regex patterns with reference counting.
///
/// This wrapper provides automatic lifetime management for regex patterns
/// that are shared across threads. It uses atomic reference counting to
/// ensure the pattern is only freed when all threads are done using it.
///
/// Example:
/// ```zig
/// var shared_regex = try SharedRegex.init(allocator, "\\d+");
/// defer shared_regex.deinit();
///
/// // Thread 1
/// {
///     var ref = shared_regex.acquire();
///     defer ref.release();
///     const match = try ref.regex.find("123");
/// }
///
/// // Thread 2
/// {
///     var ref = shared_regex.acquire();
///     defer ref.release();
///     const match = try ref.regex.find("456");
/// }
/// ```
pub fn SharedRegex(comptime Regex: type) type {
    return struct {
        const Self = @This();

        regex: Regex,
        ref_count: std.atomic.Value(usize),
        allocator: std.mem.Allocator,

        /// Initialize a shared regex pattern
        pub fn init(allocator: std.mem.Allocator, pattern: []const u8) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .regex = try Regex.compile(allocator, pattern),
                .ref_count = std.atomic.Value(usize).init(1),
                .allocator = allocator,
            };

            return self;
        }

        /// Acquire a reference to the regex (increments ref count)
        pub fn acquire(self: *Self) Reference {
            _ = self.ref_count.fetchAdd(1, .monotonic);
            return Reference{ .shared = self };
        }

        /// Release the initial reference and free if no other references exist
        pub fn deinit(self: *Self) void {
            const prev = self.ref_count.fetchSub(1, .acq_rel);
            if (prev == 1) {
                // Last reference, safe to free
                var mut_regex = self.regex;
                mut_regex.deinit();
                const allocator = self.allocator;
                allocator.destroy(self);
            }
        }

        /// A reference to a shared regex
        pub const Reference = struct {
            shared: *Self,

            /// Access the underlying regex (safe to call from multiple threads)
            pub fn regex(self: Reference) *const Regex {
                return &self.shared.regex;
            }

            /// Release this reference
            pub fn release(self: Reference) void {
                const prev = self.shared.ref_count.fetchSub(1, .acq_rel);
                if (prev == 1) {
                    // Last reference, safe to free
                    var mut_regex = self.shared.regex;
                    mut_regex.deinit();
                    const allocator = self.shared.allocator;
                    allocator.destroy(self.shared);
                }
            }
        };
    };
}

/// Thread-local regex cache for efficient pattern reuse within a single thread.
///
/// This cache maintains compiled regex patterns in thread-local storage,
/// avoiding recompilation overhead. Each thread gets its own cache.
///
/// Example:
/// ```zig
/// threadlocal var regex_cache: RegexCache = undefined;
///
/// pub fn processText(text: []const u8) !void {
///     if (!regex_cache.initialized) {
///         regex_cache = try RegexCache.init(allocator);
///     }
///     defer if (regex_cache.initialized) regex_cache.deinit();
///
///     const regex = try regex_cache.get("\\d+");
///     const match = try regex.find(text);
/// }
/// ```
pub fn RegexCache(comptime Regex: type) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            pattern: []const u8,
            regex: Regex,
        };

        cache: std.StringHashMap(Regex),
        allocator: std.mem.Allocator,
        initialized: bool = false,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .cache = std.StringHashMap(Regex).init(allocator),
                .allocator = allocator,
                .initialized = true,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.cache.iterator();
            while (it.next()) |entry| {
                var regex = entry.value_ptr.*;
                regex.deinit();
                self.allocator.free(entry.key_ptr.*);
            }
            self.cache.deinit();
            self.initialized = false;
        }

        /// Get a compiled regex from cache, or compile and cache it
        pub fn get(self: *Self, pattern: []const u8) !*const Regex {
            // Check if in cache
            const entry = self.cache.getPtr(pattern);
            if (entry) |regex_ptr| {
                return regex_ptr;
            }

            // Not in cache, compile and store
            const regex = try Regex.compile(self.allocator, pattern);
            errdefer {
                var mut_regex = regex;
                mut_regex.deinit();
            }

            const owned_pattern = try self.allocator.dupe(u8, pattern);
            errdefer self.allocator.free(owned_pattern);

            try self.cache.put(owned_pattern, regex);

            // Return pointer to cached entry
            return self.cache.getPtr(owned_pattern).?;
        }

        /// Clear all cached patterns
        pub fn clear(self: *Self) void {
            var it = self.cache.iterator();
            while (it.next()) |entry| {
                var regex = entry.value_ptr.*;
                regex.deinit();
                self.allocator.free(entry.key_ptr.*);
            }
            self.cache.clearRetainingCapacity();
        }
    };
}

test "thread safety documentation" {
    // This test exists to ensure the module compiles
    // The actual thread safety is guaranteed by the design
    const testing = std.testing;
    _ = testing;
}
