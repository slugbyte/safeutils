const std = @import("std");
const util = @import("util");
const builtin = @import("builtin");
const build_option = @import("build_option");

const path = std.fs.path;
const Allocator = std.mem.Allocator;
const FlagParser = util.FlagParser;
const FlagIterator = util.FlagIterator;
const ArgIterator = util.ArgIterator;
const ClobberInfo = util.clobber_undo.ClobberInfo;

const CopyUndoKind = enum {
    file,
    directory,
    sym_link,
};

const CopyUndoData = struct {
    dest_path: []const u8,
    kind: CopyUndoKind,
    dir_created: bool,
    clobber_trash_path: []const u8,
    clobber_trashinfo_path: []const u8,
    clobber_backup_path: []const u8,
    clobber_backup_trash_path: []const u8,
    clobber_backup_trashinfo_path: []const u8,
};

const CopyUndoLog = util.UndoLog.UndoLog(CopyUndoData);

// VALIDATE SRC INPUT
// VALIDATE DEST
// CLOBBER IF NEEDED
// EXECUTE

pub const help_msg =
    \\Usage: copy src.. dest (--flags)
    \\  Copy a files and a directories.
    \\
    \\  -u --undo            undo the most recent copy operation
    \\
    \\  -d --dir             dirs copy recursively, and clobber conflicts
    \\  -m --merge           dirs copy recursively, but src_dirs dont clobber dest_dirs
    \\  -t --trash           trash conflicting files
    \\  -c --create          create dest dir if not exists
    \\  -b --backup          backup conflicting files
    \\
    \\  -s --silent          only print errors
    \\  -v --version         print this version
    \\  -h --help            print this help
    \\ 
    \\  EXAMPLES:
    \\  copy boom.zig bap.zig     Copy boom.zig to bap.zig
    \\  copy -dt util src         Copy util to src (trash src if exists)
    \\  copy -db util src/        Copy util to src/util (backup src/util if exists)
    \\  copy -m util test src     Merge util and test dirs into src dir (error if conflicts)
    \\  copy -mt util test src/   Copy test and util into src (src/util src/test) (trash non dir-on-dir conflicts)
    \\  copy -c **.png img        Create img dir and put all the pngs in it.      
;

