const std = @import("std");
const util = @import("../root.zig");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const WorkDir = util.WorkDir;

/// Per-item clobber metadata captured during a clobber operation. Empty
/// strings mean no clobber occurred for that field.
pub const ClobberInfo = struct {
    clobber_trash_path: []const u8 = "",
    clobber_trashinfo_path: []const u8 = "",
    clobber_backup_path: []const u8 = "",
    clobber_backup_trash_path: []const u8 = "",
    clobber_backup_trashinfo_path: []const u8 = "",

    pub fn hasClobber(self: ClobberInfo) bool {
        return self.clobber_trash_path.len > 0 or self.clobber_backup_path.len > 0;
    }
};

/// Compute the trashinfo path for a trash file using default trash path resolution.
pub fn trashinfoPathFor(allocator: Allocator, cwd: WorkDir, trash_path: []const u8) ![]const u8 {
    if (builtin.os.tag != .linux) return "";
    const trash_paths = try util.trash_paths.resolve(allocator, .{});
    const info_dir = trash_paths.info_dir orelse return "";
    const info_path = try util.trashinfo.filepathAt(allocator, info_dir, std.fs.path.basename(trash_path));
    return try cwd.realpathZ(allocator, info_path);
}

/// Check that every non-empty clobber path still exists on the filesystem.
/// Returns the first missing path, or null if all are present.
pub fn preflight(cwd: WorkDir, info: ClobberInfo) !?[]const u8 {
    const paths = [_][]const u8{
        info.clobber_trash_path,
        info.clobber_backup_path,
        info.clobber_backup_trash_path,
    };
    for (paths) |p| {
        if (p.len > 0) {
            if (try cwd.statNoFollow(p) == null) return p;
        }
    }
    return null;
}

/// Reverse a clobber operation, restoring the original item at dest_path.
///
/// Trash clobber: move clobber_trash_path back to dest_path, delete trashinfo.
/// Backup clobber: move clobber_backup_path back to dest_path, then restore
/// the backup chain (backup-trash → backup) if recorded.
pub fn execute(cwd: WorkDir, dest_path: []const u8, info: ClobberInfo) !void {
    if (info.clobber_trash_path.len > 0) {
        try cwd.move(info.clobber_trash_path, dest_path);
        if (builtin.os.tag == .linux and info.clobber_trashinfo_path.len > 0) {
            cwd.dir.deleteFile(info.clobber_trashinfo_path) catch {};
        }
    } else if (info.clobber_backup_path.len > 0) {
        try cwd.move(info.clobber_backup_path, dest_path);
        if (info.clobber_backup_trash_path.len > 0) {
            try cwd.move(info.clobber_backup_trash_path, info.clobber_backup_path);
            if (builtin.os.tag == .linux and info.clobber_backup_trashinfo_path.len > 0) {
                cwd.dir.deleteFile(info.clobber_backup_trashinfo_path) catch {};
            }
        }
    }
}
