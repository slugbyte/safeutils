const std = @import("std");
const t = std.testing;

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

const TestFlags = enum {
    @"--help",
    h,
    @"--verbose",
    v,
    @"--silent",
    s,
};

test "TEST: long flag parsed correctly" {
    var iter = FlagIterator(TestFlags).init("--help");
    const result = iter.next().?;
    try t.expectEqual(TestFlags.@"--help", result.Flag);
    try t.expect(iter.isFlag());
    try t.expect(iter.next() == null);
}

test "TEST: unknown long flag" {
    var iter = FlagIterator(TestFlags).init("--bogus");
    const result = iter.next().?;
    try t.expectEqualStrings("--bogus", result.UnknownLong);
    try t.expect(iter.isFlag());
}

test "TEST: short flags iterated individually" {
    var iter = FlagIterator(TestFlags).init("-hvs");
    const r1 = iter.next().?;
    try t.expectEqual(TestFlags.h, r1.Flag);
    const r2 = iter.next().?;
    try t.expectEqual(TestFlags.v, r2.Flag);
    const r3 = iter.next().?;
    try t.expectEqual(TestFlags.s, r3.Flag);
    try t.expect(iter.next() == null);
    try t.expect(iter.isFlag());
}

test "TEST: unknown short flag" {
    var iter = FlagIterator(TestFlags).init("-x");
    const result = iter.next().?;
    try t.expectEqual(@as(u8, 'x'), result.UnknownShort);
}

test "TEST: non-flag arg returns null immediately" {
    var iter = FlagIterator(TestFlags).init("positional");
    try t.expect(iter.next() == null);
    try t.expect(!iter.isFlag());
}

test "TEST: single dash returns null" {
    var iter = FlagIterator(TestFlags).init("-");
    try t.expect(iter.next() == null);
    try t.expect(!iter.isFlag());
}
