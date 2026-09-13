const std = @import("std");

pub const KvCli = struct {
    pub const ParseError = error{
        MissingValue,
        UnknownKey,
        InvalidInteger,
        InvalidEnum,
        InvalidBoolean,
        MissingRequiredOption,
    };

    /// Parses command-line arguments formatted as `key=value` into a target struct `T`.
    pub fn parseStruct(comptime T: type, allocator: std.mem.Allocator, args: []const []const u8) ParseError!T {
        var result: T = undefined;
        const struct_info = @typeInfo(T).@"struct";
        var field_set = [_]bool{false} ** struct_info.fields.len;

        // skip binary name (args[0])
        const slice = if (args.len > 0) args[1..] else args;

        for (slice) |arg| {
            // split at the first '=' to allow values to contain '=' if needed
            const eq_index = std.mem.indexOfScalar(u8, arg, '=') orelse return ParseError.MissingValue;
            const key = arg[0..eq_index];
            const val = arg[eq_index + 1 ..];

            var matched = false;
            inline for (struct_info.fields, 0..) |field, i| {
                if (std.mem.eql(u8, field.name, key)) {
                    matched = true;
                    field_set[i] = true;
                    @field(result, field.name) = try parseValue(field.type, allocator, val);
                    break;
                }
            }

            if (!matched) {
                return ParseError.UnknownKey;
            }
        }

        // assign default values or fail on missing non-optional fields
        inline for (struct_info.fields, 0..) |field, i| {
            if (!field_set[i]) {
                if (field.default_value_ptr) |ptr| {
                    const default_ptr: *const field.type = @ptrCast(@alignCast(ptr));
                    @field(result, field.name) = default_ptr.*;
                } else if (@typeInfo(field.type) == .optional) {
                    @field(result, field.name) = null;
                } else {
                    return ParseError.MissingRequiredOption;
                }
            }
        }

        return result;
    }

    fn parseValue(comptime T: type, allocator: std.mem.Allocator, val: []const u8) ParseError!T {
        const type_info = @typeInfo(T);

        switch (type_info) {
            .optional => |opt| {
                return try parseValue(opt.child, allocator, val);
            },
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    return val;
                }
                @compileError("Unsupported pointer type: " ++ @typeName(T));
            },
            .int => {
                return parseSize(T, val) catch return ParseError.InvalidInteger;
            },
            .bool => {
                if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "yes")) return true;
                if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "no")) return false;
                return ParseError.InvalidBoolean;
            },
            .@"enum" => {
                return std.meta.stringToEnum(T, val) orelse ParseError.InvalidEnum;
            },
            else => @compileError("Unsupported field type: " ++ @typeName(T)),
        }
    }

    /// Converts integer byte quantities with `dd` unit suffixes (b=512, k=1024, M, G).
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
