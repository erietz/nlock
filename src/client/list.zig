const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
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
    const list_message = try (nlock.LockRequest{ .list = {} }).toJson(allocator);
    defer allocator.free(list_message);

    try nlock.writeLine(writer, list_message);

    // Everything below is short-lived, so free it all at once.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lock_infos = try readLockInfos(reader, arena);
    // The daemon walks a hash map, so impose a stable order.
    std.mem.sort(nlock.LockInfo, lock_infos.items, {}, lockInfoLessThan);

    const output = if (options.json)
        try formatLockInfoJson(arena, lock_infos.items)
    else if (options.quiet)
        try formatLockNames(arena, lock_infos.items)
    else
        try formatLockInfoTable(arena, lock_infos.items, options.header, format.nowSeconds(io));

    try printer.print("{s}", .{output});
}

fn lockInfoLessThan(_: void, a: nlock.LockInfo, b: nlock.LockInfo) bool {
    return std.mem.lessThan(u8, a.name, b.name);
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
