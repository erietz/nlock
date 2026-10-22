const std = @import("std");
const Io = std.Io;

pub const Waiter = struct {
    /// Set once the waiter is done waiting: either the lock was handed to it,
    /// or `replaced_by` says it was taken out of the queue.
    event: Io.Event = .unset,
    node: std.DoublyLinkedList.Node = .{},
    command: []const u8,
    pid: i32 = 0,
    /// Pid of the client that replaced this one in the queue (`--replace`),
    /// or 0 if unknown. Set before `event`. Null if the lock was handed to
    /// this waiter.
    replaced_by: ?i32 = null,

    /// True if the lock was handed to this waiter. Only meaningful once
    /// `event` is set.
    pub fn granted(self: *const Waiter) bool {
        return self.event.isSet() and self.replaced_by == null;
    }
};

pub const Lock = struct {
    waiters: std.DoublyLinkedList = .{},
    command: []const u8,
    /// Pid of the `nlock` client holding the lock.
    pid: i32 = 0,
    /// When the current holder acquired the lock, in seconds since the Unix
    /// epoch.
    acquired_at: i64 = 0,
};

test "Lock and Waiter structures" {
    var lock = Lock{
        .command = "test command",
    };

    var waiter1 = Waiter{
        .event = .unset,
        .command = "waiter1 command",
    };

    var waiter2 = Waiter{
        .event = .unset,
        .command = "waiter2 command",
    };

    lock.waiters.append(&waiter1.node);
    lock.waiters.append(&waiter2.node);

    // Check that the waiters are in the list
    try std.testing.expect(lock.waiters.len() == 2);
}

test "Waiter event handling" {
    var waiter = Waiter{
        .event = .unset,
        .command = "waiter command",
    };

    // Initially, the event should be unset
    try std.testing.expect(waiter.event == .unset);

    // Set the event and check
    waiter.event.set(std.testing.io);
    try std.testing.expect(waiter.event == .is_set);
}
