const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const test_config = @import("test_config");
const util = @import("test_util.zig");

/// Resolve the move binary to an absolute path once and cache it.
var resolved_path_buf: [fs.max_path_bytes]u8 = undefined;
var resolved_path_len: ?usize = null;

fn getMoveExePath() []const u8 {
    if (resolved_path_len) |len| return resolved_path_buf[0..len];
    const result = fs.cwd().realpath(test_config.move_exe_path, &resolved_path_buf) catch
        @panic("failed to resolve move binary path");
    resolved_path_len = result.len;
    return result;
}

fn runMove(cwd_dir: fs.Dir, args: []const []const u8) util.CliResult {
    return util.runBinary(getMoveExePath(), cwd_dir, args);
}

fn runMoveWithEnv(cwd_dir: fs.Dir, args: []const []const u8, env_overrides: []const util.EnvVar) util.CliResult {
    return util.runBinaryWithEnv(getMoveExePath(), cwd_dir, args, env_overrides);
}

// ============================================================================
// Basic move
// ============================================================================
test "basic file move" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "src.txt", "hello move");

    const result = runMove(tmp.dir, &.{ "src.txt", "dest.txt" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // src should be gone
    try testing.expect(!util.fileExists(tmp.dir, "src.txt"));

    // dest should have the content
    const content = try util.readFile(tmp.dir, "dest.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello move", content);
}

// ============================================================================
// Move into directory with trailing /
// ============================================================================
test "move file into directory with trailing slash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "file.txt", "into dir");
    try tmp.dir.makeDir("dest");

    const result = runMove(tmp.dir, &.{ "file.txt", "dest/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    try testing.expect(!util.fileExists(tmp.dir, "file.txt"));
    const content = try util.readFile(tmp.dir, "dest/file.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("into dir", content);
}

// ============================================================================
// Multi-move into directory
// ============================================================================
test "move multiple files into directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "a.txt", "aaa");
    try util.writeFile(tmp.dir, "b.txt", "bbb");
    try tmp.dir.makeDir("dest");

    const result = runMove(tmp.dir, &.{ "a.txt", "b.txt", "dest/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    try testing.expect(!util.fileExists(tmp.dir, "a.txt"));
    try testing.expect(!util.fileExists(tmp.dir, "b.txt"));

    const a = try util.readFile(tmp.dir, "dest/a.txt");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("aaa", a);

    const b = try util.readFile(tmp.dir, "dest/b.txt");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("bbb", b);
}

// ============================================================================
// --rename basic usage
// ============================================================================
test "rename flag renames file in same directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("sub");
    try util.writeFile(tmp.dir, "sub/old.txt", "rename me");

    const result = runMove(tmp.dir, &.{ "--rename", "sub/old.txt", "new.txt" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    try testing.expect(!util.fileExists(tmp.dir, "sub/old.txt"));
    const content = try util.readFile(tmp.dir, "sub/new.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("rename me", content);
}

// ============================================================================
// --rename with multiple sources errors (fix #5)
// ============================================================================
test "rename flag with multiple sources errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "a.txt", "a");
    try util.writeFile(tmp.dir, "b.txt", "b");
    try tmp.dir.makeDir("dest");

    const result = runMove(tmp.dir, &.{ "--rename", "a.txt", "b.txt", "dest/" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--rename only works with one src path") != null);
}

// ============================================================================
// --rename with / in value errors
// ============================================================================
test "rename flag with slash in value errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "src.txt", "data");

    const result = runMove(tmp.dir, &.{ "--rename", "src.txt", "sub/new.txt" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--rename value may not include a '/'") != null);
}

// ============================================================================
// --silent suppresses output (fix #4)
// ============================================================================
test "silent flag suppresses move output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "loud.txt", "data");
    try util.writeFile(tmp.dir, "quiet.txt", "data");

    // without --silent should produce output
    const loud = runMove(tmp.dir, &.{ "loud.txt", "loud_dest.txt" });
    defer loud.deinit();
    try testing.expectEqual(@as(?u8, 0), loud.code);
    try testing.expect(loud.stderr.len > 0);

    // with --silent should produce no ">" move output
    const quiet = runMove(tmp.dir, &.{ "-s", "quiet.txt", "quiet_dest.txt" });
    defer quiet.deinit();
    try testing.expectEqual(@as(?u8, 0), quiet.code);
    try testing.expect(std.mem.indexOf(u8, quiet.stderr, ">") == null);
}

test "silent flag suppresses multi-move summary" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "x.txt", "x");
    try util.writeFile(tmp.dir, "y.txt", "y");
    try tmp.dir.makeDir("dest");

    const result = runMove(tmp.dir, &.{ "-s", "x.txt", "y.txt", "dest/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "moved") == null);
}

// ============================================================================
// --backup creates .backup~ from dest (fix #1)
// ============================================================================
test "backup flag creates backup from dest not src" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "src.txt", "new content");
    try util.writeFile(tmp.dir, "dest.txt", "old content");

    const result = runMove(tmp.dir, &.{ "--backup", "src.txt", "dest.txt" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // src should be gone
    try testing.expect(!util.fileExists(tmp.dir, "src.txt"));

    // dest should have new content
    const dest_content = try util.readFile(tmp.dir, "dest.txt");
    defer testing.allocator.free(dest_content);
    try testing.expectEqualStrings("new content", dest_content);

    // backup should exist with OLD content (from dest, not src)
    const backup_content = try util.readFile(tmp.dir, "dest.txt.backup~");
    defer testing.allocator.free(backup_content);
    try testing.expectEqualStrings("old content", backup_content);
}

// ============================================================================
// src not found error
// ============================================================================
test "src not found produces error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runMove(tmp.dir, &.{ "nonexistent.txt", "dest.txt" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "src not found") != null);
}

// ============================================================================
// src == dest error
// ============================================================================
test "src and dest same location produces error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "same.txt", "data");

    // without a clobber flag, dest-exists fires first
    const result = runMove(tmp.dir, &.{ "same.txt", "same.txt" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "dest path exists") != null);

    // with a clobber flag, same-location check fires
    const result2 = runMove(tmp.dir, &.{ "--backup", "same.txt", "same.txt" });
    defer result2.deinit();
    try testing.expect(result2.code != null and result2.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result2.stderr, "src and dest cannot be same location") != null);
}

test "src and effective dest same location into dir errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "same.txt", "data");

    const result = runMove(tmp.dir, &.{ "--backup", "same.txt", "./" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "src and dest cannot be same location") != null);

    const content = try util.readFile(tmp.dir, "same.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("data", content);
}

test "dangling symlink source can be moved" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "target.txt", "target");
    try tmp.dir.symLink("target.txt", "dangling.link", .{});
    try tmp.dir.deleteFile("target.txt");

    const result = runMove(tmp.dir, &.{ "dangling.link", "moved.link" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    var old_link_buffer: [fs.max_path_bytes]u8 = undefined;
    const old_link = tmp.dir.readLink("dangling.link", &old_link_buffer) catch null;
    try testing.expect(old_link == null);

    var new_link_buffer: [fs.max_path_bytes]u8 = undefined;
    const new_link = try tmp.dir.readLink("moved.link", &new_link_buffer);
    try testing.expectEqualStrings("target.txt", new_link);
}

test "trash clobber moves existing dest into isolated trash dir" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "src.txt", "new content");
    try util.writeFile(tmp.dir, "dest.txt", "old content");
    try tmp.dir.makePath("tmp_trash/files");
    try tmp.dir.makePath("tmp_trash/info");

    const result = runMoveWithEnv(
        tmp.dir,
        &.{ "--trash", "src.txt", "dest.txt" },
        &.{
            .{ .key = "SAFEUTILS_TRASH_DIR", .value = "tmp_trash/files" },
            .{ .key = "SAFEUTILS_TRASH_INFO_DIR", .value = "tmp_trash/info" },
        },
    );
    defer result.deinit();

    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(!util.fileExists(tmp.dir, "src.txt"));

    const dest_content = try util.readFile(tmp.dir, "dest.txt");
    defer testing.allocator.free(dest_content);
    try testing.expectEqualStrings("new content", dest_content);

    const trashed = try util.readFile(tmp.dir, "tmp_trash/files/dest.txt");
    defer testing.allocator.free(trashed);
    try testing.expectEqualStrings("old content", trashed);
}

test "multi-source precheck failure prevents all moves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "a.txt", "aaa");
    try tmp.dir.makeDir("dest");

    const result = runMove(tmp.dir, &.{ "a.txt", "missing.txt", "dest/" });
    defer result.deinit();

    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "src path not found") != null);
    try testing.expect(util.fileExists(tmp.dir, "a.txt"));
    try testing.expect(!util.fileExists(tmp.dir, "dest/a.txt"));
}

