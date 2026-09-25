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

    // initialize structured task management group
    var group: Io.Group = .init;
    defer group.cancel(io);

    const allocator = init.gpa;
    var map: std.StringHashMap([]const u8) = .init(allocator);
    var mutex = std.Io.Mutex.init;
    defer {
        var it = map.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        map.deinit();
    }

    while (true) {
        const stream = try server.accept(io);
        group.concurrent(io, connectionTask, .{ io, allocator, stream, &map, &mutex }) catch |err| {
            std.log.err("Failed to spawn connection task: {s}", .{@errorName(err)});
            stream.close(io);
        };
    }
}

/// Owns the stream for the lifetime of the connection and adapts
/// `handleConnection` to the `Cancelable!void` signature `Io.Group` requires.
fn connectionTask(io: Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, map: *std.StringHashMap([]const u8), mutex: *std.Io.Mutex) Io.Cancelable!void {
    defer stream.close(io);

    handleConnection(io, allocator, stream, map, mutex) catch |err| {
        std.log.debug("Connection error: {s}", .{@errorName(err)});
    };
}

fn handleConnection(io: Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, map: *std.StringHashMap([]const u8), mutex: *std.Io.Mutex) !void {
    var buffer: [1024]u8 = undefined;

    var reader = stream.reader(io, &buffer);
    const message = (try reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;

    const lock_request = nlock.LockRequest.fromString(message) catch |err| {
        std.log.debug("Failed to parse message: {s}", .{@errorName(err)});
        return err;
    };

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    const lock_name = lock_request.name;
    const lock_value = lock_request.command;

    switch (lock_request.request_type) {
        nlock.LockRequestType.AcquireLock => {
            mutex.lock(io) catch |err| {
                std.log.err("Failed to acquire mutex lock: {s}", .{@errorName(err)});
                return err;
            };
            const existing_lock = map.get(lock_name);
            mutex.unlock(io);
            if (existing_lock) |value| {
                std.log.info("Lock for name '{s}' is already acquired with value {s}", .{ lock_name, value });

                const lock_response = nlock.LockResponse.init(nlock.LockResponseStatus.Busy).toString();

                try nlock.writeLine(&writer.interface, lock_response);
                return error.LockAlreadyAcquired;
            }

            std.log.info("Acquiring lock for name '{s}' (global: {}). Command: {s}", .{ lock_name, lock_request.global, lock_value });

            const lock_name_copy = try allocator.dupe(u8, lock_name);
            mutex.lock(io) catch |err| {
                std.log.err("Failed to acquire mutex lock: {s}", .{@errorName(err)});
                allocator.free(lock_name_copy);
                return err;
            };
            map.put(lock_name_copy, lock_value) catch |err| {
                allocator.free(lock_name_copy);
                return err;
            };
            mutex.unlock(io);

            const lock_response = nlock.LockResponse.init(nlock.LockResponseStatus.Ok).toString();
            try nlock.writeLine(&writer.interface, lock_response);
        },
        else => {
            std.log.debug("Received unexpected request type: {d}", .{lock_request.request_type});
            return error.UnexpectedRequestType;
        },
    }

    // the client executes the command and then sends a release lock request
    const exec_request_message = (try reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
    const exec_request = nlock.LockRequest.fromString(exec_request_message) catch |err| {
        std.log.debug("Failed to parse exec request message: {s}", .{@errorName(err)});
        return err;
    };

    switch (exec_request.request_type) {
        nlock.LockRequestType.ReleaseLock => {
            std.log.info("Releasing lock for name '{s}' (global: {})", .{ exec_request.name, exec_request.global });

            mutex.lock(io) catch |err| {
                std.log.err("Failed to acquire mutex lock: {s}", .{@errorName(err)});
                return err;
            };
            if (map.fetchRemove(exec_request.name)) |entry| {
                mutex.unlock(io);
                allocator.free(entry.key);
                std.log.info("Lock for name '{s}' released successfully.", .{exec_request.name});

                const lock_response = nlock.LockResponse.init(nlock.LockResponseStatus.Ok).toString();
                try nlock.writeLine(&writer.interface, lock_response);
            } else {
                std.log.err("No lock found for name '{s}' to release.", .{exec_request.name});
                // TODO: should this be a Busy response or an error? For now, we will send a Busy response.
                const lock_response = nlock.LockResponse.init(nlock.LockResponseStatus.Busy).toString();
                try nlock.writeLine(&writer.interface, lock_response);
            }
        },
        else => {
            std.log.debug("Received unexpected request type: {d}", .{exec_request.request_type});
            return error.UnexpectedRequestType;
        },
    }
}
