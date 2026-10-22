const std = @import("std");
const Io = std.Io;

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer: ?*std.Io.Writer = null;
var stdout_file_writer: Io.File.Writer = undefined;

var stderr_buffer: [1024]u8 = undefined;
var stderr_writer: ?*std.Io.Writer = null;
var stderr_file_writer: Io.File.Writer = undefined;

pub fn init(io: Io) void {
    // Streaming rather than positional: positional writes start at offset 0,
    // which clobbers the file when stdout is redirected with `>>`.
    stdout_file_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    stdout_writer = &stdout_file_writer.interface;

    stderr_file_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    stderr_writer = &stderr_file_writer.interface;
}

// Print to stdout with a format string and arguments, similar to printf in C.
pub fn print(comptime fmt: []const u8, args: anytype) !void {
    const w = stdout_writer orelse return error.WriterNotInitialized;
    try w.print(fmt, args);
    try w.flush();
}

// Print to stderr with a format string and arguments, similar to
// fprintf(stderr, ...) in C.
pub fn eprint(comptime fmt: []const u8, args: anytype) !void {
    const w = stderr_writer orelse return error.WriterNotInitialized;
    try w.print(fmt, args);
    try w.flush();
}
