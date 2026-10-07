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

/// Returns the user ID of the process on the other end of a connected Unix
/// domain socket. The kernel supplies this, so unlike a value sent by the
/// client it cannot be spoofed.
pub fn peerUid(stream: std.Io.net.Stream) !Uid {
    const fd = stream.socket.handle;
    if (builtin.os.tag == .linux) {
        var cred: ucred = undefined;
        var len: c.socklen_t = @sizeOf(ucred);
        if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.PEERCRED, &cred, &len) != 0) {
            return error.PeerCredentialsUnavailable;
        }
        return cred.uid;
    } else {
        var uid: c.uid_t = undefined;
        var gid: c.gid_t = undefined;
        if (getpeereid(fd, &uid, &gid) != 0) {
            return error.PeerCredentialsUnavailable;
        }
        return uid;
    }
}

/// Returns the username for `uid`, or the uid formatted into `buf` if it has
/// no passwd entry. The returned name points into libc's static storage and
/// is only valid until the next `getpwuid` call.
pub fn userName(buf: []u8, uid: Uid) []const u8 {
    if (c.getpwuid(uid)) |pw| {
        if (pw.name) |name| return std.mem.span(name);
    }
    return std.fmt.bufPrint(buf, "{d}", .{uid}) catch "?";
}

test "userName resolves the current user" {
    var buf: [16]u8 = undefined;
    const name = userName(&buf, c.getuid());
    try std.testing.expect(name.len > 0);
}

test "userName falls back to the numeric uid" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("4000000000", userName(&buf, 4000000000));
}
