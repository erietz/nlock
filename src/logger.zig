const std = @import("std");

pub const ENV_NLOCK_LOG_LEVEL = "NLOCK_LOG_LEVEL";

pub const LogLevel = enum {
    None,
    Debug,
    Info,
    Warn,
    Error,
};

var log_level: LogLevel = LogLevel.None;

pub fn init(level: LogLevel) void {
    log_level = level;
}

pub fn getLogLevel(environ_map: *const std.process.Environ.Map) LogLevel {
    const log_level_str = environ_map.get(ENV_NLOCK_LOG_LEVEL);
    const level = std.meta.stringToEnum(LogLevel, log_level_str orelse "None") orelse LogLevel.None;
    return level;
}

pub fn log(level: LogLevel, comptime message: []const u8, args: anytype) void {
    if (@intFromEnum(level) >= @intFromEnum(log_level)) {
        switch (level) {
            .None => {},
            .Debug => std.log.debug(message, args),
            .Info => std.log.info(message, args),
            .Warn => std.log.warn(message, args),
            .Error => std.log.err(message, args),
        }
    }
}
