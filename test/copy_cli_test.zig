const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const test_config = @import("test_config");
const Child = std.process.Child;

const CopyResult = struct {
    stderr: []u8,
    stdout: []u8,
    code: ?u8,

    fn deinit(self: CopyResult) void {
        testing.allocator.free(self.stderr);
        testing.allocator.free(self.stdout);
    }
};

/// Resolve the copy binary to an absolute path once and cache it.
/// Uses a simple fixed buffer to avoid allocator leak issues with the test allocator.
var resolved_path_buf: [fs.max_path_bytes]u8 = undefined;
var resolved_path_len: ?usize = null;

fn getCopyExePath() []const u8 {
    if (resolved_path_len) |len| return resolved_path_buf[0..len];
    const result = fs.cwd().realpath(test_config.copy_exe_path, &resolved_path_buf) catch
        @panic("failed to resolve copy binary path");
    resolved_path_len = result.len;
    return result;
}

/// Runs the `copy` binary with the given args inside `cwd_dir`.
/// Returns the captured stderr output and the exit code.
fn runCopy(cwd_dir: fs.Dir, args: []const []const u8) CopyResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);

    argv.append(testing.allocator, getCopyExePath()) catch @panic("OOM");
    argv.appendSlice(testing.allocator, args) catch @panic("OOM");

    var child = Child.init(argv.items, testing.allocator);
    child.cwd_dir = cwd_dir;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    child.spawn() catch @panic("failed to spawn copy binary");

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    child.collectOutput(testing.allocator, &stdout, &stderr, 64 * 1024) catch @panic("failed to collect output");
    const term = child.wait() catch @panic("failed to wait for copy binary");

    const code: ?u8 = switch (term) {
        .Exited => |c| c,
        else => null,
    };
    return .{
        .stderr = stderr.toOwnedSlice(testing.allocator) catch @panic("OOM"),
        .stdout = stdout.toOwnedSlice(testing.allocator) catch @panic("OOM"),
        .code = code,
    };
}

fn writeFile(dir: fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}

fn readFile(dir: fs.Dir, name: []const u8) ![]u8 {
    return try dir.readFileAlloc(testing.allocator, name, 64 * 1024);
}

fn dirExists(dir: fs.Dir, path: []const u8) bool {
    const stat = dir.statFile(path) catch return false;
    return stat.kind == .directory;
}

// ============================================================================
// Fix #2: --silent suppresses verbose output
// ============================================================================
test "silent flag suppresses verbose copy output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "hello.txt", "hello world");

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
    const loud_content = try readFile(tmp.dir, "loud.txt");
    defer testing.allocator.free(loud_content);
    try testing.expectEqualStrings("hello world", loud_content);

    const quiet_content = try readFile(tmp.dir, "quiet.txt");
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

    try writeFile(tmp.dir, "data.txt", "nested test");

    // copy -c should create a/b/c/ as nested dirs
    const result = runCopy(tmp.dir, &.{ "-c", "data.txt", "a/b/c/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // verify the nested dir structure exists and the file was copied
    try testing.expect(dirExists(tmp.dir, "a"));
    try testing.expect(dirExists(tmp.dir, "a/b"));
    try testing.expect(dirExists(tmp.dir, "a/b/c"));
    const content = try readFile(tmp.dir, "a/b/c/data.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("nested test", content);
}

test "create flag with single level dir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "file.txt", "single level");

    const result = runCopy(tmp.dir, &.{ "-c", "file.txt", "newdir/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    try testing.expect(dirExists(tmp.dir, "newdir"));
    const content = try readFile(tmp.dir, "newdir/file.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("single level", content);
}

// ============================================================================
// Fix #9: typo fixes -- test "copied to itself" error message
// ============================================================================
test "copy to self error says copied to itself" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "same.txt", "self copy");

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
    try writeFile(tmp.dir, "realdir/existing.txt", "existing");

    // create a symlink pointing to realdir
    try tmp.dir.symLink("realdir", "linkdir", .{});

    // create source dir with a new file
    try tmp.dir.makeDir("srcdir");
    try writeFile(tmp.dir, "srcdir/newfile.txt", "new content");

    // merge srcdir into linkdir (should follow symlink to realdir)
    const result = runCopy(tmp.dir, &.{ "-m", "srcdir", "linkdir/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // the new file should exist inside realdir (through the symlink)
    const content = try readFile(tmp.dir, "realdir/srcdir/newfile.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("new content", content);

    // the existing file should still be there
    const existing = try readFile(tmp.dir, "realdir/existing.txt");
    defer testing.allocator.free(existing);
    try testing.expectEqualStrings("existing", existing);
}

// ============================================================================
// Basic sanity tests (also exercise fix #6 -- dir copy with defer close)
// ============================================================================
test "basic file copy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "src.txt", "hello copy");

    const result = runCopy(tmp.dir, &.{ "src.txt", "dest.txt" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // src should still exist (copy, not move)
    const src_content = try readFile(tmp.dir, "src.txt");
    defer testing.allocator.free(src_content);
    try testing.expectEqualStrings("hello copy", src_content);

    // dest should have the same content
    const dest_content = try readFile(tmp.dir, "dest.txt");
    defer testing.allocator.free(dest_content);
    try testing.expectEqualStrings("hello copy", dest_content);
}

test "dir copy with --dir flag" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // create source directory with files
    try tmp.dir.makeDir("srcdir");
    try writeFile(tmp.dir, "srcdir/a.txt", "file a");
    try writeFile(tmp.dir, "srcdir/b.txt", "file b");
    try tmp.dir.makeDir("srcdir/sub");
    try writeFile(tmp.dir, "srcdir/sub/c.txt", "file c");

    const result = runCopy(tmp.dir, &.{ "-d", "srcdir", "destdir" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // verify recursive copy
    try testing.expect(dirExists(tmp.dir, "destdir"));
    const a = try readFile(tmp.dir, "destdir/a.txt");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("file a", a);

    const b = try readFile(tmp.dir, "destdir/b.txt");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("file b", b);

    try testing.expect(dirExists(tmp.dir, "destdir/sub"));
    const c = try readFile(tmp.dir, "destdir/sub/c.txt");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("file c", c);
}

test "copy multiple files into directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "one.txt", "1");
    try writeFile(tmp.dir, "two.txt", "2");
    try tmp.dir.makeDir("dest");

    const result = runCopy(tmp.dir, &.{ "one.txt", "two.txt", "dest/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    const one = try readFile(tmp.dir, "dest/one.txt");
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("1", one);

    const two = try readFile(tmp.dir, "dest/two.txt");
    defer testing.allocator.free(two);
    try testing.expectEqualStrings("2", two);
}

test "copy without required flags for dir src fails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("srcdir");
    try writeFile(tmp.dir, "srcdir/file.txt", "data");

    // trying to copy a directory without --dir or --merge should error
    const result = runCopy(tmp.dir, &.{ "srcdir", "destdir" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "copy dir requires --dir or --merge") != null);
}

test "copy src not found error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = runCopy(tmp.dir, &.{ "nonexistent.txt", "dest.txt" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "src file not found") != null);
}
