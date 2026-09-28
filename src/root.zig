const std = @import("std");
const Io = std.Io;
const options = @import("options.zig");
const cli = @import("cli.zig");
const protocol = @import("protocol.zig");
const hash = @import("hash.zig");

pub const SOCKET_PATH = "/tmp/nlock.sock";
pub const Command = options.Command;
pub const RunOptions = options.RunOptions;
pub const usage = cli.usage;
pub const LockResponseStatus = protocol.LockResponseStatus;
pub const LockRequestType = protocol.LockRequestType;
pub const LockRequest = protocol.LockRequest;
pub const LockResponse = protocol.LockResponse;
pub const writeLine = protocol.writeLine;
pub const ThreadSafeHashMap = hash.ThreadSafeHashMap;

test {
    _ = options;
    _ = cli;
    _ = protocol;
}

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}
