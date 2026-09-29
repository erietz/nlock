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
        try self.environ.put(nlock.SOCKET_PATH_ENV, self.socket_path);

        self.child = try std.process.spawn(io, .{
            .argv = &.{build_options.nlockd_path},
            .environ_map = &self.environ,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        errdefer self.child.kill(io);

        try waitForSocket(io, self.socket_path);
        return self;
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
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, build_options.nlock_path);
        try argv.appendSlice(gpa, args);

        return std.process.run(gpa, io, .{
            .argv = argv.items,
            .environ_map = &self.environ,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        });
    }
};

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
