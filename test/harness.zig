//! Helpers for integration tests that drive the real `nlockd` and `nlock`
//! binaries as child processes.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const nlock = @import("nlock");

/// A running `nlockd` listening on a private socket inside a temporary
/// directory, so tests never touch a real daemon or each other.
pub const Daemon = struct {
    tmp: std.testing.TmpDir,
    socket_path: []const u8,
    environ: std.process.Environ.Map,
    child: std.process.Child,

    pub fn start(gpa: std.mem.Allocator, io: Io) !*Daemon {
        const self = try gpa.create(Daemon);
        errdefer gpa.destroy(self);

        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();

        // Relative to the cwd shared by the test runner and its children;
        // keeps the path well under the ~104 byte limit for unix sockets.
        self.socket_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/nlock.sock", .{self.tmp.sub_path});
        errdefer gpa.free(self.socket_path);

        self.environ = .init(gpa);
        errdefer self.environ.deinit();
        try self.environ.put(nlock.ENV_SOCKET_PATH, self.socket_path);

        self.child = try spawnDaemon(io, &self.environ);
        errdefer self.child.kill(io);

        try waitForSocket(io, self.socket_path);
        return self;
    }

    /// Kills the daemon with SIGKILL, so it leaves its socket file behind,
    /// then starts a new one on the same socket. Safe to call after the
    /// daemon has already exited and been waited on.
    pub fn restart(self: *Daemon, io: Io) !void {
        self.child.kill(io);
        self.child = try spawnDaemon(io, &self.environ);
        try waitForSocket(io, self.socket_path);
    }

    pub fn stop(self: *Daemon, gpa: std.mem.Allocator, io: Io) void {
        self.child.kill(io);
        self.environ.deinit();
        gpa.free(self.socket_path);
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    /// Runs `nlock` with `args` against this daemon and collects its output.
    /// Caller owns `stdout` and `stderr` of the result.
    pub fn client(self: *Daemon, gpa: std.mem.Allocator, io: Io, args: []const []const u8) !std.process.RunResult {
        const argv = try clientArgv(gpa, args);
        defer gpa.free(argv);

        return std.process.run(gpa, io, .{
            .argv = argv,
            .environ_map = &self.environ,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        });
    }

    /// Starts `nlock` with `args` against this daemon without waiting for it.
    /// Caller must `wait` (or `kill`) the returned child.
    pub fn spawnClient(self: *Daemon, gpa: std.mem.Allocator, io: Io, args: []const []const u8) !std.process.Child {
        const argv = try clientArgv(gpa, args);
        defer gpa.free(argv);

        return std.process.spawn(io, .{
            .argv = argv,
            .environ_map = &self.environ,
            .stdout = .ignore,
            .stderr = .ignore,
        });
    }

    /// Returns the path of `name` inside this daemon's temporary directory,
    /// relative to the cwd shared with child processes. Caller owns the result.
    pub fn tmpPath(self: *Daemon, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ self.tmp.sub_path, name });
    }
};

fn spawnDaemon(io: Io, environ: *const std.process.Environ.Map) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{build_options.nlockd_path},
        .environ_map = environ,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn clientArgv(gpa: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    const argv = try gpa.alloc([]const u8, args.len + 1);
    argv[0] = build_options.nlock_path;
    @memcpy(argv[1..], args);
    return argv;
}

/// Polls until something accepts connections on `socket_path`, or gives up
/// after roughly five seconds.
fn waitForSocket(io: Io, socket_path: []const u8) !void {
    const address = try Io.net.UnixAddress.init(socket_path);
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        if (address.connect(io)) |stream| {
            stream.close(io);
            return;
        } else |_| {
            try io.sleep(.fromMilliseconds(10), .awake);
        }
    }
    return error.DaemonDidNotStart;
}
