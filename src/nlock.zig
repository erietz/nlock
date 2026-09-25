const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        switch (err) {
            error.InvalidArguments => {
                const usage = nlock.usage();
                std.debug.print("{s}", .{usage});
            },
            error.LockAlreadyAcquired => {
                std.debug.print("Lock is already acquired by another process.\n", .{});
            },
            else => {
                std.debug.print("An unexpected error occurred: {s}\n", .{@errorName(err)});
            },
        }
        std.process.exit(1);
    };
}

pub fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try nlock.Options.parseArgs(args);
    const command_str = std.mem.join(init.arena.allocator(), " ", options.command) catch {
        std.log.err("Failed to join command arguments", .{});
        return error.InvalidArguments;
    };
    std.debug.print("Options: name={s}, global={}, command={s}.\n", .{ options.name, options.global, command_str });

    const address = try std.Io.net.UnixAddress.init(nlock.SOCKET_PATH);
    const stream = try address.connect(init.io);
    defer stream.close(init.io);

    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(init.io, &buffer);

    const message = nlock.LockRequest
        .init(nlock.LockRequestType.AcquireLock, options.name, options.global, command_str)
        .toString();

    try nlock.writeLine(&writer.interface, message);

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(init.io, &read_buffer);
    const response_message = (try reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;

    const lockResponse = nlock.LockResponse.fromString(response_message) catch |err| {
        std.debug.print("Failed to parse response: {s}\n", .{@errorName(err)});
        return err;
    };

    if (lockResponse.status == nlock.LockResponseStatus.Busy) {
        return error.LockAlreadyAcquired;
    } else if (lockResponse.status == nlock.LockResponseStatus.Ok) {
        std.debug.print("Lock acquired successfully. Executing command... {s}\n", .{command_str});
        try runCommand(init.io, options.command);

        const release_message = nlock.LockRequest
            .init(nlock.LockRequestType.ReleaseLock, options.name, options.global, command_str)
            .toString();

        try nlock.writeLine(&writer.interface, release_message);

        const release_response_message = (try reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
        const releaseResponse = nlock.LockResponse.fromString(release_response_message) catch |err| {
            std.debug.print("Failed to parse release response: {s}\n", .{@errorName(err)});
            return err;
        };
        if (releaseResponse.status == nlock.LockResponseStatus.Ok) {
            std.debug.print("Lock released successfully.\n", .{});
        } else {
            std.debug.print("Failed to release lock. Status: {d}\n", .{releaseResponse.status});
            return error.LockReleaseFailed;
        }
    } else {
        std.debug.print("Received unknown lock response status.\n", .{});
        return error.UnknownLockResponse;
    }
}

pub fn runCommand(io: Io, command: []const []const u8) !void {
    const spawnOptions: std.process.SpawnOptions = .{
        .argv = command,
    };

    var child = std.process.spawn(io, spawnOptions) catch |err| {
        std.debug.print("Failed to spawn command: {s}\n", .{@errorName(err)});
        return err;
    };

    const term = child.wait(io) catch |err| {
        std.debug.print("Failed to wait for command: {s}\n", .{@errorName(err)});
        return err;
    };

    switch (term) {
        .exited => {
            std.debug.print("Command exited with code: {d}\n", .{term.exited});
        },
        .signal => {
            std.debug.print("Command terminated by signal: {d}\n", .{term.signal});
        },
        .stopped => {
            std.debug.print("Command stopped by signal: {d}\n", .{term.signal});
        },
        .unknown => {
            std.debug.print("Command terminated with unknown status.\n", .{});
        },
    }
}

pub fn writeToStdout(init: std.process.Init) !void {
    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try nlock.printAnotherMessage(stdout_writer);

    try stdout_writer.flush(); // Don't forget to flush!
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
