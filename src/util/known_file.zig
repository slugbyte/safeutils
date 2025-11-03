const std = @import("std");
const util = @import("../root.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub fn dirpathHome(allocator: Allocator) []const u8 {
    return (util.env.getAlloc(allocator, "HOME") catch {
        @panic("env $HOME needs to exist");
    }).?;
}

pub fn dirpathTrash(allocator: Allocator) ![]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            const home = dirpathHome(allocator);
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{
                home,
                ".local/share/Trash/files",
            });
        },
        .macos => {
            const home = dirpathHome(allocator);
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{
                home,
                ".Trash",
            });
        },
        else => @compileError("os not supported"),
    }
}

/// cheate a filename for a trash file `{original_name}__{timestamp}.trash`
pub fn trashFilenameTimestamp(allocator: Allocator, file_name: []const u8) ![]const u8 {
    const trash_dirpath = try dirpathTrash(allocator);
    defer allocator.free(trash_dirpath);
    return try util.fmt(allocator, "{s}/{s}__{d}.trash", .{ trash_dirpath, file_name, std.time.milliTimestamp() });
}

/// cheate a filename for a trash file `{original_name}__{timestamp}_{random}.trash`
pub fn trashFilenameTimestampRandom(allocator: Allocator, file_name: []const u8) ![]const u8 {
    const trash_dirpath = try dirpathTrash(allocator);
    defer allocator.free(trash_dirpath);
    var rand_buffer: [4]u8 = undefined;
    std.crypto.random.bytes(&rand_buffer);
    return try util.fmt(allocator, "{s}/{s}__{d}_{X}.trash", .{ trash_dirpath, file_name, std.time.milliTimestamp(), rand_buffer });
}

/// cheate a filename for a trash file `{original_name}__{url_safe_b64_digest}.trash`
/// NOTE: it only uses the first 16 byets of the digest to shorten the output
pub fn trashFilenameDigest(allocator: Allocator, file_name: []const u8, digest: []const u8) ![]const u8 {
    const trash_dirpath = try dirpathTrash(allocator);
    defer allocator.free(trash_dirpath);

    // truncating digest to 16 bites to shorten the output
    // b64_buffer len ==  22 == std.base64.url_safe_no_pad.Encoder.calcSize(16);
    var b64_buffer: [22]u8 = undefined;
    const b64_short_digest = std.base64.url_safe_no_pad.Encoder.encode(&b64_buffer, digest[0..16]);

    return try util.fmt(allocator, "{s}/{s}__{s}.trash", .{ trash_dirpath, file_name, b64_short_digest });
}
