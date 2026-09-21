const std = @import("std");
const file_utils = @import("file_utils.zig");

pub const ZhuffleDiagnostic = struct {
    unused_seed: bool = false,
};

/// Supported deterministic and random shuffle types
const ShuffleAlgo = enum {
    milk,
    monge,
    faro,
    xoroshiro128,
    xoshiro256,

    /// Parses an algorithm name string into its enum representation.
    pub fn parse(name: []const u8) ?ShuffleAlgo {
        if (std.mem.eql(u8, name, "milk")) return .milk;
        if (std.mem.eql(u8, name, "monge")) return .monge;
        if (std.mem.eql(u8, name, "faro")) return .faro;
        if (std.mem.eql(u8, name, "xoroshiro128")) return .xoroshiro128;
        if (std.mem.eql(u8, name, "xoshiro256")) return .xoshiro256;
        return null;
    }
};

/// Performs a single round of the Milk shuffle.
fn shuffleMilk(comptime T: type, items: []const T, buffer: []T) void {
    var left: usize = 0;
    var right: usize = items.len - 1;
    var i: usize = 0;
    while (left <= right) {
        if (i % 2 == 0) {
            buffer[i] = items[left];
            left += 1;
        } else {
            buffer[i] = items[right];
            right -= 1;
        }
        i += 1;
    }
}

/// Performs a single round of the Monge shuffle.
fn shuffleMonge(comptime T: type, items: []const T, buffer: []T) void {
    var left: usize = 0;
    var right: usize = items.len - 1;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        if (i % 2 == 0) {
            buffer[right] = items[i];
            right -= 1;
        } else {
            buffer[left] = items[i];
            left += 1;
        }
    }
}

/// Performs a single round of a perfect Faro Out-Shuffle.
fn shuffleFaro(comptime T: type, items: []const T, buffer: []T) void {
    const half = (items.len + 1) / 2;
    var i: usize = 0;
    while (i < half) : (i += 1) {
        buffer[i * 2] = items[i];
        if (i + half < items.len) {
            buffer[i * 2 + 1] = items[i + half];
        }
    }
}

/// Core sampling strategy targeting n pseudorandom elements with an implicit fast-path logic.
fn sampleWithoutReplacement(r: std.Random, comptime T: type, buf: []T, n: usize) void {
    const count = @min(n, buf.len);
    if (count <= 1) return;

    // Fast path: If picking the whole buffer, hand off to std's down-counter
    if (count == buf.len) {
        r.shuffle(T, buf);
        return;
    }

    // Optimized Partial Shuffle (Down-Counting)
    // We start at the target index boundary and pull random elements into it
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        const j = r.intRangeLessThan(usize, i, buf.len);
        std.mem.swap(T, &buf[i], &buf[j]);
    }
}

pub fn zhuffle(
    opt_algo: ?[]const u8,
    tokens: *file_utils.TokenList,
    n: usize,
    opt_seed: ?u64,
    io: std.Io,
    allocator: std.mem.Allocator,
    diag: ?*ZhuffleDiagnostic,
) !void {
    switch (tokens.*) {
        .u32_list => |*l| try zhuffleInternal(u32, opt_algo, l.items, n, opt_seed, io, allocator, diag),
        .u64_list => |*l| try zhuffleInternal(u64, opt_algo, l.items, n, opt_seed, io, allocator, diag),
    }
}

fn zhuffleInternal(
    comptime T: type,
    opt_algo: ?[]const u8,
    items: []T,
    n: usize,
    opt_seed: ?u64,
    io: std.Io,
    allocator: std.mem.Allocator,
    diag: ?*ZhuffleDiagnostic,
) !void {
    // fallback when opt_algo is totally absent
    if (opt_algo == null) {
        var seed_val: u64 = undefined;
        if (opt_seed) |s| {
            seed_val = s;
        } else {
            _ = std.Io.randomSecure(io, std.mem.asBytes(&seed_val)) catch {
                const now = std.Io.Clock.real.now(io);
                seed_val = @bitCast(now.toMilliseconds());
            };
        }
        var prng = std.Random.DefaultPrng.init(seed_val);
        sampleWithoutReplacement(prng.random(), T, items, n);
        return;
    }

    // extract name and iteration count (e.g., "milk:3", "xoroshiro128")
    const algo_str = opt_algo.?;
    var algo_name = algo_str;
    var iterations: usize = 1;

    if (std.mem.indexOfScalar(u8, algo_str, ':')) |colon_idx| {
        algo_name = algo_str[0..colon_idx];
        iterations = std.fmt.parseInt(usize, algo_str[colon_idx + 1 ..], 10) catch return error.UnknownAlgorithm;
    }

    // validate size or zero iteration rules early
    if (items.len <= 1 or iterations == 0) return;

    // resolve algorithm name string to enum token
    const algo = ShuffleAlgo.parse(algo_name) orelse return error.UnknownAlgorithm;

    switch (algo) {
        // deterministic multi round mechanics
        .milk, .monge, .faro => {
            if (opt_seed != null and diag != null) {
                diag.?.unused_seed = true;
            }

            // Temporary buffer scales directly with T (e.g., 4 bytes per item for u32)
            const buffer = try allocator.alloc(T, items.len);
            defer allocator.free(buffer);

            var round: usize = 0;
            while (round < iterations) : (round += 1) {
                switch (algo) {
                    .milk => shuffleMilk(T, items, buffer),
                    .monge => shuffleMonge(T, items, buffer),
                    .faro => shuffleFaro(T, items, buffer),
                    else => unreachable,
                }
                @memcpy(items, buffer);
            }
        },

        // single execution PRNG algorithms with partial cycle compatibility
        .xoroshiro128, .xoshiro256 => {
            var seed_val: u64 = undefined;
            if (opt_seed) |s| {
                seed_val = s;
            } else {
                _ = std.Io.randomSecure(io, std.mem.asBytes(&seed_val)) catch {
                    const now = std.Io.Clock.real.now(io);
                    seed_val = @bitCast(now.toMilliseconds());
                };
            }

            if (algo == .xoroshiro128) {
                var prng = std.Random.Xoroshiro128.init(seed_val);
                sampleWithoutReplacement(prng.random(), T, items, n);
            } else {
                var prng = std.Random.Xoshiro256.init(seed_val);
                sampleWithoutReplacement(prng.random(), T, items, n);
            }
        },
    }
}
