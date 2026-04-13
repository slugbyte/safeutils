const std = @import("std");
const util = @import("util");
const builtin = @import("builtin");
const build_option = @import("build_option");

const assert = std.debug.assert;
const dirname = std.fs.path.dirname;
const basename = std.fs.path.basename;
const Allocator = std.mem.Allocator;
const ArgIterator = util.ArgIterator;
const FlagParser = util.FlagParser;
const Reporter = util.Reporter;
const WorkDir = util.WorkDir;
const ClobberInfo = util.clobber_undo.ClobberInfo;

const MoveUndoData = struct {
    src_path: []const u8,
    dest_path: []const u8,
    clobber_trash_path: []const u8,
    clobber_trashinfo_path: []const u8,
    clobber_backup_path: []const u8,
    clobber_backup_trash_path: []const u8,
    clobber_backup_trashinfo_path: []const u8,
};

const MoveUndoLog = util.UndoLog.UndoLog(MoveUndoData);

pub const help_msg =
    \\Usage: move src.. dest (--flags)
    \\  Move or rename a file, or move multiple files into a directory.
    \\  When moving files into a directory dest must have '/' at the end.
    \\  When moving multiple files last path must be a directory and have a '/' at the end.
    \\
    \\  Move will not partially move src.. paths. Everything must move or nothing will move.
    \\
    \\  Undo:
    \\    -u --undo     Undo the most recent move operation.
    \\
    \\  Clobber Style:
    \\    (default)     Print error and exit
    \\    -t --trash    Move original dest to trash
    \\    -b --backup   Rename original dest (original).backup~
    \\
    \\    If both clobber flags are found it will choose backup over trash.
    \\
    \\  Rename:
    \\    -r --rename   Replace only the src basename with dest.
    \\                  Only works with one src path.
    \\    example:
    \\      ($ move --rename /example/oldname.zig newname.zig) results in /example/newname.zig
    \\
    \\  Other Flags:
    \\    -s --silent   Only print errors
    \\    -v --version  Print version
    \\    -h --help     Print this help
;

