const std = @import("std");
const harness = @import("harness.zig");
const nlock = @import("nlock");

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

test "client exits with the command's exit status and releases the lock" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const cases = [_]struct { command: []const []const u8, expected: u8 }{
        .{ .command = &.{"false"}, .expected = 1 },
        .{ .command = &.{ "sh", "-c", "exit 42" }, .expected = 42 },
        .{ .command = &.{ "sh", "-c", "kill -TERM $$" }, .expected = 128 + 15 },
        .{ .command = &.{"nlock-test-no-such-command"}, .expected = 127 },
    };
    for (cases) |case| {
        const args = try std.mem.concat(gpa, []const u8, &.{ &.{ "run", "mylock", "--" }, case.command });
        defer gpa.free(args);
        const result = try daemon.client(gpa, io, args);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(Term{ .exited = case.expected }, result.term);

        // The lock was released despite the failure.
        const held = try daemon.client(gpa, io, &.{ "list", "-q" });
        defer gpa.free(held.stdout);
        defer gpa.free(held.stderr);
        try std.testing.expectEqualStrings("", held.stdout);
    }
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

test "multiple concurrent clients contending for the same lock all succeed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const client_count = 6;
    var clients: [client_count]std.process.Child = undefined;
    for (0..client_count) |i| {
        clients[i] = try daemon.spawnClient(gpa, io, &.{ "run", "contended_lock", "--", "true" });
    }

    for (0..client_count) |i| {
        const term = try clients[i].wait(io);
        try std.testing.expectEqual(Term{ .exited = 0 }, term);
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

    const cases = [_]struct { args: []const []const u8, expected: []const u8 }{
        .{ .args = &.{"list"}, .expected = "NAME  USER  PID  SCOPE  ELAPSED  WAITERS  CMD\n" },
        .{ .args = &.{ "list", "-H" }, .expected = "" },
        .{ .args = &.{ "list", "-q" }, .expected = "" },
        .{ .args = &.{ "list", "--json" }, .expected = "" },
    };
    for (cases) |case| {
        const result = try daemon.client(gpa, io, case.args);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);

        try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings(case.expected, result.stdout);
    }
}

test "list rejects conflicting output options" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const result = try daemon.client(gpa, io, &.{ "list", "--json", "-q" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 64 }, result.term);
}

test "three different locks can be held at the same time and listed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const go_path = try daemon.tmpPath(gpa, "go");
    defer gpa.free(go_path);
    // Let the commands exit once the test is over, even if it fails early.
    defer daemon.tmp.dir.writeFile(io, .{ .sub_path = "go", .data = "" }) catch {};
    const script = try std.fmt.allocPrint(gpa, "while [ ! -f {s} ]; do sleep 0.01; done", .{go_path});
    defer gpa.free(script);

    // Started out of order to check that list sorts by name.
    var client_c = try daemon.spawnClient(gpa, io, &.{ "run", "--global", "lock-c", "--", "sh", "-c", script });
    var c_done = false;
    defer if (!c_done) client_c.kill(io);
    var client_a = try daemon.spawnClient(gpa, io, &.{ "run", "lock-a", "--", "sh", "-c", script });
    var a_done = false;
    defer if (!a_done) client_a.kill(io);
    var client_b = try daemon.spawnClient(gpa, io, &.{ "run", "lock-b", "--", "sh", "-c", script });
    var b_done = false;
    defer if (!b_done) client_b.kill(io);

    try waitForListOutput(gpa, io, daemon, &.{ "list", "-q" }, "lock-a\nlock-b\nlock-c\n");

    const result = try daemon.client(gpa, io, &.{"list"});
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);

    // All three clients run as the current user, whom the daemon identifies
    // from the socket's peer credentials.
    var uid_buf: [16]u8 = undefined;
    const user = nlock.peer.userName(&uid_buf, std.c.getuid());
    const expected_rows = [_]struct { name: []const u8, pid: std.posix.pid_t, scope: []const u8 }{
        .{ .name = "lock-a", .pid = client_a.id.?, .scope = "user" },
        .{ .name = "lock-b", .pid = client_b.id.?, .scope = "user" },
        .{ .name = "lock-c", .pid = client_c.id.?, .scope = "global" },
    };

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    try expectFields(lines.next().?, &.{ "NAME", "USER", "PID", "SCOPE", "ELAPSED", "WAITERS", "CMD" });
    for (expected_rows) |row| {
        var pid_buf: [16]u8 = undefined;
        const pid = try std.fmt.bufPrint(&pid_buf, "{d}", .{row.pid});
        const line = lines.next().?;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        try std.testing.expectEqualStrings(row.name, fields.next().?);
        try std.testing.expectEqualStrings(user, fields.next().?);
        try std.testing.expectEqualStrings(pid, fields.next().?);
        try std.testing.expectEqualStrings(row.scope, fields.next().?);
        _ = fields.next().?; // ELAPSED depends on timing
        try std.testing.expectEqualStrings("0", fields.next().?);
        // CMD is everything after WAITERS, spaces included.
        try std.testing.expectEqualStrings("sh", fields.next().?);
        try std.testing.expect(std.mem.endsWith(u8, line, script));
    }
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expectEqual(null, lines.next());

    try daemon.tmp.dir.writeFile(io, .{ .sub_path = "go", .data = "" });
    a_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try client_a.wait(io));
    b_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try client_b.wait(io));
    c_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try client_c.wait(io));
}

