const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const test_config = @import("test_config");
const Child = std.process.Child;

const MoveResult = struct {
    stderr: []u8,
    stdout: []u8,
    code: ?u8,

    fn deinit(self: MoveResult) void {
        testing.allocator.free(self.stderr);
        testing.allocator.free(self.stdout);
    }
};

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

/// Runs the `move` binary with the given args inside `cwd_dir`.
fn runMove(cwd_dir: fs.Dir, args: []const []const u8) MoveResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);

    argv.append(testing.allocator, getMoveExePath()) catch @panic("OOM");
    argv.appendSlice(testing.allocator, args) catch @panic("OOM");

    var child = Child.init(argv.items, testing.allocator);
    child.cwd_dir = cwd_dir;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    child.spawn() catch @panic("failed to spawn move binary");

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    child.collectOutput(testing.allocator, &stdout, &stderr, 64 * 1024) catch @panic("failed to collect output");
    const term = child.wait() catch @panic("failed to wait for move binary");

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

fn fileExists(dir: fs.Dir, path: []const u8) bool {
    _ = dir.statFile(path) catch return false;
    return true;
}

fn dirExists(dir: fs.Dir, path: []const u8) bool {
    const stat = dir.statFile(path) catch return false;
    return stat.kind == .directory;
}

// ============================================================================
// Basic move
// ============================================================================
test "basic file move" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "src.txt", "hello move");

    const result = runMove(tmp.dir, &.{ "src.txt", "dest.txt" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // src should be gone
    try testing.expect(!fileExists(tmp.dir, "src.txt"));

    // dest should have the content
    const content = try readFile(tmp.dir, "dest.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello move", content);
}

// ============================================================================
// Move into directory with trailing /
// ============================================================================
test "move file into directory with trailing slash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "file.txt", "into dir");
    try tmp.dir.makeDir("dest");

    const result = runMove(tmp.dir, &.{ "file.txt", "dest/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    try testing.expect(!fileExists(tmp.dir, "file.txt"));
    const content = try readFile(tmp.dir, "dest/file.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("into dir", content);
}

// ============================================================================
// Multi-move into directory
// ============================================================================
test "move multiple files into directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "a.txt", "aaa");
    try writeFile(tmp.dir, "b.txt", "bbb");
    try tmp.dir.makeDir("dest");

    const result = runMove(tmp.dir, &.{ "a.txt", "b.txt", "dest/" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    try testing.expect(!fileExists(tmp.dir, "a.txt"));
    try testing.expect(!fileExists(tmp.dir, "b.txt"));

    const a = try readFile(tmp.dir, "dest/a.txt");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("aaa", a);

    const b = try readFile(tmp.dir, "dest/b.txt");
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
    try writeFile(tmp.dir, "sub/old.txt", "rename me");

    const result = runMove(tmp.dir, &.{ "--rename", "sub/old.txt", "new.txt" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    try testing.expect(!fileExists(tmp.dir, "sub/old.txt"));
    const content = try readFile(tmp.dir, "sub/new.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("rename me", content);
}

// ============================================================================
// --rename with multiple sources errors (fix #5)
// ============================================================================
test "rename flag with multiple sources errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "a.txt", "a");
    try writeFile(tmp.dir, "b.txt", "b");
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

    try writeFile(tmp.dir, "src.txt", "data");

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

    try writeFile(tmp.dir, "loud.txt", "data");
    try writeFile(tmp.dir, "quiet.txt", "data");

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

    try writeFile(tmp.dir, "x.txt", "x");
    try writeFile(tmp.dir, "y.txt", "y");
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

    try writeFile(tmp.dir, "src.txt", "new content");
    try writeFile(tmp.dir, "dest.txt", "old content");

    const result = runMove(tmp.dir, &.{ "--backup", "src.txt", "dest.txt" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    // src should be gone
    try testing.expect(!fileExists(tmp.dir, "src.txt"));

    // dest should have new content
    const dest_content = try readFile(tmp.dir, "dest.txt");
    defer testing.allocator.free(dest_content);
    try testing.expectEqualStrings("new content", dest_content);

    // backup should exist with OLD content (from dest, not src)
    const backup_content = try readFile(tmp.dir, "dest.txt.backup~");
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

    try writeFile(tmp.dir, "same.txt", "data");

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

// ============================================================================
// dest exists without clobber flag errors
// ============================================================================
test "dest exists without clobber flag produces error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "src.txt", "new");
    try writeFile(tmp.dir, "dest.txt", "old");

    const result = runMove(tmp.dir, &.{ "src.txt", "dest.txt" });
    defer result.deinit();
    try testing.expect(result.code != null and result.code.? != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "dest path exists") != null);

    // both files should still exist (no partial move)
    try testing.expect(fileExists(tmp.dir, "src.txt"));
    try testing.expect(fileExists(tmp.dir, "dest.txt"));
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

    try writeFile(tmp.dir, "file.txt", "data");
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
    try writeFile(tmp.dir, "srcdir/file.txt", "dir content");

    const result = runMove(tmp.dir, &.{ "srcdir", "destdir" });
    defer result.deinit();
    try testing.expectEqual(@as(?u8, 0), result.code);

    try testing.expect(!dirExists(tmp.dir, "srcdir"));
    try testing.expect(dirExists(tmp.dir, "destdir"));
    const content = try readFile(tmp.dir, "destdir/file.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("dir content", content);
}
