const std = @import("std");

/// Whether log messages go to syslog instead of stderr. Set once at startup.
///
/// nlockd logs to stderr when stderr is a terminal (someone is running it by
/// hand) and to syslog otherwise (it is running under a service manager).
/// launchd discards a job's stderr unless the plist names a file for it, and
/// that file is never rotated, whereas syslog messages reach the macOS
/// unified log (`log stream --process nlockd --level debug`) and the systemd
/// journal (`journalctl --user -u nlockd`), both of which are rotated and
/// keep each message's level. See nlockd(1), section LOGGING.
pub var log_to_syslog = false;

/// syslog(3) priorities and options. They have the same values on Linux and
/// macOS.
const LOG_ERR = 3;
const LOG_WARNING = 4;
const LOG_INFO = 6;
const LOG_DEBUG = 7;
pub const LOG_PID = 0x01;
pub const LOG_DAEMON = 3 << 3;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!log_to_syslog) return std.log.defaultLog(level, scope, format, args);

    const priority = switch (level) {
        .err => LOG_ERR,
        .warn => LOG_WARNING,
        .info => LOG_INFO,
        .debug => LOG_DEBUG,
    };
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    // Messages longer than the buffer are truncated.
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    w.print(prefix ++ format, args) catch {};
    buf[w.end] = 0;
    std.c.syslog(priority, "%s", @as([*:0]const u8, buf[0..w.end :0]));
}
