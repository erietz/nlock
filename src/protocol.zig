const std = @import("std");
const Io = std.Io;

/// Longest lock name, in bytes.
pub const max_name_len = 255;

/// Returns true if `name` can be used as a lock name. Whitespace and control
/// characters are rejected so names stay a single field in `nlock list`
/// output. The client checks names before sending them and the daemon checks
/// them again, since anything can connect to its socket.
pub fn isValidLockName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |ch| {
        if (std.ascii.isWhitespace(ch) or std.ascii.isControl(ch)) return false;
    }
    return true;
}

test "isValidSlots" {
    try std.testing.expect(!isValidSlots(0));
    try std.testing.expect(isValidSlots(1));
    try std.testing.expect(isValidSlots(std.math.maxInt(u32)));
}

test "isValidLockName" {
    try std.testing.expect(isValidLockName("build"));
    try std.testing.expect(isValidLockName("db-migrate.v2/prod"));
    try std.testing.expect(!isValidLockName(""));
    try std.testing.expect(!isValidLockName("a b"));
    try std.testing.expect(!isValidLockName("a\tb"));
    try std.testing.expect(!isValidLockName("a\nb"));
    try std.testing.expect(isValidLockName("x" ** max_name_len));
    try std.testing.expect(!isValidLockName("x" ** (max_name_len + 1)));
}

/// Returns true if `slots` can be the size of a lock: at least one client
/// must be able to hold it, or every request would wait forever.
pub fn isValidSlots(slots: u32) bool {
    return slots >= 1;
}

/// Longest command string the client sends, in bytes. The command is only
/// shown to people, so the client truncates longer ones.
pub const max_command_len = 4096;

/// Size of the buffer each side reads one message into. Every message fits,
/// even when each byte of the name and command is escaped as `\u00XX`.
pub const max_message_len = 64 * 1024;

comptime {
    std.debug.assert(6 * (max_name_len + max_command_len) + 1024 <= max_message_len);
}

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
        nonblock: bool,
        timeout: ?u64,
        command: []const u8,
        /// What to do if the lock is held and other clients are already
        /// waiting for it.
        if_pending: IfPending = .queue,
        /// How many clients may hold the lock at once. Every request for a
        /// lock in use must ask for the same number.
        slots: u32 = 1,
    };

    pub const IfPending = enum {
        /// Wait behind them.
        queue,
        /// Do not wait: a run is already pending (`--coalesce`).
        skip,
        /// Take their place: they stop waiting (`--replace`).
        replace,
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
        .nonblock = false,
        .timeout = null,
        .command = "echo Hello",
    } };
    const expected = "{\"acquire\":{\"name\":\"mylock\",\"nonblock\":false,\"timeout\":null,\"command\":\"echo Hello\",\"if_pending\":\"queue\",\"slots\":1}}";

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
        .nonblock = false,
        .timeout = 30,
        .command = "echo Hello",
        .if_pending = .replace,
        .slots = 4,
    };

    const json = try (LockRequest{ .acquire = original }).toJson(allocator);
    defer allocator.free(json);

    const parsed = try LockRequest.fromJson(json, allocator);
    defer parsed.deinit();
    const acquire = parsed.value.acquire;

    try std.testing.expectEqualStrings(original.name, acquire.name);
    try std.testing.expectEqual(original.nonblock, acquire.nonblock);
    try std.testing.expectEqual(original.timeout, acquire.timeout);
    try std.testing.expectEqualStrings(original.command, acquire.command);
    try std.testing.expectEqual(original.if_pending, acquire.if_pending);
    try std.testing.expectEqual(original.slots, acquire.slots);
}

test "LockRequest.fromJson correctly handles colon in command" {
    const allocator = std.testing.allocator;
    const json = "{\"acquire\":{\"name\":\"mylock\",\"nonblock\":false,\"timeout\":30,\"command\":\"echo Hello:World\",\"if_pending\":\"queue\"}}";
    const parsed = try LockRequest.fromJson(json, allocator);
    defer parsed.deinit();
    const acquire = parsed.value.acquire;

    try std.testing.expectEqualStrings("mylock", acquire.name);
    try std.testing.expectEqual(false, acquire.nonblock);
    try std.testing.expectEqual(30, acquire.timeout.?);
    try std.testing.expectEqualStrings("echo Hello:World", acquire.command);
}

test "LockRequest.fromJson correctly handles newline in command" {
    const allocator = std.testing.allocator;
    const json = "{\"acquire\":{\"name\":\"mylock\",\"nonblock\":false,\"timeout\":null,\"command\":\"echo Hello\\nWorld\"}}";
    const parsed = try LockRequest.fromJson(json, allocator);
    defer parsed.deinit();
    const acquire = parsed.value.acquire;

    try std.testing.expectEqualStrings("mylock", acquire.name);
    try std.testing.expectEqual(false, acquire.nonblock);
    try std.testing.expectEqual(null, acquire.timeout);
    try std.testing.expectEqualStrings("echo Hello\nWorld", acquire.command);
}

