//! Code shared by `nlock` and `nlockd`: only what both must agree on, such as
//! the wire protocol, the socket path, peer checks and exit codes. Code used
//! by just one of them lives in `client/` or `daemon/`, even if it looks
//! reusable; move it here once the other side needs it.

const std = @import("std");
const build_zig_zon = @import("build_zig_zon");

pub const protocol = @import("protocol.zig");
pub const paths = @import("paths.zig");
pub const peer = @import("peer.zig");
pub const Logger = @import("Logger.zig");
pub const SysExits = @import("sysexits.zig").SysExits;

pub fn version() []const u8 {
    return build_zig_zon.version;
}

test {
    std.testing.refAllDecls(@This());
}
