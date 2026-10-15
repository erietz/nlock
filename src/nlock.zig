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

const RunLockedError = error{
    LockAlreadyAcquired,
    LockAcquireTimeout,
    LockReleaseFailed,
};

pub fn main(init: std.process.Init) void {
    const status = run(init) catch |err| {
        std.debug.print("An unexpected error occurred: {s}\n", .{@errorName(err)});
        nlock.SysExits.software.exit();
    };
    std.process.exit(status);
}

/// Returns the exit status for nlock: the command's for `run`, 0 for `list`.
pub fn run(init: std.process.Init) !u8 {
    nlock.logger.init(nlock.logger.getLogLevel(init.environ_map));
    nlock.printer.init(init.io);

    const args = init.minimal.args.toSlice(init.gpa) catch nlock.SysExits.oserr.exit();
    defer init.gpa.free(args);
    const command = nlock.cli.Command.parseArgs(args) catch |err| switch (err) {
        nlock.cli.UsageError.InvalidArguments => {
            nlock.printer.eprint("{s}", .{nlock.cli.USAGE}) catch nlock.SysExits.oserr.exit();
            nlock.SysExits.usage.exit();
        },
    };

    // No need to connect to the daemon for `version`, so do it first to avoid
    // unnecessary errors if the daemon is not running.
    if (command == .version) {
        printVersion() catch nlock.SysExits.oserr.exit();
        nlock.SysExits.ok.exit();
    }

    const socket_path = try nlock.getSocketPath(init.gpa, init.environ_map);
    defer init.gpa.free(socket_path);
    log(ll.Debug, "Connecting to lock server at {s}", .{socket_path});

    const address = std.Io.net.UnixAddress.init(socket_path) catch nlock.SysExits.osfile.exit();
    const stream = address.connect(init.io) catch |err| {
        nlock.printer.eprint(
            "nlockd server is not running or cannot be reached at {s}: {s}\n",
            .{ socket_path, @errorName(err) },
        ) catch nlock.SysExits.oserr.exit();
        nlock.SysExits.unavailable.exit();
    };
    defer stream.close(init.io);
    verifyServer(stream) catch |err| switch (err) {
        error.UntrustedLockServer => {
            nlock.printer.eprint(
                "Lock server socket belongs to another user. Refusing to use it.\n",
                .{},
            ) catch nlock.SysExits.oserr.exit();
            nlock.SysExits.unavailable.exit();
        },
        else => {
            nlock.printer.eprint(
                "Failed to verify lock server identity: {s}\n",
                .{@errorName(err)},
            ) catch nlock.SysExits.oserr.exit();
            nlock.SysExits.software.exit();
        },
    };

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
        .run => |options| return runLocked(ctx, options) catch |err| switch (err) {
            RunLockedError.LockAlreadyAcquired => {
                nlock.printer.eprint(
                    "Lock is already acquired by another process.\n",
                    .{},
                ) catch nlock.SysExits.oserr.exit();
                nlock.SysExits.tempfail.exit();
            },
            RunLockedError.LockAcquireTimeout => {
                nlock.printer.eprint(
                    "Failed to acquire lock within the specified timeout.\n",
                    .{},
                ) catch nlock.SysExits.oserr.exit();
                nlock.SysExits.tempfail.exit();
            },
            RunLockedError.LockReleaseFailed => {
                nlock.printer.eprint(
                    "Failed to release lock. Please check the lock server logs for more details.\n",
                    .{},
                ) catch nlock.SysExits.oserr.exit();
                nlock.SysExits.software.exit();
            },
            else => {
                return err;
            },
        },
        .list => |options| {
            try runList(ctx, options);
            return 0;
        },
        .version => {
            printVersion() catch nlock.SysExits.oserr.exit();
            return 0;
        },
    }
}

