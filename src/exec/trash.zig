const std = @import("std");
const util = @import("util");
const builtin = @import("builtin");
const build_option = @import("build_option");

const Allocator = std.mem.Allocator;
const WorkDir = util.WorkDir;
const Reporter = util.Reporter;
const FlagParser = util.FlagParser;
const NullByteDetectorWriter = util.NullByteDetectorWriter;

pub const help_msg =
    \\USAGE: trash files.. (--flags)
    \\  Move files to the trash.
    \\  Revert trash fetch back to where they came from. 
    \\  Fetch trash files to current dir.
    \\
    \\  --version                 print version
    \\  -r --revert trash_file    (linux-only) revert a file from trash back to where it came from
    \\  -R --revert-fzf           (linux-only) use fzf to revert a trash file
    \\  -F --fetch-fzf            (linux-only) use fzf to fetch a trash_file to the current dir
    \\     --viu                  add support for viu block image display in fzf preview
    \\  -s --silent               only print errors
    \\  -h --help                 display help
;

const FZFMode = enum {
    Revert,
    Fetch,
};

const UndoData = struct {
    trashinfo_path: []const u8,
    trash_path: []const u8,
    original_path: []const u8,
};

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    var wat = util.known_file.FilenameBumper.parse("cool.gif");
    wat.bump();
    util.log("name: '{s}', count: {?d}, ext: {s}", .{ wat.name, wat.count, wat.ext });

    var filename_sa = util.StackFilenameAllocator.empty;
    util.log("trash_filename: {s}", .{try wat.fmtFilename(filename_sa.allocatorInvalidatePrevious())});
    var ctx = try Context.init(arena);
    if (builtin.mode == .Debug) ctx.debugPrint();
    if (ctx.reporter.isError()) {
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    if (ctx.flag_help) {
        util.log("{s}\n\n  Version:\n   {s} {s} {s} ({s})", .{
            help_msg,
            build_option.version,
            build_option.change_id[0..8],
            build_option.commit_id[0..8],
            build_option.date,
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

    if (ctx.positionals.len == 0) {
        util.log("USAGE: trash [file]...", .{});
        std.process.exit(1);
    }

    var success_count: usize = 0;
    var fail_count: usize = 0;
    for (ctx.positionals) |path| {
        const stat = try ctx.cwd.stat(path) orelse {
            try ctx.reporter.pushWarning("file not found: {s}", .{path});
            continue;
        };
        const trash_path = ctx.cwd.trash(ctx.arena, path, stat.kind) catch |err| switch (err) {
            else => ctx.reporter.PANIC_WITH_REPORT("unexpected error: {t}", .{err}),
            error.TrashFileKindNotSupported => {
                fail_count +|= 1;
                try ctx.reporter.pushWarning("trash does not support '{t}' files, unable to trash: {s}", .{ stat.kind, path });
                continue;
            },
        };
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

    const status: u8 = if (ctx.reporter.isTrouble()) 1 else 0;
    ctx.reporter.EXIT_WITH_REPORT(status);
}

pub const RevertInfo = struct {
    trash_path: []const u8,
    trash_stat: std.fs.File.Stat,
    trashinfo_path: []const u8,
    revert_path: []const u8,
    trash_link: ?[]const u8,

    pub fn init(ctx: *Context, trash_name: []const u8) !RevertInfo {
        const basename = std.fs.path.basename(trash_name);
        const trash_dirpath = try util.known_file.dirpathTrash(ctx.arena);
        const trashinfo_dirpath = try util.known_file.dirpathTrashInfo(ctx.arena);
        const trash_path = try std.fs.path.join(ctx.arena, &.{
            trash_dirpath,
            basename,
        });
        const trashinfo_path = try std.fs.path.join(ctx.arena, &.{
            trashinfo_dirpath,
            try util.fmt(ctx.arena, "{s}.trashinfo", .{basename}),
        });

        const link_buffer = try ctx.arena.alloc(u8, std.fs.max_path_bytes);
        const trash_link = ctx.cwd.dir.readLink(trash_path, link_buffer) catch null;
        if (trash_link == null) {
            ctx.arena.free(link_buffer);
        }
        var trash_stat = try ctx.cwd.stat(trash_path);
        if (trash_link != null) {
            trash_stat.?.kind = .sym_link;
        }
        const trashinfo_stat = try ctx.cwd.stat(trashinfo_path);

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
            var count: usize = 0;

            const max_display = 20;
            while (try iter.next()) |entry| {
                count += 1;
                if (count < max_display) {
                    const stat = try dir.statFile(entry.name);
                    if (iter.index != iter.end_index) {
                        @branchHint(.likely);
                        try stdout.interface.print("  ├─ ({t} {d}) {s}\n", .{ stat.kind, stat.size, entry.name });
                    } else {
                        try stdout.interface.print("  └─ ({t} {d}) {s}\n", .{ stat.kind, stat.size, entry.name });
                    }
                }
                if (count == max_display) {
                    try stdout.interface.print("  ...\n", .{});
                }
            }
            try stdout.interface.print("  {d} children\n", .{count});
        },
        .file => {
            const file = try ctx.cwd.filepathOpen(revert_info.trash_path, .{});
            var reader = file.reader(&.{});
            var null_detector_buffer: [1024]u8 = undefined;
            var null_detector = try NullByteDetectorWriter.init(&null_detector_buffer);
            _ = reader.interface.streamRemaining(&null_detector.interface) catch {};

            if (null_detector.contains_null) {
                const is_image = util.endsWithAnyIgnoreCase(revert_info.revert_path, &.{ ".png", ".gif", ".jpg", ".jpeg" });
                if (ctx.flag_fzf_preview_viu and is_image and try util.exeExists(ctx.arena, "viu")) {
                    var viu = std.process.Child.init(&.{
                        "viu",
                        "-w",
                        "50",
                        "-b",
                        util.trim(revert_info.trash_path),
                    }, ctx.arena);
                    viu.stderr_behavior = .Ignore;
                    viu.stdin_behavior = .Ignore;
                    viu.stdout_behavior = .Pipe;
                    try viu.spawn();
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
    } else {
        const revert_info = try RevertInfo.init(ctx, trash_name);
        try ctx.cwd.move(revert_info.trash_path, revert_info.revert_path);
        try ctx.cwd.dir.deleteFile(revert_info.trashinfo_path);
        util.log("restored: {s}", .{revert_info.revert_path});
        return;
    }
}

/// trash_name gets basenamed, so it can be a path (but the dirname will be ignored).
pub fn fetchTrash(ctx: *Context, trash_name: []const u8) !void {
    if (builtin.os.tag != .linux) {
        try ctx.reporter.pushError("--revert is only supported on linux", .{});
    } else {
        const revert_info = try RevertInfo.init(ctx, trash_name);
        const basename = std.fs.path.basename(revert_info.revert_path);
        try ctx.cwd.move(revert_info.trash_path, basename);
        try ctx.cwd.dir.deleteFile(revert_info.trashinfo_path);
        util.log("fetched: ./{s}", .{basename});
        return;
    }
}

pub fn fzfTrash(ctx: *Context, fzf_mode: FZFMode) !void {
    if (builtin.os.tag != .linux) {
        try ctx.reporter.pushError("--revert is only supported on linux", .{});
    } else {
        const trashinfo_dirpath = try util.known_file.dirpathTrashInfo(ctx.arena);
        const trash_dirpath = try util.known_file.dirpathTrash(ctx.arena);
        const trash_dir = try ctx.cwd.dir.openDir(trash_dirpath, .{ .iterate = true });
        var fzf_option_list = std.ArrayList(u8).empty;
        var iter = trash_dir.iterate();
        while (try iter.next()) |entry| {
            // only show paths that can be reverted
            if (try ctx.cwd.exists(try std.fs.path.join(ctx.arena, &.{
                trashinfo_dirpath,
                try util.fmt(ctx.arena, "{s}.trashinfo", .{entry.name}),
            }))) {
                try fzf_option_list.appendSlice(ctx.arena, entry.name);
                try fzf_option_list.append(ctx.arena, '\n');
            }
        }
        const viu_flag = blk: {
            if (ctx.flag_fzf_preview_viu) {
                if (!(try util.exeExists(ctx.arena, "viu"))) {
                    try ctx.reporter.pushError("--viu set but viu executable not found", .{});
                    ctx.reporter.EXIT_WITH_REPORT(1);
                }
                break :blk "--viu";
            } else {
                break :blk "";
            }
        };
        var child = std.process.Child.init(&.{
            "fzf",
            "-m",
            "--preview",
            try util.fmt(ctx.arena, "trash --fzf-preview {{}} {s}", .{viu_flag}),
        }, ctx.arena);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        _ = try child.spawn();
        try child.stdin.?.writeAll(fzf_option_list.items);
        child.stdin.?.close();
        child.stdin = null;
        const revert_path = util.trim(try child.stdout.?.readToEndAlloc(ctx.arena, std.fs.max_path_bytes));
        _ = try child.wait();

        if (revert_path.len == 0) {
            util.log("no files reverted", .{});
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

    args: util.ArgIterator = undefined,
    positionals: [][:0]const u8 = undefined,
    flag_help: bool = false,
    flag_revert: ?[:0]const u8 = null,
    flag_revert_fzf: bool = false,
    flag_fetch: ?[:0]const u8 = null,
    flag_fetch_fzf: bool = false,
    flag_fzf_preview: ?[:0]const u8 = null,
    flag_fzf_preview_viu: bool = false,
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
        V,
        @"--silent",
        s,
        @"--fetch",
        f,
        @"--fetch-fzf",
        F,
        @"--revert",
        r,
        @"--revert-fzf",
        R,
        @"--fzf-preview",
        @"--viu",
    };

    pub fn implParseFn(flag_parser: *FlagParser, arg: [:0]const u8, iter: *util.ArgIterator) FlagParser.Error!FlagParser.ArgType {
        var self: *Context = @fieldParentPtr("flag_parser", flag_parser);

        var flag_iter = util.FlagIterator(Flags).init(arg);
        while (flag_iter.next()) |result| {
            switch (result) {
                .Flag => |flag| {
                    switch (flag) {
                        .h, .@"--help" => self.flag_help = true,
                        .V, .@"--version" => self.flag_version = true,
                        .s, .@"--silent" => self.flag_silent = true,
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
                        .@"--viu" => self.flag_fzf_preview_viu = true,
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
