const std = @import("std");

/// A string-keyed hash map guarded by a mutex. Hold the mutex, with `lock`
/// and `unlock`, for as long as `map` or any pointer into it is in use.
pub fn LockedStringMap(comptime V: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        mutex: std.Io.Mutex = .init,
        map: std.StringHashMap(V),

        pub fn init(io: std.Io, allocator: std.mem.Allocator) Self {
            return .{ .io = io, .map = .init(allocator) };
        }

        /// Only safe once nothing else can use the map.
        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        pub fn lock(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
        }

        pub fn unlock(self: *Self) void {
            self.mutex.unlock(self.io);
        }
    };
}

test "LockedStringMap guards its map" {
    var map = LockedStringMap(u32).init(std.testing.io, std.testing.allocator);
    defer map.deinit();

    map.lock();
    try map.map.put("a", 1);
    map.unlock();

    map.lock();
    defer map.unlock();
    try std.testing.expectEqual(@as(?u32, 1), map.map.get("a"));
}