pub fn main() !void {
    // Arena intentionally not freed -- OS reclaims on process exit
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    var ctx = try Context.init(arena);
    if (builtin.mode == .Debug) ctx.debugPrint();

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
        util.log("move version: ({s}) {s} {s} -- '{s}'", .{
            build_option.date,
            build_option.change_id[0..8],
            build_option.commit_id[0..8],
            build_option.description,
        });
        ctx.reporter.EXIT_WITH_REPORT(0);
    }

    if (ctx.flag_undo) {
        if (ctx.positionals.len > 0) {
            try ctx.reporter.pushError("--undo takes no arguments", .{});
            ctx.reporter.EXIT_WITH_REPORT(1);
        }
        return undoMove(&ctx);
    }

    switch (ctx.positionals.len) {
        0, 1 => {
            util.log("USAGE: move src.. dest\n    (clobber flags --trash --backup)", .{});
            ctx.reporter.EXIT_WITH_REPORT(1);
        },
        2 => {
            const src_path = ctx.positionals[0];
            var dest_path = ctx.positionals[1];
            var same_location_dest_path: []const u8 = dest_path;

            // CHECK SRC EXISTS
            if (try ctx.cwd.statNoFollow(src_path) == null) {
                try ctx.reporter.pushError("src not found: ({s})", .{src_path});
            }
            if (ctx.reporter.isError() or ctx.reporter.isWarning()) {
                return ctx.reporter.EXIT_WITH_REPORT(1);
            }

            // APPLY --rename REWRITE (must happen before dest validation)
            if (ctx.flag_rename) {
                if (std.mem.indexOf(u8, dest_path, "/")) |_| {
                    try ctx.reporter.pushError("--rename value may not include a '/'", .{});
                }
                dest_path = try util.fmtZ(arena, "{s}/{s}", .{ dirname(src_path) orelse "./", dest_path });
                if (ctx.reporter.isError() or ctx.reporter.isWarning()) {
                    return ctx.reporter.EXIT_WITH_REPORT(1);
                }
            }

            // CHECK DEST AND CLOBBER
            if (try ctx.cwd.statNoFollow(dest_path)) |dest_stat| {
                const is_parent = try checkDest(&ctx, dest_path, dest_stat, false);
                if (ctx.reporter.isError() or ctx.reporter.isWarning()) {
                    return ctx.reporter.EXIT_WITH_REPORT(1);
                }

                if (is_parent) {
                    const real_dest_path = try util.fmt(arena, "{s}{s}", .{ dest_path, basename(src_path) });
                    same_location_dest_path = real_dest_path;
                    if (try ctx.cwd.statNoFollow(real_dest_path)) |real_dest_stat| {
                        _ = try checkDest(&ctx, real_dest_path, real_dest_stat, true);
                    }
                }
            }

            // CHECK SAME LOCATION
            if (try ctx.cwd.isPathSameLocation(src_path, same_location_dest_path)) {
                try ctx.reporter.pushError("src and dest cannot be same location: ({s} == {s})", .{ src_path, same_location_dest_path });
            }

            if (ctx.reporter.isError() or ctx.reporter.isWarning()) {
                return ctx.reporter.EXIT_WITH_REPORT(1);
            }

            const undo_data = try move(&ctx, src_path, dest_path);
            persistUndoLog(ctx.arena, &.{undo_data});
        },
        else => {
            const src_path_list = ctx.positionals[0 .. ctx.positionals.len - 1];
            const dest_path: [:0]const u8 = ctx.positionals[ctx.positionals.len - 1];

            if (ctx.flag_rename) {
                try ctx.reporter.pushError("--rename only works with one src path", .{});
                return ctx.reporter.EXIT_WITH_REPORT(1);
            }

            { // CHECK SRC PATHS EXIST
                for (src_path_list) |src_path| {
                    if (try ctx.cwd.statNoFollow(src_path) == null) {
                        try ctx.reporter.pushError("src path not found: ({s})", .{src_path});
                    }
                }
                if (ctx.reporter.isError() or ctx.reporter.isWarning()) {
                    try ctx.reporter.pushError("moved 0/{d} files", .{src_path_list.len});
                    return ctx.reporter.EXIT_WITH_REPORT(1);
                }
            }

            { // CHECK DEST IS A VALID DIRECTORY WITH TRAILING SLASH
                if (try ctx.cwd.statNoFollow(dest_path)) |dest_stat| {
                    if (dest_stat.kind != .directory) {
                        try ctx.reporter.pushError("multi-source dest must be a directory: ({s})", .{dest_path});
                    } else if (!util.endsWith(dest_path, "/")) {
                        try ctx.reporter.pushError("multi-source dest must have a trailing '/': ({s})", .{dest_path});
                    }
                } else {
                    try ctx.reporter.pushError("dest not found: ({s})", .{dest_path});
                }
                if (ctx.reporter.isError() or ctx.reporter.isWarning()) {
                    try ctx.reporter.pushError("moved 0/{d} files", .{src_path_list.len});
                    return ctx.reporter.EXIT_WITH_REPORT(1);
                }
            }

            { // CHECK REAL DEST PATHS ARE VALID
                for (src_path_list) |src_path| {
                    const real_dest_path = try util.fmt(arena, "{s}{s}", .{ dest_path, basename(src_path) });

                    if (try ctx.cwd.statNoFollow(real_dest_path)) |real_dest_stat| {
                        _ = try checkDest(&ctx, real_dest_path, real_dest_stat, true);
                    }
                    if (try ctx.cwd.isPathSameLocation(src_path, real_dest_path)) {
                        try ctx.reporter.pushError("src and dest cannot be same location: ({s} == {s})", .{ src_path, real_dest_path });
                    }
                }
                if (ctx.reporter.isError() or ctx.reporter.isWarning()) {
                    try ctx.reporter.pushError("moved 0/{d} files", .{src_path_list.len});
                    return ctx.reporter.EXIT_WITH_REPORT(1);
                }
            }
            // GO FOR IT
            var undo_list = std.ArrayList(MoveUndoData).empty;
            for (ctx.positionals[0 .. ctx.positionals.len - 1]) |src_path| {
                const undo_data = try move(&ctx, src_path, dest_path);
                try undo_list.append(arena, undo_data);
            }
            persistUndoLog(ctx.arena, undo_list.items);
            if (!ctx.flag_silent) util.log("moved {d}/{d} files", .{ src_path_list.len, src_path_list.len });
        },
    }

    const status: u8 = if (ctx.reporter.isError()) 1 else 0;
    ctx.reporter.EXIT_WITH_REPORT(status);
}

