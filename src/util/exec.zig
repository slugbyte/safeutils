const std = @import("std");
const Allocator = std.mem.Allocator;

pub const run = std.process.Child.run;

pub const SpawnOptions = struct {
    args: []const []const u8,
    stdin: ?std.fs.File = null,
    stdout: ?std.fs.File = null,
    stderr: ?std.fs.File = null,
    stdin_behavior: std.process.Child.StdIo = .Ignore,
    stdout_behavior: std.process.Child.StdIo = .Ignore,
    stderr_behavior: std.process.Child.StdIo = .Ignore,
    expand_arg0: std.process.Child.Arg0Expand = .no_expand,
    cwd: ?[]const u8 = null,
    cwd_dir: ?std.fs.Dir = null,
    env_map: ?*const std.process.EnvMap = null,
};

pub fn spawn(allocator: Allocator, opt: SpawnOptions) !std.process.Child {
    var child = std.process.Child.init(opt.args, allocator);
    child.stdin = opt.stdin;
    child.stdout = opt.stdout;
    child.stderr = opt.stderr;
    child.stdin_behavior = opt.stdin_behavior;
    child.stdout_behavior = opt.stdout_behavior;
    child.stderr_behavior = opt.stderr_behavior;
    child.cwd = opt.cwd;
    child.cwd_dir = opt.cwd_dir;
    child.expand_arg0 = opt.expand_arg0;
    child.env_map = opt.env_map;

    try child.spawn();
    return child;
}

pub fn exists(allocator: Allocator, exe_name: []const u8) !bool {
    var child = std.process.Child.init(&.{ "which", exe_name }, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stdin_behavior = .Ignore;
    try child.spawn();

    switch (try child.wait()) {
        .Exited => |status| {
            return status == 0;
        },
        else => return error.UnexpectedTerm,
    }
}
