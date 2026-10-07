const std = @import("std");
const Io = std.Io;

var buffer: [1024]u8 = undefined;
var writer: ?*std.Io.Writer = null;
var file_writer: Io.File.Writer = undefined;

pub fn init(io: Io) void {
    // Streaming rather than positional: positional writes start at offset 0,
    // which clobbers the file when stdout is redirected with `>>`.
    file_writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    writer = &file_writer.interface;
}

pub fn print(comptime fmt: []const u8, args: anytype) !void {
    const w = writer orelse return error.WriterNotInitialized;
    try w.print(fmt, args);
    try w.flush();
}
