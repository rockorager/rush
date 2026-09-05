//! Allocator helpers for shell-owned arenas.

const std = @import("std");

pub const Arena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(parent_allocator: std.mem.Allocator) Arena {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_allocator) };
    }

    pub fn deinit(self: *Arena) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Arena) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn resetRetainingCapacity(self: *Arena) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn resetFreeingAll(self: *Arena) void {
        _ = self.arena.reset(.free_all);
    }
};

pub const Arenas = struct {
    parent_allocator: std.mem.Allocator,
    ast: Arena,
    scratch_scopes: std.ArrayList(ScratchArena) = .empty,
    scratch_depth: usize = 0,

    pub fn init(parent_allocator: std.mem.Allocator) Arenas {
        return .{
            .parent_allocator = parent_allocator,
            .ast = Arena.init(parent_allocator),
        };
    }

    pub fn deinit(self: *Arenas) void {
        for (self.scratch_scopes.items) |*scratch| scratch.deinit();
        self.scratch_scopes.deinit(self.parent_allocator);
        self.ast.deinit();
        self.* = undefined;
    }

    pub fn resetForTopLevelCommand(self: *Arenas) void {
        for (self.scratch_scopes.items) |*scratch| scratch.resetRetainingCapacity();
        self.scratch_depth = 0;
        self.ast.resetRetainingCapacity();
    }

    pub fn scratchAllocator(self: *Arenas) std.mem.Allocator {
        std.debug.assert(self.scratch_depth != 0);
        return self.scratch_scopes.items[self.scratch_depth - 1].allocator();
    }

    pub fn beginScratchScope(self: *Arenas) !ScratchScope {
        std.debug.assert(self.scratch_depth <= self.scratch_scopes.items.len);
        if (self.scratch_depth == self.scratch_scopes.items.len) {
            try self.scratch_scopes.append(self.parent_allocator, ScratchArena.init(self.parent_allocator));
        }
        const index = self.scratch_depth;
        self.scratch_depth += 1;
        return .{ .arenas = self, .index = index };
    }
};

pub const ScratchScope = struct {
    arenas: *Arenas,
    index: usize,

    pub fn end(self: ScratchScope) void {
        std.debug.assert(self.arenas.scratch_depth == self.index + 1);
        self.arenas.scratch_scopes.items[self.index].resetRetainingCapacity();
        self.arenas.scratch_depth = self.index;
    }
};

pub const ScratchArena = struct {
    parent_allocator: std.mem.Allocator,
    chunks: ?*Chunk = null,
    active: ?*Chunk = null,

    const default_chunk_size = 4096;

    // Each allocation contains this header followed by its usable bytes.
    // Linking headers avoids a separate allocation for chunk bookkeeping.
    const Chunk = struct {
        next: ?*Chunk = null,
        bytes: []u8,
        used: usize = 0,
    };

    pub fn init(parent_allocator: std.mem.Allocator) ScratchArena {
        return .{ .parent_allocator = parent_allocator };
    }

    pub fn deinit(self: *ScratchArena) void {
        var current = self.chunks;
        while (current) |chunk| {
            current = chunk.next;
            const allocation: [*]align(@alignOf(Chunk)) u8 = @ptrCast(chunk);
            self.parent_allocator.free(allocation[0 .. @sizeOf(Chunk) + chunk.bytes.len]);
        }
        self.* = undefined;
    }

    pub fn allocator(self: *ScratchArena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn resetRetainingCapacity(self: *ScratchArena) void {
        var current = self.chunks;
        while (current) |chunk| : (current = chunk.next) chunk.used = 0;
        self.active = self.chunks;
    }

    fn alloc(self: *ScratchArena, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        std.debug.assert(len != 0);
        var current = self.active;
        var last: ?*Chunk = null;
        while (current) |chunk| : (current = chunk.next) {
            if (allocFromChunk(chunk, len, alignment)) |ptr| {
                self.active = chunk;
                return ptr;
            }
            last = chunk;
        }

        const chunk_size = chunkSize(len, alignment) orelse return null;
        const bytes = self.parent_allocator.alignedAlloc(u8, .of(Chunk), chunk_size) catch return null;
        const chunk: *Chunk = @ptrCast(bytes.ptr);
        chunk.* = .{ .bytes = bytes[@sizeOf(Chunk)..] };
        if (last) |tail| {
            std.debug.assert(tail.next == null);
            tail.next = chunk;
        } else {
            std.debug.assert(self.chunks == null);
            self.chunks = chunk;
        }
        self.active = chunk;
        return allocFromChunk(chunk, len, alignment).?;
    }

    fn resize(self: *ScratchArena, memory: []u8, new_len: usize) bool {
        std.debug.assert(new_len != 0);
        const chunk = self.findChunk(memory) orelse return false;
        const start = @intFromPtr(memory.ptr) - @intFromPtr(chunk.bytes.ptr);
        const old_end = start + memory.len;
        const new_end = start + new_len;

        if (new_len <= memory.len) {
            if (old_end == chunk.used) chunk.used = new_end;
            return true;
        }
        if (old_end != chunk.used or new_end > chunk.bytes.len) return false;
        chunk.used = new_end;
        return true;
    }

    fn free(self: *ScratchArena, memory: []u8) void {
        const chunk = self.findChunk(memory) orelse return;
        const start = @intFromPtr(memory.ptr) - @intFromPtr(chunk.bytes.ptr);
        const end = start + memory.len;
        if (end == chunk.used) chunk.used = start;
    }

    fn findChunk(self: *ScratchArena, memory: []u8) ?*Chunk {
        const ptr = @intFromPtr(memory.ptr);
        var current = self.chunks;
        while (current) |chunk| : (current = chunk.next) {
            const start = @intFromPtr(chunk.bytes.ptr);
            const end = start + chunk.bytes.len;
            if (ptr >= start and ptr + memory.len <= end) return chunk;
        }
        return null;
    }

    fn allocFromChunk(chunk: *Chunk, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const base = @intFromPtr(chunk.bytes.ptr);
        const aligned = alignment.forward(base + chunk.used);
        const start = aligned - base;
        const end = start + len;
        if (end > chunk.bytes.len) return null;
        chunk.used = end;
        return chunk.bytes.ptr + start;
    }

    fn chunkSize(len: usize, alignment: std.mem.Alignment) ?usize {
        const required = std.math.add(usize, len, alignment.toByteUnits()) catch return null;
        const with_header = std.math.add(usize, required, @sizeOf(Chunk)) catch return null;
        return @max(default_chunk_size, with_header);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };

    fn rawAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *ScratchArena = @ptrCast(@alignCast(ctx));
        return self.alloc(len, alignment);
    }

    fn rawResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = alignment;
        _ = ret_addr;
        const self: *ScratchArena = @ptrCast(@alignCast(ctx));
        return self.resize(memory, new_len);
    }

    fn rawRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = alignment;
        _ = ret_addr;
        const self: *ScratchArena = @ptrCast(@alignCast(ctx));
        return if (self.resize(memory, new_len)) memory.ptr else null;
    }

    fn rawFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const self: *ScratchArena = @ptrCast(@alignCast(ctx));
        self.free(memory);
    }
};

