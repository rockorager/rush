//! Filesystem lookup helpers for completion candidates.

const std = @import("std");

const host = @import("host.zig");

/// Expands the leading tilde forms supported by Rush while leaving candidate
/// spelling to the caller. The returned path is always allocator-owned.
pub fn expandLeadingTilde(
    allocator: std.mem.Allocator,
    path: []const u8,
    home: ?[]const u8,
) ![]u8 {
    const value = home orelse return allocator.dupe(u8, path);
    if (path.len == 0 or path[0] != '~') return allocator.dupe(u8, path);
    if (path.len != 1 and path[1] != '/') return allocator.dupe(u8, path);
    return allocator.print("{s}{s}", .{ value, path[1..] });
}

/// Returns whether `entry` should complete as a directory.
///
/// Directory dirents are accepted as-is. Symlink and unknown (`.other`) dirents
/// are classified by `sh.host.fileTestStatusZ` with follow-symlink enabled.
/// A failed follow or non-directory target returns false. Temporary path
/// buffers are allocated and freed before return. `home` is used only when
/// `expand_leading_tilde` is set.
pub fn pathCandidateIsDirectory(
    allocator: std.mem.Allocator,
    sh: anytype,
    dir_prefix: []const u8,
    expand_leading_tilde: bool,
    home: ?[]const u8,
    entry: host.DirectoryEntry,
) !bool {
    if (entry.kind == .directory) return true;
    if (entry.kind != .symlink and entry.kind != .other) return false;

    const unexpanded_path = try allocator.print("{s}{s}", .{ dir_prefix, entry.name });
    defer allocator.free(unexpanded_path);
    const path = if (expand_leading_tilde)
        try expandLeadingTilde(allocator, unexpanded_path, home)
    else
        try allocator.dupe(u8, unexpanded_path);
    defer allocator.free(path);
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    const status = sh.host.fileTestStatusZ(path_z, true) orelse return false;
    return status.kind == .directory;
}

test "completion lookup expands only supported leading tilde forms" {
    const home_path = try expandLeadingTilde(std.testing.allocator, "~/.config", "/home/alice");
    defer std.testing.allocator.free(home_path);
    try std.testing.expectEqualStrings("/home/alice/.config", home_path);

    const named_user = try expandLeadingTilde(std.testing.allocator, "~bob/src", "/home/alice");
    defer std.testing.allocator.free(named_user);
    try std.testing.expectEqualStrings("~bob/src", named_user);

    const no_home = try expandLeadingTilde(std.testing.allocator, "~/src", null);
    defer std.testing.allocator.free(no_home);
    try std.testing.expectEqualStrings("~/src", no_home);
}

test "path candidates follow only symlink and unknown directory targets" {
    const Host = struct {
        const Self = @This();

        expected_path: []const u8,
        follow_kind: ?host.FileKind,
        follow_called: *bool,

        pub fn fileTestStatusZ(self: *Self, path: [:0]const u8, follow_symlinks: bool) ?host.FileStatus {
            self.follow_called.* = true;
            std.testing.expect(follow_symlinks) catch unreachable;
            std.testing.expectEqualStrings(self.expected_path, path) catch unreachable;
            return if (self.follow_kind) |kind| .{ .kind = kind } else null;
        }
    };
    const Shell = struct {
        host: Host,
    };
    const Case = struct {
        kind: host.FileKind,
        follow_kind: ?host.FileKind = null,
        expect_directory: bool,
        expect_follow: bool,
        dir_prefix: []const u8 = "",
        name: []const u8 = "target",
        expected_path: []const u8 = "target",
        expand_tilde: bool = false,
        home: ?[]const u8 = null,
    };
    const cases = [_]Case{
        .{ .kind = .directory, .expect_directory = true, .expect_follow = false },
        .{ .kind = .file, .expect_directory = false, .expect_follow = false },
        .{ .kind = .named_pipe, .expect_directory = false, .expect_follow = false },
        .{ .kind = .symlink, .follow_kind = .directory, .expect_directory = true, .expect_follow = true },
        .{ .kind = .symlink, .follow_kind = .file, .expect_directory = false, .expect_follow = true },
        .{ .kind = .symlink, .follow_kind = null, .expect_directory = false, .expect_follow = true },
        .{ .kind = .other, .follow_kind = .directory, .expect_directory = true, .expect_follow = true },
        .{ .kind = .other, .follow_kind = .file, .expect_directory = false, .expect_follow = true },
        .{
            .kind = .symlink,
            .follow_kind = .directory,
            .expect_directory = true,
            .expect_follow = true,
            .dir_prefix = "~/",
            .expected_path = "/home/alice/target",
            .expand_tilde = true,
            .home = "/home/alice",
        },
        .{
            .kind = .symlink,
            .follow_kind = .directory,
            .expect_directory = true,
            .expect_follow = true,
            .dir_prefix = ".config/",
            .expected_path = ".config/target",
        },
    };

    for (cases) |case| {
        var followed = false;
        var sh: Shell = .{
            .host = .{
                .expected_path = case.expected_path,
                .follow_kind = case.follow_kind,
                .follow_called = &followed,
            },
        };
        const is_directory = try pathCandidateIsDirectory(
            std.testing.allocator,
            &sh,
            case.dir_prefix,
            case.expand_tilde,
            case.home,
            .{ .name = case.name, .kind = case.kind },
        );
        try std.testing.expectEqual(case.expect_directory, is_directory);
        try std.testing.expectEqual(case.expect_follow, followed);
    }
}
