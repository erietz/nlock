const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const log = nlock.logger.log;
const ll = nlock.logger.LogLevel;

pub const std_options: std.Options = .{ .logFn = logFn };

/// Whether log messages go to syslog instead of stderr. Set once at startup.
///
/// nlockd logs to stderr when stderr is a terminal (someone is running it by
/// hand) and to syslog otherwise (it is running under a service manager).
/// launchd discards a job's stderr unless the plist names a file for it, and
/// that file is never rotated, whereas syslog messages reach the macOS
/// unified log (`log stream --process nlockd --level debug`) and the systemd
/// journal (`journalctl --user -u nlockd`), both of which are rotated and
/// keep each message's level. See nlockd(1), section LOGGING.
var log_to_syslog = false;

/// syslog(3) priorities and options. They have the same values on Linux and
/// macOS.
const LOG_ERR = 3;
const LOG_WARNING = 4;
const LOG_INFO = 6;
const LOG_DEBUG = 7;
const LOG_PID = 0x01;
const LOG_DAEMON = 3 << 3;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!log_to_syslog) return std.log.defaultLog(level, scope, format, args);

    const priority = switch (level) {
        .err => LOG_ERR,
        .warn => LOG_WARNING,
        .info => LOG_INFO,
        .debug => LOG_DEBUG,
    };
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    // Messages longer than the buffer are truncated.
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    w.print(prefix ++ format, args) catch {};
    buf[w.end] = 0;
    std.c.syslog(priority, "%s", @as([*:0]const u8, buf[0..w.end :0]));
}

