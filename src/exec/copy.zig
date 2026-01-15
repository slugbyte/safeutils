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

pub const help_msg =
    \\Usage: copy src.. dest (--flags)
    \\  Copy a files and a directories.
    \\  
    \\  -d --dir             dirs copy recursively, and cobber conflicts
    \\  -m --merge           dirs copy recursively, but src_dirs dont clobber dest_dirs
    \\  -t --trash           trash conflicting files
    \\  -c --create          create dest dir if not exists
    \\  -b --backup          backup conflicting files
    \\ 
    \\  -s --silent          only print errors
    \\  -v --version         print this version
    \\  -h --help            print this version
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
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ctx = try Context.init(arena_instance.allocator());
    if (ctx.reporter.isTrouble()) {
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    if (ctx.flag_help) {
        util.log("{s}", .{help_msg});
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

    switch (ctx.positionals.len) {
        0, 1 => {
            logUsage();
            return;
        },
        else => {
            var should_join_src_to_dest = false;
            const src_input = ctx.positionals[0 .. ctx.positionals.len - 1];
            const dest_input = ctx.positionals[ctx.positionals.len - 1];
            var copy_list = try std.ArrayList(CopyItem).initCapacity(ctx.arena, src_input.len);

            const dest_stat = try ctx.cwd.statNoFollow(dest_input);
            if (dest_stat) |stat| {
                if (ctx.flag_create) {
                    ctx.flag_create = false;
                }
                if (stat.kind == .directory) {
                    if (util.endsWith(dest_input, "/")) {
                        should_join_src_to_dest = true;
                    } else {
                        if (ctx.flag_clobber_style == .NoClobber) {
                            if (src_input.len > 1) {
                                try ctx.reporter.pushError("use clobber flags or add '/' to copy into dir", .{});
                            }
                        }
                    }
                } else {
                    if (src_input.len > 1 and ctx.flag_dir_style != .Merge) {
                        try ctx.reporter.pushError("to copy multiple src files dest must be a dir", .{});
                    }
                }
            } else {
                if (ctx.flag_create) {
                    try ctx.cwd.dir.makeDir(dest_input);
                    should_join_src_to_dest = true;
                } else {
                    if (src_input.len > 1 and ctx.flag_dir_style != .Merge) {
                        try ctx.reporter.pushError("to copy multiple src files dest must be a dir", .{});
                    }
                }
            }

            if (ctx.reporter.isError()) {
                ctx.reporter.EXIT_WITH_REPORT(1);
            }

            var dir_count: usize = 0;
            for (src_input) |src_path| {
                if (try ctx.cwd.statNoFollow(src_path)) |src_stat| {
                    switch (src_stat.kind) {
                        .directory => dir_count += 1,
                        .file,
                        .sym_link,
                        => {},
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
                        var walker = try dir.walk(ctx.arena);
                        while (try walker.next()) |item| {
                            try copy_list.append(ctx.arena, .{
                                .kind = item.kind,
                                .src = try path.joinZ(ctx.arena, &.{ src_path, item.path }),
                                .dest = try path.joinZ(ctx.arena, &.{ dest_name, item.path }),
                            });
                        }
                    }
                } else {
                    try ctx.reporter.pushError("src file not found: {s}", .{src_path});
                }
            }

            if (ctx.flag_dir_style == .Dir and ctx.flag_clobber_style != .NoClobber and !should_join_src_to_dest and src_input.len > 1) {
                try ctx.reporter.pushError("--dir can only have one src file if dest is clobbered. add '/' or user --merge", .{});
                try ctx.reporter.EXIT_WITH_REPORT(1);
            }

            // QUESTION: maby i should limit merge dirs clobbering dest to 1? when would this even be useful? seems foot-gunny
            if (ctx.flag_dir_style == .Merge and !should_join_src_to_dest and src_input.len != dir_count) {
                try ctx.reporter.pushError("merge only works if all src paths are dirs", .{});
                try ctx.reporter.EXIT_WITH_REPORT(1);
            }

            for (copy_list.items, 0..) |item_a, i| {
                for (copy_list.items[i + 1 ..]) |item_b| {
                    if (try ctx.cwd.isPathSameLocation(item_a.dest, item_b.dest)) {
                        try ctx.reporter.pushError("src items have conflicting destination: {s} and {s}", .{ item_a.src, item_b.src });
                    }
                }
            }
            if (ctx.reporter.isError()) {
                ctx.reporter.EXIT_WITH_REPORT(1);
            }

            for (copy_list.items) |item| {
                if (try ctx.cwd.isPathSameLocation(item.src, item.dest)) {
                    try ctx.reporter.pushError("item cannot be copyed to it self: ({s})", .{item.src});
                }
            }

            if (ctx.reporter.isError()) {
                ctx.reporter.EXIT_WITH_REPORT(1);
            }

            for (copy_list.items) |item| {
                try clobber(&ctx, item.dest);
            }

            if (ctx.flag_create) {
                ctx.cwd.dir.makeDir(dest_input) catch {};
            }

            if (ctx.reporter.isError()) {
                ctx.reporter.report();
                if (ctx.fail_clobber) {
                    util.log("clobber flag required (--trash --backup)", .{});
                }
                std.process.exit(1);
            }

            for (copy_list.items) |item| {
                util.log("{s} -> {s}", .{ item.src, item.dest });
                switch (item.kind) {
                    .file => try copyFile(&ctx, item),
                    .directory => try copyDir(&ctx, item),
                    .sym_link => try copySymLink(&ctx, item),
                    else => unreachable,
                }
            }
            ctx.reporter.EXIT_WITH_REPORT(0);
        },
    }
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

pub fn clobber(ctx: *Context, clobber_path: []const u8) !void {
    if (try ctx.cwd.statNoFollow(clobber_path)) |stat| {
        switch (ctx.flag_clobber_style) {
            .NoClobber => {
                if (stat.kind == .directory) {
                    if (ctx.flag_dir_style != .Merge) {
                        try ctx.reporter.pushError("dest path exists: ({s})", .{clobber_path});
                        ctx.fail_clobber = true;
                    }
                } else {
                    try ctx.reporter.pushError("dest path exists: ({s})", .{clobber_path});
                    ctx.fail_clobber = true;
                }
            },
            .Trash => {
                if (stat.kind != .directory or ctx.flag_dir_style != .Merge) {
                    const trashpath = try ctx.cwd.trash(ctx.arena, clobber_path, stat.kind);
                    try ctx.reporter.pushWarning("trashed: $trash/{s}", .{path.basename(trashpath)});
                }
            },
            .Backup => {
                if (stat.kind != .directory or ctx.flag_dir_style != .Merge) {
                    const backup_path = try util.fmt(ctx.arena, "{s}.backup~", .{clobber_path});
                    if (try ctx.cwd.stat(backup_path)) |backup_stat| {
                        const trashpath = try ctx.cwd.trash(ctx.arena, backup_path, backup_stat.kind);
                        try ctx.reporter.pushWarning("trashed: $trash/{s}", .{path.basename(trashpath)});
                    }
                    try ctx.cwd.move(clobber_path, backup_path);
                    try ctx.reporter.pushWarning("backup: {s}", .{backup_path});
                }
            },
        }
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
    fail_clobber: bool = false,
    flag_help: bool = false,
    flag_version: bool = false,
    flag_silent: bool = false,
    flag_dir_style: DirStyle = .NoCopy,
    flag_clobber_style: ClobberStyle = .NoClobber,
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
                    .s, .@"--silent" => self.flag_silent = true,
                    .c, .@"--create" => self.flag_create = true,
                    .t, .@"--trash" => self.flag_clobber_style.setPriortity(.Trash),
                    .b, .@"--backup" => self.flag_clobber_style.setPriortity(.Backup),
                    .d, .@"--dir" => self.flag_dir_style.setPriortity(.Dir),
                    .m, .@"--merge" => self.flag_dir_style.setPriortity(.Merge),
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
