const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const log = nlock.Logger.log;
const cli = @import("cli.zig");
const printer = @import("printer.zig");
const exec = @import("exec.zig");
const list = @import("list.zig");
const lock = @import("lock.zig");

pub const std_options: std.Options = .{
    // Release builds would otherwise compile out debug messages, leaving
    // NLOCK_LOG_LEVEL=debug no effect. NLOCK_LOG_LEVEL does the filtering.
    .log_level = .debug,
};

const Context = struct {
    io: Io,
    reader: *Io.Reader,
    writer: *Io.Writer,
    allocator: std.mem.Allocator,
};

const RunLockedError = error{
    LockAlreadyAcquired,
    LockAcquireTimeout,
    LockReleaseFailed,
};

pub fn main(init: std.process.Init) void {
    printer.init(init.io);
    nlock.Logger.init(nlock.Logger.getLogLevel(init.environ_map) catch blk: {
        printer.eprint(
            "nlock: ignoring invalid {s}; expected debug, info, warn, error or none\n",
            .{nlock.Logger.ENV_NLOCK_LOG_LEVEL},
        ) catch {};
        break :blk null;
    });

    const status = run(init) catch |err| {
        printer.eprint("nlock: unexpected error: {s}\n", .{@errorName(err)}) catch {};
        nlock.SysExits.software.exit();
    };
    std.process.exit(status);
}

/// Returns the exit status for nlock: the command's for `run`, 0 for `list`.
pub fn run(init: std.process.Init) !u8 {
    const args = init.minimal.args.toSlice(init.gpa) catch nlock.SysExits.oserr.exit();
    defer init.gpa.free(args);
    const command = cli.Command.parseArgs(args) catch |err| switch (err) {
        cli.UsageError.InvalidArguments => {
            printer.eprint("{s}", .{cli.USAGE}) catch nlock.SysExits.oserr.exit();
            nlock.SysExits.usage.exit();
        },
    };

    // No need to connect to the daemon for `help` or `version`, so do them
    // first to avoid unnecessary errors if the daemon is not running.
    switch (command) {
        .help => {
            printer.print("{s}", .{cli.HELP}) catch nlock.SysExits.oserr.exit();
            nlock.SysExits.ok.exit();
        },
        .version => {
            printVersion() catch nlock.SysExits.oserr.exit();
            nlock.SysExits.ok.exit();
        },
        .run, .list => {},
    }

    const socket_path = try nlock.getSocketPath(init.gpa, init.environ_map);
    defer init.gpa.free(socket_path);
    log(.debug, "Connecting to lock server at {s}", .{socket_path});

    const address = std.Io.net.UnixAddress.init(socket_path) catch nlock.SysExits.osfile.exit();
    const stream = address.connect(init.io) catch |err| {
        printer.eprint(
            "nlock: cannot reach nlockd at {s}: {s}; is it running?\n",
            .{ socket_path, @errorName(err) },
        ) catch nlock.SysExits.oserr.exit();
        nlock.SysExits.unavailable.exit();
    };
    defer stream.close(init.io);
    verifyServer(stream) catch |err| switch (err) {
        error.UntrustedLockServer => {
            printer.eprint(
                "nlock: refusing to use {s}: it is served by another user's nlockd\n",
                .{socket_path},
            ) catch nlock.SysExits.oserr.exit();
            nlock.SysExits.unavailable.exit();
        },
        else => {
            printer.eprint(
                "nlock: cannot verify who serves {s}: {s}\n",
                .{ socket_path, @errorName(err) },
            ) catch nlock.SysExits.oserr.exit();
            nlock.SysExits.software.exit();
        },
    };

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(init.io, &write_buffer);

    var read_buffer: [nlock.max_message_len]u8 = undefined;
    var reader = stream.reader(init.io, &read_buffer);

    const ctx = Context{
        .io = init.io,
        .reader = &reader.interface,
        .writer = &writer.interface,
        .allocator = init.gpa,
    };

    switch (command) {
        .run => |options| return runLocked(ctx, options) catch |err| switch (err) {
            RunLockedError.LockAlreadyAcquired => {
                printer.eprint(
                    "nlock: '{s}' is held by another process\n",
                    .{options.name},
                ) catch nlock.SysExits.oserr.exit();
                nlock.SysExits.tempfail.exit();
            },
            RunLockedError.LockAcquireTimeout => {
                printer.eprint(
                    "nlock: timed out waiting for '{s}'\n",
                    .{options.name},
                ) catch nlock.SysExits.oserr.exit();
                nlock.SysExits.tempfail.exit();
            },
            RunLockedError.LockReleaseFailed => {
                printer.eprint(
                    "nlock: failed to release '{s}'; see the nlockd logs\n",
                    .{options.name},
                ) catch nlock.SysExits.oserr.exit();
                nlock.SysExits.software.exit();
            },
            else => {
                return err;
            },
        },
        .list => |options| {
            try list.runList(ctx.io, ctx.allocator, ctx.writer, ctx.reader, options);
            return 0;
        },
        // Handled before connecting.
        .help, .version => unreachable,
    }
}

fn printVersion() !void {
    try printer.print("nlock {s}\n", .{nlock.version()});
}

/// Refuses to talk to a daemon run by another user (other than root), in case
/// someone else created a socket at our path to impersonate it.
fn verifyServer(stream: std.Io.net.Stream) !void {
    const server = try nlock.peer.peerCredentials(stream);
    const uid = std.c.getuid();
    if (server.uid != uid and server.uid != 0) {
        log(.err, "Lock server is run by uid {d}, expected {d} or root", .{ server.uid, uid });
        return error.UntrustedLockServer;
    }
}

/// Runs the command under the lock and returns its exit status.
pub fn runLocked(ctx: Context, options: cli.RunOptions) !u8 {
    // Only explain a wait, or not running, to a person: scripts and cron jobs
    // would just get noise on stderr.
    const report = Io.File.stderr().isTty(ctx.io) catch false;
    const acquire_status = try lock.acquireLock(
        ctx.io,
        ctx.allocator,
        ctx.writer,
        ctx.reader,
        options,
        report,
    );

    switch (acquire_status) {
        nlock.LockResponseStatus.ok => {
            log(.debug, "Lock acquired successfully. Running command", .{});
            // runCommand reports its own failures as an exit status, so the
            // lock is always released below.
            const status = exec.runCommand(ctx.io, options.command);
            log(.debug, "Command finished. Releasing lock: {s}", .{options.name});

            const release_status = try lock.releaseLock(ctx.allocator, ctx.writer, ctx.reader);

            switch (release_status) {
                nlock.LockResponseStatus.ok => {
                    log(.debug, "Lock released successfully", .{});
                    return status;
                },
                else => {
                    log(.err, "Failed to release lock. Status: {t}", .{release_status});
                    return RunLockedError.LockReleaseFailed;
                },
            }
        },
        nlock.LockResponseStatus.busy => {
            return RunLockedError.LockAlreadyAcquired;
        },
        nlock.LockResponseStatus.timeout => {
            return RunLockedError.LockAcquireTimeout;
        },
        // A run is pending that will start after this request was made,
        // which is what the caller asked for, so this is success.
        nlock.LockResponseStatus.coalesced, nlock.LockResponseStatus.replaced => {
            log(.debug, "Not running the command: {s}", .{@tagName(acquire_status)});
            return 0;
        },
        // acquireLock reads past queued to the final status.
        nlock.LockResponseStatus.queued => unreachable,
    }
}

test {
    _ = cli;
    _ = printer;
    _ = exec;
    _ = @import("format.zig");
    _ = list;
    _ = lock;
}
