const std = @import("std");
const util = @import("./root.zig");

// TODO: rename Reporter
// TODO: track success/failure/warning count

const Reporter = @This();
// accumulate warnings so that they can be reported at the end
allocator: std.mem.Allocator,
warn_list: std.ArrayList([]const u8),
error_list: std.ArrayList([]const u8),

pub fn init(allocator: std.mem.Allocator) Reporter {
    return .{
        .allocator = allocator,
        .warn_list = .empty,
        .error_list = .empty,
    };
}

pub fn deinit(self: *Reporter) void {
    for (self.getAllWarning()) |item| {
        self.allocator.free(item);
    }
    self.warn_list.deinit(self.allocator);
    for (self.getAllError()) |item| {
        self.allocator.free(item);
    }
    self.error_list.deinit(self.allocator);
    self.* = undefined;
}

pub fn PANIC(self: Reporter, comptime format: []const u8, args: anytype) noreturn {
    self.report();
    std.debug.panic(format, args);
}

pub fn EXIT_WITH_REPORT(self: Reporter, status: u8) noreturn {
    self.report();
    std.process.exit(status);
}

pub inline fn report(self: Reporter) void {
    for (self.getAllWarning()) |warning| {
        util.log("WARNING! {s}", .{warning});
    }
    for (self.getAllError()) |warning| {
        util.log("ERROR! {s}", .{warning});
    }
}

pub inline fn isError(self: Reporter) bool {
    return self.error_list.items.len != 0;
}

pub inline fn isWarning(self: Reporter) bool {
    return self.warn_list.items.len != 0;
}

pub inline fn isTrouble(self: Reporter) bool {
    return self.isError() or self.isWarning();
}

pub inline fn getAllWarning(self: Reporter) [][]const u8 {
    return self.warn_list.items;
}

pub inline fn getAllError(self: Reporter) [][]const u8 {
    return self.error_list.items;
}

pub inline fn pushWarning(self: *Reporter, comptime format: []const u8, args: anytype) !void {
    try self.warn_list.append(self.allocator, try std.fmt.allocPrint(self.allocator, format, args));
}

pub inline fn pushError(self: *Reporter, comptime format: []const u8, args: anytype) !void {
    try self.error_list.append(self.allocator, try std.fmt.allocPrint(self.allocator, format, args));
}
