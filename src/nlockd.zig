const std = @import("std");
const Io = std.Io;
const shared = @import("shared");

pub fn main(init: std.process.Init) !void {
    try run(init);
}

pub fn run(init: std.process.Init) !void {
    // Start the server to listen for incoming connections
    try runServer(init);
}

pub fn runServer(init: std.process.Init) !void {
    const io = init.io;

    std.Io.Dir.cwd().deleteFile(io, shared.SOCKET_PATH) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(io, shared.SOCKET_PATH) catch {};

    const address = try std.Io.net.UnixAddress.init(shared.SOCKET_PATH);

    var server = try address.listen(io, .{});
    defer server.deinit(io);
    std.debug.print("Server listening on {s}\n", .{shared.SOCKET_PATH});

    const allocator = init.gpa;
    var map: std.StringHashMap([]const u8) = .init(allocator);
    defer {
        var it = map.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        map.deinit();
    }

    while (true) {
        const stream = try server.accept(io);
        defer stream.close(io);

        handleConnection(io, allocator, stream, &map) catch |err| {
            std.debug.print("Connection error: {s}\n", .{@errorName(err)});
        };
    }
}

fn handleConnection(io: Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, map: *std.StringHashMap([]const u8)) !void {
    var buffer: [1024]u8 = undefined;

    var reader = stream.reader(io, &buffer);
    const message = try reader.interface.takeDelimiterExclusive('\n');

    const lock_request = shared.LockRequest.fromString(message) catch |err| {
        std.debug.print("Failed to parse message: {s}\n", .{@errorName(err)});
        return err;
    };

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    const lock_name = lock_request.name;

    switch (lock_request.request_type) {
        shared.LockRequestType.AcquireLock => {
            const existing_lock = map.get(lock_name);
            if (existing_lock) |value| {
                std.debug.print("Lock for name '{s}' is already acquired with value {s}", .{ lock_name, value });

                const lock_response = shared.LockResponse.init(shared.LockResponseStatus.Busy).toString();

                try writer.interface.writeAll(lock_response);
                try writer.interface.writeAll("\n");
                try writer.interface.flush();
                return error.LockAlreadyAcquired;
            }
            std.debug.print("Acquiring lock for name '{s}' (global: {})\n", .{ lock_name, lock_request.global });

            const lock_name_copy = try allocator.dupe(u8, lock_name);
            map.put(lock_name_copy, "lock value") catch |err| {
                allocator.free(lock_name_copy);
                return err;
            };

            const lock_response = shared.LockResponse.init(shared.LockResponseStatus.Ok).toString();

            try writer.interface.writeAll(lock_response);
            try writer.interface.writeAll("\n");
            try writer.interface.flush();
        },
        shared.LockRequestType.ReleaseLock => {
            std.debug.print("Releasing lock for name '{s}' (global: {})\n", .{ lock_name, lock_request.global });

            if (map.fetchRemove(lock_name)) |entry| {
                allocator.free(entry.key);
                std.debug.print("Lock for name '{s}' released successfully.\n", .{lock_name});
            } else {
                std.debug.print("No lock found for name '{s}' to release.\n", .{lock_name});
            }
        },
    }
}
