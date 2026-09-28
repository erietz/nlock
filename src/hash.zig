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

        pub fn deinit(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.map.deinit();
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.map.put(key, value);
        }

        /// Inserts `key` only if it is not already present, as a single atomic
        /// operation. Returns null on insert, or the existing value if `key`
        /// was already present (in which case the map is unchanged).
        pub fn tryPut(self: *Self, key: K, value: V) !?V {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const gop = try self.map.getOrPut(key);
            if (gop.found_existing) return gop.value_ptr.*;
            gop.value_ptr.* = value;
            return null;
        }

        pub fn get(self: *Self, key: K) ?V {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.map.get(key);
        }

        pub fn remove(self: *Self, key: K) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.map.remove(key);
        }

        pub fn fetchRemove(self: *Self, key: K) ?Map.KV {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.map.fetchRemove(key);
        }
    };
}
