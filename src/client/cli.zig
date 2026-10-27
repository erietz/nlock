const std = @import("std");
const protocol = @import("nlock").protocol;

const SYNOPSIS =
    \\Usage: nlock run [options] <name> -- <command> [args...]
    \\       nlock list [--json | -q] [-H]
    \\       nlock --help | --version
    \\
;

/// Printed to stderr when the arguments are invalid.
pub const USAGE = SYNOPSIS ++
    \\Try 'nlock --help' for more information.
    \\
;

/// Printed to stdout for `nlock --help`.
pub const HELP = SYNOPSIS ++
    \\
    \\Run a command while holding a named lock managed by nlockd.
    \\
    \\Run options:
    \\  -n, --nonblock        fail at once if the lock is held
    \\  -t, --timeout <secs>  wait at most <secs> seconds for the lock
    \\      --coalesce        exit 0 without running if a run is already pending
    \\      --replace         take the place of every client waiting for the lock
    \\      --slots <n>       let up to <n> clients hold the lock at once
    \\      --rate <n>/<per>  grant the lock at most <n> times per <per>,
    \\                        e.g. 30/m, 5000/h, 3/10s (units s, m, h, d)
    \\  -s, --shared         hold the lock alongside other shared holders
    \\  -x, --exclusive       hold the lock alone (the default)
    \\
    \\List options:
    \\      --json            print one JSON object per lock
    \\  -q, --quiet           print only lock names
    \\  -H, --no-header       omit the header row
    \\
    \\Other options:
    \\  -h, --help            show this help
    \\      --version         show the version
    \\
    \\See nlock(1) for details.
    \\
;

pub const UsageError = error{
    InvalidArguments,
};

pub const Command = union(enum) {
    run: RunOptions,
    list: ListOptions,
    help,
    version,

    pub fn parseArgs(args: []const [:0]const u8) UsageError!Command {
        if (args.len < 2) {
            return UsageError.InvalidArguments; // No subcommand provided
        }

        // --help or --version anywhere among nlock's own arguments wins over
        // everything else. Arguments after `--` belong to the command, so
        // `nlock run x -- grep -h` still runs grep.
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--")) break;
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return .{ .help = {} };
            }
            if (std.mem.eql(u8, arg, "--version")) {
                return .{ .version = {} };
            }
        }

        const subcommand = args[1];
        const rest = args[2..];

        if (std.mem.eql(u8, subcommand, "run")) {
            return .{ .run = try RunOptions.parseArgs(rest) };
        } else if (std.mem.eql(u8, subcommand, "list")) {
            return .{ .list = try ListOptions.parseArgs(rest) };
        }

        return UsageError.InvalidArguments; // Unknown subcommand
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

pub const RunOptions = struct {
    name: []const u8,
    command: []const [:0]const u8,
    nonblock: bool = false,
    timeout: ?u64 = null,
    coalesce: bool = false,
    replace: bool = false,
    /// How many clients may hold the lock at once.
    slots: u32 = 1,
    mode: protocol.Mode = .exclusive,
    rate: ?protocol.Rate = null,

    /// Parses the arguments following `run`: `[options] <name> -- <command> [args...]`
    pub fn parseArgs(args: []const [:0]const u8) !RunOptions {
        var options = RunOptions{
            .name = "",
            .command = &.{},
            .nonblock = false,
            .timeout = null,
            .coalesce = false,
            .replace = false,
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

        var shared = false;
        var exclusive = false;
        var skip_next = false;
        for (args[0..double_dash_index], 0..) |arg, i| {
            if (skip_next) {
                skip_next = false;
                continue;
            }

            if (std.mem.eql(u8, arg, "--nonblock") or std.mem.eql(u8, arg, "-n")) {
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
            } else if (std.mem.eql(u8, arg, "--slots")) {
                if (i + 1 >= double_dash_index) {
                    return error.InvalidArguments; // No value provided for --slots
                }
                options.slots = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                    return error.InvalidArguments; // Invalid integer for --slots
                };
                skip_next = true;
            } else if (std.mem.eql(u8, arg, "--rate")) {
                if (i + 1 >= double_dash_index) {
                    return error.InvalidArguments; // No value provided for --rate
                }
                options.rate = parseRate(args[i + 1]) orelse {
                    return error.InvalidArguments; // Not <n>/<per>, or out of range
                };
                skip_next = true;
            } else if (std.mem.eql(u8, arg, "--shared") or std.mem.eql(u8, arg, "-s")) {
                shared = true;
            } else if (std.mem.eql(u8, arg, "--exclusive") or std.mem.eql(u8, arg, "-x")) {
                exclusive = true;
            } else if (std.mem.eql(u8, arg, "--coalesce")) {
                options.coalesce = true;
            } else if (std.mem.eql(u8, arg, "--replace")) {
                options.replace = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return error.InvalidArguments; // Unknown option
            } else if (options.name.len == 0) {
                options.name = arg;
            } else {
                return error.InvalidArguments; // Multiple names provided
            }
        }

        if (!protocol.isValidLockName(options.name)) {
            return error.InvalidArguments; // No name, or name has whitespace or control characters
        }

        if (options.coalesce and options.replace) {
            return error.InvalidArguments; // Conflicting flags
        }

        if (shared and exclusive) {
            return error.InvalidArguments; // Conflicting flags
        }
        if (shared) options.mode = .shared;

        if (!protocol.isValidSlots(options.slots, options.mode)) {
            return error.InvalidArguments; // A lock nobody can hold, or a shared lock with several slots
        }

        return options;
    }
};

