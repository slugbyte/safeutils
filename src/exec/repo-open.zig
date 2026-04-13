const std = @import("std");
const builtin = @import("builtin");
const util = @import("util");
const build_option = @import("build_option");

const Allocator = std.mem.Allocator;
const ArgIterator = util.ArgIterator;
const FlagParser = util.FlagParser;
const FlagIterator = util.FlagIterator;
const Reporter = util.Reporter;
const WorkDir = util.WorkDir;

const MAX_CAPTURE_BYTES: usize = 256 * 1024;

pub const help_msg =
    \\Usage: repo-open (--flags)
    \\  Open this repository on the forge remote, or print the URL.
    \\  Supports github.com, gitlab.com, and codeberg.org remotes.
    \\
    \\  -r --remote   remote     remote name (default: origin, fallback first supported)
    \\  -b --branch   branch     open branch URL
    \\  -c --commit   commit     open commit URL
    \\  -p --print               print URL only, do not open browser
    \\
    \\  -v --version             print this version
    \\  -h --help                print this help
;

const RepoKind = enum {
    jj,
    git,
};

const Provider = enum {
    github,
    gitlab,
    codeberg,
};

const RemoteEntry = struct {
    name: []const u8,
    url: []const u8,
};

const RepoRemote = struct {
    name: []const u8,
    url: []const u8,
    host: []const u8,
    repo_path: []const u8,
    provider: Provider,
};

const CommandResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: ?u8,
};

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    var ctx = try Context.init(arena);

    if (ctx.reporter.isError()) {
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
        util.log("repo-open version: ({s}) {s} {s} -- '{s}'", .{
            build_option.date,
            build_option.change_id[0..8],
            build_option.commit_id[0..8],
            build_option.description,
        });
        ctx.reporter.EXIT_WITH_REPORT(0);
    }

    if (ctx.positionals.len != 0) {
        try ctx.reporter.pushError("repo-open does not accept positional arguments", .{});
    }

    if (ctx.flag_branch != null and ctx.flag_commit != null) {
        try ctx.reporter.pushError("--branch and --commit cannot be used together", .{});
    }

    if (ctx.reporter.isError()) {
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    const repo_kind = try detectRepoKind(&ctx);
    const remote = try selectRemote(&ctx, repo_kind);
    const url = try buildTargetUrl(&ctx, repo_kind, remote);

    if (ctx.flag_print) {
        util.log("{s}", .{url});
        ctx.reporter.EXIT_WITH_REPORT(0);
    }

    const opener = switch (builtin.os.tag) {
        .linux => "xdg-open",
        .macos => "open",
        else => {
            try ctx.reporter.pushError("opening browser is unsupported on this OS; use --print", .{});
            ctx.reporter.EXIT_WITH_REPORT(1);
        },
    };

    var child = util.exec.spawn(ctx.arena, .{
        .args = &.{ opener, url },
        .stdin_behavior = .Ignore,
        .stdout_behavior = .Ignore,
        .stderr_behavior = .Ignore,
    }) catch |err| {
        try ctx.reporter.pushError("failed to start opener '{s}': {t}", .{ opener, err });
        ctx.reporter.EXIT_WITH_REPORT(2);
    };

    switch (try child.wait()) {
        .Exited => |code| {
            if (code != 0) {
                try ctx.reporter.pushError("opener '{s}' exited with status {d}", .{ opener, code });
                ctx.reporter.EXIT_WITH_REPORT(2);
            }
        },
        else => {
            try ctx.reporter.pushError("opener '{s}' terminated unexpectedly", .{opener});
            ctx.reporter.EXIT_WITH_REPORT(2);
        },
    }

    ctx.reporter.EXIT_WITH_REPORT(0);
}

fn detectRepoKind(ctx: *Context) !RepoKind {
    if (try ctx.cwd.statNoFollow(".jj") != null) return .jj;
    if (try ctx.cwd.statNoFollow(".git") != null) return .git;
    try ctx.reporter.pushError("not inside a jj or git repository", .{});
    ctx.reporter.EXIT_WITH_REPORT(1);
}

