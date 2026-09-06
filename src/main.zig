//! Executable entry point.

const std = @import("std");
const builtin = @import("builtin");

const app = @import("app.zig");

const use_debug_allocator = builtin.mode == .Debug;
const AppDebugAllocator = if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void;

pub fn main(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: AppDebugAllocator = if (use_debug_allocator) .init else {};
    defer if (use_debug_allocator) {
        _ = debug_allocator.deinit();
    };

    const root_allocator = if (use_debug_allocator) debug_allocator.allocator() else std.heap.smp_allocator;

    var process_arena = std.heap.ArenaAllocator.init(root_allocator);
    defer process_arena.deinit();

    return app.run(root_allocator, process_arena.allocator(), init);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("shell/Function.zig");
    _ = @import("host/RealHost.zig");
}
