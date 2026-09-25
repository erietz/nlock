const std = @import("std");
const Io = std.Io;
const options = @import("options.zig");
const cli = @import("cli.zig");
const protocol = @import("protocol.zig");

pub const SOCKET_PATH = "/tmp/nlock.sock";
pub const Options = options.Options;
pub const usage = cli.usage;
pub const LockResponseStatus = protocol.LockResponseStatus;
pub const LockRequestType = protocol.LockRequestType;
pub const LockRequest = protocol.LockRequest;
pub const LockResponse = protocol.LockResponse;

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn writeLine(writer: *Io.Writer, message: []const u8) Io.Writer.Error!void {
    try writer.writeAll(message);
    try writer.writeAll("\n");
    try writer.flush();
}
