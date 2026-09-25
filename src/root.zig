//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const SOCKET_PATH = "/tmp/nlock.sock";

pub fn usage() []const u8 {
    return "Usage: nlock <name> [--global] -- <command> [args...]\n";
}

test "usage function returns correct usage string" {
    const expected = "Usage: nlock <name> [--global] -- <command> [args...]\n";
    try std.testing.expectEqualStrings(expected, usage());
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

pub const LockResponseStatus = enum {
    Ok,
    Busy,
    Timeout,
};

pub const LockRequestType = enum {
    AcquireLock,
    ReleaseLock,
};

pub const LockRequest = struct {
    request_type: LockRequestType,
    name: []const u8,
    global: bool,
    command: []const u8,

    pub fn init(request_type: LockRequestType, name: []const u8, global: bool, command: []const u8) LockRequest {
        return LockRequest{
            .request_type = request_type,
            .name = name,
            .global = global,
            .command = command,
        };
    }

    pub fn toString(self: LockRequest) []const u8 {
        return std.fmt.allocPrint(
            std.heap.page_allocator,
            "{d}:{s}:{}:{s}",
            .{
                @intFromEnum(self.request_type),
                self.name,
                self.global,
                self.command,
            },
        ) catch unreachable;
    }

    pub fn fromString(bytes: []const u8) !LockRequest {
        if (bytes.len == 0) {
            return error.InvalidRequestFormat;
        }

        var lock_request = LockRequest{
            .request_type = LockRequestType.AcquireLock,
            .name = "",
            .global = false,
            .command = "",
        };

        var parts = std.mem.splitScalar(u8, bytes, ':');
        var i: usize = 0;
        while (parts.next()) |part| {
            if (i == 0) {
                const request_type = switch (try std.fmt.parseInt(u8, part, 10)) {
                    0 => LockRequestType.AcquireLock,
                    1 => LockRequestType.ReleaseLock,
                    else => return error.InvalidRequestType,
                };
                lock_request.request_type = request_type;
            } else if (i == 1) {
                lock_request.name = part;
            } else if (i == 2) {
                if (std.mem.eql(u8, part, "true")) {
                    lock_request.global = true;
                } else if (std.mem.eql(u8, part, "false")) {
                    lock_request.global = false;
                } else {
                    return error.InvalidGlobalFlag;
                }
            } else if (i == 3) {
                lock_request.command = part;
            } else {
                return error.InvalidRequestFormat;
            }

            i += 1;
        }

        return lock_request;
    }
};

test "lockRequestToBytes serializes LockRequest correctly" {
    const request = LockRequest{
        .request_type = LockRequestType.AcquireLock,
        .name = "mylock",
        .global = true,
    };
    const bytes = request.toString();
    try std.testing.expectEqualStrings("0:mylock:true", bytes);
}

test "lockRequestToBytes serializes LockRequest with ReleaseLock correctly" {
    const request = LockRequest{
        .request_type = LockRequestType.ReleaseLock,
        .name = "mylock",
        .global = false,
    };
    const bytes = request.toString();
    try std.testing.expectEqualStrings("1:mylock:false", bytes);
}

test "bytesToLockRequest deserializes bytes into LockRequest correctly" {
    const bytes = "0:mylock:true";
    const request = try LockRequest.fromString(bytes);
    try std.testing.expectEqual(@intFromEnum(LockRequestType.AcquireLock), @intFromEnum(request.request_type));
    try std.testing.expectEqualStrings("mylock", request.name);
    try std.testing.expectEqual(true, request.global);
}

test "bytesToLockRequest deserializes bytes into LockRequest with ReleaseLock correctly" {
    const bytes = "1:mylock:false";
    const request = try LockRequest.fromString(bytes);
    try std.testing.expectEqual(@intFromEnum(LockRequestType.ReleaseLock), @intFromEnum(request.request_type));
    try std.testing.expectEqualStrings("mylock", request.name);
    try std.testing.expectEqual(false, request.global);
}

pub const LockResponse = struct {
    status: LockResponseStatus,

    pub fn init(status: LockResponseStatus) LockResponse {
        return LockResponse{
            .status = status,
        };
    }

    pub fn toString(self: LockResponse) []const u8 {
        return std.fmt.allocPrint(
            std.heap.page_allocator,
            "{d}",
            .{@intFromEnum(self.status)},
        ) catch unreachable;
    }

    pub fn fromString(bytes: []const u8) !LockResponse {
        const status = switch (try std.fmt.parseInt(u8, bytes, 10)) {
            0 => LockResponseStatus.Ok,
            1 => LockResponseStatus.Busy,
            2 => LockResponseStatus.Timeout,
            else => return error.InvalidResponseStatus,
        };
        return LockResponse{
            .status = status,
        };
    }
};

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn writeLine(writer: *Io.Writer, message: []const u8) Io.Writer.Error!void {
    try writer.writeAll(message);
    try writer.writeAll("\n");
    try writer.flush();
}
