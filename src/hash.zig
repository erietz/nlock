const std = @import("std");

pub fn ThreadSafeHashMap(comptime K: type, comptime V: type) type {
    const Map = if (K == []const u8) std.StringHashMap(V) else std.AutoHashMap(K, V);

    return struct {
        const Self = @This();

        io: std.Io,
        map: Map,
        mutex: std.Io.Mutex,

        pub fn init(io: std.Io, allocator: std.mem.Allocator) Self {
            return .{
                .io = io,
                .map = Map.init(allocator),
                .mutex = .init,
            };
        }

        pub fn lock(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
        }

        pub fn unlock(self: *Self) void {
            self.mutex.unlock(self.io);
        }

        pub fn deinit(self: *Self) void {
            self.lock();
            defer self.unlock();
            self.map.deinit();
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            self.lock();
            defer self.unlock();
            try self.map.put(key, value);
        }

        /// Inserts `key` only if it is not already present, as a single atomic
        /// operation. Returns true on insert, or false if `key` was already
        /// present (in which case the map is unchanged). The existing value is
        /// deliberately not returned: once the mutex is released another task
        /// may remove and free it.
        pub fn tryPut(self: *Self, key: K, value: V) !bool {
            self.lock();
            defer self.unlock();
            const gop = try self.map.getOrPut(key);
            if (gop.found_existing) {
                return false;
            }
            gop.value_ptr.* = value;
            return true;
        }

        pub fn get(self: *Self, key: K) ?V {
            self.lock();
            defer self.unlock();
            return self.map.get(key);
        }

        pub fn getPtr(self: *Self, key: K) ?*V {
            self.lock();
            defer self.unlock();
            return self.map.getPtr(key);
        }

        pub fn remove(self: *Self, key: K) bool {
            self.lock();
            defer self.unlock();
            return self.map.remove(key);
        }

        pub fn fetchRemove(self: *Self, key: K) ?Map.KV {
            self.lock();
            defer self.unlock();
            return self.map.fetchRemove(key);
        }
    };
}

test "ThreadSafeHashMap basic operations and manual locking" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var map = ThreadSafeHashMap([]const u8, u32).init(io, allocator);
    defer map.deinit();

    try map.put("a", 1);
    try std.testing.expectEqual(@as(?u32, 1), map.get("a"));

    // tryPut on existing key should return false
    try std.testing.expect(!try map.tryPut("a", 2));
    try std.testing.expectEqual(@as(?u32, 1), map.get("a"));

    // tryPut on new key
    try std.testing.expect(try map.tryPut("b", 2));
    try std.testing.expectEqual(@as(?u32, 2), map.get("b"));

    // Manual lock / unlock control
    map.lock();
    if (map.map.getPtr("a")) |ptr| {
        ptr.* = 42;
    }
    map.unlock();

    try std.testing.expectEqual(@as(?u32, 42), map.get("a"));

    // fetchRemove
    const kv = map.fetchRemove("a");
    try std.testing.expect(kv != null);
    try std.testing.expectEqualStrings("a", kv.?.key);
    try std.testing.expectEqual(@as(u32, 42), kv.?.value);
    try std.testing.expectEqual(@as(?u32, null), map.get("a"));
}
