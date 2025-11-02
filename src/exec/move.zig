const std = @import("std");
const util = @import("util");
const builtin = @import("builtin");
const build_option = @import("build_option");

const assert = std.debug.assert;
const dirname = std.fs.path.dirname;
const basename = std.fs.path.basename;
const Allocator = std.mem.Allocator;
const Args = util.Args;
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
    var reporter: Reporter = .init(arena);
    if (!util.env.exists("trash")) {
        util.log("ERROR: $trash must be set", .{});
        std.process.exit(1);
    }

    var flags = Flags{};
    var args = try Args.init(arena, &flags.flag_parser);
    if (builtin.mode == .Debug) {
        std.debug.print("---------------------------------------------------------------------------------\n", .{});
        args.debugPrint();
        flags.debugPrint();
        std.debug.print("---------------------------------------------------------------------------------\n", .{});
    }

    if (flags.help) {
        util.log("{s}\n\n  Version:\n    {s} {s} {s} ({s})", .{ help_msg, build_option.version, build_option.change_id[0..8], build_option.commit_id[0..8], build_option.date });
        std.process.exit(1);
    }

    if (flags.version) {
        util.log("move {s} {s} {s} ({s})", .{ build_option.version, build_option.change_id[0..8], build_option.commit_id[0..8], build_option.date });
        return;
    }

    const wd = util.WorkDir.initCWD();
    switch (args.positional.len) {
        0, 1 => {
            util.log("USAGE: move src.. dest\n    (clobber flags --trash --backup)", .{});
            std.process.exit(1);
        },
        2 => {
            const src_path = args.positional[0];
            var dest_path = args.positional[1];
            if (try wd.stat(src_path) == null) {
                try reporter.pushError("src not found: ({s})", .{src_path});
            }
            if (reporter.isTrouble()) {
                return reporter.EXIT_WITH_REPORT(1);
            }

            if (try wd.stat(dest_path)) |dest_stat| {
                const is_parrent = try checkDest(&reporter, flags, dest_path, dest_stat, false);
                if (reporter.isTrouble()) {
                    return reporter.EXIT_WITH_REPORT(1);
                }

                if (is_parrent) {
                    const real_dest_path = try std.fmt.allocPrint(arena, "{s}{s}", .{ dest_path, basename(src_path) });
                    if (try wd.stat(real_dest_path)) |real_dest_stat| {
                        _ = try checkDest(&reporter, flags, real_dest_path, real_dest_stat, true);
                    }
                }
            }

            if (flags.rename) {
                if (std.mem.indexOf(u8, dest_path, "/")) |_| {
                    try reporter.pushError("--rename value may not inculed a '/'", .{});
                }
                dest_path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dirname(src_path) orelse "./", dest_path }, 0);
            }

            if (try wd.isPathEqual(src_path, dest_path)) {
                try reporter.pushError("src and dest cannot be same location: ({s} == {s})", .{ src_path, dest_path });
            }

            if (reporter.isTrouble()) {
                return reporter.EXIT_WITH_REPORT(1);
            }

            try move(&reporter, flags, wd, src_path, dest_path);
        },
        else => {
            const src_path_list = args.positional[0 .. args.positional.len - 1];
            const dest_path: [:0]const u8 = args.positional[args.positional.len - 1];

            { // CHECK SRC PATHS EXIST
                for (src_path_list) |src_path| {
                    if (try wd.stat(src_path) == null) {
                        try reporter.pushError("src path not found: ({s})", .{src_path});
                    }
                }
                if (reporter.isTrouble()) {
                    try reporter.pushError("moved 0/{d} files", .{src_path_list.len});
                    return reporter.EXIT_WITH_REPORT(1);
                }
            }

            { // CHECK DEST IS A VALID DIRECTORY
                if (try wd.stat(dest_path)) |dest_stat| {
                    _ = try checkDest(&reporter, flags, dest_path, dest_stat, false);
                } else {
                    try reporter.pushError("dest must be a directory.", .{});
                }
                if (reporter.isTrouble()) {
                    try reporter.pushError("moved 0/{d} files", .{src_path_list.len});
                    return reporter.EXIT_WITH_REPORT(1);
                }
            }

            { // CHECK REAL DEST PATHS ARE VALID
                for (src_path_list) |src_path| {
                    const real_dest_path = try std.fmt.allocPrint(arena, "{s}{s}", .{ dest_path, basename(src_path) });

                    if (try wd.stat(real_dest_path)) |real_dest_stat| {
                        _ = try checkDest(&reporter, flags, real_dest_path, real_dest_stat, true);
                    }
                    if (try wd.isPathEqual(src_path, real_dest_path)) {
                        try reporter.pushError("src and dest cannot be same location: ({s} == {s})", .{ src_path, real_dest_path });
                    }
                }
                if (reporter.isTrouble()) {
                    try reporter.pushError("moved 0/{d} files", .{src_path_list.len});
                    return reporter.EXIT_WITH_REPORT(1);
                }
            }
            // GO FOR IT
            for (args.positional[0 .. args.positional.len - 1]) |arg| {
                try move(&reporter, flags, wd, arg, dest_path);
            }
            util.log("moved {d}/{d} files", .{ src_path_list.len, src_path_list.len });
        },
    }

    const status: u8 = if (reporter.isError()) 1 else 0;
    reporter.EXIT_WITH_REPORT(status);
}

