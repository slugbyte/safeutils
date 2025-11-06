const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const getEnvMap = std.process.getEnvMap;
pub const get = std.process.getEnvVarOwned;

/// get an env var or null
pub fn getOptional(allocator: Allocator, key: []const u8) !?[]u8 {
    const result = get(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    return result;
}

/// buf get an env var or null
pub fn getBuf(buffer: []u8, key: []const u8) ![]u8 {
    var fbo = std.heap.FixedBufferAllocator.init(buffer);
    return try get(fbo.allocator(), key);
}

/// buf get an env var or null
pub fn getBufOptional(buffer: []u8, key: []const u8) !?[]u8 {
    var fbo = std.heap.FixedBufferAllocator.init(buffer);
    return try getOptional(fbo.allocator(), key);
}

/// check if an env var is set
pub fn exists(key: []const u8) !bool {
    var buffer: [1]u8 = undefined;
    _ = getBuf(&buffer, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        error.OutOfMemory => return true,
        else => return err,
    };
    return true;
}
