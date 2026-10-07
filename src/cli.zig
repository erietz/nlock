const std = @import("std");

pub const USAGE =
    \\Usage: nlock run <name> [--global] -- <command> [args...]
    \\       nlock list [--json | -q] [-H]
    \\
;

pub const Command = union(enum) {
    run: RunOptions,
    list: ListOptions,

    pub fn parseArgs(args: []const [:0]const u8) !Command {
        if (args.len < 2) {
            return error.InvalidArguments; // No subcommand provided
        }

        const subcommand = args[1];
        const rest = args[2..];

        if (std.mem.eql(u8, subcommand, "run")) {
            return .{ .run = try RunOptions.parseArgs(rest) };
        } else if (std.mem.eql(u8, subcommand, "list")) {
            return .{ .list = try ListOptions.parseArgs(rest) };
        }

        return error.InvalidArguments; // Unknown subcommand
    }
};

pub const ListOptions = struct {
    /// Print one JSON object per lock, one per line.
    json: bool = false,
    /// Print only lock names, one per line.
    quiet: bool = false,
    /// Print the column header row in the default table output.
    header: bool = true,

    /// Parses the arguments following `list`: `[--json | -q] [-H]`
    pub fn parseArgs(args: []const [:0]const u8) !ListOptions {
        var options = ListOptions{};
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--json")) {
                options.json = true;
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
                options.quiet = true;
            } else if (std.mem.eql(u8, arg, "--no-header") or std.mem.eql(u8, arg, "-H")) {
                options.header = false;
            } else {
                return error.InvalidArguments; // Unknown option or stray argument
            }
        }
        if (options.json and options.quiet) {
            return error.InvalidArguments; // Conflicting output formats
        }
        return options;
    }
};

/// Returns true if `name` can be used as a lock name. Whitespace and control
/// characters are rejected so names stay a single field in `nlock list`
/// output.
pub fn isValidLockName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (std.ascii.isWhitespace(ch) or std.ascii.isControl(ch)) return false;
    }
    return true;
}

pub const RunOptions = struct {
    name: []const u8,
    global: bool,
    command: []const [:0]const u8,
    nonblock: bool = false,
    timeout: ?u64 = null,

    /// Parses the arguments following `run`: `<name> [--global] -- <command> [args...]`
    pub fn parseArgs(args: []const [:0]const u8) !RunOptions {
        var options = RunOptions{
            .global = false,
            .name = "",
            .command = &.{},
            .nonblock = false,
            .timeout = null,
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

        var skip_next = false;
        for (args[0..double_dash_index], 0..) |arg, i| {
            if (skip_next) {
                skip_next = false;
                continue;
            }

            if (std.mem.eql(u8, arg, "--global") or std.mem.eql(u8, arg, "-g")) {
                options.global = true;
            } else if (std.mem.eql(u8, arg, "--nonblock") or std.mem.eql(u8, arg, "-n")) {
                options.nonblock = true;
            } else if (std.mem.eql(u8, arg, "--timeout") or std.mem.eql(u8, arg, "-t")) {
                if (i + 1 >= double_dash_index) {
                    return error.InvalidArguments; // No value provided for --timeout
                }
                const timeout_str = args[i + 1];
                const timeout_value = std.fmt.parseInt(u64, timeout_str, 10) catch {
                    return error.InvalidArguments; // Invalid integer for --timeout
                };
                options.timeout = timeout_value;
                skip_next = true; // Skip the next argument since it's the value for --timeout
            } else if (options.name.len == 0) {
                options.name = arg;
            } else {
                return error.InvalidArguments; // Multiple names provided
            }
        }

        if (!isValidLockName(options.name)) {
            return error.InvalidArguments; // No name, or name has whitespace or control characters
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
    try std.testing.expectEqual(ListOptions{}, result.list);
}

test "Command.parseArgs list with output options" {
    const args: []const [:0]const u8 = &.{ "nlock", "list", "--json", "-H" };
    const result = try Command.parseArgs(args);
    try std.testing.expectEqual(ListOptions{ .json = true, .header = false }, result.list);
}

test "ListOptions.parseArgs long and short flags" {
    const short: []const [:0]const u8 = &.{ "-q", "-H" };
    try std.testing.expectEqual(ListOptions{ .quiet = true, .header = false }, try ListOptions.parseArgs(short));
    const long: []const [:0]const u8 = &.{ "--quiet", "--no-header" };
    try std.testing.expectEqual(ListOptions{ .quiet = true, .header = false }, try ListOptions.parseArgs(long));
}

test "ListOptions.parseArgs rejects --json with --quiet" {
    const args: []const [:0]const u8 = &.{ "--json", "-q" };
    try std.testing.expectError(error.InvalidArguments, ListOptions.parseArgs(args));
}

test "ListOptions.parseArgs rejects unknown options" {
    const args: []const [:0]const u8 = &.{"--wide"};
    try std.testing.expectError(error.InvalidArguments, ListOptions.parseArgs(args));
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
    try std.testing.expectEqual(false, result.nonblock);
    try std.testing.expectEqual(null, result.timeout);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "RunOptions.parseArgs with global flag" {
    const args: []const [:0]const u8 = &.{ "--global", "mylock", "--", "echo", "Hello" };
    const result = try RunOptions.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(true, result.global);
    try std.testing.expectEqual(false, result.nonblock);
    try std.testing.expectEqual(null, result.timeout);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "RunOptions.parseArgs with nonblock flag" {
    const args: []const [:0]const u8 = &.{ "--nonblock", "mylock", "--", "echo", "Hello" };
    const result = try RunOptions.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(false, result.global);
    try std.testing.expectEqual(true, result.nonblock);
    try std.testing.expectEqual(null, result.timeout);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "RunOptions.parseArgs with timeout flag" {
    const args: []const [:0]const u8 = &.{ "--timeout", "30", "mylock", "--", "echo", "Hello" };
    const result = try RunOptions.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(false, result.global);
    try std.testing.expectEqual(false, result.nonblock);
    try std.testing.expectEqual(30, result.timeout.?);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "RunOptions.parseArgs with flags after positional arguments" {
    const args: []const [:0]const u8 = &.{ "mylock", "--global", "--", "echo", "Hello" };
    const result = try RunOptions.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(true, result.global);
    try std.testing.expectEqual(false, result.nonblock);
    try std.testing.expectEqual(null, result.timeout);
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

test "RunOptions.parseArgs rejects names with whitespace" {
    const args: []const [:0]const u8 = &.{ "my lock", "--", "echo", "Hello" };
    try std.testing.expectError(error.InvalidArguments, RunOptions.parseArgs(args));
}

test "RunOptions.parseArgs rejects names with control characters" {
    const args: []const [:0]const u8 = &.{ "my\x1block", "--", "echo", "Hello" };
    try std.testing.expectError(error.InvalidArguments, RunOptions.parseArgs(args));
}

test "isValidLockName" {
    try std.testing.expect(isValidLockName("build"));
    try std.testing.expect(isValidLockName("db-migrate.v2/prod"));
    try std.testing.expect(!isValidLockName(""));
    try std.testing.expect(!isValidLockName("a b"));
    try std.testing.expect(!isValidLockName("a\tb"));
    try std.testing.expect(!isValidLockName("a\nb"));
}