// returns true if dest is a valid parent directory
pub fn checkDest(
    ctx: *Context,
    dest_path: []const u8,
    dest_stat: std.fs.File.Stat,
    /// dest_is_into_path is a strange name.. it just means that dest_path has been created from og_dest/og_src
    dest_is_into_path: bool,
) !bool {
    switch (dest_stat.kind) {
        .directory => {
            if (!dest_is_into_path) {
                if (util.endsWith(dest_path, "/")) {
                    if (ctx.flag_rename) {
                        try ctx.reporter.pushError("--rename cannot be used when moving into a directory", .{});
                    }
                    return true;
                }
                if (ctx.flag_clobber_style == .NoClobber) {
                    try ctx.reporter.pushError("dest is a directory. use clobber flag or add '/' to dest to move src... into.", .{});
                }
            } else {
                if (ctx.flag_clobber_style == .NoClobber) {
                    try ctx.reporter.pushError("dest child dir exists ({s})", .{dest_path});
                }
            }
        },
        .file, .sym_link => {
            if (ctx.flag_clobber_style == .NoClobber) {
                if (dest_is_into_path) {
                    try ctx.reporter.pushError("dest child path exists ({s})", .{dest_path});
                } else {
                    try ctx.reporter.pushError("dest path exists, choose a clobber flag (--trash --backup)", .{});
                }
            }
        },
        else => {
            switch (ctx.flag_clobber_style) {
                .NoClobber => {
                    try ctx.reporter.pushError("dest path exists, choose a clobber flag (--trash --backup)", .{});
                },
                .Trash => {
                    try ctx.reporter.pushError("dest path exists and --trash does not support file type {t}, use --backup", .{
                        dest_stat.kind,
                    });
                },
                .Backup => {},
            }
        },
    }
    return false;
}

