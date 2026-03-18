const std = @import("std");
const builtin = @import("builtin");
const util = @import("../root.zig");

const Allocator = std.mem.Allocator;

pub const ENV_TRASH_DIR = "SAFEUTILS_TRASH_DIR";
pub const ENV_TRASH_INFO_DIR = "SAFEUTILS_TRASH_INFO_DIR";

pub const ResolveOptions = struct {
    cli_trash_dir: ?[]const u8 = null,
    cli_trash_info_dir: ?[]const u8 = null,
};

pub const TrashPaths = struct {
    files_dir: []const u8,
    info_dir: ?[]const u8,
};

pub fn resolve(allocator: Allocator, options: ResolveOptions) !TrashPaths {
    const env_trash_dir = try util.env.getOptional(allocator, ENV_TRASH_DIR);
    const env_trash_info_dir = try util.env.getOptional(allocator, ENV_TRASH_INFO_DIR);

    const files_dir = if (options.cli_trash_dir) |path|
        path
    else if (env_trash_dir) |path|
        path
    else
        try util.dirpath.trash(allocator);

    const info_dir = switch (builtin.os.tag) {
        .linux => blk: {
            if (options.cli_trash_info_dir) |path| {
                break :blk path;
            }
            if (env_trash_info_dir) |path| {
                break :blk path;
            }
            if (options.cli_trash_dir != null or env_trash_dir != null) {
                break :blk try deriveInfoDirFromFilesDir(allocator, files_dir);
            }
            break :blk try util.dirpath.trashInfo(allocator);
        },
        else => blk: {
            if (options.cli_trash_info_dir != null or env_trash_info_dir != null) {
                return error.TrashInfoDirUnsupportedOnThisOs;
            }
            break :blk null;
        },
    };

    return .{
        .files_dir = files_dir,
        .info_dir = info_dir,
    };
}

fn deriveInfoDirFromFilesDir(allocator: Allocator, files_dir: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(files_dir) orelse return error.InvalidTrashFilesDir;
    return std.fs.path.join(allocator, &.{ parent, "info" });
}
