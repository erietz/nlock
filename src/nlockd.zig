const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const log = nlock.logger.log;
const ll = nlock.logger.LogLevel;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        // Printed regardless of NLOCK_LOG_LEVEL: the daemon is exiting.
        switch (err) {
            error.AlreadyRunning => std.debug.print("nlockd: another nlockd is already running on this socket\n", .{}),
            else => std.debug.print("nlockd: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
}

pub fn run(init: std.process.Init) !void {
    // Start the server to listen for incoming connections
    try runServer(init);
}

pub fn runServer(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    nlock.logger.init(nlock.logger.getLogLevel(init.environ_map));

    // Everything the daemon creates (lock file, socket) is for this user only.
    _ = std.c.umask(0o077);

    const socket_path = try nlock.getSocketPath(gpa, init.environ_map);
    defer gpa.free(socket_path);

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

    const socket_path_z = try gpa.dupeZ(u8, socket_path);
    defer gpa.free(socket_path_z);
    installShutdownHandlers(socket_path_z);
    log(ll.Info, "Server started and listening on {s}", .{socket_path});

    var map = nlock.ThreadSafeHashMap([]const u8, nlock.Lock).init(io, gpa);
    // Declared before `group` so this runs after `group.cancel`: no connection
    // tasks remain, so it is safe to walk the inner map without the mutex.
    defer {
        var it = map.map.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*.command);
        }
        map.deinit();
    }

    // initialize structured task management group
    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = try server.accept(io);
        // Spawn a new task to handle the connection
        group.concurrent(io, connectionTask, .{
            io,
            gpa,
            stream,
            &map,
        }) catch |err| {
            log(ll.Error, "Failed to spawn connection task: {s}", .{@errorName(err)});
            stream.close(io);
        };
    }
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

/// Adapts `handleConnection` to the `Cancelable!void` signature `Io.Group`
/// requires.
fn connectionTask(
    io: Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
) Io.Cancelable!void {
    handleConnection(
        io,
        allocator,
        stream,
        map,
    ) catch |err| {
        log(ll.Debug, "Connection error: {s}", .{@errorName(err)});
    };
}

fn handleConnection(
    io: Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
) !void {
    defer stream.close(io);
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    // Ask the kernel who is on the other end of the socket rather than
    // trusting a uid sent by the client.
    const peer = nlock.peer.peerCredentials(stream) catch |err| {
        log(ll.Error, "Failed to get peer credentials: {s}", .{@errorName(err)});
        return err;
    };

    // Client current follows this simple ACQUIRE -> EXECUTE -> RELEASE
    // pattern, but this will change when implementing the `list` command, for
    // example.

    // Read the acquire request message from the client
    // const req = try readRequest(&reader.interface);
    var req = try readRequest(&reader.interface, allocator);
    defer req.deinit(allocator);
    switch (req.request_type) {
        nlock.LockRequestType.AcquireLock => {
            const holding = handleAcquireLockRequest(
                io,
                allocator,
                req,
                peer,
                map,
                &writer.interface,
            ) catch |err| {
                log(ll.Error, "Failed to handle acquire lock request: {s}", .{@errorName(err)});
                return err;
            };
            // Nonblocking request for a busy lock: nothing to release.
            if (!holding) return;
        },
        nlock.LockRequestType.ListLocks => {
            return handleListLocksRequest(allocator, map, &writer.interface) catch |err| {
                log(ll.Error, "Failed to handle list locks request: {s}", .{@errorName(err)});
                return err;
            };
        },
        else => {
            log(ll.Error, "Received unexpected request type: {d}", .{req.request_type});
            return error.UnexpectedRequestType;
        },
    }

    // If the client goes away without releasing (e.g. it was killed by a
    // signal), release the lock on its behalf so it is not held forever.
    var released = false;
    defer if (!released) {
        log(ll.Info, "Client disconnected while holding lock '{s}'. Releasing it.", .{req.name});
        _ = releaseLock(io, allocator, map, req.name);
    };

    // The client executes the command and then sends a release lock request
    log(ll.Debug, "Waiting for release lock request from client", .{});
    var release_req = try readRequest(&reader.interface, allocator);
    defer release_req.deinit(allocator);
    switch (release_req.request_type) {
        nlock.LockRequestType.ReleaseLock => {
            // A connection may only release the lock it acquired, whatever
            // name the request carries; otherwise any client could release
            // locks it does not hold.
            if (!std.mem.eql(u8, release_req.name, req.name)) {
                log(ll.Warn, "Client holding '{s}' asked to release '{s}'. Releasing '{s}'.", .{
                    req.name,
                    release_req.name,
                    req.name,
                });
            }
            handleReleaseLockRequest(
                io,
                allocator,
                req.name,
                map,
                &writer.interface,
            ) catch |err| {
                log(ll.Debug, "Failed to handle release lock request: {s}", .{@errorName(err)});
                return err;
            };
            released = true;
        },
        else => {
            log(ll.Debug, "Received unexpected request type: {d}", .{release_req.request_type});
            return error.UnexpectedRequestType;
        },
    }
}

