const std = @import("std");
const Io = std.Io;

/// Options for parsing every protocol message.
const parse_options: std.json.ParseOptions = .{
    // Copy strings rather than pointing into the input, which is usually a
    // reader's buffer that is overwritten by the next message.
    .allocate = .alloc_always,
    // A client and daemon of different versions should fail loudly rather
    // than silently drop what the other side sent.
    .ignore_unknown_fields = false,
};

/// A message from the client to the daemon. Serialized as an object with a
/// single key naming the request, e.g. `{"list":{}}`.
pub const LockRequest = union(enum) {
    acquire: Acquire,
    /// Releases the lock this connection holds.
    release,
    list,

    pub const Acquire = struct {
        name: []const u8,
        global: bool,
        nonblock: bool,
        timeout: ?u64,
        command: []const u8,
    };

    /// Serializes the LockRequest to a JSON string.
    /// Allocates memory for the JSON string, which must be freed by the caller.
    pub fn toJson(
        self: LockRequest,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return std.json.Stringify.valueAlloc(
            allocator,
            self,
            .{ .whitespace = .minified },
        );
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

test "LockRequest.toJson serializes an acquire request correctly" {
    const allocator = std.testing.allocator;
    const request: LockRequest = .{ .acquire = .{
        .name = "mylock",
        .global = true,
        .nonblock = false,
        .timeout = null,
        .command = "echo Hello",
    } };
    const expected = "{\"acquire\":{\"name\":\"mylock\",\"global\":true,\"nonblock\":false,\"timeout\":null,\"command\":\"echo Hello\"}}";

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expectEqualStrings(expected, json);
}

test "LockRequest.toJson serializes requests without a payload as an empty object" {
    const allocator = std.testing.allocator;
    for ([_]LockRequest{ .release, .list }, [_][]const u8{
        "{\"release\":{}}",
        "{\"list\":{}}",
    }) |request, expected| {
        const json = try request.toJson(allocator);
        defer allocator.free(json);
        try std.testing.expectEqualStrings(expected, json);

        const parsed = try LockRequest.fromJson(json, allocator);
        defer parsed.deinit();
        try std.testing.expectEqual(std.meta.activeTag(request), std.meta.activeTag(parsed.value));
    }
}

test "LockRequest.fromJson(LockRequest.toJson()) round-trip works correctly" {
    const allocator = std.testing.allocator;
    const original: LockRequest.Acquire = .{
        .name = "mylock",
        .global = true,
        .nonblock = false,
        .timeout = 30,
        .command = "echo Hello",
    };

    const json = try (LockRequest{ .acquire = original }).toJson(allocator);
    defer allocator.free(json);

    const parsed = try LockRequest.fromJson(json, allocator);
    defer parsed.deinit();
    const acquire = parsed.value.acquire;

    try std.testing.expectEqualStrings(original.name, acquire.name);
    try std.testing.expectEqual(original.global, acquire.global);
    try std.testing.expectEqual(original.nonblock, acquire.nonblock);
    try std.testing.expectEqual(original.timeout, acquire.timeout);
    try std.testing.expectEqualStrings(original.command, acquire.command);
}

test "LockRequest.fromJson correctly handles colon in command" {
    const allocator = std.testing.allocator;
    const json = "{\"acquire\":{\"name\":\"mylock\",\"global\":true,\"nonblock\":false,\"timeout\":30,\"command\":\"echo Hello:World\"}}";
    const parsed = try LockRequest.fromJson(json, allocator);
    defer parsed.deinit();
    const acquire = parsed.value.acquire;

    try std.testing.expectEqualStrings("mylock", acquire.name);
    try std.testing.expectEqual(true, acquire.global);
    try std.testing.expectEqual(false, acquire.nonblock);
    try std.testing.expectEqual(30, acquire.timeout.?);
    try std.testing.expectEqualStrings("echo Hello:World", acquire.command);
}

test "LockRequest.fromJson correctly handles newline in command" {
    const allocator = std.testing.allocator;
    const json = "{\"acquire\":{\"name\":\"mylock\",\"global\":true,\"nonblock\":false,\"timeout\":null,\"command\":\"echo Hello\\nWorld\"}}";
    const parsed = try LockRequest.fromJson(json, allocator);
    defer parsed.deinit();
    const acquire = parsed.value.acquire;

    try std.testing.expectEqualStrings("mylock", acquire.name);
    try std.testing.expectEqual(true, acquire.global);
    try std.testing.expectEqual(false, acquire.nonblock);
    try std.testing.expectEqual(null, acquire.timeout);
    try std.testing.expectEqualStrings("echo Hello\nWorld", acquire.command);
}

test "LockRequest.fromJson rejects unknown fields and requests" {
    // A client and daemon of different versions should fail loudly.
    const unknown_field = "{\"acquire\":{\"name\":\"mylock\",\"global\":true,\"nonblock\":false,\"timeout\":null,\"command\":\"echo Hello\",\"from_the_future\":true}}";
    try std.testing.expectError(error.UnknownField, LockRequest.fromJson(unknown_field, std.testing.allocator));
    const unknown_request = "{\"FromTheFuture\":{}}";
    try std.testing.expectError(error.UnknownField, LockRequest.fromJson(unknown_request, std.testing.allocator));
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

/// A message from the daemon to the client. Serialized as an object with a
/// single key naming the response, e.g. `{"ok":{}}`.
pub const LockResponse = union(enum) {
    ok,
    busy,
    timeout,
    /// The lock is held by someone else and the request was queued. Sent
    /// before the client starts waiting, followed later by `ok` or `timeout`.
    queued: Queued,

    pub const Queued = struct {
        /// Who holds the lock.
        holder: LockInfo,
        /// Number of clients queued ahead of this one.
        ahead: usize,
    };

    /// Serializes the LockResponse to a JSON string.
    /// Allocates memory for the JSON string, which must be freed by the caller.
    pub fn toJson(
        self: LockResponse,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return std.json.Stringify.valueAlloc(
            allocator,
            self,
            .{ .whitespace = .minified },
        );
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

/// Which kind of response the daemon sent, without its payload.
pub const LockResponseStatus = std.meta.Tag(LockResponse);

test "LockResponse.toJson serializes LockResponse correctly" {
    const allocator = std.testing.allocator;
    const response: LockResponse = .ok;
    const expected = "{\"ok\":{}}";

    const json = try response.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expectEqualStrings(expected, json);
}

test "LockResponse.fromJson deserializes JSON into LockResponse correctly" {
    const allocator = std.testing.allocator;
    const json = "{\"busy\":{}}";

    const parsed = try LockResponse.fromJson(json, allocator);
    defer parsed.deinit();

    try std.testing.expectEqual(LockResponseStatus.busy, std.meta.activeTag(parsed.value));
}

test "LockResponse.fromJson(LockResponse.toJson()) round-trips a queued response" {
    const allocator = std.testing.allocator;
    const original: LockResponse = .{ .queued = .{
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
    } };

    const json = try original.toJson(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"queued\":{\"holder\":{\"name\":\"db\",\"uid\":501,\"pid\":4242,\"global\":false,\"waiters\":3,\"acquired_at\":1791331200,\"command\":\"./migrate --up\"},\"ahead\":2}}",
        json,
    );

    const parsed = try LockResponse.fromJson(json, allocator);
    defer parsed.deinit();
    const queued = parsed.value.queued;
    try std.testing.expectEqual(2, queued.ahead);
    try std.testing.expectEqualStrings("db", queued.holder.name);
    try std.testing.expectEqual(4242, queued.holder.pid);
    try std.testing.expectEqualStrings("./migrate --up", queued.holder.command);
}

pub fn writeLine(writer: *Io.Writer, message: []const u8) Io.Writer.Error!void {
    try writer.writeAll(message);
    try writer.writeAll("\n");
    try writer.flush();
}
