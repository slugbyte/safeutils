const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const test_config = @import("test_config");
const util = @import("test_util.zig");

/// Resolve the copy binary to an absolute path once and cache it.
var resolved_path_buf: [fs.max_path_bytes]u8 = undefined;
var resolved_path_len: ?usize = null;

fn getCopyExePath() []const u8 {
    if (resolved_path_len) |len| return resolved_path_buf[0..len];
    const result = fs.cwd().realpath(test_config.copy_exe_path, &resolved_path_buf) catch
        @panic("failed to resolve copy binary path");
    resolved_path_len = result.len;
    return result;
}

fn runCopy(cwd_dir: fs.Dir, args: []const []const u8) util.CliResult {
    return util.runBinary(getCopyExePath(), cwd_dir, args);
}

fn runCopyWithEnv(cwd_dir: fs.Dir, args: []const []const u8, env_overrides: []const util.EnvVar) util.CliResult {
    return util.runBinaryWithEnv(getCopyExePath(), cwd_dir, args, env_overrides);
}

// ============================================================================
// Fix #2: --silent suppresses verbose output
// ============================================================================
test "silent flag suppresses verbose copy output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "hello.txt", "hello world");

    // copy WITHOUT --silent should produce output on stderr
    const loud = runCopy(tmp.dir, &.{ "hello.txt", "loud.txt" });
    defer loud.deinit();
    try testing.expectEqual(@as(?u8, 0), loud.code);
    try testing.expect(loud.stderr.len > 0);
    try testing.expect(std.mem.indexOf(u8, loud.stderr, "->") != null);

    // copy WITH --silent should produce no "->" copy output on stderr
    // (note: Debug builds print diagnostic info regardless of --silent)
    const quiet = runCopy(tmp.dir, &.{ "-s", "hello.txt", "quiet.txt" });
    defer quiet.deinit();
    try testing.expectEqual(@as(?u8, 0), quiet.code);
    try testing.expect(std.mem.indexOf(u8, quiet.stderr, "->") == null);

    // both destination files should exist and contain the right data
    const loud_content = try util.readFile(tmp.dir, "loud.txt");
    defer testing.allocator.free(loud_content);
    try testing.expectEqualStrings("hello world", loud_content);

    const quiet_content = try util.readFile(tmp.dir, "quiet.txt");
    defer testing.allocator.free(quiet_content);
    try testing.expectEqualStrings("hello world", quiet_content);
}

// ============================================================================
// Fix #3: --help text says "print this help" not "print this version"
// ============================================================================
test "help flag prints correct help text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runCopy(tmp.dir, &.{"-h"});
    defer result.deinit();
    // help exits 0
    try testing.expectEqual(@as(?u8, 0), result.code);
    // must contain the corrected text
    try testing.expect(std.mem.indexOf(u8, result.stderr, "print this help") != null);
    // check that "print this help" appears after "--help"
    const help_pos = std.mem.indexOf(u8, result.stderr, "--help") orelse
        return error.TestUnexpectedResult;
    const after_help = result.stderr[help_pos..];
    try testing.expect(std.mem.indexOf(u8, after_help, "print this help") != null);
}

// ============================================================================
// Fix #5 & #15: --create with nested dirs (makePath instead of makeDir)
// ============================================================================
test "create flag creates nested destination directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "data.txt", "nested test");

    // copy -c should create a/b/c/ as nested dirs
    const result = runCopy(tmp.dir, &.{ "-c", "data.txt", "a/b/c/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // verify the nested dir structure exists and the file was copied
    try testing.expect(util.dirExists(tmp.dir, "a"));
    try testing.expect(util.dirExists(tmp.dir, "a/b"));
    try testing.expect(util.dirExists(tmp.dir, "a/b/c"));
    const content = try util.readFile(tmp.dir, "a/b/c/data.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("nested test", content);
}

test "create flag with single level dir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "file.txt", "single level");

    const result = runCopy(tmp.dir, &.{ "-c", "file.txt", "newdir/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    try testing.expect(util.dirExists(tmp.dir, "newdir"));
    const content = try util.readFile(tmp.dir, "newdir/file.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("single level", content);
}

// ============================================================================
// Fix #9: typo fixes -- test "copied to itself" error message
// ============================================================================
test "copy to self error says copied to itself" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "same.txt", "self copy");

    const result = runCopy(tmp.dir, &.{ "same.txt", "same.txt" });
    defer result.deinit();
    // should fail
    try testing.expect(result.code != null and result.code.? != 0);
    // error message should contain the corrected text
    try testing.expect(std.mem.indexOf(u8, result.stderr, "copied to itself") != null);
}

test "dir flag help text says clobber not cobber" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runCopy(tmp.dir, &.{"-h"});
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);
    // must contain "clobber" in the --dir description
    try testing.expect(std.mem.indexOf(u8, result.stderr, "clobber conflicts") != null);
    // must NOT contain "cobber"
    try testing.expect(std.mem.indexOf(u8, result.stderr, "cobber") == null);
}

