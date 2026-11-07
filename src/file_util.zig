//! Small file helpers shared by invocation paths.

const std = @import("std");

const host = @import("host.zig");

/// An unlinked, private (0600) temporary file whose descriptor is never a
/// standard stream. It captures output that may exceed a pipe buffer while the
/// writer runs in the current process, without a path another user can race.
pub const AnonymousFile = struct {
    fd: host.Fd,

    /// `file_host` must provide RealHost's `openZ`, `duplicateAtLeast`,
    /// `close`, and `deleteFileZ`. `prefix` names the file while it exists.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, file_host: anytype, prefix: []const u8) !AnonymousFile {
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            var random: u64 = undefined;
            io.random(std.mem.asBytes(&random));
            const path = try std.fmt.allocPrintSentinel(allocator, "/tmp/{s}-{x}", .{ prefix, random }, 0);
            defer allocator.free(path);
            const opened_fd = file_host.openZ(path, .{
                .access = .read_write,
                .create = true,
                .append = true,
                .exclusive = true,
                .mode = 0o600,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            const fd = file_host.duplicateAtLeast(opened_fd, 3) catch |err| {
                // Best-effort cleanup while returning the primary error.
                file_host.close(opened_fd) catch {};
                // Best-effort cleanup while returning the primary error.
                file_host.deleteFileZ(path) catch {};
                return err;
            };
            // The duplicate is the descriptor callers use.
            file_host.close(opened_fd) catch {};
            file_host.deleteFileZ(path) catch |err| {
                // Best-effort cleanup while returning the unlink error.
                file_host.close(fd) catch {};
                return err;
            };
            return .{ .fd = fd };
        }
        return error.PathAlreadyExists;
    }

    pub fn deinit(self: *AnonymousFile, file_host: anytype) void {
        // Closing a private unlinked file cannot lose data callers still need.
        file_host.close(self.fd) catch {};
        self.* = undefined;
    }

    /// Appends everything written so far to `output`.
    pub fn readAll(
        self: AnonymousFile,
        allocator: std.mem.Allocator,
        file_host: anytype,
        output: *std.ArrayList(u8),
    ) !void {
        try file_host.seekTo(self.fd, 0);
        var buffer: [4096]u8 = undefined;
        while (true) {
            const read_len = try file_host.read(self.fd, &buffer);
            if (read_len == 0) break;
            try output.appendSlice(allocator, buffer[0..read_len]);
        }
    }
};

test "anonymous files never occupy a standard descriptor" {
    var real_host: host.RealHost = .{};
    const saved_stdin = try real_host.duplicate(.stdin);
    defer {
        real_host.duplicateTo(saved_stdin, .stdin) catch unreachable;
        real_host.close(saved_stdin) catch unreachable;
    }
    try real_host.close(.stdin);

    var file = try AnonymousFile.init(std.testing.allocator, std.testing.io, &real_host, "rush-test");
    defer file.deinit(&real_host);
    try std.testing.expect(file.fd.raw() >= 3);
}

/// Returns the complete file contents owned by `allocator`.
pub fn readFileAlloc(allocator: std.mem.Allocator, real_host: *host.RealHost, path: []const u8) ![]const u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = try real_host.openZ(path_z, .{ .access = .read_only });
    defer real_host.close(fd) catch {};

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var buffer: [8192]u8 = undefined;
    while (true) {
        const read_len = try real_host.read(fd, &buffer);
        if (read_len == 0) break;
        try bytes.appendSlice(allocator, buffer[0..read_len]);
    }
    return bytes.toOwnedSlice(allocator);
}
