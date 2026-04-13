const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const test_config = @import("test_config");
const util = @import("test_util.zig");

/// Resolve the trash binary to an absolute path once and cache it.
var resolved_path_buf: [fs.max_path_bytes]u8 = undefined;
var resolved_path_len: ?usize = null;

fn getTrashExePath() []const u8 {
    if (resolved_path_len) |len| return resolved_path_buf[0..len];
    const result = fs.cwd().realpath(test_config.trash_exe_path, &resolved_path_buf) catch
        @panic("failed to resolve trash binary path");
    resolved_path_len = result.len;
    return result;
}

fn runTrash(cwd_dir: fs.Dir, args: []const []const u8) util.CliResult {
    return util.runBinaryWithIsolatedTrash(getTrashExePath(), cwd_dir, args);
}

fn runTrashWithEnv(cwd_dir: fs.Dir, args: []const []const u8, env_overrides: []const util.EnvVar) util.CliResult {
    return util.runBinaryWithEnv(getTrashExePath(), cwd_dir, args, env_overrides);
}

fn runTrashViaScript(cwd_dir: fs.Dir, shell_command: []const u8) !util.CliResult {
    const argv = [_][]const u8{ "script", "-qfec", shell_command, "/dev/null" };
    var child = std.process.Child.init(&argv, testing.allocator);
    child.cwd_dir = cwd_dir;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    child.spawn() catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    try child.collectOutput(testing.allocator, &stdout, &stderr, 64 * 1024);
    const term = try child.wait();

    const code: ?u8 = switch (term) {
        .Exited => |c| c,
        else => null,
    };
    return .{
        .stderr = try stderr.toOwnedSlice(testing.allocator),
        .stdout = try stdout.toOwnedSlice(testing.allocator),
        .code = code,
    };
}

// ============================================================================
// Basic trash
// ============================================================================
test "TEST: basic file trash removes file from cwd" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "hello.txt", "hello world");

    const result = runTrash(tmp.dir, &.{"hello.txt"});
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // file should be gone from the source directory
    try testing.expect(!util.fileExists(tmp.dir, "hello.txt"));

    // stderr should mention the trash destination
    try testing.expect(std.mem.indexOf(u8, result.stderr, "> $trash/") != null);
}

// ============================================================================
// Trash directory
// ============================================================================
test "TEST: trash directory removes dir from cwd" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("mydir");
    try util.writeFile(tmp.dir, "mydir/file.txt", "inside dir");

    const result = runTrash(tmp.dir, &.{"mydir"});
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    try testing.expect(!util.dirExists(tmp.dir, "mydir"));
}

// ============================================================================
// Trash nonexistent file
// ============================================================================
test "TEST: trash nonexistent file produces warning" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runTrash(tmp.dir, &.{"nonexistent.txt"});
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "file not found") != null);
}

// ============================================================================
// No args prints usage
// ============================================================================
test "TEST: no args prints usage and exits with error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runTrash(tmp.dir, &.{});
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "USAGE: trash") != null);
}

// ============================================================================
// --help
// ============================================================================
test "TEST: help flag prints help and exits 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runTrash(tmp.dir, &.{"-h"});
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "USAGE: trash") != null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--revert") != null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--fetch") != null);
}

// ============================================================================
// --version
// ============================================================================
test "TEST: version flag prints version and exits 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runTrash(tmp.dir, &.{"-v"});
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "trash version:") != null);
}

// ============================================================================
// Multiple files
// ============================================================================
test "TEST: trash multiple files removes all from cwd" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "a.txt", "aaa");
    try util.writeFile(tmp.dir, "b.txt", "bbb");
    try util.writeFile(tmp.dir, "c.txt", "ccc");

    const result = runTrash(tmp.dir, &.{ "a.txt", "b.txt", "c.txt" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    try testing.expect(!util.fileExists(tmp.dir, "a.txt"));
    try testing.expect(!util.fileExists(tmp.dir, "b.txt"));
    try testing.expect(!util.fileExists(tmp.dir, "c.txt"));

    // should report summary for multiple files
    try testing.expect(std.mem.indexOf(u8, result.stderr, "trashed 3/3") != null);
}

// ============================================================================
// --silent
// ============================================================================
test "TEST: silent flag suppresses verbose output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "loud.txt", "data");
    try util.writeFile(tmp.dir, "quiet.txt", "data");

    // without --silent should produce "> $trash/" output
    const loud = runTrash(tmp.dir, &.{"loud.txt"});
    defer loud.deinit();
    try testing.expectEqual(@as(?u8, 0), loud.code);
    try testing.expect(std.mem.indexOf(u8, loud.stderr, "> $trash/") != null);

    // with --silent should not produce "> $trash/" output
    const quiet = runTrash(tmp.dir, &.{ "-s", "quiet.txt" });
    defer quiet.deinit();
    try testing.expectEqual(@as(?u8, 0), quiet.code);
    try testing.expect(std.mem.indexOf(u8, quiet.stderr, "> $trash/") == null);
}