fn selectRemote(ctx: *Context, repo_kind: RepoKind) !RepoRemote {
    const remotes = try listRemotes(ctx, repo_kind);
    if (remotes.len == 0) {
        try ctx.reporter.pushError("no remotes found", .{});
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    if (ctx.flag_remote) |remote_name| {
        for (remotes) |remote| {
            if (std.mem.eql(u8, remote.name, remote_name)) {
                return try parseSelectedRemote(ctx, remote);
            }
        }
        try ctx.reporter.pushError("remote not found: {s}", .{remote_name});
        ctx.reporter.EXIT_WITH_REPORT(1);
    }

    for (remotes) |remote| {
        if (std.mem.eql(u8, remote.name, "origin")) {
            return try parseSelectedRemote(ctx, remote);
        }
    }

    for (remotes) |remote| {
        if (parseRemoteUrl(remote.url)) |parsed| {
            return .{
                .name = remote.name,
                .url = remote.url,
                .host = parsed.host,
                .repo_path = parsed.repo_path,
                .provider = parsed.provider,
            };
        } else |_| {
            continue;
        }
    }

    try ctx.reporter.pushError("no remotes use a supported host (github.com, gitlab.com, codeberg.org)", .{});
    ctx.reporter.EXIT_WITH_REPORT(1);
}

fn parseSelectedRemote(ctx: *Context, remote: RemoteEntry) !RepoRemote {
    const parsed = parseRemoteUrl(remote.url) catch |err| switch (err) {
        error.UnsupportedRemoteHost => {
            try ctx.reporter.pushError("unsupported remote host for '{s}': {s}", .{ remote.name, remote.url });
            ctx.reporter.EXIT_WITH_REPORT(1);
        },
        error.InvalidRemoteUrl => {
            try ctx.reporter.pushError("could not parse remote url for '{s}': {s}", .{ remote.name, remote.url });
            ctx.reporter.EXIT_WITH_REPORT(1);
        },
        else => return err,
    };

    return .{
        .name = remote.name,
        .url = remote.url,
        .host = parsed.host,
        .repo_path = parsed.repo_path,
        .provider = parsed.provider,
    };
}

fn listRemotes(ctx: *Context, repo_kind: RepoKind) ![]RemoteEntry {
    var remote_list = std.ArrayList(RemoteEntry).empty;

    switch (repo_kind) {
        .jj => {
            const result = try runCommandCapture(ctx.arena, &.{ "jj", "git", "remote", "list" });
            if (result.exit_code == null or result.exit_code.? != 0) {
                try ctx.reporter.pushError("failed to list jj remotes", .{});
                ctx.reporter.EXIT_WITH_REPORT(1);
            }

            var line_iter = std.mem.splitScalar(u8, result.stdout, '\n');
            while (line_iter.next()) |line_raw| {
                const line = util.trim(line_raw);
                if (line.len == 0) continue;

                const split_index = std.mem.indexOfScalar(u8, line, ' ') orelse {
                    try ctx.reporter.pushError("could not parse jj remote list entry: {s}", .{line});
                    ctx.reporter.EXIT_WITH_REPORT(1);
                };
                const name = line[0..split_index];
                const url = util.trim(line[split_index + 1 ..]);
                try remote_list.append(ctx.arena, .{
                    .name = name,
                    .url = url,
                });
            }
        },
        .git => {
            const names_result = try runCommandCapture(ctx.arena, &.{ "git", "remote" });
            if (names_result.exit_code == null or names_result.exit_code.? != 0) {
                try ctx.reporter.pushError("failed to list git remotes", .{});
                ctx.reporter.EXIT_WITH_REPORT(1);
            }

            var line_iter = std.mem.splitScalar(u8, names_result.stdout, '\n');
            while (line_iter.next()) |line_raw| {
                const name = util.trim(line_raw);
                if (name.len == 0) continue;

                const url_result = try runCommandCapture(ctx.arena, &.{ "git", "remote", "get-url", name });
                if (url_result.exit_code == null or url_result.exit_code.? != 0) {
                    try ctx.reporter.pushError("failed to resolve git remote url for: {s}", .{name});
                    ctx.reporter.EXIT_WITH_REPORT(1);
                }
                const url = util.trim(url_result.stdout);
                try remote_list.append(ctx.arena, .{
                    .name = name,
                    .url = url,
                });
            }
        },
    }

    return remote_list.items;
}

fn buildTargetUrl(ctx: *Context, repo_kind: RepoKind, remote: RepoRemote) ![]const u8 {
    const base_url = try util.fmt(ctx.arena, "https://{s}/{s}", .{ remote.host, remote.repo_path });

    if (ctx.flag_branch) |branch| {
        const encoded = try urlEncodePathSegment(ctx.arena, branch);
        return switch (remote.provider) {
            .github => try util.fmt(ctx.arena, "{s}/tree/{s}", .{ base_url, encoded }),
            .gitlab => try util.fmt(ctx.arena, "{s}/-/tree/{s}", .{ base_url, encoded }),
            .codeberg => try util.fmt(ctx.arena, "{s}/src/branch/{s}", .{ base_url, encoded }),
        };
    }

    if (ctx.flag_commit) |commit| {
        const encoded = try urlEncodePathSegment(ctx.arena, commit);
        return switch (remote.provider) {
            .github => try util.fmt(ctx.arena, "{s}/commit/{s}", .{ base_url, encoded }),
            .gitlab => try util.fmt(ctx.arena, "{s}/-/commit/{s}", .{ base_url, encoded }),
            .codeberg => try util.fmt(ctx.arena, "{s}/commit/{s}", .{ base_url, encoded }),
        };
    }

    if (repo_kind == .jj) {
        return base_url;
    }

    if (try currentGitBranch(ctx.arena)) |branch| {
        const encoded = try urlEncodePathSegment(ctx.arena, branch);
        return switch (remote.provider) {
            .github => try util.fmt(ctx.arena, "{s}/tree/{s}", .{ base_url, encoded }),
            .gitlab => try util.fmt(ctx.arena, "{s}/-/tree/{s}", .{ base_url, encoded }),
            .codeberg => try util.fmt(ctx.arena, "{s}/src/branch/{s}", .{ base_url, encoded }),
        };
    }

    if (try currentGitCommit(ctx.arena)) |commit| {
        const encoded = try urlEncodePathSegment(ctx.arena, commit);
        return switch (remote.provider) {
            .github => try util.fmt(ctx.arena, "{s}/commit/{s}", .{ base_url, encoded }),
            .gitlab => try util.fmt(ctx.arena, "{s}/-/commit/{s}", .{ base_url, encoded }),
            .codeberg => try util.fmt(ctx.arena, "{s}/commit/{s}", .{ base_url, encoded }),
        };
    }

    return base_url;
}

fn currentGitBranch(arena: Allocator) !?[]const u8 {
    const result = try runCommandCapture(arena, &.{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" });
    if (result.exit_code == null or result.exit_code.? != 0) return null;
    const value = util.trim(result.stdout);
    if (value.len == 0) return null;
    return value;
}

fn currentGitCommit(arena: Allocator) !?[]const u8 {
    const result = try runCommandCapture(arena, &.{ "git", "rev-parse", "--verify", "HEAD" });
    if (result.exit_code == null or result.exit_code.? != 0) return null;
    const value = util.trim(result.stdout);
    if (value.len == 0) return null;
    return value;
}

fn runCommandCapture(arena: Allocator, args: []const []const u8) !CommandResult {
    var child = try util.exec.spawn(arena, .{
        .args = args,
        .stdin_behavior = .Ignore,
        .stdout_behavior = .Pipe,
        .stderr_behavior = .Pipe,
    });

    const stdout = child.stdout.?.readToEndAlloc(arena, MAX_CAPTURE_BYTES) catch |err| switch (err) {
        error.FileTooBig => return error.OutputTooLarge,
        else => return err,
    };
    child.stdout.?.close();
    child.stdout = null;

    const stderr = child.stderr.?.readToEndAlloc(arena, MAX_CAPTURE_BYTES) catch |err| switch (err) {
        error.FileTooBig => return error.OutputTooLarge,
        else => return err,
    };
    child.stderr.?.close();
    child.stderr = null;

    const exit_code: ?u8 = switch (try child.wait()) {
        .Exited => |code| @as(u8, @truncate(code)),
        else => null,
    };

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
    };
}

const ParsedRemote = struct {
    host: []const u8,
    repo_path: []const u8,
    provider: Provider,
};

fn parseRemoteUrl(url_raw: []const u8) !ParsedRemote {
    const url = util.trim(url_raw);
    var host: []const u8 = undefined;
    var path: []const u8 = undefined;

    if (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://")) {
        const scheme_index = std.mem.indexOf(u8, url, "://").?;
        const after_scheme = url[scheme_index + 3 ..];
        const slash_index = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return error.InvalidRemoteUrl;
        host = after_scheme[0..slash_index];
        path = after_scheme[slash_index + 1 ..];
    } else if (std.mem.startsWith(u8, url, "ssh://")) {
        const after_scheme = url[6..];
        const slash_index = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return error.InvalidRemoteUrl;
        var host_part = after_scheme[0..slash_index];
        if (std.mem.indexOfScalar(u8, host_part, '@')) |at_index| {
            host_part = host_part[at_index + 1 ..];
        }
        host = host_part;
        path = after_scheme[slash_index + 1 ..];
    } else {
        const colon_index = std.mem.indexOfScalar(u8, url, ':') orelse return error.InvalidRemoteUrl;
        const left = url[0..colon_index];
        const right = url[colon_index + 1 ..];
        if (std.mem.indexOfScalar(u8, left, '@')) |at_index| {
            host = left[at_index + 1 ..];
        } else {
            host = left;
        }
        path = right;
    }

    const host_clean = trimPort(host);
    var repo_path = std.mem.trimLeft(u8, path, "/");
    repo_path = std.mem.trimRight(u8, repo_path, "/");
    if (std.mem.endsWith(u8, repo_path, ".git")) {
        repo_path = repo_path[0 .. repo_path.len - 4];
    }

    if (host_clean.len == 0 or repo_path.len == 0) {
        return error.InvalidRemoteUrl;
    }

    const provider = if (std.mem.eql(u8, host_clean, "github.com"))
        Provider.github
    else if (std.mem.eql(u8, host_clean, "gitlab.com"))
        Provider.gitlab
    else if (std.mem.eql(u8, host_clean, "codeberg.org"))
        Provider.codeberg
    else
        return error.UnsupportedRemoteHost;

    return .{
        .host = host_clean,
        .repo_path = repo_path,
        .provider = provider,
    };
}

fn trimPort(host: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, host, ':')) |index| {
        return host[0..index];
    }
    return host;
}

