const std = @import("std");
const util = @import("../root.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub fn home(allocator: Allocator) []const u8 {
    return (util.env.get(allocator, "HOME") catch {
        @panic("env $HOME needs to exist");
    });
}

pub fn trash(allocator: Allocator) ![]const u8 {
    var home_dirpath_sa = util.StackFilepathAllocator.empty;
    const home_dirpath = home(home_dirpath_sa.allocatorInvalidatePrevious());
    switch (builtin.os.tag) {
        .linux => {
            return std.fs.path.join(allocator, &.{
                home_dirpath,
                ".local/share/Trash/files",
            });
        },
        .macos => {
            return std.fs.path.join(allocator, &.{
                home_dirpath,
                ".Trash",
            });
        },
        else => @compileError("os not supported"),
    }
}

pub fn trashInfo(allocator: Allocator) ![]const u8 {
    if (builtin.os.tag != .linux) {
        @compileError("sorry trash info is only for linux");
    }
    var home_dirpath_sa = util.StackFilepathAllocator.empty;
    const home_dirpath = home(home_dirpath_sa.allocatorInvalidatePrevious());
    return std.fs.path.join(allocator, &.{
        home_dirpath,
        ".local/share/Trash/info",
    });
}

/// if the origional_path is not absolute it joins the original_path with CWD
/// WARN: dont try to free the slice returned by this function directly, instead you should
/// pass an (arena or stack) allocator!
pub fn cwdAbosoluteFilepath(arena: Allocator, original_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(original_path)) {
        return original_path;
    } else {
        var cwd_path_sa = util.StackFilepathAllocator.empty;
        const cwd_path = try std.fs.cwd().realpathAlloc(cwd_path_sa.allocatorInvalidatePrevious(), ".");
        return try std.fs.path.resolve(arena, &.{ cwd_path, original_path });
    }
}
