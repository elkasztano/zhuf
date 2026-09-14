const std = @import("std");
const KvCli = @import("kv_cli.zig").KvCli;
const file_utils = @import("file_utils.zig");
const zhuf_utils = @import("zhuf_utils.zig");

pub const ShufOptions = struct {
    seed: ?u64 = null,
    count: ?usize = null,
    delimiter: []const u8 = "\n",
    algo: ?[]const u8 = null,
    @"if": ?[]const u8 = null,
    of: ?[]const u8 = null,
};

fn printHelp() void {
    const help_text =
        \\Usage: zhuf [options]
        \\
        \\Options:
        \\  if=<path>              Input file path (default: stdin)
        \\  of=<path>              Output file path (default: stdout)
        \\  seed=<u64>             Seed for the PRNG (e.g. seed=12345)
        \\  count=<usize>          Maximum number of output items (e.g. count=42)
        \\  delimiter=<char>       Token delimiter (single character, default: "\n")
        \\                         type 'null' for the null character
        \\
        \\  algo=<algorithm>       Select algorithm for shuffle:
        \\
        \\                         Deterministic (supports optional ':N' iterations):
        \\                           milk    - Interleaves from outer edges inwards
        \\                           monge   - Alternates placing items front and back
        \\                           faro    - Perfect out-shuffle interleaving
        \\
        \\                         Pseudo-Random (runs exactly once, ignores ':N'):
        \\                           xoroshiro128
        \\                           xoshiro256
        \\                           (Omitting 'algo' falls back to default PRNG)
        \\
        \\  -n, -nonewline         Omit new line at the end of output
        \\  -h, -help              Display this help text and exit
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    var newline = true;

    // filter non-kv flags during pre-pass scan
    var kv_args: std.ArrayListUnmanaged([]const u8) = .empty;
    try kv_args.append(allocator, args[0]); // keep binary name at index 0

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-nonewline") or std.mem.eql(u8, arg, "-n")) {
            newline = false;
        } else {
            try kv_args.append(allocator, arg);
        }
    }

    const opts = KvCli.parseStruct(ShufOptions, allocator, kv_args.items) catch |err| {
        std.debug.print("\x1b[91merror\x1b[0m parsing CLI options: {s}\n\n", .{@errorName(err)});
        printHelp();
        return;
    };

    // read file or stdin into buffer
    const input = try file_utils.readToBuffer(allocator, init.io, opts.@"if");

    // handle delimiter including possible null character
    const delim_char = if (std.mem.eql(u8, opts.delimiter, "null")) 0 else if (opts.delimiter.len > 0) opts.delimiter[0] else '\n';

    // estimate total number of tokens for preallocation
    var tokens: std.ArrayListUnmanaged([*:0]const u8) = .empty;
    const estimated_tokens = input.len / 7;
    try tokens.ensureTotalCapacity(allocator, estimated_tokens);

    try file_utils.tokenizeInPlace(allocator, &tokens, input, delim_char);

    // perform actual shuffle
    var diag = zhuf_utils.ZhuffleDiagnostic{};
    const limit = if (opts.count) |c| @min(c, tokens.items.len) else tokens.items.len;
    try zhuf_utils.zhuffle(opts.algo, tokens, limit, opts.seed, init.io, allocator, &diag);

    if (diag.unused_seed) {
        std.debug.print("\x1b[93mWarning:\x1b[0m A custom seed was provided but is ignored by the deterministic algorithm.\n", .{});
    }

    if (limit > 0) {
        var output_buf: std.ArrayListUnmanaged(u8) = .empty;
        try output_buf.ensureTotalCapacityPrecise(allocator, input.len + 2);

        var dest_ptr = output_buf.unusedCapacitySlice().ptr;
        const base_start = dest_ptr;

        for (tokens.items[0..(limit - 1)]) |token| {
            // cast the sentinel pointer to a raw byte pointer
            var src_ptr: [*]const u8 = @ptrCast(token);

            // loop-copy bytes directly until we hit null byte
            while (src_ptr[0] != 0) : ({
                src_ptr += 1;
                dest_ptr += 1;
            }) {
                dest_ptr[0] = src_ptr[0];
            }

            // append the delimiter character in place
            dest_ptr[0] = delim_char;
            dest_ptr += 1;
        }

        // handle final token
        var src_ptr: [*]const u8 = @ptrCast(tokens.items[limit - 1]);
        while (src_ptr[0] != 0) : ({
            src_ptr += 1;
            dest_ptr += 1;
        }) {
            dest_ptr[0] = src_ptr[0];
        }

        if (newline) {
            dest_ptr[0] = '\n';
            dest_ptr += 1;
        }

        // inform ArrayList how many elements we wrote manually
        output_buf.items.len = (@intFromPtr(dest_ptr) - @intFromPtr(base_start));

        try file_utils.writeFromBufferBuffered(init.io, opts.of, output_buf.items);
    }
}
