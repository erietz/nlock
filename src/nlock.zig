const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const log = nlock.Logger.log;

pub const std_options: std.Options = .{
    // Release builds would otherwise compile out debug messages, leaving
    // NLOCK_LOG_LEVEL=Debug no effect. NLOCK_LOG_LEVEL does the filtering.
    .log_level = .debug,
};

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
        nlock.printer.eprint("nlock: unexpected error: {s}\n", .{@errorName(err)}) catch {};
        nlock.SysExits.software.exit();
    };
    std.process.exit(status);
}

/// Returns the exit status for nlock: the command's for `run`, 0 for `list`.
pub fn run(init: std.process.Init) !u8 {
    nlock.printer.init(init.io);
    nlock.Logger.init(nlock.Logger.getLogLevel(init.environ_map) catch blk: {
        nlock.printer.eprint(
            "nlock: ignoring invalid {s}; expected debug, info, warn, error or none\n",
            .{nlock.Logger.ENV_NLOCK_LOG_LEVEL},
        ) catch {};
        break :blk null;
    });

    const args = init.minimal.args.toSlice(init.gpa) catch nlock.SysExits.oserr.exit();
    defer init.gpa.free(args);
    const command = nlock.cli.Command.parseArgs(args) catch |err| switch (err) {
        nlock.cli.UsageError.InvalidArguments => {
            nlock.printer.eprint("{s}", .{nlock.cli.USAGE}) catch nlock.SysExits.oserr.exit();
            nlock.SysExits.usage.exit();
        },
    };

    // No need to connect to the daemon for `help` or `version`, so do them
    // first to avoid unnecessary errors if the daemon is not running.
    switch (command) {
        .help => {
            nlock.printer.print("{s}", .{nlock.cli.HELP}) catch nlock.SysExits.oserr.exit();
            nlock.SysExits.ok.exit();
        },
        .version => {
            printVersion() catch nlock.SysExits.oserr.exit();
            nlock.SysExits.ok.exit();
        },
        .run, .list => {},
    }

    const socket_path = try nlock.getSocketPath(init.gpa, init.environ_map);
    defer init.gpa.free(socket_path);
    log(.debug, "Connecting to lock server at {s}", .{socket_path});

    const address = std.Io.net.UnixAddress.init(socket_path) catch nlock.SysExits.osfile.exit();
    const stream = address.connect(init.io) catch |err| {
        nlock.printer.eprint(
            "nlock: cannot reach nlockd at {s}: {s}; is it running?\n",
            .{ socket_path, @errorName(err) },
        ) catch nlock.SysExits.oserr.exit();
        nlock.SysExits.unavailable.exit();
    };
    defer stream.close(init.io);
    verifyServer(stream) catch |err| switch (err) {
        error.UntrustedLockServer => {
            nlock.printer.eprint(
                "nlock: refusing to use {s}: it is served by another user's nlockd\n",
                .{socket_path},
            ) catch nlock.SysExits.oserr.exit();
            nlock.SysExits.unavailable.exit();
        },
        else => {
            nlock.printer.eprint(
                "nlock: cannot verify who serves {s}: {s}\n",
                .{ socket_path, @errorName(err) },
            ) catch nlock.SysExits.oserr.exit();
            nlock.SysExits.software.exit();
        },
    };

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(init.io, &write_buffer);

    var read_buffer: [nlock.max_message_len]u8 = undefined;
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
                    "nlock: '{s}' is held by another process\n",
                    .{options.name},
                ) catch nlock.SysExits.oserr.exit();
                nlock.SysExits.tempfail.exit();
            },
            RunLockedError.LockAcquireTimeout => {
                nlock.printer.eprint(
                    "nlock: timed out waiting for '{s}'\n",
                    .{options.name},
                ) catch nlock.SysExits.oserr.exit();
                nlock.SysExits.tempfail.exit();
            },
            RunLockedError.LockReleaseFailed => {
                nlock.printer.eprint(
                    "nlock: failed to release '{s}'; see the nlockd logs\n",
                    .{options.name},
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
        // Handled before connecting.
        .help, .version => unreachable,
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
        log(.err, "Lock server is run by uid {d}, expected {d} or root", .{ server.uid, uid });
        return error.UntrustedLockServer;
    }
}

