const std = @import("std");
const harness = @import("harness.zig");

const Term = std.process.Child.Term;

test "client runs a command under a lock" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const result = try daemon.client(gpa, io, &.{ "run", "mylock", "--", "echo", "hello" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("hello\n", result.stdout);
}

test "lock can be reacquired after it is released" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    for (0..2) |_| {
        const result = try daemon.client(gpa, io, &.{ "run", "mylock", "--", "true" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
    }
}

test "list succeeds with no locks held" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const result = try daemon.client(gpa, io, &.{"list"});
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("", result.stdout);
}

test "client fails when no daemon is running" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("NLOCK_SOCKET", ".zig-cache/tmp/nlock-does-not-exist.sock");

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ @import("build_options").nlock_path, "run", "mylock", "--", "true" },
        .environ_map = &environ,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try std.testing.expectEqual(Term{ .exited = 1 }, result.term);
}
