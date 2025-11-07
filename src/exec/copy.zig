const std = @import("std");
const util = @import("util");
const builtin = @import("builtin");
const build_option = @import("build_option");

const path = std.fs.path;
const Allocator = std.mem.Allocator;
const FlagParser = util.FlagParser;
const FlagIterator = util.FlagIterator;
const ArgIterator = util.ArgIterator;

// VALIDATE SRC INPUT
// VALIDATE DEST
// CLOBBER IF NEEDED
// EXECUTE

const help =
    \\Usage: copy src.. dest (--flags)
    \\  Copy a file, multiple files, or a directory to a destination.
    \\  When copying files into a directory dest must have a '/' at the end.
    \\  
    \\  -d --dir             dirs copy recursively, and clbber dest on conflict (dirs and files clobber)
    \\  -m --merge           dirs copy recursively, and merge with dest dirs on confilct (only file cloober)
    \\  -t --trash           trash conflicting files
    \\  -b --backup          backup conflicting files
;

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ctx = try Context.init(arena_instance.allocator());
    if (ctx.reporter.isTrouble()) {
        logUsage();
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    if (ctx.flag_help) {}

    switch (ctx.positionals.len) {
        0, 1 => {
            logUsage();
            return;
        },
        2 => {
            const src_path: []const u8 = ctx.positionals[0][0..];
            const src_stat = (try ctx.cwd.statNoFollow(src_path)) orelse {
                @panic("src need to exists");
            };
            switch (src_stat.kind) {
                .file, .directory, .sym_link => {},
                else => @panic("todo better error handling for non supported file"),
            }
            var dest_path: []const u8 = ctx.positionals[1][0..];
            var dest_stat = try ctx.cwd.statNoFollow(dest_path);
            if (dest_stat) |stat| {
                if (stat.kind == .directory) {
                    if (util.endsWith(dest_path, "/")) {
                        dest_path = try path.join(ctx.arena, &.{
                            dest_path,
                            path.basename(src_path),
                        });
                        dest_stat = try ctx.cwd.statNoFollow(dest_path);
                    } else {}
                }
            } else {
                //TODO: --c --create-dest crete dir and update src paths

            }

            if (dest_stat) |stat| {
                try handleClobber(&ctx, dest_path, stat);
            }

            try copyRecursive(&ctx, .{
                .src = src_path,
                .dest = dest_path,
                .stat = src_stat,
            });
            ctx.reporter.EXIT_WITH_REPORT(0);
        },
        else => {
            @panic("todo copy more than one src");
        },
    }
}

const SrcPath = struct {
    src: []const u8,
    stat: ?std.fs.File.Stat,
};

const CopyPath = struct {
    src: []const u8,
    dest: []const u8,
    stat: std.fs.File.Stat,
};

pub fn copyRecursive(ctx: *Context, copy_path: CopyPath) !void {
    switch (copy_path.stat.kind) {
        .file => try copyFile(ctx, copy_path),
        .directory => try copyDirRecursive(ctx, copy_path),
        .sym_link => try copySymLink(ctx, copy_path),
        else => unreachable,
    }
}

pub fn copyNoRecursive(ctx: *Context, copy_path: CopyPath) !void {
    switch (copy_path.stat.kind) {
        .file => try copyFile(ctx, copy_path),
        .directory => try copyDir(ctx, copy_path),
        .sym_link => try copySymLink(ctx, copy_path),
        else => unreachable,
    }
}

inline fn copyFile(ctx: *Context, copy_path: CopyPath) !void {
    util.assert(copy_path.stat.kind == .file);
    try ctx.cwd.dir.copyFile(copy_path.src, ctx.cwd.dir, copy_path.dest, .{});
}

inline fn copySymLink(ctx: *Context, copy_path: CopyPath) !void {
    util.assert(copy_path.stat.kind == .sym_link);
    var link_buffer: util.FilepathBuffer = undefined;
    const link = try ctx.cwd.dir.readLink(copy_path.src, &link_buffer);
    try ctx.cwd.dir.symLink(link, copy_path.dest, .{});
}

inline fn copyDir(ctx: *Context, copy_path: CopyPath) !void {
    util.assert(copy_path.stat.kind == .directory);
    ctx.cwd.dir.makeDir(copy_path.dest) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if (ctx.flag_dir_style != .Merge) {
                return err;
            }
        },
        else => return err,
    };
}

