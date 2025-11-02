const std = @import("std");
const util = @import("util");
const builtin = @import("builtin");
const build_option = @import("build_option");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Args = util.Args;

pub const help_msg =
    \\USAGE: trash files.. (--flags)
    \\  Move files to $trash.
    \\
    \\  --version      print version
    \\  --s --silent   dont print trash paths
    \\  --h --help     display help
;

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    var reporter: util.Reporter = .init(arena);

    if (!util.env.exists("trash")) {
        util.log("ERROR: $trash must be set", .{});
        std.process.exit(1);
    }

    var flag = Flags{};
    const args = try Args.init(arena, &flag.flag_parser);
    if (builtin.mode == .Debug) args.debugPrint();

    if (flag.help) {
        util.log("{s}\n\n  Version:\n   {s} {s} {s} ({s})", .{
            help_msg,
            build_option.version,
            build_option.change_id[0..8],
            build_option.commit_id[0..8],
            build_option.date,
        });
        return;
    }

    if (flag.version) {
        util.log("trash {s} {s} {s} ({s})", .{
            build_option.version,
            build_option.change_id[0..8],
            build_option.commit_id[0..8],
            build_option.date,
        });
        return;
    }

    if (args.positional.len == 0) {
        util.log("USAGE: trash [file]...", .{});
        std.process.exit(1);
    }

    var success_count: usize = 0;
    var fail_count: usize = 0;
    const wd = util.WorkDir.initCWD();
    for (args.positional) |path| {
        const stat = try wd.stat(path) orelse {
            try reporter.pushWarning("file not found: {s}", .{path});
            continue;
        };
        const trash_path = wd.trashKind(path, stat.kind) catch |err| switch (err) {
            else => reporter.PANIC("unexpected error: {t}", .{err}),
            error.TrashFileKindNotSupported => {
                fail_count +|= 1;
                try reporter.pushWarning("trash does not support '{t}' files, unable to trash: {s}", .{ stat.kind, path });
                continue;
            },
        };
        success_count +|= 1;
        if (!flag.silent) util.log("{s} > $trash/{s}", .{ path, std.fs.path.basename(trash_path) });
    }
    if (fail_count > 0) {
        try reporter.pushWarning("{d} files failed to trash. trashed {d}/{d} files.", .{ fail_count, success_count, success_count + fail_count });
    }
    reporter.report();
    if (success_count > 1 and fail_count == 0) {
        util.log("trashed {d}/{d} files", .{ success_count, success_count + fail_count });
    }

    const status: u8 = if (reporter.isTrouble()) 1 else 0;
    reporter.EXIT_WITH_REPORT(status);
}

const Flags = struct {
    help: bool = false,
    version: bool = false,
    silent: bool = false,

    flag_parser: Args.FlagParser = .{
        .parseFn = Flags.implParseFn,
    },

    pub fn implParseFn(flag_parser: *Args.FlagParser, arg: [:0]const u8, _: *Args.ArgIterator) Args.Error!bool {
        var self = @as(*Flags, @fieldParentPtr("flag_parser", flag_parser));

        if (Args.eqlFlag(arg, "--help", "-h")) {
            self.help = true;
            return true;
        }

        if (Args.eqlFlag(arg, "--silent", "-s")) {
            self.silent = true;
            return true;
        }

        if (Args.eql(arg, "--version")) {
            self.version = true;
            return true;
        }

        return false;
    }
};