// ============================================================================
// Fix #19: --merge follows symlinks on dest
// ============================================================================
test "merge follows dest symlink to directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // create real dest dir with an existing file
    try tmp.dir.makeDir("realdir");
    try util.writeFile(tmp.dir, "realdir/existing.txt", "existing");

    // create a symlink pointing to realdir
    try tmp.dir.symLink("realdir", "linkdir", .{});

    // create source dir with a new file
    try tmp.dir.makeDir("srcdir");
    try util.writeFile(tmp.dir, "srcdir/newfile.txt", "new content");

    // merge srcdir into linkdir (should follow symlink to realdir)
    const result = runCopy(tmp.dir, &.{ "-m", "srcdir", "linkdir/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // the new file should exist inside realdir (through the symlink)
    const content = try util.readFile(tmp.dir, "realdir/srcdir/newfile.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("new content", content);

    // the existing file should still be there
    const existing = try util.readFile(tmp.dir, "realdir/existing.txt");
    defer testing.allocator.free(existing);
    try testing.expectEqualStrings("existing", existing);
}

// ============================================================================
// Basic sanity tests (also exercise fix #6 -- dir copy with defer close)
// ============================================================================
test "basic file copy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "src.txt", "hello copy");

    const result = runCopy(tmp.dir, &.{ "src.txt", "dest.txt" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // src should still exist (copy, not move)
    const src_content = try util.readFile(tmp.dir, "src.txt");
    defer testing.allocator.free(src_content);
    try testing.expectEqualStrings("hello copy", src_content);

    // dest should have the same content
    const dest_content = try util.readFile(tmp.dir, "dest.txt");
    defer testing.allocator.free(dest_content);
    try testing.expectEqualStrings("hello copy", dest_content);
}

test "dir copy with --dir flag" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // create source directory with files
    try tmp.dir.makeDir("srcdir");
    try util.writeFile(tmp.dir, "srcdir/a.txt", "file a");
    try util.writeFile(tmp.dir, "srcdir/b.txt", "file b");
    try tmp.dir.makeDir("srcdir/sub");
    try util.writeFile(tmp.dir, "srcdir/sub/c.txt", "file c");

    const result = runCopy(tmp.dir, &.{ "-d", "srcdir", "destdir" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // verify recursive copy
    try testing.expect(util.dirExists(tmp.dir, "destdir"));
    const a = try util.readFile(tmp.dir, "destdir/a.txt");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("file a", a);

    const b = try util.readFile(tmp.dir, "destdir/b.txt");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("file b", b);

    try testing.expect(util.dirExists(tmp.dir, "destdir/sub"));
    const c = try util.readFile(tmp.dir, "destdir/sub/c.txt");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("file c", c);
}

test "copy multiple files into directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "one.txt", "1");
    try util.writeFile(tmp.dir, "two.txt", "2");
    try tmp.dir.makeDir("dest");

    const result = runCopy(tmp.dir, &.{ "one.txt", "two.txt", "dest/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    const one = try util.readFile(tmp.dir, "dest/one.txt");
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("1", one);

    const two = try util.readFile(tmp.dir, "dest/two.txt");
    defer testing.allocator.free(two);
    try testing.expectEqualStrings("2", two);
}

test "existing directory dest without slash errors in no-clobber mode" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "src.txt", "hello");
    try tmp.dir.makeDir("dest");

    const result = runCopy(tmp.dir, &.{ "src.txt", "dest" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "use clobber flags or add '/' to copy into dir") != null);

    const src_content = try util.readFile(tmp.dir, "src.txt");
    defer testing.allocator.free(src_content);
    try testing.expectEqualStrings("hello", src_content);
}

test "backup clobber handles dangling backup symlink path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "src.txt", "new content");
    try util.writeFile(tmp.dir, "dest.txt", "old content");
    try tmp.dir.symLink("missing-target.txt", "dest.txt.backup~", .{});

    const result = runCopy(tmp.dir, &.{ "--backup", "src.txt", "dest.txt" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    const dest_content = try util.readFile(tmp.dir, "dest.txt");
    defer testing.allocator.free(dest_content);
    try testing.expectEqualStrings("new content", dest_content);

    const backup_content = try util.readFile(tmp.dir, "dest.txt.backup~");
    defer testing.allocator.free(backup_content);
    try testing.expectEqualStrings("old content", backup_content);
}

test "trash clobber moves existing dest into isolated trash dir" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "src.txt", "new content");
    try util.writeFile(tmp.dir, "dest.txt", "old content");
    try tmp.dir.makePath("tmp_trash/files");
    try tmp.dir.makePath("tmp_trash/info");

    const result = runCopyWithEnv(
        tmp.dir,
        &.{ "--trash", "src.txt", "dest.txt" },
        &.{
            .{ .key = "SAFEUTILS_TRASH_DIR", .value = "tmp_trash/files" },
            .{ .key = "SAFEUTILS_TRASH_INFO_DIR", .value = "tmp_trash/info" },
        },
    );
    defer result.deinit();

    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(util.fileExists(tmp.dir, "src.txt"));

    const dest_content = try util.readFile(tmp.dir, "dest.txt");
    defer testing.allocator.free(dest_content);
    try testing.expectEqualStrings("new content", dest_content);

    const trashed = try util.readFile(tmp.dir, "tmp_trash/files/dest.txt");
    defer testing.allocator.free(trashed);
    try testing.expectEqualStrings("old content", trashed);
}

test "copying symlink copies link target path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "target.txt", "target body");
    try tmp.dir.symLink("target.txt", "link.txt", .{});

    const result = runCopy(tmp.dir, &.{ "link.txt", "copied_link.txt" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    var link_buffer: [fs.max_path_bytes]u8 = undefined;
    const link_target = try tmp.dir.readLink("copied_link.txt", &link_buffer);
    try testing.expectEqualStrings("target.txt", link_target);
}

test "copy without required flags for dir src fails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("srcdir");
    try util.writeFile(tmp.dir, "srcdir/file.txt", "data");

    // trying to copy a directory without --dir or --merge should error
    const result = runCopy(tmp.dir, &.{ "srcdir", "destdir" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "copy dir requires --dir or --merge") != null);
}

// ============================================================================
// --merge conflict handling: file->dir is not silently merged
// ============================================================================
test "merge mode file onto existing dir errors without clobber" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Source: srcdir/conflict is a regular file.
    try tmp.dir.makeDir("srcdir");
    try util.writeFile(tmp.dir, "srcdir/conflict", "I am a file");

    // Destination already has destdir/srcdir/conflict as a directory.
    // This creates a file-on-dir conflict at the merge destination.
    try tmp.dir.makePath("destdir/srcdir/conflict");
    try util.writeFile(tmp.dir, "destdir/srcdir/conflict/keep.txt", "keep me");

    const result = runCopy(tmp.dir, &.{ "-m", "srcdir", "destdir/" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "dest path exists") != null);

    // The existing directory should be untouched.
    const kept = try util.readFile(tmp.dir, "destdir/srcdir/conflict/keep.txt");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("keep me", kept);
}

test "merge mode dir-on-dir preserves destination directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Source: srcdir/sub/new.txt
    try tmp.dir.makeDir("srcdir");
    try tmp.dir.makeDir("srcdir/sub");
    try util.writeFile(tmp.dir, "srcdir/sub/new.txt", "new");

    // Destination already has destdir/srcdir/sub/old.txt.
    // The dir-on-dir merge should preserve destdir/srcdir/sub/ and add new.txt.
    try tmp.dir.makePath("destdir/srcdir/sub");
    try util.writeFile(tmp.dir, "destdir/srcdir/sub/old.txt", "old");

    const result = runCopy(tmp.dir, &.{ "-m", "srcdir", "destdir/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // Both files should coexist in the merged directory.
    const old = try util.readFile(tmp.dir, "destdir/srcdir/sub/old.txt");
    defer testing.allocator.free(old);
    try testing.expectEqualStrings("old", old);

    const new = try util.readFile(tmp.dir, "destdir/srcdir/sub/new.txt");
    defer testing.allocator.free(new);
    try testing.expectEqualStrings("new", new);
}

test "copy src not found error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runCopy(tmp.dir, &.{ "nonexistent.txt", "dest.txt" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "src file not found") != null);
}

// ============================================================================
// Undo helpers
// ============================================================================
fn runCopyIsolated(cwd_dir: fs.Dir, args: []const []const u8) util.CliResult {
    const cwd_abs = cwd_dir.realpathAlloc(testing.allocator, ".") catch @panic("failed to resolve cwd path");
    defer testing.allocator.free(cwd_abs);
    const xdg_cache = std.fmt.allocPrint(testing.allocator, "{s}/.xdg-cache", .{cwd_abs}) catch @panic("OOM");
    defer testing.allocator.free(xdg_cache);
    const xdg_data = std.fmt.allocPrint(testing.allocator, "{s}/.xdg-data", .{cwd_abs}) catch @panic("OOM");
    defer testing.allocator.free(xdg_data);
    cwd_dir.makePath(".xdg-data/Trash/files") catch {};
    cwd_dir.makePath(".xdg-data/Trash/info") catch {};
    return runCopyWithEnv(cwd_dir, args, &.{
        .{ .key = "HOME", .value = cwd_abs },
        .{ .key = "XDG_CACHE_HOME", .value = xdg_cache },
        .{ .key = "XDG_DATA_HOME", .value = xdg_data },
    });
}

// ============================================================================
// --undo: basic undo removes copied file
// ============================================================================
test "undo removes a copied file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "src.txt", "undo copy");

    const copy_result = runCopyIsolated(tmp.dir, &.{ "src.txt", "dest.txt" });
    defer copy_result.deinit();
    try testing.expectEqual(@as(?u8, 0), copy_result.code);
    try testing.expect(util.fileExists(tmp.dir, "dest.txt"));

    const undo_result = runCopyIsolated(tmp.dir, &.{"--undo"});
    defer undo_result.deinit();
    try testing.expectEqual(@as(?u8, 0), undo_result.code);

    // src should still exist (it was copied, not moved).
    try testing.expect(util.fileExists(tmp.dir, "src.txt"));
    // dest should be removed by undo.
    try testing.expect(!util.fileExists(tmp.dir, "dest.txt"));
}

