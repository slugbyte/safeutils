const std = @import("std");
const util = @import("util");
const builtin = @import("builtin");
const build_option = @import("build_option");

const Allocator = std.mem.Allocator;
const WorkDir = util.WorkDir;
const Reporter = util.Reporter;
const FlagParser = util.FlagParser;
const BinaryDetectorWriter = util.BinaryDetectorWriter;

pub const help_msg =
    \\USAGE: trash files.. (--flags)
    \\  Move files to $trash.
    \\
    \\  --version                 print version
    \\  -r --revert trash_file    (linux-only) revert a file from trash back to where it came from
    \\  -R --revert-fzf           (linux-only) use fzf to select a trash_file to revert
    \\  --viu                     add support for viu block image display in fzf preview
    \\  -s --silent               dont print trash paths
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
        return;
    }
    if (ctx.flag_version) {
        util.log("trash version: ({s}) {s} {s} -- '{s}'", .{
            build_option.date,
            build_option.change_id[0..8],
            build_option.commit_id[0..8],
            build_option.description,
        });
        return;
    }

    if (ctx.flag_revert) |value| {
        return revert(&ctx, value);
    }

    if (ctx.flag_fetch) |value| {
        return fetch(&ctx, value);
    }

    if (ctx.flag_revert_fzf) {
        return fzfTrash(&ctx, .Revert);
    }

    if (ctx.flag_fetch_fzf) {
        return fzfTrash(&ctx, .Fetch);
    }

    if (ctx.flag_fzf_preview) |value| {
        return revertFZFPreview(&ctx, value);
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
            else => ctx.reporter.PANIC("unexpected error: {t}", .{err}),
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

        const trash_stat = try ctx.cwd.stat(trash_path);
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
        };
    }
};

pub fn revertFZFPreview(ctx: *Context, trash_name: []const u8) !void {
    const revert_info = try RevertInfo.init(ctx, trash_name);
    var stdout_buffer: [4 * 1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout.interface.flush() catch {};
    try stdout.interface.print("-----------------------------------------------------\n", .{});
    try stdout.interface.print("Path: {s}\n", .{revert_info.revert_path});
    try stdout.interface.print("Kind: {t}\n", .{revert_info.trash_stat.kind});
    try stdout.interface.print("Size: {d}\n", .{revert_info.trash_stat.size});
    try stdout.interface.print("-----------------------------------------------------\n", .{});

    const file = try ctx.cwd.filepathOpen(revert_info.trash_path, .{});
    var reader = file.reader(&.{});
    var binary_detector_buffer: [1024]u8 = undefined;
    var binary_detector = try BinaryDetectorWriter.init(&binary_detector_buffer);
    _ = reader.interface.streamRemaining(&binary_detector.interface) catch {};

    if (binary_detector.is_binary) {
        if (ctx.flag_fzf_preview_viu and util.endsWithAnyIgnoreCase(revert_info.revert_path, &.{ ".png", ".jpg", ".gif", ".jpeg" })) {
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
}

/// trashname can be a filename in trash or a full path..
/// reveht actually taskes the basename of trash_name and then trys to find that in trash_dirpath
pub fn revert(ctx: *Context, trash_name: []const u8) !void {
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

pub fn fetch(ctx: *Context, trash_name: []const u8) !void {
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

        const viu_flag = if (ctx.flag_fzf_preview_viu) "--viu" else "";
        var child = std.process.Child.init(&.{
            "fzf",
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
        switch (fzf_mode) {
            .Fetch => try fetch(ctx, revert_path),
            .Revert => try revert(ctx, revert_path),
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
    flag_parser: util.FlagParser = .{
        .parseFn = Context.implParseFn,
        .setArgIteratorFn = Context.implSetArgIterator,
        .setPositionalListFn = Context.implSetPositionalList,
        .setProgramPathFn = FlagParser.noopSetProgramPath,
    },

    pub fn init(arena: Allocator) !Context {
        var result = Context{
            .arena = arena,
            .cwd = WorkDir.cwd(),
            .reporter = Reporter.init(arena),
        };
        try result.flag_parser.parse(arena);
        return result;
    }

    pub fn debugPrint(self: *Context) void {
        std.debug.print("---------------------------------------------------------------------------------\n", .{});
        self.args.reset();
        _ = self.args.skip();
        std.debug.print("ARGS: ", .{});
        while (self.args.next()) |arg| {
            std.debug.print("'{s}' ", .{arg});
        }
        std.debug.print("\n", .{});
        util.logFlagFields(Context, self.*);
        std.debug.print("---------------------------------------------------------------------------------\n", .{});
    }

    pub fn implSetPositionalList(flag_parser: *util.FlagParser, positional: [][:0]const u8) bool {
        var self = @as(*Context, @fieldParentPtr("flag_parser", flag_parser));
        self.positionals = positional;
        return true;
    }

    pub fn implSetArgIterator(flag_parser: *util.FlagParser, iter: util.ArgIterator) bool {
        var self = @as(*Context, @fieldParentPtr("flag_parser", flag_parser));
        self.args = iter;
        return true;
    }

    pub fn implParseFn(flag_parser: *util.FlagParser, arg: [:0]const u8, iter: *util.ArgIterator) util.FlagParser.Error!bool {
        var self = @as(*Context, @fieldParentPtr("flag_parser", flag_parser));

        if (util.eqlFlag(arg, "--help", "-h")) {
            self.flag_help = true;
            return true;
        }

        if (util.eqlFlag(arg, "--silent", "-s")) {
            self.flag_silent = true;
            return true;
        }

        if (util.eqlFlag(arg, "--revert", "-r")) {
            self.flag_revert = iter.next();
            if (self.flag_revert == null) {
                try self.reporter.pushError("--revert value missing", .{});
            }
            return true;
        }
        if (util.eqlFlag(arg, "--fetch", "-f")) {
            self.flag_fetch = iter.next();
            if (self.flag_fetch == null) {
                try self.reporter.pushError("--fetch value missing", .{});
            }
            return true;
        }

        if (util.eqlFlag(arg, "--revert-fzf", "-R")) {
            self.flag_revert_fzf = true;
            return true;
        }

        if (util.eqlFlag(arg, "--fetch-fzf", "-F")) {
            self.flag_fetch_fzf = true;
            return true;
        }

        if (util.eql(arg, "--fzf-preview")) {
            self.flag_fzf_preview = iter.next();
            if (self.flag_fzf_preview == null) {
                try self.reporter.pushError("--fzf-preview value missing", .{});
            }
            return true;
        }
        if (util.eql(arg, "--viu")) {
            self.flag_fzf_preview_viu = true;
            return true;
        }
        if (util.eql(arg, "--version")) {
            self.flag_version = true;
            return true;
        }

        return false;
    }
};
