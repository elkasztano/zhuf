const std = @import("std");

pub const KvCli = struct {
    pub const ParseError = error{
        MissingValue,
        UnknownKey,
        UnknownFlag,
        InvalidInteger,
        InvalidEnum,
        InvalidBoolean,
        MissingRequiredOption,
        OutOfMemory,
    };

    pub fn ParseResult(comptime Opts: type, comptime Flags: type) type {
        return struct {
            opts: Opts,
            flags: Flags,
            positionals: std.ArrayListUnmanaged([*:0]const u8),
        };
    }

    /// Parses command-line arguments. Key-value options are stored in `opts`,
    /// standalone boolean flags in `flags`, and positional arguments in `positionals`.
    pub fn parse(
        comptime Opts: type,
        comptime Flags: type,
        allocator: std.mem.Allocator,
        args: []const []const u8,
    ) ParseError!ParseResult(Opts, Flags) {
        var opts: Opts = undefined;
        var flags: Flags = initDefaults(Flags);

        var positionals: std.ArrayListUnmanaged([*:0]const u8) = .empty;
        errdefer positionals.deinit(allocator);

        const opts_info = @typeInfo(Opts).@"struct";
        var field_set = [_]bool{false} ** opts_info.fields.len;

        const slice = if (args.len > 0) args[1..] else args;

        for (slice) |arg| {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq_index| {
                // handle key=value options
                const key = arg[0..eq_index];
                const val = arg[eq_index + 1 ..];

                var matched = false;

                // Resolve key alias if present
                var resolved_key = key;
                if (@hasDecl(Opts, "aliases")) {
                    inline for (Opts.aliases) |alias| {
                        if (std.mem.eql(u8, key, alias[0])) {
                            resolved_key = alias[1];
                            break;
                        }
                    }
                }

                inline for (opts_info.fields, 0..) |field, i| {
                    if (std.mem.eql(u8, field.name, resolved_key)) {
                        matched = true;
                        field_set[i] = true;
                        @field(opts, field.name) = try parseValue(field.type, allocator, val);
                        break;
                    }
                }

                if (!matched) return ParseError.UnknownKey;
            } else {
                // Try matching flag or alias
                var flag_matched = false;

                if (Flags != void) {
                    // Check alias mappings
                    if (@hasDecl(Flags, "aliases")) {
                        inline for (Flags.aliases) |alias| {
                            if (std.mem.eql(u8, arg, alias[0])) {
                                @field(flags, alias[1]) = true;
                                flag_matched = true;
                                break;
                            }
                        }
                    }

                    // Fall back to direct "--field_name" matching
                    if (!flag_matched and std.mem.startsWith(u8, arg, "--")) {
                        const flag_name = arg[2..];
                        inline for (@typeInfo(Flags).@"struct".fields) |field| {
                            if (std.mem.eql(u8, field.name, flag_name)) {
                                @field(flags, field.name) = true;
                                flag_matched = true;
                                break;
                            }
                        }
                    }
                }

                if (!flag_matched) {
                    if (std.mem.startsWith(u8, arg, "-")) {
                        // Any argument starting with '-' that isn't a recognized flag is an error
                        return ParseError.UnknownFlag;
                    } else {
                        // Unnamed positional argument
                        const z_arg: [:0]const u8 = arg[0..arg.len :0];
                        try positionals.append(allocator, z_arg);
                    }
                }
            }
        }

        // Assign default values or fail on missing required options
        inline for (opts_info.fields, 0..) |field, i| {
            if (!field_set[i]) {
                if (field.default_value_ptr) |ptr| {
                    const default_ptr: *const field.type = @ptrCast(@alignCast(ptr));
                    @field(opts, field.name) = default_ptr.*;
                } else if (@typeInfo(field.type) == .optional) {
                    @field(opts, field.name) = null;
                } else {
                    return ParseError.MissingRequiredOption;
                }
            }
        }

        return .{
            .opts = opts,
            .flags = flags,
            .positionals = positionals,
        };
    }

    fn initDefaults(comptime T: type) T {
        if (T == void) return {};
        var result: T = undefined;
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (field.default_value_ptr) |ptr| {
                const default_ptr: *const field.type = @ptrCast(@alignCast(ptr));
                @field(result, field.name) = default_ptr.*;
            } else if (field.type == bool) {
                @field(result, field.name) = false;
            }
        }
        return result;
    }

    fn parseValue(comptime T: type, allocator: std.mem.Allocator, val: []const u8) ParseError!T {
        const type_info = @typeInfo(T);

        switch (type_info) {
            .optional => |opt| return try parseValue(opt.child, allocator, val),
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) return val;
                @compileError("Unsupported pointer type: " ++ @typeName(T));
            },
            .int => return parseSize(T, val) catch return ParseError.InvalidInteger,
            .bool => {
                if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "yes")) return true;
                if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "no")) return false;
                return ParseError.InvalidBoolean;
            },
            .@"enum" => return std.meta.stringToEnum(T, val) orelse ParseError.InvalidEnum,
            else => @compileError("Unsupported field type: " ++ @typeName(T)),
        }
    }

    fn parseSize(comptime T: type, val: []const u8) !T {
        if (val.len == 0) return error.InvalidInteger;

        var multiplier: u64 = 1;
        var num_str = val;

        const suffix = std.ascii.toLower(val[val.len - 1]);
        switch (suffix) {
            'b' => {
                multiplier = 512;
                num_str = val[0 .. val.len - 1];
            },
            'k' => {
                multiplier = 1024;
                num_str = val[0 .. val.len - 1];
            },
            'm' => {
                multiplier = 1024 * 1024;
                num_str = val[0 .. val.len - 1];
            },
            'g' => {
                multiplier = 1024 * 1024 * 1024;
                num_str = val[0 .. val.len - 1];
            },
            else => {},
        }

        const base = try std.fmt.parseInt(u64, num_str, 10);
        return std.math.cast(T, base * multiplier) orelse error.InvalidInteger;
    }
};
