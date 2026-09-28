const std = @import("std");

pub fn ThreadSafeHashMap(io: std.Io, comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        map: std.AutoHashMap(K, V),
        mutex: std.Io.Mutex,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .map = std.AutoHashMap(K, V).init(allocator),
                .mutex = .init,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock(io);
            defer self.mutex.unlock(io);
            self.map.deinit();
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            self.mutex.lock(io);
            defer self.mutex.unlock(io);
            try self.map.put(key, value);
        }

        pub fn get(self: *Self, key: K) ?V {
            self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.map.get(key);
        }

        pub fn remove(self: *Self, key: K) bool {
            self.mutex.lock(io);
            defer self.mutex.unlock(io);
            return self.map.remove(key);
        }
    };
}