fn readRequest(reader: *Io.Reader, allocator: std.mem.Allocator) !nlock.LockRequest {
    const message = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
    log(ll.Debug, "Received lock request: {s}", .{message});
    return nlock.LockRequest.fromJson(message, allocator);
}

test "readRequest parses a valid LockRequest where command contains newlines" {
    const message = "{\"request_type\":\"AcquireLock\",\"name\":\"my_lock\",\"global\":false,\"nonblock\":false,\"timeout\":null,\"command\":\"echo 'Hello, World!'\\necho 'This is a test.'\\n\"}\n";
    const allocator = std.testing.allocator;
    const expected_request = nlock.LockRequest.init(
        nlock.LockRequestType.AcquireLock,
        "my_lock",
        false,
        false,
        null,
        "echo 'Hello, World!'\necho 'This is a test.'\n",
    );

    var reader = std.Io.Reader.fixed(message);
    var request = try readRequest(&reader, allocator);
    defer request.deinit(allocator);

    try std.testing.expectEqual(expected_request.request_type, request.request_type);
    try std.testing.expectEqualStrings(expected_request.name, request.name);
    try std.testing.expectEqual(expected_request.global, request.global);
    try std.testing.expectEqual(expected_request.nonblock, request.nonblock);
    try std.testing.expectEqualStrings(expected_request.command, request.command);
}

/// Returns true if the connection now holds the lock, or false if the lock
/// was busy and the request was nonblocking.
fn handleAcquireLockRequest(
    io: Io,
    allocator: std.mem.Allocator,
    lock_request: nlock.LockRequest,
    peer: nlock.peer.Credentials,
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
    writer: *Io.Writer,
) !bool {
    // Check and insert in one atomic step so two clients racing for the same
    // name cannot both acquire it.
    // The map owns copies of both the name and the command: `lock_request`
    // slices point into this connection's read buffer, which is reused by the
    // next read and invalid once the connection ends.
    const lock_name_copy = try allocator.dupe(u8, lock_request.name);
    const command_copy = allocator.dupe(u8, lock_request.command) catch |err| {
        allocator.free(lock_name_copy);
        return err;
    };
    // defer allocator.free(lock_name_copy);
    // defer allocator.free(command_copy);

    const lock = nlock.Lock{
        .command = command_copy,
        .uid = peer.uid,
        .pid = peer.pid,
        .global = lock_request.global,
        .acquired_at = nowSeconds(io),
    };

    const acquired = map.tryPut(lock_name_copy, lock) catch |err| {
        allocator.free(lock_name_copy);
        allocator.free(command_copy);
        return err;
    };

    if (acquired) {
        log(ll.Info, "Acquired lock for name '{s}' (uid: {d}, pid: {d}, global: {}). Command: {s}", .{
            lock_request.name,
            peer.uid,
            peer.pid,
            lock_request.global,
            lock_request.command,
        });
    } else {
        log(ll.Info, "Lock for name '{s}' is already acquired", .{lock_name_copy});
        // TODO: almost feel like we need manual control of the mutex from
        // above, so that we can do a get and then a put in the same section.
        // There is still a race condition here.
        var existing_lock = map.getPtr(lock_name_copy) orelse {
            log(ll.Error, "Lock for name '{s}' was removed before we could add a waiter", .{lock_name_copy});
            return error.LockAlreadyAcquired;
        };

        // TODO: lock_name_copy is never freed on this path, and on the
        // busy/timeout paths below command_copy leaks too.
        if (lock_request.nonblock) {
            const busy_response = try nlock.LockResponse.init(nlock.LockResponseStatus.Busy).toJson(allocator);
            defer allocator.free(busy_response);
            try nlock.writeLine(writer, busy_response);
            return false;
        }

        var waiter = nlock.Waiter{
            .event = .unset,
            .command = command_copy,
            .uid = peer.uid,
            .pid = peer.pid,
            .global = lock_request.global,
        };
        // Queue up the command to be executed when the acquired lock is
        // released
        existing_lock.waiters.append(&waiter.node);

        if (lock_request.timeout) |timeout_s| {
            log(ll.Debug, "Waiting for lock '{s}' to be released with timeout of {d} seconds", .{ lock_name_copy, timeout_s });
            // TODO: This is not a safe type cast. We should use a safe cast or
            // check the value before casting.
            const timeout = std.Io.Timeout{ .duration = .{
                .clock = .awake,
                .raw = std.Io.Duration.fromSeconds(@intCast(timeout_s)),
            } };

            // Wait for the lock to be released. This does not happen until the
            // client sends a release lock request, which will signal this
            // waiter. Or if the timeout expires, we will return a timeout
            // error to the client.
            waiter.event.waitTimeout(io, timeout) catch |err| switch (err) {
                error.Timeout => {
                    log(ll.Info, "Timeout while waiting for lock '{s}' to be released", .{lock_name_copy});
                    // Remove the waiter from the queue since it timed out
                    existing_lock.waiters.remove(&waiter.node);
                    const timeout_response = try nlock.LockResponse.init(nlock.LockResponseStatus.Timeout).toJson(allocator);
                    defer allocator.free(timeout_response);
                    try nlock.writeLine(writer, timeout_response);
                    return error.Timeout;
                },
                else => return err,
            };
        } else {
            // Wait for the lock to be released. This does not happen until the
            // client sends a release lock request, which will signal this waiter.
            log(ll.Debug, "Waiting for lock '{s}' to be released without timeout", .{lock_name_copy});
            try waiter.event.wait(io);
        }

        log(ll.Debug, "Waiting for lock '{s}' to be released", .{lock_name_copy});
        try waiter.event.wait(io);
    }

    // The lock is ours now. If the client cannot be told (e.g. it was killed
    // while queued), pass the lock on to the next waiter.
    errdefer _ = releaseLock(io, allocator, map, lock_request.name);

    log(ll.Info, "Sending acquired response for lock {s}.", .{lock_name_copy});
    const acquired_response = try nlock.LockResponse
        .init(
            nlock.LockResponseStatus.Ok,
        ).toJson(allocator);
    defer allocator.free(acquired_response);
    try nlock.writeLine(writer, acquired_response);
    return true;
}

