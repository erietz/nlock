const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const log = nlock.logger.log;
const ll = nlock.logger.LogLevel;

const Context = struct {
    io: Io,
    allocator: std.mem.Allocator,
    map: *nlock.ThreadSafeHashMap([]const u8, *nlock.Lock),
    writer: *Io.Writer,
};

pub fn main(init: std.process.Init) void {
    runServer(init) catch |err| {
        log(ll.Error, "Error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

pub fn runServer(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const socket_path = nlock.getSocketPath(init.environ_map);
    nlock.logger.init(nlock.logger.getLogLevel(init.environ_map));

    std.Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};

    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    log(ll.Info, "Server started and listening on {s}", .{socket_path});

    var map = nlock.ThreadSafeHashMap([]const u8, *nlock.Lock).init(io, gpa);
    // Declared before `group` so this runs after `group.cancel`: no connection
    // tasks remain, so it is safe to walk the inner map without the mutex.
    defer {
        var it = map.map.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*.command);
            gpa.destroy(entry.value_ptr.*);
        }
        map.deinit();
    }

    // initialize structured task management group
    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = try server.accept(io);
        // Spawn a new task to handle the connection
        group.concurrent(io, connectionTask, .{
            io,
            gpa,
            stream,
            &map,
        }) catch |err| {
            log(ll.Error, "Failed to spawn connection task: {s}", .{@errorName(err)});
            stream.close(io);
        };
    }
}

/// Adapts `handleConnection` to the `Cancelable!void` signature `Io.Group`
/// requires.
fn connectionTask(
    io: Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    map: *nlock.ThreadSafeHashMap([]const u8, *nlock.Lock),
) Io.Cancelable!void {
    handleConnection(
        io,
        allocator,
        stream,
        map,
    ) catch |err| {
        log(ll.Debug, "Connection error: {s}", .{@errorName(err)});
    };
}

const AcquireResult = enum {
    acquired,
    not_acquired,
};

fn handleConnection(
    io: Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    map: *nlock.ThreadSafeHashMap([]const u8, *nlock.Lock),
) !void {
    defer stream.close(io);
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    const ctx = Context{
        .io = io,
        .allocator = allocator,
        .map = map,
        .writer = &writer.interface,
    };

    var req = try readRequest(&reader.interface, allocator);
    defer req.deinit(allocator);
    switch (req.request_type) {
        nlock.LockRequestType.AcquireLock => {
            const result = handleAcquireLockRequest(ctx, req) catch |err| {
                log(ll.Error, "Failed to handle acquire lock request: {s}", .{@errorName(err)});
                return err;
            };
            if (result != .acquired) {
                return;
            }
        },
        nlock.LockRequestType.ListLocks => {
            return handleListLocksRequest(ctx) catch |err| {
                log(ll.Error, "Failed to handle list locks request: {s}", .{@errorName(err)});
                return err;
            };
        },
        else => {
            log(ll.Error, "Received unexpected request type: {d}", .{req.request_type});
            return error.UnexpectedRequestType;
        },
    }

    // The client executes the command and then sends a release lock request
    log(ll.Debug, "Waiting for release lock request from client", .{});
    var release_req = readRequest(&reader.interface, allocator) catch |err| {
        log(ll.Debug, "Failed to read release request (client may have disconnected): {s}", .{@errorName(err)});
        handleReleaseLockRequest(ctx, req) catch |release_err| {
            log(ll.Error, "Failed to auto-release lock on client disconnect: {s}", .{@errorName(release_err)});
        };
        return err;
    };
    defer release_req.deinit(allocator);
    switch (release_req.request_type) {
        nlock.LockRequestType.ReleaseLock => {
            handleReleaseLockRequest(ctx, release_req) catch |err| {
                log(ll.Debug, "Failed to handle release lock request: {s}", .{@errorName(err)});
                return err;
            };
        },
        else => {
            log(ll.Debug, "Received unexpected request type: {d}", .{release_req.request_type});
            return error.UnexpectedRequestType;
        },
    }
}

fn readRequest(reader: *Io.Reader, allocator: std.mem.Allocator) !nlock.LockRequest {
    const message = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
    log(ll.Debug, "Received lock request: {s}", .{message});
    return nlock.LockRequest.fromJson(message, allocator);
}

test "readRequest parses a valid LockRequest where command contains newlines" {
    const message = "{\"request_type\":\"AcquireLock\",\"name\":\"my_lock\",\"global\":false,\"nonblock\":false,\"timeout\":null,\"command\":\"echo 'Hello, World!'\\necho 'This is a test.'\\n\"}\n";
    const allocator = std.testing.allocator;
    const expected_request = nlock.LockRequest.init(
        nlock.LockRequestType.AcquireLock,
        "my_lock",
        false,
        false,
        null,
        "echo 'Hello, World!'\necho 'This is a test.'\n",
    );

    var reader = std.Io.Reader.fixed(message);
    var request = try readRequest(&reader, allocator);
    defer request.deinit(allocator);

    try std.testing.expectEqual(expected_request.request_type, request.request_type);
    try std.testing.expectEqualStrings(expected_request.name, request.name);
    try std.testing.expectEqual(expected_request.global, request.global);
    try std.testing.expectEqual(expected_request.nonblock, request.nonblock);
    try std.testing.expectEqualStrings(expected_request.command, request.command);
}

fn sendLockResponse(
    ctx: Context,
    status: nlock.LockResponseStatus,
) !void {
    const response = try nlock.LockResponse
        .init(status)
        .toJson(ctx.allocator);
    defer ctx.allocator.free(response);
    try nlock.writeLine(ctx.writer, response);
}

