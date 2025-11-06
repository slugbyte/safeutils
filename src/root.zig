//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const env = @import("./util/env.zig");
pub const dirpath = @import("./util/dirpath.zig");
pub const term = @import("./util/term.zig");
pub const exec = @import("./util/exec.zig");
pub const trashinfo = @import("./util/trashinfo.zig");

pub const ArgIterator = @import("./util/ArgIterator.zig");
pub const FlagIterator = @import("./util/FlagIterator.zig").FlagIterator;
pub const FlagParser = @import("./util/FlagParser.zig");
pub const Reporter = @import("./util/Reporter.zig");
pub const WorkDir = @import("./util/WorkDir.zig");
pub const NullByteDetectorWriter = @import("./util/NullByteDetectorWriter.zig");
pub const StackAllocator = @import("./util/StackAllocator.zig").StackAllocator;
pub const StackFilenameAllocator = @import("./util/StackAllocator.zig").StackFilenameAllocator;
pub const StackFilepathAllocator = @import("./util/StackAllocator.zig").StackFilepathAllocator;
pub const FilenameBumper = @import("./util/FilenameBumper.zig");
pub const FilepathBuffer = [std.fs.max_path_bytes]u8;
pub const FilenameBuffer = [std.fs.max_path_bytes]u8;

pub const Allocator = std.mem.Allocator;
pub const assert = std.debug.assert;

pub fn log(comptime format: []const u8, arg: anytype) void {
    var buffer: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buffer, format, arg) catch return;
    std.debug.print("{s}\n", .{msg});
}

pub fn isString(T: type) bool {
    switch (T) {
        []u8,
        []const u8,
        [:0]u8,
        [:0]const u8,
        => return true,
        else => switch (@typeInfo(T)) {
            .array => |a| return a.child == u8,
            .pointer => |t| return isString(t.child),
            .optional => |t| isString(t.child),
            else => return false,
        },
    }
}

pub const fmt = std.fmt.allocPrint;
pub fn fmtZ(allocator: Allocator, comptime format: []const u8, arg: anytype) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, format, arg, 0);
}
pub const fmtBuf = std.fmt.bufPrint;
pub const fmtBufZ = std.fmt.bufPrintZ;
pub fn fmtBufTrunc(buffer: []u8, comptime format: []const u8, arg: anytype) []u8 {
    var w: std.Io.Writer = .fixed(buffer);
    w.print(format, arg) catch |err| switch (err) {
        error.WriteFailed => return w.buffered(),
    };
    return w.buffered();
}

// trim all whitespace
pub inline fn trim(str: []const u8) []const u8 {
    return std.mem.trim(u8, str, "\n\t ");
}

pub inline fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub inline fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub inline fn eqlAny(value: []const u8, needles: [][]const u8) bool {
    for (needles) |needle| {
        if (eql(value, needle)) {
            return true;
        }
    }
    return false;
}

pub inline fn eqlAnyIgnoreCase(value: []const u8, needles: [][]const u8) bool {
    for (needles) |needle| {
        if (eqlIgnoreCase(value, needle)) {
            return true;
        }
    }
    return false;
}

pub inline fn eqlFlag(value: []const u8, a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, value, a) or std.mem.eql(u8, value, b);
}

pub inline fn startsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

pub inline fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(haystack, needle);
}

pub inline fn endsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.endsWith(u8, haystack, needle);
}

pub inline fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(haystack, needle);
}

pub inline fn endsWithAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (endsWith(haystack, needle)) {
            return true;
        }
    }
    return false;
}

pub inline fn endsWithAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (endsWithIgnoreCase(haystack, needle)) {
            return true;
        }
    }
    return false;
}

pub fn debug(src: std.builtin.SourceLocation, comptime format: []const u8, args: anytype) void {
    std.debug.print("DEBUG ({d}:{s} {s}) ", .{ src.line, src.file, src.fn_name });
    std.debug.print(format, args);
    std.debug.print("\n", .{});
}

/// prints "{header}: 'item0' 'item1' ...\n"
pub fn debugPrintArgIterator(arg_iterator: *ArgIterator, header: []const u8, skip_exe: bool) void {
    arg_iterator.reset();
    if (skip_exe) {
        _ = arg_iterator.skip();
    }
    std.debug.print("{s}: ", .{header});
    while (arg_iterator.next()) |arg| {
        std.debug.print("'{s}' ", .{arg});
    }
    std.debug.print("\n", .{});
}

/// prints "{header}: 'item0' 'item1' ...\n"
pub fn debugPrintPositionalList(positional_list: [][:0]const u8, header: []const u8) void {
    std.debug.print("{s}: ", .{header});
    for (positional_list) |arg| {
        std.debug.print("'{s}' ", .{arg});
    }
    std.debug.print("\n", .{});
}

/// prints all the fields in a struct that begin with `flag_`
pub fn debugPrintFlagFields(comptime T: type, value: T) void {
    const info = @typeInfo(T);
    inline for (info.@"struct".fields) |field| {
        if (std.mem.startsWith(u8, field.name, "flag_") and std.mem.indexOf(u8, field.name, "parser") == null) {
            std.debug.print("{s: <30}: {any}\n", .{ field.name, @field(value, field.name) });
        }
    }
}
