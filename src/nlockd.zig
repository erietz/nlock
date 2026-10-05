const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const log = nlock.logger.log;
const ll = nlock.logger.LogLevel;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        log(ll.Error, "Error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

pub fn run(init: std.process.Init) !void {
    // Start the server to listen for incoming connections
    try runServer(init);
}

pub fn runServer(init: std.process.Init) !void {
    const io = init.io;
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

    const gpa = init.gpa;
    var map = nlock.ThreadSafeHashMap([]const u8, nlock.Lock).init(io, gpa);
    // Declared before `group` so this runs after `group.cancel`: no connection
    // tasks remain, so it is safe to walk the inner map without the mutex.
    defer {
        var it = map.map.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*.command);
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
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
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

fn handleConnection(
    io: Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
) !void {
    defer stream.close(io);
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    // Client current follows this simple ACQUIRE -> EXECUTE -> RELEASE
    // pattern, but this will change when implementing the `list` command, for
    // example.

    // Read the acquire request message from the client
    // const req = try readRequest(&reader.interface);
    var req = try readRequest(&reader.interface, allocator);
    defer req.deinit(allocator);
    switch (req.request_type) {
        nlock.LockRequestType.AcquireLock => {
            handleAcquireLockRequest(
                io,
                allocator,
                req,
                map,
                &writer.interface,
            ) catch |err| {
                log(ll.Error, "Failed to handle acquire lock request: {s}", .{@errorName(err)});
                return err;
            };
        },
        nlock.LockRequestType.ListLocks => {
            return handleListLocksRequest(allocator, map, &writer.interface) catch |err| {
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
    var release_req = try readRequest(&reader.interface, allocator);
    defer release_req.deinit(allocator);
    switch (release_req.request_type) {
        nlock.LockRequestType.ReleaseLock => {
            handleReleaseLockRequest(
                io,
                allocator,
                release_req,
                map,
                &writer.interface,
            ) catch |err| {
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
    const message = "{\"request_type\":\"AcquireLock\",\"name\":\"my_lock\",\"global\":false,\"command\":\"echo 'Hello, World!'\\necho 'This is a test.'\\n\"}\n";
    const allocator = std.testing.allocator;
    const expected_request = nlock.LockRequest.init(
        nlock.LockRequestType.AcquireLock,
        "my_lock",
        false,
        "echo 'Hello, World!'\necho 'This is a test.'\n",
    );

    var reader = std.Io.Reader.fixed(message);
    var request = try readRequest(&reader, allocator);
    defer request.deinit(allocator);

    try std.testing.expectEqual(expected_request.request_type, request.request_type);
    try std.testing.expectEqualStrings(expected_request.name, request.name);
    try std.testing.expectEqual(expected_request.global, request.global);
    try std.testing.expectEqualStrings(expected_request.command, request.command);
}

fn handleAcquireLockRequest(
    io: Io,
    allocator: std.mem.Allocator,
    lock_request: nlock.LockRequest,
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
    writer: *Io.Writer,
) !void {
    // Check and insert in one atomic step so two clients racing for the same
    // name cannot both acquire it.
    // The map owns copies of both the name and the command: `lock_request`
    // slices point into this connection's read buffer, which is reused by the
    // next read and invalid once the connection ends.
    const lock_name_copy = try allocator.dupe(u8, lock_request.name);
    const command_copy = allocator.dupe(u8, lock_request.command) catch |err| {
        allocator.free(lock_name_copy);
        return err;
    };
    // defer allocator.free(lock_name_copy);
    // defer allocator.free(command_copy);

    const lock = nlock.Lock{
        .command = command_copy,
    };

    const acquired = map.tryPut(lock_name_copy, lock) catch |err| {
        allocator.free(lock_name_copy);
        allocator.free(command_copy);
        return err;
    };

    if (acquired) {
        log(ll.Info, "Acquired lock for name '{s}' (global: {}). Command: {s}", .{
            lock_request.name,
            lock_request.global,
            lock_request.command,
        });
    } else {
        log(ll.Info, "Lock for name '{s}' is already acquired", .{lock_name_copy});
        // TODO: almost feel like we need manual control of the mutex from
        // above, so that we can do a get and then a put in the same section.
        // There is still a race condition here.
        var existing_lock = map.getPtr(lock_name_copy) orelse {
            log(ll.Error, "Lock for name '{s}' was removed before we could add a waiter", .{lock_name_copy});
            return error.LockAlreadyAcquired;
        };
        var waiter = nlock.Waiter{
            .event = .unset,
            .command = command_copy,
        };
        // Queue up the command to be executed when the acquired lock is
        // released
        existing_lock.waiters.append(&waiter.node);
        // Wait for the lock to be released. This does not happen until the
        // client sends a release lock request, which will signal this waiter.
        log(ll.Debug, "Waiting for lock '{s}' to be released", .{lock_name_copy});
        try waiter.event.wait(io);
    }

    log(ll.Info, "Sending acquired response for lock {s}.", .{lock_name_copy});
    const acquired_response = try nlock.LockResponse
        .init(
            nlock.LockResponseStatus.Ok,
        ).toJson(allocator);
    defer allocator.free(acquired_response);
    try nlock.writeLine(writer, acquired_response);
}

fn handleReleaseLockRequest(
    io: Io,
    allocator: std.mem.Allocator,
    lock_request: nlock.LockRequest,
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
    writer: *Io.Writer,
) !void {
    log(ll.Info, "Releasing lock for name '{s}' (global: {})", .{
        lock_request.name,
        lock_request.global,
    });

    if (map.getPtr(lock_request.name)) |lock_ptr| {
        if (lock_ptr.waiters.popFirst()) |waiter_node| {
            var w: *nlock.Waiter = @fieldParentPtr("node", waiter_node);
            lock_ptr.command = w.command; // Update the lock's command to the waiter's command
            // Signal the waiter that the lock has been released
            w.event.set(io);
            // allocator.free(w.command); // Free the waiter's command after signaling
        } else {
            allocator.free(lock_ptr.command);
            _ = map.remove(lock_request.name);
        }

        log(ll.Info, "Lock for name '{s}' released successfully.", .{lock_request.name});
        const lock_response = try nlock.LockResponse.init(nlock.LockResponseStatus.Ok).toJson(allocator);
        defer allocator.free(lock_response);
        try nlock.writeLine(writer, lock_response);
        return;
    }

    log(ll.Error, "No lock found for name '{s}' to release.", .{lock_request.name});
    return error.LockNotFound;
}

fn handleListLocksRequest(
    allocator: std.mem.Allocator,
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
    writer: *Io.Writer,
) !void {
    var it = map.map.iterator();
    while (it.next()) |entry| {
        const lock_name = entry.key_ptr.*;
        const lock_command = entry.value_ptr.*.command;

        const lock_info = try nlock.LockRequest.init(
            nlock.LockRequestType.AcquireLock,
            lock_name,
            false,
            lock_command,
        ).toJson(allocator);
        defer allocator.free(lock_info);

        try nlock.writeLine(writer, lock_info);
    }
}
