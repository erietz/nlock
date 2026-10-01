// TODO: Need to handle ctrl-c and other signals to release the lock properly
// TODO: Current implementation is non-blocking, but blocking should be the default
//       and non-blocking should be put behind -n or --non-blocking flag

const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const log = nlock.log.log;
const ll = nlock.log.LogLevel;

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
    const log_level_str = init.environ_map.get(nlock.log.ENV_NLOCK_LOG_LEVEL);
    const log_level = std.meta.stringToEnum(
        nlock.log.LogLevel,
        log_level_str orelse @tagName(ll.None),
    ) orelse ll.None;
    nlock.log.init(log_level);

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    switch (try nlock.Command.parseArgs(args)) {
        .run => |options| try runLocked(init, options),
        .list => try runList(init),
    }
}

pub fn runLocked(init: std.process.Init, options: nlock.RunOptions) !void {
    const address = try std.Io.net.UnixAddress.init(nlock.socketPath(init.environ_map));
    const stream = try address.connect(init.io);
    defer stream.close(init.io);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(init.io, &write_buffer);

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(init.io, &read_buffer);

    const acquireStatus = try acquireLock(
        init.arena.allocator(),
        &writer.interface,
        &reader.interface,
        options,
    );

    if (acquireStatus == nlock.LockResponseStatus.Ok) {
        log(ll.Debug, "Lock acquired successfully. Running command\n", .{});
        runCommand(init.io, options.command) catch |err| {
            // Even if the command fails, we should still attempt to release
            // the lock so no return error here, just log the error
            std.debug.print("Failed to run command: {s}\n", .{@errorName(err)});
        };

        log(ll.Debug, "Command finished. Releasing lock: {s}\n", .{options.name});
        const releaseStatus = try releaseLock(
            init.arena.allocator(),
            &writer.interface,
            &reader.interface,
            options,
        );

        if (releaseStatus != nlock.LockResponseStatus.Ok) {
            std.debug.print("Failed to release lock. Status: {d}\n", .{releaseStatus});
            return error.LockReleaseFailed;
        }
    } else if (acquireStatus == nlock.LockResponseStatus.Busy) {
        return error.LockAlreadyAcquired;
    } else {
        std.debug.print("Received unknown lock response status.\n", .{});
        return error.UnknownLockResponse;
    }
}

pub fn runList(init: std.process.Init) !void {
    const address = try std.Io.net.UnixAddress.init(nlock.socketPath(init.environ_map));
    const stream = try address.connect(init.io);
    defer stream.close(init.io);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(init.io, &write_buffer);

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(init.io, &read_buffer);

    const allocator = init.gpa;
    const list_message = try nlock.LockRequest
        .init(nlock.LockRequestType.ListLocks, "", false, "")
        .toJson(allocator);
    defer allocator.free(list_message);

    try nlock.writeLine(&writer.interface, list_message);

    while (true) {
        const response_message = (try reader.interface.takeDelimiter('\n')) orelse break;
        log(ll.Debug, "Received lock response: {s}\n", .{response_message});

        const parsed_lock_request = try nlock.LockRequest.fromJson(response_message, allocator);
        defer parsed_lock_request.deinit();
        const lock_request = parsed_lock_request.value;

        // TODO: this should be stdout output not log to stderr
        log(ll.Warn, "Lock Name: {s}, Global: {}, Command: {s}", .{
            lock_request.name,
            lock_request.global,
            lock_request.command,
        });
    }
}

pub fn acquireLock(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    reader: *Io.Reader,
    options: nlock.RunOptions,
) !nlock.LockResponseStatus {
    const command_str = std.mem.join(allocator, " ", options.command) catch {
        log(ll.Error, "Failed to join command arguments", .{});
        return error.InvalidArguments;
    };
    defer allocator.free(command_str);
    const message = try nlock.LockRequest
        .init(nlock.LockRequestType.AcquireLock, options.name, options.global, command_str)
        .toJson(allocator);
    defer allocator.free(message);

    try nlock.writeLine(writer, message);

    const response_message = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
    log(ll.Debug, "Received lock response: {s}\n", .{response_message});
    const lock_response = try nlock.LockResponse.fromJson(response_message, allocator);
    return lock_response.status;
}

pub fn releaseLock(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    reader: *Io.Reader,
    options: nlock.RunOptions,
) !nlock.LockResponseStatus {
    const command_str = std.mem.join(allocator, " ", options.command) catch {
        log(ll.Error, "Failed to join command arguments", .{});
        return error.InvalidArguments;
    };
    defer allocator.free(command_str);
    const release_message = try nlock.LockRequest
        .init(nlock.LockRequestType.ReleaseLock, options.name, options.global, command_str)
        .toJson(allocator);
    defer allocator.free(release_message);

    try nlock.writeLine(writer, release_message);

    const release_response_message = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
    log(ll.Debug, "Received release lock response: {s}\n", .{release_response_message});

    const release_response = try nlock.LockResponse.fromJson(release_response_message, allocator);
    return release_response.status;
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
            log(ll.Debug, "Process exited with code: {d}\n", .{term.exited});
        },
        .signal => {
            log(ll.Debug, "Process terminated by signal: {d}\n", .{term.signal});
        },
        .stopped => {
            log(ll.Debug, "Process stopped by signal: {d}\n", .{term.signal});
        },
        .unknown => {
            log(ll.Debug, "Process terminated with unknown status.\n", .{});
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