/// Runs the command under the lock and returns its exit status.
pub fn runLocked(ctx: Context, options: nlock.cli.RunOptions) !u8 {
    // Only explain a wait, or not running, to a person: scripts and cron jobs
    // would just get noise on stderr.
    const report = Io.File.stderr().isTty(ctx.io) catch false;
    const acquire_status = try acquireLock(
        ctx.io,
        ctx.allocator,
        ctx.writer,
        ctx.reader,
        options,
        report,
    );

    switch (acquire_status) {
        nlock.LockResponseStatus.ok => {
            log(.debug, "Lock acquired successfully. Running command", .{});
            // runCommand reports its own failures as an exit status, so the
            // lock is always released below.
            const status = runCommand(ctx.io, options.command);
            log(.debug, "Command finished. Releasing lock: {s}", .{options.name});

            const release_status = try releaseLock(ctx.allocator, ctx.writer, ctx.reader);

            switch (release_status) {
                nlock.LockResponseStatus.ok => {
                    log(.debug, "Lock released successfully", .{});
                    return status;
                },
                else => {
                    log(.err, "Failed to release lock. Status: {t}", .{release_status});
                    return RunLockedError.LockReleaseFailed;
                },
            }
        },
        nlock.LockResponseStatus.busy => {
            return RunLockedError.LockAlreadyAcquired;
        },
        nlock.LockResponseStatus.timeout => {
            return RunLockedError.LockAcquireTimeout;
        },
        // A run is pending that will start after this request was made,
        // which is what the caller asked for, so this is success.
        nlock.LockResponseStatus.coalesced, nlock.LockResponseStatus.replaced => {
            log(.debug, "Not running the command: {s}", .{@tagName(acquire_status)});
            return 0;
        },
        // acquireLock reads past queued to the final status.
        nlock.LockResponseStatus.queued => unreachable,
    }
}

pub fn runList(ctx: Context, options: nlock.cli.ListOptions) !void {
    const list_message = try (nlock.LockRequest{ .list = {} }).toJson(ctx.allocator);
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

/// Reads lock infos until the daemon closes the connection. Everything is
/// allocated from `arena` and freed along with it.
fn readLockInfos(
    reader: *Io.Reader,
    arena: std.mem.Allocator,
) !std.ArrayList(nlock.LockInfo) {
    var lock_infos: std.ArrayList(nlock.LockInfo) = .empty;
    while (true) {
        const response_message = try (reader.takeDelimiter('\n')) orelse break;
        log(.debug, "Received lock info: {s}", .{response_message});
        try lock_infos.append(arena, try nlock.LockInfo.fromJsonLeaky(response_message, arena));
    }
    return lock_infos;
}

/// `nlock list --json`: one JSON object per lock, one per line. Unlike the
/// table, names and commands are not escaped.
fn formatLockInfoJson(allocator: std.mem.Allocator, lock_infos: []const nlock.LockInfo) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lock_infos) |lock_info| {
        try out.appendSlice(allocator, try lock_info.toJson(allocator));
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
    .{ .title = "PID", .align_right = true },
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
            if (lock_info.pid > 0) try std.fmt.allocPrint(allocator, "{d}", .{lock_info.pid}) else "-",
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
        .{ .name = "build", .pid = 123, .waiters = 0, .acquired_at = 1000, .command = "make -j8" },
        .{ .name = "deploy-prod", .pid = 0, .waiters = 12, .acquired_at = 0, .command = "sh -c 'a\nb'" },
    };
    const table = try formatLockInfoTable(arena, &lock_infos, true, 1065);
    try std.testing.expectEqualStrings(
        \\NAME         PID  ELAPSED  WAITERS  CMD
        \\build        123    01:05        0  make -j8
        \\deploy-prod    -    17:45       12  sh -c 'a\nb'
        \\
    , table);

    const no_header = try formatLockInfoTable(arena, lock_infos[0..1], false, 1065);
    try std.testing.expectEqualStrings("build  123  01:05  0  make -j8\n", no_header);
}

