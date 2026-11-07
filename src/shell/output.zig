//! Shell output adapters backed by Host effects.

const std = @import("std");

const host_mod = @import("../host.zig");

pub fn HostWriter(comptime Host: type) type {
    return struct {
        host: *Host,
        fd: host_mod.Fd,
        interface: std.Io.Writer,

        const Self = @This();

        pub fn init(host: *Host, fd: host_mod.Fd, buffer: []u8) Self {
            std.debug.assert(buffer.len != 0);
            return .{
                .host = host,
                .fd = fd,
                .interface = .{
                    .vtable = &.{ .drain = drain },
                    .buffer = buffer,
                },
            };
        }

        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", writer));
            if (writer.end != 0) {
                self.host.writeAll(self.fd, writer.buffer[0..writer.end]) catch return error.WriteFailed;
                writer.end = 0;
            }
            for (data[0 .. data.len - 1]) |bytes| {
                self.host.writeAll(self.fd, bytes) catch return error.WriteFailed;
            }

            const pattern = data[data.len - 1];
            if (pattern.len == 1) {
                var remaining = splat;
                while (remaining >= writer.buffer.len) {
                    @memset(writer.buffer, pattern[0]);
                    self.host.writeAll(self.fd, writer.buffer) catch return error.WriteFailed;
                    remaining -= writer.buffer.len;
                }
                if (remaining != 0) {
                    @memset(writer.buffer[0..remaining], pattern[0]);
                    writer.end = remaining;
                }
            } else if (pattern.len != 0) {
                for (0..splat) |_| self.host.writeAll(self.fd, pattern) catch return error.WriteFailed;
            }
            return std.Io.Writer.countSplat(data, splat);
        }
    };
}

test "HostWriter buffers writes until flush" {
    const TestHost = struct {
        bytes: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.bytes.deinit(std.testing.allocator);
        }

        pub fn writeAll(self: *@This(), fd: host_mod.Fd, bytes: []const u8) !void {
            try std.testing.expectEqual(host_mod.Fd.stdout, fd);
            try self.bytes.appendSlice(std.testing.allocator, bytes);
        }
    };

    var host: TestHost = .{};
    defer host.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = HostWriter(TestHost).init(&host, .stdout, &buffer);
    try writer.interface.writeAll("hello");
    try std.testing.expectEqualStrings("", host.bytes.items);
    try writer.interface.flush();
    try std.testing.expectEqualStrings("hello", host.bytes.items);
}

test "HostWriter flushes repeated bytes in buffer-sized chunks" {
    const TestHost = struct {
        bytes: std.ArrayList(u8) = .empty,
        writes: usize = 0,

        fn deinit(self: *@This()) void {
            self.bytes.deinit(std.testing.allocator);
        }

        pub fn writeAll(self: *@This(), fd: host_mod.Fd, bytes: []const u8) !void {
            try std.testing.expectEqual(host_mod.Fd.stdout, fd);
            try self.bytes.appendSlice(std.testing.allocator, bytes);
            self.writes += 1;
        }
    };

    var host: TestHost = .{};
    defer host.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = HostWriter(TestHost).init(&host, .stdout, &buffer);
    try writer.interface.splatByteAll('x', buffer.len + 3);

    try std.testing.expectEqual(@as(usize, 1), host.writes);
    try std.testing.expectEqual(buffer.len, host.bytes.items.len);
    try writer.interface.flush();
    try std.testing.expectEqual(@as(usize, 2), host.writes);
    try std.testing.expectEqual(buffer.len + 3, host.bytes.items.len);
    try std.testing.expect(std.mem.allEqual(u8, host.bytes.items, 'x'));
}
