const std = @import("std");
const Io = std.Io;

pub const LockResponseStatus = enum {
    Ok,
    Busy,
    Timeout,
    /// The lock is held by someone else and the request was queued. Sent
    /// before the client starts waiting, followed later by `Ok` or `Timeout`.
    Queued,
};

pub const LockRequestType = enum {
    AcquireLock,
    ReleaseLock,
    ListLocks,
};

/// Options for parsing every protocol message.
const parse_options: std.json.ParseOptions = .{
    // Copy strings rather than pointing into the input, which is usually a
    // reader's buffer that is overwritten by the next message.
    .allocate = .alloc_always,
    // A client and daemon of different versions should fail loudly rather
    // than silently drop what the other side sent.
    .ignore_unknown_fields = false,
};

pub const LockRequest = struct {
    request_type: LockRequestType,
    name: []const u8,
    global: bool,
    nonblock: bool,
    timeout: ?u64,
    command: []const u8,

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

    /// Deserializes a JSON string into a LockRequest. The result owns its
    /// memory, which must be freed by the caller with `deinit`.
    pub fn fromJson(
        bytes: []const u8,
        allocator: std.mem.Allocator,
    ) !std.json.Parsed(LockRequest) {
        return std.json.parseFromSlice(LockRequest, allocator, bytes, parse_options);
    }
};

test "LockRequest.toJson serializes LockRequest correctly" {
    const allocator = std.testing.allocator;
    const request = LockRequest{
        .request_type = LockRequestType.AcquireLock,
        .name = "mylock",
        .global = true,
        .nonblock = false,
        .timeout = null,
        .command = "echo Hello",
    };
    const expected = "{\"request_type\":\"AcquireLock\",\"name\":\"mylock\",\"global\":true,\"nonblock\":false,\"timeout\":null,\"command\":\"echo Hello\"}";

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expectEqualStrings(expected, json);
}

test "LockRequest.fromJson deserializes JSON into LockRequest correctly" {
    const allocator = std.testing.allocator;
    const json = "{\"request_type\":\"AcquireLock\",\"name\":\"mylock\",\"global\":true,\"nonblock\":false,\"timeout\":null,\"command\":\"echo Hello\"}";
    const expected = LockRequest{
        .request_type = LockRequestType.AcquireLock,
        .name = "mylock",
        .global = true,
        .nonblock = false,
        .timeout = null,
        .command = "echo Hello",
    };

    const request_parsed = try LockRequest.fromJson(json, allocator);
    defer request_parsed.deinit();
    const request = request_parsed.value;

    try std.testing.expectEqual(request.request_type, expected.request_type);
    try std.testing.expectEqualStrings(request.name, expected.name);
    try std.testing.expectEqual(request.global, expected.global);
    try std.testing.expectEqual(request.nonblock, expected.nonblock);
    try std.testing.expectEqual(request.timeout, expected.timeout);
    try std.testing.expectEqualStrings(request.command, expected.command);
}

test "LockRequest.fromJson(LockRequest.toJson()) round-trip works correctly" {
    const allocator = std.testing.allocator;
    const original = LockRequest{
        .request_type = LockRequestType.AcquireLock,
        .name = "mylock",
        .global = true,
        .nonblock = false,
        .timeout = 30,
        .command = "echo Hello",
    };

    const json = try original.toJson(allocator);
    defer allocator.free(json);

    const request_parsed = try LockRequest.fromJson(json, allocator);
    defer request_parsed.deinit();
    const request = request_parsed.value;

    try std.testing.expectEqual(request.request_type, original.request_type);
    try std.testing.expectEqualStrings(request.name, original.name);
    try std.testing.expectEqual(request.global, original.global);
    try std.testing.expectEqual(request.nonblock, original.nonblock);
    try std.testing.expectEqual(request.timeout, original.timeout);
    try std.testing.expectEqualStrings(request.command, original.command);
}

