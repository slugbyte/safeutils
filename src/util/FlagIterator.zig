const std = @import("std");

/// iterates over each of the flags within a single arg
/// if its a long flag `--flag` it will just parse the whole arg as an enum
/// if its a short flag `-SiCk` it will parse each char as an enum
pub fn FlagIterator(FlagEnum: type) type {
    if (@typeInfo(FlagEnum) != .@"enum") {
        @compileError("FlagIterator expects an enum");
    }
    return struct {
        arg: []const u8,
        is_long: bool,
        index: usize = 0,

        const empty: @This() = .{ .arg = "", .is_long = false };

        const NextResult = union(enum) {
            /// the long or short arg cast as the enum
            Flag: FlagEnum,
            /// the arg started with `--` but could not be cast as the enum
            UnknownLong: []const u8,
            /// the arg started with `-` but the char could not be cast as the enmu
            UnknownShort: u8,
        };

        pub fn init(arg: []const u8) @This() {
            if (std.mem.startsWith(u8, arg, "--") and arg.len > 2) return .{
                .arg = arg,
                .is_long = true,
            };
            if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) return .{
                .arg = arg[1..],
                .is_long = false,
            };
            return @This().empty;
        }

        pub inline fn isFlag(self: @This()) bool {
            return self.index != 0;
        }

        pub fn next(self: *@This()) ?NextResult {
            if (self.arg.len == 0) return null;

            if (self.is_long) {
                if (self.index != 0) return null;
                self.index += 1;
                if (std.meta.stringToEnum(FlagEnum, self.arg)) |value| {
                    return NextResult{ .Flag = value };
                }
                return NextResult{ .UnknownLong = self.arg };
            }

            if (self.index < self.arg.len) {
                defer self.index += 1;
                if (std.meta.stringToEnum(FlagEnum, self.arg[self.index..][0..1])) |value| {
                    return NextResult{ .Flag = value };
                }
                return NextResult{ .UnknownShort = self.arg[self.index] };
            }
            return null;
        }
    };
}
