const std = @import("std");
const build_zig_zon = @import("build_zig_zon");
const protocol = @import("protocol.zig");
pub const Logger = @import("Logger.zig");
pub const peer = @import("peer.zig");
const paths = @import("paths.zig");
const sysexits = @import("sysexits.zig");

pub const SOCKET_NAME = paths.SOCKET_NAME;
pub const ENV_SOCKET_PATH = paths.ENV_SOCKET_PATH;
pub const getSocketPath = paths.getSocketPath;
pub const fallbackSocketDir = paths.fallbackSocketDir;

pub fn version() []const u8 {
    return build_zig_zon.version;
}

pub const LockResponseStatus = protocol.LockResponseStatus;
pub const LockRequest = protocol.LockRequest;
pub const LockResponse = protocol.LockResponse;
pub const LockInfo = protocol.LockInfo;
pub const writeLine = protocol.writeLine;
pub const max_name_len = protocol.max_name_len;
pub const max_command_len = protocol.max_command_len;
pub const max_message_len = protocol.max_message_len;
pub const SysExits = sysexits.SysExits;

test {
    std.testing.refAllDecls(@This());
    _ = paths;
    _ = sysexits;
}
