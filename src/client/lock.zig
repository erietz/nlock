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
/// coalesced, replaced, mismatch or rate_limited. When `report` is set,
/// explains on stderr who holds the lock before waiting for it, and why the
/// command will not run if the request was coalesced or replaced. A mismatch
/// or a rate limit means the command does not run, so those are always
/// explained.
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
        .mode = options.mode,
        .rate = options.rate,
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
            const m = try formatMismatchMessage(arena_state.allocator(), options, parsed.value.mismatch);
            printer.eprint("{s}", .{m}) catch {};
        } else if (parsed.value == .rate_limited) {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const m = try formatRateLimitedMessage(arena_state.allocator(), options, parsed.value.rate_limited);
            printer.eprint("{s}", .{m}) catch {};
        } else if (report) {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const explanation: ?[]const u8 = switch (parsed.value) {
                .queued => |queued| try formatQueuedMessage(arena, queued.holder, queued.ahead, format.nowSeconds(io)),
                .coalesced => |coalesced| try formatCoalescedMessage(arena, options.name, coalesced),
                .replaced => |replaced| try formatReplacedMessage(arena, options.name, replaced),
                .ok, .busy, .timeout, .mismatch, .rate_limited => null,
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

    const exact = try formatCommand(allocator, &.{&@as([protocol.max_command_len]u8, @splat('x'))});
    defer allocator.free(exact);
    try std.testing.expectEqual(protocol.max_command_len, exact.len);

    const long = try formatCommand(allocator, &.{ "echo", &@as([2 * protocol.max_command_len]u8, @splat('x')) });
    defer allocator.free(long);
    try std.testing.expectEqual(protocol.max_command_len, long.len);
    try std.testing.expect(std.mem.endsWith(u8, long, "xx..."));

    // "é" is two bytes; a cut through the middle of one backs up before it.
    const accents = try formatCommand(allocator, &.{std.mem.sliceAsBytes(&@as([protocol.max_command_len][2]u8, @splat("é".*)))});
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
/// slots or rate limit than requested, e.g.
/// `nlock: 'build' is in use with --slots 4, not 2`
/// `nlock: 'api' is in use with --rate 30/m, not 10/m`
fn formatMismatchMessage(
    allocator: std.mem.Allocator,
    options: cli.RunOptions,
    mismatch: protocol.LockResponse.Mismatch,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "nlock: '");
    try appendEscaped(allocator, &out, options.name);
    if (!protocol.Rate.eql(options.rate, mismatch.rate)) {
        if (mismatch.rate) |rate| {
            try out.print(allocator, "' is in use with --rate {s}", .{try format.formatRate(allocator, rate)});
            if (options.rate) |requested| {
                try out.print(allocator, ", not {s}", .{try format.formatRate(allocator, requested)});
            }
            try out.append(allocator, '\n');
        } else {
            try out.appendSlice(allocator, "' is in use without --rate\n");
        }
        return out.items;
    }
    try out.print(allocator, "' is in use with --slots {d}", .{mismatch.slots});
    switch (options.mode) {
        // Shared locks have one slot, so the number was not what differed.
        .shared => try out.appendSlice(allocator, ", so it cannot be held --shared\n"),
        .exclusive => try out.print(allocator, ", not {d}\n", .{options.slots}),
    }
    return out.items;
}

/// The line printed when the lock was not granted because of its rate
/// limit, e.g.
/// `nlock: 'api' has reached its limit of 30/m; next run allowed in 23s`
fn formatRateLimitedMessage(
    allocator: std.mem.Allocator,
    options: cli.RunOptions,
    rate_limited: protocol.LockResponse.RateLimited,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "nlock: '");
    try appendEscaped(allocator, &out, options.name);
    try out.appendSlice(allocator, "' has reached its limit");
    // Always set: the daemon only rate limits a request that asked for the
    // lock's rate.
    if (options.rate) |rate| try out.print(allocator, " of {s}", .{try format.formatRate(allocator, rate)});
    // Rounded up, so waiting that long is always enough.
    const wait_s = std.math.divCeil(u64, rate_limited.retry_after_ms, std.time.ms_per_s) catch unreachable;
    try out.print(allocator, "; next run allowed in {s}\n", .{try formatWait(allocator, wait_s)});
    return out.items;
}

/// Formats a wait for people: `23s`, `4m 10s`, `2h 5m`.
fn formatWait(allocator: std.mem.Allocator, seconds: u64) ![]const u8 {
    if (seconds < std.time.s_per_min) return std.fmt.allocPrint(allocator, "{d}s", .{seconds});
    if (seconds < std.time.s_per_hour) {
        return std.fmt.allocPrint(allocator, "{d}m {d}s", .{ seconds / std.time.s_per_min, seconds % std.time.s_per_min });
    }
    return std.fmt.allocPrint(allocator, "{d}h {d}m", .{ seconds / std.time.s_per_hour, seconds % std.time.s_per_hour / std.time.s_per_min });
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
    const build: cli.RunOptions = .{ .name = "build", .command = &.{"make"} };
    try std.testing.expectEqualStrings(
        "nlock: 'build' is in use with --slots 4, not 1\n",
        try formatMismatchMessage(arena, build, .{ .slots = 4 }),
    );
    var shared = build;
    shared.mode = .shared;
    try std.testing.expectEqualStrings(
        "nlock: 'build' is in use with --slots 4, so it cannot be held --shared\n",
        try formatMismatchMessage(arena, shared, .{ .slots = 4 }),
    );
}

