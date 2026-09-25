const std = @import("std");

pub const Command = union(enum) {
    run: RunOptions,
    list,

    pub fn parseArgs(args: []const [:0]const u8) !Command {
        if (args.len < 2) {
            return error.InvalidArguments; // No subcommand provided
        }

        const subcommand = args[1];
        const rest = args[2..];

        if (std.mem.eql(u8, subcommand, "run")) {
            return .{ .run = try RunOptions.parseArgs(rest) };
        } else if (std.mem.eql(u8, subcommand, "list")) {
            if (rest.len != 0) {
                return error.InvalidArguments; // list takes no arguments
            }
            return .list;
        }

        return error.InvalidArguments; // Unknown subcommand
    }
};

pub const RunOptions = struct {
    name: []const u8,
    global: bool,
    command: []const [:0]const u8,

    /// Parses the arguments following `run`: `<name> [--global] -- <command> [args...]`
    pub fn parseArgs(args: []const [:0]const u8) !RunOptions {
        var options = RunOptions{
            .global = false,
            .name = "",
            .command = &.{},
        };

        const double_dash_index = for (args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "--")) break i;
        } else {
            return error.InvalidArguments; // No "--" found in arguments
        };

        options.command = args[(double_dash_index + 1)..];
        if (options.command.len == 0) {
            return error.InvalidArguments; // No command provided after "--"
        }

        for (args[0..double_dash_index]) |arg| {
            if (std.mem.eql(u8, arg, "--global")) {
                options.global = true;
            } else if (options.name.len == 0) {
                options.name = arg;
            } else {
                return error.InvalidArguments; // Multiple names provided
            }
        }

        if (options.name.len == 0) {
            return error.InvalidArguments; // No name provided
        }

        return options;
    }
};

test "Command.parseArgs with empty arguments" {
    const args: []const [:0]const u8 = &.{};
    const result = Command.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Command.parseArgs with only program name" {
    const args: []const [:0]const u8 = &.{"nlock"};
    const result = Command.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Command.parseArgs with unknown subcommand" {
    const args: []const [:0]const u8 = &.{ "nlock", "doodoo" };
    const result = Command.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Command.parseArgs without subcommand" {
    const args: []const [:0]const u8 = &.{ "nlock", "mylock", "--", "echo", "Hello" };
    const result = Command.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Command.parseArgs list" {
    const args: []const [:0]const u8 = &.{ "nlock", "list" };
    const result = try Command.parseArgs(args);
    try std.testing.expect(result == .list);
}

test "Command.parseArgs list with extra arguments" {
    const args: []const [:0]const u8 = &.{ "nlock", "list", "mylock" };
    const result = Command.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Command.parseArgs run with name and command" {
    const args: []const [:0]const u8 = &.{ "nlock", "run", "mylock", "--", "echo", "Hello" };
    const result = try Command.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.run.name);
    try std.testing.expectEqual(false, result.run.global);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.run.command);
}

test "Command.parseArgs run with no arguments" {
    const args: []const [:0]const u8 = &.{ "nlock", "run" };
    const result = Command.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "Command.parseArgs run allows a lock named list" {
    const args: []const [:0]const u8 = &.{ "nlock", "run", "list", "--", "echo", "Hello" };
    const result = try Command.parseArgs(args);
    try std.testing.expectEqualStrings("list", result.run.name);
}

test "RunOptions.parseArgs with no arguments" {
    const args: []const [:0]const u8 = &.{};
    const result = RunOptions.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "RunOptions.parseArgs with name and command" {
    const args: []const [:0]const u8 = &.{ "mylock", "--", "echo", "Hello" };
    const result = try RunOptions.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(false, result.global);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "RunOptions.parseArgs with global flag" {
    const args: []const [:0]const u8 = &.{ "--global", "mylock", "--", "echo", "Hello" };
    const result = try RunOptions.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(true, result.global);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "RunOptions.parseArgs with flags after positional arguments" {
    const args: []const [:0]const u8 = &.{ "mylock", "--global", "--", "echo", "Hello" };
    const result = try RunOptions.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(true, result.global);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "RunOptions.parseArgs with missing command" {
    const args: []const [:0]const u8 = &.{ "mylock", "--" };
    const result = RunOptions.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "RunOptions.parseArgs with missing name" {
    const args: []const [:0]const u8 = &.{ "--global", "--", "echo", "Hello" };
    const result = RunOptions.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "RunOptions.parseArgs with no double dash" {
    const args: []const [:0]const u8 = &.{ "mylock", "echo", "Hello" };
    const result = RunOptions.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "RunOptions.parseArgs with multiple names" {
    const args: []const [:0]const u8 = &.{ "mylock", "anotherlock", "--", "echo", "Hello" };
    const result = RunOptions.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "RunOptions.parseArgs with only command" {
    const args: []const [:0]const u8 = &.{ "--", "echo", "Hello" };
    const result = RunOptions.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "RunOptions.parseArgs with only global flag" {
    const args: []const [:0]const u8 = &.{"--global"};
    const result = RunOptions.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "RunOptions.parseArgs with only name" {
    const args: []const [:0]const u8 = &.{"mylock"};
    const result = RunOptions.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}
