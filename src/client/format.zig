const std = @import("std");
const Io = std.Io;
const protocol = @import("nlock").protocol;

/// The current wall-clock time in seconds, as `formatElapsed` compares it
/// against the daemon's timestamps.
pub fn nowSeconds(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds();
}

/// Formats a duration like `ps -o etime`: `[[dd-]hh:]mm:ss`.
pub fn formatElapsed(allocator: std.mem.Allocator, seconds: i64) ![]const u8 {
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

/// Formats a rate limit the way `--rate` accepts it, in the largest unit
/// that divides its period: `30/m`, `3/10s`, `100/2h`.
pub fn formatRate(allocator: std.mem.Allocator, rate: protocol.Rate) ![]const u8 {
    const units = [_]struct { name: []const u8, s: u32 }{
        .{ .name = "d", .s = std.time.s_per_day },
        .{ .name = "h", .s = std.time.s_per_hour },
        .{ .name = "m", .s = std.time.s_per_min },
        .{ .name = "s", .s = 1 },
    };
    const unit = for (units) |unit| {
        if (rate.period_s % unit.s == 0) break unit;
    } else unreachable; // Every period is a whole number of seconds.
    const amount = rate.period_s / unit.s;
    if (amount == 1) return std.fmt.allocPrint(allocator, "{d}/{s}", .{ rate.count, unit.name });
    return std.fmt.allocPrint(allocator, "{d}/{d}{s}", .{ rate.count, amount, unit.name });
}

/// Appends `s` with control characters escaped (`\n`, `\t`, `\r`, `\xNN`)
/// so that each lock always occupies exactly one line.
pub fn appendEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
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

test "formatRate uses the largest unit that divides the period" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("30/m", try formatRate(arena, .{ .count = 30, .period_s = 60 }));
    try std.testing.expectEqualStrings("10/s", try formatRate(arena, .{ .count = 10, .period_s = 1 }));
    try std.testing.expectEqualStrings("3/10s", try formatRate(arena, .{ .count = 3, .period_s = 10 }));
    try std.testing.expectEqualStrings("5000/h", try formatRate(arena, .{ .count = 5000, .period_s = 3600 }));
    try std.testing.expectEqualStrings("100/2h", try formatRate(arena, .{ .count = 100, .period_s = 7200 }));
    try std.testing.expectEqualStrings("100/90m", try formatRate(arena, .{ .count = 100, .period_s = 5400 }));
    try std.testing.expectEqualStrings("1/d", try formatRate(arena, .{ .count = 1, .period_s = 86400 }));
    try std.testing.expectEqualStrings("1/61s", try formatRate(arena, .{ .count = 1, .period_s = 61 }));
}
