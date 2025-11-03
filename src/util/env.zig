const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// buf get an env var or null
pub fn getBuf(buffer: []u8, key: []const u8) !?[]u8 {
    var fbo = std.heap.FixedBufferAllocator.init(buffer);
    return try getAlloc(fbo.allocator(), key);
}

/// get an env var or null
pub fn getAlloc(allocator: Allocator, key: []const u8) !?[]u8 {
    const result = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };

    if (result.len == 0) return null;
    return result;
}

/// check if an env var is set
pub fn exists(key: []const u8) bool {
    var buffer: [1]u8 = undefined;
    const value = getBuf(&buffer, key) catch |err| switch (err) {
        error.OutOfMemory => return true,
    };
    if (value == null) return false;
    return true;
}
