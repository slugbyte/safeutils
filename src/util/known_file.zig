const std = @import("std");
const util = @import("../root.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub fn dirpathHome(allocator: Allocator) []const u8 {
    return (util.env.getAlloc(allocator, "HOME") catch {
        @panic("env $HOME needs to exist");
    }).?;
}

pub fn dirpathTrashInfo(allocator: Allocator) ![]const u8 {
    if (builtin.os.tag != .linux) {
        @compileError("sorry trash info is only for linux");
    }
    const home = dirpathHome(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{
        home,
        ".local/share/Trash/info",
    });
}

pub fn dirpathTrash(allocator: Allocator) ![]const u8 {
    var home_dirpath_sa = util.StackFilepathAllocator.empty;
    const home_dirpath = dirpathHome(home_dirpath_sa.allocatorInvalidatePrevious());
    switch (builtin.os.tag) {
        .linux => {
            return std.fs.path.join(allocator, &.{
                home_dirpath,
                ".local/share/Trash/files",
            });
        },
        .macos => {
            return std.fs.path.join(allocator, &.{
                home_dirpath,
                ".Trash",
            });
        },
        else => @compileError("os not supported"),
    }
}

/// parses and creates filenames with a counter before the extension
/// used when trying to make sure files don't have naming confilcts
pub const FilenameBumper = struct {
    ext: []const u8,
    name: []const u8,
    count: ?usize,

    // parse the name of a filepath (should not include dirname)
    pub fn parse(filename: []const u8) FilenameBumper {
        const ext = std.fs.path.extension(filename);
        var name = filename[0 .. filename.len - ext.len];
        var count: ?usize = null;

        var end_digit_count: usize = 0;
        for (0..name.len) |i| {
            if (std.ascii.isDigit(name[name.len - i - 1])) {
                end_digit_count += 1;
            }
        }
        if (end_digit_count > 0) {
            count = std.fmt.parseInt(usize, name[name.len - end_digit_count ..], 10) catch null;
        }
        if (count != null) {
            name = name[0 .. name.len - end_digit_count];
        }
        name = std.mem.trimEnd(u8, name[0 .. name.len - end_digit_count], "-_ .");
        return .{
            .ext = ext,
            .name = name,
            .count = count,
        };
    }

    /// parse the basename of a filepath
    pub fn parseBasename(filepath: []u8) FilenameBumper {
        return try parse(std.fs.path.basename(filepath));
    }

    pub fn bump(self: *FilenameBumper) void {
        if (self.count) |count| {
            self.count = count + 1;
            return;
        }
        self.count = 0;
    }

    pub fn fmtTrashpath(self: FilenameBumper, allocator: Allocator) ![]u8 {
        var trash_dirpath_sa = util.StackFilepathAllocator.empty;
        const trash_dirpath = try dirpathTrash(trash_dirpath_sa.allocatorInvalidatePrevious());

        return try self.fmtFilepath(allocator, trash_dirpath);
    }

    // create a filename and join it onto the dirpath
    pub fn fmtFilepath(self: FilenameBumper, allocator: Allocator, dirpath: []const u8) ![]u8 {
        var trashname_sa = util.StackFilenameAllocator.empty;
        const trashname = try self.fmtFilename(trashname_sa.allocatorInvalidatePrevious());

        return try std.fs.path.join(allocator, &.{
            dirpath,
            trashname,
        });
    }

    // create a filename
    pub fn fmtFilename(self: FilenameBumper, allocator: Allocator) ![]u8 {
        if (self.count) |count| {
            if (self.name.len > 0) {
                return try util.fmt(allocator, "{s}_{d:0>2}{s}", .{ self.name, count, self.ext });
            } else {
                return try util.fmt(allocator, "{d:0>2}{s}", .{ count, self.ext });
            }
        } else {
            return try util.fmt(allocator, "{s}{s}", .{ self.name, self.ext });
        }
    }
};

/// cheate a filename for a trash file `{original_name}__{timestamp}.trash`
pub fn trashFilenameTimestamp(allocator: Allocator, file_name: []const u8) ![]const u8 {
    const trash_dirpath = try dirpathTrash(allocator);
    defer allocator.free(trash_dirpath);
    return try util.fmt(allocator, "{s}/{s}__{d}.trash{s}", .{
        trash_dirpath,
        file_name,
        std.time.milliTimestamp(),
        std.fs.path.extension(file_name),
    });
}

/// cheate a filename for a trash file `{original_name}__{timestamp}_{random}.trash`
pub fn trashFilenameTimestampRandom(allocator: Allocator, file_name: []const u8) ![]const u8 {
    const trash_dirpath = try dirpathTrash(allocator);
    defer allocator.free(trash_dirpath);
    var rand_buffer: [4]u8 = undefined;
    std.crypto.random.bytes(&rand_buffer);
    return try util.fmt(allocator, "{s}/{s}__{d}_{X}.trash{s}", .{
        trash_dirpath,
        file_name,
        std.time.milliTimestamp(),
        rand_buffer,
        std.fs.path.extension(file_name),
    });
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

    return try util.fmt(allocator, "{s}/{s}__{s}.trash{s}", .{
        trash_dirpath,
        file_name,
        b64_short_digest,
        std.fs.path.extension(file_name),
    });
}
