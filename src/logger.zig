const std = @import("std");
const Level = std.log.Level;

pub const ENV_NLOCK_LOG_LEVEL = "NLOCK_LOG_LEVEL";

/// Least severe level that is logged, or null to log nothing (the default).
var threshold: ?Level = null;

pub fn init(level: ?Level) void {
    threshold = level;
}

/// Reads NLOCK_LOG_LEVEL: `debug`, `info`, `warn`, `error` or `none`, in any
/// case. Unset means `none`.
pub fn getLogLevel(environ_map: *const std.process.Environ.Map) error{InvalidLogLevel}!?Level {
    return parseLevel(environ_map.get(ENV_NLOCK_LOG_LEVEL) orelse return null);
}

fn parseLevel(value: []const u8) error{InvalidLogLevel}!?Level {
    if (std.ascii.eqlIgnoreCase(value, "none")) return null;
    // std.log calls the most severe level `err`; accept the usual `error`.
    if (std.ascii.eqlIgnoreCase(value, "error")) return .err;
    inline for (.{ Level.warn, Level.info, Level.debug }) |level| {
        if (std.ascii.eqlIgnoreCase(value, @tagName(level))) return level;
    }
    return error.InvalidLogLevel;
}

/// Returns true if a message at `level` is logged when the least severe
/// level logged is `least_severe`.
fn enabled(level: Level, least_severe: ?Level) bool {
    const t = least_severe orelse return false;
    return @intFromEnum(level) <= @intFromEnum(t);
}

pub fn log(comptime level: Level, comptime format: []const u8, args: anytype) void {
    if (!enabled(level, threshold)) return;
    switch (level) {
        .err => std.log.err(format, args),
        .warn => std.log.warn(format, args),
        .info => std.log.info(format, args),
        .debug => std.log.debug(format, args),
    }
}

test "parseLevel" {
    try std.testing.expectEqual(@as(?Level, .debug), try parseLevel("debug"));
    try std.testing.expectEqual(@as(?Level, .debug), try parseLevel("Debug"));
    try std.testing.expectEqual(@as(?Level, .info), try parseLevel("INFO"));
    try std.testing.expectEqual(@as(?Level, .warn), try parseLevel("warn"));
    try std.testing.expectEqual(@as(?Level, .err), try parseLevel("Error"));
    try std.testing.expectEqual(@as(?Level, null), try parseLevel("None"));
    try std.testing.expectError(error.InvalidLogLevel, parseLevel("verbose"));
    try std.testing.expectError(error.InvalidLogLevel, parseLevel(""));
}

test "enabled" {
    try std.testing.expect(!enabled(.err, null));
    try std.testing.expect(!enabled(.debug, null));
    try std.testing.expect(enabled(.debug, .debug));
    try std.testing.expect(enabled(.err, .debug));
    try std.testing.expect(!enabled(.info, .warn));
    try std.testing.expect(enabled(.warn, .warn));
}
