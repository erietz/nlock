const std = @import("std");
const Io = std.Io;

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
