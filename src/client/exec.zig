const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const log = nlock.Logger.log;
const printer = @import("printer.zig");

/// Handler which does absolutely nothing installed while the command runs. A
/// handler rather than SIG_IGN, because ignored signals are inherited across
/// exec while handlers are reset to the default, so the child still gets the
/// usual behavior.
fn ignoreSignal(_: std.posix.SIG) callconv(.c) void {}

/// Signals the terminal sends to the whole foreground process group. The
/// child receives them too, so nlock outlives it and can release the lock.
const terminal_signals = [_]std.posix.SIG{ .INT, .QUIT };

/// Signals asking nlock to stop, from `kill`, `timeout`, a service manager or
/// a closing terminal. They are passed on to the command instead, so the
/// lock is released only once the command has exited. Were nlock to die
/// first, the daemon would release the lock with the command still running.
const forwarded_signals = [_]std.posix.SIG{ .TERM, .HUP };

const SigNum = std.meta.Tag(std.posix.SIG);

/// Pid of the running command, or 0 before it has started.
var forward_pid: std.atomic.Value(std.posix.pid_t) = .init(0);
/// The last forwarded signal received, or 0 if none.
var forward_sig: std.atomic.Value(SigNum) = .init(0);

/// Signal handlers may run on any thread, including while the command is
/// being started. The handler records the signal before reading the pid, and
/// `runCommand` records the pid before reading the signal, so at least one
/// of them sees the other's write and the command always gets the signal
/// (occasionally twice).
fn forwardSignal(sig: std.posix.SIG) callconv(.c) void {
    forward_sig.store(@backingInt(sig), .seq_cst);
    const pid = forward_pid.load(.seq_cst);
    if (pid > 0) _ = std.c.kill(pid, sig);
}

/// Exit statuses for a command that could not be started, as used by shells
/// and by `env`, `nohup` and `flock`.
const exit_not_executable = 126;
const exit_not_found = 127;

/// Runs the command and returns its exit status, or 128 plus the signal
/// number if a signal ended it, as a shell reports it.
pub fn runCommand(io: Io, command: []const []const u8) u8 {
    var old_actions: [terminal_signals.len]std.posix.Sigaction = undefined;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = ignoreSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    for (terminal_signals, &old_actions) |sig, *old| std.posix.sigaction(sig, &act, old);
    defer for (terminal_signals, &old_actions) |sig, *old| std.posix.sigaction(sig, old, null);

    forward_pid.store(0, .seq_cst);
    forward_sig.store(0, .seq_cst);
    var old_forward_actions: [forwarded_signals.len]std.posix.Sigaction = undefined;
    const forward_act: std.posix.Sigaction = .{
        .handler = .{ .handler = forwardSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    for (forwarded_signals, &old_forward_actions) |sig, *old| std.posix.sigaction(sig, &forward_act, old);
    defer for (forwarded_signals, &old_forward_actions) |sig, *old| std.posix.sigaction(sig, old, null);
    defer forward_pid.store(0, .seq_cst);

    const spawnOptions: std.process.SpawnOptions = .{
        .argv = command,
    };

    var child = std.process.spawn(io, spawnOptions) catch |err| {
        printer.eprint("nlock: {s}: {s}\n", .{ command[0], @errorName(err) }) catch {};
        return switch (err) {
            error.FileNotFound => exit_not_found,
            else => exit_not_executable,
        };
    };

    if (child.id) |pid| {
        forward_pid.store(pid, .seq_cst);
        // A signal that arrived while the command was starting.
        const sig = forward_sig.load(.seq_cst);
        if (sig != 0) _ = std.c.kill(pid, @fromBackingInt(@intCast(sig)));
    }

    const term = child.wait(io) catch |err| {
        printer.eprint("nlock: failed to wait for {s}: {s}\n", .{ command[0], @errorName(err) }) catch {};
        return 1;
    };

    switch (term) {
        .exited => |code| {
            log(.debug, "Process exited with code: {d}", .{code});
            return code;
        },
        .signal, .stopped => |sig| {
            log(.debug, "Process ended by signal: {d}", .{@backingInt(sig)});
            return 128 +| @as(u8, @intCast(@backingInt(sig)));
        },
        .unknown => |status| {
            log(.debug, "Process ended with unknown status: {d}", .{status});
            return 1;
        },
    }
}
