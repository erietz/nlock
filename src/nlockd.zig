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
    var mapWrap = nlock.ThreadSafeHashMap([]const u8, []const u8).init(io, allocator);
    defer {
        mapWrap.deinit();
    }

    while (true) {
        const stream = try server.accept(io);
        group.concurrent(io, connectionTask, .{
            io,
            allocator,
            stream,
            &mapWrap,
        }) catch |err| {
            std.log.err("Failed to spawn connection task: {s}", .{@errorName(err)});
            stream.close(io);
        };
    }
}

/// Owns the stream for the lifetime of the connection and adapts
/// `handleConnection` to the `Cancelable!void` signature `Io.Group` requires.
fn connectionTask(
    io: Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    map: *nlock.ThreadSafeHashMap([]const u8, []const u8),
) Io.Cancelable!void {
    defer stream.close(io);

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
    map: *nlock.ThreadSafeHashMap([]const u8, []const u8),
) !void {
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    // Client current follows this simple ACQUIRE -> EXECUTE -> RELEASE
    // pattern, but this will change when implementing the `list` command, for
    // example.

    // Read the acquire request message from the client
    const acquireReq = try readRequest(&reader.interface);
    switch (acquireReq.request_type) {
        nlock.LockRequestType.AcquireLock => {
            handleAcquireLockRequest(
                allocator,
                acquireReq,
                map,
                &writer.interface,
            ) catch |err| {
                std.log.debug("Failed to handle acquire lock request: {s}", .{@errorName(err)});
                return err;
            };
        },
        else => {
            std.log.debug("Received unexpected request type: {d}", .{acquireReq.request_type});
            return error.UnexpectedRequestType;
        },
    }

    // The client executes the command and then sends a release lock request
    const releaseReq = try readRequest(&reader.interface);
    switch (releaseReq.request_type) {
        nlock.LockRequestType.ReleaseLock => {
            handleReleaseLockRequest(
                allocator,
                releaseReq,
                map,
                &writer.interface,
            ) catch |err| {
                std.log.debug("Failed to handle release lock request: {s}", .{@errorName(err)});
                return err;
            };
        },
        else => {
            std.log.debug("Received unexpected request type: {d}", .{releaseReq.request_type});
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
    allocator: std.mem.Allocator,
    lock_request: nlock.LockRequest,
    map: *nlock.ThreadSafeHashMap([]const u8, []const u8),
    writer: *Io.Writer,
) !void {
    const existing_lock = map.get(lock_request.name);
    if (existing_lock) |value| {
        std.log.info("Lock for name '{s}' is already acquired with value {s}", .{
            lock_request.name,
            value,
        });

        const lock_response = nlock.LockResponse.init(nlock.LockResponseStatus.Busy).toString();

        try nlock.writeLine(writer, lock_response);
        return error.LockAlreadyAcquired;
    }

    std.log.info("Acquiring lock for name '{s}' (global: {}). Command: {s}", .{
        lock_request.name,
        lock_request.global,
        lock_request.command,
    });

    const lock_name_copy = try allocator.dupe(u8, lock_request.name);
    map.put(lock_name_copy, lock_request.command) catch |err| {
        allocator.free(lock_name_copy);
        return err;
    };

    const lock_response = nlock.LockResponse.init(nlock.LockResponseStatus.Ok).toString();
    try nlock.writeLine(writer, lock_response);
}

fn handleReleaseLockRequest(
    allocator: std.mem.Allocator,
    lock_request: nlock.LockRequest,
    map: *nlock.ThreadSafeHashMap([]const u8, []const u8),
    writer: *Io.Writer,
) !void {
    std.log.info("Releasing lock for name '{s}' (global: {})", .{
        lock_request.name,
        lock_request.global,
    });

    if (map.fetchRemove(lock_request.name)) |entry| {
        allocator.free(entry.key);
        std.log.info("Lock for name '{s}' released successfully.", .{lock_request.name});

        const lock_response = nlock.LockResponse.init(nlock.LockResponseStatus.Ok).toString();
        try nlock.writeLine(writer, lock_response);
    } else {
        std.log.err("No lock found for name '{s}' to release.", .{lock_request.name});
        // TODO: should this be a Busy response or an error? For now, we will send a Busy response.
        const lock_response = nlock.LockResponse.init(nlock.LockResponseStatus.Busy).toString();
        try nlock.writeLine(writer, lock_response);
    }
}
