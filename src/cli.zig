const std = @import("std");

pub fn usage() []const u8 {
    return
    \\Usage: nlock run <name> [--global] -- <command> [args...]
    \\       nlock list
    \\
    ;
}

test "usage function returns correct usage string" {
    const expected =
        \\Usage: nlock run <name> [--global] -- <command> [args...]
        \\       nlock list
        \\
    ;
    try std.testing.expectEqualStrings(expected, usage());
}