// ============================================================================
// Help text typo fix: "displayed" not "displated"
// ============================================================================
test "TEST: help text has correct spelling of displayed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runTrash(tmp.dir, &.{"-h"});
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // must not contain the old typo
    try testing.expect(std.mem.indexOf(u8, result.stderr, "displated") == null);
    // must contain the corrected word
    try testing.expect(std.mem.indexOf(u8, result.stderr, "displayed") != null);
}

// ============================================================================
// Mixed existing and nonexistent files
// ============================================================================
test "TEST: trash mix of existing and nonexistent files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "exists.txt", "data");

    const result = runTrash(tmp.dir, &.{ "exists.txt", "nope.txt" });
    defer result.deinit();
    // should exit with non-zero due to warning about missing file
    try testing.expect(result.code != null and result.code.? != 0);

    // the existing file should still have been trashed
    try testing.expect(!util.fileExists(tmp.dir, "exists.txt"));

    // stderr should mention the missing file
    try testing.expect(std.mem.indexOf(u8, result.stderr, "file not found: nope.txt") != null);
}

// ============================================================================
// Unknown flag
// ============================================================================
test "TEST: unknown flag produces error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runTrash(tmp.dir, &.{"--bogus"});
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "unknown long flag: --bogus") != null);
}

test "TEST: cli trash dir overrides destination and writes trashinfo" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "hello.txt", "hello world");
    try tmp.dir.makePath("custom/files");
    try tmp.dir.makePath("custom/info");

    const result = runTrash(tmp.dir, &.{
        "--trash-dir",
        "custom/files",
        "--trash-info-dir",
        "custom/info",
        "hello.txt",
    });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(!util.fileExists(tmp.dir, "hello.txt"));

    const trashed = try util.readFile(tmp.dir, "custom/files/hello.txt");
    defer testing.allocator.free(trashed);
    try testing.expectEqualStrings("hello world", trashed);

    const info = try util.readFile(tmp.dir, "custom/info/hello.txt.trashinfo");
    defer testing.allocator.free(info);
    try testing.expect(std.mem.indexOf(u8, info, "[Trash Info]") != null);
    try testing.expect(std.mem.indexOf(u8, info, "Path=") != null);
}

test "TEST: cli trash dir overrides env trash dir" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "world.txt", "world data");
    try tmp.dir.makePath("env/files");
    try tmp.dir.makePath("env/info");
    try tmp.dir.makePath("cli/files");
    try tmp.dir.makePath("cli/info");

    const result = runTrashWithEnv(
        tmp.dir,
        &.{
            "--trash-dir",
            "cli/files",
            "--trash-info-dir",
            "cli/info",
            "world.txt",
        },
        &.{
            .{ .key = "SAFEUTILS_TRASH_DIR", .value = "env/files" },
            .{ .key = "SAFEUTILS_TRASH_INFO_DIR", .value = "env/info" },
        },
    );
    defer result.deinit();

    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(util.fileExists(tmp.dir, "cli/files/world.txt"));
    try testing.expect(util.fileExists(tmp.dir, "cli/info/world.txt.trashinfo"));
    try testing.expect(!util.fileExists(tmp.dir, "env/files/world.txt"));
    try testing.expect(!util.fileExists(tmp.dir, "env/info/world.txt.trashinfo"));
}