/// Parses a `--rate` value: `<n>/<per>`, where `<per>` is a unit (`s`, `m`
/// or `min`, `h`, `d`) optionally preceded by how many of it, e.g. `30/m`,
/// `3/10s`. Returns null if it is malformed or outside the allowed range.
fn parseRate(text: []const u8) ?protocol.Rate {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return null;
    const count = std.fmt.parseInt(u32, text[0..slash], 10) catch return null;

    const per = text[slash + 1 ..];
    const digits = for (per, 0..) |ch, i| {
        if (!std.ascii.isDigit(ch)) break i;
    } else per.len;
    const amount: u32 = if (digits == 0) 1 else std.fmt.parseInt(u32, per[0..digits], 10) catch return null;
    const unit = per[digits..];
    const unit_s: u32 = if (std.mem.eql(u8, unit, "s"))
        1
    else if (std.mem.eql(u8, unit, "m") or std.mem.eql(u8, unit, "min"))
        std.time.s_per_min
    else if (std.mem.eql(u8, unit, "h"))
        std.time.s_per_hour
    else if (std.mem.eql(u8, unit, "d"))
        std.time.s_per_day
    else
        return null;

    const period_s = std.math.mul(u32, amount, unit_s) catch return null;
    const rate: protocol.Rate = .{ .count = count, .period_s = period_s };
    return if (protocol.isValidRate(rate)) rate else null;
}

test "parseRate" {
    const cases = [_]struct { text: []const u8, count: u32, period_s: u32 }{
        .{ .text = "30/m", .count = 30, .period_s = 60 },
        .{ .text = "30/min", .count = 30, .period_s = 60 },
        .{ .text = "10/s", .count = 10, .period_s = 1 },
        .{ .text = "5000/h", .count = 5000, .period_s = 3600 },
        .{ .text = "1/d", .count = 1, .period_s = 86400 },
        .{ .text = "3/10s", .count = 3, .period_s = 10 },
        .{ .text = "100/15m", .count = 100, .period_s = 900 },
        .{ .text = "100/1h", .count = 100, .period_s = 3600 },
    };
    for (cases) |case| {
        const rate = parseRate(case.text) orelse return error.TestUnexpectedNull;
        try std.testing.expectEqual(case.count, rate.count);
        try std.testing.expectEqual(case.period_s, rate.period_s);
    }
}

test "parseRate rejects malformed and out-of-range rates" {
    for ([_][]const u8{
        "",       "30",      "/m",      "30/",     "30/x",       "30/ms",
        "30/m/s", "-1/m",    "x/m",     "30/-1m",  "30/1.5m",    "30/ m",
        "0/m",    "30/0s",   "10001/h", "1/2d",    "1/86401s",   "1/4294967296s",
        "1/99999999999d",
    }) |text| {
        if (parseRate(text)) |rate| {
            std.debug.print("accepted {s} as {d}/{d}s\n", .{ text, rate.count, rate.period_s });
            return error.TestExpectedNull;
        }
    }
}

