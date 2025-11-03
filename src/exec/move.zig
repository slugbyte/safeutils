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

pub const help_msg =
    \\Usage: move src.. dest (--flags)
    \\  Move or rename a file, or move multiple files into a directory.
    \\  When moveing files into a directory dest must have '/' at the end.
    \\  When moving multiple files last path must be a directory and have a '/' at the end.
    \\
    \\  Move will not partially move src.. paths. Everyting must move or nothing will move.
    \\
    \\  Clobber Style:
    \\    (default)  error with warning
    \\    -t --trash    move to $trash
    \\    -b --backup   rename the dest file
    \\
    \\    If mulitiple clober flags the presidence is (backup > trash > no clobber).
    \\  
    \\  Other Flags:
    \\    --version     print version
    \\    -r --rename   just replace the basename with dest
    \\    -s --silent   only print errors
    \\    -h --help     print this help
;

pub fn main() !void {
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
        std.process.exit(1);
    }

    if (ctx.flag_version) {
        util.log("move version: ({s}) {s} {s} -- '{s}'", .{
            build_option.date,
            build_option.change_id[0..8],
            build_option.commit_id[0..8],
            build_option.description,
        });
        return;
    }

    switch (ctx.positionals.len) {
        0, 1 => {
            util.log("USAGE: move src.. dest\n    (clobber flags --trash --backup)", .{});
            std.process.exit(1);
        },
        2 => {
            const src_path = ctx.positionals[0];
            var dest_path = ctx.positionals[1];
            if (try ctx.cwd.stat(src_path) == null) {
                try ctx.reporter.pushError("src not found: ({s})", .{src_path});
            }
            if (ctx.reporter.isTrouble()) {
                return ctx.reporter.EXIT_WITH_REPORT(1);
            }

            if (try ctx.cwd.stat(dest_path)) |dest_stat| {
                const is_parrent = try checkDest(&ctx, dest_path, dest_stat, false);
                if (ctx.reporter.isTrouble()) {
                    return ctx.reporter.EXIT_WITH_REPORT(1);
                }

                if (is_parrent) {
                    const real_dest_path = try util.fmt(arena, "{s}{s}", .{ dest_path, basename(src_path) });
                    if (try ctx.cwd.stat(real_dest_path)) |real_dest_stat| {
                        _ = try checkDest(&ctx, real_dest_path, real_dest_stat, true);
                    }
                }
            }

            if (ctx.flag_rename) {
                if (std.mem.indexOf(u8, dest_path, "/")) |_| {
                    try ctx.reporter.pushError("--rename value may not inculed a '/'", .{});
                }
                dest_path = try util.fmtZ(arena, "{s}/{s}", .{ dirname(src_path) orelse "./", dest_path });
            }

            if (try ctx.cwd.isPathSameLocation(src_path, dest_path)) {
                try ctx.reporter.pushError("src and dest cannot be same location: ({s} == {s})", .{ src_path, dest_path });
            }

            if (ctx.reporter.isTrouble()) {
                return ctx.reporter.EXIT_WITH_REPORT(1);
            }

            try move(&ctx, src_path, dest_path);
        },
        else => {
            const src_path_list = ctx.positionals[0 .. ctx.positionals.len - 1];
            const dest_path: [:0]const u8 = ctx.positionals[ctx.positionals.len - 1];

            { // CHECK SRC PATHS EXIST
                for (src_path_list) |src_path| {
                    if (try ctx.cwd.stat(src_path) == null) {
                        try ctx.reporter.pushError("src path not found: ({s})", .{src_path});
                    }
                }
                if (ctx.reporter.isTrouble()) {
                    try ctx.reporter.pushError("moved 0/{d} files", .{src_path_list.len});
                    return ctx.reporter.EXIT_WITH_REPORT(1);
                }
            }

            { // CHECK DEST IS A VALID DIRECTORY
                if (try ctx.cwd.stat(dest_path)) |dest_stat| {
                    _ = try checkDest(&ctx, dest_path, dest_stat, false);
                } else {
                    try ctx.reporter.pushError("dest must be a directory.", .{});
                }
                if (ctx.reporter.isTrouble()) {
                    try ctx.reporter.pushError("moved 0/{d} files", .{src_path_list.len});
                    return ctx.reporter.EXIT_WITH_REPORT(1);
                }
            }

            { // CHECK REAL DEST PATHS ARE VALID
                for (src_path_list) |src_path| {
                    const real_dest_path = try util.fmt(arena, "{s}{s}", .{ dest_path, basename(src_path) });

                    if (try ctx.cwd.stat(real_dest_path)) |real_dest_stat| {
                        _ = try checkDest(&ctx, real_dest_path, real_dest_stat, true);
                    }
                    if (try ctx.cwd.isPathSameLocation(src_path, real_dest_path)) {
                        try ctx.reporter.pushError("src and dest cannot be same location: ({s} == {s})", .{ src_path, real_dest_path });
                    }
                }
                if (ctx.reporter.isTrouble()) {
                    try ctx.reporter.pushError("moved 0/{d} files", .{src_path_list.len});
                    return ctx.reporter.EXIT_WITH_REPORT(1);
                }
            }
            // GO FOR IT
            for (ctx.positionals[0 .. ctx.positionals.len - 1]) |src_path| {
                try move(&ctx, src_path, dest_path);
            }
            util.log("moved {d}/{d} files", .{ src_path_list.len, src_path_list.len });
        },
    }

    const status: u8 = if (ctx.reporter.isError()) 1 else 0;
    ctx.reporter.EXIT_WITH_REPORT(status);
}

