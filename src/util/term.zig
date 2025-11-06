const std = @import("std");

pub fn isTTY() bool {
    const stdout = std.fs.File.stdout();
    return std.posix.isatty(stdout.handle);
}

pub fn winsize() !std.posix.winsize {
    const stdout = std.fs.File.stdout();
    var result: std.posix.winsize = undefined;
    const status = std.posix.system.ioctl(stdout.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&result));
    if (status != 0) {
        return error.WinsizeNotFound;
    }
    return result;
}