fn handleAcquireLockRequest(
    ctx: Context,
    lock_request: nlock.LockRequest,
) !AcquireResult {
    var waiter = nlock.Waiter{
        .command = lock_request.command,
    };
    var is_waiting = false;

    {
        ctx.map.mutex.lockUncancelable(ctx.io);
        defer ctx.map.mutex.unlock(ctx.io);

        if (ctx.map.map.get(lock_request.name)) |existing_lock| {
            if (lock_request.nonblock) {
                log(ll.Info, "Lock for name '{s}' is already acquired (non-blocking).", .{lock_request.name});
                try sendLockResponse(ctx, nlock.LockResponseStatus.Busy);
                return .not_acquired;
            }
            log(ll.Info, "Lock for name '{s}' is already acquired. Waiting for release.", .{lock_request.name});
            existing_lock.waiters.append(&waiter.node);
            is_waiting = true;
        } else {
            const key = try ctx.allocator.dupe(u8, lock_request.name);
            errdefer ctx.allocator.free(key);
            const cmd = try ctx.allocator.dupe(u8, lock_request.command);
            errdefer ctx.allocator.free(cmd);
            const lock = try ctx.allocator.create(nlock.Lock);
            errdefer ctx.allocator.destroy(lock);
            lock.* = .{
                .command = cmd,
                .waiters = .{},
            };
            try ctx.map.map.put(key, lock);

            log(ll.Info, "Acquired lock for name '{s}' (global: {}). Command: {s}", .{
                lock_request.name,
                lock_request.global,
                lock_request.command,
            });
            log(ll.Info, "Sending acquired response for lock {s}.", .{lock_request.name});
            try sendLockResponse(ctx, nlock.LockResponseStatus.Ok);
            return .acquired;
        }
    }

    if (is_waiting) {
        if (lock_request.timeout) |timeout_s| {
            log(ll.Debug, "Waiting for lock '{s}' to be released with timeout of {d} seconds", .{
                lock_request.name,
                timeout_s,
            });
            const timeout = std.Io.Timeout{ .duration = .{
                .clock = .awake,
                .raw = std.Io.Duration.fromSeconds(@intCast(timeout_s)),
            } };

            waiter.event.waitTimeout(ctx.io, timeout) catch |err| switch (err) {
                error.Timeout => {
                    log(ll.Info, "Timeout while waiting for lock '{s}' to be released", .{
                        lock_request.name,
                    });
                    ctx.map.mutex.lockUncancelable(ctx.io);
                    defer ctx.map.mutex.unlock(ctx.io);

                    if (waiter.event == .is_set) {
                        log(ll.Info, "Sending acquired response for lock {s}.", .{lock_request.name});
                        try sendLockResponse(ctx, nlock.LockResponseStatus.Ok);
                        return .acquired;
                    } else {
                        if (ctx.map.map.get(lock_request.name)) |existing_lock| {
                            existing_lock.waiters.remove(&waiter.node);
                        }
                        try sendLockResponse(ctx, nlock.LockResponseStatus.Timeout);
                        return .not_acquired;
                    }
                },
                else => return err,
            };
        } else {
            log(ll.Debug, "Waiting for lock '{s}' to be released without timeout", .{lock_request.name});
            try waiter.event.wait(ctx.io);
        }

        log(ll.Info, "Sending acquired response for lock {s}.", .{lock_request.name});
        try sendLockResponse(ctx, nlock.LockResponseStatus.Ok);
        return .acquired;
    }

    return .not_acquired;
}

fn handleReleaseLockRequest(
    ctx: Context,
    lock_request: nlock.LockRequest,
) !void {
    log(ll.Info, "Releasing lock for name '{s}' (global: {})", .{
        lock_request.name,
        lock_request.global,
    });

    ctx.map.mutex.lockUncancelable(ctx.io);
    defer ctx.map.mutex.unlock(ctx.io);

    if (ctx.map.map.get(lock_request.name)) |lock_ptr| {
        if (lock_ptr.waiters.popFirst()) |waiter_node| {
            const waiter: *nlock.Waiter = @fieldParentPtr("node", waiter_node);
            const new_cmd = try ctx.allocator.dupe(u8, waiter.command);
            ctx.allocator.free(lock_ptr.command);
            lock_ptr.command = new_cmd;

            // Signal the waiter that the lock has been released
            waiter.event.set(ctx.io);
        } else {
            if (ctx.map.map.fetchRemove(lock_request.name)) |kv| {
                ctx.allocator.free(kv.key);
                ctx.allocator.free(kv.value.command);
                ctx.allocator.destroy(kv.value);
            }
        }

        log(ll.Info, "Lock for name '{s}' released successfully.", .{lock_request.name});
        try sendLockResponse(ctx, nlock.LockResponseStatus.Ok);
        return;
    }

    log(ll.Error, "No lock found for name '{s}' to release.", .{lock_request.name});
    return error.LockNotFound;
}

fn handleListLocksRequest(
    ctx: Context,
) !void {
    ctx.map.mutex.lockUncancelable(ctx.io);
    defer ctx.map.mutex.unlock(ctx.io);

    var it = ctx.map.map.iterator();
    while (it.next()) |entry| {
        const lock_name = entry.key_ptr.*;
        const lock_command = entry.value_ptr.*.command;

        const lock_info = try nlock.LockRequest.init(
            nlock.LockRequestType.AcquireLock,
            lock_name,
            false,
            false,
            null,
            lock_command,
        ).toJson(ctx.allocator);
        defer ctx.allocator.free(lock_info);

        try nlock.writeLine(ctx.writer, lock_info);
    }
}
