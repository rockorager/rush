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
    chunks: std.ArrayList(Chunk) = .empty,
    active_index: usize = 0,

    const default_chunk_size = 4096;

    const Chunk = struct {
        bytes: []u8,
        used: usize = 0,
    };

    pub fn init(parent_allocator: std.mem.Allocator) ScratchArena {
        return .{ .parent_allocator = parent_allocator };
    }

    pub fn deinit(self: *ScratchArena) void {
        for (self.chunks.items) |chunk| self.parent_allocator.free(chunk.bytes);
        self.chunks.deinit(self.parent_allocator);
        self.* = undefined;
    }

    pub fn allocator(self: *ScratchArena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn resetRetainingCapacity(self: *ScratchArena) void {
        for (self.chunks.items) |*chunk| chunk.used = 0;
        self.active_index = 0;
    }

    fn alloc(self: *ScratchArena, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        std.debug.assert(len != 0);
        var index = self.active_index;
        while (index < self.chunks.items.len) : (index += 1) {
            if (allocFromChunk(&self.chunks.items[index], len, alignment)) |ptr| {
                self.active_index = index;
                return ptr;
            }
        }

        const chunk_size = chunkSize(len, alignment) orelse return null;
        const bytes = self.parent_allocator.alloc(u8, chunk_size) catch return null;
        self.chunks.append(self.parent_allocator, .{ .bytes = bytes }) catch {
            self.parent_allocator.free(bytes);
            return null;
        };
        self.active_index = self.chunks.items.len - 1;
        return allocFromChunk(&self.chunks.items[self.active_index], len, alignment).?;
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
        for (self.chunks.items) |*chunk| {
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
        return @max(default_chunk_size, required);
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
