const std = @import("std");
const Io = std.Io;
const nlock = @import("nlock");
const Mode = nlock.protocol.Mode;

/// One client's claim on a lock: queued in `Lock.waiters`, then moved to
/// `Lock.holders` when granted. Owned by the connection, which outlives both,
/// so the lock never owns or frees it.
pub const Client = struct {
    node: std.DoublyLinkedList.Node = .{},
    /// Set when the client stops waiting: granted, replaced, or abandoned.
    event: Io.Event = .unset,
    state: State = .idle,
    /// Borrowed from the connection's request, which outlives the client.
    command: []const u8,
    /// Pid of the `nlock` client, or 0 if unknown.
    pid: i32 = 0,
    mode: Mode = .exclusive,
    /// When it became a holder, in seconds since the Unix epoch.
    acquired_at: i64 = 0,
    /// Pid of the client that replaced this one in the queue (`--replace`),
    /// or 0 if unknown. Only meaningful in the `replaced` state.
    replaced_by: i32 = 0,
    /// The connection's socket, or null if there is none (in tests). A
    /// waiter's thread is blocked on `event`, not reading it, so this is how
    /// the lock notices a waiter whose `nlock` has died.
    socket: ?std.posix.fd_t = null,

    /// True if the client's `nlock` has gone away. Only call this while the
    /// client is in one of the lock's lists, so its socket is still open.
    pub fn hungUp(self: *const Client) bool {
        const socket = self.socket orelse return false;
        return nlock.peer.hungUp(socket);
    }

    /// Which list `node` is in, if any. Only read or written under the map
    /// mutex.
    pub const State = enum {
        /// In neither list: not yet queued, or already left.
        idle,
        /// In `Lock.waiters`.
        waiting,
        /// In `Lock.holders`.
        holding,
        /// Taken out of `Lock.waiters` by a newer client (`--replace`).
        replaced,
        /// Taken out of `Lock.waiters` because its `nlock` went away while
        /// waiting.
        abandoned,
    };
};

