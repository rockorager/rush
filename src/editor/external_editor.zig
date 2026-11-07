//! Filesystem and process orchestration for editing a command with an external editor.

const std = @import("std");

const ExternalEditorTempFile = struct {
    dir: std.Io.Dir,
    sub_path: []const u8,
    path: []const u8,

    fn deinit(self: ExternalEditorTempFile, allocator: std.mem.Allocator, io: std.Io) void {
        // Best-effort temporary file cleanup.
        self.dir.deleteFile(io, self.sub_path) catch {};
        self.dir.close(io);
        allocator.free(self.path);
        allocator.free(self.sub_path);
    }
};

pub fn editCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    editor_command: []const u8,
    tmpdir: []const u8,
    initial_text: []const u8,
) ![]const u8 {
    const temp = try createTempFile(allocator, io, tmpdir, initial_text);
    defer temp.deinit(allocator, io);

    try runCommand(allocator, io, editor_command, temp.path);
    return temp.dir.readFileAlloc(io, temp.sub_path, allocator, .limited(1024 * 1024));
}

fn createTempFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmpdir: []const u8,
    initial_text: []const u8,
) !ExternalEditorTempFile {
    var dir = if (std.fs.path.isAbsolute(tmpdir))
        try std.Io.Dir.openDirAbsolute(io, tmpdir, .{})
    else
        try std.Io.Dir.cwd().openDir(io, tmpdir, .{});
    errdefer dir.close(io);

    var attempts: usize = 0;
    while (attempts < 64) : (attempts += 1) {
        const sub_path = try allocator.print(
            "rush-edit-{d}-{d}-{d}.sh",
            .{ std.c.getpid(), nowMs(io), attempts },
        );
        errdefer allocator.free(sub_path);
        var file = dir.createFile(io, sub_path, .{
            .read = true,
            .exclusive = true,
            .permissions = @fromBackingInt(@intCast(0o600)),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(sub_path);
                continue;
            },
            else => |e| return e,
        };
        defer file.close(io);
        try file.writeStreamingAll(io, initial_text);
        if (initial_text.len != 0 and initial_text[initial_text.len - 1] != '\n') try file.writeStreamingAll(io, "\n");
        const path = try std.fs.path.join(allocator, &.{ tmpdir, sub_path });
        return .{ .dir = dir, .sub_path = sub_path, .path = path };
    }
    return error.TemporaryNameExhausted;
}

fn runCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    editor_command: []const u8,
    path: []const u8,
) !void {
    const command = try allocator.print("exec {s} \"$1\"", .{editor_command});
    defer allocator.free(command);
    const argv = [_][]const u8{ "/bin/sh", "-c", command, "rush-editor", path };
    var child = try std.process.spawn(io, .{ .argv = &argv });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ExternalEditorFailed,
        .signal, .stopped, .unknown => return error.ExternalEditorFailed,
    }
}

fn nowMs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds());
}

test "external editor helper writes reads and removes temporary command file" {
    const tmpdir = "rush-editor-test-tmp";
    try std.Io.Dir.cwd().deleteTree(std.testing.io, tmpdir);
    try std.Io.Dir.cwd().createDir(std.testing.io, tmpdir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tmpdir) catch {};

    const edited = try editCommand(
        std.testing.allocator,
        std.testing.io,
        "/bin/sh -c 'grep -q original \"$1\" && printf edited > \"$1\"' edit",
        tmpdir,
        "original",
    );
    defer std.testing.allocator.free(edited);

    try std.testing.expectEqualStrings("edited", edited);
}

test "external editor helper rejects failed editor commands" {
    const tmpdir = "rush-editor-fail-test-tmp";
    try std.Io.Dir.cwd().deleteTree(std.testing.io, tmpdir);
    try std.Io.Dir.cwd().createDir(std.testing.io, tmpdir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tmpdir) catch {};

    try std.testing.expectError(
        error.ExternalEditorFailed,
        editCommand(std.testing.allocator, std.testing.io, "false", tmpdir, "original"),
    );
}
