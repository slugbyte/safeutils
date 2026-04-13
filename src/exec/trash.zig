const std = @import("std");
const util = @import("util");
const builtin = @import("builtin");
const build_option = @import("build_option");

const Allocator = std.mem.Allocator;
const WorkDir = util.WorkDir;
const Reporter = util.Reporter;
const FlagParser = util.FlagParser;
const NullByteDetectorWriter = util.NullByteDetectorWriter;
const TrashPaths = util.trash_paths.TrashPaths;

pub const help_msg =
    \\USAGE: trash files.. (--flags)
    \\  Move files to the trash.
    \\  Revert trash fetch back to where they came from.
    \\  Fetch trash files to current dir.
    \\
    \\  Undo:
    \\    -u --undo                 Undo the most recent trash operation.
    \\
    \\  Revert and Fetch: (linux-only)
    \\    -r --revert trashfile     Revert a trash file to its original location.
    \\    -f --fetch  trashfile     Fetch a trash file to the current directory.
    \\                              Fetch and Revert also manage .trashinfo files.
    \\
    \\    FZF:
    \\    -R --revert-fzf           Use fzf to revert a trash file.
    \\    -F --fetch-fzf            Use fzf to fetch a trash file to the current dir.
    \\
    \\    FZF Preview Options: (Combine with --revert-fzf or --fetch-fzf)
    \\    --viu                  Add support for viu block image display in fzf preview.
    \\    --viu-width            Overwrite the width viu images are displayed at.
    \\    --fzf-preview-window   Overwrite the --preview-window fzf flag. (see fzf --help)
    \\
    \\  Other Flags:
    \\  --trash-dir             Override trash files dir. env: SAFEUTILS_TRASH_DIR
    \\  --trash-info-dir        Override trash info dir. env: SAFEUTILS_TRASH_INFO_DIR
    \\  -s --silent               Only print errors.
    \\  -v --version              Print version.
    \\  -h --help                 Display this help.
    \\
    \\  OPTIONAL DEPS:
    \\  fzf: https://github.com/junegunn/fzf (fuzzy find)
    \\  viu: https://github.com/atanunq/viu  (image preview)
;

const FZFMode = enum {
    Revert,
    Fetch,
};

const MAX_FZF_SELECTION_BYTES: usize = 1024 * 1024;

const UndoData = struct {
    original_path: []const u8,
    trash_path: []const u8,
    trashinfo_path: []const u8,
};

const TrashUndoLog = util.UndoLog.UndoLog(UndoData);