// returns true if dest is a valid parrent directory
pub fn checkDest(
    ctx: *Context,
    dest_path: []const u8,
    dest_stat: std.fs.File.Stat,
    /// dest_is_into_path is strage name.. it just means that dest_path has been created from og_dest/og_src
    dest_is_into_path: bool,
) !bool {
    switch (dest_stat.kind) {
        .directory => {
            if (!dest_is_into_path) {
                if (util.endsWith(dest_path, "/")) {
                    if (ctx.flag_rename) {
                        try ctx.reporter.pushError("--remove cannot be used when moving into a directory", .{});
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

/// asserts that everything has been prevalidated.. src must be able to move to dest or it will panic
pub fn move(ctx: *Context, src_path: [:0]const u8, dest_path: [:0]const u8) !void {
    var rename_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var real_dest_path = dest_path;
    var into_dir = false;

    if (std.mem.endsWith(u8, real_dest_path, "/")) {
        const file_name = std.fs.path.basename(src_path);
        real_dest_path = try std.fmt.bufPrintZ(&rename_buffer, "{s}{s}", .{ real_dest_path, file_name });
        into_dir = true;
    }

    if (try ctx.cwd.exists(real_dest_path)) {
        switch (ctx.flag_clobber_style) {
            .NoClobber => ctx.reporter.PANIC("NoClobber should be unreachable", .{}),
            .Trash => {
                const stat = (try ctx.cwd.stat(real_dest_path)).?;
                const trash_path = try ctx.cwd.trash(ctx.arena, real_dest_path, stat.kind);
                if (!ctx.flag_silent) try ctx.reporter.pushWarning("trashed: {s} > $trash/{s}", .{ real_dest_path, basename(trash_path) });
            },
            .Backup => {
                const path_destinaton_backup = try util.fmtZ(ctx.arena, "{s}.backup~", .{src_path});
                if (try ctx.cwd.exists(path_destinaton_backup)) {
                    const stat = (try ctx.cwd.stat(path_destinaton_backup)).?;
                    const trash_path = try ctx.cwd.trash(ctx.arena, path_destinaton_backup, stat.kind);
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
}

const Context = struct {
    arena: Allocator,
    reporter: Reporter,
    cwd: WorkDir,

    args: util.ArgIterator = undefined,
    positionals: [][:0]const u8 = undefined,
    flag_help: bool = false,
    flag_version: bool = false,
    flag_rename: bool = false,
    flag_silent: bool = false,
    flag_clobber_style: ClobberStyle = .NoClobber,
    flag_parser: util.FlagParser = .{
        .parseFn = Context.implParseFn,
        .setArgIteratorFn = Context.implSetArgIterator,
        .setPositionalListFn = Context.implSetPositionalList,
        .setProgramPathFn = FlagParser.noopSetProgramPath,
    },

    pub fn init(arena: Allocator) !Context {
        const reporter = Reporter.init(arena);
        const work_dir = WorkDir.cwd();
        var result: Context = .{
            .arena = arena,
            .cwd = work_dir,
            .reporter = reporter,
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

    pub const ClobberStyle = enum(u3) {
        NoClobber = 0, // DEFAULT
        Trash = 1,
        Backup = 2,

        pub fn prioritySet(self: *ClobberStyle, value: ClobberStyle) void {
            if (@intFromEnum(self.*) < @intFromEnum(value)) {
                self.* = value;
            }
        }
    };

    pub fn implParseFn(flag_parser: *util.FlagParser, arg: [:0]const u8, _: *util.ArgIterator) FlagParser.Error!bool {
        var self = @as(*Context, @fieldParentPtr("flag_parser", flag_parser));
        if (util.eqlFlag(arg, "--trash", "-t")) {
            self.flag_clobber_style.prioritySet(.Trash);
            return true;
        }
        if (util.eqlFlag(arg, "--backup", "-b")) {
            self.flag_clobber_style.prioritySet(.Backup);
            return true;
        }
        if (util.eqlFlag(arg, "--rename", "-r")) {
            self.flag_rename = true;
            return true;
        }
        if (util.eql(arg, "--silent")) {
            self.flag_silent = true;
            return true;
        }
        if (util.eql(arg, "--version")) {
            self.flag_version = true;
            return true;
        }

        if (util.eqlFlag(arg, "--help", "-h")) {
            self.flag_help = true;
            return true;
        }

        return false;
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
};
