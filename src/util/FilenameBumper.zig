const std = @import("std");
const t = std.testing;
const util = @import("../root.zig");
const Allocator = std.mem.Allocator;

const FilenameBumper = @This();
/// parses and creates filenames with a counter before the extension
/// used when trying to make sure files don't have naming conflicts
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
        } else break;
    }
    if (end_digit_count > 0) {
        count = std.fmt.parseInt(usize, name[name.len - end_digit_count ..], 10) catch null;
    }
    if (count != null) {
        name = name[0 .. name.len - end_digit_count];
    }
    name = std.mem.trimEnd(u8, name, "-_ .");
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

test "TEST: parse simple filename" {
    const b = parse("hello.txt");
    try t.expectEqualStrings("hello", b.name);
    try t.expectEqualStrings(".txt", b.ext);
    try t.expectEqual(@as(?usize, null), b.count);
}

test "TEST: parse filename with trailing number" {
    const b = parse("foo_42.txt");
    try t.expectEqualStrings("foo", b.name);
    try t.expectEqualStrings(".txt", b.ext);
    try t.expectEqual(@as(?usize, 42), b.count);
}

test "TEST: parse filename with no extension" {
    const b = parse("README");
    try t.expectEqualStrings("README", b.name);
    try t.expectEqualStrings("", b.ext);
    try t.expectEqual(@as(?usize, null), b.count);
}

test "TEST: parse filename with embedded digits keeps them" {
    const b = parse("a1b2c.txt");
    try t.expectEqualStrings("a1b2c", b.name);
    try t.expectEqualStrings(".txt", b.ext);
    try t.expectEqual(@as(?usize, null), b.count);
}

test "TEST: bump from null starts at 0" {
    var b = parse("file.txt");
    try t.expectEqual(@as(?usize, null), b.count);
    b.bump();
    try t.expectEqual(@as(?usize, 0), b.count);
    b.bump();
    try t.expectEqual(@as(?usize, 1), b.count);
}

test "TEST: bump from existing count increments" {
    var b = parse("file_05.txt");
    try t.expectEqual(@as(?usize, 5), b.count);
    b.bump();
    try t.expectEqual(@as(?usize, 6), b.count);
}

test "TEST: fmtFilename without count" {
    const b = parse("hello.txt");
    const name = try b.fmtFilename(t.allocator);
    defer t.allocator.free(name);
    try t.expectEqualStrings("hello.txt", name);
}

test "TEST: fmtFilename with count" {
    var b = parse("hello.txt");
    b.bump();
    const name = try b.fmtFilename(t.allocator);
    defer t.allocator.free(name);
    try t.expectEqualStrings("hello_00.txt", name);
}

test "TEST: fmtFilename bumped twice" {
    var b = parse("hello.txt");
    b.bump();
    b.bump();
    const name = try b.fmtFilename(t.allocator);
    defer t.allocator.free(name);
    try t.expectEqualStrings("hello_01.txt", name);
}
