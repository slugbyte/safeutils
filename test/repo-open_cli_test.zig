const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const Child = std.process.Child;
const test_config = @import("test_config");
const util = @import("test_util.zig");

var resolved_path_buf: [fs.max_path_bytes]u8 = undefined;
var resolved_path_len: ?usize = null;

fn getRepoOpenExePath() []const u8 {
    if (resolved_path_len) |len| return resolved_path_buf[0..len];
    const exe_path = @field(test_config, "repo-open_exe_path");
    const result = fs.cwd().realpath(exe_path, &resolved_path_buf) catch
        @panic("failed to resolve repo-open binary path");
    resolved_path_len = result.len;
    return result;
}

fn runRepoOpen(cwd_dir: fs.Dir, args: []const []const u8) util.CliResult {
    return util.runBinary(getRepoOpenExePath(), cwd_dir, args);
}

fn ensureCommandExists(name: []const u8) !void {
    var child = Child.init(&.{ name, "--version" }, testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    _ = try child.wait();
}

fn runCommand(cwd_dir: fs.Dir, args: []const []const u8) !void {
    var child = Child.init(args, testing.allocator);
    child.cwd_dir = cwd_dir;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    }
}

fn runCommandCaptureStdout(cwd_dir: fs.Dir, args: []const []const u8) ![]u8 {
    var child = Child.init(args, testing.allocator);
    child.cwd_dir = cwd_dir;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(testing.allocator);
    try child.collectOutput(testing.allocator, &stdout, &stderr, 64 * 1024);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                stdout.deinit(testing.allocator);
                return error.TestUnexpectedResult;
            }
        },
        else => {
            stdout.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        },
    }

    return try stdout.toOwnedSlice(testing.allocator);
}

fn initGitRepoWithRemote(tmp: anytype, remote_url: []const u8) !void {
    try runCommand(tmp.dir, &.{ "git", "init", "-q" });
    try runCommand(tmp.dir, &.{ "git", "config", "user.name", "Repo Open Test" });
    try runCommand(tmp.dir, &.{ "git", "config", "user.email", "repo-open@test.invalid" });
    try util.writeFile(tmp.dir, "README.txt", "seed");
    try runCommand(tmp.dir, &.{ "git", "add", "README.txt" });
    try runCommand(tmp.dir, &.{ "git", "commit", "-qm", "seed" });
    try runCommand(tmp.dir, &.{ "git", "branch", "-M", "main" });
    try runCommand(tmp.dir, &.{ "git", "remote", "add", "origin", remote_url });
}

test "help flag prints help text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runRepoOpen(tmp.dir, &.{"-h"});
    defer result.deinit();

    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Usage: repo-open") != null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--print") != null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--remote") != null);
}

test "git default opens current branch URL" {
    try ensureCommandExists("git");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try initGitRepoWithRemote(&tmp, "git@github.com:slugbyte/safeutils.git");

    const result = runRepoOpen(tmp.dir, &.{"-p"});
    defer result.deinit();

    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "https://github.com/slugbyte/safeutils/tree/main") != null);
}

test "git detached head falls back to commit URL" {
    try ensureCommandExists("git");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try initGitRepoWithRemote(&tmp, "git@github.com:slugbyte/safeutils.git");
    const commit_raw = try runCommandCaptureStdout(tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer testing.allocator.free(commit_raw);
    const commit = std.mem.trim(u8, commit_raw, "\n\t ");

    try runCommand(tmp.dir, &.{ "git", "checkout", "--detach", "-q" });

    const result = runRepoOpen(tmp.dir, &.{"-p"});
    defer result.deinit();

    try testing.expectEqual(@as(?u8, 0), result.code);
    const expected = try std.fmt.allocPrint(testing.allocator, "https://github.com/slugbyte/safeutils/commit/{s}", .{commit});
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.indexOf(u8, result.stderr, expected) != null);
}

test "branch flag uses provider-specific branch URL and encoding" {
    try ensureCommandExists("git");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try initGitRepoWithRemote(&tmp, "https://gitlab.com/group/project.git");

    const result = runRepoOpen(tmp.dir, &.{ "-p", "-b", "feature/hello world" });
    defer result.deinit();

    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "https://gitlab.com/group/project/-/tree/feature%2Fhello%20world") != null);
}

test "branch and commit flags conflict" {
    try ensureCommandExists("git");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try initGitRepoWithRemote(&tmp, "git@github.com:slugbyte/safeutils.git");
    const result = runRepoOpen(tmp.dir, &.{ "-p", "-b", "main", "-c", "abc123" });
    defer result.deinit();

    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "cannot be used together") != null);
}

test "unknown host errors" {
    try ensureCommandExists("git");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try initGitRepoWithRemote(&tmp, "git@bitbucket.org:slugbyte/safeutils.git");
    const result = runRepoOpen(tmp.dir, &.{"-p"});
    defer result.deinit();

    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported remote host") != null);
}

test "remote override chooses supported remote" {
    try ensureCommandExists("git");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try initGitRepoWithRemote(&tmp, "git@bitbucket.org:slugbyte/safeutils.git");
    try runCommand(tmp.dir, &.{ "git", "remote", "add", "upstream", "ssh://git@codeberg.org/slugbyte/safeutils.git" });

    const result = runRepoOpen(tmp.dir, &.{ "-p", "-r", "upstream" });
    defer result.deinit();

    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "https://codeberg.org/slugbyte/safeutils/src/branch/main") != null);
}

test "jj defaults to repo root unless ref flag is provided" {
    try ensureCommandExists("jj");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try runCommand(tmp.dir, &.{ "jj", "git", "init", "." });
    try runCommand(tmp.dir, &.{ "jj", "git", "remote", "add", "origin", "git@github.com:slugbyte/safeutils.git" });

    const root_result = runRepoOpen(tmp.dir, &.{"-p"});
    defer root_result.deinit();
    try testing.expectEqual(@as(?u8, 0), root_result.code);
    try testing.expect(std.mem.indexOf(u8, root_result.stderr, "https://github.com/slugbyte/safeutils") != null);
    try testing.expect(std.mem.indexOf(u8, root_result.stderr, "/tree/") == null);

    const branch_result = runRepoOpen(tmp.dir, &.{ "-p", "-b", "my/branch" });
    defer branch_result.deinit();
    try testing.expectEqual(@as(?u8, 0), branch_result.code);
    try testing.expect(std.mem.indexOf(u8, branch_result.stderr, "https://github.com/slugbyte/safeutils/tree/my%2Fbranch") != null);
}