test "formatLockInfoTable prints only the header when no locks are held" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "NAME  PID  ELAPSED  WAITERS  CMD\n",
        try formatLockInfoTable(arena, &.{}, true, 0),
    );
    try std.testing.expectEqualStrings("", try formatLockInfoTable(arena, &.{}, false, 0));
}

/// Requests the lock and waits for the daemon's answer: ok, busy, timeout,
/// coalesced or replaced. When `report` is set, explains on stderr who holds
/// the lock before waiting for it, and why the command will not run if the
/// request was coalesced or replaced.
pub fn acquireLock(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    reader: *Io.Reader,
    options: nlock.cli.RunOptions,
    report: bool,
) !nlock.LockResponseStatus {
    const command_str = try formatCommand(allocator, options.command);
    defer allocator.free(command_str);
    const message = try (nlock.LockRequest{ .acquire = .{
        .name = options.name,
        .nonblock = options.nonblock,
        .timeout = options.timeout,
        .command = command_str,
        .if_pending = if (options.coalesce) .skip else if (options.replace) .replace else .queue,
    } }).toJson(allocator);
    defer allocator.free(message);
    try nlock.writeLine(writer, message);

    // Every response but queued is final.
    while (true) {
        const response_message = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
        log(.debug, "Received lock response: {s}", .{response_message});
        const parsed = try nlock.LockResponse.fromJson(response_message, allocator);
        defer parsed.deinit();
        const status = std.meta.activeTag(parsed.value);

        if (report) {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const explanation: ?[]const u8 = switch (parsed.value) {
                .queued => |queued| try formatQueuedMessage(arena, queued.holder, queued.ahead, nowSeconds(io)),
                .coalesced => |coalesced| try formatCoalescedMessage(arena, options.name, coalesced),
                .replaced => |replaced| try formatReplacedMessage(arena, options.name, replaced),
                .ok, .busy, .timeout => null,
            };
            if (explanation) |m| nlock.printer.eprint("{s}", .{m}) catch {};
        }

        if (status != .queued) return status;
    }
}

/// The command as shown in `nlock list` and in messages: the arguments joined
/// with spaces, truncated to `max_command_len` bytes. Caller owns the result.
fn formatCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const joined = try std.mem.join(allocator, " ", argv);
    if (joined.len <= nlock.max_command_len) return joined;
    defer allocator.free(joined);

    const ellipsis = "...";
    var end = nlock.max_command_len - ellipsis.len;
    // Back up to the start of a UTF-8 sequence so the cut does not turn a
    // valid command into invalid UTF-8.
    while (end > 0 and joined[end] & 0xC0 == 0x80) end -= 1;
    return std.mem.concat(allocator, u8, &.{ joined[0..end], ellipsis });
}

test "formatCommand joins arguments and truncates long commands" {
    const allocator = std.testing.allocator;

    const short = try formatCommand(allocator, &.{ "echo", "hello" });
    defer allocator.free(short);
    try std.testing.expectEqualStrings("echo hello", short);

    const exact = try formatCommand(allocator, &.{"x" ** nlock.max_command_len});
    defer allocator.free(exact);
    try std.testing.expectEqual(nlock.max_command_len, exact.len);

    const long = try formatCommand(allocator, &.{ "echo", "x" ** (2 * nlock.max_command_len) });
    defer allocator.free(long);
    try std.testing.expectEqual(nlock.max_command_len, long.len);
    try std.testing.expect(std.mem.endsWith(u8, long, "xx..."));

    // "é" is two bytes; a cut through the middle of one backs up before it.
    const accents = try formatCommand(allocator, &.{"é" ** nlock.max_command_len});
    defer allocator.free(accents);
    try std.testing.expect(accents.len <= nlock.max_command_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(accents));
}

