const std = @import("std");
const util = @import("./root.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const WorkDir = @This();

dir: std.fs.Dir,

pub fn init(dir: std.fs.Dir) WorkDir {
    return .{
        .dir = dir,
    };
}

pub fn initCWD() WorkDir {
    return init(std.fs.cwd());
}

pub fn openFile(self: WorkDir, path: []const u8, open_flags: std.fs.File.OpenFlags) !std.fs.File {
    return try self.dir.openFile(path, open_flags);
}

pub fn hashFileSha256(self: WorkDir, file: std.fs.File, digest_buffer: *[Sha256.digest_length]u8) !void {
    _ = self;
    const Hashing = std.Io.Writer.Hashing(Sha256);
    var hashing_buffer: [1024]u8 = undefined;
    var hashing = Hashing.initHasher(Sha256.init(.{}), &hashing_buffer);

    var read_buffer: [1024]u8 = undefined;
    var file_reader = file.readerStreaming(&read_buffer);
    _ = try file_reader.interface.streamRemaining(&hashing.writer);
    try hashing.writer.flush();

    hashing.hasher.final(digest_buffer);
}

pub fn hashFilePathSha256(self: WorkDir, path: []const u8, digest_buffer: *[Sha256.digest_length]u8) !void {
    const file = try self.openFile(path, .{});
    defer file.close();

    try self.hashFileSha256(file, digest_buffer);
}

pub fn stat(self: WorkDir, path: []const u8) !?std.fs.File.Stat {
    return self.dir.statFile(path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

pub fn exists(self: WorkDir, path: []const u8) !bool {
    if (try self.stat(path)) |_| {
        return true;
    }
    return false;
}

pub fn trashKind(self: WorkDir, path: []const u8, kind: std.fs.File.Kind) ![]const u8 {
    switch (kind) {
        .file => {
            const file_name = std.fs.path.basename(path);
            var digest: [Sha256.digest_length]u8 = undefined;
            try self.hashFilePathSha256(path, &digest);
            const trash_path = try util.path.trashPathNameDigest(file_name, &digest);
            try self.move(path, trash_path);
            return trash_path;
        },
        .directory, .sym_link => {
            const file_name = std.fs.path.basename(path);
            var trash_path = try util.path.trashPathNameTimestamp(file_name);
            if (try self.exists(trash_path)) {
                trash_path = try util.path.trashPathNameTimestampRandom(file_name);
            }
            try self.move(path, trash_path);
            return trash_path;
        },
        else => {
            return error.TrashFileKindNotSupported;
        },
    }
}

pub fn trashAutoKind(self: WorkDir, path: []const u8) ![]const u8 {
    const path_stat = try self.stat(path);
    return self.trashKind(path, path_stat.kind);
}

pub fn isPathEqual(self: WorkDir, path_a: []const u8, path_b: []const u8) !bool {
    var buffer: [3 * std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = fba.allocator();

    const cwd = try self.dir.realpathAlloc(arena, ".");
    const resolve_a = blk_a: {
        if (std.fs.path.isAbsolute(path_a)) {
            break :blk_a try std.fs.path.resolve(arena, &.{path_a});
        } else {
            break :blk_a try std.fs.path.resolve(arena, &.{ cwd, path_a });
        }
    };
    const resolve_b = blk_b: {
        if (std.fs.path.isAbsolute(path_b)) {
            break :blk_b try std.fs.path.resolve(arena, &.{path_b});
        } else {
            break :blk_b try std.fs.path.resolve(arena, &.{ cwd, path_b });
        }
    };

    return std.mem.eql(u8, resolve_a, resolve_b);
}

pub fn move(self: WorkDir, path_source: []const u8, path_destination: []const u8) !void {
    try self.dir.rename(path_source, path_destination);
}
