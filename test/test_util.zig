const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const Child = std.process.Child;

/// Result from running a CLI binary in a test.
pub const CliResult = struct {
    stderr: []u8,
    stdout: []u8,
    code: ?u8,

    pub fn deinit(self: CliResult) void {
        testing.allocator.free(self.stderr);
        testing.allocator.free(self.stdout);
    }
};

/// Runs a binary at `exe_path` with the given args inside `cwd_dir`.
/// Returns captured stdout, stderr, and exit code.
pub fn runBinary(exe_path: []const u8, cwd_dir: fs.Dir, args: []const []const u8) CliResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);

    argv.append(testing.allocator, exe_path) catch @panic("OOM");
    argv.appendSlice(testing.allocator, args) catch @panic("OOM");

    var child = Child.init(argv.items, testing.allocator);
    child.cwd_dir = cwd_dir;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    child.spawn() catch @panic("failed to spawn binary");

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    child.collectOutput(testing.allocator, &stdout, &stderr, 64 * 1024) catch @panic("failed to collect output");
    const term = child.wait() catch @panic("failed to wait for binary");

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

pub fn writeFile(dir: fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}

pub fn readFile(dir: fs.Dir, name: []const u8) ![]u8 {
    return try dir.readFileAlloc(testing.allocator, name, 64 * 1024);
}

pub fn fileExists(dir: fs.Dir, path: []const u8) bool {
    _ = dir.statFile(path) catch return false;
    return true;
}

pub fn dirExists(dir: fs.Dir, path: []const u8) bool {
    const stat = dir.statFile(path) catch return false;
    return stat.kind == .directory;
}
