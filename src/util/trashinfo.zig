const std = @import("std");
const util = @import("../root.zig");
const Allocator = std.mem.Allocator;

pub fn filepath(allocator: Allocator, filename: []const u8) ![]const u8 {
    var trash_dirpath_sa = util.StackFilepathAllocator.empty;
    const trash_dirpath = try util.dirpath.trashInfo(trash_dirpath_sa.allocatorInvalidatePrevious());

    var trashinfo_name_sa = util.StackFilenameAllocator.empty;
    const trashinfo_name = try util.fmt(
        trashinfo_name_sa.allocatorInvalidatePrevious(),
        "{s}.trashinfo",
        .{filename},
    );

    return std.fs.path.join(allocator, &.{
        trash_dirpath,
        trashinfo_name,
    });
}

// TODO: add date
/// ensurse the original_path is an abosolute path and write trashinfo content to the writer
pub fn writeContent(w: *std.Io.Writer, original_path: []const u8) !void {
    var abosole_path_sa = util.StackFilepathAllocator.empty;
    const revert_path = try util.dirpath.cwdAbosoluteFilepath(
        abosole_path_sa.allocatorInvalidatePrevious(),
        original_path,
    );
    try w.print(
        \\[Trash Info]
        \\Path={s}
    , .{revert_path});
    try w.flush();
}