test "formatMismatchMessage explains a different rate limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lock_rate: protocol.Rate = .{ .count = 30, .period_s = 60 };
    var api: cli.RunOptions = .{ .name = "api", .command = &.{"true"} };

    api.rate = .{ .count = 10, .period_s = 60 };
    try std.testing.expectEqualStrings(
        "nlock: 'api' is in use with --rate 30/m, not 10/m\n",
        try formatMismatchMessage(arena, api, .{ .slots = 1, .rate = lock_rate }),
    );
    api.rate = null;
    try std.testing.expectEqualStrings(
        "nlock: 'api' is in use with --rate 30/m\n",
        try formatMismatchMessage(arena, api, .{ .slots = 1, .rate = lock_rate }),
    );
    api.rate = lock_rate;
    try std.testing.expectEqualStrings(
        "nlock: 'api' is in use without --rate\n",
        try formatMismatchMessage(arena, api, .{ .slots = 1 }),
    );
    // The same rate: what differed was the slots.
    api.slots = 2;
    try std.testing.expectEqualStrings(
        "nlock: 'api' is in use with --slots 1, not 2\n",
        try formatMismatchMessage(arena, api, .{ .slots = 1, .rate = lock_rate }),
    );
}

test "formatRateLimitedMessage rounds the wait up" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const api: cli.RunOptions = .{ .name = "api", .command = &.{"true"}, .rate = .{ .count = 30, .period_s = 60 } };

    try std.testing.expectEqualStrings(
        "nlock: 'api' has reached its limit of 30/m; next run allowed in 23s\n",
        try formatRateLimitedMessage(arena, api, .{ .retry_after_ms = 22_001 }),
    );
    try std.testing.expectEqualStrings(
        "nlock: 'api' has reached its limit of 30/m; next run allowed in 1s\n",
        try formatRateLimitedMessage(arena, api, .{ .retry_after_ms = 1 }),
    );
    try std.testing.expectEqualStrings(
        "nlock: 'api' has reached its limit of 30/m; next run allowed in 4m 10s\n",
        try formatRateLimitedMessage(arena, api, .{ .retry_after_ms = 250_000 }),
    );
    try std.testing.expectEqualStrings(
        "nlock: 'api' has reached its limit of 30/m; next run allowed in 2h 5m\n",
        try formatRateLimitedMessage(arena, api, .{ .retry_after_ms = 7_500_000 }),
    );
}

/// The line printed while waiting for a lock held by someone else, e.g.
/// `nlock: waiting for 'db' — held by pid 4242 for 02:13: ./migrate --up (2 ahead of you)`
/// For a lock with several slots, the holder described is the
/// longest-standing one:
/// `nlock: waiting for 'build' — all 4 slots held, longest by pid 4242 for 02:13: make (next in line)`
/// and for a lock held shared:
/// `nlock: waiting for 'db' — held shared, longest by pid 4242 for 02:13: ./backup.sh (next in line)`
/// A lock that has used up its rate limit may have no holder at all, so then
/// the limit is what is described:
/// `nlock: waiting for 'api' — limit of 30/m reached (next in line)`
fn formatQueuedMessage(
    allocator: std.mem.Allocator,
    holder: protocol.LockInfo,
    ahead: usize,
    now: i64,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "nlock: waiting for '");
    try appendEscaped(allocator, &out, holder.name);
    const full_rate: ?protocol.Rate = if (holder.rate) |rate| (if (holder.rate_used >= rate.count) rate else null) else null;
    if (full_rate) |rate| {
        try out.print(allocator, "' — limit of {s} reached", .{try format.formatRate(allocator, rate)});
    } else {
        if (holder.slots > 1) {
            try out.print(allocator, "' — all {d} slots held, longest", .{holder.slots});
        } else if (holder.mode == .shared) {
            try out.appendSlice(allocator, "' — held shared, longest");
        } else {
            try out.appendSlice(allocator, "' — held");
        }
        if (holder.pid > 0) try out.print(allocator, " by pid {d}", .{holder.pid});
        try out.print(allocator, " for {s}: ", .{try formatElapsed(allocator, now - holder.acquired_at)});
        try appendEscaped(allocator, &out, holder.command);
    }
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

    var shared = holder;
    shared.mode = .shared;
    try std.testing.expectEqualStrings(
        "nlock: waiting for 'db' — held shared, longest by pid 4242 for 02:13: ./migrate --up (2 ahead of you)\n",
        try formatQueuedMessage(arena, shared, 2, 1133),
    );

    // Its rate limit used up, a lock may wait with no holder at all.
    const rate_limited: protocol.LockInfo = .{
        .name = "api",
        .pid = 0,
        .waiters = 1,
        .acquired_at = 0,
        .command = "",
        .rate = .{ .count = 30, .period_s = 60 },
        .rate_used = 30,
    };
    try std.testing.expectEqualStrings(
        "nlock: waiting for 'api' — limit of 30/m reached (next in line)\n",
        try formatQueuedMessage(arena, rate_limited, 0, 1133),
    );
    // Within its limit, it waits for its holders as usual.
    var within_rate = holder;
    within_rate.rate = .{ .count = 30, .period_s = 60 };
    within_rate.rate_used = 29;
    try std.testing.expectEqualStrings(
        "nlock: waiting for 'db' — held by pid 4242 for 02:13: ./migrate --up (next in line)\n",
        try formatQueuedMessage(arena, within_rate, 0, 1133),
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