pub fn main(init: std.process.Init) void {
    const stderr_is_tty = std.Io.File.stderr().isTty(init.io) catch false;
    if (!stderr_is_tty) {
        std.c.openlog("nlockd", LOG_PID, LOG_DAEMON);
        log_to_syslog = true;
    }
    run(init) catch |err| {
        // Reported regardless of NLOCK_LOG_LEVEL: the daemon is exiting.
        // Always printed to stderr so whoever started nlockd sees why, and
        // also sent to syslog when that is where the daemon's logs go.
        switch (err) {
            error.AlreadyRunning => {
                std.debug.print("nlockd: another nlockd is already running on this socket\n", .{});
                if (log_to_syslog) std.log.err("another nlockd is already running on this socket", .{});
            },
            else => {
                std.debug.print("nlockd: {s}\n", .{@errorName(err)});
                if (log_to_syslog) std.log.err("{s}", .{@errorName(err)});
            },
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
    log(ll.Info, "nlockd version {s}", .{nlock.version()});
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
    const req_parsed = try readRequest(&reader.interface, allocator);
    defer req_parsed.deinit();
    const req = switch (req_parsed.value) {
        .acquire => |acquire| acquire,
        .list => {
            return handleListLocksRequest(allocator, map, &writer.interface) catch |err| {
                log(ll.Error, "Failed to handle list locks request: {s}", .{@errorName(err)});
                return err;
            };
        },
        .release => {
            log(ll.Error, "Received release request before acquiring a lock", .{});
            return error.UnexpectedRequestType;
        },
    };
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
    // Busy, coalesced or replaced: nothing to release.
    if (!holding) return;

    // If the client goes away without releasing (e.g. it was killed by a
    // signal), release the lock on its behalf so it is not held forever.
    var released = false;
    defer if (!released) {
        log(ll.Info, "Client disconnected while holding lock '{s}'. Releasing it.", .{req.name});
        _ = releaseLock(io, allocator, map, req.name);
    };

    // The client executes the command and then sends a release lock request
    log(ll.Debug, "Waiting for release lock request from client", .{});
    const release_req_parsed = try readRequest(&reader.interface, allocator);
    defer release_req_parsed.deinit();
    switch (release_req_parsed.value) {
        // A connection may only release the lock it acquired, so the request
        // does not name one.
        .release => {
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
        else => |release_req| {
            log(ll.Debug, "Received unexpected request type: {s}", .{@tagName(release_req)});
            return error.UnexpectedRequestType;
        },
    }
}

fn readRequest(reader: *Io.Reader, allocator: std.mem.Allocator) !std.json.Parsed(nlock.LockRequest) {
    const message = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
    log(ll.Debug, "Received lock request: {s}", .{message});
    return nlock.LockRequest.fromJson(message, allocator);
}

test "readRequest parses a valid LockRequest where command contains newlines" {
    const message = "{\"acquire\":{\"name\":\"my_lock\",\"global\":false,\"nonblock\":false,\"timeout\":null,\"command\":\"echo 'Hello, World!'\\necho 'This is a test.'\\n\"}}\n";
    const allocator = std.testing.allocator;
    const expected_request: nlock.LockRequest.Acquire = .{
        .name = "my_lock",
        .global = false,
        .nonblock = false,
        .timeout = null,
        .command = "echo 'Hello, World!'\necho 'This is a test.'\n",
    };

    var reader = std.Io.Reader.fixed(message);
    const parsed = try readRequest(&reader, allocator);
    defer parsed.deinit();
    const request = parsed.value.acquire;

    try std.testing.expectEqualStrings(expected_request.name, request.name);
    try std.testing.expectEqual(expected_request.global, request.global);
    try std.testing.expectEqual(expected_request.nonblock, request.nonblock);
    try std.testing.expectEqualStrings(expected_request.command, request.command);
}

/// Returns true if the connection now holds the lock, or false if it does
/// not: the lock was busy and the request was nonblocking, the request was
/// coalesced into a pending run, or it was replaced while queued.
fn handleAcquireLockRequest(
    io: Io,
    allocator: std.mem.Allocator,
    lock_request: nlock.LockRequest.Acquire,
    peer: nlock.peer.Credentials,
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
    writer: *Io.Writer,
) !bool {
    // Acquire the map mutex so checking whether the lock is held, creating
    // the lock, or adding a waiter to the queue is atomic with respect to
    // other acquires and releases.
    map.lock();
    if (map.map.getPtr(lock_request.name)) |existing_lock| {
        log(ll.Info, "Lock for name '{s}' is already acquired", .{lock_request.name});

        // A queued client has not started its run yet, so that run happens
        // after whatever triggered this request: no need to queue another.
        if (lock_request.if_pending == .skip) if (existing_lock.waiters.last) |last_node| {
            const pending: *nlock.Waiter = @fieldParentPtr("node", last_node);
            // Serialized while holding the mutex: the waiter and its command
            // may be gone as soon as it is released.
            const coalesced_response = (nlock.LockResponse{ .coalesced = .{
                .pending = .{ .uid = pending.uid, .pid = pending.pid, .command = pending.command },
                .waiters = existing_lock.waiters.len(),
            } }).toJson(allocator) catch |err| {
                map.unlock();
                return err;
            };
            map.unlock();
            defer allocator.free(coalesced_response);
            log(ll.Info, "Lock '{s}' already has a pending run. Not queueing.", .{lock_request.name});
            try nlock.writeLine(writer, coalesced_response);
            return false;
        };

        if (lock_request.nonblock) {
            map.unlock();
            const busy_response = try (nlock.LockResponse{ .busy = {} }).toJson(allocator);
            defer allocator.free(busy_response);
            try nlock.writeLine(writer, busy_response);
            return false;
        }

        const command_copy = allocator.dupe(u8, lock_request.command) catch |err| {
            map.unlock();
            return err;
        };

        const replace = lock_request.if_pending == .replace;

        // Tell the client who it is waiting for. Serialized now, while the
        // holder cannot change, but sent after releasing the mutex.
        const ahead = if (replace) 0 else existing_lock.waiters.len();
        const queued_response = (nlock.LockResponse{ .queued = .{
            .holder = .{
                .name = lock_request.name,
                .uid = existing_lock.uid,
                .pid = existing_lock.pid,
                .global = existing_lock.global,
                .waiters = ahead + 1,
                .acquired_at = existing_lock.acquired_at,
                .command = existing_lock.command,
            },
            .ahead = ahead,
        } }).toJson(allocator) catch |err| {
            allocator.free(command_copy);
            map.unlock();
            return err;
        };
        defer allocator.free(queued_response);

        var waiter = nlock.Waiter{
            .event = .unset,
            .command = command_copy,
            .uid = peer.uid,
            .pid = peer.pid,
            .global = lock_request.global,
        };
        if (replace) {
            // Every waiter is an older request for the same job, so take
            // their place. Each is woken and told who replaced it.
            var replaced_count: usize = 0;
            while (existing_lock.waiters.popFirst()) |node| : (replaced_count += 1) {
                const replaced: *nlock.Waiter = @fieldParentPtr("node", node);
                replaced.replaced_by = .{ .uid = peer.uid, .pid = peer.pid };
                replaced.event.set(io);
            }
            log(ll.Info, "Replaced {d} waiter(s) for lock '{s}'", .{ replaced_count, lock_request.name });
        }
        // Queue up the command to be executed when the acquired lock is
        // released
        existing_lock.waiters.append(&waiter.node);
        map.unlock();

        nlock.writeLine(writer, queued_response) catch |err| {
            abandonWait(io, allocator, map, lock_request.name, &waiter);
            return err;
        };

        if (lock_request.timeout) |timeout_s| {
            log(ll.Debug, "Waiting for lock '{s}' to be released with timeout of {d} seconds", .{ lock_request.name, timeout_s });
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
                    log(ll.Info, "Timeout while waiting for lock '{s}' to be released", .{lock_request.name});
                    map.lock();
                    // Not set: still queued. Set: the lock arrived, or this
                    // waiter was replaced, just as the timeout expired;
                    // handled below.
                    if (!waiter.event.isSet()) {
                        if (map.map.getPtr(lock_request.name)) |curr_lock| {
                            curr_lock.waiters.remove(&waiter.node);
                        }
                        map.unlock();
                        allocator.free(command_copy);
                        const timeout_response = try (nlock.LockResponse{ .timeout = {} }).toJson(allocator);
                        defer allocator.free(timeout_response);
                        try nlock.writeLine(writer, timeout_response);
                        return error.Timeout;
                    }
                    map.unlock();
                },
                else => {
                    abandonWait(io, allocator, map, lock_request.name, &waiter);
                    return err;
                },
            };
        } else {
            // Wait for the lock to be released. This does not happen until the
            // client sends a release lock request, which will signal this waiter.
            log(ll.Debug, "Waiting for lock '{s}' to be released without timeout", .{lock_request.name});
            waiter.event.wait(io) catch |err| {
                abandonWait(io, allocator, map, lock_request.name, &waiter);
                return err;
            };
        }

        if (waiter.replaced_by) |by| {
            // Taken out of the queue, so the command was never handed to
            // the lock and is still ours.
            allocator.free(command_copy);
            log(ll.Info, "Waiter for lock '{s}' was replaced by pid {d}", .{ lock_request.name, by.pid });
            const replaced_response = try (nlock.LockResponse{ .replaced = .{
                .uid = by.uid,
                .pid = by.pid,
            } }).toJson(allocator);
            defer allocator.free(replaced_response);
            try nlock.writeLine(writer, replaced_response);
            return false;
        }
    } else {
        // The map owns copies of both the name and the command: `lock_request`
        // slices point into this connection's read buffer, which is reused by the
        // next read and invalid once the connection ends.
        const lock_name_copy = allocator.dupe(u8, lock_request.name) catch |err| {
            map.unlock();
            return err;
        };
        errdefer allocator.free(lock_name_copy);

        const command_copy = allocator.dupe(u8, lock_request.command) catch |err| {
            allocator.free(lock_name_copy);
            map.unlock();
            return err;
        };
        errdefer allocator.free(command_copy);

        const lock = nlock.Lock{
            .command = command_copy,
            .uid = peer.uid,
            .pid = peer.pid,
            .global = lock_request.global,
            .acquired_at = nowSeconds(io),
        };

        map.map.put(lock_name_copy, lock) catch |err| {
            allocator.free(lock_name_copy);
            allocator.free(command_copy);
            map.unlock();
            return err;
        };
        map.unlock();

        log(ll.Info, "Acquired lock for name '{s}' (uid: {d}, pid: {d}, global: {}). Command: {s}", .{
            lock_request.name,
            peer.uid,
            peer.pid,
            lock_request.global,
            lock_request.command,
        });
    }

    // The lock is ours now. If the client cannot be told (e.g. it was killed
    // while queued), pass the lock on to the next waiter.
    errdefer _ = releaseLock(io, allocator, map, lock_request.name);

    log(ll.Info, "Sending acquired response for lock {s}.", .{lock_request.name});
    const acquired_response = try (nlock.LockResponse{ .ok = {} }).toJson(allocator);
    defer allocator.free(acquired_response);
    try nlock.writeLine(writer, acquired_response);
    return true;
}

/// Cleans up after a queued client that stopped waiting because of an error
/// (e.g. it disconnected). If the lock has not reached it yet, it leaves the
/// queue; if it has, the lock is passed on to the next waiter. If it was
/// replaced, it is already out of the queue and only its command is freed.
fn abandonWait(
    io: Io,
    allocator: std.mem.Allocator,
    map: *nlock.ThreadSafeHashMap([]const u8, nlock.Lock),
    name: []const u8,
    waiter: *nlock.Waiter,
) void {
    map.lock();
    if (!waiter.event.isSet()) {
        if (map.map.getPtr(name)) |curr_lock| {
            curr_lock.waiters.remove(&waiter.node);
        }
        map.unlock();
        allocator.free(waiter.command);
    } else if (!waiter.granted()) {
        map.unlock();
        allocator.free(waiter.command);
    } else {
        map.unlock();
        _ = releaseLock(io, allocator, map, name);
    }
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
        const lock_response = try (nlock.LockResponse{ .ok = {} }).toJson(allocator);
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
    map.lock();
    defer map.unlock();

    const lock_ptr = map.map.getPtr(name) orelse return false;
    if (lock_ptr.waiters.popFirst()) |waiter_node| {
        var w: *nlock.Waiter = @fieldParentPtr("node", waiter_node);
        // Free previous holder's command before taking ownership of the waiter's command
        allocator.free(lock_ptr.command);
        // The lock now belongs to the waiter
        lock_ptr.command = w.command;
        lock_ptr.uid = w.uid;
        lock_ptr.pid = w.pid;
        lock_ptr.global = w.global;
        lock_ptr.acquired_at = nowSeconds(io);
        // Signal the waiter that the lock has been released
        w.event.set(io);
    } else {
        allocator.free(lock_ptr.command);
        if (map.map.fetchRemove(name)) |kv| {
            allocator.free(kv.key);
        }
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
        map.lock();
        defer map.unlock();

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
