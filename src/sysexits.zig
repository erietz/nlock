const std = @import("std");

/// Exit status codes for programs, as defined in sysexits.h.
/// Rather than @cImport("sysexits.h"), which is removed in zig 17, we define
/// the constants ourselves. See https://man.openbsd.org/sysexits
pub const SysExits = enum(u8) {
    /// Successful termination
    ok = 0,
    /// The command was used incorrectly, e.g., with the wrong number of
    /// arguments, a bad flag, bad syntax in a parameter, or whatever.
    usage = 64,
    /// The input data was incorrect in some way. This should only be used for
    /// user's data and not system files.
    dataerr = 65,
    /// An input file (not a system file) did not exist or was not
    /// readable. This could also include errors like “No message” to
    /// a mailer (if it cared to catch it).
    noinput = 66,
    /// The user specified did not exist. This might be used for mail
    /// addresses or remote logins.
    nouser = 67,
    /// The host specified did not exist. This is used in mail
    /// addresses or network requests.
    nohost = 68,
    /// A service is unavailable. This can occur if a support program
    /// or file does not exist. This can also be used as a catch-all
    /// message when something you wanted to do doesn't work, but you
    /// don't know why.
    unavailable = 69,
    /// An internal software error has been detected. This should be
    /// limited to non-operating system related errors if possible.
    software = 70,
    /// An operating system error has been detected. This is intended
    /// to be used for such things as “cannot fork”, or “cannot create
    /// pipe”. It includes things like getuid(2) returning a user that
    /// does not exist in the passwd file.
    oserr = 71,
    /// Some system file (e.g., /etc/passwd, /var/run/utmp) does not
    /// exist, cannot be opened, or has some sort of error (e.g.,
    /// syntax error).
    osfile = 72,
    /// A (user specified) output file cannot be created.
    cantcreat = 73,
    /// An error occurred while doing I/O on some file.
    ioerr = 74,
    /// Temporary failure, indicating something that is not really an error.
    /// For example that a mailer could not create a connection, and the
    /// request should be reattempted later.
    tempfail = 75,
    /// The remote system returned something that was “not possible” during a
    /// protocol exchange.
    protocol = 76,
    /// You did not have sufficient permission to perform the operation. This
    /// is not intended for file system problems, which should use EX_NOINPUT
    /// or EX_CANTCREAT, but rather for higher level permissions.
    noperm = 77,
    /// Something was found in an unconfigured or misconfigured state. The
    /// numerical values corresponding to the symbolical ones are given in
    /// parentheses for easy reference.
    config = 78,

    /// Exit the program with the given exit status code.
    pub fn exit(self: SysExits) noreturn {
        std.process.exit(@backingInt(self));
    }
};