/// Asserts that everything has been prevalidated. Returns undo metadata.
pub fn move(ctx: *Context, src_path: [:0]const u8, dest_path: [:0]const u8) !MoveUndoData {
    var rename_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var real_dest_path = dest_path;

    if (std.mem.endsWith(u8, real_dest_path, "/")) {
        const file_name = std.fs.path.basename(src_path);
        real_dest_path = try std.fmt.bufPrintZ(&rename_buffer, "{s}{s}", .{ real_dest_path, file_name });
    }

    const abs_src = try ctx.cwd.realpathZ(ctx.arena, src_path);
    const abs_dest = try ctx.cwd.realpathZ(ctx.arena, real_dest_path);
    var undo = MoveUndoData{
        .src_path = abs_src,
        .dest_path = abs_dest,
        .clobber_trash_path = "",
        .clobber_trashinfo_path = "",
        .clobber_backup_path = "",
        .clobber_backup_trash_path = "",
        .clobber_backup_trashinfo_path = "",
    };

    if (try ctx.cwd.statNoFollow(real_dest_path)) |dest_stat| {
        switch (ctx.flag_clobber_style) {
            .NoClobber => ctx.reporter.PANIC_WITH_REPORT("NoClobber should be unreachable", .{}),
            .Trash => {
                const trash_path = try ctx.cwd.trash(ctx.arena, real_dest_path, dest_stat.kind);
                undo.clobber_trash_path = try ctx.cwd.realpathZ(ctx.arena, trash_path);
                undo.clobber_trashinfo_path = try util.clobber_undo.trashinfoPathFor(ctx.arena, ctx.cwd, trash_path);
                if (!ctx.flag_silent) try ctx.reporter.pushWarning("trashed: {s} > $trash/{s}", .{ real_dest_path, basename(trash_path) });
            },
            .Backup => {
                const path_destinaton_backup = try util.fmtZ(ctx.arena, "{s}.backup~", .{real_dest_path});
                undo.clobber_backup_path = try ctx.cwd.realpathZ(ctx.arena, path_destinaton_backup);
                if (try ctx.cwd.statNoFollow(path_destinaton_backup)) |backup_stat| {
                    const trash_path = try ctx.cwd.trash(ctx.arena, path_destinaton_backup, backup_stat.kind);
                    undo.clobber_backup_trash_path = try ctx.cwd.realpathZ(ctx.arena, trash_path);
                    undo.clobber_backup_trashinfo_path = try util.clobber_undo.trashinfoPathFor(ctx.arena, ctx.cwd, trash_path);
                    if (!ctx.flag_silent) try ctx.reporter.pushWarning("trashed: {s} > $trash/{s}", .{ path_destinaton_backup, basename(trash_path) });
                }
                try ctx.cwd.move(real_dest_path, path_destinaton_backup);
                if (!ctx.flag_silent) try ctx.reporter.pushWarning("backup created: {s}", .{path_destinaton_backup});
            },
        }
    }
    try ctx.cwd.move(src_path, real_dest_path);
    if (!ctx.flag_silent) {
        util.log("{s} > {s}", .{ src_path, real_dest_path });
    }
    return undo;
}

fn persistUndoLog(allocator: Allocator, undo_files: []const MoveUndoData) void {
    const log_path = util.UndoLog.logPath(allocator, "move-undo.zon") catch return;
    const was_reset = MoveUndoLog.appendAndSave(allocator, log_path, undo_files) catch false;
    if (was_reset) util.log("warning: undo history was corrupt and has been reset", .{});
}

