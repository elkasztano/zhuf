const std = @import("std");
const KvCli = @import("kv_cli.zig").KvCli;
const file_utils = @import("file_utils.zig");
const zhuf_utils = @import("zhuf_utils.zig");

pub const ZhufOptions = struct {
    seed: ?u64 = null,
    count: ?usize = null,
    delimiter: []const u8 = "\n",
    algo: ?[]const u8 = null,
    @"if": ?[]const u8 = null,
    of: ?[]const u8 = null,
};

pub const ZhufFlags = struct {
    help: bool = false,
    nonewline: bool = false,
    echo: bool = false,

    pub const aliases = .{
        .{ "-h", "help" },
        .{ "-help", "help" },
        .{ "--help", "help" },
        .{ "-n", "nonewline" },
        .{ "-nonewline", "nonewline" },
        .{ "--no-newline", "nonewline" },
        .{ "-e", "echo" },
        .{ "-echo", "echo" },
        .{ "--echo", "echo" },
    };
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
        \\  -e, -echo, --echo               Treat positional arguments as tokens
        \\                                  Ignores 'if=' option
        \\  -n, -nonewline, --no-newline    Omit new line at the end of output
        \\  -h, -help, --help               Display this help text and exit
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    const parsed = KvCli.parse(ZhufOptions, ZhufFlags, allocator, args) catch |err| {
        std.debug.print("\x1b[91merror\x1b[0m parsing CLI options: {s}\n\n", .{@errorName(err)});
        printHelp();
        return;
    };

    if (parsed.flags.help) {
        printHelp();
        return;
    }

    // handle delimiter including possible null character
    const delim_char = if (std.mem.eql(u8, parsed.opts.delimiter, "null"))
        0
    else if (parsed.opts.delimiter.len > 0)
        parsed.opts.delimiter[0]
    else
        '\n';

    var tokens: std.ArrayListUnmanaged([*:0]const u8) = .empty;
    var output_len: usize = undefined;

    if (parsed.flags.echo) {
        tokens = parsed.positionals;
        output_len = computeTotalOutputLenNull(tokens.items, parsed.opts.delimiter.len);
    } else {

        // read file or stdin into buffer
        const input = try file_utils.readToBuffer(allocator, init.io, parsed.opts.@"if");

        // estimate total number of tokens for preallocation
        const estimated_tokens = input.len / 7;
        try tokens.ensureTotalCapacity(allocator, estimated_tokens);

        try file_utils.tokenizeInPlace(allocator, &tokens, input, delim_char);

        output_len = input.len + 2;
    }

    // perform actual shuffle
    var diag = zhuf_utils.ZhuffleDiagnostic{};
    const limit = if (parsed.opts.count) |c| @min(c, tokens.items.len) else tokens.items.len;
    try zhuf_utils.zhuffle(parsed.opts.algo, tokens, limit, parsed.opts.seed, init.io, allocator, &diag);

    if (diag.unused_seed) {
        std.debug.print("\x1b[93mWarning:\x1b[0m A custom seed was provided but is ignored by the deterministic algorithm.\n", .{});
    }

    if (limit > 0) {
        var output_buf: std.ArrayListUnmanaged(u8) = .empty;
        try output_buf.ensureTotalCapacityPrecise(allocator, output_len);

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

        if (!parsed.flags.nonewline) {
            dest_ptr[0] = '\n';
            dest_ptr += 1;
        }

        // inform ArrayList how many elements we wrote manually
        output_buf.items.len = (@intFromPtr(dest_ptr) - @intFromPtr(base_start));

        try file_utils.writeFromBufferBuffered(init.io, parsed.opts.of, output_buf.items);
    }
}

/// Compute output length for all null-terminated positional arguments
fn computeTotalOutputLenNull(args: []const [*:0]const u8, delimiter_len: usize) usize {
    var total_bytes: usize = 0;
    for (args) |arg| {
        total_bytes += std.mem.len(arg) + delimiter_len;
    }
    return total_bytes;
}
