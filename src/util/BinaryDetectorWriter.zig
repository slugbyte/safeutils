const std = @import("std");

/// used for detecting if something is a binary file
/// is_binary is set to `true` if a null byte `0` is written
/// count and errors from this writer should be ignored they dont matter
const BinaryDetectorWriter = @This();
is_binary: bool = false,
interface: std.Io.Writer,

pub fn init(buffer: []u8) !BinaryDetectorWriter {
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
    var self = @as(*BinaryDetectorWriter, @fieldParentPtr("interface", w));
    const buffered = w.buffered();
    w.end = 0;
    for (buffered) |char| {
        if (char == 0) {
            self.is_binary = true;
            return std.Io.Writer.Error.WriteFailed;
        }
    }

    for (data) |item| {
        for (item) |char| {
            if (char == 0) {
                self.is_binary = true;
                return std.Io.Writer.Error.WriteFailed;
            }
        }
    }

    // end of stream
    if (data.len == 1 and data[0].len == 0) {
        w.end = 0;
        return 0;
    }

    return 420;
}
