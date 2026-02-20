const std = @import("std");
const t = std.testing;

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

test "TEST: basic allocation works" {
    var sa = StackAllocator(256).empty;
    const allocator = sa.allocatorInvalidatePrevious();
    const slice = try allocator.alloc(u8, 10);
    try t.expectEqual(@as(usize, 10), slice.len);
}

test "TEST: invalidate resets for new allocation" {
    var sa = StackAllocator(64).empty;
    const a1 = sa.allocatorInvalidatePrevious();
    const s1 = try a1.alloc(u8, 32);
    try t.expectEqual(@as(usize, 32), s1.len);

    // second call resets -- we can allocate the full 64 again
    const a2 = sa.allocatorInvalidatePrevious();
    const s2 = try a2.alloc(u8, 64);
    try t.expectEqual(@as(usize, 64), s2.len);
}

test "TEST: allocation beyond capacity fails" {
    var sa = StackAllocator(16).empty;
    const allocator = sa.allocatorInvalidatePrevious();
    try t.expectError(error.OutOfMemory, allocator.alloc(u8, 17));
}
