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

pub fn runList(
    io: Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    reader: *Io.Reader,
    options: cli.ListOptions,
) !void {
    const list_message = try (protocol.LockRequest{ .list = {} }).toJson(allocator);
    defer allocator.free(list_message);

    try protocol.writeLine(writer, list_message);

    // Everything below is short-lived, so free it all at once.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lock_infos = try readLockInfos(reader, arena);
    // The daemon walks a hash map, so impose a stable order. Each lock's rows
    // stay together, longest-standing holder first.
    std.mem.sort(protocol.LockInfo, lock_infos.items, {}, lockInfoLessThan);

    const output = if (options.json)
        try formatLockInfoJson(arena, lock_infos.items)
    else if (options.quiet)
        try formatLockNames(arena, lock_infos.items)
    else
        try formatLockInfoTable(arena, lock_infos.items, options.header, format.nowSeconds(io));

    try printer.print("{s}", .{output});
}

fn lockInfoLessThan(_: void, a: protocol.LockInfo, b: protocol.LockInfo) bool {
    return switch (std.mem.order(u8, a.name, b.name)) {
        .lt => true,
        .gt => false,
        .eq => if (a.acquired_at != b.acquired_at) a.acquired_at < b.acquired_at else a.pid < b.pid,
    };
}

/// Reads lock infos until the daemon closes the connection. Everything is
/// allocated from `arena` and freed along with it.
fn readLockInfos(
    reader: *Io.Reader,
    arena: std.mem.Allocator,
) !std.ArrayList(protocol.LockInfo) {
    var lock_infos: std.ArrayList(protocol.LockInfo) = .empty;
    while (true) {
        const response_message = try (reader.takeDelimiter('\n')) orelse break;
        log(.debug, "Received lock info: {s}", .{response_message});
        try lock_infos.append(arena, try protocol.LockInfo.fromJsonLeaky(response_message, arena));
    }
    return lock_infos;
}

/// `nlock list --json`: one JSON object per holder, one per line. Unlike the
/// table, names and commands are not escaped.
fn formatLockInfoJson(allocator: std.mem.Allocator, lock_infos: []const protocol.LockInfo) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lock_infos) |lock_info| {
        try out.appendSlice(allocator, try lock_info.toJson(allocator));
        try out.append(allocator, '\n');
    }
    return out.items;
}

/// `nlock list --quiet`: lock names only, one per line. A lock with several
/// holders is listed once. `lock_infos` must be sorted by name.
fn formatLockNames(allocator: std.mem.Allocator, lock_infos: []const protocol.LockInfo) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lock_infos, 0..) |lock_info, i| {
        if (i > 0 and std.mem.eql(u8, lock_infos[i - 1].name, lock_info.name)) continue;
        try appendEscaped(allocator, &out, lock_info.name);
        try out.append(allocator, '\n');
    }
    return out.items;
}

const Column = struct {
    title: []const u8,
    align_right: bool = false,
    /// Shown only if some lock has a rate limit, so output for locks without
    /// one stays as it was.
    rate: bool = false,
};

/// CMD is last because it is the only column that may contain spaces, so
/// every other column can be split on whitespace.
const columns = [_]Column{
    .{ .title = "NAME" },
    .{ .title = "PID", .align_right = true },
    .{ .title = "ELAPSED", .align_right = true },
    .{ .title = "WAITERS", .align_right = true },
    .{ .title = "MODE" },
    .{ .title = "SLOTS", .align_right = true },
    // The limit as `--rate` takes it, and how many grants it counts now.
    .{ .title = "RATE", .align_right = true, .rate = true },
    .{ .title = "USED", .align_right = true, .rate = true },
    .{ .title = "CMD" },
};

const column_separator = "  ";

