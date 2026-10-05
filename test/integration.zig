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

test "second client waits until the held lock is released" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const log_path = try daemon.tmpPath(gpa, "log");
    defer gpa.free(log_path);
    const go_path = try daemon.tmpPath(gpa, "go");
    defer gpa.free(go_path);

    // Client A takes the lock and holds it until the test creates `go`.
    const script_a = try std.fmt.allocPrint(
        gpa,
        "echo a-start >> {0s}; while [ ! -f {1s} ]; do sleep 0.01; done; echo a-end >> {0s}",
        .{ log_path, go_path },
    );
    defer gpa.free(script_a);
    var client_a = try daemon.spawnClient(gpa, io, &.{ "run", "mylock", "--", "sh", "-c", script_a });
    var a_done = false;
    defer if (!a_done) client_a.kill(io);

    try waitForFileContents(gpa, io, daemon.tmp.dir, "log", "a-start\n");

    // Client B asks for the same lock and should queue behind A.
    const script_b = try std.fmt.allocPrint(gpa, "echo b >> {s}", .{log_path});
    defer gpa.free(script_b);
    var client_b = try daemon.spawnClient(gpa, io, &.{ "run", "mylock", "--", "sh", "-c", script_b });
    var b_done = false;
    defer if (!b_done) client_b.kill(io);

    // Give B time to reach the daemon; it must not run while A holds the lock.
    try io.sleep(.fromMilliseconds(300), .awake);
    try expectFileContents(gpa, io, daemon.tmp.dir, "log", "a-start\n");

    try daemon.tmp.dir.writeFile(io, .{ .sub_path = "go", .data = "" });

    a_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try client_a.wait(io));
    b_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try client_b.wait(io));

    try expectFileContents(gpa, io, daemon.tmp.dir, "log", "a-start\na-end\nb\n");
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
    try std.testing.expectEqualStrings("| NAME | GLOBAL   | CMD |\n", result.stdout);
}

test "three different locks can be held at the same time and listed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    var a_done = false;
    var b_done = false;
    var c_done = false;
    var client_a = try daemon.spawnClient(gpa, io, &.{ "run", "lock-a", "--", "sleep", "1" });
    defer if (!a_done) client_a.kill(io);
    var client_b = try daemon.spawnClient(gpa, io, &.{ "run", "lock-b", "--", "sleep", "1" });
    defer if (!b_done) client_b.kill(io);
    var client_c = try daemon.spawnClient(gpa, io, &.{ "run", "lock-c", "--", "sleep", "1" });
    defer if (!c_done) client_c.kill(io);

    const result = try daemon.client(gpa, io, &.{"list"});
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
    const expected_contents =
        \\| NAME   | GLOBAL   | CMD     |
        \\| lock-b | false    | sleep 1 |
        \\| lock-c | false    | sleep 1 |
        \\| lock-a | false    | sleep 1 |
        \\
    ;
    try std.testing.expectEqualStrings(
        expected_contents,
        result.stdout,
    );

    a_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try client_a.wait(io));
    b_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try client_b.wait(io));
    c_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try client_c.wait(io));
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

fn expectFileContents(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(io, sub_path, gpa, .limited(4096));
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

/// Polls until `sub_path` exists with exactly `expected` contents, or gives up
/// after roughly five seconds.
fn waitForFileContents(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, expected: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        if (dir.readFileAlloc(io, sub_path, gpa, .limited(4096))) |actual| {
            defer gpa.free(actual);
            if (std.mem.eql(u8, expected, actual)) return;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return expectFileContents(gpa, io, dir, sub_path, expected);
}