fn isUnreservedByte(char: u8) bool {
    if (std.ascii.isAlphanumeric(char)) return true;
    return switch (char) {
        '-', '.', '_', '~' => true,
        else => false,
    };
}

fn urlEncodePathSegment(arena: Allocator, value: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    for (value) |char| {
        if (isUnreservedByte(char)) {
            try result.append(arena, char);
        } else {
            try result.writer(arena).print("%{X:0>2}", .{char});
        }
    }
    return result.items;
}

const Context = struct {
    arena: Allocator,
    reporter: Reporter,
    cwd: WorkDir,

    args: ArgIterator = undefined,
    positionals: [][:0]const u8 = undefined,
    flag_help: bool = false,
    flag_version: bool = false,
    flag_print: bool = false,
    flag_remote: ?[:0]const u8 = null,
    flag_branch: ?[:0]const u8 = null,
    flag_commit: ?[:0]const u8 = null,
    flag_parser: FlagParser = .{
        .parseFn = Context.implParseFn,
        .setProgramPathFn = FlagParser.noopSetProgramPath,
        .setArgIteratorFn = FlagParser.autoSetArgIterator(Context, "flag_parser", "args"),
        .setPositionalListFn = FlagParser.autoSetPositionalList(Context, "flag_parser", "positionals"),
    },

    const Flags = enum {
        @"--help",
        h,
        @"--version",
        v,
        @"--print",
        p,
        @"--remote",
        r,
        @"--branch",
        b,
        @"--commit",
        c,
    };

    fn init(arena: Allocator) !Context {
        var result: Context = .{
            .arena = arena,
            .reporter = Reporter.init(arena),
            .cwd = WorkDir.cwd(),
        };
        try result.flag_parser.parseProcessArgs(arena);
        return result;
    }

    fn implParseFn(flag_parser: *FlagParser, arg: [:0]const u8, iter: *ArgIterator) FlagParser.Error!FlagParser.ArgType {
        const self: *Context = @fieldParentPtr("flag_parser", flag_parser);
        var flag_iter = FlagIterator(Flags).init(arg);

        while (flag_iter.next()) |flag_result| {
            switch (flag_result) {
                .Flag => |flag| switch (flag) {
                    .h, .@"--help" => self.flag_help = true,
                    .v, .@"--version" => self.flag_version = true,
                    .p, .@"--print" => self.flag_print = true,
                    .r, .@"--remote" => {
                        self.flag_remote = iter.next();
                        if (self.flag_remote == null) {
                            try self.reporter.pushError("--remote value missing", .{});
                        }
                    },
                    .b, .@"--branch" => {
                        self.flag_branch = iter.next();
                        if (self.flag_branch == null) {
                            try self.reporter.pushError("--branch value missing", .{});
                        }
                    },
                    .c, .@"--commit" => {
                        self.flag_commit = iter.next();
                        if (self.flag_commit == null) {
                            try self.reporter.pushError("--commit value missing", .{});
                        }
                    },
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
