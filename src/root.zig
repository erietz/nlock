const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_zig_zon = @import("build_zig_zon");
const protocol = @import("protocol.zig");
const hash = @import("hash.zig");
const queue = @import("queue.zig");
pub const Logger = @import("Logger.zig");
pub const printer = @import("printer.zig");
pub const cli = @import("cli.zig");
pub const peer = @import("peer.zig");

pub const SOCKET_NAME = "nlock.sock";
pub const ENV_SOCKET_PATH = "NLOCK_SOCKET";

pub fn version() []const u8 {
    return build_zig_zon.version;
}

/// `confstr` name for the per-user temporary directory on macOS (unistd.h).
const _CS_DARWIN_USER_TEMP_DIR = 65537;
extern "c" fn confstr(name: c_int, buf: ?[*]u8, len: usize) usize;

/// Returns the path of the Unix socket that `nlockd` listens on and `nlock`
/// connects to. In order of preference:
///
/// 1. `$NLOCK_SOCKET`
/// 2. Linux: `$XDG_RUNTIME_DIR/nlock.sock`
/// 3. macOS: `nlock.sock` in the per-user temporary directory
///    (`getconf DARWIN_USER_TEMP_DIR`)
/// 4. `nlock.sock` in `fallbackSocketDir()`, `/tmp/nlock-<uid>`
///
/// The per-user directories are private to the user, so nobody else can
/// create a socket there first and impersonate the daemon. `nlockd` creates
/// the fallback directory and checks that it is private before using it.
/// Caller owns the result.
pub fn getSocketPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]u8 {
    if (environ_map.get(ENV_SOCKET_PATH)) |path| {
        if (path.len > 0) return allocator.dupe(u8, path);
    }
    if (builtin.os.tag == .linux) {
        if (environ_map.get("XDG_RUNTIME_DIR")) |dir| {
            if (dir.len > 0) return std.fs.path.join(allocator, &.{ dir, SOCKET_NAME });
        }
    }
    if (builtin.os.tag.isDarwin()) {
        // Read from confstr rather than $TMPDIR so the daemon and the client
        // agree even when started from environments that do not set it.
        var buf: [1024]u8 = undefined;
        const len = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.len);
        if (len > 1 and len <= buf.len) {
            return std.fs.path.join(allocator, &.{ buf[0 .. len - 1], SOCKET_NAME });
        }
    }
    const dir = try fallbackSocketDir(allocator);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, SOCKET_NAME });
}

/// The directory holding the socket when no per-user directory is available,
/// `/tmp/nlock-<uid>`. Caller owns the result.
pub fn fallbackSocketDir(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "/tmp/nlock-{d}", .{std.c.getuid()});
}

test "getSocketPath prefers NLOCK_SOCKET" {
    const allocator = std.testing.allocator;
    var environ: std.process.Environ.Map = .init(allocator);
    defer environ.deinit();
    try environ.put(ENV_SOCKET_PATH, "/some/where.sock");
    try environ.put("XDG_RUNTIME_DIR", "/run/user/1000");

    const path = try getSocketPath(allocator, &environ);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/some/where.sock", path);
}

test "getSocketPath defaults to a per-user path" {
    const allocator = std.testing.allocator;
    var environ: std.process.Environ.Map = .init(allocator);
    defer environ.deinit();
    try environ.put("XDG_RUNTIME_DIR", "/run/user/1000");

    const path = try getSocketPath(allocator, &environ);
    defer allocator.free(path);
    if (builtin.os.tag == .linux) {
        try std.testing.expectEqualStrings("/run/user/1000/nlock.sock", path);
    } else if (builtin.os.tag.isDarwin()) {
        try std.testing.expect(std.mem.endsWith(u8, path, "/T/nlock.sock"));
    } else {
        const expected = try std.fmt.allocPrint(allocator, "/tmp/nlock-{d}/nlock.sock", .{std.c.getuid()});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, path);
    }
}
pub const LockResponseStatus = protocol.LockResponseStatus;
pub const LockRequest = protocol.LockRequest;
pub const LockResponse = protocol.LockResponse;
pub const LockInfo = protocol.LockInfo;
pub const writeLine = protocol.writeLine;
pub const max_name_len = protocol.max_name_len;
pub const max_command_len = protocol.max_command_len;
pub const max_message_len = protocol.max_message_len;
pub const LockedStringMap = hash.LockedStringMap;
pub const Lock = queue.Lock;
pub const Waiter = queue.Waiter;

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
        std.process.exit(@intFromEnum(self));
    }
};

test {
    std.testing.refAllDecls(@This());
}
