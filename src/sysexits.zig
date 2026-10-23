const std = @import("std");

// Rather than @cImport("sysexits.h"), which is removed in zig 17, we define
// the constants ourselves. See https://man.openbsd.org/sysexits
pub const SysExits = enum(u8) {
    ok = 0,
    usage = 64,
    dataerr = 65,
    noinput = 66,
    nouser = 67,
    nohost = 68,
    unavailable = 69,
    software = 70,
    oserr = 71,
    osfile = 72,
    cantcreat = 73,
    ioerr = 74,
    tempfail = 75,
    protocol = 76,
    noperm = 77,
    config = 78,

    pub fn exit(self: SysExits) noreturn {
        std.process.exit(@backingInt(self));
    }
};
