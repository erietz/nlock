//! The history behind a lock's rate limit (`--rate`): at most `count` grants
//! in any window of `period_ns`. Times are nanoseconds on a monotonic clock
//! that keeps counting while the machine sleeps, as an external quota does.

const std = @import("std");

/// The most recent grants of a rate-limited lock, oldest first, in a ring
/// buffer of `count` entries. Never grows: older grants are overwritten once
/// they no longer matter.
pub const Window = struct {
    count: u32,
    period_ns: i64,
    /// Grant times. Only the first `len` entries, starting at `oldest` and
    /// wrapping around, are filled.
    starts: []i64,
    /// Index of the oldest grant in `starts`.
    oldest: u32 = 0,
    /// How many grants are recorded, up to `count`.
    len: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, count: u32, period_ns: i64) !Window {
        std.debug.assert(count > 0 and period_ns > 0);
        return .{
            .count = count,
            .period_ns = period_ns,
            .starts = try allocator.alloc(i64, count),
        };
    }

    pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        allocator.free(self.starts);
        self.* = undefined;
    }

    /// True if a grant at `now` stays within the limit.
    pub fn allows(self: *const Window, now: i64) bool {
        return now >= self.readyAt();
    }

    /// Records a grant at `now`, which must be allowed.
    pub fn record(self: *Window, now: i64) void {
        std.debug.assert(self.allows(now));
        if (self.len < self.count) {
            self.starts[self.index(self.len)] = now;
            self.len += 1;
        } else {
            self.starts[self.oldest] = now;
            self.oldest = @intCast(self.index(1));
        }
    }

    /// The earliest time the next grant is allowed: a full period after the
    /// oldest of the last `count` grants. `minInt` while fewer were made.
    pub fn readyAt(self: *const Window) i64 {
        if (self.len < self.count) return std.math.minInt(i64);
        return self.starts[self.oldest] + self.period_ns;
    }

    /// How many grants fall inside the window ending at `now`.
    pub fn usedAt(self: *const Window, now: i64) u32 {
        var used: u32 = 0;
        // Newest first: once one is outside the window, so are the rest.
        while (used < self.len) : (used += 1) {
            if (self.starts[self.index(self.len - 1 - used)] + self.period_ns <= now) break;
        }
        return used;
    }

    /// When the history stops limiting anything: a full period after the
    /// newest grant. `minInt` if there were none.
    pub fn idleAt(self: *const Window) i64 {
        if (self.len == 0) return std.math.minInt(i64);
        return self.starts[self.index(self.len - 1)] + self.period_ns;
    }

    /// Returns a window with a different limit that keeps as many of the most
    /// recent grants as fit, so changing the limit cannot reset it. The caller
    /// still owns `self`.
    pub fn withLimit(self: *const Window, allocator: std.mem.Allocator, count: u32, period_ns: i64) !Window {
        var window: Window = try .init(allocator, count, period_ns);
        const kept = @min(self.len, count);
        for (self.len - kept..self.len) |i| {
            window.starts[window.len] = self.starts[self.index(@intCast(i))];
            window.len += 1;
        }
        return window;
    }

    /// Index in `starts` of the grant `offset` places after the oldest.
    fn index(self: *const Window, offset: u32) u32 {
        return (self.oldest + offset) % self.count;
    }
};

const testing = std.testing;

test "Window allows count grants, then the next once the oldest is a period old" {
    var window: Window = try .init(testing.allocator, 2, 100);
    defer window.deinit(testing.allocator);

    try testing.expect(window.allows(0));
    window.record(0);
    window.record(10);
    try testing.expect(!window.allows(10));
    try testing.expect(!window.allows(99));
    try testing.expectEqual(100, window.readyAt());

    // The slot freed by the grant at 0 comes back at 100, and the one freed
    // by the grant at 10 only at 110.
    try testing.expect(window.allows(100));
    window.record(100);
    try testing.expect(!window.allows(100));
    try testing.expectEqual(110, window.readyAt());
}

test "Window never lets more than count grants into any period, across many wraps" {
    const count = 3;
    const period = 50;
    var window: Window = try .init(testing.allocator, count, period);
    defer window.deinit(testing.allocator);

    var granted: std.ArrayList(i64) = .empty;
    defer granted.deinit(testing.allocator);
    // Ask every tick and grant whenever allowed, which is as fast as the
    // limit permits.
    var now: i64 = 0;
    while (now < 1000) : (now += 1) {
        if (!window.allows(now)) continue;
        window.record(now);
        try granted.append(testing.allocator, now);
    }

    // Any count + 1 consecutive grants span at least a full period.
    for (granted.items[count..], 0..) |t, i| {
        try testing.expect(t - granted.items[i] >= period);
    }
    // And the limit is reached, not just respected: count per period.
    try testing.expectEqual(count * (1000 / period), granted.items.len);
}

test "Window.usedAt counts only grants inside the window" {
    var window: Window = try .init(testing.allocator, 4, 100);
    defer window.deinit(testing.allocator);

    try testing.expectEqual(0, window.usedAt(0));
    for ([_]i64{ 0, 30, 60 }) |t| window.record(t);
    try testing.expectEqual(3, window.usedAt(60));
    try testing.expectEqual(2, window.usedAt(100));
    try testing.expectEqual(1, window.usedAt(159));
    try testing.expectEqual(0, window.usedAt(160));

    // Still right once the ring has wrapped: 60, 200, 210, 220 are recorded.
    for ([_]i64{ 200, 210, 220 }) |t| window.record(t);
    try testing.expectEqual(3, window.usedAt(220));
    try testing.expectEqual(2, window.usedAt(305));
}

test "Window.idleAt is a period after the newest grant" {
    var window: Window = try .init(testing.allocator, 2, 100);
    defer window.deinit(testing.allocator);

    try testing.expectEqual(std.math.minInt(i64), window.idleAt());
    window.record(5);
    try testing.expectEqual(105, window.idleAt());
    window.record(40);
    window.record(120);
    try testing.expectEqual(220, window.idleAt());
}

test "Window.withLimit keeps the most recent grants that fit" {
    var window: Window = try .init(testing.allocator, 3, 100);
    defer window.deinit(testing.allocator);
    for ([_]i64{ 0, 10, 20 }) |t| window.record(t);
    window.record(100); // Wraps, overwriting the grant at 0.

    // Fewer grants allowed: only the newest two carry over.
    var smaller = try window.withLimit(testing.allocator, 2, 100);
    defer smaller.deinit(testing.allocator);
    try testing.expectEqual(2, smaller.len);
    try testing.expect(!smaller.allows(100));
    try testing.expectEqual(120, smaller.readyAt());

    // More allowed, and a longer period: every grant carries over, in order.
    var larger = try window.withLimit(testing.allocator, 5, 1000);
    defer larger.deinit(testing.allocator);
    try testing.expectEqual(3, larger.len);
    try testing.expect(larger.allows(100));
    larger.record(100);
    larger.record(101);
    try testing.expectEqual(1010, larger.readyAt());
    try testing.expectEqual(1101, larger.idleAt());
}