test "list --json reports waiters and round-trips the command" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const go_path = try daemon.tmpPath(gpa, "go");
    defer gpa.free(go_path);
    defer daemon.tmp.dir.writeFile(io, .{ .sub_path = "go", .data = "" }) catch {};
    // The newline must survive in JSON but be escaped in the table.
    const script = try std.fmt.allocPrint(gpa, "while [ ! -f {s} ]; do sleep 0.01; done\ntrue", .{go_path});
    defer gpa.free(script);

    var holder = try daemon.spawnClient(gpa, io, &.{ "run", "mylock", "--", "sh", "-c", script });
    var holder_done = false;
    defer if (!holder_done) holder.kill(io);
    try waitForListOutput(gpa, io, daemon, &.{ "list", "-q" }, "mylock\n");

    var waiter = try daemon.spawnClient(gpa, io, &.{ "run", "mylock", "--", "true" });
    var waiter_done = false;
    defer if (!waiter_done) waiter.kill(io);

    const before = nowSeconds(io);
    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        const result = try daemon.client(gpa, io, &.{ "list", "--json" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(Term{ .exited = 0 }, result.term);

        const parsed = try std.json.parseFromSlice(struct {
            name: []const u8,
            user: []const u8,
            uid: u32,
            pid: i32,
            global: bool,
            waiters: usize,
            acquired_at: i64,
            command: []const u8,
        }, gpa, std.mem.trimEnd(u8, result.stdout, "\n"), .{});
        defer parsed.deinit();
        const info = parsed.value;

        if (info.waiters == 0 and attempts < 500) {
            try io.sleep(.fromMilliseconds(10), .awake);
            continue;
        }
        try std.testing.expectEqualStrings("mylock", info.name);
        try std.testing.expectEqual(std.c.getuid(), info.uid);
        try std.testing.expectEqual(holder.id.?, info.pid);
        try std.testing.expectEqual(false, info.global);
        try std.testing.expectEqual(1, info.waiters);
        try std.testing.expect(info.acquired_at <= before and info.acquired_at > before - 60);
        const expected_command = try std.fmt.allocPrint(gpa, "sh -c {s}", .{script});
        defer gpa.free(expected_command);
        try std.testing.expectEqualStrings(expected_command, info.command);
        break;
    }

    const result = try daemon.client(gpa, io, &.{ "list", "-H" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(1, std.mem.count(u8, result.stdout, "\n"));
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, "done\\ntrue\n"));

    try daemon.tmp.dir.writeFile(io, .{ .sub_path = "go", .data = "" });
    holder_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try holder.wait(io));
    waiter_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try waiter.wait(io));
}

test "run rejects lock names containing whitespace" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const result = try daemon.client(gpa, io, &.{ "run", "my lock", "--", "true" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 64 }, result.term);
}

