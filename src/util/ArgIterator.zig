const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ArgIterator = @This();

pub const Error = error{
    MissingValue,
    ParseFailed,
} || Allocator.Error;

// inner: std.process.ArgIterator,
args: []const [:0]u8,
index: usize,

pub fn init(args: []const [:0]u8) ArgIterator {
    return .{
        .args = args,
        .index = 0,
    };
}

pub fn initProcessArgs(allocator: Allocator) !ArgIterator {
    return .{
        .args = try std.process.argsAlloc(allocator),
        .index = 0,
    };
}

pub fn deinit(self: *ArgIterator, allocator: Allocator) void {
    std.process.argsFree(allocator, self.args);
    self.* = undefined;
}

pub inline fn reset(self: *ArgIterator) void {
    self.index = 0;
}

pub inline fn remaining(self: ArgIterator) usize {
    return self.args.len - self.index;
}

pub inline fn peek(self: ArgIterator) ?[:0]const u8 {
    if (self.index < self.args.len) {
        return self.args[self.index];
    }
    return null;
}

pub inline fn skip(self: *ArgIterator) ?[:0]const u8 {
    if (self.index < self.args.len) {
        self.index += 1;
    }
    return null;
}

pub inline fn next(self: *ArgIterator) ?[:0]const u8 {
    if (self.index < self.args.len) {
        defer self.index += 1;
        return self.args[self.index];
    }
    return null;
}

pub inline fn nextOrFail(self: *ArgIterator) ![:0]const u8 {
    return self.next() orelse Error.MissingValue;
}

pub inline fn nextInt(self: *ArgIterator, T: type, base: u8) !T {
    const arg = try self.nextOrFail();
    return std.fmt.parseInt(T, arg, base) catch return Error.ParseFailed;
}

pub inline fn nextFloat(self: *ArgIterator, T: type) !T {
    const arg = try self.nextOrFail();
    return std.fmt.parseFloat(T, arg) catch Error.ParseFailed;
}

pub inline fn nextEnum(self: *ArgIterator, T: type) !T {
    const arg = try self.nextOrFail();
    return std.meta.stringToEnum(T, arg) orelse return Error.ParseFailed;
}
