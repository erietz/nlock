const std = @import("std");
const Io = std.Io;

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
        .command = "echo Hello",
    };
    const bytes = request.toString();
    try std.testing.expectEqualStrings("0:mylock:true:echo Hello", bytes);
}

test "lockRequestToBytes serializes LockRequest with ReleaseLock correctly" {
    const request = LockRequest{
        .request_type = LockRequestType.ReleaseLock,
        .name = "mylock",
        .global = false,
        .command = "echo Hello",
    };
    const bytes = request.toString();
    try std.testing.expectEqualStrings("1:mylock:false:echo Hello", bytes);
}

test "bytesToLockRequest deserializes bytes into LockRequest correctly" {
    const bytes = "0:mylock:true:echo Hello";
    const request = try LockRequest.fromString(bytes);
    try std.testing.expectEqual(@intFromEnum(LockRequestType.AcquireLock), @intFromEnum(request.request_type));
    try std.testing.expectEqualStrings("mylock", request.name);
    try std.testing.expectEqual(true, request.global);
    try std.testing.expectEqualStrings("echo Hello", request.command);
}

test "bytesToLockRequest deserializes bytes into LockRequest with ReleaseLock correctly" {
    const bytes = "1:mylock:false:echo Hello";
    const request = try LockRequest.fromString(bytes);
    try std.testing.expectEqual(@intFromEnum(LockRequestType.ReleaseLock), @intFromEnum(request.request_type));
    try std.testing.expectEqualStrings("mylock", request.name);
    try std.testing.expectEqual(false, request.global);
    try std.testing.expectEqualStrings("echo Hello", request.command);
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

pub fn writeLine(writer: *Io.Writer, message: []const u8) Io.Writer.Error!void {
    try writer.writeAll(message);
    try writer.writeAll("\n");
    try writer.flush();
}
