const std = @import("std");
const util = @import("../root.zig");

const Allocator = std.mem.Allocator;

/// Resolve the absolute path for an undo log file inside the XDG cache directory.
/// Creates the parent directory if it does not exist.
pub fn logPath(allocator: Allocator, log_filename: []const u8) ![:0]const u8 {
    var cache_home_sa = util.StackFilepathAllocator.empty;
    const cache_home = try util.dirpath.xdgCacheHome(cache_home_sa.allocatorInvalidatePrevious());
    var dir_sa = util.StackFilepathAllocator.empty;
    const dir = try std.fs.path.join(dir_sa.allocatorInvalidatePrevious(), &.{ cache_home, "safeutils" });
    std.fs.cwd().makePath(dir) catch {};
    return util.fmtZ(allocator, "{s}/{s}", .{ dir, log_filename });
}

/// Generic undo log backed by a ZON file. Parameterized on the per-file
/// entry type so trash, move, and copy can share the same read/write logic.
pub fn UndoLog(comptime FileEntry: type) type {
    return struct {
        pub const Entry = struct {
            timestamp: i64,
            files: []const FileEntry,
        };

        pub const max_entries = 3;

        /// Read and parse the undo log. Returns an empty slice when the file
        /// is missing. Returns `error.UndoLogCorrupt` when the file exists
        /// but cannot be parsed.
        pub fn read(allocator: Allocator, log_path: [:0]const u8) ![]const Entry {
            const file = std.fs.cwd().openFile(log_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return &.{},
                else => return err,
            };
            defer file.close();

            var read_buffer: [4 * 1024]u8 = undefined;
            var reader = file.reader(&read_buffer);
            var allocating = std.Io.Writer.Allocating.init(allocator);
            _ = reader.interface.streamRemaining(&allocating.writer) catch return error.UndoLogCorrupt;
            const content = allocating.toOwnedSliceSentinel(0) catch return error.UndoLogCorrupt;
            if (content.len == 0) return &.{};
            return std.zon.parse.fromSlice([]const Entry, allocator, content, null, .{}) catch
                return error.UndoLogCorrupt;
        }

        /// Serialize entries and write to the log file.
        pub fn write(log_path: [:0]const u8, entries: []const Entry) !void {
            const file = std.fs.cwd().createFile(log_path, .{}) catch
                return error.UndoLogWriteFailed;
            defer file.close();
            var write_buffer: [4 * 1024]u8 = undefined;
            var writer = file.writer(&write_buffer);
            std.zon.stringify.serialize(entries, .{}, &writer.interface) catch
                return error.UndoLogWriteFailed;
            writer.interface.flush() catch return error.UndoLogWriteFailed;
        }

        /// Read existing log, append a new entry, trim to max_entries, and
        /// write back. Intended for the happy-path after a successful command.
        pub fn appendAndSave(allocator: Allocator, log_path: [:0]const u8, files: []const FileEntry) !void {
            const existing = try read(allocator, log_path);
            const start = if (existing.len >= max_entries) existing.len - (max_entries - 1) else 0;
            const kept = existing[start..];

            var list = std.ArrayList(Entry).empty;
            try list.appendSlice(allocator, kept);
            try list.append(allocator, .{
                .timestamp = std.time.timestamp(),
                .files = files,
            });
            try write(log_path, list.items);
        }

        /// Read the log, remove the newest (last) entry, and rewrite.
        /// Returns the removed entry, or null if the log was empty.
        pub fn popLatestAndSave(allocator: Allocator, log_path: [:0]const u8) !?Entry {
            const entries = try read(allocator, log_path);
            if (entries.len == 0) return null;
            const latest = entries[entries.len - 1];
            const remaining = entries[0 .. entries.len - 1];
            try write(log_path, remaining);
            return latest;
        }
    };
}
