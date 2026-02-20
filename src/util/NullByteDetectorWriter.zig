const std = @import("std");

/// Used to detect if a file is a binary file, inspired by [Vjekoslav Krajačić's talk on File Pilot](https://www.youtube.com/watch?v=bUOOaXf9qIM)
/// if a file contains a null byte `0` its a binary file otherwise its a text file
/// NOTE: you should ignore all `count` and `err` values returned from `.interface` fns
const NullByteDetectorWriter = @This();

/// true if the writer ever receives a null byte `0`
contains_null: bool = false,
/// you should ignore all `count` and `err` values returned from `.interface` fns
interface: std.Io.Writer,

/// buffer.len must be greater than 0
pub fn init(buffer: []u8) !NullByteDetectorWriter {
    std.debug.assert(buffer.len > 0);
    return .{
        .interface = .{
            .buffer = buffer,
            .vtable = &.{
                .drain = implDrain,
            },
        },
    };
}

fn implDrain(w: *std.Io.Writer, data: []const []const u8, _: usize) std.Io.Writer.Error!usize {
    var self = @as(*NullByteDetectorWriter, @fieldParentPtr("interface", w));
    const buffered = w.buffered();
    w.end = 0;
    for (buffered) |char| {
        if (char == 0) {
            self.contains_null = true;
            return std.Io.Writer.Error.WriteFailed; // null found so stop and terminate future writes
        }
    }

    for (data) |item| {
        for (item) |char| {
            if (char == 0) {
                self.contains_null = true;
                return std.Io.Writer.Error.WriteFailed; // null found so stop and terminate future writes
            }
        }
    }

    // end of stream (flush exits when w.end is 0 and return value is 0)
    if (data.len == 1 and data[0].len == 0) {
        w.end = 0;
        return 0;
    }

    // a garbage non-zero number
    return 420;
}