pub const Lock = struct {
    holders: std.DoublyLinkedList = .{},
    waiters: std.DoublyLinkedList = .{},
    /// How many clients may hold the lock at once (`--slots`).
    capacity: u32 = 1,
    /// Length of `holders`, which would otherwise take a walk of the list to
    /// count.
    holder_count: u32 = 0,
    /// How many of `holders` hold the lock shared.
    shared_count: u32 = 0,

    /// True if a client could hold the lock in `mode` alongside the current
    /// holders. Shared holders exclude exclusive ones and vice versa; shared
    /// holders are not limited by `capacity`, which is 1 for any lock held
    /// shared.
    pub fn hasRoomFor(self: *const Lock, mode: Mode) bool {
        return switch (mode) {
            .exclusive => self.shared_count == 0 and self.holder_count < self.capacity,
            .shared => self.shared_count == self.holder_count,
        };
    }

    /// A new request may skip the queue only if nobody is queued. Otherwise,
    /// FIFO order breaks, and a stream of shared requests could keep an
    /// exclusive one waiting forever.
    pub fn canGrantNow(self: *const Lock, mode: Mode) bool {
        return self.hasRoomFor(mode) and self.waiters.first == null;
    }

    pub fn grant(self: *Lock, client: *Client, now: i64) void {
        self.holders.append(&client.node);
        self.holder_count += 1;
        if (client.mode == .shared) self.shared_count += 1;
        client.state = .holding;
        client.acquired_at = now;
    }

    pub fn enqueue(self: *Lock, client: *Client) void {
        self.waiters.append(&client.node);
        client.state = .waiting;
    }

    /// Grants waiters from the front of the queue while there is room for
    /// them. Never skips over a waiter, so the queue stays FIFO: a run of
    /// shared waiters is granted together, but stops at the first exclusive
    /// one.
    /// Waiters whose `nlock` has gone are dropped rather than granted.
    pub fn grantWaiters(self: *Lock, io: Io, now: i64) void {
        while (self.waiters.first) |waiter_node| {
            const client: *Client = @fieldParentPtr("node", waiter_node);
            if (client.hungUp()) {
                self.abandon(io, client);
                continue;
            }
            if (!self.hasRoomFor(client.mode)) break;
            _ = self.waiters.popFirst();
            self.grant(client, now);
            client.event.set(io);
        }
    }

    /// Drops waiters whose `nlock` has gone from the back of the queue, so
    /// `lastWaiter` is one that will still run. Stops at the first one that
    /// is still there, so it costs one check while nobody has died. Never
    /// makes room for anyone: the front of the queue only changes if every
    /// waiter is dropped.
    pub fn dropAbandonedTail(self: *Lock, io: Io) void {
        while (self.lastWaiter()) |client| {
            if (!client.hungUp()) break;
            self.abandon(io, client);
        }
    }

    /// Drops every waiter whose `nlock` has gone, then grants the lock to
    /// whoever they were keeping out. Costs one check per waiter.
    pub fn dropAbandoned(self: *Lock, io: Io, now: i64) void {
        var node = self.waiters.first;
        while (node) |n| {
            node = n.next;
            const client: *Client = @fieldParentPtr("node", n);
            if (client.hungUp()) self.abandon(io, client);
        }
        self.grantWaiters(io, now);
    }

    /// Takes a waiter whose `nlock` has gone out of the queue, and wakes its
    /// connection so it can finish.
    fn abandon(self: *Lock, io: Io, client: *Client) void {
        self.waiters.remove(&client.node);
        client.state = .abandoned;
        client.event.set(io);
    }

    /// Takes the client out of whichever list it is in, if any.
    pub fn remove(self: *Lock, client: *Client) void {
        switch (client.state) {
            .holding => {
                self.holders.remove(&client.node);
                self.holder_count -= 1;
                if (client.mode == .shared) self.shared_count -= 1;
            },
            .waiting => self.waiters.remove(&client.node),
            .idle, .replaced, .abandoned => return,
        }
        client.state = .idle;
    }

    /// The longest-standing holder, or null if nobody holds the lock.
    pub fn firstHolder(self: *const Lock) ?*Client {
        const node = self.holders.first orelse return null;
        return @fieldParentPtr("node", node);
    }

    /// The most recently queued waiter, or null if nobody is waiting.
    pub fn lastWaiter(self: *const Lock) ?*Client {
        const node = self.waiters.last orelse return null;
        return @fieldParentPtr("node", node);
    }

    pub fn isUnused(self: *const Lock) bool {
        return self.holders.first == null and self.waiters.first == null;
    }
};

test "grantWaiters hands a capacity-1 lock to one waiter at a time, in order" {
    var lock: Lock = .{};
    var a: Client = .{ .command = "a" };
    var b: Client = .{ .command = "b" };
    var c: Client = .{ .command = "c" };

    try std.testing.expect(lock.canGrantNow(.exclusive));
    lock.grant(&a, 1);
    try std.testing.expect(!lock.canGrantNow(.exclusive));
    lock.enqueue(&b);
    lock.enqueue(&c);

    lock.grantWaiters(std.testing.io, 2);
    try std.testing.expectEqual(Client.State.waiting, b.state);

    lock.remove(&a);
    lock.grantWaiters(std.testing.io, 3);
    try std.testing.expectEqual(Client.State.holding, b.state);
    try std.testing.expect(b.event.isSet());
    try std.testing.expectEqual(@as(i64, 3), b.acquired_at);
    try std.testing.expectEqual(Client.State.waiting, c.state);
    try std.testing.expectEqual(&b, lock.firstHolder().?);
}