pub fn copyDirRecursive(ctx: *Context, copy_path: CopyPath) !void {
    util.assert(copy_path.stat.kind == .directory);
    var src_path_list = std.ArrayList(CopyPath).empty;
    try src_path_list.append(ctx.arena, copy_path);
    const src_dir = try ctx.cwd.dir.openDir(copy_path.src, .{ .iterate = true });
    var walker = try src_dir.walk(ctx.arena);
    while (try walker.next()) |dir_item| {
        const src = try path.join(ctx.arena, &.{ copy_path.src, dir_item.path });
        const dest = try path.join(ctx.arena, &.{ copy_path.dest, dir_item.path });
        const stat = try ctx.cwd.statNoFollow(src) orelse unreachable;
        try src_path_list.append(ctx.arena, .{
            .src = src,
            .dest = dest,
            .stat = stat,
        });
    }
    for (src_path_list.items) |item| {
        try copyNoRecursive(ctx, item);
    }
}

pub fn handleClobber(ctx: *Context, clobber_path: []const u8, clobber_stat: std.fs.File.Stat) !void {
    switch (ctx.flag_clobber_style) {
        .NoClobber => {
            if (clobber_stat.kind == .directory) {
                if (ctx.flag_dir_style != .Merge) {
                    try ctx.reporter.pushError("dest dir exists, add '/' or clobber flag: ({s})", .{clobber_path});
                    ctx.reporter.EXIT_WITH_REPORT(1);
                }
            } else {
                try ctx.reporter.pushError("dest path exsist choose clobber flag: ({s})", .{clobber_path});
                ctx.reporter.EXIT_WITH_REPORT(1);
            }
        },
        .Trash => {
            const trashpath = try ctx.cwd.trash(ctx.arena, clobber_path, clobber_stat.kind);
            try ctx.reporter.pushWarning("trashed: $trash/{s}", .{path.basename(trashpath)});
        },
        .Backup => {
            const backup_path = try util.fmt(ctx.arena, "{s}.backup~", .{clobber_path});
            if (try ctx.cwd.stat(backup_path)) |backup_stat| {
                const trashpath = try ctx.cwd.trash(ctx.arena, backup_path, backup_stat.kind);
                try ctx.reporter.pushWarning("trashed: $trash/{s}", .{path.basename(trashpath)});
            }
            try ctx.cwd.move(clobber_path, backup_path);
            try ctx.reporter.pushWarning("backup: {s}", .{backup_path});
        },
    }
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
    flag_help: bool = false,
    flag_version: bool = false,
    flag_silent: bool = false,
    flag_dir_style: DirStyle = .NoCopy,
    flag_clobber_style: ClobberStyle = .NoClobber,
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

        /// greater priorty wins
        pub fn setPriortity(self: *DirStyle, value: DirStyle) void {
            if (@intFromEnum(value) > @intFromEnum(self.*)) {
                self.* = value;
            }
        }
    };

    pub const ClobberStyle = enum(u8) {
        NoClobber = 0,
        Trash = 1,
        Backup = 2,

        /// greater priorty wins
        pub fn setPriortity(self: *ClobberStyle, value: ClobberStyle) void {
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
    };

    pub fn implParseFn(flag_parser: *FlagParser, arg: []const u8, _: *ArgIterator) FlagParser.Error!FlagParser.ArgType {
        const self: *Context = @fieldParentPtr("flag_parser", flag_parser);
        var flag_iter = FlagIterator(Flags).init(arg);
        while (flag_iter.next()) |result| {
            switch (result) {
                .Flag => |flag| switch (flag) {
                    .h, .@"--help" => self.flag_help = true,
                    .v, .@"--version" => self.flag_version = true,
                    .s, .@"--silent" => self.flag_silent = true,
                    .t, .@"--trash" => self.flag_clobber_style.setPriortity(.Trash),
                    .b, .@"--backup" => self.flag_clobber_style.setPriortity(.Backup),
                    .d, .@"--dir" => self.flag_dir_style.setPriortity(.Dir),
                    .m, .@"--merge" => self.flag_dir_style.setPriortity(.Merge),
                },
                .UnknownLong => |unknown| {
                    util.log("unknown short: {s}", .{unknown});
                },
                .UnknownShort => |unknown| {
                    util.log("unknown short: {c}", .{unknown});
                },
            }
        }

        if (flag_iter.isFlag()) return .NotPositional;
        return .Positional;
    }
};
