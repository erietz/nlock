const std = @import("std");

pub fn usage() []const u8 {
    return "Usage: nlock <name> [--global] -- <command> [args...]\n";
}

test "usage function returns correct usage string" {
    const expected = "Usage: nlock <name> [--global] -- <command> [args...]\n";
    try std.testing.expectEqualStrings(expected, usage());
}
