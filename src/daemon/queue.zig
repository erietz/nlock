const std = @import("std");
const Io = std.Io;

/// One client's claim on a lock: queued in `Lock.waiters`, then moved to
/// `Lock.holders` when granted. Owned by the connection, which outlives both,
/// so the lock never owns or frees it.
pub const Client = struct {
    node: std.DoublyLinkedList.Node = .{},
    /// Set when the client stops waiting: granted, or replaced.
    event: Io.Event = .unset,
    state: State = .idle,
    /// Borrowed from the connection's request, which outlives the client.
    command: []const u8,
    /// Pid of the `nlock` client, or 0 if unknown.
    pid: i32 = 0,
    /// When it became a holder, in seconds since the Unix epoch.
    acquired_at: i64 = 0,
    /// Pid of the client that replaced this one in the queue (`--replace`),
    /// or 0 if unknown. Only meaningful in the `replaced` state.
    replaced_by: i32 = 0,

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

    pub fn hasRoom(self: *const Lock) bool {
        return self.holder_count < self.capacity;
    }

    /// A new request may skip the queue only if nobody is queued. Otherwise,
    /// FIFO order breaks, which also matters for writer starvation.
    pub fn canGrantNow(self: *const Lock) bool {
        return self.hasRoom() and self.waiters.first == null;
    }

    pub fn grant(self: *Lock, client: *Client, now: i64) void {
        self.holders.append(&client.node);
        self.holder_count += 1;
        client.state = .holding;
        client.acquired_at = now;
    }

    pub fn enqueue(self: *Lock, client: *Client) void {
        self.waiters.append(&client.node);
        client.state = .waiting;
    }

    /// Grants waiters from the front of the queue while there is room. Never
    /// skips over a waiter, so the queue stays FIFO.
    pub fn grantWaiters(self: *Lock, io: Io, now: i64) void {
        while (self.hasRoom()) {
            const waiter_node = self.waiters.popFirst() orelse break;
            const client: *Client = @fieldParentPtr("node", waiter_node);
            self.grant(client, now);
            client.event.set(io);
        }
    }

    /// Takes the client out of whichever list it is in, if any.
    pub fn remove(self: *Lock, client: *Client) void {
        switch (client.state) {
            .holding => {
                self.holders.remove(&client.node);
                self.holder_count -= 1;
            },
            .waiting => self.waiters.remove(&client.node),
            .idle, .replaced => return,
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

    try std.testing.expect(lock.canGrantNow());
    lock.grant(&a, 1);
    try std.testing.expect(!lock.canGrantNow());
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
    try std.testing.expect(!lock.canGrantNow());
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
