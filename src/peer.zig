const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const Uid = c.uid_t;

extern "c" fn getpeereid(fd: c.fd_t, uid: *c.uid_t, gid: *c.gid_t) c_int;

const ucred = extern struct {
    pid: c.pid_t,
    uid: c.uid_t,
    gid: c.gid_t,
};

/// macOS `getsockopt` level and option for the peer's pid (sys/un.h).
const SOL_LOCAL = 0;
const LOCAL_PEERPID = 0x002;

/// Identity of the process on the other end of a connected Unix domain socket.
pub const Credentials = struct {
    uid: Uid,
    /// 0 if the platform cannot report the peer's pid.
    pid: c.pid_t,
};

/// True if the other end of a connected socket has closed it, e.g. because
/// the process exited or was killed. Never blocks, and leaves anything sent
/// on the socket to be read.
pub fn hungUp(fd: c.fd_t) bool {
    var byte: u8 = undefined;
    const rc = c.recv(fd, &byte, 1, c.MSG.PEEK | c.MSG.DONTWAIT);
    // 0 is the end of the stream. Data means the peer is still there.
    if (rc >= 0) return rc == 0;
    return switch (c.errno(rc)) {
        .AGAIN, .INTR => false,
        // E.g. reset by the peer.
        else => true,
    };
}

test "hungUp tells an open socket from one whose peer has closed it" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(0, c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[0]);

    try std.testing.expect(!hungUp(fds[0]));
    // Unread data does not count, and is still there afterwards.
    try std.testing.expectEqual(1, c.write(fds[1], "x", 1));
    try std.testing.expect(!hungUp(fds[0]));
    try std.testing.expect(!hungUp(fds[0]));

    _ = c.close(fds[1]);
    // Data sent before closing is read first, as with any stream.
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(1, c.read(fds[0], &byte, 1));
    try std.testing.expect(hungUp(fds[0]));
}

/// Returns the credentials of the process on the other end of a connected
/// Unix domain socket. The kernel supplies these, so unlike values sent by
/// the client they cannot be spoofed.
pub fn peerCredentials(stream: std.Io.net.Stream) !Credentials {
    const fd = stream.socket.handle;
    if (builtin.os.tag == .linux) {
        var cred: ucred = undefined;
        var len: c.socklen_t = @sizeOf(ucred);
        if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.PEERCRED, &cred, &len) != 0) {
            return error.PeerCredentialsUnavailable;
        }
        return .{ .uid = cred.uid, .pid = cred.pid };
    } else {
        var uid: c.uid_t = undefined;
        var gid: c.gid_t = undefined;
        if (getpeereid(fd, &uid, &gid) != 0) {
            return error.PeerCredentialsUnavailable;
        }
        var pid: c.pid_t = 0;
        if (builtin.os.tag.isDarwin()) {
            var len: c.socklen_t = @sizeOf(c.pid_t);
            if (c.getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) != 0) {
                return error.PeerCredentialsUnavailable;
            }
        }
        return .{ .uid = uid, .pid = pid };
    }
}