fn handleReleaseLockRequest(
    io: Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
    writer: *Io.Writer,
) !void {
    log(ll.Info, "Releasing lock for name '{s}'", .{name});

    if (releaseLock(io, allocator, map, name)) {
        log(ll.Info, "Lock for name '{s}' released successfully.", .{name});
        const lock_response = try nlock.LockResponse.init(nlock.LockResponseStatus.Ok).toJson(allocator);
        defer allocator.free(lock_response);
        try nlock.writeLine(writer, lock_response);
        return;
    }

    log(ll.Error, "No lock found for name '{s}' to release.", .{name});
    return error.LockNotFound;
}

/// Hands the lock to the next waiter, or removes it if there is none.
/// Returns false if no lock with that name exists.
fn releaseLock(
    io: Io,
    allocator: std.mem.Allocator,
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
    name: []const u8,
) bool {
    const lock_ptr = map.getPtr(name) orelse return false;
    if (lock_ptr.waiters.popFirst()) |waiter_node| {
        var w: *nlock.Waiter = @fieldParentPtr("node", waiter_node);
        // The lock now belongs to the waiter
        lock_ptr.command = w.command;
        lock_ptr.uid = w.uid;
        lock_ptr.pid = w.pid;
        lock_ptr.global = w.global;
        lock_ptr.acquired_at = nowSeconds(io);
        // Signal the waiter that the lock has been released
        w.event.set(io);
        // allocator.free(w.command); // Free the waiter's command after signaling
    } else {
        allocator.free(lock_ptr.command);
        // TODO: this leaks the key; the map owns a copy of the name made
        // in handleAcquireLockRequest. Use fetchRemove and free it.
        _ = map.remove(name);
    }
    return true;
}

fn nowSeconds(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds();
}

fn handleListLocksRequest(
    allocator: std.mem.Allocator,
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
    writer: *Io.Writer,
) !void {
    // Serialize every lock while holding the mutex so the snapshot is
    // consistent, but write to the socket only after releasing it so a slow
    // client cannot stall other connections.
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    {
        map.mutex.lockUncancelable(map.io);
        defer map.mutex.unlock(map.io);

        var it = map.map.iterator();
        while (it.next()) |entry| {
            const lock = entry.value_ptr;
            const line = try (nlock.LockInfo{
                .name = entry.key_ptr.*,
                .uid = lock.uid,
                .pid = lock.pid,
                .global = lock.global,
                .waiters = lock.waiters.len(),
                .acquired_at = lock.acquired_at,
                .command = lock.command,
            }).toJson(allocator);
            lines.append(allocator, line) catch |err| {
                allocator.free(line);
                return err;
            };
        }
    }

    for (lines.items) |line| try nlock.writeLine(writer, line);
}
