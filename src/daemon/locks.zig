const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const protocol = nlock.protocol;
const log = nlock.Logger.log;
const LockedStringMap = @import("hash.zig").LockedStringMap;
const queue = @import("queue.zig");
const Lock = queue.Lock;
const Client = queue.Client;

/// Every lock currently held or waited for, by name.
pub const LockMap = LockedStringMap(Lock);

/// Longest `--timeout` honored, in seconds. Longer ones wait indefinitely.
const max_timeout_s: u64 = 10 * 365 * std.time.s_per_day;

/// Returns true if `client` now holds the lock, or false if it does not: the
/// lock was busy and the request was nonblocking, the request was coalesced
/// into a pending run, it was replaced while queued, or its timeout expired.
///
/// The caller must call `leave` with the same `client` once done with the
/// lock, including when this returns an error: the client may be holding it,
/// or still queued.
pub fn handleAcquireLockRequest(
    io: Io,
    allocator: std.mem.Allocator,
    lock_request: protocol.LockRequest.Acquire,
    peer: nlock.peer.Credentials,
    map: *LockMap,
    writer: *Io.Writer,
    client: *Client,
) !bool {
    // Acquire the map mutex so checking whether the lock is held, creating
    // the lock, or adding a waiter to the queue is atomic with respect to
    // other acquires and releases.
    map.lock();
    const entry = map.map.getOrPut(lock_request.name) catch |err| {
        map.unlock();
        return err;
    };
    if (!entry.found_existing) {
        // The map owns a copy of the name: `lock_request` slices point into
        // the connection's parsed request, which is freed when it ends.
        entry.key_ptr.* = allocator.dupe(u8, lock_request.name) catch |err| {
            map.map.removeByPtr(entry.key_ptr);
            map.unlock();
            return err;
        };
        entry.value_ptr.* = .{};
    }
    const lock = entry.value_ptr;

    if (lock.canGrantNow()) {
        lock.grant(client, nowSeconds(io));
        map.unlock();

        log(.info, "Acquired lock for name '{s}' (uid: {d}, pid: {d}). Command: {s}", .{
            lock_request.name,
            peer.uid,
            peer.pid,
            lock_request.command,
        });
    } else {
        log(.info, "Lock for name '{s}' is already acquired", .{lock_request.name});

        // A queued client has not started its run yet, so that run happens
        // after whatever triggered this request: no need to queue another.
        if (lock_request.if_pending == .skip) if (lock.lastWaiter()) |pending| {
            // Serialized while holding the mutex: the waiter and its command
            // may be gone as soon as it is released.
            const coalesced_response = (protocol.LockResponse{ .coalesced = .{
                .pending = .{ .pid = pending.pid, .command = pending.command },
                .waiters = lock.waiters.len(),
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

        const replace = lock_request.if_pending == .replace;

        // Tell the client who it is waiting for. Serialized now, while the
        // holder cannot change, but sent after releasing the mutex.
        const ahead = if (replace) 0 else lock.waiters.len();
        const queued_response = (protocol.LockResponse{ .queued = .{
            .holder = lockInfo(lock_request.name, lock, ahead + 1),
            .ahead = ahead,
        } }).toJson(allocator) catch |err| {
            map.unlock();
            return err;
        };
        defer allocator.free(queued_response);

        if (replace) {
            // Every waiter is an older request for the same job, so take
            // their place. Each is woken and told who replaced it.
            var replaced_count: usize = 0;
            while (lock.waiters.popFirst()) |node| : (replaced_count += 1) {
                const replaced: *Client = @fieldParentPtr("node", node);
                replaced.state = .replaced;
                replaced.replaced_by = peer.pid;
                replaced.event.set(io);
            }
            log(.info, "Replaced {d} waiter(s) for lock '{s}'", .{ replaced_count, lock_request.name });
        }
        // Wait until a holder leaves and `grantWaiters` hands the lock to
        // this client.
        lock.enqueue(client);
        map.unlock();

        try protocol.writeLine(writer, queued_response);

        // The timeout comes from the client, so anything too large to be a
        // real limit is treated as no limit rather than trusted.
        const timeout_s: ?u64 = if (lock_request.timeout) |t| (if (t <= max_timeout_s) t else null) else null;
        if (timeout_s) |t| {
            log(.debug, "Waiting for lock '{s}' to be released with timeout of {d} seconds", .{ lock_request.name, t });
            const timeout = std.Io.Timeout{ .duration = .{
                .clock = .awake,
                .raw = std.Io.Duration.fromSeconds(@intCast(t)),
            } };

            client.event.waitTimeout(io, timeout) catch |err| switch (err) {
                error.Timeout => {
                    log(.info, "Timeout while waiting for lock '{s}' to be released", .{lock_request.name});
                    map.lock();
                    // Still waiting: give up. Otherwise the lock arrived, or
                    // this client was replaced, just as the timeout expired;
                    // handled below.
                    if (client.state == .waiting) {
                        leaveLocked(io, allocator, map, lock_request.name, client);
                        map.unlock();
                        const timeout_response = try (protocol.LockResponse{ .timeout = {} }).toJson(allocator);
                        defer allocator.free(timeout_response);
                        try protocol.writeLine(writer, timeout_response);
                        return false;
                    }
                    map.unlock();
                },
                else => return err,
            };
        } else {
            log(.debug, "Waiting for lock '{s}' to be released without timeout", .{lock_request.name});
            try client.event.wait(io);
        }

        if (client.state == .replaced) {
            log(.info, "Waiter for lock '{s}' was replaced by pid {d}", .{ lock_request.name, client.replaced_by });
            const replaced_response = try (protocol.LockResponse{ .replaced = .{
                .pid = client.replaced_by,
            } }).toJson(allocator);
            defer allocator.free(replaced_response);
            try protocol.writeLine(writer, replaced_response);
            return false;
        }
    }

    log(.info, "Sending acquired response for lock {s}.", .{lock_request.name});
    const acquired_response = try (protocol.LockResponse{ .ok = {} }).toJson(allocator);
    defer allocator.free(acquired_response);
    try protocol.writeLine(writer, acquired_response);
    return true;
}

/// Takes `client` out of the lock, wherever it is: releases the lock if it
/// holds it, or leaves the queue if it is waiting. Does nothing if it is in
/// neither, so it is safe to call more than once.
pub fn leave(
    io: Io,
    allocator: std.mem.Allocator,
    map: *LockMap,
    name: []const u8,
    client: *Client,
) void {
    map.lock();
    defer map.unlock();
    leaveLocked(io, allocator, map, name, client);
}

/// `leave`, with the map mutex already held.
fn leaveLocked(
    io: Io,
    allocator: std.mem.Allocator,
    map: *LockMap,
    name: []const u8,
    client: *Client,
) void {
    if (client.state != .holding and client.state != .waiting) return;
    const lock = map.map.getPtr(name) orelse return;
    lock.remove(client);
    // Whoever left may have been all that kept the next waiters out.
    lock.grantWaiters(io, nowSeconds(io));
    if (lock.isUnused()) {
        if (map.map.fetchRemove(name)) |kv| allocator.free(kv.key);
    }
}

fn nowSeconds(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds();
}

/// Describes the lock by its longest-standing holder. Only valid while the
/// map mutex is held.
fn lockInfo(name: []const u8, lock: *const Lock, waiters: usize) protocol.LockInfo {
    const holder = lock.firstHolder();
    return .{
        .name = name,
        .pid = if (holder) |h| h.pid else 0,
        .waiters = waiters,
        .acquired_at = if (holder) |h| h.acquired_at else 0,
        .command = if (holder) |h| h.command else "",
    };
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
            const line = try lockInfo(entry.key_ptr.*, lock, lock.waiters.len()).toJson(allocator);
            lines.append(allocator, line) catch |err| {
                allocator.free(line);
                return err;
            };
        }
    }

    for (lines.items) |line| try protocol.writeLine(writer, line);
}
