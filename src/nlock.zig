// TODO: Need to handle ctrl-c and other signals to release the lock properly
// TODO: Current implementation is non-blocking, but blocking should be the default
//       and non-blocking should be put behind -n or --non-blocking flag

const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const log = nlock.logger.log;
const ll = nlock.logger.LogLevel;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        switch (err) {
            error.InvalidArguments => {
                std.debug.print("{s}", .{nlock.cli.USAGE});
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
    nlock.logger.init(nlock.logger.getLogLevel(init.environ_map));
    nlock.printer.init(init.io);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    switch (try nlock.cli.Command.parseArgs(args)) {
        .run => |options| try runLocked(init, options),
        .list => try runList(init),
    }
}

pub fn runLocked(init: std.process.Init, options: nlock.cli.RunOptions) !void {
    const address = try std.Io.net.UnixAddress.init(nlock.getSocketPath(init.environ_map));
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
        log(ll.Debug, "Lock acquired successfully. Running command", .{});
        runCommand(init.io, options.command) catch |err| {
            // Even if the command fails, we should still attempt to release
            // the lock so no return error here, just log the error
            std.debug.print("Failed to run command: {s}\n", .{@errorName(err)});
        };

        log(ll.Debug, "Command finished. Releasing lock: {s}", .{options.name});
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
    const address = try std.Io.net.UnixAddress.init(nlock.getSocketPath(init.environ_map));
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

    // // Print a header for the table of the list of locks
    // nlock.printer.print("{s:<12} {s:<8} {s:<80}\n", .{ "NAME", "GLOBAL", "CMD" }) catch |err| {
    //     log(ll.Error, "Failed to print lock list header: {s}", .{@errorName(err)});
    // };
    //
    // // Print the list of locks received from the server in a tabular format
    // while (true) {
    //     const response_message = (try reader.interface.takeDelimiter('\n')) orelse break;
    //     log(ll.Debug, "Received lock response: {s}", .{response_message});
    //
    //     var lock_request = try nlock.LockRequest.fromJson(response_message, allocator);
    //     defer lock_request.deinit(allocator);
    //
    //     // nlock.printer.print("Lock Name: {s}, Global: {}, Command: {s}\n", .{
    //     //     lock_request.name,
    //     //     lock_request.global,
    //     //     lock_request.command,
    //     // }) catch |err| {
    //     //     log(ll.Error, "Failed to print lock info: {s}", .{@errorName(err)});
    //     // };
    //
    //     nlock.printer.print("{s:<12} {:<8} {s:<80}\n", .{
    //         lock_request.name,
    //         lock_request.global,
    //         lock_request.command,
    //     }) catch |err| {
    //         log(ll.Error, "Failed to print lock info: {s}", .{@errorName(err)});
    //     };
    // }

    var lock_requests = try readLockRequests(&reader.interface, allocator);
    defer {
        for (lock_requests.items) |*lock_request| lock_request.deinit(allocator);
        lock_requests.deinit(allocator);
    }

    try printLockRequestTable(lock_requests);
}

fn readLockRequests(
    reader: *Io.Reader,
    allocator: std.mem.Allocator,
) !std.ArrayList(nlock.LockRequest) {
    var lock_requests: std.ArrayList(nlock.LockRequest) = .empty;
    errdefer {
        for (lock_requests.items) |*lock_request| lock_request.deinit(allocator);
        lock_requests.deinit(allocator);
    }
    while (true) {
        const response_message = try (reader.takeDelimiter('\n')) orelse break;
        log(ll.Debug, "Received lock request: {s}", .{response_message});

        var lock_request = try nlock.LockRequest.fromJson(response_message, allocator);
        errdefer lock_request.deinit(allocator);

        try lock_requests.append(allocator, lock_request);
    }
    return lock_requests;
}

fn printLockRequestTable(lock_requests: std.ArrayList(nlock.LockRequest)) !void {
    var max_name_len: usize = "NAME".len;
    var max_cmd_len: usize = "CMD".len;
    for (lock_requests.items) |lock_request| {
        max_name_len = @max(max_name_len, lock_request.name.len);
        max_cmd_len = @max(max_cmd_len, lock_request.command.len);
    }

    nlock.printer.print("| {[name]s:<[name_width]} | {[global]s:<[global_width]} | {[cmd]s:<[cmd_width]} |\n", .{
        .name = "NAME",
        .name_width = max_name_len,
        .global = "GLOBAL",
        .global_width = 8,
        .cmd = "CMD",
        .cmd_width = max_cmd_len,
    }) catch |err| {
        log(ll.Error, "Failed to print lock list header: {s}", .{@errorName(err)});
    };

    for (lock_requests.items) |lock_request| {
        nlock.printer.print("| {[name]s:<[name_width]} | {[global]s:<[global_width]} | {[cmd]s:<[cmd_width]} |\n", .{
            .name = lock_request.name,
            .name_width = max_name_len,
            .global = if (lock_request.global) "true" else "false",
            .global_width = 8,
            .cmd = lock_request.command,
            .cmd_width = max_cmd_len,
        }) catch |err| {
            log(ll.Error, "Failed to print lock info: {s}", .{@errorName(err)});
        };
    }
}

pub fn acquireLock(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    reader: *Io.Reader,
    options: nlock.cli.RunOptions,
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
    log(ll.Debug, "Received lock response: {s}", .{response_message});
    const lock_response = try nlock.LockResponse.fromJson(response_message, allocator);
    return lock_response.status;
}

pub fn releaseLock(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    reader: *Io.Reader,
    options: nlock.cli.RunOptions,
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
    log(ll.Debug, "Received release lock response: {s}", .{release_response_message});

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
            log(ll.Debug, "Process exited with code: {d}", .{term.exited});
        },
        .signal => {
            log(ll.Debug, "Process terminated by signal: {d}", .{term.signal});
        },
        .stopped => {
            log(ll.Debug, "Process stopped by signal: {d}", .{term.signal});
        },
        .unknown => {
            log(ll.Debug, "Process terminated with unknown status.", .{});
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
