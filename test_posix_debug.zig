const std = @import("std");
const Regex = @import("regex").Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Compiling pattern: [[:alpha:]]+\n", .{});

    var regex = Regex.compile(allocator, "[[:alpha:]]+") catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return err;
    };
    defer regex.deinit();

    std.debug.print("Compiled successfully!\n", .{});

    const text = "hello123";
    const match = try regex.find(text);
    if (match) |m| {
        defer {
            var mut_m = m;
            mut_m.deinit(allocator);
        }
        std.debug.print("Match: {s}\n", .{m.slice});
    } else {
        std.debug.print("No match\n", .{});
    }
}
