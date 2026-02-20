const std = @import("std");
const util = @import("../root.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Returns $XDG_DATA_HOME if set, otherwise falls back to $HOME/.local/share.
fn xdgDataHome(allocator: Allocator) ![]const u8 {
    if (try util.env.getOptional(allocator, "XDG_DATA_HOME")) |xdg_path| {
        return xdg_path;
    }
    var home_sa = util.StackFilepathAllocator.empty;
    const home_dirpath = try home(home_sa.allocatorInvalidatePrevious());
    return std.fs.path.join(allocator, &.{
        home_dirpath,
        ".local/share",
    });
}

pub fn home(allocator: Allocator) ![]const u8 {
    return util.env.get(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => @panic("env $HOME needs to exist"),
        else => return err,
    };
}

pub fn trash(allocator: Allocator) ![]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            var data_home_sa = util.StackFilepathAllocator.empty;
            const data_home = try xdgDataHome(data_home_sa.allocatorInvalidatePrevious());
            return std.fs.path.join(allocator, &.{
                data_home,
                "Trash/files",
            });
        },
        .macos => {
            var home_dirpath_sa = util.StackFilepathAllocator.empty;
            const home_dirpath = try home(home_dirpath_sa.allocatorInvalidatePrevious());
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
    var data_home_sa = util.StackFilepathAllocator.empty;
    const data_home = try xdgDataHome(data_home_sa.allocatorInvalidatePrevious());
    return std.fs.path.join(allocator, &.{
        data_home,
        "Trash/info",
    });
}

/// if the original_path is not absolute it joins the original_path with CWD
/// WARN: dont try to free the slice returned by this function directly, instead you should
/// pass an (arena or stack) allocator!
pub fn cwdAbsoluteFilepath(arena: Allocator, original_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(original_path)) {
        return original_path;
    } else {
        var cwd_path_sa = util.StackFilepathAllocator.empty;
        const cwd_path = try std.fs.cwd().realpathAlloc(cwd_path_sa.allocatorInvalidatePrevious(), ".");
        return try std.fs.path.resolve(arena, &.{ cwd_path, original_path });
    }
}