test "grantWaiters fills every free slot without skipping a waiter" {
    var lock: Lock = .{ .capacity = 2 };
    var a: Client = .{ .command = "a" };
    var b: Client = .{ .command = "b" };
    var c: Client = .{ .command = "c" };
    var d: Client = .{ .command = "d" };

    lock.grant(&a, 1);
    // There is room, but a queued client would be skipped.
    lock.enqueue(&b);
    try std.testing.expect(!lock.canGrantNow(.exclusive));
    lock.enqueue(&c);
    lock.enqueue(&d);

    lock.grantWaiters(std.testing.io, 2);
    try std.testing.expectEqual(Client.State.holding, b.state);
    try std.testing.expectEqual(Client.State.waiting, c.state);

    lock.remove(&a);
    lock.remove(&b);
    lock.grantWaiters(std.testing.io, 3);
    try std.testing.expectEqual(Client.State.holding, c.state);
    try std.testing.expectEqual(Client.State.holding, d.state);
    try std.testing.expectEqual(@as(u32, 2), lock.holder_count);
    try std.testing.expectEqual(@as(usize, 2), lock.holders.len());
}

test "remove is a no-op for a client in neither list" {
    var lock: Lock = .{};
    var a: Client = .{ .command = "a" };

    lock.remove(&a);
    lock.grant(&a, 1);
    lock.remove(&a);
    lock.remove(&a);
    try std.testing.expectEqual(Client.State.idle, a.state);
    try std.testing.expect(lock.isUnused());
}

test "shared holders share the lock, and exclude an exclusive one" {
    var lock: Lock = .{};
    var r1: Client = .{ .command = "r1", .mode = .shared };
    var r2: Client = .{ .command = "r2", .mode = .shared };
    var w: Client = .{ .command = "w" };

    lock.grant(&r1, 1);
    try std.testing.expect(lock.canGrantNow(.shared));
    try std.testing.expect(!lock.canGrantNow(.exclusive));
    lock.grant(&r2, 1);

    lock.enqueue(&w);
    lock.remove(&r1);
    lock.grantWaiters(std.testing.io, 2);
    try std.testing.expectEqual(Client.State.waiting, w.state);

    lock.remove(&r2);
    lock.grantWaiters(std.testing.io, 3);
    try std.testing.expectEqual(Client.State.holding, w.state);
    try std.testing.expect(!lock.canGrantNow(.shared));
    try std.testing.expect(!lock.canGrantNow(.exclusive));
}

test "a queued exclusive waiter is not starved by later shared requests" {
    var lock: Lock = .{};
    var r1: Client = .{ .command = "r1", .mode = .shared };
    var w: Client = .{ .command = "w" };
    var r2: Client = .{ .command = "r2", .mode = .shared };
    var r3: Client = .{ .command = "r3", .mode = .shared };

    lock.grant(&r1, 1);
    lock.enqueue(&w);
    // The lock is held shared, but a shared request must not overtake the
    // exclusive one already waiting.
    try std.testing.expect(!lock.canGrantNow(.shared));
    lock.enqueue(&r2);
    lock.enqueue(&r3);

    lock.remove(&r1);
    lock.grantWaiters(std.testing.io, 2);
    try std.testing.expectEqual(Client.State.holding, w.state);
    try std.testing.expectEqual(Client.State.waiting, r2.state);

    // Once the exclusive holder leaves, every shared waiter behind it is
    // granted together.
    lock.remove(&w);
    lock.grantWaiters(std.testing.io, 3);
    try std.testing.expectEqual(Client.State.holding, r2.state);
    try std.testing.expectEqual(Client.State.holding, r3.state);
    try std.testing.expectEqual(@as(u32, 2), lock.shared_count);
}

test "grantWaiters stops at the first waiter that does not fit" {
    var lock: Lock = .{};
    var w1: Client = .{ .command = "w1" };
    var r1: Client = .{ .command = "r1", .mode = .shared };
    var w2: Client = .{ .command = "w2" };
    var r2: Client = .{ .command = "r2", .mode = .shared };

    lock.grant(&w1, 1);
    lock.enqueue(&r1);
    lock.enqueue(&w2);
    lock.enqueue(&r2);

    lock.remove(&w1);
    lock.grantWaiters(std.testing.io, 2);
    try std.testing.expectEqual(Client.State.holding, r1.state);
    try std.testing.expectEqual(Client.State.waiting, w2.state);
    try std.testing.expectEqual(Client.State.waiting, r2.state);
}