pub fn main() !void {
    // Arena intentionally not freed -- OS reclaims on process exit
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    var ctx = try Context.init(arena);
    if (builtin.mode == .Debug) ctx.debugPrint();
    if (ctx.reporter.isError()) {
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    if (ctx.flag_help) {
        util.log("{s}\n\n  Version:\n    {s} {s} {s} ({s}) '{s}'", .{
            help_msg,
            build_option.version,
            build_option.change_id[0..8],
            build_option.commit_id[0..8],
            build_option.date,
            build_option.description,
        });
        ctx.reporter.EXIT_WITH_REPORT(0);
    }
    if (ctx.flag_version) {
        util.log("trash version: ({s}) {s} {s} -- '{s}'", .{
            build_option.date,
            build_option.change_id[0..8],
            build_option.commit_id[0..8],
            build_option.description,
        });
        ctx.reporter.EXIT_WITH_REPORT(0);
    }

    if (ctx.flag_revert) |value| {
        return revertTrash(&ctx, value);
    }

    if (ctx.flag_fetch) |value| {
        return fetchTrash(&ctx, value);
    }

    if (ctx.flag_revert_fzf) {
        return fzfTrash(&ctx, .Revert);
    }

    if (ctx.flag_fetch_fzf) {
        return fzfTrash(&ctx, .Fetch);
    }

    if (ctx.flag_fzf_preview) |value| {
        return fzfPreview(&ctx, value);
    }

    if (ctx.flag_undo) {
        if (ctx.positionals.len > 0) {
            try ctx.reporter.pushError("--undo takes no arguments", .{});
            ctx.reporter.EXIT_WITH_REPORT(1);
        }
        return undoTrash(&ctx);
    }

    if (ctx.positionals.len == 0) {
        util.log("USAGE: trash [file]...", .{});
        std.process.exit(1);
    }

    var undo_files = std.ArrayList(UndoData).empty;
    var success_count: usize = 0;
    var fail_count: usize = 0;
    for (ctx.positionals) |path| {
        const stat = try ctx.cwd.statNoFollow(path) orelse {
            try ctx.reporter.pushWarning("file not found: {s}", .{path});
            continue;
        };

        // Capture absolute original path before trashing.
        const original_path = try ctx.cwd.realpathZ(ctx.arena, path);

        const trash_path = ctx.cwd.trashAt(ctx.arena, ctx.trash_paths, path, stat.kind) catch |err| switch (err) {
            else => ctx.reporter.PANIC_WITH_REPORT("unexpected error: {t}", .{err}),
            error.TrashFileKindNotSupported => {
                fail_count +|= 1;
                try ctx.reporter.pushWarning("trash does not support '{t}' files, unable to trash: {s}", .{ stat.kind, path });
                continue;
            },
        };

        // Record undo metadata for this file.
        const abs_trash_path = try ctx.cwd.realpathZ(ctx.arena, trash_path);
        const trashinfo_path: []const u8 = if (ctx.trash_paths.info_dir) |info_dir|
            try util.trashinfo.filepathAt(ctx.arena, info_dir, std.fs.path.basename(trash_path))
        else
            "";
        const abs_trashinfo_path: []const u8 = if (trashinfo_path.len > 0)
            try ctx.cwd.realpathZ(ctx.arena, trashinfo_path)
        else
            "";
        try undo_files.append(ctx.arena, .{
            .original_path = original_path,
            .trash_path = abs_trash_path,
            .trashinfo_path = abs_trashinfo_path,
        });

        success_count +|= 1;
        if (!ctx.flag_silent) util.log("{s} > $trash/{s}", .{ path, std.fs.path.basename(trash_path) });
    }
    if (fail_count > 0) {
        try ctx.reporter.pushWarning("{d} files failed to trash. trashed {d}/{d} files.", .{ fail_count, success_count, success_count + fail_count });
    }
    ctx.reporter.report();
    if (success_count > 1 and fail_count == 0) {
        util.log("trashed {d}/{d} files", .{ success_count, success_count + fail_count });
    }

    const status: u8 = if (ctx.reporter.isError() or ctx.reporter.isWarning()) 1 else 0;

    // Only persist undo log when the entire command succeeded.
    if (status == 0 and undo_files.items.len > 0) {
        const log_path = util.UndoLog.logPath(ctx.arena, "trash-undo.zon") catch null;
        if (log_path) |path| {
            const was_reset = TrashUndoLog.appendAndSave(ctx.arena, path, undo_files.items) catch false;
            if (was_reset) util.log("warning: undo history was corrupt and has been reset", .{});
        }
    }

    ctx.reporter.EXIT_WITH_REPORT(status);
}

pub const RevertInfo = struct {
    trash_path: []const u8,
    trash_stat: std.fs.File.Stat,
    trashinfo_path: []const u8,
    revert_path: []const u8,
    /// if trash_stat is a link this describes where it links to
    trash_link: ?[]const u8,

    pub fn init(ctx: *Context, trash_name: []const u8) !RevertInfo {
        const basename = std.fs.path.basename(trash_name);
        const trash_path = try std.fs.path.join(ctx.arena, &.{
            ctx.trash_paths.files_dir,
            basename,
        });
        const info_dir = ctx.trash_paths.info_dir orelse return error.TrashInfoDirRequired;
        const trashinfo_path = try util.trashinfo.filepathAt(ctx.arena, info_dir, basename);

        const link_buffer = try ctx.arena.alloc(u8, std.fs.max_path_bytes);
        const trash_link = ctx.cwd.dir.readLink(trash_path, link_buffer) catch null;
        const trash_stat = try ctx.cwd.statNoFollow(trash_path);
        const trashinfo_stat = try ctx.cwd.statNoFollow(trashinfo_path);

        if (trash_stat == null) {
            try ctx.reporter.pushError("could not find trash file: {s}", .{trash_path});
        }
        if (trashinfo_stat == null) {
            try ctx.reporter.pushError("could not find trashinfo file.", .{});
        }
        if (ctx.reporter.isError()) {
            ctx.reporter.EXIT_WITH_REPORT(1);
        }

        const trashinfo_content = try ctx.cwd.filepathRead(ctx.arena, trashinfo_path);
        var iter_trashinfo_lines = std.mem.splitScalar(u8, trashinfo_content, '\n');
        var revert_path: ?[]const u8 = null;
        while (iter_trashinfo_lines.next()) |line| {
            if (line.len > 5 and util.startsWithIgnoreCase(line, "path=")) {
                revert_path = util.trim(line[5..]);
                break;
            }
        }
        if (revert_path == null) {
            try ctx.reporter.pushError("could not find revert path.", .{});
            ctx.reporter.EXIT_WITH_REPORT(1);
        }

        return .{
            .trash_path = trash_path,
            .trash_stat = trash_stat.?,
            .trashinfo_path = trashinfo_path,
            .revert_path = revert_path.?,
            .trash_link = trash_link,
        };
    }
};

pub fn fzfPreview(ctx: *Context, trash_name: []const u8) !void {
    const revert_info = try RevertInfo.init(ctx, trash_name);
    var stdout_buffer: [4 * 1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout.interface.flush() catch {};
    try stdout.interface.print("-----------------------------------------------------\n", .{});
    try stdout.interface.print("Path: {s}\n", .{revert_info.revert_path});
    try stdout.interface.print("Kind: {t}\n", .{revert_info.trash_stat.kind});
    if (revert_info.trash_stat.kind == .file) {
        try stdout.interface.print("Size: {d}\n", .{revert_info.trash_stat.size});
    }
    try stdout.interface.print("-----------------------------------------------------\n", .{});

    switch (revert_info.trash_stat.kind) {
        else => {},
        .sym_link => {
            var path_buffer: util.FilepathBuffer = undefined;
            const link = try ctx.cwd.dir.readLink(revert_info.trash_path, &path_buffer);
            try stdout.interface.print("links to: {s}/\n", .{link});
        },
        .directory => {
            var dir = try ctx.cwd.dir.openDir(revert_info.trash_path, .{ .iterate = true });
            defer dir.close();

            try stdout.interface.print("{s}/\n", .{std.fs.path.basename(revert_info.trash_path)});
            var iter = dir.iterate();
            var total_count: usize = 0;

            const max_display = 20;
            const Entry = struct { name: [std.fs.max_name_bytes]u8, name_len: usize, stat: ?std.fs.File.Stat };
            var entries: [max_display]Entry = undefined;
            var display_count: usize = 0;

            while (try iter.next()) |entry| {
                if (display_count < max_display) {
                    // statFile follows symlinks, so dangling symlinks will fail with
                    // FileNotFound. Catch all stat errors and show the entry without
                    // size/kind info rather than crashing the preview.
                    const entry_stat: ?std.fs.File.Stat = dir.statFile(entry.name) catch null;
                    var name_buf: [std.fs.max_name_bytes]u8 = undefined;
                    @memcpy(name_buf[0..entry.name.len], entry.name);
                    entries[display_count] = .{ .name = name_buf, .name_len = entry.name.len, .stat = entry_stat };
                    display_count += 1;
                }
                total_count += 1;
            }

            // Draw tree: we collect entries first because Dir.Iterator.index and
            // end_index are internal buffer byte offsets, not entry counts. They
            // only reflect the current kernel readdir buffer batch, so comparing
            // them cannot reliably detect the last directory entry.
            for (entries[0..display_count], 0..) |entry, i| {
                const is_last = i == display_count - 1 and total_count <= max_display;
                const prefix: []const u8 = if (is_last) "  └─ " else "  ├─ ";
                if (entry.stat) |stat| {
                    try stdout.interface.print("{s}({t} {d}) {s}\n", .{ prefix, stat.kind, stat.size, entry.name[0..entry.name_len] });
                } else {
                    try stdout.interface.print("{s}(? ?) {s}\n", .{ prefix, entry.name[0..entry.name_len] });
                }
            }
            if (total_count > max_display) {
                try stdout.interface.print("  ...\n", .{});
            }
            try stdout.interface.print("  {d} children\n", .{total_count});
        },
        .file => {
            const file = try ctx.cwd.filepathOpen(revert_info.trash_path, .{});
            var reader = file.reader(&.{});
            var null_detector_buffer: [1024]u8 = undefined;
            var null_detector = try NullByteDetectorWriter.init(&null_detector_buffer);
            _ = reader.interface.streamRemaining(&null_detector.interface) catch {};

            // fzf --preview doenst pass a tty as stdout so we caint use util.term.winwidth to set the
            // viu width. my workaroud is that i pass a --viu-width flag when seting the --preview command
            // and trash -F and -R do have access to a tty so they just get winwidth.col to pass along
            const width = if (ctx.flag_fzf_preview_viu_width) |width| try util.fmt(ctx.arena, "{d}", .{width}) else "50";
            if (null_detector.contains_null) {
                const is_image = util.endsWithAnyIgnoreCase(revert_info.revert_path, &.{ ".png", ".gif", ".jpg", ".jpeg" });
                if (ctx.flag_fzf_preview_viu and is_image and try util.exec.exists(ctx.arena, "viu")) {
                    var viu = try util.exec.spawn(ctx.arena, .{
                        .stdout_behavior = .Pipe,
                        .args = &.{
                            "viu",
                            "-w",
                            width,
                            "-b",
                            util.trim(revert_info.trash_path),
                        },
                    });
                    var viu_reader = viu.stdout.?.reader(&.{});
                    _ = try viu_reader.interface.streamRemaining(&stdout.interface);
                    viu.stdout.?.close();
                    viu.stdout = null;
                    _ = try viu.wait();
                } else {
                    _ = try stdout.interface.write("binary data\n");
                }
            } else {
                try reader.seekTo(0);
                _ = reader.interface.streamRemaining(&stdout.interface) catch {};
            }
        },
    }
}

/// trash_name gets basenamed, so it can be a path (but the dirname will be ignored).
pub fn revertTrash(ctx: *Context, trash_name: []const u8) !void {
    if (builtin.os.tag != .linux) {
        try ctx.reporter.pushError("--revert is only supported on linux", .{});
        ctx.reporter.EXIT_WITH_REPORT(1);
    } else {
        const revert_info = try RevertInfo.init(ctx, trash_name);
        if (try ctx.cwd.statNoFollow(revert_info.revert_path) != null) {
            try ctx.reporter.pushError("revert dest already exists: ({s})", .{revert_info.revert_path});
            ctx.reporter.EXIT_WITH_REPORT(1);
        }
        try ctx.cwd.move(revert_info.trash_path, revert_info.revert_path);
        try ctx.cwd.dir.deleteFile(revert_info.trashinfo_path);
        util.log("restored: {s}", .{revert_info.revert_path});
        return;
    }
}

/// trash_name gets basenamed, so it can be a path (but the dirname will be ignored).
pub fn fetchTrash(ctx: *Context, trash_name: []const u8) !void {
    if (builtin.os.tag != .linux) {
        try ctx.reporter.pushError("--fetch is only supported on linux", .{});
        ctx.reporter.EXIT_WITH_REPORT(1);
    } else {
        const revert_info = try RevertInfo.init(ctx, trash_name);
        const fetch_basename = std.fs.path.basename(revert_info.revert_path);
        if (try ctx.cwd.statNoFollow(fetch_basename) != null) {
            try ctx.reporter.pushError("fetch dest already exists: (./{s})", .{fetch_basename});
            ctx.reporter.EXIT_WITH_REPORT(1);
        }
        try ctx.cwd.move(revert_info.trash_path, fetch_basename);
        try ctx.cwd.dir.deleteFile(revert_info.trashinfo_path);
        util.log("fetched: ./{s}", .{fetch_basename});
        return;
    }
}

pub fn undoTrash(ctx: *Context) !void {
    const log_path = try util.UndoLog.logPath(ctx.arena, "trash-undo.zon");
    const entries = TrashUndoLog.read(ctx.arena, log_path) catch |err| switch (err) {
        error.UndoLogCorrupt => {
            try TrashUndoLog.write(log_path, &.{});
            util.log("warning: undo history was corrupt and has been reset", .{});
            util.log("nothing to undo", .{});
            return;
        },
        else => return err,
    };
    if (entries.len == 0) {
        util.log("nothing to undo", .{});
        return;
    }
    const files = entries[entries.len - 1].files;

    // Pre-flight: validate every restore target before moving anything.
    var preflight_ok = true;
    for (files) |file| {
        if (try ctx.cwd.statNoFollow(file.trash_path) == null) {
            try ctx.reporter.pushError("undo failed: trash file missing: {s}", .{file.trash_path});
            preflight_ok = false;
        }
        if (try ctx.cwd.statNoFollow(file.original_path) != null) {
            try ctx.reporter.pushError("undo failed: original path already exists: {s}", .{file.original_path});
            preflight_ok = false;
        }
        if (std.fs.path.dirname(file.original_path)) |parent| {
            const parent_stat = try ctx.cwd.statNoFollow(parent);
            if (parent_stat == null or parent_stat.?.kind != .directory) {
                try ctx.reporter.pushError("undo failed: parent directory missing: {s}", .{parent});
                preflight_ok = false;
            }
        }
    }
    if (!preflight_ok) {
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    // Execute: restore each file to its original location.
    for (files) |file| {
        try ctx.cwd.move(file.trash_path, file.original_path);
        if (builtin.os.tag == .linux and file.trashinfo_path.len > 0) {
            ctx.cwd.dir.deleteFile(file.trashinfo_path) catch {};
        }
        if (!ctx.flag_silent) util.log("restored: {s}", .{file.original_path});
    }

    // Remove the entry from the log only after successful undo.
    try TrashUndoLog.write(log_path, entries[0 .. entries.len - 1]);
}

pub fn fzfTrash(ctx: *Context, fzf_mode: FZFMode) !void {
    if (builtin.os.tag != .linux) {
        try ctx.reporter.pushError("--fetch and --revert are only supported on linux", .{});
        ctx.reporter.EXIT_WITH_REPORT(1);
    } else {
        if (!util.term.isTTY()) {
            try ctx.reporter.pushError("fzf needs stdout to be a tty", .{});
            ctx.reporter.EXIT_WITH_REPORT(1);
        }
        var trash_dir = try ctx.cwd.dir.openDir(ctx.trash_paths.files_dir, .{ .iterate = true });
        defer trash_dir.close();

        var fzf_option_list = std.ArrayList(u8).empty;
        var iter = trash_dir.iterate();
        const info_dir = ctx.trash_paths.info_dir orelse return error.TrashInfoDirRequired;
        fill_fzf_option_list: while (try iter.next()) |entry| {
            // filter out files with non ascii names (this one had me stumped for a while)
            for (entry.name) |char| {
                if (!std.ascii.isAscii(char)) continue :fill_fzf_option_list;
            }

            const trashinfo_path = try util.trashinfo.filepathAt(ctx.arena, info_dir, entry.name);

            if (try ctx.cwd.exists(trashinfo_path)) {
                try fzf_option_list.appendSlice(ctx.arena, entry.name);
                try fzf_option_list.append(ctx.arena, '\n');
            }
        }

        const winsize = try util.term.winsize();
        const fzf_prompt = switch (fzf_mode) {
            .Fetch => "fetch> ",
            .Revert => "revert> ",
        };
        const preview_horizontal = winsize.col < 170;
        const preview_command_viu_flags: []const u8 = blk: {
            if (ctx.flag_fzf_preview_viu) {
                if (!(try util.exec.exists(ctx.arena, "viu"))) {
                    try ctx.reporter.pushError("--viu set but viu executable not found", .{});
                    ctx.reporter.EXIT_WITH_REPORT(1);
                }
                const viu_width_default: usize = if (preview_horizontal) winsize.col else @intFromFloat(@as(f32, @floatFromInt(winsize.col)) * 0.6);
                const viu_width = ctx.flag_fzf_preview_viu_width orelse viu_width_default;
                break :blk try util.fmt(ctx.arena, "--viu --viu-width {d}", .{viu_width});
            } else {
                break :blk "";
            }
        };
        const preview_command_trash_flags: []const u8 = blk: {
            var flags = std.ArrayList(u8).empty;
            if (ctx.flag_trash_dir) |path| {
                try flags.appendSlice(ctx.arena, " --trash-dir ");
                try flags.appendSlice(ctx.arena, path);
            }
            if (ctx.flag_trash_info_dir) |path| {
                try flags.appendSlice(ctx.arena, " --trash-info-dir ");
                try flags.appendSlice(ctx.arena, path);
            }
            break :blk flags.items;
        };
        const preview_command = try util.fmt(ctx.arena, "trash --fzf-preview {{}} {s}{s}", .{ preview_command_viu_flags, preview_command_trash_flags });
        const preview_window_default = if (preview_horizontal) "top:80%" else "right:60%";
        const preview_window = ctx.flag_fzf_preview_window orelse preview_window_default;
        var child = try util.exec.spawn(ctx.arena, .{
            .stdin_behavior = .Pipe,
            .stdout_behavior = .Pipe,
            .args = &.{
                "fzf",
                "-m",
                "--style",
                "minimal",
                "--prompt",
                fzf_prompt,
                "--preview",
                preview_command,
                "--preview-window",
                preview_window,
            },
        });
        try child.stdin.?.writeAll(std.mem.trimEnd(u8, fzf_option_list.items, "\n"));
        child.stdin.?.close();
        child.stdin = null;
        const revert_path_raw = child.stdout.?.readToEndAlloc(ctx.arena, MAX_FZF_SELECTION_BYTES) catch |err| switch (err) {
            error.FileTooBig => {
                try ctx.reporter.pushError(
                    "fzf selection output exceeded {d} bytes; reduce selected items or narrow the query",
                    .{MAX_FZF_SELECTION_BYTES},
                );
                ctx.reporter.EXIT_WITH_REPORT(1);
            },
            else => return err,
        };
        const revert_path = util.trim(revert_path_raw);
        const term = try child.wait();

        switch (term) {
            .Exited => |code| switch (code) {
                0 => {},
                // fzf exit 1 = no match, 130 = interrupted (Ctrl+C / ESC)
                1, 130 => return,
                // fzf exit 2 = error
                else => {
                    try ctx.reporter.pushError("fzf exited with error code {d}", .{code});
                    ctx.reporter.EXIT_WITH_REPORT(1);
                },
            },
            else => {
                try ctx.reporter.pushError("fzf terminated abnormally", .{});
                ctx.reporter.EXIT_WITH_REPORT(1);
            },
        }

        if (revert_path.len == 0) {
            return;
        }

        var iter_path = std.mem.splitScalar(u8, revert_path, '\n');
        while (iter_path.next()) |p| {
            switch (fzf_mode) {
                .Fetch => try fetchTrash(ctx, p),
                .Revert => try revertTrash(ctx, p),
            }
        }
        return;
    }
}

const Context = struct {
    arena: Allocator,
    reporter: Reporter,
    cwd: WorkDir,
    trash_paths: TrashPaths = undefined,

    args: util.ArgIterator = undefined,
    positionals: [][:0]const u8 = undefined,
    flag_help: bool = false,
    flag_undo: bool = false,
    flag_revert: ?[:0]const u8 = null,
    flag_revert_fzf: bool = false,
    flag_fetch: ?[:0]const u8 = null,
    flag_fetch_fzf: bool = false,
    flag_fzf_preview: ?[:0]const u8 = null,
    flag_fzf_preview_viu: bool = false,
    flag_fzf_preview_viu_width: ?usize = null,
    flag_fzf_preview_window: ?[:0]const u8 = null,
    flag_trash_dir: ?[:0]const u8 = null,
    flag_trash_info_dir: ?[:0]const u8 = null,
    flag_version: bool = false,
    flag_silent: bool = false,
    flag_parser: FlagParser = .{
        .parseFn = Context.implParseFn,
        .setProgramPathFn = FlagParser.noopSetProgramPath,
        .setArgIteratorFn = FlagParser.autoSetArgIterator(Context, "flag_parser", "args"),
        .setPositionalListFn = FlagParser.autoSetPositionalList(Context, "flag_parser", "positionals"),
    },

    pub fn init(arena: Allocator) !Context {
        var result = Context{
            .arena = arena,
            .cwd = WorkDir.cwd(),
            .reporter = Reporter.init(arena),
        };
        try result.flag_parser.parseProcessArgs(arena);

        // Mode flags are mutually exclusive.
        var mode_count: u8 = 0;
        if (result.flag_undo) mode_count += 1;
        if (result.flag_revert != null) mode_count += 1;
        if (result.flag_fetch != null) mode_count += 1;
        if (result.flag_revert_fzf) mode_count += 1;
        if (result.flag_fetch_fzf) mode_count += 1;
        if (result.flag_fzf_preview != null) mode_count += 1;
        if (mode_count > 1) {
            try result.reporter.pushError("--undo, --revert, --fetch, --revert-fzf, --fetch-fzf, and --fzf-preview are mutually exclusive", .{});
        }

        result.trash_paths = util.trash_paths.resolve(arena, .{
            .cli_trash_dir = result.flag_trash_dir,
            .cli_trash_info_dir = result.flag_trash_info_dir,
        }) catch |err| {
            if (builtin.os.tag == .linux) {
                switch (err) {
                    error.InvalidTrashFilesDir => {
                        try result.reporter.pushError("--trash-dir must include a parent directory", .{});
                    },
                    else => return err,
                }
            } else {
                switch (err) {
                    error.TrashInfoDirUnsupportedOnThisOs => {
                        try result.reporter.pushError("--trash-info-dir is only supported on linux", .{});
                    },
                    else => return err,
                }
            }
            return result;
        };
        return result;
    }

    pub fn debugPrint(self: *Context) void {
        std.debug.print("---------------------------------------------------------------------------------\n", .{});
        util.debugPrintArgIterator(&self.args, "ARGS", true);
        util.debugPrintPositionalList(self.positionals, "POSITIONALS");
        util.debugPrintFlagFields(Context, self.*);
        std.debug.print("---------------------------------------------------------------------------------\n", .{});
    }

    const Flags = enum {
        @"--help",
        h,
        @"--version",
        v,
        @"--silent",
        s,
        @"--undo",
        u,
        @"--fetch",
        f,
        @"--fetch-fzf",
        F,
        @"--revert",
        r,
        @"--revert-fzf",
        R,
        @"--fzf-preview",
        @"--fzf-preview-window",
        @"--trash-dir",
        @"--trash-info-dir",
        @"--viu",
        @"--viu-width",
    };

    pub fn implParseFn(flag_parser: *FlagParser, arg: [:0]const u8, iter: *util.ArgIterator) FlagParser.Error!FlagParser.ArgType {
        var self: *Context = @fieldParentPtr("flag_parser", flag_parser);

        var flag_iter = util.FlagIterator(Flags).init(arg);
        while (flag_iter.next()) |result| {
            switch (result) {
                .Flag => |flag| {
                    switch (flag) {
                        .h, .@"--help" => self.flag_help = true,
                        .v, .@"--version" => self.flag_version = true,
                        .s, .@"--silent" => self.flag_silent = true,
                        .u, .@"--undo" => self.flag_undo = true,
                        .F, .@"--fetch-fzf" => self.flag_fetch_fzf = true,
                        .f, .@"--fetch" => {
                            self.flag_fetch = iter.next();
                            if (self.flag_fetch == null) {
                                try self.reporter.pushError("--fetch value missing", .{});
                            }
                        },
                        .R, .@"--revert-fzf" => self.flag_revert_fzf = true,
                        .r, .@"--revert" => {
                            self.flag_revert = iter.next();
                            if (self.flag_revert == null) {
                                try self.reporter.pushError("--revert value missing", .{});
                            }
                        },
                        .@"--fzf-preview" => {
                            self.flag_fzf_preview = iter.next();
                            if (self.flag_fzf_preview == null) {
                                try self.reporter.pushError("--fzf-preview value missing", .{});
                            }
                        },
                        .@"--fzf-preview-window" => {
                            self.flag_fzf_preview_window = iter.next();
                            if (self.flag_fzf_preview_window == null) {
                                try self.reporter.pushError("--fzf-preview-window value missing", .{});
                            }
                        },
                        .@"--trash-dir" => {
                            self.flag_trash_dir = iter.next();
                            if (self.flag_trash_dir == null) {
                                try self.reporter.pushError("--trash-dir value missing", .{});
                            }
                        },
                        .@"--trash-info-dir" => {
                            self.flag_trash_info_dir = iter.next();
                            if (self.flag_trash_info_dir == null) {
                                try self.reporter.pushError("--trash-info-dir value missing", .{});
                            }
                        },
                        .@"--viu" => self.flag_fzf_preview_viu = true,
                        .@"--viu-width" => {
                            self.flag_fzf_preview_viu_width = iter.nextInt(usize, 10) catch {
                                try self.reporter.pushError("--viu-width requires a valid number", .{});
                                break;
                            };
                        },
                    }
                },
                .UnknownLong => |unknown_long| {
                    try self.reporter.pushError("unknown long flag: {s}", .{unknown_long});
                },
                .UnknownShort => |unknown_short| {
                    try self.reporter.pushError("unknown short flag: -{c}", .{unknown_short});
                },
            }
        }

        if (flag_iter.isFlag()) return .NotPositional;
        return .Positional;
    }
};