// returns true if dest is a valid parrent directory
pub fn checkDest(
    reporter: *Reporter,
    flags: Flags,
    dest_path: []const u8,
    dest_stat: std.fs.File.Stat,
    /// dest_is_into_path is strage name.. it just means that dest_path has been created from og_dest/og_src
    dest_is_into_path: bool,
) !bool {
    switch (dest_stat.kind) {
        .directory => {
            if (!dest_is_into_path) {
                if (Args.endsWith(dest_path, "/")) {
                    if (flags.rename) {
                        try reporter.pushError("--remove cannot be used when moving into a directory", .{});
                    }
                    return true;
                }
                if (flags.clobber_style == .NoClobber) {
                    try reporter.pushError("dest is a directory. use clobber flag or add '/' to dest to move src... into.", .{});
                }
            } else {
                if (flags.clobber_style == .NoClobber) {
                    try reporter.pushError("dest child dir exists ({s})", .{dest_path});
                }
            }
        },
        .file, .sym_link => {
            if (flags.clobber_style == .NoClobber) {
                if (dest_is_into_path) {
                    try reporter.pushError("dest child path exists ({s})", .{dest_path});
                } else {
                    try reporter.pushError("dest path exists, choose a clobber flag (--trash --backup)", .{});
                }
            }
        },
        else => {
            switch (flags.clobber_style) {
                .NoClobber => {
                    try reporter.pushError("dest path exists, choose a clobber flag (--trash --backup)", .{});
                },
                .Trash => {
                    try reporter.pushError("dest path exists and --trash does not support file type {t}, use --backup", .{
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
pub fn move(reporter: *Reporter, flag: Flags, cwd: util.WorkDir, src_path: [:0]const u8, dest_path: [:0]const u8) !void {
    var rename_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var real_dest_path = dest_path;
    var into_dir = false;

    if (std.mem.endsWith(u8, real_dest_path, "/")) {
        const file_name = std.fs.path.basename(src_path);
        real_dest_path = try std.fmt.bufPrintZ(&rename_buffer, "{s}{s}", .{ real_dest_path, file_name });
        into_dir = true;
    }

    if (try cwd.exists(real_dest_path)) {
        switch (flag.clobber_style) {
            .NoClobber => reporter.PANIC("NoClobber should be unreachable", .{}),
            .Trash => {
                const stat = (try cwd.stat(real_dest_path)).?;
                const trash_path = try cwd.trashKind(real_dest_path, stat.kind);
                if (!flag.silent) try reporter.pushWarning("trashed: {s} > $trash/{s}", .{ real_dest_path, basename(trash_path) });
            },
            .Backup => {
                const path_destinaton_backup = try util.path.backupPathFromPath(real_dest_path);
                if (try cwd.exists(path_destinaton_backup)) {
                    const stat = (try cwd.stat(path_destinaton_backup)).?;
                    const trash_path = try cwd.trashKind(path_destinaton_backup, stat.kind);
                    if (!flag.silent) try reporter.pushWarning("trashed: {s} > $trash/{s}", .{ path_destinaton_backup, basename(trash_path) });
                }
                try cwd.move(real_dest_path, path_destinaton_backup);
                if (!flag.silent) try reporter.pushWarning("backup created: {s}", .{path_destinaton_backup});
            },
        }
    }
    try cwd.move(src_path, real_dest_path);
    if (!flag.silent) {
        util.log("{s} > {s}", .{ src_path, real_dest_path });
    }
}

const Flags = struct {
    help: bool = false,
    version: bool = false,
    rename: bool = false,
    silent: bool = false,
    clobber_style: ClobberStyle = .NoClobber,

    param_count: usize = 0,

    flag_parser: Args.FlagParser = .{
        .parseFn = Flags.implParseFn,
    },

    pub fn debugPrint(self: Flags) void {
        util.log("FLAG clobber: {t}", .{self.clobber_style});
        util.log("FLAG rename: {any}", .{self.rename});
        util.log("FLAG slient: {any}", .{self.silent});
        util.log("FLAG help: {any}", .{self.help});
        util.log("FLAG version: {any}", .{self.version});
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

    pub fn implParseFn(flag_parser: *Args.FlagParser, arg: [:0]const u8, _: *Args.ArgIterator) Args.Error!bool {
        var self = @as(*Flags, @fieldParentPtr("flag_parser", flag_parser));
        if (Args.eqlFlag(arg, "--trash", "-t")) {
            self.clobber_style.prioritySet(.Trash);
            return true;
        }
        if (Args.eqlFlag(arg, "--backup", "-b")) {
            self.clobber_style.prioritySet(.Backup);
            return true;
        }
        if (Args.eqlFlag(arg, "--rename", "-r")) {
            self.rename = true;
            return true;
        }
        if (Args.eql(arg, "--silent")) {
            self.silent = true;
            return true;
        }
        if (Args.eql(arg, "--version")) {
            self.version = true;
            return true;
        }

        if (Args.eqlFlag(arg, "--help", "-h")) {
            self.help = true;
            return true;
        }

        return false;
    }
};