test "RunOptions.parseArgs with rate" {
    const args: []const [:0]const u8 = &.{ "--rate", "30/m", "mylock", "--", "make" };
    const rate = (try RunOptions.parseArgs(args)).rate.?;
    try std.testing.expectEqual(30, rate.count);
    try std.testing.expectEqual(60, rate.period_s);

    const default: []const [:0]const u8 = &.{ "mylock", "--", "make" };
    try std.testing.expectEqual(null, (try RunOptions.parseArgs(default)).rate);

    for ([_][]const [:0]const u8{
        &.{ "mylock", "--rate", "--", "make" },
        &.{ "--rate", "0/m", "mylock", "--", "make" },
        &.{ "--rate", "fast", "mylock", "--", "make" },
    }) |bad| {
        try std.testing.expectError(error.InvalidArguments, RunOptions.parseArgs(bad));
    }
}

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

test "Command.parseArgs version" {
    const args: []const [:0]const u8 = &.{ "nlock", "--version" };
    const result = try Command.parseArgs(args);
    try std.testing.expectEqual(Command{ .version = {} }, result);
}

test "Command.parseArgs version with extra arguments" {
    const args: []const [:0]const u8 = &.{ "nlock", "--version", "extra" };
    const result = try Command.parseArgs(args);
    try std.testing.expectEqual(Command{ .version = {} }, result);
}

test "Command.parseArgs help" {
    for ([_][]const [:0]const u8{
        &.{ "nlock", "--help" },
        &.{ "nlock", "-h" },
        &.{ "nlock", "run", "-h" },
        &.{ "nlock", "list", "--json", "--help" },
        &.{ "nlock", "run", "mylock", "--help", "--", "echo" },
    }) |args| {
        try std.testing.expectEqual(Command{ .help = {} }, try Command.parseArgs(args));
    }
}

test "Command.parseArgs leaves --help and --version after -- to the command" {
    for ([_][:0]const u8{ "--help", "-h", "--version" }) |flag| {
        const args: []const [:0]const u8 = &.{ "nlock", "run", "mylock", "--", "grep", flag };
        const result = try Command.parseArgs(args);
        try std.testing.expectEqualStrings("mylock", result.run.name);
        try std.testing.expectEqual(2, result.run.command.len);
    }
}

test "Command.parseArgs version with run subcommand" {
    const args: []const [:0]const u8 = &.{ "nlock", "run", "--version" };
    const result = try Command.parseArgs(args);
    try std.testing.expectEqual(Command{ .version = {} }, result);
}