/// A connected pair of sockets: `daemon` for a `Client`, `nlock` to close
/// as if the client's process had died.
const TestSocket = struct {
    daemon: std.posix.fd_t,
    nlock: std.posix.fd_t,

    fn open() !TestSocket {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
        return .{ .daemon = fds[0], .nlock = fds[1] };
    }

    fn hangUp(self: *TestSocket) void {
        _ = std.c.close(self.nlock);
        self.nlock = -1;
    }

    fn close(self: *TestSocket) void {
        _ = std.c.close(self.daemon);
        if (self.nlock != -1) _ = std.c.close(self.nlock);
    }
};

test "grantWaiters drops waiters whose nlock has gone instead of granting them" {
    var sa = try TestSocket.open();
    defer sa.close();
    var sb = try TestSocket.open();
    defer sb.close();

    var lock: Lock = .{};
    var holder: Client = .{ .command = "holder" };
    var a: Client = .{ .command = "a", .socket = sa.daemon };
    var b: Client = .{ .command = "b", .socket = sb.daemon };

    lock.grant(&holder, 1);
    lock.enqueue(&a);
    lock.enqueue(&b);
    sa.hangUp();

    lock.remove(&holder);
    lock.grantWaiters(std.testing.io, 2);
    try std.testing.expectEqual(Client.State.abandoned, a.state);
    try std.testing.expect(a.event.isSet());
    try std.testing.expectEqual(Client.State.holding, b.state);
    try std.testing.expectEqual(&b, lock.firstHolder().?);
}

test "dropAbandonedTail drops dead waiters from the back only" {
    var sa = try TestSocket.open();
    defer sa.close();
    var sb = try TestSocket.open();
    defer sb.close();
    var sc = try TestSocket.open();
    defer sc.close();

    var lock: Lock = .{};
    var holder: Client = .{ .command = "holder" };
    var a: Client = .{ .command = "a", .socket = sa.daemon };
    var b: Client = .{ .command = "b", .socket = sb.daemon };
    var c: Client = .{ .command = "c", .socket = sc.daemon };

    lock.grant(&holder, 1);
    lock.enqueue(&a);
    lock.enqueue(&b);
    lock.enqueue(&c);
    sa.hangUp();
    sc.hangUp();

    lock.dropAbandonedTail(std.testing.io);
    try std.testing.expectEqual(Client.State.abandoned, c.state);
    try std.testing.expectEqual(&b, lock.lastWaiter().?);
    // Not at the back, so left for `grantWaiters` or `dropAbandoned`.
    try std.testing.expectEqual(Client.State.waiting, a.state);
}

test "dropAbandoned drops every dead waiter and grants whoever they kept out" {
    var sw = try TestSocket.open();
    defer sw.close();
    var sr = try TestSocket.open();
    defer sr.close();

    var lock: Lock = .{};
    var r1: Client = .{ .command = "r1", .mode = .shared };
    var w: Client = .{ .command = "w", .socket = sw.daemon };
    var r2: Client = .{ .command = "r2", .mode = .shared, .socket = sr.daemon };

    // The exclusive waiter keeps the shared one out, though the lock is held
    // shared. Once it is gone, nothing does.
    lock.grant(&r1, 1);
    lock.enqueue(&w);
    lock.enqueue(&r2);
    sw.hangUp();

    lock.dropAbandoned(std.testing.io, 2);
    try std.testing.expectEqual(Client.State.abandoned, w.state);
    try std.testing.expectEqual(Client.State.holding, r2.state);
    try std.testing.expectEqual(@as(u32, 2), lock.shared_count);
}
