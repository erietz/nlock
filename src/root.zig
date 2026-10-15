const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_zig_zon = @import("build_zig_zon");
const protocol = @import("protocol.zig");
const hash = @import("hash.zig");
const queue = @import("queue.zig");
pub const logger = @import("logger.zig");
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
/// 4. `/tmp/nlock-<uid>.sock`
///
/// The per-user directories are private to the user, so nobody else can
/// create a socket there first and impersonate the daemon.
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
    return std.fmt.allocPrint(allocator, "/tmp/nlock-{d}.sock", .{std.c.getuid()});
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
        const expected = try std.fmt.allocPrint(allocator, "/tmp/nlock-{d}.sock", .{std.c.getuid()});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, path);
    }
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
    _ = logger;
}
