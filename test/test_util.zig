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

pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

/// Runs a binary at `exe_path` with the given args inside `cwd_dir`.
/// Returns captured stdout, stderr, and exit code.
pub fn runBinary(exe_path: []const u8, cwd_dir: fs.Dir, args: []const []const u8) CliResult {
    return runBinaryWithEnv(exe_path, cwd_dir, args, &.{});
}

pub fn runBinaryWithEnv(exe_path: []const u8, cwd_dir: fs.Dir, args: []const []const u8, env_overrides: []const EnvVar) CliResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);

    argv.append(testing.allocator, exe_path) catch @panic("OOM");
    argv.appendSlice(testing.allocator, args) catch @panic("OOM");

    var env_map = std.process.getEnvMap(testing.allocator) catch @panic("failed to read env map");
    defer env_map.deinit();
    for (env_overrides) |item| {
        env_map.put(item.key, item.value) catch @panic("failed to set env var");
    }

    var child = Child.init(argv.items, testing.allocator);
    child.cwd_dir = cwd_dir;
    child.env_map = &env_map;
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

pub fn runBinaryWithIsolatedTrash(exe_path: []const u8, cwd_dir: fs.Dir, args: []const []const u8) CliResult {
    const cwd_abs = cwd_dir.realpathAlloc(testing.allocator, ".") catch @panic("failed to resolve cwd path");
    defer testing.allocator.free(cwd_abs);

    const xdg_data_home = std.fmt.allocPrint(testing.allocator, "{s}/.xdg-data", .{cwd_abs}) catch @panic("OOM");
    defer testing.allocator.free(xdg_data_home);

    const xdg_cache_home = std.fmt.allocPrint(testing.allocator, "{s}/.xdg-cache", .{cwd_abs}) catch @panic("OOM");
    defer testing.allocator.free(xdg_cache_home);

    cwd_dir.makePath(".xdg-data/Trash/files") catch @panic("failed to create isolated trash files dir");
    cwd_dir.makePath(".xdg-data/Trash/info") catch @panic("failed to create isolated trash info dir");

    return runBinaryWithEnv(exe_path, cwd_dir, args, &.{
        .{ .key = "HOME", .value = cwd_abs },
        .{ .key = "XDG_DATA_HOME", .value = xdg_data_home },
        .{ .key = "XDG_CACHE_HOME", .value = xdg_cache_home },
    });
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
