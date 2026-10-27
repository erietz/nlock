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
    const now = clockNow(io);
    // Before `getOrPut`, which `removeUnused` would invalidate.
    removeUnused(allocator, map, now);
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
        entry.value_ptr.* = .{ .capacity = lock_request.slots };
    }
    const lock = entry.value_ptr;

    if (lock.isIdle()) {
        // Nobody holds or waits for the lock, so nobody depends on its size
        // or rate limit: take the request's. A rate-limited lock keeps the
        // grants it has counted, so this cannot reset its limit.
        lock.capacity = lock_request.slots;
        lock.setRateLimit(allocator, lock_request.rate) catch |err| {
            if (!entry.found_existing) removeLocked(allocator, map, lock_request.name);
            map.unlock();
            return err;
        };
    } else if (lock.capacity != lock_request.slots or !protocol.Rate.eql(lock.rateLimit(), lock_request.rate)) {
        // Clients that disagree on the size or rate limit of the lock would
        // each limit the others differently, so only the ones it is in use
        // with are allowed.
        const mismatch: protocol.LockResponse.Mismatch = .{ .slots = lock.capacity, .rate = lock.rateLimit() };
        map.unlock();
        log(.info, "Lock '{s}' is in use with other slots or another rate limit than requested", .{lock_request.name});
        const mismatch_response = try (protocol.LockResponse{ .mismatch = mismatch }).toJson(allocator);
        defer allocator.free(mismatch_response);
        try protocol.writeLine(writer, mismatch_response);
        return false;
    }

    // A waiter whose `nlock` has died would still count as a pending run
    // (`--coalesce`) or as someone ahead in the queue.
    lock.dropAbandonedTail(io);

    if (lock.canGrantNow(client.mode, now)) {
        lock.grant(client, now);
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
            // If nothing but the rate limit is in the way, say when it would
            // not be.
            const response: protocol.LockResponse = if (lock.waiters.first == null and lock.hasRoomFor(client.mode)) .{
                .rate_limited = .{ .retry_after_ms = msUntil(now, lock.rate.?.readyAt()) },
            } else .busy;
            map.unlock();
            const busy_response = try response.toJson(allocator);
            defer allocator.free(busy_response);
            try protocol.writeLine(writer, busy_response);
            return false;
        }

        const replace = lock_request.if_pending == .replace;

        // Tell the client who it is waiting for. Serialized now, while the
        // holder cannot change, but sent after releasing the mutex.
        const ahead = if (replace) 0 else lock.waiters.len();
        const queued_response = (protocol.LockResponse{ .queued = .{
            .holder = lockInfo(lock_request.name, lock, lock.firstHolder(), ahead + 1, now),
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
        lock.enqueue(client);
        map.unlock();

        try protocol.writeLine(writer, queued_response);

        // The timeout comes from the client, so anything too large to be a
        // real limit is treated as no limit rather than trusted.
        const timeout_s: ?u64 = if (lock_request.timeout) |t| (if (t <= max_timeout_s) t else null) else null;
        const deadline: ?i64 = if (timeout_s) |t| now.mono_ns + @as(i64, @intCast(t)) * std.time.ns_per_s else null;
        log(.debug, "Waiting for lock '{s}' (timeout: {?d}s)", .{ lock_request.name, timeout_s });

        // Wait until `grantWaiters` hands the lock to this client, or it is
        // replaced or abandoned, or the timeout expires. A holder leaving
        // wakes it. So does the rate limit, if any, while it is at the front
        // of the queue: then it waits until the limit allows the next grant,
        // and grants it itself, as no holder leaving would.
        map.lock();
        while (client.state == .waiting) {
            const t = clockNow(io);
            if (deadline) |d| if (t.mono_ns >= d) {
                log(.info, "Timeout while waiting for lock '{s}' to be released", .{lock_request.name});
                leaveLocked(io, allocator, map, lock_request.name, client);
                map.unlock();
                const timeout_response = try (protocol.LockResponse{ .timeout = {} }).toJson(allocator);
                defer allocator.free(timeout_response);
                try protocol.writeLine(writer, timeout_response);
                return false;
            };

            // A waiter keeps its lock in the map. Looked up again each time,
            // as other connections may have moved it since.
            const waited_for = map.map.getPtr(lock_request.name).?;
            waited_for.grantWaiters(io, t);
            if (client.state != .waiting) break;

            var wake_at = deadline;
            if (waited_for.rateWakeAt(client, t)) |ready| wake_at = @min(wake_at orelse ready, ready);
            // Under the mutex, as every `set` is, so no wake-up is lost.
            client.event.reset();
            map.unlock();
            const timeout: Io.Timeout = if (wake_at) |w| .{
                .deadline = .{ .clock = .boot, .raw = .{ .nanoseconds = w } },
            } else .none;
            client.event.waitTimeout(io, timeout) catch |err| switch (err) {
                error.Timeout => {},
                else => return err,
            };
            map.lock();
        }
        map.unlock();

        if (client.state == .abandoned) {
            // Nobody to tell: the socket's other end is closed.
            log(.info, "Waiter for lock '{s}' went away (pid {d})", .{ lock_request.name, peer.pid });
            return false;
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
    const now = clockNow(io);
    // Whoever left may have been all that kept the next waiters out.
    lock.grantWaiters(io, now);
    if (lock.isUnused(now)) removeLocked(allocator, map, name);
}

/// Removes lock `name` from the map, with the map mutex held.
fn removeLocked(allocator: std.mem.Allocator, map: *LockMap, name: []const u8) void {
    var kv = map.map.fetchRemove(name) orelse return;
    kv.value.deinit(allocator);
    allocator.free(kv.key);
}

/// Removes every lock that is no longer worth keeping, with the map mutex
/// held. `leave` removes a lock as soon as nobody holds or waits for it,
/// but a rate-limited one stays until its recent grants no longer count,
/// when nobody may be around to notice. Walks every lock.
fn removeUnused(allocator: std.mem.Allocator, map: *LockMap, now: queue.Now) void {
    while (true) {
        // Removing invalidates the iterator, so start over after each.
        var it = map.map.iterator();
        const name = while (it.next()) |entry| {
            if (entry.value_ptr.isUnused(now)) break entry.key_ptr.*;
        } else return;
        removeLocked(allocator, map, name);
    }
}

/// The time on both of a lock's clocks.
fn clockNow(io: Io) queue.Now {
    return .{
        .wall_s = Io.Timestamp.now(io, .real).toSeconds(),
        .mono_ns = @intCast(Io.Timestamp.now(io, .boot).nanoseconds),
    };
}

/// Milliseconds from `now` until `mono_ns`, rounded up, or 0 if it has
/// passed.
fn msUntil(now: queue.Now, mono_ns: i64) u64 {
    if (mono_ns <= now.mono_ns) return 0;
    return std.math.divCeil(u64, @intCast(mono_ns - now.mono_ns), std.time.ns_per_ms) catch unreachable;
}

/// Describes the lock and one of its holders, or no holder if null. Only
/// valid while the map mutex is held.
fn lockInfo(name: []const u8, lock: *const Lock, holder: ?*const Client, waiters: usize, now: queue.Now) protocol.LockInfo {
    return .{
        .name = name,
        .pid = if (holder) |h| h.pid else 0,
        .waiters = waiters,
        .slots = lock.capacity,
        .mode = if (holder) |h| h.mode else .exclusive,
        .acquired_at = if (holder) |h| h.acquired_at else 0,
        .command = if (holder) |h| h.command else "",
        .rate = lock.rateLimit(),
        .rate_used = if (lock.rate) |window| window.usedAt(now.mono_ns) else 0,
    };
}

pub fn handleListLocksRequest(
    io: Io,
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

        const now = clockNow(io);
        // Count only waiters that are still there. Dropping them may leave a
        // lock unused, so remove those afterwards.
        var drop_it = map.map.valueIterator();
        while (drop_it.next()) |lock| lock.dropAbandoned(io, now);
        removeUnused(allocator, map, now);

        var it = map.map.iterator();
        while (it.next()) |entry| {
            const lock = entry.value_ptr;
            // TODO: Below traversal is O(n) for waiters, store the count in
            // the lock itself. Same for holders. Probs less likely to be large
            // number holders though?
            const waiters = lock.waiters.len();
            // A lock nobody holds is still listed, once: it has waiters held
            // back by its rate limit, or it is idle but still counts recent
            // grants.
            if (lock.holders.first == null) {
                const line = try lockInfo(entry.key_ptr.*, lock, null, waiters, now).toJson(allocator);
                lines.append(allocator, line) catch |err| {
                    allocator.free(line);
                    return err;
                };
            }
            // One line per holder, longest-standing first.
            var holder_node = lock.holders.first;
            while (holder_node) |node| : (holder_node = node.next) {
                const holder: *const Client = @fieldParentPtr("node", node);
                const line = try lockInfo(entry.key_ptr.*, lock, holder, waiters, now).toJson(allocator);
                lines.append(allocator, line) catch |err| {
                    allocator.free(line);
                    return err;
                };
            }
        }
    }

    for (lines.items) |line| try protocol.writeLine(writer, line);
}
