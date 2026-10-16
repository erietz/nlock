const std = @import("std");
const Io = std.Io;

pub const Waiter = struct {
    /// Set once the waiter is done waiting: either the lock was handed to it,
    /// or `replaced_by` says it was taken out of the queue.
    event: Io.Event = .unset,
    node: std.DoublyLinkedList.Node = .{},
    command: []const u8,
    uid: u32,
    pid: i32 = 0,
    global: bool,
    /// The client that replaced this one in the queue (`--replace`), set
    /// before `event`. Null if the lock was handed to this waiter.
    replaced_by: ?Replacer = null,

    pub const Replacer = struct {
        uid: u32,
        pid: i32,
    };

    /// True if the lock was handed to this waiter. Only meaningful once
    /// `event` is set.
    pub fn granted(self: *const Waiter) bool {
        return self.event.isSet() and self.replaced_by == null;
    }
};

pub const Lock = struct {
    waiters: std.DoublyLinkedList = .{},
    command: []const u8,
    uid: u32,
    /// Pid of the `nlock` client holding the lock.
    pid: i32 = 0,
    global: bool,
    /// When the current holder acquired the lock, in seconds since the Unix
    /// epoch.
    acquired_at: i64 = 0,
};

test "Lock and Waiter structures" {
    var lock = Lock{
        .command = "test command",
        .uid = 0,
        .global = false,
    };

    var waiter1 = Waiter{
        .event = .unset,
        .command = "waiter1 command",
        .uid = 0,
        .global = false,
    };

    var waiter2 = Waiter{
        .event = .unset,
        .command = "waiter2 command",
        .uid = 0,
        .global = false,
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
        .uid = 0,
        .global = false,
    };

    // Initially, the event should be unset
    try std.testing.expect(waiter.event == .unset);

    // Set the event and check
    waiter.event.set(std.testing.io);
    try std.testing.expect(waiter.event == .is_set);
}
