const std = @import("std");
const Allocator = std.mem.Allocator;

const Args = @This();

pub fn parse(allocator: Allocator, flag_parser: *FlagParser) !void {
    var iter = try ArgIterator.init(allocator);
    defer {
        iter.reset();
        if (!flag_parser.setArgIteratorFn(flag_parser, iter)) {
            iter.deinit();
        }
    }

    const program_path = try allocator.dupeZ(u8, iter.next().?);
    errdefer allocator.free(program_path);
    if (!flag_parser.setProgramPathFn(flag_parser, program_path)) {
        allocator.free(program_path);
    }

    var positional = std.ArrayList([:0]const u8).empty;
    errdefer positional.deinit(allocator);
    while (iter.next()) |arg| {
        if (!try flag_parser.parseFn(flag_parser, arg, &iter)) {
            try positional.append(allocator, try allocator.dupeZ(u8, arg));
        }
    }

    const positional_list = try positional.toOwnedSlice(allocator);
    if (!flag_parser.setPositionalListFn(flag_parser, positional_list)) {
        allocator.free(positional_list);
    }
}

pub const Error = error{ MissingValue, ParseFailed } || Allocator.Error || std.fs.Dir.StatFileError;

pub const FlagParser = struct {
    parseFn: *const fn (*FlagParser, [:0]const u8, *ArgIterator) Error!bool,
    /// return true if ArgIterator is now owned by caller
    setArgIteratorFn: *const fn (*FlagParser, ArgIterator) bool = implNoopSetArgIterator,
    /// return true if positional_list is now owned by caller
    setPositionalListFn: *const fn (*FlagParser, [][:0]const u8) bool = implNoopSetPositionalList,
    /// return true if program_path is now owned by caller
    setProgramPathFn: *const fn (*FlagParser, [:0]const u8) bool = implNoopSetProgramPath,

    pub fn implNoopSetProgramPath(_: *FlagParser, _: [:0]const u8) bool {
        return false;
    }
    pub fn implNoopSetPositionalList(_: *FlagParser, _: [][:0]const u8) bool {
        return false;
    }
    pub fn implNoopSetArgIterator(_: *FlagParser, _: ArgIterator) bool {
        return false;
    }
};

pub const ArgIterator = struct {
    // inner: std.process.ArgIterator,
    args: [][:0]u8,
    index: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !ArgIterator {
        return .{
            .args = try std.process.argsAlloc(allocator),
            .index = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ArgIterator) void {
        self.allocator.free(self.args);
        self.* = undefined;
    }

    pub fn create(allocator: Allocator) !*ArgIterator {
        const iter = try allocator.create(ArgIterator);
        errdefer allocator.destroy(iter);
        iter.* = try ArgIterator.init(allocator);
        return iter;
    }

    pub fn destroy(self: *ArgIterator) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn reset(self: *ArgIterator) void {
        self.index = 0;
    }

    pub fn countRemaing(self: ArgIterator) usize {
        return self.args.len - self.index;
    }

    pub inline fn peek(self: ArgIterator) ?[:0]const u8 {
        if (self.index < self.args.len) {
            return self.args[self.index];
        }
        return null;
    }

    pub inline fn skip(self: *ArgIterator) ?[:0]const u8 {
        if (self.index < self.args.len) {
            self.index += 1;
        }
        return null;
    }

    pub inline fn next(self: *ArgIterator) ?[:0]const u8 {
        if (self.index < self.args.len) {
            defer self.index += 1;
            return self.args[self.index];
        }
        return null;
    }

    pub inline fn nextOrFail(self: *ArgIterator) ![:0]const u8 {
        return self.next() orelse Error.MissingValue;
    }

    pub inline fn nextInt(self: *ArgIterator, T: type, base: u8) !T {
        const arg = try self.nextOrFail();
        return std.fmt.parseInt(T, arg, base) catch return Error.ParseFailed;
    }

    pub inline fn nextFloat(self: *ArgIterator, T: type) !T {
        const arg = try self.nextOrFail();
        return std.fmt.parseFloat(T, arg) catch Error.ParseFailed;
    }

    pub inline fn nextEnum(self: *ArgIterator, T: type) !T {
        const arg = try self.nextOrFail();
        return std.meta.stringToEnum(T, arg) catch return Error.ParseFailed;
    }

    pub inline fn nextFileOpen(self: *ArgIterator, flags: std.fs.File.OpenFlags) !std.fs.File {
        const file_path = try self.nextFilePath();
        if (file_path.stat.kind != .file) return Error.ParseFailed;
        return try std.fs.cwd().openFile(file_path.path, flags);
    }

    pub inline fn nextFileRead(self: *ArgIterator, allocator: Allocator) ![:0]const u8 {
        const file = try self.nextFileOpen(.{});
        // TODO: can i remove this buffer? it seems like it might not be needed when streamReamaing to Writer.Allocating...
        var buffer: [4 * 1024]u8 = undefined;
        var file_reader = file.reader(&buffer);
        var allocating = std.Io.Writer.Allocating.init(allocator);
        errdefer allocating.deinit();
        _ = file_reader.interface.streamRemaining(&allocating.writer) catch return error.OutOfMemory;
        return try allocating.toOwnedSliceSentinel(0);
    }

    pub inline fn nextFileParseZon(self: *ArgIterator, T: type, allocator: Allocator, diagnostics: ?*std.zon.parse.Diagnostics, options: std.zon.parse.Options) !T {
        const file_content = try self.nextFileRead(Allocator);
        defer allocator.free(file_content);
        return std.zon.parse.fromSlice(T, allocator, file_content, diagnostics, options) catch Error.ParseFailed;
    }

    pub const FilePath = struct {
        stat: std.fs.File.Stat,
        path: [:0]const u8,
    };

    pub inline fn nextFilePath(self: *ArgIterator) !FilePath {
        const arg = try self.nextOrFail();
        const stat = try std.fs.cwd().statFile(arg);
        return .{
            .path = arg,
            .stat = stat,
        };
    }
};

pub inline fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub inline fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub inline fn eqlAny(value: []const u8, needles: [][]const u8) bool {
    for (needles) |needle| {
        if (eql(value, needle)) {
            return true;
        }
    }
    return false;
}

pub inline fn eqlAnyIgnoreCase(value: []const u8, needles: [][]const u8) bool {
    for (needles) |needle| {
        if (eqlIgnoreCase(value, needle)) {
            return true;
        }
    }
    return false;
}

pub inline fn eqlFlag(value: []const u8, a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, value, a) or std.mem.eql(u8, value, b);
}

pub inline fn startsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

pub inline fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(haystack, needle);
}

pub inline fn endsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.endsWith(u8, haystack, needle);
}

pub inline fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(haystack, needle);
}

pub inline fn endsWithAny(haystack: []const u8, needles: [][]const u8) bool {
    for (needles) |needle| {
        if (endsWith(haystack, needle)) {
            return true;
        }
    }
    return false;
}

pub inline fn endsWithAnyIgnoreCase(haystack: []const u8, needles: [][]const u8) bool {
    for (needles) |needle| {
        if (endsWithIgnoreCase(haystack, needle)) {
            return true;
        }
    }
    return false;
}
