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
