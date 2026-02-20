const std = @import("std");
const t = std.testing;
const util = @import("../root.zig");
const Allocator = std.mem.Allocator;

/// accumulates error and warning messages
const Reporter = @This();

allocator: Allocator,
warn_list: std.ArrayList([]const u8),
error_list: std.ArrayList([]const u8),

pub fn init(allocator: Allocator) Reporter {
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

pub fn PANIC_WITH_REPORT(self: Reporter, comptime format: []const u8, args: anytype) noreturn {
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

pub inline fn getAllWarning(self: Reporter) [][]const u8 {
    return self.warn_list.items;
}

pub inline fn getAllError(self: Reporter) [][]const u8 {
    return self.error_list.items;
}

pub inline fn pushWarning(self: *Reporter, comptime format: []const u8, args: anytype) Allocator.Error!void {
    try self.warn_list.append(self.allocator, try util.fmt(self.allocator, format, args));
}

pub inline fn pushError(self: *Reporter, comptime format: []const u8, args: anytype) Allocator.Error!void {
    try self.error_list.append(self.allocator, try util.fmt(self.allocator, format, args));
}

test "TEST: init starts with no errors or warnings" {
    var reporter = init(t.allocator);
    defer reporter.deinit();
    try t.expect(!reporter.isError());
    try t.expect(!reporter.isWarning());
}

test "TEST: pushError sets isError" {
    var reporter = init(t.allocator);
    defer reporter.deinit();
    try reporter.pushError("test error {s}", .{"msg"});
    try t.expect(reporter.isError());
    try t.expect(!reporter.isWarning());
    try t.expectEqual(@as(usize, 1), reporter.getAllError().len);
    try t.expectEqualStrings("test error msg", reporter.getAllError()[0]);
}

test "TEST: pushWarning sets isWarning" {
    var reporter = init(t.allocator);
    defer reporter.deinit();
    try reporter.pushWarning("warn {d}", .{42});
    try t.expect(!reporter.isError());
    try t.expect(reporter.isWarning());
    try t.expectEqual(@as(usize, 1), reporter.getAllWarning().len);
    try t.expectEqualStrings("warn 42", reporter.getAllWarning()[0]);
}

test "TEST: multiple errors accumulate" {
    var reporter = init(t.allocator);
    defer reporter.deinit();
    try reporter.pushError("e1", .{});
    try reporter.pushError("e2", .{});
    try reporter.pushWarning("w1", .{});
    try t.expectEqual(@as(usize, 2), reporter.getAllError().len);
    try t.expectEqual(@as(usize, 1), reporter.getAllWarning().len);
}
