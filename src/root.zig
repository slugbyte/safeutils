//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const env = @import("./env.zig");
pub const path = @import("./path.zig");

pub const Reporter = @import("./Reporter.zig");
pub const WorkDir = @import("./WorkDir.zig");
pub const Args = @import("./Args.zig");

pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    std.debug.print("{s}\n", .{msg});
}