test "LockRequest.fromJson correctly handles colon in command" {
    const allocator = std.testing.allocator;
    const json = "{\"request_type\":\"AcquireLock\",\"name\":\"mylock\",\"global\":true,\"nonblock\":false,\"timeout\":30,\"command\":\"echo Hello:World\"}";
    const lock_request_parsed = try LockRequest.fromJson(json, allocator);
    defer lock_request_parsed.deinit();
    const lock_request = lock_request_parsed.value;

    try std.testing.expectEqual(@intFromEnum(LockRequestType.AcquireLock), @intFromEnum(lock_request.request_type));
    try std.testing.expectEqualStrings("mylock", lock_request.name);
    try std.testing.expectEqual(true, lock_request.global);
    try std.testing.expectEqual(false, lock_request.nonblock);
    try std.testing.expectEqual(30, lock_request.timeout.?);
    try std.testing.expectEqualStrings("echo Hello:World", lock_request.command);
}

test "LockRequest.fromJson correctly handles newline in command" {
    const allocator = std.testing.allocator;
    const json = "{\"request_type\":\"AcquireLock\",\"name\":\"mylock\",\"global\":true,\"nonblock\":false,\"timeout\":null,\"command\":\"echo Hello\\nWorld\"}";
    const lock_request_parsed = try LockRequest.fromJson(json, allocator);
    defer lock_request_parsed.deinit();
    const lock_request = lock_request_parsed.value;

    try std.testing.expectEqual(@intFromEnum(LockRequestType.AcquireLock), @intFromEnum(lock_request.request_type));
    try std.testing.expectEqualStrings("mylock", lock_request.name);
    try std.testing.expectEqual(true, lock_request.global);
    try std.testing.expectEqual(false, lock_request.nonblock);
    try std.testing.expectEqual(null, lock_request.timeout);
    try std.testing.expectEqualStrings("echo Hello\nWorld", lock_request.command);
}

test "LockRequest.fromJson rejects unknown fields" {
    // A client and daemon of different versions should fail loudly.
    const json = "{\"request_type\":\"AcquireLock\",\"name\":\"mylock\",\"global\":true,\"nonblock\":false,\"timeout\":null,\"command\":\"echo Hello\",\"from_the_future\":true}";
    try std.testing.expectError(error.UnknownField, LockRequest.fromJson(json, std.testing.allocator));
}

/// One row of the `list` response: a lock currently held, and who holds it.
pub const LockInfo = struct {
    name: []const u8,
    uid: u32,
    /// Pid of the `nlock` client holding the lock, or 0 if unknown.
    pid: i32,
    global: bool,
    /// Number of clients queued for the lock.
    waiters: usize,
    /// When the current holder acquired the lock, in seconds since the Unix
    /// epoch.
    acquired_at: i64,
    command: []const u8,

    /// Serializes the LockInfo to a JSON string.
    /// Allocates memory for the JSON string, which must be freed by the caller.
    pub fn toJson(
        self: LockInfo,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return std.json.Stringify.valueAlloc(
            allocator,
            self,
            .{ .whitespace = .minified },
        );
    }

    /// Deserializes a JSON string into a LockInfo. The result owns its
    /// memory, which must be freed by the caller with `deinit`.
    pub fn fromJson(
        bytes: []const u8,
        allocator: std.mem.Allocator,
    ) !std.json.Parsed(LockInfo) {
        return std.json.parseFromSlice(LockInfo, allocator, bytes, parse_options);
    }

    /// Like `fromJson`, but allocates directly from `arena` and is freed
    /// along with it. Leaks if `arena` is not an arena.
    pub fn fromJsonLeaky(
        bytes: []const u8,
        arena: std.mem.Allocator,
    ) !LockInfo {
        return std.json.parseFromSliceLeaky(LockInfo, arena, bytes, parse_options);
    }
};