// ============================================================================
// --undo: nothing to undo
// ============================================================================
test "copy undo with empty log prints nothing to undo" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runCopyIsolated(tmp.dir, &.{"--undo"});
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "nothing to undo") != null);
}

// ============================================================================
// --undo: undo directory copy removes created dirs
// ============================================================================
test "undo removes recursively copied directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("srcdir");
    try util.writeFile(tmp.dir, "srcdir/a.txt", "aaa");

    const copy_result = runCopyIsolated(tmp.dir, &.{ "-d", "srcdir", "destdir" });
    defer copy_result.deinit();
    try testing.expectEqual(@as(?u8, 0), copy_result.code);
    try testing.expect(util.dirExists(tmp.dir, "destdir"));

    const undo_result = runCopyIsolated(tmp.dir, &.{"--undo"});
    defer undo_result.deinit();
    try testing.expectEqual(@as(?u8, 0), undo_result.code);

    try testing.expect(!util.dirExists(tmp.dir, "destdir"));
    // src should still exist.
    try testing.expect(util.dirExists(tmp.dir, "srcdir"));
}

// ============================================================================
// --undo: undo with backup clobber reversal
// ============================================================================
test "copy undo reverses backup clobber" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "src.txt", "new");
    try util.writeFile(tmp.dir, "dest.txt", "old");

    const copy_result = runCopyIsolated(tmp.dir, &.{ "--backup", "src.txt", "dest.txt" });
    defer copy_result.deinit();
    try testing.expectEqual(@as(?u8, 0), copy_result.code);

    const undo_result = runCopyIsolated(tmp.dir, &.{"--undo"});
    defer undo_result.deinit();
    try testing.expectEqual(@as(?u8, 0), undo_result.code);

    // dest should be restored to old content.
    const dest_content = try util.readFile(tmp.dir, "dest.txt");
    defer testing.allocator.free(dest_content);
    try testing.expectEqualStrings("old", dest_content);

    // backup file should be gone.
    try testing.expect(!util.fileExists(tmp.dir, "dest.txt.backup~"));
}