/// The line printed when the request was coalesced into a run that is
/// already pending, e.g.
/// `nlock: 'rebuild' already has a pending run (pid 4321): make; not queueing`
fn formatCoalescedMessage(
    allocator: std.mem.Allocator,
    name: []const u8,
    coalesced: nlock.LockResponse.Coalesced,
) ![]const u8 {
    const pending = coalesced.pending;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "nlock: '");
    try appendEscaped(allocator, &out, name);
    try out.appendSlice(allocator, "' already has a pending run");
    if (pending.pid > 0) try out.print(allocator, " (pid {d})", .{pending.pid});
    try out.appendSlice(allocator, ": ");
    try appendEscaped(allocator, &out, pending.command);
    try out.appendSlice(allocator, "; not queueing\n");
    return out.items;
}

/// The line printed when a newer request took this one's place in the
/// queue, e.g.
/// `nlock: replaced in the queue for 'deploy' by a newer request (pid 4321)`
fn formatReplacedMessage(
    allocator: std.mem.Allocator,
    name: []const u8,
    replaced: nlock.LockResponse.Replaced,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "nlock: replaced in the queue for '");
    try appendEscaped(allocator, &out, name);
    try out.appendSlice(allocator, "' by a newer request");
    if (replaced.pid > 0) try out.print(allocator, " (pid {d})", .{replaced.pid});
    try out.append(allocator, '\n');
    return out.items;
}

test "formatCoalescedMessage and formatReplacedMessage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "nlock: 'rebuild' already has a pending run (pid 4321): make -j8; not queueing\n",
        try formatCoalescedMessage(arena, "rebuild", .{
            .pending = .{ .pid = 4321, .command = "make -j8" },
            .waiters = 1,
        }),
    );
    try std.testing.expectEqualStrings(
        "nlock: replaced in the queue for 'deploy' by a newer request\n",
        try formatReplacedMessage(arena, "deploy", .{ .pid = 0 }),
    );
}

/// The line printed while waiting for a lock held by someone else, e.g.
/// `nlock: waiting for 'db' — held by pid 4242 for 02:13: ./migrate --up (2 ahead of you)`
fn formatQueuedMessage(
    allocator: std.mem.Allocator,
    holder: nlock.LockInfo,
    ahead: usize,
    now: i64,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "nlock: waiting for '");
    try appendEscaped(allocator, &out, holder.name);
    try out.appendSlice(allocator, "' — held");
    if (holder.pid > 0) try out.print(allocator, " by pid {d}", .{holder.pid});
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

    const holder: nlock.LockInfo = .{ .name = "db", .pid = 4242, .waiters = 3, .acquired_at = 1000, .command = "./migrate --up" };
    try std.testing.expectEqualStrings(
        "nlock: waiting for 'db' — held by pid 4242 for 02:13: ./migrate --up (2 ahead of you)\n",
        try formatQueuedMessage(arena, holder, 2, 1133),
    );

    var unknown_pid = holder;
    unknown_pid.pid = 0;
    unknown_pid.command = "sh -c 'a\nb'";
    try std.testing.expectEqualStrings(
        "nlock: waiting for 'db' — held for 00:00: sh -c 'a\\nb' (next in line)\n",
        try formatQueuedMessage(arena, unknown_pid, 0, 1000),
    );
}

