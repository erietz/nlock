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