test "Command.parseArgs version with list subcommand" {
    const args: []const [:0]const u8 = &.{ "nlock", "list", "--version" };
    const result = try Command.parseArgs(args);
    try std.testing.expectEqual(Command{ .version = {} }, result);
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
    try std.testing.expectEqual(false, result.nonblock);
    try std.testing.expectEqual(null, result.timeout);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "RunOptions.parseArgs rejects unknown options rather than taking them as the name" {
    for ([_][:0]const u8{ "--wide", "-z" }) |flag| {
        const before: []const [:0]const u8 = &.{ flag, "--", "echo", "Hello" };
        try std.testing.expectError(error.InvalidArguments, RunOptions.parseArgs(before));
        const after: []const [:0]const u8 = &.{ "mylock", flag, "--", "echo", "Hello" };
        try std.testing.expectError(error.InvalidArguments, RunOptions.parseArgs(after));
    }
}

test "RunOptions.parseArgs with nonblock flag" {
    const args: []const [:0]const u8 = &.{ "--nonblock", "mylock", "--", "echo", "Hello" };
    const result = try RunOptions.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(true, result.nonblock);
    try std.testing.expectEqual(null, result.timeout);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "RunOptions.parseArgs with timeout flag" {
    const args: []const [:0]const u8 = &.{ "--timeout", "30", "mylock", "--", "echo", "Hello" };
    const result = try RunOptions.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(false, result.nonblock);
    try std.testing.expectEqual(30, result.timeout.?);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "RunOptions.parseArgs with coalesce flag" {
    const args: []const [:0]const u8 = &.{ "--coalesce", "mylock", "--", "echo", "Hello" };
    const result = try RunOptions.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(false, result.nonblock);
    try std.testing.expectEqual(null, result.timeout);
    try std.testing.expectEqual(true, result.coalesce);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "RunOptions.parseArgs with replace flag" {
    const args: []const [:0]const u8 = &.{ "--replace", "mylock", "--", "echo", "Hello" };
    const result = try RunOptions.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(false, result.nonblock);
    try std.testing.expectEqual(null, result.timeout);
    try std.testing.expectEqual(true, result.replace);
    const expected_command: []const [:0]const u8 = &.{ "echo", "Hello" };
    try std.testing.expectEqualDeep(expected_command, result.command);
}

test "RunOptions.parseArgs with slots" {
    const args: []const [:0]const u8 = &.{ "--slots", "4", "mylock", "--", "make" };
    const result = try RunOptions.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(4, result.slots);

    const default: []const [:0]const u8 = &.{ "mylock", "--", "make" };
    try std.testing.expectEqual(1, (try RunOptions.parseArgs(default)).slots);
}

test "RunOptions.parseArgs rejects missing, zero and invalid slots" {
    for ([_][]const [:0]const u8{
        &.{ "mylock", "--slots", "--", "make" },
        &.{ "--slots", "0", "mylock", "--", "make" },
        &.{ "--slots", "-1", "mylock", "--", "make" },
        &.{ "--slots", "two", "mylock", "--", "make" },
        &.{ "--slots", "4294967296", "mylock", "--", "make" },
    }) |args| {
        try std.testing.expectError(error.InvalidArguments, RunOptions.parseArgs(args));
    }
}

test "RunOptions.parseArgs with shared and exclusive flags" {
    for ([_]struct { args: []const [:0]const u8, mode: protocol.Mode }{
        .{ .args = &.{ "mylock", "--", "cat" }, .mode = .exclusive },
        .{ .args = &.{ "-s", "mylock", "--", "cat" }, .mode = .shared },
        .{ .args = &.{ "mylock", "--shared", "--", "cat" }, .mode = .shared },
        .{ .args = &.{ "-x", "mylock", "--", "cat" }, .mode = .exclusive },
        .{ .args = &.{ "--exclusive", "--slots", "4", "mylock", "--", "cat" }, .mode = .exclusive },
        .{ .args = &.{ "--shared", "--slots", "1", "mylock", "--", "cat" }, .mode = .shared },
    }) |case| {
        try std.testing.expectEqual(case.mode, (try RunOptions.parseArgs(case.args)).mode);
    }
}

test "RunOptions.parseArgs rejects --shared with --exclusive or several slots" {
    for ([_][]const [:0]const u8{
        &.{ "-s", "-x", "mylock", "--", "cat" },
        &.{ "--shared", "--slots", "2", "mylock", "--", "cat" },
    }) |args| {
        try std.testing.expectError(error.InvalidArguments, RunOptions.parseArgs(args));
    }
}

test "RunOptions.parseArgs with both coalesce and replace flags should error" {
    const args: []const [:0]const u8 = &.{ "--coalesce", "--replace", "mylock", "--", "echo", "Hello" };
    const result = RunOptions.parseArgs(args);
    try std.testing.expectError(error.InvalidArguments, result);
}

test "RunOptions.parseArgs with flags after positional arguments" {
    const args: []const [:0]const u8 = &.{ "mylock", "--nonblock", "--", "echo", "Hello" };
    const result = try RunOptions.parseArgs(args);
    try std.testing.expectEqualStrings("mylock", result.name);
    try std.testing.expectEqual(true, result.nonblock);
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
    const args: []const [:0]const u8 = &.{ "--nonblock", "--", "echo", "Hello" };
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

test "RunOptions.parseArgs with only nonblock flag" {
    const args: []const [:0]const u8 = &.{"--nonblock"};
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