// ============================================================================
// dest exists without clobber flag errors
// ============================================================================
test "dest exists without clobber flag produces error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "src.txt", "new");
    try util.writeFile(tmp.dir, "dest.txt", "old");

    const result = runMove(tmp.dir, &.{ "src.txt", "dest.txt" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "dest path exists") != null);

    // both files should still exist (no partial move)
    try testing.expect(util.fileExists(tmp.dir, "src.txt"));
    try testing.expect(util.fileExists(tmp.dir, "dest.txt"));
}

// ============================================================================
// --help prints help text
// ============================================================================
test "help flag prints help text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runMove(tmp.dir, &.{"-h"});
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Usage: move") != null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--rename") != null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--trash") != null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--backup") != null);
}

// ============================================================================
// help_msg typos are fixed (fix #6)
// ============================================================================
test "help text has correct spelling" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runMove(tmp.dir, &.{"-h"});
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // fixed typos should not appear
    try testing.expect(std.mem.indexOf(u8, result.stderr, "moveing") == null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Everyting") == null);

    // correct text should appear
    try testing.expect(std.mem.indexOf(u8, result.stderr, "When moving files") != null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Everything must move") != null);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "clobber flags") != null);
}

// ============================================================================
// --rename error message says --rename not --remove (fix #3)
// ============================================================================
test "rename with slash in dest errors about slash not remove" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "file.txt", "data");
    try tmp.dir.makeDir("dest");

    // --rename with dest containing / should error about the slash
    const result = runMove(tmp.dir, &.{ "--rename", "file.txt", "dest/" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--rename value may not include") != null);
    // must NOT say --remove anywhere
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--remove") == null);
}

// ============================================================================
// no args prints usage
// ============================================================================
test "no args prints usage and exits with error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runMove(tmp.dir, &.{});
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "USAGE: move") != null);
}

// ============================================================================
// move directory
// ============================================================================
test "move directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("srcdir");
    try util.writeFile(tmp.dir, "srcdir/file.txt", "dir content");

    const result = runMove(tmp.dir, &.{ "srcdir", "destdir" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    try testing.expect(!util.dirExists(tmp.dir, "srcdir"));
    try testing.expect(util.dirExists(tmp.dir, "destdir"));
    const content = try util.readFile(tmp.dir, "destdir/file.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("dir content", content);
}