fn printVersion() !void {
    try nlock.printer.print("nlock {s}\n", .{nlock.version()});
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

/// Runs the command under the lock and returns its exit status.
pub fn runLocked(ctx: Context, options: nlock.cli.RunOptions) !u8 {
    // Only explain a wait to a person: scripts and cron jobs would just get
    // noise on stderr.
    const report_queued = Io.File.stderr().isTty(ctx.io) catch false;
    const acquire_status = try acquireLock(
        ctx.io,
        ctx.allocator,
        ctx.writer,
        ctx.reader,
        options,
        report_queued,
    );

    switch (acquire_status) {
        nlock.LockResponseStatus.Ok => {
            log(ll.Debug, "Lock acquired successfully. Running command", .{});
            // runCommand reports its own failures as an exit status, so the
            // lock is always released below.
            const status = runCommand(ctx.io, options.command);
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
                    return status;
                },
                else => {
                    log(ll.Error, "Failed to release lock. Status: {d}", .{release_status});
                    return RunLockedError.LockReleaseFailed;
                },
            }
        },
        nlock.LockResponseStatus.Busy => {
            return RunLockedError.LockAlreadyAcquired;
        },
        nlock.LockResponseStatus.Timeout => {
            return RunLockedError.LockAcquireTimeout;
        },
        // acquireLock reads past Queued to the final status.
        nlock.LockResponseStatus.Queued => unreachable,
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

/// Requests the lock and waits for the daemon's answer: Ok, Busy or Timeout.
/// If the lock is held by someone else, first prints who holds it to stderr
/// when `report_queued` is set.
pub fn acquireLock(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    reader: *Io.Reader,
    options: nlock.cli.RunOptions,
    report_queued: bool,
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

    while (true) {
        const response_message = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
        log(ll.Debug, "Received lock response: {s}", .{response_message});
        var lock_response = try nlock.LockResponse.fromJson(response_message, allocator);
        defer lock_response.deinit(allocator);

        if (lock_response.status != .Queued) return lock_response.status;
        if (!report_queued) continue;
        const holder = lock_response.holder orelse continue;

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const queued_message = try formatQueuedMessage(
            arena_state.allocator(),
            holder,
            lock_response.ahead orelse 0,
            nowSeconds(io),
        );
        nlock.printer.eprint("{s}", .{queued_message}) catch {};
    }
}

/// The line printed while waiting for a lock held by someone else, e.g.
/// `nlock: waiting for 'db' — held by alice (pid 4242) for 02:13: ./migrate --up (2 ahead of you)`
fn formatQueuedMessage(
    allocator: std.mem.Allocator,
    holder: nlock.LockInfo,
    ahead: usize,
    now: i64,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "nlock: waiting for '");
    try appendEscaped(allocator, &out, holder.name);
    try out.print(allocator, "' — held by {s}", .{try userNameAlloc(allocator, holder.uid)});
    if (holder.pid > 0) try out.print(allocator, " (pid {d})", .{holder.pid});
    try out.print(allocator, " for {s}: ", .{try formatElapsed(allocator, now - holder.acquired_at)});
    try appendEscaped(allocator, &out, holder.command);
    if (ahead == 0) {
        try out.appendSlice(allocator, " (next in line)\n");
    } else {
        try out.print(allocator, " ({d} ahead of you)\n", .{ahead});
    }
    return out.items;
}

test "formatQueuedMessage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const holder: nlock.LockInfo = .{ .name = "db", .uid = 4000000000, .pid = 4242, .global = false, .waiters = 3, .acquired_at = 1000, .command = "./migrate --up" };
    try std.testing.expectEqualStrings(
        "nlock: waiting for 'db' — held by 4000000000 (pid 4242) for 02:13: ./migrate --up (2 ahead of you)\n",
        try formatQueuedMessage(arena, holder, 2, 1133),
    );

    var unknown_pid = holder;
    unknown_pid.pid = 0;
    unknown_pid.command = "sh -c 'a\nb'";
    try std.testing.expectEqualStrings(
        "nlock: waiting for 'db' — held by 4000000000 for 00:00: sh -c 'a\\nb' (next in line)\n",
        try formatQueuedMessage(arena, unknown_pid, 0, 1000),
    );
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

/// Exit statuses for a command that could not be started, as used by shells
/// and by `env`, `nohup` and `flock`.
const exit_not_executable = 126;
const exit_not_found = 127;

/// Runs the command and returns its exit status, or 128 plus the signal
/// number if a signal ended it, as a shell reports it.
pub fn runCommand(io: Io, command: []const []const u8) u8 {
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
        std.debug.print("nlock: {s}: {s}\n", .{ command[0], @errorName(err) });
        return switch (err) {
            error.FileNotFound => exit_not_found,
            else => exit_not_executable,
        };
    };

    const term = child.wait(io) catch |err| {
        std.debug.print("nlock: failed to wait for {s}: {s}\n", .{ command[0], @errorName(err) });
        return 1;
    };

    switch (term) {
        .exited => |code| {
            log(ll.Debug, "Process exited with code: {d}", .{code});
            return code;
        },
        .signal, .stopped => |sig| {
            log(ll.Debug, "Process ended by signal: {d}", .{@intFromEnum(sig)});
            return 128 +| @as(u8, @intCast(@intFromEnum(sig)));
        },
        .unknown => |status| {
            log(ll.Debug, "Process ended with unknown status: {d}", .{status});
            return 1;
        },
    }
}
