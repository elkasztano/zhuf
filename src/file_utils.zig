const std = @import("std");

pub const TokenList = union(enum) {
    u32_list: std.ArrayListUnmanaged(u32),
    u64_list: std.ArrayListUnmanaged(u64),

    /// Initializes a TokenList with capacity reserved for `capacity` elements.
    pub fn initCapacity(allocator: std.mem.Allocator, input_len: usize, capacity: usize) !TokenList {
        if (input_len <= std.math.maxInt(u32)) {
            var list = std.ArrayListUnmanaged(u32).empty;
            try list.ensureTotalCapacity(allocator, capacity);
            return .{ .u32_list = list };
        } else {
            var list = std.ArrayListUnmanaged(u64).empty;
            try list.ensureTotalCapacity(allocator, capacity);
            return .{ .u64_list = list };
        }
    }

    pub fn len(self: *const TokenList) usize {
        return switch (self.*) {
            .u32_list => |l| l.items.len,
            .u64_list => |l| l.items.len,
        };
    }

    pub fn deinit(self: *TokenList, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .u32_list => |*l| l.deinit(allocator),
            .u64_list => |*l| l.deinit(allocator),
        }
    }

    pub fn getPtr(self: TokenList, input: []const u8, index: usize) [*:0]const u8 {
        const offset: usize = switch (self) {
            .u32_list => |l| l.items[index],
            .u64_list => |l| l.items[index],
        };
        return @ptrCast(&input[offset]);
    }
};

/// Tokenizes 'input' in-place, preallocating space based on delimiter count.
pub fn tokenizeInPlace(
    allocator: std.mem.Allocator,
    tokens: *TokenList,
    input: []u8,
    delim_char: u8,
) !void {
    if (input.len == 0) return;

    const parseable_slice = input[0 .. input.len - 1];

    // Fast SIMD pass to calculate the worst-case token count
    const delim_count = std.mem.count(u8, parseable_slice, &.{delim_char});
    const max_tokens = delim_count + 1;

    tokens.* = try TokenList.initCapacity(allocator, input.len, max_tokens);

    switch (tokens.*) {
        .u32_list => |*l| tokenizeInternal(u32, l, parseable_slice, delim_char),
        .u64_list => |*l| tokenizeInternal(u64, l, parseable_slice, delim_char),
    }
}

fn tokenizeInternal(
    comptime T: type,
    list: *std.ArrayListUnmanaged(T),
    parseable_slice: []u8,
    delim_char: u8,
) void {
    var in_token = false;
    var token_start: usize = 0;

    for (parseable_slice, 0..) |char, i| {
        if (char == delim_char) {
            if (delim_char != 0) {
                parseable_slice[i] = 0;
            }

            if (in_token) {
                list.appendAssumeCapacity(@intCast(token_start));
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
        list.appendAssumeCapacity(@intCast(token_start));
    }
}

/// Reads a slice of zero-terminated string pointers into a single contiguous buffer.
pub fn readArgsToBuffer(
    allocator: std.mem.Allocator,
    args: []const [*:0]const u8,
) ![]u8 {
    if (args.len == 0) return &[_]u8{};

    // Calculate exact bytes needed: sum of (string_len + 1 null byte)
    var total_bytes: usize = 0;
    for (args) |ptr| {
        total_bytes += std.mem.len(ptr) + 1;
    }

    const buffer = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(buffer);

    var write_idx: usize = 0;
    for (args) |ptr| {
        const len = std.mem.len(ptr);
        @memcpy(buffer[write_idx .. write_idx + len + 1], ptr[0 .. len + 1]);
        write_idx += len + 1;
    }

    return buffer;
}

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

pub fn formatAndWriteTokens(
    tokens: TokenList,
    input_buffer: []const u8,
    limit: usize,
    output_len: usize,
    delim_char: u8,
    nonewline: bool,
    output_path: ?[]const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    if (limit == 0) return;

    switch (tokens) {
        .u32_list => |l| try formatAndWriteTyped(
            u32,
            l.items,
            input_buffer,
            limit,
            output_len,
            delim_char,
            nonewline,
            output_path,
            io,
            allocator,
        ),
        .u64_list => |l| try formatAndWriteTyped(
            u64,
            l.items,
            input_buffer,
            limit,
            output_len,
            delim_char,
            nonewline,
            output_path,
            io,
            allocator,
        ),
    }
}

fn formatAndWriteTyped(
    comptime T: type,
    offsets: []const T,
    input_buffer: []const u8,
    limit: usize,
    output_len: usize,
    delim_char: u8,
    nonewline: bool,
    output_path: ?[]const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    const active_count = @min(limit, offsets.len);
    if (active_count == 0) return;

    var output_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer output_buf.deinit(allocator);

    try output_buf.ensureTotalCapacityPrecise(allocator, output_len);

    var dest_ptr = output_buf.unusedCapacitySlice().ptr;
    const base_start = dest_ptr;

    // Process all tokens except the last
    for (offsets[0 .. active_count - 1]) |offset| {
        const ptr: [*:0]const u8 = @ptrCast(&input_buffer[offset]);
        const str = std.mem.span(ptr);

        // Vectorized block copy
        @memcpy(dest_ptr[0..str.len], str);
        dest_ptr += str.len;

        dest_ptr[0] = delim_char;
        dest_ptr += 1;
    }

    // Handle final token
    const last_offset = offsets[active_count - 1];
    const last_ptr: [*:0]const u8 = @ptrCast(&input_buffer[last_offset]);
    const last_str = std.mem.span(last_ptr);

    @memcpy(dest_ptr[0..last_str.len], last_str);
    dest_ptr += last_str.len;

    if (!nonewline) {
        dest_ptr[0] = '\n';
        dest_ptr += 1;
    }

    // Set written byte count
    output_buf.items.len = @intFromPtr(dest_ptr) - @intFromPtr(base_start);

    // Pass slice into existing function without changes
    try writeFromBufferBuffered(io, output_path, output_buf.items);
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
