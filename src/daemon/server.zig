const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const log = nlock.Logger.log;
const connection = @import("connection.zig");
const LockMap = @import("locks.zig").LockMap;

pub fn runServer(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    nlock.Logger.init(nlock.Logger.getLogLevel(init.environ_map) catch blk: {
        std.debug.print(
            "nlockd: ignoring invalid {s}; expected debug, info, warn, error or none\n",
            .{nlock.Logger.ENV_NLOCK_LOG_LEVEL},
        );
        break :blk null;
    });

    // Everything the daemon creates (lock file, socket) is for this user only.
    _ = std.c.umask(0o077);

    // Every client holding or waiting for a lock keeps a connection, and so
    // a file descriptor, open. Service managers start daemons with a low soft
    // limit (1024 under systemd, 256 under launchd), past which new clients
    // cannot connect, so raise it as far as the hard limit allows.
    std.process.raiseFileDescriptorLimit();
    if (std.posix.getrlimit(.NOFILE)) |limit| {
        log(.info, "File descriptor limit: {d}", .{limit.cur});
    } else |_| {}

    const socket_path = try nlock.paths.getSocketPath(gpa, init.environ_map);
    defer gpa.free(socket_path);

    // The fallback directory has a predictable name in the shared /tmp, so
    // make sure it is ours before putting the socket and lock file in it.
    const fallback_dir = try nlock.paths.fallbackSocketDir(gpa);
    defer gpa.free(fallback_dir);
    if (std.mem.eql(u8, std.fs.path.dirname(socket_path) orelse "", fallback_dir)) {
        try makePrivateDir(io, std.Io.Dir.cwd(), fallback_dir);
    }

    // Holding an exclusive lock on `<socket>.lock` for the daemon's lifetime
    // guarantees only one nlockd serves a socket path. The kernel drops the
    // lock however the daemon exits, so it never goes stale. The lock file is
    // deliberately never deleted: removing it would let a second daemon lock
    // a fresh file while the first still holds the old one.
    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{socket_path});
    defer gpa.free(lock_path);
    const lock_file = std.Io.Dir.cwd().createFile(io, lock_path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.AlreadyRunning,
        else => return err,
    };
    defer lock_file.close(io);

    // We hold the lock, so any socket file left at the path belongs to a
    // daemon that is no longer running.
    std.Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};

    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const socket_path_z = try gpa.dupeSentinel(u8, socket_path, 0);
    defer gpa.free(socket_path_z);
    installShutdownHandlers(socket_path_z);
    log(.info, "nlockd version {s}", .{nlock.version()});
    log(.info, "Server started and listening on {s}", .{socket_path});

    var map: LockMap = .init(io, gpa);
    // Declared before `group` so this runs after `group.cancel`: no connection
    // tasks remain, so it is safe to walk the inner map without the mutex.
    defer {
        var it = map.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(gpa);
            gpa.free(entry.key_ptr.*);
        }
        map.deinit();
    }

    // initialize structured task management group
    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled, error.SocketNotListening => return err,
            // Usually temporary, e.g. out of file descriptors because of
            // many open connections. Pause rather than spin, then retry.
            else => {
                log(.err, "Failed to accept connection: {s}", .{@errorName(err)});
                try io.sleep(.fromMilliseconds(100), .awake);
                continue;
            },
        };
        // Spawn a new task to handle the connection
        group.concurrent(io, connection.connectionTask, .{
            io,
            gpa,
            stream,
            &map,
        }) catch |err| {
            log(.err, "Failed to spawn connection task: {s}", .{@errorName(err)});
            stream.close(io);
        };
    }
}

/// Creates the directory `sub_path` in `parent` if it does not exist, and
/// makes sure only this user can use it. It must be a real directory, not a
/// symlink, and it must be ours: only its owner may change its permissions,
/// so failing to set them to 0700 means another user created it.
fn makePrivateDir(io: Io, parent: std.Io.Dir, sub_path: []const u8) !void {
    const private: std.Io.File.Permissions = .fromMode(0o700);
    parent.createDir(io, sub_path, private) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    // `iterate` only to get a real descriptor: without it, Linux opens the
    // directory with O_PATH, which cannot have its permissions changed.
    var dir = parent.openDir(io, sub_path, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
        error.SymLinkLoop, error.NotDir => return error.SocketDirNotPrivate,
        else => return err,
    };
    defer dir.close(io);
    dir.setPermissions(io, private) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SocketDirNotPrivate,
        else => return err,
    };
}

test "makePrivateDir creates a private directory and rejects symlinks" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try makePrivateDir(io, tmp.dir, "new");
    try std.testing.expectEqual(0o700, (try tmp.dir.statFile(io, "new", .{})).permissions.toMode() & 0o777);

    // An existing directory of ours is made private.
    try tmp.dir.createDir(io, "open", .fromMode(0o755));
    try makePrivateDir(io, tmp.dir, "open");
    try std.testing.expectEqual(0o700, (try tmp.dir.statFile(io, "open", .{})).permissions.toMode() & 0o777);

    // A symlink could point anywhere, even to a directory of ours.
    try tmp.dir.symLink(io, "new", "link", .{ .is_directory = true });
    try std.testing.expectError(error.SocketDirNotPrivate, makePrivateDir(io, tmp.dir, "link"));

    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "" });
    try std.testing.expectError(error.SocketDirNotPrivate, makePrivateDir(io, tmp.dir, "file"));
}

/// Socket path removed by `handleShutdownSignal`. Set once before the
/// handlers are installed and never changed afterwards.
var shutdown_socket_path: ?[*:0]const u8 = null;

/// Signals a service manager or terminal sends to stop the daemon.
const shutdown_signals = [_]std.posix.SIG{ .TERM, .INT, .HUP };

/// Removes the socket and exits immediately. Lock state lives only in memory,
/// so there is nothing else to save, and both calls are async-signal-safe.
/// Clients still connected see their connection drop.
fn handleShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    if (shutdown_socket_path) |path| _ = std.c.unlink(path);
    std.c._exit(0);
}

fn installShutdownHandlers(socket_path: [*:0]const u8) void {
    shutdown_socket_path = socket_path;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (shutdown_signals) |sig| std.posix.sigaction(sig, &act, null);
}