test "LockInfo.fromJson(LockInfo.toJson()) round-trip works correctly" {
    const allocator = std.testing.allocator;
    const original = LockInfo{
        .name = "mylock",
        .uid = 501,
        .pid = 4242,
        .global = true,
        .waiters = 2,
        .acquired_at = 1791331200,
        .command = "echo Hello",
    };

    const json = try original.toJson(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"name\":\"mylock\",\"uid\":501,\"pid\":4242,\"global\":true,\"waiters\":2,\"acquired_at\":1791331200,\"command\":\"echo Hello\"}",
        json,
    );

    const info_parsed = try LockInfo.fromJson(json, allocator);
    defer info_parsed.deinit();
    const info = info_parsed.value;

    try std.testing.expectEqualStrings(original.name, info.name);
    try std.testing.expectEqual(original.uid, info.uid);
    try std.testing.expectEqual(original.pid, info.pid);
    try std.testing.expectEqual(original.global, info.global);
    try std.testing.expectEqual(original.waiters, info.waiters);
    try std.testing.expectEqual(original.acquired_at, info.acquired_at);
    try std.testing.expectEqualStrings(original.command, info.command);
}

pub const LockResponse = struct {
    status: LockResponseStatus,
    /// Who holds the lock. Only sent with `Queued`.
    holder: ?LockInfo = null,
    /// Number of clients queued ahead of this one. Only sent with `Queued`.
    ahead: ?usize = null,

    /// Serializes the LockResponse to a JSON string. Fields that are null are
    /// omitted, so responses other than `Queued` are just the status.
    /// Allocates memory for the JSON string, which must be freed by the caller.
    pub fn toJson(
        self: LockResponse,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const json = try std.json.Stringify.valueAlloc(
            allocator,
            self,
            .{ .whitespace = .minified, .emit_null_optional_fields = false },
        );
        return json;
    }

    /// Deserializes a JSON string into a LockResponse. The result owns its
    /// memory, which must be freed by the caller with `deinit`.
    pub fn fromJson(
        bytes: []const u8,
        allocator: std.mem.Allocator,
    ) !std.json.Parsed(LockResponse) {
        return std.json.parseFromSlice(LockResponse, allocator, bytes, parse_options);
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

    const response_parsed = try LockResponse.fromJson(json, allocator);
    defer response_parsed.deinit();
    const response = response_parsed.value;

    try std.testing.expectEqual(response.status, expected.status);
}

test "LockResponse.fromJson(LockResponse.toJson()) round-trip works correctly" {
    const allocator = std.testing.allocator;
    const original = LockResponse{
        .status = LockResponseStatus.Ok,
    };

    const json = try original.toJson(allocator);
    defer allocator.free(json);

    const response_parsed = try LockResponse.fromJson(json, allocator);
    defer response_parsed.deinit();
    const response = response_parsed.value;

    try std.testing.expectEqual(response.status, original.status);
}

test "LockResponse.fromJson(LockResponse.toJson()) round-trips a Queued response" {
    const allocator = std.testing.allocator;
    const original = LockResponse{
        .status = LockResponseStatus.Queued,
        .holder = .{
            .name = "db",
            .uid = 501,
            .pid = 4242,
            .global = false,
            .waiters = 3,
            .acquired_at = 1791331200,
            .command = "./migrate --up",
        },
        .ahead = 2,
    };

    const json = try original.toJson(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"status\":\"Queued\",\"holder\":{\"name\":\"db\",\"uid\":501,\"pid\":4242,\"global\":false,\"waiters\":3,\"acquired_at\":1791331200,\"command\":\"./migrate --up\"},\"ahead\":2}",
        json,
    );

    const response_parsed = try LockResponse.fromJson(json, allocator);
    defer response_parsed.deinit();
    const response = response_parsed.value;
    try std.testing.expectEqual(LockResponseStatus.Queued, response.status);
    try std.testing.expectEqual(2, response.ahead);
    try std.testing.expectEqualStrings("db", response.holder.?.name);
    try std.testing.expectEqual(4242, response.holder.?.pid);
    try std.testing.expectEqualStrings("./migrate --up", response.holder.?.command);
}

pub fn writeLine(writer: *Io.Writer, message: []const u8) Io.Writer.Error!void {
    try writer.writeAll(message);
    try writer.writeAll("\n");
    try writer.flush();
}