pub fn main() !void {
    // Arena intentionally not freed -- OS reclaims on process exit
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ctx = try Context.init(arena_instance.allocator());
    if (ctx.reporter.isError() or ctx.reporter.isWarning()) {
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
        util.log("copy version: ({s}) {s} {s} -- '{s}'", .{
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
        return undoCopy(&ctx);
    }

    if (ctx.positionals.len <= 1) {
        logUsage();
        return;
    }

    const src_input = ctx.positionals[0 .. ctx.positionals.len - 1];
    const dest_input = ctx.positionals[ctx.positionals.len - 1];

    const should_join_src_to_dest = try resolveDestination(&ctx, src_input, dest_input);
    if (ctx.reporter.isError()) {
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    const copy_list = try expandSources(&ctx, src_input, dest_input, should_join_src_to_dest);
    try checkConflicts(&ctx, copy_list, src_input, should_join_src_to_dest);
    if (ctx.reporter.isError()) {
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    const clobber_results = try clobberDestinations(&ctx, copy_list, dest_input);
    if (ctx.reporter.isError()) {
        ctx.reporter.report();
        if (ctx.fail_clobber) {
            util.log("clobber flag required (--trash --backup)", .{});
        }
        std.process.exit(1);
    }

    const dir_created_list = try performCopies(&ctx, copy_list);

    // Persist undo log on success.
    persistUndoLog(&ctx, copy_list, clobber_results, dir_created_list);

    ctx.reporter.EXIT_WITH_REPORT(0);
}

/// Resolve the destination path: check existence, create with --create,
/// and determine whether src basenames should be joined onto dest.
fn resolveDestination(ctx: *Context, src_input: [][:0]const u8, dest_input: [:0]const u8) !bool {
    var should_join_src_to_dest = false;

    const dest_stat = if (ctx.flag_dir_style == .Merge)
        try ctx.cwd.stat(dest_input)
    else
        try ctx.cwd.statNoFollow(dest_input);

    if (dest_stat) |stat| {
        if (ctx.flag_create) {
            ctx.flag_create = false;
        }
        if (stat.kind == .directory) {
            if (util.endsWith(dest_input, "/")) {
                should_join_src_to_dest = true;
            } else {
                if (ctx.flag_dir_style != .Merge and ctx.flag_clobber_style == .NoClobber) {
                    try ctx.reporter.pushError("use clobber flags or add '/' to copy into dir", .{});
                }
            }
        } else {
            if (src_input.len > 1 and ctx.flag_dir_style != .Merge) {
                try ctx.reporter.pushError("to copy multiple src files dest must be a dir", .{});
            }
        }
    } else {
        if (ctx.flag_create) {
            try ctx.cwd.dir.makePath(dest_input);
            should_join_src_to_dest = true;
            ctx.flag_create = false;
        } else {
            if (src_input.len > 1 and ctx.flag_dir_style != .Merge) {
                try ctx.reporter.pushError("to copy multiple src files dest must be a dir", .{});
            }
        }
    }

    return should_join_src_to_dest;
}

/// Expand src paths into a flat list of copy operations, walking
/// directories recursively when --dir or --merge is set.
fn expandSources(ctx: *Context, src_input: [][:0]const u8, dest_input: [:0]const u8, should_join_src_to_dest: bool) ![]CopyItem {
    var copy_list = try std.ArrayList(CopyItem).initCapacity(ctx.arena, src_input.len);

    for (src_input) |src_path| {
        if (try ctx.cwd.statNoFollow(src_path)) |src_stat| {
            switch (src_stat.kind) {
                .directory, .file, .sym_link => {},
                else => {
                    try ctx.reporter.pushError("file type not supported [{t}]: ({s})", .{ src_stat.kind, src_path });
                    continue;
                },
            }
            const dest_name = dest: {
                if (should_join_src_to_dest) {
                    break :dest try ctx.cwd.realpathZ(ctx.arena, try path.joinZ(ctx.arena, &.{ dest_input, path.basename(src_path) }));
                } else {
                    break :dest try ctx.cwd.realpathZ(ctx.arena, dest_input);
                }
            };
            try copy_list.append(ctx.arena, .{
                .src = src_path,
                .dest = dest_name,
                .kind = src_stat.kind,
            });
            if (src_stat.kind == .directory) {
                if (ctx.flag_dir_style == .NoCopy) {
                    try ctx.reporter.pushError("copy dir requires --dir or --merge: ({s})", .{src_path});
                    continue;
                }
                var dir = try ctx.cwd.dir.openDir(src_path, .{ .iterate = true });
                defer dir.close();
                var walker = try dir.walk(ctx.arena);
                while (try walker.next()) |item| {
                    switch (item.kind) {
                        .file, .directory, .sym_link => {
                            try copy_list.append(ctx.arena, .{
                                .kind = item.kind,
                                .src = try path.joinZ(ctx.arena, &.{ src_path, item.path }),
                                .dest = try path.joinZ(ctx.arena, &.{ dest_name, item.path }),
                            });
                        },
                        else => {
                            try ctx.reporter.pushError("file type not supported [{t}]: ({s})", .{
                                item.kind,
                                try path.joinZ(ctx.arena, &.{ src_path, item.path }),
                            });
                        },
                    }
                }
            }
        } else {
            try ctx.reporter.pushError("src file not found: {s}", .{src_path});
        }
    }

    return copy_list.items;
}

/// Check for dir/merge constraint violations, conflicting destinations,
/// and self-copy attempts.
fn checkConflicts(ctx: *Context, copy_list: []const CopyItem, src_input: [][:0]const u8, should_join_src_to_dest: bool) !void {
    var dir_count: usize = 0;
    for (copy_list) |item| {
        if (item.kind == .directory) dir_count += 1;
    }

    if (ctx.flag_dir_style == .Dir and ctx.flag_clobber_style != .NoClobber and !should_join_src_to_dest and src_input.len > 1) {
        try ctx.reporter.pushError("--dir can only have one src file if dest is clobbered. add '/' or use --merge", .{});
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    // QUESTION: maby i should limit merge dirs clobbering dest to 1? when would this even be useful? seems foot-gunny
    if (ctx.flag_dir_style == .Merge and !should_join_src_to_dest and src_input.len != dir_count) {
        try ctx.reporter.pushError("merge only works if all src paths are dirs", .{});
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    for (copy_list, 0..) |item_a, i| {
        for (copy_list[i + 1 ..]) |item_b| {
            if (try ctx.cwd.isPathSameLocation(item_a.dest, item_b.dest)) {
                try ctx.reporter.pushError("src items have conflicting destination: {s} and {s}", .{ item_a.src, item_b.src });
            }
        }
    }
    if (ctx.reporter.isError()) {
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    for (copy_list) |item| {
        if (try ctx.cwd.isPathSameLocation(item.src, item.dest)) {
            try ctx.reporter.pushError("item cannot be copied to itself: ({s})", .{item.src});
        }
    }
}

/// Trash or backup existing destination paths, then create dest dir if needed.
/// Returns per-item clobber metadata for undo recording.
fn clobberDestinations(ctx: *Context, copy_list: []const CopyItem, dest_input: [:0]const u8) ![]ClobberInfo {
    var results = try std.ArrayList(ClobberInfo).initCapacity(ctx.arena, copy_list.len);
    for (copy_list) |item| {
        try results.append(ctx.arena, try clobber(ctx, item.dest, item.kind));
    }

    if (ctx.flag_create) {
        ctx.cwd.dir.makePath(dest_input) catch {};
    }
    return results.items;
}

/// Perform all file, directory, and symlink copy operations.
/// Returns a per-item boolean indicating whether each directory was created
/// (true) or pre-existed (false). Non-directory items are always false.
fn performCopies(ctx: *Context, copy_list: []const CopyItem) ![]bool {
    var dir_created_list = try ctx.arena.alloc(bool, copy_list.len);
    for (copy_list, 0..) |item, i| {
        if (!ctx.flag_silent) util.log("{s} -> {s}", .{ item.src, item.dest });
        dir_created_list[i] = false;
        switch (item.kind) {
            .file => try copyFile(ctx, item),
            .directory => {
                const existed = try ctx.cwd.exists(item.dest);
                try copyDir(ctx, item);
                dir_created_list[i] = !existed;
            },
            .sym_link => try copySymLink(ctx, item),
            else => unreachable,
        }
    }
    return dir_created_list;
}

const CopyItem = struct {
    src: [:0]const u8,
    dest: [:0]const u8,
    kind: std.fs.File.Kind,
};

inline fn copyFile(ctx: *Context, item: CopyItem) !void {
    util.assert(item.kind == .file);
    try ctx.cwd.dir.copyFile(item.src, ctx.cwd.dir, item.dest, .{});
}

inline fn copySymLink(ctx: *Context, item: CopyItem) !void {
    util.assert(item.kind == .sym_link);
    var link_buffer: util.FilepathBuffer = undefined;
    const link = try ctx.cwd.dir.readLink(item.src, &link_buffer);
    try ctx.cwd.dir.symLink(link, item.dest, .{});
}

inline fn copyDir(ctx: *Context, item: CopyItem) !void {
    util.assert(item.kind == .directory);
    ctx.cwd.dir.makeDir(item.dest) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if (ctx.flag_dir_style != .Merge) {
                return err;
            }
        },
        else => return err,
    };
}

pub fn clobber(ctx: *Context, clobber_path: []const u8, src_kind: std.fs.File.Kind) !ClobberInfo {
    var result = ClobberInfo{};
    if (try ctx.cwd.statNoFollow(clobber_path)) |stat| {
        // In merge mode, only dir-on-dir conflicts are merged. All other
        // combinations (file->dir, link->dir, etc.) follow normal clobber rules.
        const is_merge_dir = ctx.flag_dir_style == .Merge and stat.kind == .directory and src_kind == .directory;
        switch (ctx.flag_clobber_style) {
            .NoClobber => {
                if (!is_merge_dir) {
                    try ctx.reporter.pushError("dest path exists: ({s})", .{clobber_path});
                    ctx.fail_clobber = true;
                }
            },
            .Trash => {
                if (!is_merge_dir) {
                    const trashpath = try ctx.cwd.trash(ctx.arena, clobber_path, stat.kind);
                    result.clobber_trash_path = try ctx.cwd.realpathZ(ctx.arena, trashpath);
                    result.clobber_trashinfo_path = try util.clobber_undo.trashinfoPathFor(ctx.arena, ctx.cwd, trashpath);
                    try ctx.reporter.pushWarning("trashed: $trash/{s}", .{path.basename(trashpath)});
                }
            },
            .Backup => {
                if (!is_merge_dir) {
                    const backup_path = try util.fmt(ctx.arena, "{s}.backup~", .{clobber_path});
                    result.clobber_backup_path = try ctx.cwd.realpathZ(ctx.arena, backup_path);
                    if (try ctx.cwd.statNoFollow(backup_path)) |backup_stat| {
                        const trashpath = try ctx.cwd.trash(ctx.arena, backup_path, backup_stat.kind);
                        result.clobber_backup_trash_path = try ctx.cwd.realpathZ(ctx.arena, trashpath);
                        result.clobber_backup_trashinfo_path = try util.clobber_undo.trashinfoPathFor(ctx.arena, ctx.cwd, trashpath);
                        try ctx.reporter.pushWarning("trashed: $trash/{s}", .{path.basename(trashpath)});
                    }
                    try ctx.cwd.move(clobber_path, backup_path);
                    try ctx.reporter.pushWarning("backup: {s}", .{backup_path});
                }
            },
        }
    }
    return result;
}

fn toCopyUndoKind(kind: std.fs.File.Kind) CopyUndoKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .sym_link,
        else => unreachable,
    };
}

fn persistUndoLog(ctx: *Context, copy_list: []const CopyItem, clobber_results: []const ClobberInfo, dir_created_list: []const bool) void {
    util.assert(copy_list.len == clobber_results.len);
    util.assert(copy_list.len == dir_created_list.len);
    var undo_list = std.ArrayList(CopyUndoData).initCapacity(ctx.arena, copy_list.len) catch return;
    for (copy_list, 0..) |item, i| {
        const abs_dest = ctx.cwd.realpathZ(ctx.arena, item.dest) catch return;
        const cr = clobber_results[i];
        undo_list.append(ctx.arena, .{
            .dest_path = abs_dest,
            .kind = toCopyUndoKind(item.kind),
            .dir_created = dir_created_list[i],
            .clobber_trash_path = cr.clobber_trash_path,
            .clobber_trashinfo_path = cr.clobber_trashinfo_path,
            .clobber_backup_path = cr.clobber_backup_path,
            .clobber_backup_trash_path = cr.clobber_backup_trash_path,
            .clobber_backup_trashinfo_path = cr.clobber_backup_trashinfo_path,
        }) catch return;
    }
    const log_path = util.UndoLog.logPath(ctx.arena, "copy-undo.zon") catch return;
    const was_reset = CopyUndoLog.appendAndSave(ctx.arena, log_path, undo_list.items) catch false;
    if (was_reset) util.log("warning: undo history was corrupt and has been reset", .{});
}

pub fn undoCopy(ctx: *Context) !void {
    const log_path = try util.UndoLog.logPath(ctx.arena, "copy-undo.zon");
    const entries = CopyUndoLog.read(ctx.arena, log_path) catch |err| switch (err) {
        error.UndoLogCorrupt => {
            try CopyUndoLog.write(log_path, &.{});
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

    // Pre-flight: validate every dest file/symlink still exists and clobber paths are intact.
    var preflight_ok = true;
    for (files) |file| {
        if (file.kind != .directory) {
            if (try ctx.cwd.statNoFollow(file.dest_path) == null) {
                try ctx.reporter.pushError("undo failed: dest file missing: {s}", .{file.dest_path});
                preflight_ok = false;
            }
        }
        const clobber_info = ClobberInfo{
            .clobber_trash_path = file.clobber_trash_path,
            .clobber_trashinfo_path = file.clobber_trashinfo_path,
            .clobber_backup_path = file.clobber_backup_path,
            .clobber_backup_trash_path = file.clobber_backup_trash_path,
            .clobber_backup_trashinfo_path = file.clobber_backup_trashinfo_path,
        };
        if (try util.clobber_undo.preflight(ctx.cwd, clobber_info)) |missing| {
            try ctx.reporter.pushError("undo failed: clobber path missing: {s}", .{missing});
            preflight_ok = false;
        }
        if (clobber_info.hasClobber()) {
            if (std.fs.path.dirname(file.dest_path)) |parent| {
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

    // Step 1: Delete copied files and symlinks.
    for (files) |file| {
        if (file.kind == .file or file.kind == .sym_link) {
            ctx.cwd.dir.deleteFile(file.dest_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    // Step 2: Delete dir_created directories deepest-first (reverse order).
    var i = files.len;
    while (i > 0) {
        i -= 1;
        const file = files[i];
        if (file.kind == .directory and file.dir_created) {
            ctx.cwd.dir.deleteDir(file.dest_path) catch |err| switch (err) {
                error.DirNotEmpty => {
                    if (!ctx.flag_silent) util.log("warning: directory not empty, skipped: {s}", .{file.dest_path});
                },
                else => return err,
            };
        }
    }

    // Step 3: Reverse clobber for all items.
    for (files) |file| {
        const clobber_info = ClobberInfo{
            .clobber_trash_path = file.clobber_trash_path,
            .clobber_trashinfo_path = file.clobber_trashinfo_path,
            .clobber_backup_path = file.clobber_backup_path,
            .clobber_backup_trash_path = file.clobber_backup_trash_path,
            .clobber_backup_trashinfo_path = file.clobber_backup_trashinfo_path,
        };
        if (clobber_info.hasClobber()) {
            try util.clobber_undo.execute(ctx.cwd, file.dest_path, clobber_info);
        }
    }

    // Remove the entry from the log only after successful undo.
    try CopyUndoLog.write(log_path, entries[0 .. entries.len - 1]);

    if (!ctx.flag_silent) util.log("undo complete", .{});
}

pub fn logUsage() void {
    util.log("USAGE: copy src.. dest (--flags)", .{});
}

pub const Context = struct {
    arena: Allocator,
    cwd: util.WorkDir,
    reporter: util.Reporter,

    args: ArgIterator = undefined,
    positionals: [][:0]const u8 = undefined,
    fail_clobber: bool = false,
    flag_help: bool = false,
    flag_version: bool = false,
    flag_undo: bool = false,
    flag_silent: bool = false,
    flag_dir_style: DirStyle = .NoCopy,
    flag_clobber_style: util.ClobberStyle = .NoClobber,
    flag_create: bool = false,
    flag_parser: FlagParser = .{
        .parseFn = implParseFn,
        .setArgIteratorFn = FlagParser.autoSetArgIterator(Context, "flag_parser", "args"),
        .setPositionalListFn = FlagParser.autoSetPositionalList(Context, "flag_parser", "positionals"),
        .setProgramPathFn = FlagParser.noopSetProgramPath,
    },

    pub fn init(arena: Allocator) !Context {
        var result: Context = .{
            .arena = arena,
            .cwd = util.WorkDir.cwd(),
            .reporter = util.Reporter.init(arena),
        };
        try FlagParser.parseProcessArgs(&result.flag_parser, result.arena);
        if (builtin.mode == .Debug) {
            util.log("**************************************************************", .{});
            util.debugPrintArgIterator(&result.args, "args:", true);
            util.debugPrintPositionalList(result.positionals, "positionals:");
            util.debugPrintFlagFields(Context, result);
            util.log("**************************************************************", .{});
        }
        return result;
    }

    pub const DirStyle = enum(u8) {
        NoCopy = 0,
        Merge = 1,
        Dir = 2,

        /// greater priority wins
        pub fn setPriority(self: *DirStyle, value: DirStyle) void {
            if (@intFromEnum(value) > @intFromEnum(self.*)) {
                self.* = value;
            }
        }
    };

    const Flags = enum {
        @"--help",
        h,
        @"--version",
        v,
        @"--undo",
        u,
        @"--silent",
        s,
        @"--trash",
        t,
        @"--backup",
        b,
        @"--dir",
        d,
        @"--merge",
        m,
        @"--create",
        c,
    };

    pub fn implParseFn(flag_parser: *FlagParser, arg: []const u8, _: *ArgIterator) FlagParser.Error!FlagParser.ArgType {
        const self: *Context = @fieldParentPtr("flag_parser", flag_parser);
        var flag_iter = FlagIterator(Flags).init(arg);
        while (flag_iter.next()) |result| {
            switch (result) {
                .Flag => |flag| switch (flag) {
                    .h, .@"--help" => self.flag_help = true,
                    .v, .@"--version" => self.flag_version = true,
                    .u, .@"--undo" => self.flag_undo = true,
                    .s, .@"--silent" => self.flag_silent = true,
                    .c, .@"--create" => self.flag_create = true,
                    .t, .@"--trash" => self.flag_clobber_style.prioritySet(.Trash),
                    .b, .@"--backup" => self.flag_clobber_style.prioritySet(.Backup),
                    .d, .@"--dir" => self.flag_dir_style.setPriority(.Dir),
                    .m, .@"--merge" => self.flag_dir_style.setPriority(.Merge),
                },
                .UnknownLong => |unknown| {
                    try self.reporter.pushError("unknown flag: {s}", .{unknown});
                },
                .UnknownShort => |unknown| {
                    try self.reporter.pushError("unknown flag: -{c}", .{unknown});
                },
            }
        }

        if (flag_iter.isFlag()) return .NotPositional;
        return .Positional;
    }
};