test "lock is released when the holding client is killed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const log_path = try daemon.tmpPath(gpa, "log");
    defer gpa.free(log_path);
    const go_path = try daemon.tmpPath(gpa, "go");
    defer gpa.free(go_path);
    // Let the orphaned command exit once the test is over.
    defer daemon.tmp.dir.writeFile(io, .{ .sub_path = "go", .data = "" }) catch {};

    const script = try std.fmt.allocPrint(
        gpa,
        "echo start >> {s}; while [ ! -f {s} ]; do sleep 0.01; done",
        .{ log_path, go_path },
    );
    defer gpa.free(script);
    var holder = try daemon.spawnClient(gpa, io, &.{ "run", "mylock", "--", "sh", "-c", script });
    try waitForFileContents(gpa, io, daemon.tmp.dir, "log", "start\n");

    // SIGKILL gives the client no chance to send a release request.
    holder.kill(io);

    const result = try daemon.client(gpa, io, &.{ "run", "--timeout", "5", "mylock", "--", "true" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
}

test "client survives SIGINT and releases the lock after the command exits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const log_path = try daemon.tmpPath(gpa, "log");
    defer gpa.free(log_path);
    const go_path = try daemon.tmpPath(gpa, "go");
    defer gpa.free(go_path);

    const script = try std.fmt.allocPrint(
        gpa,
        "echo start >> {0s}; while [ ! -f {1s} ]; do sleep 0.01; done; echo end >> {0s}",
        .{ log_path, go_path },
    );
    defer gpa.free(script);
    var holder = try daemon.spawnClient(gpa, io, &.{ "run", "mylock", "--", "sh", "-c", script });
    var holder_done = false;
    defer if (!holder_done) holder.kill(io);
    try waitForFileContents(gpa, io, daemon.tmp.dir, "log", "start\n");

    // Only the client is interrupted here, not its command. It must keep
    // running until the command finishes rather than abandon the lock.
    try std.posix.kill(holder.id.?, .INT);
    try io.sleep(.fromMilliseconds(100), .awake);
    try daemon.tmp.dir.writeFile(io, .{ .sub_path = "go", .data = "" });

    holder_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try holder.wait(io));
    try expectFileContents(gpa, io, daemon.tmp.dir, "log", "start\nend\n");

    const result = try daemon.client(gpa, io, &.{ "run", "--nonblock", "mylock", "--", "true" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
}

test "a second daemon refuses to take over a socket in use" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const second = try std.process.run(gpa, io, .{
        .argv = &.{@import("build_options").nlockd_path},
        .environ_map = &daemon.environ,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    defer gpa.free(second.stdout);
    defer gpa.free(second.stderr);
    try std.testing.expectEqual(Term{ .exited = 1 }, second.term);
    try std.testing.expect(std.mem.indexOf(u8, second.stderr, "already running") != null);

    // The first daemon still owns the socket.
    const result = try daemon.client(gpa, io, &.{ "run", "mylock", "--", "true" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
}

test "daemon removes its socket on SIGTERM" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    try std.posix.kill(daemon.child.id.?, .TERM);
    try std.testing.expectEqual(Term{ .exited = 0 }, try daemon.child.wait(io));
    try std.testing.expectError(error.FileNotFound, daemon.tmp.dir.access(io, "nlock.sock", .{}));

    // The single-instance lock was released with the process.
    try daemon.restart(io);
    const result = try daemon.client(gpa, io, &.{ "run", "mylock", "--", "true" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
}

test "daemon replaces a stale socket left by a killed daemon" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    // SIGKILL gives the daemon no chance to remove its socket.
    try daemon.restart(io);

    const result = try daemon.client(gpa, io, &.{ "run", "mylock", "--", "true" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
}

test "a queued client is told who holds the lock before it waits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const go_path = try daemon.tmpPath(gpa, "go");
    defer gpa.free(go_path);
    defer daemon.tmp.dir.writeFile(io, .{ .sub_path = "go", .data = "" }) catch {};
    const script = try std.fmt.allocPrint(gpa, "while [ ! -f {s} ]; do sleep 0.01; done", .{go_path});
    defer gpa.free(script);

    var holder = try daemon.spawnClient(gpa, io, &.{ "run", "db", "--", "sh", "-c", script });
    var holder_done = false;
    defer if (!holder_done) holder.kill(io);
    try waitForListOutput(gpa, io, daemon, &.{ "list", "-q" }, "db\n");

    const address = try std.Io.net.UnixAddress.init(daemon.socket_path);
    const stream = try address.connect(io);
    defer stream.close(io);
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    const request = try (nlock.LockRequest{ .acquire = .{
        .name = "db",
        .global = false,
        .nonblock = false,
        .timeout = null,
        .command = "true",
    } }).toJson(gpa);
    defer gpa.free(request);
    try nlock.writeLine(&writer.interface, request);

    const queued_parsed = try nlock.LockResponse.fromJson((try reader.interface.takeDelimiter('\n')).?, gpa);
    defer queued_parsed.deinit();
    const queued = queued_parsed.value.queued;
    try std.testing.expectEqual(0, queued.ahead);
    const info = queued.holder;
    try std.testing.expectEqualStrings("db", info.name);
    try std.testing.expectEqual(std.c.getuid(), info.uid);
    try std.testing.expectEqual(holder.id.?, info.pid);
    const expected_command = try std.fmt.allocPrint(gpa, "sh -c {s}", .{script});
    defer gpa.free(expected_command);
    try std.testing.expectEqualStrings(expected_command, info.command);

    // The lock is granted once the holder finishes.
    try daemon.tmp.dir.writeFile(io, .{ .sub_path = "go", .data = "" });
    holder_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try holder.wait(io));
    const acquired_parsed = try nlock.LockResponse.fromJson((try reader.interface.takeDelimiter('\n')).?, gpa);
    defer acquired_parsed.deinit();
    try std.testing.expectEqual(nlock.LockResponseStatus.ok, std.meta.activeTag(acquired_parsed.value));
}

test "--coalesce queues if nothing is pending, and otherwise exits 0 without running" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const log_path = try daemon.tmpPath(gpa, "log");
    defer gpa.free(log_path);
    var holder = try HeldLock.start(gpa, io, daemon, "build");
    defer holder.finish(io) catch {};

    // Nothing is pending yet, so the first request queues as usual.
    const script_1 = try std.fmt.allocPrint(gpa, "echo first >> {s}", .{log_path});
    defer gpa.free(script_1);
    var first = try daemon.spawnClient(gpa, io, &.{ "run", "--coalesce", "build", "--", "sh", "-c", script_1 });
    var first_done = false;
    defer if (!first_done) first.kill(io);
    try waitForWaiters(gpa, io, daemon, "build", 1);

    // A run is pending now, so the second request returns at once.
    const script_2 = try std.fmt.allocPrint(gpa, "echo second >> {s}", .{log_path});
    defer gpa.free(script_2);
    const second = try daemon.client(gpa, io, &.{ "run", "--coalesce", "build", "--", "sh", "-c", script_2 });
    defer gpa.free(second.stdout);
    defer gpa.free(second.stderr);
    try std.testing.expectEqual(Term{ .exited = 0 }, second.term);
    try waitForWaiters(gpa, io, daemon, "build", 1);

    try holder.finish(io);
    first_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try first.wait(io));
    try expectFileContents(gpa, io, daemon.tmp.dir, "log", "first\n");
}

test "--replace takes the place of every waiter, which exit 0 without running" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const log_path = try daemon.tmpPath(gpa, "log");
    defer gpa.free(log_path);
    var holder = try HeldLock.start(gpa, io, daemon, "deploy");
    defer holder.finish(io) catch {};

    var waiters: [2]std.process.Child = undefined;
    var waiters_done = [_]bool{ false, false };
    defer for (&waiters, waiters_done) |*waiter, done| if (!done) waiter.kill(io);
    // One waits with a timeout and one without, since the daemon waits for
    // them differently.
    for (&waiters, [_][]const u8{ "v1", "v2" }, [_][]const u8{ "-t", "--global" }, [_][]const u8{ "30", "--global" }, 1..) |*waiter, version, flag, value, count| {
        const script = try std.fmt.allocPrint(gpa, "echo {s} >> {s}", .{ version, log_path });
        defer gpa.free(script);
        waiter.* = try daemon.spawnClient(gpa, io, &.{ "run", flag, value, "deploy", "--", "sh", "-c", script });
        try waitForWaiters(gpa, io, daemon, "deploy", count);
    }

    const script = try std.fmt.allocPrint(gpa, "echo v3 >> {s}", .{log_path});
    defer gpa.free(script);
    var newest = try daemon.spawnClient(gpa, io, &.{ "run", "--replace", "deploy", "--", "sh", "-c", script });
    var newest_done = false;
    defer if (!newest_done) newest.kill(io);

    // The replaced clients give up while the lock is still held.
    for (&waiters, &waiters_done) |*waiter, *done| {
        done.* = true;
        try std.testing.expectEqual(Term{ .exited = 0 }, try waiter.wait(io));
    }
    try waitForWaiters(gpa, io, daemon, "deploy", 1);

    try holder.finish(io);
    newest_done = true;
    try std.testing.expectEqual(Term{ .exited = 0 }, try newest.wait(io));
    try expectFileContents(gpa, io, daemon.tmp.dir, "log", "v3\n");
}

test "run rejects --coalesce with --replace" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const daemon = try harness.Daemon.start(gpa, io);
    defer daemon.stop(gpa, io);

    const result = try daemon.client(gpa, io, &.{ "run", "--coalesce", "--replace", "mylock", "--", "true" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = @intFromEnum(nlock.SysExits.usage) }, result.term);
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

    try std.testing.expectEqual(Term{ .exited = 69 }, result.term);
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

fn nowSeconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

fn expectFields(line: []const u8, expected: []const []const u8) !void {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    for (expected) |field| try std.testing.expectEqualStrings(field, fields.next().?);
    try std.testing.expectEqual(null, fields.next());
}

/// Polls `nlock` with `args` until it prints exactly `expected`, or gives up
/// after roughly five seconds.
fn waitForListOutput(gpa: std.mem.Allocator, io: std.Io, daemon: *harness.Daemon, args: []const []const u8, expected: []const u8) !void {
    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        const result = try daemon.client(gpa, io, args);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (std.mem.eql(u8, expected, result.stdout) or attempts >= 500) {
            return std.testing.expectEqualStrings(expected, result.stdout);
        }
        try io.sleep(.fromMilliseconds(10), .awake);
    }
}

