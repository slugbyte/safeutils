const std = @import("std");
const util = @import("util");
const builtin = @import("builtin");
const build_option = @import("build_option");

const Allocator = std.mem.Allocator;
const WorkDir = util.WorkDir;
const Reporter = util.Reporter;
const FlagParser = util.FlagParser;

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

    var ctx = try Context.init(arena);
    if (builtin.mode == .Debug) ctx.debugPrint();

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
        const trash_path = ctx.cwd.trashKind(ctx.arena, path, stat.kind) catch |err| switch (err) {
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

const Context = struct {
    arena: Allocator,
    reporter: Reporter,
    cwd: WorkDir,

    args: util.ArgIterator = undefined,
    positionals: [][:0]const u8 = undefined,
    flag_help: bool = false,
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
        std.debug.print("ARGS ", .{});
        while (self.args.next()) |arg| {
            std.debug.print("'{s}' ", .{arg});
        }
        util.log("\nFLAG help: {any}", .{self.flag_help});
        util.log("FLAG version: {any}", .{self.flag_version});
        util.log("FLAG slient: {any}", .{self.flag_silent});
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

    pub fn implParseFn(flag_parser: *util.FlagParser, arg: [:0]const u8, _: *util.ArgIterator) util.FlagParser.Error!bool {
        var self = @as(*Context, @fieldParentPtr("flag_parser", flag_parser));

        if (util.eqlFlag(arg, "--help", "-h")) {
            self.flag_help = true;
            return true;
        }

        if (util.eqlFlag(arg, "--silent", "-s")) {
            self.flag_silent = true;
            return true;
        }

        if (util.eql(arg, "--version")) {
            self.flag_version = true;
            return true;
        }

        return false;
    }
};
