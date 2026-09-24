//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub fn usage() []const u8 {
    return "Usage: nlock <name> [--global] -- <command> [args...]\n";
}

pub const Options = struct {
    program: []const u8,
    name: []const u8,
    global: bool,
    command: []const [:0]const u8,

    pub fn parseArgs(args: []const [:0]const u8) !Options {
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

        if (double_dash_index == args.len) {
            return error.InvalidArguments; // No "--" found in arguments
        }

        if (double_dash_index == args.len - 1) {
            return error.InvalidArguments; // No command provided after "--"
        }

        for (args[1..double_dash_index]) |arg| {
            if (std.mem.eql(u8, arg, "--global")) {
                options.global = true;
            } else if (options.name.len == 0) {
                options.name = arg;
            } else if (options.name.len != 0) {
                return error.InvalidArguments; // Multiple names provided
            }
        }

        if (options.name.len == 0) {
            return error.InvalidArguments; // No name provided
        }

        return options;
    }
};

test "Options.parseArgs no arguments" {
    const args: []const [:0]const u8 = &.{"nlock"};
    const result = Options.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Options.parseArgs with name and command" {
    const args: []const [:0]const u8 = &.{ "nlock", "mylock", "--", "echo", "Hello" };
    const result = try Options.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(false, result.global);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "Options.parseArgs with global flag" {
    const args: []const [:0]const u8 = &.{ "nlock", "--global", "mylock", "--", "echo", "Hello" };
    const result = try Options.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(true, result.global);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "Options.parseArgs with flags after positional arguments" {
    const args: []const [:0]const u8 = &.{ "nlock", "mylock", "--global", "--", "echo", "Hello" };
    const result = try Options.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(true, result.global);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "Options.parseArgs with missing command" {
    const args: []const [:0]const u8 = &.{ "nlock", "mylock", "--" };
    const result = Options.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Options.parseArgs with missing name" {
    const args: []const [:0]const u8 = &.{ "nlock", "--global", "--", "echo", "Hello" };
    const result = Options.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Options.parseArgs with no double dash" {
    const args: []const [:0]const u8 = &.{ "nlock", "mylock", "echo", "Hello" };
    const result = Options.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Options.parseArgs with multiple names" {
    const args: []const [:0]const u8 = &.{ "nlock", "mylock", "anotherlock", "--", "echo", "Hello" };
    const result = Options.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Options.parseArgs with only global flag" {
    const args: []const [:0]const u8 = &.{ "nlock", "--global", "--", "echo", "Hello" };
    const result = Options.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Options.parseArgs with only name" {
    const args: []const [:0]const u8 = &.{ "nlock", "mylock", "--" };
    const result = Options.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Options.parseArgs with only command" {
    const args: []const [:0]const u8 = &.{ "nlock", "--", "echo", "Hello" };
    const result = Options.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Options.parseArgs with empty arguments" {
    const args: []const [:0]const u8 = &.{};
    const result = Options.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Options.parseArgs with only program name" {
    const args: []const [:0]const u8 = &.{"nlock"};
    const result = Options.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Options.parseArgs with only program name and global flag" {
    const args: []const [:0]const u8 = &.{ "nlock", "--global" };
    const result = Options.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Options.parseArgs with only program name and name" {
    const args: []const [:0]const u8 = &.{ "nlock", "mylock" };
    const result = Options.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

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
