const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const protocol = nlock.protocol;
const log = nlock.Logger.log;
const cli = @import("cli.zig");
const printer = @import("printer.zig");
const format = @import("format.zig");
const appendEscaped = format.appendEscaped;
const formatElapsed = format.formatElapsed;

/// Requests the lock and waits for the daemon's answer: ok, busy, timeout,
/// coalesced, replaced or mismatch. When `report` is set, explains on stderr
/// who holds the lock before waiting for it, and why the command will not
/// run if the request was coalesced or replaced. A mismatch is an error, so
/// it is always explained.
pub fn acquireLock(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    reader: *Io.Reader,
    options: cli.RunOptions,
    report: bool,
) !protocol.LockResponseStatus {
    const command_str = try formatCommand(allocator, options.command);
    defer allocator.free(command_str);
    const message = try (protocol.LockRequest{ .acquire = .{
        .name = options.name,
        .nonblock = options.nonblock,
        .timeout = options.timeout,
        .command = command_str,
        .if_pending = if (options.coalesce) .skip else if (options.replace) .replace else .queue,
        .slots = options.slots,
    } }).toJson(allocator);
    defer allocator.free(message);
    try protocol.writeLine(writer, message);

    // Every response but queued is final.
    while (true) {
        const response_message = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
        log(.debug, "Received lock response: {s}", .{response_message});
        const parsed = try protocol.LockResponse.fromJson(response_message, allocator);
        defer parsed.deinit();
        const status = std.meta.activeTag(parsed.value);

        if (parsed.value == .mismatch) {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const m = try formatMismatchMessage(arena_state.allocator(), options.name, options.slots, parsed.value.mismatch);
            printer.eprint("{s}", .{m}) catch {};
        } else if (report) {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const explanation: ?[]const u8 = switch (parsed.value) {
                .queued => |queued| try formatQueuedMessage(arena, queued.holder, queued.ahead, format.nowSeconds(io)),
                .coalesced => |coalesced| try formatCoalescedMessage(arena, options.name, coalesced),
                .replaced => |replaced| try formatReplacedMessage(arena, options.name, replaced),
                .ok, .busy, .timeout, .mismatch => null,
            };
            if (explanation) |m| printer.eprint("{s}", .{m}) catch {};
        }

        if (status != .queued) return status;
    }
}

/// The command as shown in `nlock list` and in messages: the arguments joined
/// with spaces, truncated to `max_command_len` bytes. Caller owns the result.
fn formatCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const joined = try std.mem.join(allocator, " ", argv);
    if (joined.len <= protocol.max_command_len) return joined;
    defer allocator.free(joined);

    const ellipsis = "...";
    var end = protocol.max_command_len - ellipsis.len;
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

    const exact = try formatCommand(allocator, &.{"x" ** protocol.max_command_len});
    defer allocator.free(exact);
    try std.testing.expectEqual(protocol.max_command_len, exact.len);

    const long = try formatCommand(allocator, &.{ "echo", "x" ** (2 * protocol.max_command_len) });
    defer allocator.free(long);
    try std.testing.expectEqual(protocol.max_command_len, long.len);
    try std.testing.expect(std.mem.endsWith(u8, long, "xx..."));

    // "é" is two bytes; a cut through the middle of one backs up before it.
    const accents = try formatCommand(allocator, &.{"é" ** protocol.max_command_len});
    defer allocator.free(accents);
    try std.testing.expect(accents.len <= protocol.max_command_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(accents));
}

/// The line printed when the request was coalesced into a run that is
/// already pending, e.g.
/// `nlock: 'rebuild' already has a pending run (pid 4321): make; not queueing`
fn formatCoalescedMessage(
    allocator: std.mem.Allocator,
    name: []const u8,
    coalesced: protocol.LockResponse.Coalesced,
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
    replaced: protocol.LockResponse.Replaced,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "nlock: replaced in the queue for '");
    try appendEscaped(allocator, &out, name);
    try out.appendSlice(allocator, "' by a newer request");
    if (replaced.pid > 0) try out.print(allocator, " (pid {d})", .{replaced.pid});
    try out.append(allocator, '\n');
    return out.items;
}

/// The line printed when the lock is in use with a different number of
/// slots than requested, e.g.
/// `nlock: 'build' is in use with --slots 4, not 2`
fn formatMismatchMessage(
    allocator: std.mem.Allocator,
    name: []const u8,
    requested: u32,
    mismatch: protocol.LockResponse.Mismatch,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "nlock: '");
    try appendEscaped(allocator, &out, name);
    try out.print(allocator, "' is in use with --slots {d}, not {d}\n", .{ mismatch.slots, requested });
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
    try std.testing.expectEqualStrings(
        "nlock: 'build' is in use with --slots 4, not 1\n",
        try formatMismatchMessage(arena, "build", 1, .{ .slots = 4 }),
    );
}

/// The line printed while waiting for a lock held by someone else, e.g.
/// `nlock: waiting for 'db' — held by pid 4242 for 02:13: ./migrate --up (2 ahead of you)`
/// For a lock with several slots, the holder described is the
/// longest-standing one:
/// `nlock: waiting for 'build' — all 4 slots held, longest by pid 4242 for 02:13: make (next in line)`
fn formatQueuedMessage(
    allocator: std.mem.Allocator,
    holder: protocol.LockInfo,
    ahead: usize,
    now: i64,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "nlock: waiting for '");
    try appendEscaped(allocator, &out, holder.name);
    if (holder.slots > 1) {
        try out.print(allocator, "' — all {d} slots held, longest", .{holder.slots});
    } else {
        try out.appendSlice(allocator, "' — held");
    }
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

    const holder: protocol.LockInfo = .{ .name = "db", .pid = 4242, .waiters = 3, .acquired_at = 1000, .command = "./migrate --up" };
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

    var slots = holder;
    slots.slots = 4;
    try std.testing.expectEqualStrings(
        "nlock: waiting for 'db' — all 4 slots held, longest by pid 4242 for 02:13: ./migrate --up (next in line)\n",
        try formatQueuedMessage(arena, slots, 0, 1133),
    );
}

/// Releases the lock this connection holds. Returns the status of the
/// release operation.
pub fn releaseLock(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    reader: *Io.Reader,
) !protocol.LockResponseStatus {
    const release_message = try (protocol.LockRequest{ .release = {} }).toJson(allocator);
    defer allocator.free(release_message);

    try protocol.writeLine(writer, release_message);

    const release_response_message = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
    log(.debug, "Received release lock response: {s}", .{release_response_message});

    const release_response = try protocol.LockResponse.fromJson(release_response_message, allocator);
    defer release_response.deinit();
    return std.meta.activeTag(release_response.value);
}