/// Releases the lock this connection holds. Returns the status of the
/// release operation.
pub fn releaseLock(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    reader: *Io.Reader,
) !nlock.LockResponseStatus {
    const release_message = try (nlock.LockRequest{ .release = {} }).toJson(allocator);
    defer allocator.free(release_message);

    try nlock.writeLine(writer, release_message);

    const release_response_message = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
    log(.debug, "Received release lock response: {s}", .{release_response_message});

    const release_response = try nlock.LockResponse.fromJson(release_response_message, allocator);
    defer release_response.deinit();
    return std.meta.activeTag(release_response.value);
}

/// Handler which does absolutely nothing installed while the command runs. A
/// handler rather than SIG_IGN, because ignored signals are inherited across
/// exec while handlers are reset to the default, so the child still gets the
/// usual behavior.
fn ignoreSignal(_: std.posix.SIG) callconv(.c) void {}

/// Signals the terminal sends to the whole foreground process group. The
/// child receives them too, so nlock outlives it and can release the lock.
const terminal_signals = [_]std.posix.SIG{ .INT, .QUIT };

/// Signals asking nlock to stop, from `kill`, `timeout`, a service manager or
/// a closing terminal. They are passed on to the command instead, so the
/// lock is released only once the command has exited. Were nlock to die
/// first, the daemon would release the lock with the command still running.
const forwarded_signals = [_]std.posix.SIG{ .TERM, .HUP };

const SigNum = std.meta.Tag(std.posix.SIG);

/// Pid of the running command, or 0 before it has started.
var forward_pid: std.atomic.Value(std.posix.pid_t) = .init(0);
/// The last forwarded signal received, or 0 if none.
var forward_sig: std.atomic.Value(SigNum) = .init(0);

/// Signal handlers may run on any thread, including while the command is
/// being started. The handler records the signal before reading the pid, and
/// `runCommand` records the pid before reading the signal, so at least one
/// of them sees the other's write and the command always gets the signal
/// (occasionally twice).
fn forwardSignal(sig: std.posix.SIG) callconv(.c) void {
    forward_sig.store(@intFromEnum(sig), .seq_cst);
    const pid = forward_pid.load(.seq_cst);
    if (pid > 0) _ = std.c.kill(pid, sig);
}

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

    forward_pid.store(0, .seq_cst);
    forward_sig.store(0, .seq_cst);
    var old_forward_actions: [forwarded_signals.len]std.posix.Sigaction = undefined;
    const forward_act: std.posix.Sigaction = .{
        .handler = .{ .handler = forwardSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    for (forwarded_signals, &old_forward_actions) |sig, *old| std.posix.sigaction(sig, &forward_act, old);
    defer for (forwarded_signals, &old_forward_actions) |sig, *old| std.posix.sigaction(sig, old, null);
    defer forward_pid.store(0, .seq_cst);

    const spawnOptions: std.process.SpawnOptions = .{
        .argv = command,
    };

    var child = std.process.spawn(io, spawnOptions) catch |err| {
        nlock.printer.eprint("nlock: {s}: {s}\n", .{ command[0], @errorName(err) }) catch {};
        return switch (err) {
            error.FileNotFound => exit_not_found,
            else => exit_not_executable,
        };
    };

    if (child.id) |pid| {
        forward_pid.store(pid, .seq_cst);
        // A signal that arrived while the command was starting.
        const sig = forward_sig.load(.seq_cst);
        if (sig != 0) _ = std.c.kill(pid, @enumFromInt(sig));
    }

    const term = child.wait(io) catch |err| {
        nlock.printer.eprint("nlock: failed to wait for {s}: {s}\n", .{ command[0], @errorName(err) }) catch {};
        return 1;
    };

    switch (term) {
        .exited => |code| {
            log(.debug, "Process exited with code: {d}", .{code});
            return code;
        },
        .signal, .stopped => |sig| {
            log(.debug, "Process ended by signal: {d}", .{@intFromEnum(sig)});
            return 128 +| @as(u8, @intCast(@intFromEnum(sig)));
        },
        .unknown => |status| {
            log(.debug, "Process ended with unknown status: {d}", .{status});
            return 1;
        },
    }
}
