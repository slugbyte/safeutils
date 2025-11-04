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

    try writer.interface.print(README_CONTENT, .{ move_help_msg, trash_help_msg });
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
    \\### trash clobber strategy
    \\* move files to trash but rename them so they dont confict
    \\* if on `linux` it also adds a `.trashinfo` file so that you can undo using a file browser
    \\* files become `$trash/(basename)__(url_safe_base64_hash).trash`
    \\* dirs and links become `$trash/(basename)__(timestamp).trash` or `$trash/(basename)__(timestap)_(random).trash` if there is a conflict.
    \\
    \\### backup clobber strategy
    \\* rename file `(original_path).backup~`
    \\* if a backup allready exists it will be moved to trash
    \\
    \\## move (mv replacement)
    \\```
    \\{s}
    \\```
    \\
    \\## trash (rm replacement)
    \\trash can revert and fetch files using fzf with a custom preview that shows `revert_path`, `stat_kind`, `file_size` and `content`.
    \\if you have [viu](https://github.com/atanunq/viu) installed you can also pass a `--viu` flag so that you can see image previews (in block form).
    \\```
    \\{s}
    \\```
;
