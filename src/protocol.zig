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
    ListLocks,
};

pub const LockRequest = struct {
    request_type: LockRequestType,
    name: []const u8,
    global: bool,
    command: []const u8,

    pub fn init(
        request_type: LockRequestType,
        name: []const u8,
        global: bool,
        command: []const u8,
    ) LockRequest {
        return LockRequest{
            .request_type = request_type,
            .name = name,
            .global = global,
            .command = command,
        };
    }

    /// Serializes the LockRequest to a JSON string.
    /// Allocates memory for the JSON string, which must be freed by the caller.
    pub fn toJson(
        self: LockRequest,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const json = try std.json.Stringify.valueAlloc(
            allocator,
            self,
            .{ .whitespace = .minified },
        );
        return json;
    }

    // TODO: Consider returning a LockRequest struct directly instead of a
    // Parsed(LockRequest) to simplify usage. Would require allocator.dupe of
    // the name and command fields but then the caller would have to free
    // those. Add a deinit method to LockRequest to free those fields?
    pub fn fromJson(
        bytes: []const u8,
        allocator: std.mem.Allocator,
    ) !std.json.Parsed(LockRequest) {
        const parsed = try std.json.parseFromSlice(
            LockRequest,
            allocator,
            bytes,
            .{},
        );
        return parsed;
    }
};

test "LockRequest.toJson serializes LockRequest correctly" {
    const allocator = std.testing.allocator;
    const request = LockRequest{
        .request_type = LockRequestType.AcquireLock,
        .name = "mylock",
        .global = true,
        .command = "echo Hello",
    };
    const expected = "{\"request_type\":\"AcquireLock\",\"name\":\"mylock\",\"global\":true,\"command\":\"echo Hello\"}";

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expectEqualStrings(expected, json);
}

test "LockRequest.fromJson deserializes JSON into LockRequest correctly" {
    const allocator = std.testing.allocator;
    const json = "{\"request_type\":\"AcquireLock\",\"name\":\"mylock\",\"global\":true,\"command\":\"echo Hello\"}";
    const expected = LockRequest{
        .request_type = LockRequestType.AcquireLock,
        .name = "mylock",
        .global = true,
        .command = "echo Hello",
    };

    const parsed = try LockRequest.fromJson(json, allocator);
    defer parsed.deinit();
    const request = parsed.value;

    try std.testing.expectEqual(request.request_type, expected.request_type);
    try std.testing.expectEqualStrings(request.name, expected.name);
    try std.testing.expectEqual(request.global, expected.global);
    try std.testing.expectEqualStrings(request.command, expected.command);
}

test "LockRequest.fromJson(LockRequest.toJson()) round-trip works correctly" {
    const allocator = std.testing.allocator;
    const original = LockRequest{
        .request_type = LockRequestType.AcquireLock,
        .name = "mylock",
        .global = true,
        .command = "echo Hello",
    };

    const json = try original.toJson(allocator);
    defer allocator.free(json);

    const parsed = try LockRequest.fromJson(json, allocator);
    defer parsed.deinit();
    const request = parsed.value;

    try std.testing.expectEqual(request.request_type, original.request_type);
    try std.testing.expectEqualStrings(request.name, original.name);
    try std.testing.expectEqual(request.global, original.global);
    try std.testing.expectEqualStrings(request.command, original.command);
}

test "LockRequest.fromJson correctly handles colon in command" {
    const allocator = std.testing.allocator;
    const json = "{\"request_type\":\"AcquireLock\",\"name\":\"mylock\",\"global\":true,\"command\":\"echo Hello:World\"}";
    const request = try LockRequest.fromJson(json, allocator);
    defer request.deinit();
    const lock_request = request.value;

    try std.testing.expectEqual(@intFromEnum(LockRequestType.AcquireLock), @intFromEnum(lock_request.request_type));
    try std.testing.expectEqualStrings("mylock", lock_request.name);
    try std.testing.expectEqual(true, lock_request.global);
    try std.testing.expectEqualStrings("echo Hello:World", lock_request.command);
}

test "LockRequest.fromJson correctly handles newline in command" {
    const allocator = std.testing.allocator;
    const json = "{\"request_type\":\"AcquireLock\",\"name\":\"mylock\",\"global\":true,\"command\":\"echo Hello\\nWorld\"}";
    const request = try LockRequest.fromJson(json, allocator);
    defer request.deinit();
    const lock_request = request.value;

    try std.testing.expectEqual(@intFromEnum(LockRequestType.AcquireLock), @intFromEnum(lock_request.request_type));
    try std.testing.expectEqualStrings("mylock", lock_request.name);
    try std.testing.expectEqual(true, lock_request.global);
    try std.testing.expectEqualStrings("echo Hello\nWorld", lock_request.command);
}

pub const LockResponse = struct {
    status: LockResponseStatus,

    pub fn init(status: LockResponseStatus) LockResponse {
        return LockResponse{
            .status = status,
        };
    }

    pub fn toJson(
        self: LockResponse,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const json = try std.json.Stringify.valueAlloc(
            allocator,
            self,
            .{ .whitespace = .minified },
        );
        return json;
    }

    /// Deserializes a JSON string into a LockResponse.
    /// Allocates memory for the LockResponse, which must be freed by the caller.
    pub fn fromJson(
        bytes: []const u8,
        allocator: std.mem.Allocator,
    ) !LockResponse {
        const parsed = try std.json.parseFromSlice(
            LockResponse,
            allocator,
            bytes,
            .{},
        );
        defer parsed.deinit();

        return .init(parsed.value.status);
    }
};

test "LockResponse.toJson serializes LockResponse correctly" {
    const allocator = std.testing.allocator;
    const response = LockResponse{
        .status = LockResponseStatus.Ok,
    };
    const expected = "{\"status\":\"Ok\"}";

    const json = try response.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expectEqualStrings(expected, json);
}

test "LockResponse.fromJson deserializes JSON into LockResponse correctly" {
    const allocator = std.testing.allocator;
    const json = "{\"status\":\"Ok\"}";
    const expected = LockResponse{
        .status = LockResponseStatus.Ok,
    };

    const response = try LockResponse.fromJson(json, allocator);

    try std.testing.expectEqual(response.status, expected.status);
}

test "LockResponse.fromJson(LockResponse.toJson()) round-trip works correctly" {
    const allocator = std.testing.allocator;
    const original = LockResponse{
        .status = LockResponseStatus.Ok,
    };

    const json = try original.toJson(allocator);
    defer allocator.free(json);

    const response = try LockResponse.fromJson(json, allocator);

    try std.testing.expectEqual(response.status, original.status);
}

pub fn writeLine(writer: *Io.Writer, message: []const u8) Io.Writer.Error!void {
    try writer.writeAll(message);
    try writer.writeAll("\n");
    try writer.flush();
}
