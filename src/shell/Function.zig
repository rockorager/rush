//! Immutable function definition packed into one allocation with its source name.
//! The function table and each active invocation own references independently.
//! Replacing a table entry cannot invalidate an active invocation's AST or names.

const Function = @This();

const std = @import("std");
const ast = @import("ast.zig");

name: []const u8,
source_name: []const u8,
definition: ast.FunctionDefinition,
references: usize = 1,
allocation_len: usize,

/// Deep-copies all AST data and names into one allocation. Returns one owned
/// reference; input storage need survive only this call. Not thread-safe.
pub fn create(
    allocator: std.mem.Allocator,
    definition: ast.FunctionDefinition,
    source_name: []const u8,
) std.mem.Allocator.Error!*Function {
    definition.validate();
    std.debug.assert(source_name.len != 0);
    var sizing: Layout(false) = .{};
    _ = try sizing.copy(definition);
    _ = try sizing.copy(source_name);

    const bytes = try allocator.alignedAlloc(u8, .of(Function), sizing.offset);
    errdefer allocator.free(bytes);
    var copying: Layout(true) = .{ .buffer = bytes };
    const owned_definition = try copying.copy(definition);
    const owned_source_name = try copying.copy(source_name);
    std.debug.assert(copying.offset == bytes.len);
    const function: *Function = @ptrCast(bytes.ptr);
    function.* = .{
        .name = owned_definition.name,
        .source_name = owned_source_name,
        .definition = owned_definition,
        .allocation_len = bytes.len,
    };
    return function;
}

/// Acquires an additional reference before the current owner can release it.
pub fn retain(self: *Function) void {
    std.debug.assert(self.references != 0);
    self.references += 1;
}

/// Releases one owned reference, freeing the entire definition on the last
/// release. Must use the allocator passed to create. Not thread-safe.
pub fn release(self: *Function, allocator: std.mem.Allocator) void {
    std.debug.assert(self.references != 0);
    self.references -= 1;
    if (self.references == 0) {
        const bytes: [*]align(@alignOf(Function)) u8 = @ptrCast(self);
        allocator.free(bytes[0..self.allocation_len]);
    }
}

pub fn validate(self: *const Function) void {
    std.debug.assert(self.references != 0);
    std.debug.assert(self.name.len != 0);
    std.debug.assert(self.source_name.len != 0);
    std.debug.assert(self.name.ptr == self.definition.name.ptr);
    self.definition.validate();
}

// AST data is an acyclic tree of structs, tagged unions, optional values,
// const slices and const single pointers. Use the same traversal for sizing
// and copying so new AST fields cannot silently escape the ownership boundary.
// This is deliberately private to function storage, not a general serializer.
fn Layout(comptime copying: bool) type {
    return struct {
        const Self = @This();

        offset: usize = @sizeOf(Function),
        buffer: []align(@alignOf(Function)) u8 = &.{},

        fn reserve(self: *Self, comptime T: type, len: usize) std.mem.Allocator.Error!usize {
            comptime std.debug.assert(@alignOf(T) <= @alignOf(Function));
            const padded = std.math.add(usize, self.offset, @alignOf(T) - 1) catch return error.OutOfMemory;
            const start = std.mem.alignBackward(usize, padded, @alignOf(T));
            const size = std.math.mul(usize, @sizeOf(T), len) catch return error.OutOfMemory;
            self.offset = std.math.add(usize, start, size) catch return error.OutOfMemory;
            if (copying) std.debug.assert(self.offset <= self.buffer.len);
            return start;
        }

        fn copy(self: *Self, value: anytype) std.mem.Allocator.Error!@TypeOf(value) {
            const T = @TypeOf(value);
            switch (@typeInfo(T)) {
                .@"struct" => |info| {
                    var result = value;
                    inline for (info.fields) |field| {
                        const copied = try self.copy(@field(value, field.name));
                        if (copying) @field(result, field.name) = copied;
                    }
                    return result;
                },
                .@"union" => {
                    switch (value) {
                        inline else => |payload, tag| {
                            const copied = try self.copy(payload);
                            return if (copying) @unionInit(T, @tagName(tag), copied) else value;
                        },
                    }
                },
                .optional => return if (value) |payload| try self.copy(payload) else null,
                .pointer => |info| {
                    comptime std.debug.assert(info.is_const and info.sentinel_ptr == null);
                    const Child = info.child;
                    switch (info.size) {
                        .slice => {
                            if (value.len == 0) return &.{};
                            const start = try self.reserve(Child, value.len);
                            const destination = if (copying) destination: {
                                const ptr: [*]Child = @ptrCast(@alignCast(self.buffer.ptr + start));
                                break :destination ptr[0..value.len];
                            } else undefined;
                            if (Child == u8) {
                                if (copying) @memcpy(destination, value);
                            } else {
                                for (value, 0..) |item, index| {
                                    const copied = try self.copy(item);
                                    if (copying) destination[index] = copied;
                                }
                            }
                            return if (copying) destination else value;
                        },
                        .one => {
                            const start = try self.reserve(Child, 1);
                            const copied = try self.copy(value.*);
                            if (!copying) return value;
                            const destination: *Child = @ptrCast(@alignCast(self.buffer.ptr + start));
                            destination.* = copied;
                            return destination;
                        },
                        else => @compileError("unsupported AST pointer"),
                    }
                },
                .int, .bool, .@"enum", .void => return value,
                else => @compileError("unsupported AST field: " ++ @typeName(T)),
            }
        }
    };
}

test "function owns a complete AST in one allocation after parser storage is freed" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const source = @import("source.zig");
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = counted.allocator();
    {
        const function = owned: {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const text = try arena.allocator().dupe(u8,
                \\f() {
                \\    inner() { : "${1:-$(printf nested)}"; }
                \\    if test "$1" = x; then
                \\        printf '%s\n' "${a[1]:-fallback}"
                \\    else
                \\        cat <<EOF
                \\${x:-$(printf body)}
                \\EOF
                \\    fi
                \\    [[ ! -n "$x" || "$x" = y ]]
                \\    : <(printf process)
                \\} 3>out
            );
            const src: source.Source = .{
                .id = 1,
                .kind = .sourced_file,
                .name = try arena.allocator().dupe(u8, "source-file"),
                .text = text,
            };
            const tokens = try lexer.lex(arena.allocator(), src);
            const program = try parser.parse(arena.allocator(), src, tokens);
            const definition = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].function_definition;
            const function = try Function.create(allocator, definition, src.name);
            errdefer function.release(allocator);
            try std.testing.expectEqualDeep(definition, function.definition);
            try std.testing.expect(definition.name.ptr != function.name.ptr);
            break :owned function;
        };
        defer function.release(allocator);
        function.validate();
        try std.testing.expectEqualStrings("f", function.name);
        try std.testing.expectEqualStrings("source-file", function.source_name);
        try std.testing.expectEqual(@as(usize, 1), counted.allocations);
        try std.testing.expectEqual(function.allocation_len, counted.allocated_bytes);
        function.retain();
        function.release(allocator);
        try std.testing.expectEqual(@as(usize, 1), function.references);
        try std.testing.expectEqual(@as(usize, 0), counted.deallocations);
    }
    try std.testing.expectEqual(@as(usize, 1), counted.deallocations);
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}
