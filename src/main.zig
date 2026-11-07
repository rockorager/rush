//! Executable entry point.

const std = @import("std");
const builtin = @import("builtin");

const app = @import("app.zig");

const use_safe_allocator = builtin.mode == .debug;
const AppSafeAllocator = if (use_safe_allocator) std.heap.SafeAllocator else void;

pub fn main(init: std.process.Init.Minimal) !u8 {
    var safe_allocator: AppSafeAllocator = if (use_safe_allocator) .init(std.heap.page_allocator, .{}) else {};
    defer if (use_safe_allocator) {
        _ = safe_allocator.deinit();
    };

    const root_allocator = if (use_safe_allocator) safe_allocator.allocator() else std.heap.smp_allocator;

    var process_arena = std.heap.ArenaAllocator.init(root_allocator);
    defer process_arena.deinit();

    return app.run(root_allocator, process_arena.allocator(), init);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("shell/Function.zig");
    _ = @import("host/RealHost.zig");
}
