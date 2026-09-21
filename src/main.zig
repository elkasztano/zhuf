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
    const delim_char: u8 = if (std.mem.eql(u8, parsed.opts.delimiter, "null"))
        0
    else if (parsed.opts.delimiter.len > 0)
        parsed.opts.delimiter[0]
    else
        '\n';

    var tokens: file_utils.TokenList = undefined;
    var output_len: usize = undefined;
    var input_buf: []u8 = undefined;

    if (parsed.flags.echo) {
        input_buf = try file_utils.readArgsToBuffer(allocator, parsed.positionals.items);
        const estimated_tokens = 16;
        tokens = try file_utils.TokenList.initCapacity(allocator, input_buf.len, estimated_tokens);

        // positional parameters are always zero terminated
        try file_utils.tokenizeInPlace(allocator, &tokens, input_buf, 0);

        output_len = input_buf.len + 2;
    } else {
        // read file or stdin into buffer
        input_buf = try file_utils.readToBuffer(allocator, init.io, parsed.opts.@"if");

        // estimate total number of tokens for preallocation
        const estimated_tokens = input_buf.len / 7;
        tokens = try file_utils.TokenList.initCapacity(allocator, input_buf.len, estimated_tokens);

        try file_utils.tokenizeInPlace(allocator, &tokens, input_buf, delim_char);

        output_len = input_buf.len + 2;
    }

    // perform actual shuffle
    var diag = zhuf_utils.ZhuffleDiagnostic{};
    const total_tokens = tokens.len();
    const limit = if (parsed.opts.count) |c| @min(c, total_tokens) else total_tokens;

    try zhuf_utils.zhuffle(parsed.opts.algo, &tokens, limit, parsed.opts.seed, init.io, allocator, &diag);

    if (diag.unused_seed) {
        std.debug.print("\x1b[93mWarning:\x1b[0m A custom seed was provided but is ignored by the deterministic algorithm.\n", .{});
    }

    if (limit > 0) {
        try file_utils.formatAndWriteTokens(
            tokens,
            input_buf,
            limit,
            output_len,
            delim_char,
            parsed.flags.nonewline,
            parsed.opts.of,
            init.io,
            allocator,
        );
    }
}