// ============================================================================
// --undo: short flag -u works
// ============================================================================
test "short flag -u works for copy undo" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "src.txt", "short");

    const copy_result = runCopyIsolated(tmp.dir, &.{ "src.txt", "dest.txt" });
    defer copy_result.deinit();
    try testing.expectEqual(@as(?u8, 0), copy_result.code);

    const undo_result = runCopyIsolated(tmp.dir, &.{"-u"});
    defer undo_result.deinit();
    try testing.expectEqual(@as(?u8, 0), undo_result.code);

    try testing.expect(!util.fileExists(tmp.dir, "dest.txt"));
}

// ============================================================================
// --undo: undo only undoes the most recent copy
// ============================================================================
test "copy undo only undoes the most recent operation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.writeFile(tmp.dir, "first.txt", "first");
    try util.writeFile(tmp.dir, "second.txt", "second");

    const copy1 = runCopyIsolated(tmp.dir, &.{ "first.txt", "first_dest.txt" });
    defer copy1.deinit();
    try testing.expectEqual(@as(?u8, 0), copy1.code);

    const copy2 = runCopyIsolated(tmp.dir, &.{ "second.txt", "second_dest.txt" });
    defer copy2.deinit();
    try testing.expectEqual(@as(?u8, 0), copy2.code);

    const undo_result = runCopyIsolated(tmp.dir, &.{"--undo"});
    defer undo_result.deinit();
    try testing.expectEqual(@as(?u8, 0), undo_result.code);

    // first_dest should still exist (not undone).
    try testing.expect(util.fileExists(tmp.dir, "first_dest.txt"));
    // second_dest should be removed.
    try testing.expect(!util.fileExists(tmp.dir, "second_dest.txt"));
}