test "nested scratch scopes do not invalidate outer allocations" {
    var arenas = Arenas.init(std.testing.allocator);
    defer arenas.deinit();

    const outer = try arenas.beginScratchScope();
    defer outer.end();
    const outer_bytes = try arenas.scratchAllocator().dupe(u8, "outer");

    const inner = try arenas.beginScratchScope();
    const inner_bytes = try arenas.scratchAllocator().dupe(u8, "inner");
    try std.testing.expectEqualStrings("inner", inner_bytes);
    inner.end();

    try std.testing.expectEqualStrings("outer", outer_bytes);
}

test "scratch arena reuses retained chunks after reset" {
    var scratch = ScratchArena.init(std.testing.allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();

    const first = try allocator.alloc(u8, 32);
    @memset(first, 'a');
    scratch.resetRetainingCapacity();
    const second = try allocator.alloc(u8, 32);

    try std.testing.expectEqual(first.ptr, second.ptr);
}

test "scratch arena honors allocation alignment" {
    var scratch = ScratchArena.init(std.testing.allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();

    _ = try allocator.alloc(u8, 1);
    const aligned = try allocator.alignedAlloc(u8, .fromByteUnits(64), 8);

    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 64);
}

test "scratch arena can resize the most recent allocation in place" {
    var scratch = ScratchArena.init(std.testing.allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();

    var bytes = try allocator.alloc(u8, 8);
    bytes[0] = 'x';
    try std.testing.expect(allocator.resize(bytes, 16));
    bytes = bytes.ptr[0..16];

    try std.testing.expectEqual('x', bytes[0]);
}

test "scratch chunks allocate once and preserve retained storage on allocation failure" {
    var parent = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var scratch = ScratchArena.init(parent.allocator());
    defer scratch.deinit();
    const allocator = scratch.allocator();

    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 32));
    try std.testing.expect(scratch.chunks == null);
    parent.fail_index = std.math.maxInt(usize);
    const first = try allocator.alloc(u8, 32);
    @memset(first, 'a');
    try std.testing.expectEqual(@as(usize, 1), parent.allocations);
    const first_chunk = scratch.chunks.?;

    parent.fail_index = parent.alloc_index;
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 8192));
    try std.testing.expect(first_chunk.next == null);
    try std.testing.expectEqual(first_chunk, scratch.active.?);
    try std.testing.expectEqualStrings("a" ** 32, first);

    parent.fail_index = std.math.maxInt(usize);
    const second = try allocator.alignedAlloc(u8, .fromByteUnits(4096), 8192);
    @memset(second, 'b');
    try std.testing.expectEqual(@as(usize, 2), parent.allocations);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(second.ptr) % 4096);
    try std.testing.expectEqualStrings("a" ** 32, first);

    parent.fail_index = parent.alloc_index;
    scratch.resetRetainingCapacity();
    const reused_first = try allocator.alloc(u8, 32);
    const reused_second = try allocator.alignedAlloc(u8, .fromByteUnits(4096), 8192);
    try std.testing.expectEqual(first.ptr, reused_first.ptr);
    try std.testing.expectEqual(second.ptr, reused_second.ptr);
    try std.testing.expectEqual(@as(usize, 2), parent.allocations);
}

test "scratch chunk headers survive frees and resizes across multiple chunks" {
    var scratch = ScratchArena.init(std.testing.allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();

    const first = try allocator.alloc(u8, 16);
    @memset(first, 'a');
    var second = try allocator.alloc(u8, 8192);
    @memset(second, 'b');
    try std.testing.expect(allocator.resize(first, 32));
    const grown_first: []u8 = first.ptr[0..32];
    try std.testing.expect(!allocator.resize(grown_first, 8192));
    try std.testing.expect(allocator.resize(second, 4096));
    second = second.ptr[0..4096];
    allocator.free(second);
    const reused = try allocator.alloc(u8, 8192);
    try std.testing.expectEqual(second.ptr, reused.ptr);
    try std.testing.expectEqualStrings("a" ** 16, first);
    try std.testing.expectEqual(@as(usize, 8192), reused.len);
}