test "TEST: env trash dir override controls trash destination" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "envonly.txt", "env only");
    try tmp.dir.makePath("env/files");
    try tmp.dir.makePath("env/info");

    const result = runTrashWithEnv(
        tmp.dir,
        &.{"envonly.txt"},
        &.{
            .{ .key = "SAFEUTILS_TRASH_DIR", .value = "env/files" },
            .{ .key = "SAFEUTILS_TRASH_INFO_DIR", .value = "env/info" },
        },
    );
    defer result.deinit();

    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(util.fileExists(tmp.dir, "env/files/envonly.txt"));
    try testing.expect(util.fileExists(tmp.dir, "env/info/envonly.txt.trashinfo"));
}

test "TEST: env trash dir derives info sibling when info env missing" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "derived.txt", "derive info dir");
    try tmp.dir.makePath("custom/files");
    try tmp.dir.makePath("custom/info");

    const result = runTrashWithEnv(
        tmp.dir,
        &.{"derived.txt"},
        &.{
            .{ .key = "SAFEUTILS_TRASH_DIR", .value = "custom/files" },
        },
    );
    defer result.deinit();

    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(util.fileExists(tmp.dir, "custom/files/derived.txt"));
    try testing.expect(util.fileExists(tmp.dir, "custom/info/derived.txt.trashinfo"));
}

test "TEST: invalid --trash-dir without parent errors" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "x.txt", "x");

    const result = runTrash(tmp.dir, &.{ "--trash-dir", "files", "x.txt" });
    defer result.deinit();

    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--trash-dir must include a parent directory") != null);
}

test "TEST: missing --trash-dir value errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runTrash(tmp.dir, &.{"--trash-dir"});
    defer result.deinit();

    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--trash-dir value missing") != null);
}

test "TEST: missing --trash-info-dir value errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runTrash(tmp.dir, &.{"--trash-info-dir"});
    defer result.deinit();

    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--trash-info-dir value missing") != null);
}

test "TEST: revert restores file and removes trashinfo" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "restore.txt", "restore me");

    const trash_result = runTrash(tmp.dir, &.{"restore.txt"});
    defer trash_result.deinit();
    try testing.expectEqual(@as(?u8, 0), trash_result.code);

    const revert_result = runTrash(tmp.dir, &.{ "--revert", "restore.txt" });
    defer revert_result.deinit();
    try testing.expectEqual(@as(?u8, 0), revert_result.code);

    const restored = try util.readFile(tmp.dir, "restore.txt");
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings("restore me", restored);
    try testing.expect(!util.fileExists(tmp.dir, ".xdg-data/Trash/info/restore.txt.trashinfo"));
}

test "TEST: fetch restores file into cwd and removes trashinfo" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "fetchme.txt", "fetch me");

    const trash_result = runTrash(tmp.dir, &.{"fetchme.txt"});
    defer trash_result.deinit();
    try testing.expectEqual(@as(?u8, 0), trash_result.code);

    const fetch_result = runTrash(tmp.dir, &.{ "--fetch", "fetchme.txt" });
    defer fetch_result.deinit();
    try testing.expectEqual(@as(?u8, 0), fetch_result.code);

    const fetched = try util.readFile(tmp.dir, "fetchme.txt");
    defer testing.allocator.free(fetched);
    try testing.expectEqualStrings("fetch me", fetched);
    try testing.expect(!util.fileExists(tmp.dir, ".xdg-data/Trash/info/fetchme.txt.trashinfo"));
}

test "TEST: revert restores broken symlink" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a broken symlink and trash it.
    try tmp.dir.symLink("nonexistent_target", "broken.link", .{});

    const trash_result = runTrash(tmp.dir, &.{"broken.link"});
    defer trash_result.deinit();
    try testing.expectEqual(@as(?u8, 0), trash_result.code);
    try testing.expect(!util.fileExists(tmp.dir, "broken.link"));

    // Revert should succeed even though the symlink target does not exist.
    const revert_result = runTrash(tmp.dir, &.{ "--revert", "broken.link" });
    defer revert_result.deinit();
    try testing.expectEqual(@as(?u8, 0), revert_result.code);

    // The symlink should be restored and still point at the original target.
    var link_buffer: [fs.max_path_bytes]u8 = undefined;
    const link_target = try tmp.dir.readLink("broken.link", &link_buffer);
    try testing.expectEqualStrings("nonexistent_target", link_target);
}

