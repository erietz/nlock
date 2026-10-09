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
            error.UntrustedLockServer => {
                std.debug.print("Lock server socket belongs to another user. Refusing to use it.\n", .{});
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

    const socket_path = try nlock.getSocketPath(init.gpa, init.environ_map);
    defer init.gpa.free(socket_path);
    log(ll.Debug, "Connecting to lock server at {s}", .{socket_path});

    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = address.connect(init.io) catch |err| {
        log(ll.Error, "Failed to connect to lock server: {s}", .{@errorName(err)});
        return error.LockServerNotRunning;
    };
    defer stream.close(init.io);
    try verifyServer(stream);

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
        .list => |options| try runList(ctx, options),
    }
}

/// Refuses to talk to a daemon run by another user (other than root), in case
/// someone else created a socket at our path to impersonate it.
fn verifyServer(stream: std.Io.net.Stream) !void {
    const server = try nlock.peer.peerCredentials(stream);
    const uid = std.c.getuid();
    if (server.uid != uid and server.uid != 0) {
        log(ll.Error, "Lock server is run by uid {d}, expected {d} or root", .{ server.uid, uid });
        return error.UntrustedLockServer;
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
            // TODO: nlock exits 0 even when the command fails or is killed
            // by a signal. Propagate the command's exit status instead.
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

pub fn runList(ctx: Context, options: nlock.cli.ListOptions) !void {
    const list_message = try nlock.LockRequest
        .init(nlock.LockRequestType.ListLocks, "", false, false, null, "")
        .toJson(ctx.allocator);
    defer ctx.allocator.free(list_message);

    try nlock.writeLine(ctx.writer, list_message);

    // Everything below is short-lived, so free it all at once.
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lock_infos = try readLockInfos(ctx.reader, arena);
    // The daemon walks a hash map, so impose a stable order.
    std.mem.sort(nlock.LockInfo, lock_infos.items, {}, lockInfoLessThan);

    const output = if (options.json)
        try formatLockInfoJson(arena, lock_infos.items)
    else if (options.quiet)
        try formatLockNames(arena, lock_infos.items)
    else
        try formatLockInfoTable(arena, lock_infos.items, options.header, nowSeconds(ctx.io));

    try nlock.printer.print("{s}", .{output});
}

fn lockInfoLessThan(_: void, a: nlock.LockInfo, b: nlock.LockInfo) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn nowSeconds(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds();
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

/// Resolves `uid` to a username, or its decimal form if it has no passwd
/// entry. getpwuid returns static storage, so the name is copied.
fn userNameAlloc(allocator: std.mem.Allocator, uid: u32) ![]const u8 {
    var uid_buf: [16]u8 = undefined;
    return allocator.dupe(u8, nlock.peer.userName(&uid_buf, uid));
}

/// `nlock list --json`: one JSON object per lock, one per line. Unlike the
/// table, this round-trips arbitrary names and commands exactly.
fn formatLockInfoJson(allocator: std.mem.Allocator, lock_infos: []const nlock.LockInfo) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lock_infos) |lock_info| {
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .name = lock_info.name,
            .user = try userNameAlloc(allocator, lock_info.uid),
            .uid = lock_info.uid,
            .pid = lock_info.pid,
            .global = lock_info.global,
            .waiters = lock_info.waiters,
            .acquired_at = lock_info.acquired_at,
            .command = lock_info.command,
        }, .{ .whitespace = .minified });
        try out.appendSlice(allocator, json);
        try out.append(allocator, '\n');
    }
    return out.items;
}

/// `nlock list --quiet`: lock names only, one per line.
fn formatLockNames(allocator: std.mem.Allocator, lock_infos: []const nlock.LockInfo) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lock_infos) |lock_info| {
        try appendEscaped(allocator, &out, lock_info.name);
        try out.append(allocator, '\n');
    }
    return out.items;
}

const Column = struct {
    title: []const u8,
    align_right: bool = false,
};

/// CMD is last because it is the only column that may contain spaces, so
/// every other column can be split on whitespace.
const columns = [_]Column{
    .{ .title = "NAME" },
    .{ .title = "USER" },
    .{ .title = "PID", .align_right = true },
    .{ .title = "SCOPE" },
    .{ .title = "ELAPSED", .align_right = true },
    .{ .title = "WAITERS", .align_right = true },
    .{ .title = "CMD" },
};

const column_separator = "  ";

