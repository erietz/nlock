const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const protocol = @import("protocol.zig");
const hash = @import("hash.zig");
const queue = @import("queue.zig");

pub const SOCKET_PATH = "/tmp/nlock.sock";
pub const SOCKET_PATH_ENV = "NLOCK_SOCKET";

/// Returns the socket path from the `NLOCK_SOCKET` environment variable,
/// falling back to `SOCKET_PATH`.
pub fn socketPath(environ_map: *const std.process.Environ.Map) []const u8 {
    return environ_map.get(SOCKET_PATH_ENV) orelse SOCKET_PATH;
}
pub const Command = cli.Command;
pub const RunOptions = cli.RunOptions;
pub const usage = cli.usage;
pub const LockResponseStatus = protocol.LockResponseStatus;
pub const LockRequestType = protocol.LockRequestType;
pub const LockRequest = protocol.LockRequest;
pub const LockResponse = protocol.LockResponse;
pub const writeLine = protocol.writeLine;
pub const ThreadSafeHashMap = hash.ThreadSafeHashMap;
pub const Lock = queue.Lock;
pub const Waiter = queue.Waiter;

test {
    _ = cli;
    _ = protocol;
    _ = hash;
    _ = queue;
}

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}