/// A client holding a lock until `finish` is called.
const HeldLock = struct {
    child: std.process.Child,
    daemon: *harness.Daemon,
    done: bool = false,

    /// Starts a client that holds `name`, and waits until it does.
    fn start(gpa: std.mem.Allocator, io: std.Io, daemon: *harness.Daemon, name: []const u8) !HeldLock {
        const go_path = try daemon.tmpPath(gpa, "go");
        defer gpa.free(go_path);
        const script = try std.fmt.allocPrint(gpa, "while [ ! -f {s} ]; do sleep 0.01; done", .{go_path});
        defer gpa.free(script);

        var child = try daemon.spawnClient(gpa, io, &.{ "run", name, "--", "sh", "-c", script });
        errdefer child.kill(io);
        try waitForWaiters(gpa, io, daemon, name, 0);
        return .{ .child = child, .daemon = daemon };
    }

    /// Lets the command finish, so the lock passes to the next waiter.
    fn finish(self: *HeldLock, io: std.Io) !void {
        if (self.done) return;
        self.done = true;
        try self.daemon.tmp.dir.writeFile(io, .{ .sub_path = "go", .data = "" });
        try std.testing.expectEqual(Term{ .exited = 0 }, try self.child.wait(io));
    }
};

/// Polls `nlock list --json` until lock `name` is held with exactly
/// `expected` waiters, or gives up after roughly five seconds.
fn waitForWaiters(gpa: std.mem.Allocator, io: std.Io, daemon: *harness.Daemon, name: []const u8, expected: usize) !void {
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        const result = try daemon.client(gpa, io, &.{ "list", "--json" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            const parsed = try std.json.parseFromSlice(
                struct { name: []const u8, waiters: usize },
                gpa,
                line,
                .{ .ignore_unknown_fields = true },
            );
            defer parsed.deinit();
            if (std.mem.eql(u8, name, parsed.value.name) and parsed.value.waiters == expected) return;
        }
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.WaitersNeverMatched;
}
