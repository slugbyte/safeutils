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
    return util.runBinary(getTrashExePath(), cwd_dir, args);
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
