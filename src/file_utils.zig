const std = @import("std");

/// Opens the file exactly once, preallocates memory based on size, and reads to completion.
/// Input from stdin is dynamically allocated.
pub fn readToBuffer(
    allocator: std.mem.Allocator,
    io: std.Io,
    opt_path: ?[]const u8,
) ![]u8 {
    var scratch_buf: [65536]u8 = undefined;

    if (opt_path) |path| {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
        defer file.close(io);

        // query file size
        const stats = try file.stat(io);

        // initialize the ArrayList with the exact required capacity
        var out_buf = try std.ArrayList(u8).initCapacity(allocator, stats.size);
        errdefer out_buf.deinit(allocator);

        // stream data to buffer
        var file_reader = file.reader(io, &scratch_buf);
        try file_reader.interface.appendRemainingUnlimited(allocator, &out_buf);

        // ensure null terminator byte is at the end
        try out_buf.append(allocator, 0);

        return try out_buf.toOwnedSlice(allocator);
    } else {
        // fallback for stdin, initialize with capacity
        const stdin = std.Io.File.stdin();
        var stdin_reader = stdin.reader(io, &scratch_buf);

        var out_buf = try std.ArrayList(u8).initCapacity(allocator, 65536);
        errdefer out_buf.deinit(allocator);

        try stdin_reader.interface.appendRemainingUnlimited(allocator, &out_buf);

        // ensure null terminator is at the end
        try out_buf.append(allocator, 0);

        return try out_buf.toOwnedSlice(allocator);
    }
}

/// Write to file or fallback to stdout.
pub fn writeFromBufferBuffered(
    io: std.Io,
    opt_path: ?[]const u8,
    buffer: []const u8,
) !void {
    var scratch_buf: [65536]u8 = undefined;

    if (opt_path) |path| {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);

        var file_writer = file.writer(io, &scratch_buf);
        const writer = &file_writer.interface;

        try writer.writeAll(buffer);
        try writer.flush();
    } else {
        const stdout = std.Io.File.stdout();
        var stdout_writer = stdout.writer(io, &scratch_buf);
        const writer = &stdout_writer.interface;

        try writer.writeAll(buffer);
        try writer.flush();
    }
}
