const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const protocol = nlock.protocol;
const log = nlock.Logger.log;
const queue = @import("queue.zig");
const locks = @import("locks.zig");
const LockMap = locks.LockMap;

/// Adapts `handleConnection` to the `Cancelable!void` signature `Io.Group`
/// requires.
pub fn connectionTask(
    io: Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    map: *LockMap,
) Io.Cancelable!void {
    handleConnection(
        io,
        allocator,
        stream,
        map,
    ) catch |err| {
        log(.debug, "Connection error: {s}", .{@errorName(err)});
    };
}

fn handleConnection(
    io: Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    map: *LockMap,
) !void {
    defer stream.close(io);
    // On the heap: connection tasks may run on small stacks.
    const read_buffer = try allocator.alloc(u8, protocol.max_message_len);
    defer allocator.free(read_buffer);
    var reader = stream.reader(io, read_buffer);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    // Ask the kernel who is on the other end of the socket rather than
    // trusting a pid sent by the client.
    const peer = nlock.peer.peerCredentials(stream) catch |err| {
        log(.err, "Failed to get peer credentials: {s}", .{@errorName(err)});
        return err;
    };

    // A connection makes one request: `list`, or `acquire` followed, once
    // the client's command has finished, by `release`.
    const req_parsed = try readRequest(&reader.interface, allocator);
    defer req_parsed.deinit();
    const req = switch (req_parsed.value) {
        .acquire => |acquire| acquire,
        .list => {
            return locks.handleListLocksRequest(allocator, map, &writer.interface) catch |err| {
                log(.err, "Failed to handle list locks request: {s}", .{@errorName(err)});
                return err;
            };
        },
        .release => {
            log(.err, "Received release request before acquiring a lock", .{});
            return error.UnexpectedRequestType;
        },
    };
    // Not logged: the name may contain the control characters that make it
    // invalid.
    if (!protocol.isValidLockName(req.name)) {
        log(.err, "Received acquire request with an invalid lock name ({d} bytes)", .{req.name.len});
        return error.InvalidLockName;
    }

    // Borrows the command from `req_parsed`, which outlives it.
    var client: queue.Client = .{
        .command = req.command,
        .pid = peer.pid,
    };
    // Whatever happens below, the client must not stay in the lock's queue
    // or holders once this connection ends. If it goes away while holding
    // the lock (e.g. it was killed by a signal), release the lock on its
    // behalf so it is not held forever.
    defer {
        if (client.state == .holding) {
            log(.info, "Client disconnected while holding lock '{s}'. Releasing it.", .{req.name});
        }
        locks.leave(io, allocator, map, req.name, &client);
    }

    const holding = locks.handleAcquireLockRequest(
        io,
        allocator,
        req,
        peer,
        map,
        &writer.interface,
        &client,
    ) catch |err| {
        log(.err, "Failed to handle acquire lock request: {s}", .{@errorName(err)});
        return err;
    };
    // Busy, coalesced, replaced or timed out: nothing to release.
    if (!holding) return;

    // The client executes the command and then sends a release lock request
    log(.debug, "Waiting for release lock request from client", .{});
    const release_req_parsed = try readRequest(&reader.interface, allocator);
    defer release_req_parsed.deinit();
    switch (release_req_parsed.value) {
        // A connection may only release the lock it acquired, so the request
        // does not name one.
        .release => {
            log(.info, "Releasing lock for name '{s}'", .{req.name});
            // Leaves the client idle, so the deferred `leave` does nothing.
            locks.leave(io, allocator, map, req.name, &client);
            const lock_response = try (protocol.LockResponse{ .ok = {} }).toJson(allocator);
            defer allocator.free(lock_response);
            try protocol.writeLine(&writer.interface, lock_response);
        },
        else => |release_req| {
            log(.debug, "Received unexpected request type: {s}", .{@tagName(release_req)});
            return error.UnexpectedRequestType;
        },
    }
}

fn readRequest(reader: *Io.Reader, allocator: std.mem.Allocator) !std.json.Parsed(protocol.LockRequest) {
    const message = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
    log(.debug, "Received lock request: {s}", .{message});
    return protocol.LockRequest.fromJson(message, allocator);
}

test "readRequest parses a valid LockRequest where command contains newlines" {
    const message = "{\"acquire\":{\"name\":\"my_lock\",\"nonblock\":false,\"timeout\":null,\"command\":\"echo 'Hello, World!'\\necho 'This is a test.'\\n\"}}\n";
    const allocator = std.testing.allocator;
    const expected_request: protocol.LockRequest.Acquire = .{
        .name = "my_lock",
        .nonblock = false,
        .timeout = null,
        .command = "echo 'Hello, World!'\necho 'This is a test.'\n",
    };

    var reader = std.Io.Reader.fixed(message);
    const parsed = try readRequest(&reader, allocator);
    defer parsed.deinit();
    const request = parsed.value.acquire;

    try std.testing.expectEqualStrings(expected_request.name, request.name);
    try std.testing.expectEqual(expected_request.nonblock, request.nonblock);
    try std.testing.expectEqualStrings(expected_request.command, request.command);
}
