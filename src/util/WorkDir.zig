const std = @import("std");
const util = @import("../root.zig");
const builtin = @import("builtin");
const FilenameBumper = @import("./FilenameBumper.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const TrashPaths = util.trash_paths.TrashPaths;
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

/// move a path on the file system, falls back to copy+delete across mount points
pub fn move(self: WorkDir, path_src: []const u8, path_dest: []const u8) !void {
    self.dir.rename(path_src, path_dest) catch |err| switch (err) {
        error.RenameAcrossMountPoints => return self.moveAcrossMountPoints(path_src, path_dest),
        else => return err,
    };
}

/// fallback for move across mount points: copy then delete the source
fn moveAcrossMountPoints(self: WorkDir, path_src: []const u8, path_dest: []const u8) !void {
    const source_stat = try self.statNoFollow(path_src) orelse return error.FileNotFound;
    switch (source_stat.kind) {
        .file => {
            try self.dir.copyFile(path_src, self.dir, path_dest, .{});
            try self.dir.deleteFile(path_src);
        },
        .sym_link => {
            var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const link_target = try self.dir.readLink(path_src, &link_buffer);
            try self.dir.symLink(link_target, path_dest, .{});
            try self.dir.deleteFile(path_src);
        },
        .directory => {
            try self.copyDirRecursive(path_src, path_dest);
            try self.dir.deleteTree(path_src);
        },
        else => return error.FileNotFound,
    }
}

/// recursively copy a directory tree from src to dest within self.dir
fn copyDirRecursive(self: WorkDir, src_path: []const u8, dest_path: []const u8) !void {
    // create the top-level destination directory
    self.dir.makeDir(dest_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var src_dir = try self.dir.openDir(src_path, .{ .iterate = true });
    defer src_dir.close();

    // use a fixed buffer allocator for path joins to avoid heap allocation
    var path_buffer: [2 * std.fs.max_path_bytes]u8 = undefined;
    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        var fba = std.heap.FixedBufferAllocator.init(&path_buffer);
        const fba_allocator = fba.allocator();
        const child_src = try std.fs.path.join(fba_allocator, &.{ src_path, entry.name });
        const child_dest = try std.fs.path.join(fba_allocator, &.{ dest_path, entry.name });

        switch (entry.kind) {
            .file => try self.dir.copyFile(child_src, self.dir, child_dest, .{}),
            .sym_link => {
                var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const link_target = try self.dir.readLink(child_src, &link_buffer);
                try self.dir.symLink(link_target, child_dest, .{});
            },
            .directory => try self.copyDirRecursive(child_src, child_dest),
            else => {},
        }
    }
}

/// stat a path and get null if FileNotFound
pub fn stat(self: WorkDir, path: []const u8) !?std.fs.File.Stat {
    return self.dir.statFile(path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// modified version of dir.statFile but added SYMLINK_NOFOLLOW and null instead of FileNotFound (also only linux/posix)
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
    const st = std.posix.fstatat(self.dir.fd, sub_path, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return Stat.fromPosix(st);
}

/// consider using stat instead
/// checks if a path exists
pub fn exists(self: WorkDir, path: []const u8) !bool {
    if (try self.stat(path)) |_| {
        return true;
    }
    return false;
}

pub fn trashinfoWrite(self: WorkDir, allocator: Allocator, original_path: []const u8, trash_path: []const u8) !void {
    const trash_paths = try util.trash_paths.resolve(allocator, .{});
    return self.trashinfoWriteAt(allocator, trash_paths, original_path, trash_path);
}

pub fn trashinfoWriteAt(self: WorkDir, allocator: Allocator, trash_paths: TrashPaths, original_path: []const u8, trash_path: []const u8) !void {
    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    // resolve original_path relative to self.dir (not process cwd) so
    // trashinfo records the correct absolute path even when WorkDir is
    // not the process cwd.
    const absolute_original_path = try self.realpathZ(arena, original_path);

    const info_dir = trash_paths.info_dir orelse return error.TrashInfoDirRequired;
    const trashinfo_filepath = try util.trashinfo.filepathAt(arena, info_dir, std.fs.path.basename(trash_path));
    const file = try self.dir.createFile(trashinfo_filepath, .{});
    defer file.close();
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(&buffer);
    try util.trashinfo.writeContent(&writer.interface, absolute_original_path);
}

/// move a file, directory or sym_link to the trash
pub fn trash(self: WorkDir, allocator: Allocator, path: []const u8, kind: std.fs.File.Kind) ![]const u8 {
    const trash_paths = try util.trash_paths.resolve(allocator, .{});
    return self.trashAt(allocator, trash_paths, path, kind);
}

pub fn trashAt(self: WorkDir, allocator: Allocator, trash_paths: TrashPaths, path: []const u8, kind: std.fs.File.Kind) ![]const u8 {
    switch (kind) {
        .file, .directory, .sym_link => {
            const file_name = std.fs.path.basename(path);

            var filename_bumper = FilenameBumper.parse(file_name);
            var trash_path_sa = util.StackFilepathAllocator.empty;
            var trash_path = try filename_bumper.fmtFilepath(trash_path_sa.allocatorInvalidatePrevious(), trash_paths.files_dir);

            while (try self.exists(trash_path)) {
                filename_bumper.bump();
                trash_path = try filename_bumper.fmtFilepath(trash_path_sa.allocatorInvalidatePrevious(), trash_paths.files_dir);
            }
            try self.move(path, trash_path);
            if (builtin.os.tag == .linux) {
                try self.trashinfoWriteAt(allocator, trash_paths, path, trash_path);
            }
            return allocator.dupe(u8, trash_path);
        },
        else => {
            return error.TrashFileKindNotSupported;
        },
    }
}

pub fn realpathZ(self: WorkDir, allocator: Allocator, path: []const u8) ![:0]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        var result_sa = util.StackFilepathAllocator.empty;
        const result = try std.fs.path.resolve(result_sa.allocatorInvalidatePrevious(), &.{path});
        return try allocator.dupeZ(u8, result);
    } else {
        var cwd_path_sa = util.StackFilepathAllocator.empty;
        const cwd_path = try self.dir.realpathAlloc(cwd_path_sa.allocatorInvalidatePrevious(), ".");
        var result_sa = util.StackFilepathAllocator.empty;
        const result = try std.fs.path.resolve(result_sa.allocatorInvalidatePrevious(), &.{ cwd_path, path });
        return try allocator.dupeZ(u8, result);
    }
}

/// check if two paths resolve to same location on the filesystem
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
    // TODO: can i remove this buffer? it seems like it might not be needed when streamRemaining to Writer.Allocating...
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