pub fn undoMove(ctx: *Context) !void {
    const log_path = try util.UndoLog.logPath(ctx.arena, "move-undo.zon");
    const entries = MoveUndoLog.read(ctx.arena, log_path) catch |err| switch (err) {
        error.UndoLogCorrupt => {
            try MoveUndoLog.write(log_path, &.{});
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
        if (try ctx.cwd.statNoFollow(file.dest_path) == null) {
            try ctx.reporter.pushError("undo failed: dest file missing: {s}", .{file.dest_path});
            preflight_ok = false;
        }
        if (try ctx.cwd.statNoFollow(file.src_path) != null) {
            try ctx.reporter.pushError("undo failed: original location occupied: {s}", .{file.src_path});
            preflight_ok = false;
        }
        const clobber = ClobberInfo{
            .clobber_trash_path = file.clobber_trash_path,
            .clobber_trashinfo_path = file.clobber_trashinfo_path,
            .clobber_backup_path = file.clobber_backup_path,
            .clobber_backup_trash_path = file.clobber_backup_trash_path,
            .clobber_backup_trashinfo_path = file.clobber_backup_trashinfo_path,
        };
        if (try util.clobber_undo.preflight(ctx.cwd, clobber)) |missing| {
            try ctx.reporter.pushError("undo failed: clobber path missing: {s}", .{missing});
            preflight_ok = false;
        }
        if (dirname(file.src_path)) |parent| {
            const parent_stat = try ctx.cwd.statNoFollow(parent);
            if (parent_stat == null or parent_stat.?.kind != .directory) {
                try ctx.reporter.pushError("undo failed: parent directory missing: {s}", .{parent});
                preflight_ok = false;
            }
        }
        if (clobber.hasClobber()) {
            if (dirname(file.dest_path)) |parent| {
                const parent_stat = try ctx.cwd.statNoFollow(parent);
                if (parent_stat == null or parent_stat.?.kind != .directory) {
                    try ctx.reporter.pushError("undo failed: clobber restore parent missing: {s}", .{parent});
                    preflight_ok = false;
                }
            }
        }
    }
    if (!preflight_ok) {
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    // Execute: move dest back to src, then reverse clobber.
    for (files) |file| {
        try ctx.cwd.move(file.dest_path, file.src_path);
        const clobber = ClobberInfo{
            .clobber_trash_path = file.clobber_trash_path,
            .clobber_trashinfo_path = file.clobber_trashinfo_path,
            .clobber_backup_path = file.clobber_backup_path,
            .clobber_backup_trash_path = file.clobber_backup_trash_path,
            .clobber_backup_trashinfo_path = file.clobber_backup_trashinfo_path,
        };
        try util.clobber_undo.execute(ctx.cwd, file.dest_path, clobber);
        if (!ctx.flag_silent) util.log("restored: {s}", .{file.src_path});
    }

    // Remove the entry from the log only after successful undo.
    try MoveUndoLog.write(log_path, entries[0 .. entries.len - 1]);
}

const Context = struct {
    arena: Allocator,
    reporter: Reporter,
    cwd: WorkDir,

    args: util.ArgIterator = undefined,
    positionals: [][:0]const u8 = undefined,
    flag_help: bool = false,
    flag_version: bool = false,
    flag_undo: bool = false,
    flag_rename: bool = false,
    flag_silent: bool = false,
    flag_clobber_style: util.ClobberStyle = .NoClobber,
    flag_parser: FlagParser = .{
        .parseFn = Context.implParseFn,
        .setProgramPathFn = FlagParser.noopSetProgramPath,
        .setArgIteratorFn = FlagParser.autoSetArgIterator(Context, "flag_parser", "args"),
        .setPositionalListFn = FlagParser.autoSetPositionalList(Context, "flag_parser", "positionals"),
    },

    pub fn init(arena: Allocator) !Context {
        const reporter = Reporter.init(arena);
        const work_dir = WorkDir.cwd();
        var result: Context = .{
            .arena = arena,
            .cwd = work_dir,
            .reporter = reporter,
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

    pub const Flags = enum {
        @"--help",
        h,
        @"--version",
        v,
        @"--undo",
        u,
        @"--trash",
        t,
        @"--backup",
        b,
        @"--rename",
        r,
        @"--silent",
        s,
    };

    pub fn implParseFn(flag_parser: *FlagParser, arg: [:0]const u8, _: *util.ArgIterator) FlagParser.Error!FlagParser.ArgType {
        var self: *Context = @fieldParentPtr("flag_parser", flag_parser);
        var flag_iter = util.FlagIterator(Flags).init(arg);
        while (flag_iter.next()) |result| {
            switch (result) {
                .Flag => |flag| switch (flag) {
                    .h, .@"--help" => self.flag_help = true,
                    .v, .@"--version" => self.flag_version = true,
                    .u, .@"--undo" => self.flag_undo = true,
                    .s, .@"--silent" => self.flag_silent = true,
                    .r, .@"--rename" => self.flag_rename = true,
                    .t, .@"--trash" => self.flag_clobber_style.prioritySet(.Trash),
                    .b, .@"--backup" => self.flag_clobber_style.prioritySet(.Backup),
                },
                .UnknownLong => |unknown| {
                    try self.reporter.pushError("unknown long flag: {s}", .{unknown});
                },
                .UnknownShort => |unknown| {
                    try self.reporter.pushError("unknown short flag: -{c}", .{unknown});
                },
            }
        }
        if (flag_iter.isFlag()) return .NotPositional;
        return .Positional;
    }
};
