// TODO: Need to handle ctrl-c and other signals to release the lock properly

const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const log = nlock.logger.log;
const ll = nlock.logger.LogLevel;

const Context = struct {
    io: Io,
    reader: *Io.Reader,
    writer: *Io.Writer,
    allocator: std.mem.Allocator,
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        switch (err) {
            error.InvalidArguments => {
                std.debug.print("{s}", .{nlock.cli.USAGE});
            },
            error.LockAlreadyAcquired => {
                std.debug.print("Lock is already acquired by another process.\n", .{});
            },
            error.LockServerNotRunning => {
                std.debug.print("Lock server is not running. Please start the lock server first.\n", .{});
            },
            error.LockAcquireTimeout => {
                std.debug.print("Failed to acquire lock within the specified timeout.\n", .{});
            },
            error.LockReleaseFailed => {
                std.debug.print("Failed to release lock. Please check the lock server logs for more details.\n", .{});
            },
            else => {
                std.debug.print("An unexpected error occurred: {s}\n", .{@errorName(err)});
            },
        }
        std.process.exit(1);
    };
}

pub fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    const command = try nlock.cli.Command.parseArgs(args);

    nlock.logger.init(nlock.logger.getLogLevel(init.environ_map));
    nlock.printer.init(init.io);

    const address = try std.Io.net.UnixAddress.init(nlock.getSocketPath(init.environ_map));
    const stream = address.connect(init.io) catch |err| {
        log(ll.Error, "Failed to connect to lock server: {s}", .{@errorName(err)});
        return error.LockServerNotRunning;
    };
    defer stream.close(init.io);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(init.io, &write_buffer);

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(init.io, &read_buffer);

    const ctx = Context{
        .io = init.io,
        .reader = &reader.interface,
        .writer = &writer.interface,
        .allocator = init.gpa,
    };

    switch (command) {
        .run => |options| try runLocked(ctx, options),
        .list => try runList(ctx),
    }
}

pub fn runLocked(ctx: Context, options: nlock.cli.RunOptions) !void {
    const acquire_status = try acquireLock(
        ctx.allocator,
        ctx.writer,
        ctx.reader,
        options,
    );

    switch (acquire_status) {
        nlock.LockResponseStatus.Ok => {
            log(ll.Debug, "Lock acquired successfully. Running command", .{});
            runCommand(ctx.io, options.command) catch |err| {
                // Even if the command fails, we should still attempt to release
                // the lock so no return error here, just log the error
                std.debug.print("Failed to run command: {s}\n", .{@errorName(err)});
            };
            log(ll.Debug, "Command finished. Releasing lock: {s}", .{options.name});

            const release_status = try releaseLock(
                ctx.allocator,
                ctx.writer,
                ctx.reader,
                options,
            );

            switch (release_status) {
                nlock.LockResponseStatus.Ok => {
                    log(ll.Debug, "Lock released successfully", .{});
                },
                else => {
                    log(ll.Error, "Failed to release lock. Status: {d}", .{release_status});
                    return error.LockReleaseFailed;
                },
            }
        },
        nlock.LockResponseStatus.Busy => {
            return error.LockAlreadyAcquired;
        },
        nlock.LockResponseStatus.Timeout => {
            return error.LockAcquireTimeout;
        },
    }
}

pub fn runList(ctx: Context) !void {
    const list_message = try nlock.LockRequest
        .init(nlock.LockRequestType.ListLocks, "", false, false, null, "")
        .toJson(ctx.allocator);
    defer ctx.allocator.free(list_message);

    try nlock.writeLine(ctx.writer, list_message);

    var lock_infos = try readLockInfos(ctx.reader, ctx.allocator);
    defer {
        for (lock_infos.items) |*lock_info| lock_info.deinit(ctx.allocator);
        lock_infos.deinit(ctx.allocator);
    }

    try printLockInfoTable(ctx.allocator, lock_infos);
}

fn readLockInfos(
    reader: *Io.Reader,
    allocator: std.mem.Allocator,
) !std.ArrayList(nlock.LockInfo) {
    var lock_infos: std.ArrayList(nlock.LockInfo) = .empty;
    errdefer {
        for (lock_infos.items) |*lock_info| lock_info.deinit(allocator);
        lock_infos.deinit(allocator);
    }
    while (true) {
        const response_message = try (reader.takeDelimiter('\n')) orelse break;
        log(ll.Debug, "Received lock info: {s}", .{response_message});

        var lock_info = try nlock.LockInfo.fromJson(response_message, allocator);
        errdefer lock_info.deinit(allocator);

        try lock_infos.append(allocator, lock_info);
    }
    return lock_infos;
}

fn printLockInfoTable(allocator: std.mem.Allocator, lock_infos: std.ArrayList(nlock.LockInfo)) !void {
    // Resolve each uid to a username up front so the column can be sized.
    // getpwuid returns static storage, so each name is copied.
    const users = try allocator.alloc([]const u8, lock_infos.items.len);
    var users_len: usize = 0;
    defer {
        for (users[0..users_len]) |user| allocator.free(user);
        allocator.free(users);
    }
    for (lock_infos.items) |lock_info| {
        var uid_buf: [16]u8 = undefined;
        users[users_len] = try allocator.dupe(u8, nlock.peer.userName(&uid_buf, lock_info.uid));
        users_len += 1;
    }

    var max_name_len: usize = "NAME".len;
    var max_user_len: usize = "USER".len;
    var max_cmd_len: usize = "CMD".len;
    for (lock_infos.items, users) |lock_info, user| {
        max_name_len = @max(max_name_len, lock_info.name.len);
        max_user_len = @max(max_user_len, user.len);
        max_cmd_len = @max(max_cmd_len, lock_info.command.len);
    }

    const row_fmt = "| {[name]s:<[name_width]} | {[user]s:<[user_width]} | {[global]s:<[global_width]} | {[cmd]s:<[cmd_width]} |\n";

    nlock.printer.print(row_fmt, .{
        .name = "NAME",
        .name_width = max_name_len,
        .user = "USER",
        .user_width = max_user_len,
        .global = "GLOBAL",
        .global_width = 8,
        .cmd = "CMD",
        .cmd_width = max_cmd_len,
    }) catch |err| {
        log(ll.Error, "Failed to print lock list header: {s}", .{@errorName(err)});
    };

    for (lock_infos.items, users) |lock_info, user| {
        nlock.printer.print(row_fmt, .{
            .name = lock_info.name,
            .name_width = max_name_len,
            .user = user,
            .user_width = max_user_len,
            .global = if (lock_info.global) "true" else "false",
            .global_width = 8,
            .cmd = lock_info.command,
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
        .init(
            nlock.LockRequestType.AcquireLock,
            options.name,
            options.global,
            options.nonblock,
            options.timeout,
            command_str,
        )
        .toJson(allocator);
    defer allocator.free(message);

    try nlock.writeLine(writer, message);

    const response_message = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
    log(ll.Debug, "Received lock response: {s}", .{response_message});
    const lock_response = try nlock.LockResponse.fromJson(response_message, allocator);
    return lock_response.status;
}

/// Releases the lock with the given name. Returns the status of the release
/// operation.
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
        .init(
            nlock.LockRequestType.ReleaseLock,
            options.name,
            options.global,
            options.nonblock,
            options.timeout,
            command_str,
        )
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