/// Default `nlock list` output: whitespace-aligned columns with an optional
/// header row, in the style of `ps`. One row per holder; `lock_infos` must be
/// sorted by name so each lock's rows are together.
fn formatLockInfoTable(
    allocator: std.mem.Allocator,
    lock_infos: []const protocol.LockInfo,
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
    // Rows for the same lock are together, so count each lock's holders once
    // at its first row: every row shows how many of its slots are taken.
    var group_end: usize = 0;
    var holders: usize = 0;
    for (lock_infos, 0..) |lock_info, i| {
        if (i == group_end) {
            holders = 0;
            while (group_end < lock_infos.len and std.mem.eql(u8, lock_infos[group_end].name, lock_info.name)) : (group_end += 1) {
                if (lock_infos[group_end].hasHolder()) holders += 1;
            }
        }

        var name: std.ArrayList(u8) = .empty;
        try appendEscaped(allocator, &name, lock_info.name);
        const slots = try std.fmt.allocPrint(allocator, "{d}/{d}", .{ holders, lock_info.slots });
        const waiters = try std.fmt.allocPrint(allocator, "{d}", .{lock_info.waiters});
        const rate = if (lock_info.rate) |r| try format.formatRate(allocator, r) else "-";
        const used = if (lock_info.rate != null) try std.fmt.allocPrint(allocator, "{d}", .{lock_info.rate_used}) else "-";

        if (!lock_info.hasHolder()) {
            try rows.append(allocator, .{ name.items, "-", "-", waiters, "-", slots, rate, used, "-" });
            continue;
        }

        var command: std.ArrayList(u8) = .empty;
        try appendEscaped(allocator, &command, lock_info.command);
        try rows.append(allocator, .{
            name.items,
            if (lock_info.pid > 0) try std.fmt.allocPrint(allocator, "{d}", .{lock_info.pid}) else "-",
            try formatElapsed(allocator, now - lock_info.acquired_at),
            waiters,
            @tagName(lock_info.mode),
            // Shared holders share the lock's one slot.
            if (lock_info.mode == .shared) "-" else slots,
            rate,
            used,
            command.items,
        });
    }

    const show_rate = for (lock_infos) |lock_info| {
        if (lock_info.rate != null) break true;
    } else false;

    var widths: [columns.len]usize = @splat(0);
    for (rows.items) |row| {
        for (row, &widths) |cell, *width| width.* = @max(width.*, cell.len);
    }

    var out: std.ArrayList(u8) = .empty;
    for (rows.items) |row| {
        for (columns, row, widths, 0..) |column, cell, width, i| {
            if (column.rate and !show_rate) continue;
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

test "formatLockInfoTable aligns columns and leaves CMD last and unpadded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lock_infos = [_]protocol.LockInfo{
        .{ .name = "build", .pid = 123, .waiters = 0, .acquired_at = 1000, .command = "make -j8" },
        .{ .name = "deploy-prod", .pid = 0, .waiters = 12, .acquired_at = 1, .command = "sh -c 'a\nb'" },
    };
    const table = try formatLockInfoTable(arena, &lock_infos, true, 1065);
    try std.testing.expectEqualStrings(
        \\NAME         PID  ELAPSED  WAITERS  MODE       SLOTS  CMD
        \\build        123    01:05        0  exclusive    1/1  make -j8
        \\deploy-prod    -    17:44       12  exclusive    1/1  sh -c 'a\nb'
        \\
    , table);

    const no_header = try formatLockInfoTable(arena, lock_infos[0..1], false, 1065);
    try std.testing.expectEqualStrings("build  123  01:05  0  exclusive  1/1  make -j8\n", no_header);
}

test "formatLockInfoTable shows a lock nobody holds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Waiting only for its rate limit.
    const lock_infos = [_]protocol.LockInfo{
        .{ .name = "api", .pid = 0, .waiters = 2, .slots = 4, .acquired_at = 0, .command = "", .rate = .{ .count = 1, .period_s = 60 }, .rate_used = 1 },
    };
    try std.testing.expectEqualStrings(
        \\NAME  PID  ELAPSED  WAITERS  MODE  SLOTS  RATE  USED  CMD
        \\api     -        -        2  -       0/4   1/m     1  -
        \\
    , try formatLockInfoTable(arena, &lock_infos, true, 1065));
}