test "TEST: revert fails when dest already exists" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "conflict.txt", "original");

    const trash_result = runTrash(tmp.dir, &.{"conflict.txt"});
    defer trash_result.deinit();
    try testing.expectEqual(@as(?u8, 0), trash_result.code);

    // Recreate the file at the original location.
    try util.writeFile(tmp.dir, "conflict.txt", "replacement");

    const revert_result = runTrash(tmp.dir, &.{ "--revert", "conflict.txt" });
    defer revert_result.deinit();
    try testing.expect(revert_result.code != null and revert_result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, revert_result.stderr, "revert dest already exists") != null);

    // The replacement file should be untouched.
    const content = try util.readFile(tmp.dir, "conflict.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("replacement", content);
}

test "TEST: fetch fails when dest already exists in cwd" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "dup.txt", "original");

    const trash_result = runTrash(tmp.dir, &.{"dup.txt"});
    defer trash_result.deinit();
    try testing.expectEqual(@as(?u8, 0), trash_result.code);

    // Create a file with the same name in cwd.
    try util.writeFile(tmp.dir, "dup.txt", "blocker");

    const fetch_result = runTrash(tmp.dir, &.{ "--fetch", "dup.txt" });
    defer fetch_result.deinit();
    try testing.expect(fetch_result.code != null and fetch_result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, fetch_result.stderr, "fetch dest already exists") != null);

    // The blocking file should be untouched.
    const content = try util.readFile(tmp.dir, "dup.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("blocker", content);
}

test "TEST: revert errors when trashinfo is missing" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("custom/files");
    try tmp.dir.makePath("custom/info");
    try util.writeFile(tmp.dir, "custom/files/lost.txt", "lost");

    const result = runTrash(tmp.dir, &.{
        "--trash-dir",
        "custom/files",
        "--trash-info-dir",
        "custom/info",
        "--revert",
        "lost.txt",
    });
    defer result.deinit();

    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "could not find trashinfo file") != null);
}

test "TEST: revert errors when trash file is missing" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("custom/files");
    try tmp.dir.makePath("custom/info");
    try util.writeFile(tmp.dir, "custom/info/lost2.txt.trashinfo", "[Trash Info]\nPath=/tmp/example\n");

    const result = runTrash(tmp.dir, &.{
        "--trash-dir",
        "custom/files",
        "--trash-info-dir",
        "custom/info",
        "--revert",
        "lost2.txt",
    });
    defer result.deinit();

    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "could not find trash file") != null);
}

// ============================================================================
// Flag validation
// ============================================================================
test "TEST: mutually exclusive mode flags produce error" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runTrash(tmp.dir, &.{ "--revert", "a.txt", "--fetch", "b.txt" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "mutually exclusive") != null);
}

test "TEST: --viu-width rejects non-numeric input" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runTrash(tmp.dir, &.{ "--viu-width", "abc" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--viu-width requires a valid number") != null);
}

test "TEST: --fzf-preview-window rejects missing value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runTrash(tmp.dir, &.{"--fzf-preview-window"});
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--fzf-preview-window value missing") != null);
}

test "TEST: fetch fzf oversized output returns clear error" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".local/share/Trash/files");
    try tmp.dir.makePath(".local/share/Trash/info");

    {
        const fzf = try tmp.dir.createFile("fzf", .{ .mode = 0o755 });
        defer fzf.close();
        try fzf.writeAll(
            \\#!/bin/sh
            \\i=0
            \\while [ $i -lt 20000 ]; do
            \\  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
            \\  i=$((i+1))
            \\done
            \\exit 0
        );
    }

    const tmp_abs = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_abs);
    const shell_command = try std.fmt.allocPrint(
        testing.allocator,
        "HOME={s} PATH={s}:$PATH {s} --fetch-fzf",
        .{ tmp_abs, tmp_abs, getTrashExePath() },
    );
    defer testing.allocator.free(shell_command);

    const result = runTrashViaScript(tmp.dir, shell_command) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer result.deinit();

    try testing.expect(result.code != null and result.code.? != 0);
    const saw_error = std.mem.indexOf(u8, result.stderr, "fzf selection output exceeded") != null or
        std.mem.indexOf(u8, result.stdout, "fzf selection output exceeded") != null;
    try testing.expect(saw_error);
}
