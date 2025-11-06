const std = @import("std");
step: std.Build.Step,

pub fn init(b: *std.Build) *@This() {
    const result = b.allocator.create(@This()) catch @panic("OOM");
    result.step = .init(.{
        .id = .custom,
        .name = "update readme",
        .makeFn = make,
        .owner = b,
    });
    return result;
}

pub fn make(b: *std.Build.Step, opt: std.Build.Step.MakeOptions) !void {
    _ = opt;
    const root_dir_path = b.owner.build_root.path.?;

    var root_dir = try std.fs.openDirAbsolute(root_dir_path, .{});
    defer root_dir.close();

    var readme_file = try root_dir.createFile("README.md", .{});
    defer readme_file.close();

    var write_buffer: [1024]u8 = undefined;
    var writer = readme_file.writer(&write_buffer);

    const move_help_msg = @import("../exec/move.zig").help_msg;
    const trash_help_msg = @import("../exec/trash.zig").help_msg;

    try writer.interface.print(README_CONTENT, .{ trash_help_msg, move_help_msg });
    try writer.interface.flush();
}

const README_CONTENT =
    \\# safeutils
    \\> coreutil replacements that aim to protect me from overwriting work.
    \\
    \\## about
    \\I lost work one too many times, by accidently overwriting data with coreutils. I made these utils to
    \\reduce the chances that would happen again. They provide much less dangerous clobber strats.
    \\ 
    \\### clobber strats
    \\* `trash` - move files to trash but rename them so they dont confict `_00.ext, _01.ext, _02.ext ..`
    \\* `backup` -  move original file to `(original_path).backup~`
    \\   * if a backup allready exists it will be moved to trash
    \\
    \\## trash (rm replacement)
    \\'--revert-fzf' and '--fetch-fzf' have a custom [fzf](https://github.com/junegunn/fzf) preview for displaying:
    \\* A header with the original path, file type, and file size.
    \\* File content: text is printed, non-text prints `binary data` except images can optionaly be displayed with [viu](https://github.com/atanunq/viu)
    \\```
    \\{s}
    \\```
    \\
    \\## move (mv replacement)
    \\```
    \\{s}
    \\```
;