test "formatLockInfoTable shows RATE and USED only if some lock has a rate limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lock_infos = [_]protocol.LockInfo{
        .{ .name = "build", .pid = 123, .waiters = 0, .acquired_at = 1000, .command = "make -j8" },
        .{ .name = "github-api", .pid = 456, .waiters = 3, .acquired_at = 1060, .command = "gh api /repos", .rate = .{ .count = 5000, .period_s = 3600 }, .rate_used = 12 },
    };
    try std.testing.expectEqualStrings(
        \\NAME        PID  ELAPSED  WAITERS  MODE       SLOTS    RATE  USED  CMD
        \\build       123    01:05        0  exclusive    1/1       -     -  make -j8
        \\github-api  456    00:05        3  exclusive    1/1  5000/h    12  gh api /repos
        \\
    , try formatLockInfoTable(arena, &lock_infos, true, 1065));

    // Without any rate limit, the columns are left out.
    try std.testing.expectEqualStrings(
        \\NAME   PID  ELAPSED  WAITERS  MODE       SLOTS  CMD
        \\build  123    01:05        0  exclusive    1/1  make -j8
        \\
    , try formatLockInfoTable(arena, lock_infos[0..1], true, 1065));
}

test "formatLockInfoTable and formatLockNames show a lock with several holders" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lock_infos = [_]protocol.LockInfo{
        .{ .name = "pool", .pid = 30, .waiters = 1, .slots = 4, .acquired_at = 1060, .command = "b" },
        .{ .name = "build", .pid = 123, .waiters = 0, .acquired_at = 1000, .command = "make" },
        .{ .name = "pool", .pid = 20, .waiters = 1, .slots = 4, .acquired_at = 1000, .command = "a" },
        .{ .name = "pool", .pid = 10, .waiters = 1, .slots = 4, .acquired_at = 1060, .command = "c" },
    };
    std.mem.sort(protocol.LockInfo, &lock_infos, {}, lockInfoLessThan);

    try std.testing.expectEqualStrings(
        \\NAME   PID  ELAPSED  WAITERS  MODE       SLOTS  CMD
        \\build  123    01:05        0  exclusive    1/1  make
        \\pool    20    01:05        1  exclusive    3/4  a
        \\pool    10    00:05        1  exclusive    3/4  c
        \\pool    30    00:05        1  exclusive    3/4  b
        \\
    , try formatLockInfoTable(arena, &lock_infos, true, 1065));
    try std.testing.expectEqualStrings("build\npool\n", try formatLockNames(arena, &lock_infos));
}

test "formatLockInfoTable shows shared holders without a slot count" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lock_infos = [_]protocol.LockInfo{
        .{ .name = "db", .pid = 10, .waiters = 1, .mode = .shared, .acquired_at = 1000, .command = "./backup.sh" },
        .{ .name = "db", .pid = 20, .waiters = 1, .mode = .shared, .acquired_at = 1060, .command = "./report.sh" },
    };
    try std.testing.expectEqualStrings(
        \\NAME  PID  ELAPSED  WAITERS  MODE    SLOTS  CMD
        \\db     10    01:05        1  shared      -  ./backup.sh
        \\db     20    00:05        1  shared      -  ./report.sh
        \\
    , try formatLockInfoTable(arena, &lock_infos, true, 1065));
}

test "formatLockInfoTable prints only the header when no locks are held" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "NAME  PID  ELAPSED  WAITERS  MODE  SLOTS  CMD\n",
        try formatLockInfoTable(arena, &.{}, true, 0),
    );
    try std.testing.expectEqualStrings("", try formatLockInfoTable(arena, &.{}, false, 0));
}
