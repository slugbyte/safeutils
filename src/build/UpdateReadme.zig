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
    const copy_help_msg = @import("../exec/copy.zig").help_msg;

    try writer.interface.print(README_CONTENT, .{ trash_help_msg, copy_help_msg, move_help_msg });
    try writer.interface.flush();
}

const README_CONTENT =
    \\# safeutils
    \\> coreutil replacements that aim to protect me from overwriting work.
    \\
    \\## About
    \\I lost work by accident one to many times, so I decided to make some safe replacements and added
    \\a few nice modern features for fun.
    \\
    \\## Features
    \\* Verbose by default
    \\* Safe clobber strategys
    \\  * `trash` - move files to trash but rename conflicts `(name)_00.(ext) (name)_01.(ext)...`
    \\  * `backup` -  rename original file to `(original).backup~` and trash any previous backups.
    \\* `trash` can use [fzf](https://github.com/junegunn/fzf) to revert and fetch trashed files, and provieds a nice trash previewer.
    \\
    \\## trash (rm replacement)
    \\`--revert-fzf` and `--fetch-fzf` have a custom [fzf](https://github.com/junegunn/fzf) preview with...
    \\* A header section with the `original path`, `file type`, and `file size`.
    \\* A content section where text is printed, non-text prints `binary data` except images can optionaly be displayed with [viu](https://github.com/atanunq/viu)
    \\```
    \\{s}
    \\```
    \\
    \\## copy (cp replacement)
    \\```
    \\{s}
    \\```
    \\
    \\## move (mv replacement)
    \\```
    \\{s}
    \\```
;
