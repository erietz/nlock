//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

// Usage:
//
// nlock <name> --global -- command --with --args and positional arguments

pub const Options = struct {
    program: []const u8,
    name: []const u8,
    global: bool,
    command: []const [:0]const u8,

    pub fn parseArgs(init: std.process.Init) !Options {
        const args = try init.minimal.args.toSlice(init.arena.allocator());
        if (args.len < 2) {
            return error.InvalidArguments;
        }
        var options = Options{
            .program = args[0],
            .global = false,
            .name = "",
            .command = &.{},
        };

        var double_dash_index: usize = args.len; // Default to args.len if not found
        for (args[1..], 1..) |arg, i| {
            if (std.mem.eql(u8, arg, "--")) {
                double_dash_index = i;
                options.command = args[(i + 1)..];
                break;
            }
        }

        for (args[1..double_dash_index]) |arg| {
            if (std.mem.eql(u8, arg, "--global")) {
                options.global = true;
            } else if (options.name.len == 0) {
                options.name = arg;
            }
        }

        return options;
    }
};

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
