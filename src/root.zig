const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");
const hash = @import("hash.zig");
const queue = @import("queue.zig");
pub const logger = @import("logger.zig");
pub const printer = @import("printer.zig");
pub const cli = @import("cli.zig");
pub const peer = @import("peer.zig");

pub const SOCKET_PATH = "/tmp/nlock.sock";
pub const ENV_SOCKET_PATH = "NLOCK_SOCKET";

/// Returns the socket path from the `NLOCK_SOCKET` environment variable,
/// falling back to `SOCKET_PATH`.
pub fn getSocketPath(environ_map: *const std.process.Environ.Map) []const u8 {
    return environ_map.get(ENV_SOCKET_PATH) orelse SOCKET_PATH;
}
pub const LockResponseStatus = protocol.LockResponseStatus;
pub const LockRequestType = protocol.LockRequestType;
pub const LockRequest = protocol.LockRequest;
pub const LockResponse = protocol.LockResponse;
pub const LockInfo = protocol.LockInfo;
pub const writeLine = protocol.writeLine;
pub const ThreadSafeHashMap = hash.ThreadSafeHashMap;
pub const Lock = queue.Lock;
pub const Waiter = queue.Waiter;

test {
    _ = cli;
    _ = protocol;
    _ = hash;
    _ = queue;
    _ = peer;
}

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}
