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

/// Tokenizes 'input' in-place by replacing 'delim_char' occurrences with null bytes.
/// Expects 'input' to end with an artificial trailing null-terminator at 'input.len - 1'.
pub fn tokenizeInPlace(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayListUnmanaged([*:0]const u8),
    input: []u8,
    delim_char: u8,
) !void {
    if (input.len == 0) return;

    const parseable_slice = input[0 .. input.len - 1];

    var in_token = false;
    var token_start: usize = 0;

    for (parseable_slice, 0..) |char, i| {
        if (char == delim_char) {

            // avoid unnecessary memory operation in case the elements in
            // 'input' are already null separated
            if (delim_char != 0) {
                input[i] = 0;
            }

            if (in_token) {
                const ptr: [*:0]const u8 = @ptrCast(&input[token_start]);
                try tokens.append(allocator, ptr);
                in_token = false;
            }
        } else {
            if (!in_token) {
                token_start = i;
                in_token = true;
            }
        }
    }

    if (in_token) {
        const ptr: [*:0]const u8 = @ptrCast(&input[token_start]);
        try tokens.append(allocator, ptr);
    }
}
