const std = @import("std");
const Io = std.Io;
const shared = @import("shared");

pub fn main(init: std.process.Init) !void {
    try run(init);
}

pub fn run(init: std.process.Init) !void {
    // Start the server to listen for incoming connections
    try runServer(init);
}

pub fn runServer(init: std.process.Init) !void {
    const io = init.io;
    const path = "/tmp/nlock.sock";

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const address = try std.Io.net.UnixAddress.init(path);

    var server = try address.listen(io, .{});
    defer server.deinit(io);
    std.debug.print("Server listening on {s}\n", .{path});

    while (true) {
        const stream = try server.accept(io);
        defer stream.close(io);

        var buffer: [1024]u8 = undefined;

        var reader = stream.reader(io, &buffer);
        const message = try reader.interface.takeDelimiterExclusive('\n');

        std.debug.print("Received message: {s}\n", .{message});

        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        try writer.interface.writeAll(message);
        try writer.interface.flush();
    }
}
