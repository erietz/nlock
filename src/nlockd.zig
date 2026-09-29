const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");

pub fn main(init: std.process.Init) !void {
    try run(init);
}

pub fn run(init: std.process.Init) !void {
    // Start the server to listen for incoming connections
    try runServer(init);
}

pub fn runServer(init: std.process.Init) !void {
    const io = init.io;

    std.Io.Dir.cwd().deleteFile(io, nlock.SOCKET_PATH) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(io, nlock.SOCKET_PATH) catch {};

    const address = try std.Io.net.UnixAddress.init(nlock.SOCKET_PATH);

    var server = try address.listen(io, .{});
    defer server.deinit(io);
    std.log.info("Server started and listening on {s}", .{nlock.SOCKET_PATH});

    const allocator = init.gpa;
    var map = nlock.ThreadSafeHashMap([]const u8, nlock.Lock).init(io, allocator);
    // Declared before `group` so this runs after `group.cancel`: no connection
    // tasks remain, so it is safe to walk the inner map without the mutex.
    defer {
        var it = map.map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*.command);
        }
        map.deinit();
    }

    // initialize structured task management group
    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        var stream = try server.accept(io);
        group.concurrent(io, connectionTask, .{
            io,
            allocator,
            stream,
            &map,
        }) catch |err| {
            std.log.err("Failed to spawn connection task: {s}", .{@errorName(err)});
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
        std.log.debug("Connection error: {s}", .{@errorName(err)});
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
    const req = try readRequest(&reader.interface);
    switch (req.request_type) {
        nlock.LockRequestType.AcquireLock => {
            handleAcquireLockRequest(
                io,
                allocator,
                req,
                map,
                &writer.interface,
            ) catch |err| {
                std.log.debug("Failed to handle acquire lock request: {s}", .{@errorName(err)});
                return err;
            };
        },
        nlock.LockRequestType.ListLocks => {
            std.log.debug("Received list locks request\n", .{});
            handleListLocksRequest(map, &writer.interface) catch |err| {
                std.log.debug("Failed to handle list locks request: {s}", .{@errorName(err)});
                return err;
            };
            return;
        },
        else => {
            std.log.debug("Received unexpected request type: {d}", .{req.request_type});
            return error.UnexpectedRequestType;
        },
    }

    // The client executes the command and then sends a release lock request
    std.log.debug("Waiting for release lock request from client\n", .{});
    const release_req = try readRequest(&reader.interface);
    switch (release_req.request_type) {
        nlock.LockRequestType.ReleaseLock => {
            handleReleaseLockRequest(
                io,
                allocator,
                release_req,
                map,
                &writer.interface,
            ) catch |err| {
                std.log.debug("Failed to handle release lock request: {s}", .{@errorName(err)});
                return err;
            };
        },
        else => {
            std.log.debug("Received unexpected request type: {d}", .{release_req.request_type});
            return error.UnexpectedRequestType;
        },
    }
}

fn readRequest(reader: *Io.Reader) !nlock.LockRequest {
    const message = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
    return nlock.LockRequest.fromString(message) catch |err| {
        std.log.debug("Failed to parse message: {s}", .{@errorName(err)});
        return err;
    };
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
        std.log.info("Acquired lock for name '{s}' (global: {}). Command: {s}", .{
            lock_request.name,
            lock_request.global,
            lock_request.command,
        });
    } else {
        std.log.info("Lock for name '{s}' is already acquired", .{lock_name_copy});
        // TODO: almost feel like we need manual control of the mutex from
        // above, so that we can do a get and then a put in the same section.
        // There is still a race condition here.
        var existing_lock = map.getPtr(lock_name_copy) orelse {
            std.log.err("Lock for name '{s}' was removed before we could add a waiter", .{lock_name_copy});
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
        std.log.debug("Waiting for lock '{s}' to be released\n", .{lock_name_copy});
        try waiter.event.wait(io);
    }

    std.log.info("Sending acquired response for lock {s}.", .{lock_name_copy});
    const acquired_response = nlock.LockResponse.init(nlock.LockResponseStatus.Ok).toString();
    try nlock.writeLine(writer, acquired_response);
}

fn handleReleaseLockRequest(
    io: Io,
    allocator: std.mem.Allocator,
    lock_request: nlock.LockRequest,
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
    writer: *Io.Writer,
) !void {
    std.log.info("Releasing lock for name '{s}' (global: {})", .{
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

        std.log.info("Lock for name '{s}' released successfully.", .{lock_request.name});
        const lock_response = nlock.LockResponse.init(nlock.LockResponseStatus.Ok).toString();
        try nlock.writeLine(writer, lock_response);
    } else {
        std.log.err("No lock found for name '{s}' to release.", .{lock_request.name});
        return error.LockNotFound;
    }
}

fn handleListLocksRequest(
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
    writer: *Io.Writer,
) !void {
    var it = map.map.iterator();
    while (it.next()) |entry| {
        const lock_name = entry.key_ptr.*;
        const lock_command = entry.value_ptr.*.command;

        const lock_info = nlock.LockRequest.init(
            nlock.LockRequestType.AcquireLock,
            lock_name,
            false,
            lock_command,
        ).toString();

        try nlock.writeLine(writer, lock_info);
    }
}
