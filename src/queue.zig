const std = @import("std");
const Io = std.Io;

pub const Waiter = struct {
    event: Io.Event = .unset,
    node: std.DoublyLinkedList.Node = .{},
    command: []const u8,
};

pub const Lock = struct {
    waiters: std.DoublyLinkedList = .{},
    command: []const u8,
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