/// Default `nlock list` output: whitespace-aligned columns with an optional
/// header row, in the style of `ps`.
fn formatLockInfoTable(
    allocator: std.mem.Allocator,
    lock_infos: []const nlock.LockInfo,
    header: bool,
    now: i64,
) ![]const u8 {
    const Row = [columns.len][]const u8;

    var rows: std.ArrayList(Row) = .empty;
    if (header) {
        var row: Row = undefined;
        for (columns, &row) |column, *cell| cell.* = column.title;
        try rows.append(allocator, row);
    }
    for (lock_infos) |lock_info| {
        var name: std.ArrayList(u8) = .empty;
        try appendEscaped(allocator, &name, lock_info.name);
        var command: std.ArrayList(u8) = .empty;
        try appendEscaped(allocator, &command, lock_info.command);

        try rows.append(allocator, .{
            name.items,
            try userNameAlloc(allocator, lock_info.uid),
            if (lock_info.pid > 0) try std.fmt.allocPrint(allocator, "{d}", .{lock_info.pid}) else "-",
            if (lock_info.global) "global" else "user",
            try formatElapsed(allocator, now - lock_info.acquired_at),
            try std.fmt.allocPrint(allocator, "{d}", .{lock_info.waiters}),
            command.items,
        });
    }

    var widths = [_]usize{0} ** columns.len;
    for (rows.items) |row| {
        for (row, &widths) |cell, *width| width.* = @max(width.*, cell.len);
    }

    var out: std.ArrayList(u8) = .empty;
    for (rows.items) |row| {
        for (columns, row, widths, 0..) |column, cell, width, i| {
            const last = i == columns.len - 1;
            if (last) {
                // No padding, so lines never end in whitespace.
                try out.appendSlice(allocator, cell);
                try out.append(allocator, '\n');
            } else if (column.align_right) {
                try out.appendNTimes(allocator, ' ', width - cell.len);
                try out.appendSlice(allocator, cell);
                try out.appendSlice(allocator, column_separator);
            } else {
                try out.appendSlice(allocator, cell);
                try out.appendNTimes(allocator, ' ', width - cell.len);
                try out.appendSlice(allocator, column_separator);
            }
        }
    }
    return out.items;
}

/// Formats a duration like `ps -o etime`: `[[dd-]hh:]mm:ss`.
fn formatElapsed(allocator: std.mem.Allocator, seconds: i64) ![]const u8 {
    // Clamp in case the daemon's clock and ours disagree.
    const total: u64 = @intCast(@max(seconds, 0));
    const days = total / std.time.s_per_day;
    const hours = total / std.time.s_per_hour % 24;
    const minutes = total / std.time.s_per_min % 60;
    const secs = total % 60;
    if (days > 0) {
        return std.fmt.allocPrint(allocator, "{d}-{d:0>2}:{d:0>2}:{d:0>2}", .{ days, hours, minutes, secs });
    } else if (hours > 0) {
        return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, secs });
    }
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{ minutes, secs });
}

/// Appends `s` with control characters escaped (`\n`, `\t`, `\r`, `\xNN`)
/// so that each lock always occupies exactly one line.
fn appendEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        0...8, 11, 12, 14...31, 127 => try out.print(allocator, "\\x{x:0>2}", .{ch}),
        else => try out.append(allocator, ch),
    };
}

test "formatElapsed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("00:00", try formatElapsed(arena, -5));
    try std.testing.expectEqualStrings("00:07", try formatElapsed(arena, 7));
    try std.testing.expectEqualStrings("02:05", try formatElapsed(arena, 125));
    try std.testing.expectEqualStrings("01:00:00", try formatElapsed(arena, 3600));
    try std.testing.expectEqualStrings("3-04:05:06", try formatElapsed(arena, 3 * 86400 + 4 * 3600 + 5 * 60 + 6));
}

test "appendEscaped keeps output on one line" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendEscaped(std.testing.allocator, &out, "echo a\tb\nc\x1b d\\e");
    try std.testing.expectEqualStrings("echo a\\tb\\nc\\x1b d\\e", out.items);
}

test "formatLockInfoTable aligns columns and leaves CMD last and unpadded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lock_infos = [_]nlock.LockInfo{
        .{ .name = "build", .uid = 4000000000, .pid = 123, .global = false, .waiters = 0, .acquired_at = 1000, .command = "make -j8" },
        .{ .name = "deploy-prod", .uid = 4000000001, .pid = 0, .global = true, .waiters = 12, .acquired_at = 0, .command = "sh -c 'a\nb'" },
    };
    const table = try formatLockInfoTable(arena, &lock_infos, true, 1065);
    try std.testing.expectEqualStrings(
        \\NAME         USER        PID  SCOPE   ELAPSED  WAITERS  CMD
        \\build        4000000000  123  user      01:05        0  make -j8
        \\deploy-prod  4000000001    -  global    17:45       12  sh -c 'a\nb'
        \\
    , table);

    const no_header = try formatLockInfoTable(arena, lock_infos[0..1], false, 1065);
    try std.testing.expectEqualStrings("build  4000000000  123  user  01:05  0  make -j8\n", no_header);
}

test "formatLockInfoTable prints only the header when no locks are held" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "NAME  USER  PID  SCOPE  ELAPSED  WAITERS  CMD\n",
        try formatLockInfoTable(arena, &.{}, true, 0),
    );
    try std.testing.expectEqualStrings("", try formatLockInfoTable(arena, &.{}, false, 0));
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

/// Handler which does absolutely nothing installed while the command runs. A
/// handler rather than SIG_IGN, because ignored signals are inherited across
/// exec while handlers are reset to the default, so the child still gets the
/// usual behavior.
fn ignoreSignal(_: std.posix.SIG) callconv(.c) void {}

/// Signals the terminal sends to the whole foreground process group. The
/// child receives them too, so nlock outlives it and can release the lock.
const terminal_signals = [_]std.posix.SIG{ .INT, .QUIT };

pub fn runCommand(io: Io, command: []const []const u8) !void {
    var old_actions: [terminal_signals.len]std.posix.Sigaction = undefined;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = ignoreSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    for (terminal_signals, &old_actions) |sig, *old| std.posix.sigaction(sig, &act, old);
    defer for (terminal_signals, &old_actions) |sig, *old| std.posix.sigaction(sig, old, null);

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
