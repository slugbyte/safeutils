const std = @import("std");
const Allocator = std.mem.Allocator;
const ArgIterator = @import("ArgIterator.zig");

pub const Error = error{Unknown} || ArgIterator.Error;
pub const FlagParser = @This();

/// return true if arg is a flag
parseFn: *const fn (*FlagParser, [:0]const u8, *ArgIterator) Error!ArgType,
/// return true if ArgIterator is now owned by caller
setArgIteratorFn: *const fn (*FlagParser, ArgIterator) bool,
/// return true if positional_list is now owned by caller
setPositionalListFn: *const fn (*FlagParser, [][:0]const u8) bool,
/// return true if program_path is now owned by caller
setProgramPathFn: *const fn (*FlagParser, [:0]const u8) bool,

pub const ArgType = enum {
    Positional,
    NotPositional,
};

pub fn parse(flag_parser: *FlagParser, allocator: Allocator, args: []const [:0]u8) !void {
    var iter = ArgIterator.init(args);
    defer {
        iter.reset();
        if (!flag_parser.setArgIteratorFn(flag_parser, iter)) {
            iter.deinit(allocator);
        }
    }

    const program_path = try allocator.dupeZ(u8, iter.next().?);
    errdefer allocator.free(program_path);
    if (!flag_parser.setProgramPathFn(flag_parser, program_path)) {
        allocator.free(program_path);
    }

    var positional_list = std.ArrayList([:0]const u8).empty;
    errdefer positional_list.deinit(allocator);
    while (iter.next()) |arg| {
        if (try flag_parser.parseFn(flag_parser, arg, &iter) == .Positional) {
            try positional_list.append(allocator, try allocator.dupeZ(u8, arg));
        }
    }

    const positional_list_owned = try positional_list.toOwnedSlice(allocator);
    if (!flag_parser.setPositionalListFn(flag_parser, positional_list_owned)) {
        allocator.free(positional_list_owned);
    }
}

pub fn parseProcessArgs(flag_parser: *FlagParser, allocator: Allocator) !void {
    try parse(flag_parser, allocator, try std.process.argsAlloc(allocator));
}

pub fn noopSetProgramPath(_: *FlagParser, _: [:0]const u8) bool {
    return false;
}
pub fn noopSetPositionalList(_: *FlagParser, _: [][:0]const u8) bool {
    return false;
}
pub fn noopSetArgIterator(_: *FlagParser, _: ArgIterator) bool {
    return false;
}

pub fn autoSetArgIterator(T: type, comptime interface_field: []const u8, comptime value_field: []const u8) *const fn (*FlagParser, ArgIterator) bool {
    const Temp = struct {
        pub fn implSetArgIterator(flag_parser: *FlagParser, iter: ArgIterator) bool {
            var self = @as(*T, @fieldParentPtr(interface_field, flag_parser));
            @field(self, value_field) = iter;
            return true;
        }
    };
    return Temp.implSetArgIterator;
}

pub fn autoSetPositionalList(T: type, comptime interface_field: []const u8, comptime value_field: []const u8) *const fn (*FlagParser, [][:0]const u8) bool {
    const Temp = struct {
        pub fn implSetArgIterator(flag_parser: *FlagParser, positional_list: [][:0]const u8) bool {
            var self = @as(*T, @fieldParentPtr(interface_field, flag_parser));
            @field(self, value_field) = positional_list;
            return true;
        }
    };
    return Temp.implSetArgIterator;
}

pub fn autoSetProgramPath(T: type, comptime interface_field: []const u8, comptime value_field: []const u8) *const fn (*FlagParser, [:0]const u8) bool {
    const Temp = struct {
        pub fn implSetArgIterator(flag_parser: *FlagParser, program_path: [:0]const u8) bool {
            var self = @as(*T, @fieldParentPtr(interface_field, flag_parser));
            @field(self, value_field) = program_path;
            return true;
        }
    };
    return Temp.implSetArgIterator;
}
