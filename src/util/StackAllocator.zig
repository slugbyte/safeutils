const std = @import("std");

pub fn StackAllocator(comptime capacity: usize) type {
    return struct {
        buffer: [capacity]u8 = undefined,
        fixed_buffer_allocator: std.heap.FixedBufferAllocator = undefined,
        is_init: bool = false,

        pub const empty: @This() = .{};

        /// WARN: resets `fixed_buffer_allocator` any  previously allocated data is undefined
        pub fn allocatorInvalidatePrevious(self: *@This()) std.mem.Allocator {
            if (self.is_init) {
                self.fixed_buffer_allocator.reset();
            } else {
                self.is_init = true;
                self.fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&self.buffer);
            }
            return self.fixed_buffer_allocator.allocator();
        }
    };
}

pub const StackFilepathAllocator = StackAllocator(std.fs.max_path_bytes);
pub const StackFilenameAllocator = StackAllocator(std.fs.max_path_bytes);