test "LockRequest.fromJson rejects unknown fields and requests" {
    // A client and daemon of different versions should fail loudly.
    const unknown_field = "{\"acquire\":{\"name\":\"mylock\",\"nonblock\":false,\"timeout\":null,\"command\":\"echo Hello\",\"from_the_future\":true}}";
    try std.testing.expectError(error.UnknownField, LockRequest.fromJson(unknown_field, std.testing.allocator));
    const unknown_request = "{\"FromTheFuture\":{}}";
    try std.testing.expectError(error.UnknownField, LockRequest.fromJson(unknown_request, std.testing.allocator));
}

/// One row of the `list` response: a lock currently held, and one of the
/// clients holding it. A lock with several holders has one row for each.
pub const LockInfo = struct {
    name: []const u8,
    /// Pid of the `nlock` client holding the lock, or 0 if unknown.
    pid: i32,
    /// Number of clients queued for the lock.
    waiters: usize,
    /// How many clients may hold the lock at once.
    slots: u32 = 1,
    /// When this holder acquired the lock, in seconds since the Unix epoch.
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
        .pid = 4242,
        .waiters = 2,
        .slots = 4,
        .acquired_at = 1791331200,
        .command = "echo Hello",
    };

    const json = try original.toJson(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"name\":\"mylock\",\"pid\":4242,\"waiters\":2,\"slots\":4,\"acquired_at\":1791331200,\"command\":\"echo Hello\"}",
        json,
    );

    const info_parsed = try LockInfo.fromJson(json, allocator);
    defer info_parsed.deinit();
    const info = info_parsed.value;

    try std.testing.expectEqualStrings(original.name, info.name);
    try std.testing.expectEqual(original.pid, info.pid);
    try std.testing.expectEqual(original.waiters, info.waiters);
    try std.testing.expectEqual(original.slots, info.slots);
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
    /// before the client starts waiting, followed later by `ok`, `timeout`
    /// or `replaced`.
    queued: Queued,
    /// The request asked to skip waiting (`if_pending = skip`) and another
    /// client was already waiting for the lock, so it was not queued.
    coalesced: Coalesced,
    /// A queued request was taken out of the queue by a newer request with
    /// `if_pending = replace`. Sent instead of `ok`.
    replaced: Replaced,
    /// The lock is in use with a different number of slots than the
    /// request asked for, so it was not queued.
    mismatch: Mismatch,

    pub const Queued = struct {
        /// The lock's longest-standing holder. Every slot is taken.
        holder: LockInfo,
        /// Number of clients queued ahead of this one.
        ahead: usize,
    };

    pub const Coalesced = struct {
        /// The most recently queued client, whose run is still to come.
        pending: Client,
        /// Number of clients waiting for the lock.
        waiters: usize,
    };

    /// The client that took this one's place in the queue.
    pub const Replaced = struct {
        /// 0 if unknown.
        pid: i32,
    };

    pub const Mismatch = struct {
        /// The number of slots the lock is in use with.
        slots: u32,
    };

    /// A client waiting for a lock.
    pub const Client = struct {
        /// 0 if unknown.
        pid: i32,
        command: []const u8,
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
            .pid = 4242,
            .waiters = 3,
            .acquired_at = 1791331200,
            .command = "./migrate --up",
        },
        .ahead = 2,
    } };

    const json = try original.toJson(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"queued\":{\"holder\":{\"name\":\"db\",\"pid\":4242,\"waiters\":3,\"slots\":1,\"acquired_at\":1791331200,\"command\":\"./migrate --up\"},\"ahead\":2}}",
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

test "LockResponse.fromJson(LockResponse.toJson()) round-trips coalesced and replaced responses" {
    const allocator = std.testing.allocator;
    const client: LockResponse.Client = .{ .pid = 4321, .command = "make" };
    for ([_]LockResponse{
        .{ .coalesced = .{ .pending = client, .waiters = 1 } },
        .{ .replaced = .{ .pid = 4321 } },
        .{ .mismatch = .{ .slots = 4 } },
    }, [_][]const u8{
        "{\"coalesced\":{\"pending\":{\"pid\":4321,\"command\":\"make\"},\"waiters\":1}}",
        "{\"replaced\":{\"pid\":4321}}",
        "{\"mismatch\":{\"slots\":4}}",
    }) |original, expected| {
        const json = try original.toJson(allocator);
        defer allocator.free(json);
        try std.testing.expectEqualStrings(expected, json);

        const parsed = try LockResponse.fromJson(json, allocator);
        defer parsed.deinit();
        try std.testing.expectEqual(std.meta.activeTag(original), std.meta.activeTag(parsed.value));
    }
}

pub fn writeLine(writer: *Io.Writer, message: []const u8) Io.Writer.Error!void {
    try writer.writeAll(message);
    try writer.writeAll("\n");
    try writer.flush();
}
