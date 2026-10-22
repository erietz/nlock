const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const protocol = nlock.protocol;
const log = nlock.Logger.log;
const LockedStringMap = @import("hash.zig").LockedStringMap;
const queue = @import("queue.zig");
const Lock = queue.Lock;
const Waiter = queue.Waiter;

/// Every lock currently held, by name.
pub const LockMap = LockedStringMap(Lock);

/// Longest `--timeout` honored, in seconds. Longer ones wait indefinitely.
const max_timeout_s: u64 = 10 * 365 * std.time.s_per_day;

/// Returns true if the connection now holds the lock, or false if it does
/// not: the lock was busy and the request was nonblocking, the request was
/// coalesced into a pending run, it was replaced while queued, or its timeout
/// expired.
pub fn handleAcquireLockRequest(
    io: Io,
    allocator: std.mem.Allocator,
    lock_request: protocol.LockRequest.Acquire,
    peer: nlock.peer.Credentials,
    map: *LockMap,
    writer: *Io.Writer,
) !bool {
    // Acquire the map mutex so checking whether the lock is held, creating
    // the lock, or adding a waiter to the queue is atomic with respect to
    // other acquires and releases.
    map.lock();
    if (map.map.getPtr(lock_request.name)) |existing_lock| {
        log(.info, "Lock for name '{s}' is already acquired", .{lock_request.name});

        // A queued client has not started its run yet, so that run happens
        // after whatever triggered this request: no need to queue another.
        if (lock_request.if_pending == .skip) if (existing_lock.waiters.last) |last_node| {
            const pending: *Waiter = @fieldParentPtr("node", last_node);
            // Serialized while holding the mutex: the waiter and its command
            // may be gone as soon as it is released.
            const coalesced_response = (protocol.LockResponse{ .coalesced = .{
                .pending = .{ .pid = pending.pid, .command = pending.command },
                .waiters = existing_lock.waiters.len(),
            } }).toJson(allocator) catch |err| {
                map.unlock();
                return err;
            };
            map.unlock();
            defer allocator.free(coalesced_response);
            log(.info, "Lock '{s}' already has a pending run. Not queueing.", .{lock_request.name});
            try protocol.writeLine(writer, coalesced_response);
            return false;
        };

        if (lock_request.nonblock) {
            map.unlock();
            const busy_response = try (protocol.LockResponse{ .busy = {} }).toJson(allocator);
            defer allocator.free(busy_response);
            try protocol.writeLine(writer, busy_response);
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
        const queued_response = (protocol.LockResponse{ .queued = .{
            .holder = .{
                .name = lock_request.name,
                .pid = existing_lock.pid,
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

        var waiter = Waiter{
            .event = .unset,
            .command = command_copy,
            .pid = peer.pid,
        };
        if (replace) {
            // Every waiter is an older request for the same job, so take
            // their place. Each is woken and told who replaced it.
            var replaced_count: usize = 0;
            while (existing_lock.waiters.popFirst()) |node| : (replaced_count += 1) {
                const replaced: *Waiter = @fieldParentPtr("node", node);
                replaced.replaced_by = peer.pid;
                replaced.event.set(io);
            }
            log(.info, "Replaced {d} waiter(s) for lock '{s}'", .{ replaced_count, lock_request.name });
        }
        // Queue up the command to be executed when the acquired lock is
        // released
        existing_lock.waiters.append(&waiter.node);
        map.unlock();

        protocol.writeLine(writer, queued_response) catch |err| {
            abandonWait(io, allocator, map, lock_request.name, &waiter);
            return err;
        };

        // The timeout comes from the client, so anything too large to be a
        // real limit is treated as no limit rather than trusted.
        const timeout_s: ?u64 = if (lock_request.timeout) |t| (if (t <= max_timeout_s) t else null) else null;
        if (timeout_s) |t| {
            log(.debug, "Waiting for lock '{s}' to be released with timeout of {d} seconds", .{ lock_request.name, t });
            const timeout = std.Io.Timeout{ .duration = .{
                .clock = .awake,
                .raw = std.Io.Duration.fromSeconds(@intCast(t)),
            } };

            // Wait for the lock to be released. This does not happen until the
            // client sends a release lock request, which will signal this
            // waiter. Or if the timeout expires, we will return a timeout
            // error to the client.
            waiter.event.waitTimeout(io, timeout) catch |err| switch (err) {
                error.Timeout => {
                    log(.info, "Timeout while waiting for lock '{s}' to be released", .{lock_request.name});
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
                        const timeout_response = try (protocol.LockResponse{ .timeout = {} }).toJson(allocator);
                        defer allocator.free(timeout_response);
                        try protocol.writeLine(writer, timeout_response);
                        return false;
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
            log(.debug, "Waiting for lock '{s}' to be released without timeout", .{lock_request.name});
            waiter.event.wait(io) catch |err| {
                abandonWait(io, allocator, map, lock_request.name, &waiter);
                return err;
            };
        }

        if (waiter.replaced_by) |by_pid| {
            // Taken out of the queue, so the command was never handed to
            // the lock and is still ours.
            allocator.free(command_copy);
            log(.info, "Waiter for lock '{s}' was replaced by pid {d}", .{ lock_request.name, by_pid });
            const replaced_response = try (protocol.LockResponse{ .replaced = .{
                .pid = by_pid,
            } }).toJson(allocator);
            defer allocator.free(replaced_response);
            try protocol.writeLine(writer, replaced_response);
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

        const lock = Lock{
            .command = command_copy,
            .pid = peer.pid,
            .acquired_at = nowSeconds(io),
        };

        map.map.put(lock_name_copy, lock) catch |err| {
            allocator.free(lock_name_copy);
            allocator.free(command_copy);
            map.unlock();
            return err;
        };
        map.unlock();

        log(.info, "Acquired lock for name '{s}' (uid: {d}, pid: {d}). Command: {s}", .{
            lock_request.name,
            peer.uid,
            peer.pid,
            lock_request.command,
        });
    }

    // The lock is ours now. If the client cannot be told (e.g. it was killed
    // while queued), pass the lock on to the next waiter.
    errdefer _ = releaseLock(io, allocator, map, lock_request.name);

    log(.info, "Sending acquired response for lock {s}.", .{lock_request.name});
    const acquired_response = try (protocol.LockResponse{ .ok = {} }).toJson(allocator);
    defer allocator.free(acquired_response);
    try protocol.writeLine(writer, acquired_response);
    return true;
}

/// Cleans up after a queued client that stopped waiting because of an error
/// (e.g. it disconnected). If the lock has not reached it yet, it leaves the
/// queue; if it has, the lock is passed on to the next waiter. If it was
/// replaced, it is already out of the queue and only its command is freed.
fn abandonWait(
    io: Io,
    allocator: std.mem.Allocator,
    map: *LockMap,
    name: []const u8,
    waiter: *Waiter,
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

/// Hands the lock to the next waiter, or removes it if there is none.
/// Returns false if no lock with that name exists.
pub fn releaseLock(
    io: Io,
    allocator: std.mem.Allocator,
    map: *LockMap,
    name: []const u8,
) bool {
    map.lock();
    defer map.unlock();

    const lock_ptr = map.map.getPtr(name) orelse return false;
    if (lock_ptr.waiters.popFirst()) |waiter_node| {
        var w: *Waiter = @fieldParentPtr("node", waiter_node);
        // Free previous holder's command before taking ownership of the waiter's command
        allocator.free(lock_ptr.command);
        // The lock now belongs to the waiter
        lock_ptr.command = w.command;
        lock_ptr.pid = w.pid;
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

pub fn handleListLocksRequest(
    allocator: std.mem.Allocator,
    map: *LockMap,
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
            const line = try (protocol.LockInfo{
                .name = entry.key_ptr.*,
                .pid = lock.pid,
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

    for (lines.items) |line| try protocol.writeLine(writer, line);
}
