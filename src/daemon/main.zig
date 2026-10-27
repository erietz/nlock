const std = @import("std");
const server = @import("server.zig");
const syslog = @import("syslog.zig");

pub const std_options: std.Options = .{
    // Release builds would otherwise compile out debug messages, leaving
    // NLOCK_LOG_LEVEL=debug no effect. NLOCK_LOG_LEVEL does the filtering.
    .log_level = .debug,
    .logFn = syslog.logFn,
};

pub fn main(init: std.process.Init) void {
    const stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false;
    if (!stderr_is_tty) {
        std.c.openlog("nlockd", syslog.LOG_PID, syslog.LOG_DAEMON);
        syslog.log_to_syslog = true;
    }
    run(init) catch |err| {
        // Reported regardless of NLOCK_LOG_LEVEL: the daemon is exiting.
        // Always printed to stderr so whoever started nlockd sees why, and
        // also sent to syslog when that is where the daemon's logs go.
        switch (err) {
            error.AlreadyRunning => {
                std.debug.print("nlockd: another nlockd is already running on this socket\n", .{});
                if (syslog.log_to_syslog) std.log.err("another nlockd is already running on this socket", .{});
            },
            error.SocketDirNotPrivate => {
                const message = "/tmp/nlock-{d} is not a directory of yours; remove it or set NLOCK_SOCKET";
                std.debug.print("nlockd: " ++ message ++ "\n", .{std.c.getuid()});
                if (syslog.log_to_syslog) std.log.err(message, .{std.c.getuid()});
            },
            else => {
                std.debug.print("nlockd: {s}\n", .{@errorName(err)});
                if (syslog.log_to_syslog) std.log.err("{s}", .{@errorName(err)});
            },
        }
        std.process.exit(1);
    };
}

pub fn run(init: std.process.Init) !void {
    // Start the server to listen for incoming connections
    try server.runServer(init);
}

test {
    _ = @import("hash.zig");
    _ = @import("queue.zig");
    _ = @import("connection.zig");
    _ = @import("locks.zig");
    _ = @import("rate.zig");
    _ = server;
    _ = syslog;
}
