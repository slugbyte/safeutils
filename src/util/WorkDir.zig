const std = @import("std");
const util = @import("../root.zig");
const builtin = @import("builtin");
const FilenameBumper = @import("./FilenameBumper.zig");
const dirpath = @import("./dirpath.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const WorkDir = @This();
dir: std.fs.Dir,

pub fn init(dir: std.fs.Dir) WorkDir {
    return .{
        .dir = dir,
    };
}

/// init with the current working directory
pub fn cwd() WorkDir {
    return init(std.fs.cwd());
}

/// move a path on the file system
pub fn move(self: WorkDir, path_src: []const u8, path_dest: []const u8) !void {
    try self.dir.rename(path_src, path_dest);
}

/// stat a path and get null if FileNotFound
pub fn stat(self: WorkDir, path: []const u8) !?std.fs.File.Stat {
    return self.dir.statFile(path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// modified version of dir.statFile but added SYMLIN_NOFOLLOW an null instead of File not Foound (also only linux/posix)
pub fn statNoFollow(self: WorkDir, sub_path: []const u8) !?std.fs.File.Stat {
    const Stat = std.fs.File.Stat;
    const linux = std.os.linux;
    if (builtin.os.tag == .linux) {
        const sub_path_c = try std.posix.toPosixPath(sub_path);
        var stx = std.mem.zeroes(linux.Statx);

        const rc = linux.statx(
            self.dir.fd,
            &sub_path_c,
            linux.AT.NO_AUTOMOUNT | linux.AT.SYMLINK_NOFOLLOW,
            linux.STATX_TYPE | linux.STATX_MODE | linux.STATX_ATIME | linux.STATX_MTIME | linux.STATX_CTIME,
            &stx,
        );

        return switch (linux.E.init(rc)) {
            .SUCCESS => Stat.fromLinux(stx),
            .ACCES => error.AccessDenied,
            .BADF => unreachable,
            .FAULT => unreachable,
            .INVAL => unreachable,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => unreachable, // Handled by posix.toPosixPath() above.
            .NOMEM => error.SystemResources,
            .NOENT, .NOTDIR => null, // error.FileNotFound,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    const st = try std.posix.fstatat(self.dir.fd, sub_path, std.posix.AT.SYMLINK_NOFOLLOW);
    return Stat.fromPosix(st);
}

/// consiter using stat instead
/// checks if a path exists
pub fn exists(self: WorkDir, path: []const u8) !bool {
    if (try self.stat(path)) |_| {
        return true;
    }
    return false;
}

pub fn trashinfoWrite(self: WorkDir, allocator: Allocator, original_path: []const u8, trash_path: []const u8) !void {
    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const trashinfo_filepath = try util.trashinfo.filepath(arena, std.fs.path.basename(trash_path));
    const file = try self.dir.createFile(trashinfo_filepath, .{});
    defer file.close();
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(&buffer);
    try util.trashinfo.writeContent(&writer.interface, original_path);
}

/// move a file, directory or sym_link to the trash
pub fn trash(self: WorkDir, allocator: Allocator, path: []const u8, kind: std.fs.File.Kind) ![]const u8 {
    switch (kind) {
        .file, .directory, .sym_link => {
            const file_name = std.fs.path.basename(path);

            var trash_dirpath_sa = util.StackFilepathAllocator.empty;
            const trash_dirpath = try dirpath.trash(trash_dirpath_sa.allocatorInvalidatePrevious());

            var filename_bumper = FilenameBumper.parse(file_name);
            var trash_path_sa = util.StackFilepathAllocator.empty;
            var trash_path = try filename_bumper.fmtFilepath(trash_path_sa.allocatorInvalidatePrevious(), trash_dirpath);

            while (try self.exists(trash_path)) {
                filename_bumper.bump();
                trash_path = try filename_bumper.fmtFilepath(trash_path_sa.allocatorInvalidatePrevious(), trash_dirpath);
            }
            try self.move(path, trash_path);
            if (builtin.os.tag == .linux) {
                try self.trashinfoWrite(allocator, path, trash_path);
            }
            return allocator.dupe(u8, trash_path);
        },
        else => {
            return error.TrashFileKindNotSupported;
        },
    }
}

/// check if two paths resolve to same location on the filestem
pub fn isPathSameLocation(self: WorkDir, path_a: []const u8, path_b: []const u8) !bool {
    var buffer: [3 * std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const arena = fba.allocator();

    const cwd_path = try self.dir.realpathAlloc(arena, ".");
    const resolve_a = blk_a: {
        if (std.fs.path.isAbsolute(path_a)) {
            break :blk_a try std.fs.path.resolve(arena, &.{path_a});
        } else {
            break :blk_a try std.fs.path.resolve(arena, &.{ cwd_path, path_a });
        }
    };
    const resolve_b = blk_b: {
        if (std.fs.path.isAbsolute(path_b)) {
            break :blk_b try std.fs.path.resolve(arena, &.{path_b});
        } else {
            break :blk_b try std.fs.path.resolve(arena, &.{ cwd_path, path_b });
        }
    };

    return std.mem.eql(u8, resolve_a, resolve_b);
}

pub fn filepathOpen(self: WorkDir, filepath: []const u8, open_flags: std.fs.File.OpenFlags) !std.fs.File {
    return try self.dir.openFile(filepath, open_flags);
}

pub fn filepathRead(self: WorkDir, allocator: Allocator, filepath: []const u8) ![:0]const u8 {
    const file = try self.filepathOpen(filepath, .{});
    // TODO: can i remove this buffer? it seems like it might not be needed when streamReamaing to Writer.Allocating...
    var buffer: [4 * 1024]u8 = undefined;
    var file_reader = file.reader(&buffer);
    var allocating = std.Io.Writer.Allocating.init(allocator);
    errdefer allocating.deinit();
    _ = file_reader.interface.streamRemaining(&allocating.writer) catch return error.OutOfMemory;
    return try allocating.toOwnedSliceSentinel(0);
}

pub fn filepathParseZon(self: WorkDir, T: type, allocator: Allocator, filepath: []const u8, diagnostics: ?*std.zon.parse.Diagnostics, options: std.zon.parse.Options) !T {
    const file_content = try self.filepathRead(allocator, filepath);
    defer allocator.free(file_content);
    return try std.zon.parse.fromSlice(T, allocator, file_content, diagnostics, options);
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

pub fn hashFilepathSha256(self: WorkDir, path: []const u8, digest_buffer: *[Sha256.digest_length]u8) !void {
    const file = try self.filepathOpen(path, .{});
    defer file.close();

    try self.hashFileSha256(file, digest_buffer);
}
