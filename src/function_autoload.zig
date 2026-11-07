//! Rush function autoload search and sourcing.

const std = @import("std");
const build_config = @import("build_config");

const host = @import("host.zig");
const shell = @import("shell.zig");

const max_function_source_bytes = 1024 * 1024;

pub fn autoload(sh: anytype, name: []const u8) !bool {
    if (!isFunctionName(name)) return false;
    if (sh.state.isFunctionAutoloadSuppressed(name)) return false;
    if (sh.state.isFunctionAutoloadMissed(name)) return false;

    const source = try findFunctionSource(sh, name) orelse {
        try sh.state.markFunctionAutoloadMissed(name);
        return false;
    };
    defer source.deinit(sh.allocator);

    var discard = try OutputDiscard.init(&sh.host);
    defer discard.restore(&sh.host) catch {};

    const src: shell.source.Source = .{
        .id = 0,
        .kind = .sourced_file,
        .name = source.path,
        .text = source.text,
    };
    const evaluated = try sh.evalSourceNested(src);
    if (evaluated.flow == .exit or evaluated.flow == .fatal) return false;
    return sh.state.getFunction(name) != null;
}

const FunctionSource = struct {
    path: []const u8,
    text: []const u8,

    fn deinit(self: FunctionSource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.text);
    }
};

fn findFunctionSource(sh: anytype, name: []const u8) !?FunctionSource {
    var dirs = try functionSearchDirs(sh.allocator, sh);
    defer dirs.deinit();

    const file_name = try std.fmt.allocPrint(sh.allocator, "{s}.rush", .{name});
    defer sh.allocator.free(file_name);

    for (dirs.paths) |dir| {
        const path = try std.fs.path.join(sh.allocator, &.{ dir, file_name });
        errdefer sh.allocator.free(path);
        const text = readFileAlloc(sh, path) catch |err| switch (err) {
            error.FileNotFound => {
                sh.allocator.free(path);
                continue;
            },
            else => return err,
        };
        return .{ .path = path, .text = text };
    }
    return null;
}

const SearchDirs = struct {
    allocator: std.mem.Allocator,
    paths: []const []const u8,

    fn deinit(self: *SearchDirs) void {
        for (self.paths) |path| self.allocator.free(path);
        self.allocator.free(self.paths);
        self.* = undefined;
    }
};

fn functionSearchDirs(allocator: std.mem.Allocator, sh: anytype) !SearchDirs {
    var config_dirs: std.ArrayList([]const u8) = .empty;
    defer freePathList(allocator, &config_dirs);
    var data_dirs: std.ArrayList([]const u8) = .empty;
    defer freePathList(allocator, &data_dirs);

    try appendUserConfigDir(allocator, sh, &config_dirs);
    try appendPath(allocator, &config_dirs, &.{ build_config.sysconfdir, "rush", "functions" });
    try appendUserDataDir(allocator, sh, &data_dirs);
    try appendXdgDataDirs(allocator, sh, &data_dirs);
    try appendPath(allocator, &data_dirs, &.{ build_config.datadir, "rush", "functions" });

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer freePathList(allocator, &paths);
    try appendUniquePaths(allocator, &paths, config_dirs.items);
    try appendUniquePaths(allocator, &paths, data_dirs.items);
    return .{ .allocator = allocator, .paths = try paths.toOwnedSlice(allocator) };
}

fn appendUserConfigDir(allocator: std.mem.Allocator, sh: anytype, paths: *std.ArrayList([]const u8)) !void {
    if (shellValue(sh, "XDG_CONFIG_HOME")) |xdg_config_home| {
        if (xdg_config_home.len != 0) return appendPath(allocator, paths, &.{ xdg_config_home, "rush", "functions" });
    }
    if (shellValue(sh, "HOME")) |home| {
        if (home.len != 0) return appendPath(allocator, paths, &.{ home, ".config", "rush", "functions" });
    }
}

fn appendUserDataDir(allocator: std.mem.Allocator, sh: anytype, paths: *std.ArrayList([]const u8)) !void {
    if (shellValue(sh, "XDG_DATA_HOME")) |xdg_data_home| {
        if (xdg_data_home.len != 0) return appendPath(allocator, paths, &.{ xdg_data_home, "rush", "functions" });
    }
    if (shellValue(sh, "HOME")) |home| {
        if (home.len != 0) return appendPath(allocator, paths, &.{ home, ".local", "share", "rush", "functions" });
    }
}

fn appendXdgDataDirs(allocator: std.mem.Allocator, sh: anytype, paths: *std.ArrayList([]const u8)) !void {
    const value = shellValue(sh, "XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var parts = std.mem.splitScalar(u8, value, ':');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        try appendPath(allocator, paths, &.{ part, "rush", "functions" });
    }
}

fn appendPath(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), parts: []const []const u8) !void {
    try paths.append(allocator, try std.fs.path.join(allocator, parts));
}

fn appendUniquePaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), candidates: []const []const u8) !void {
    for (candidates) |candidate| {
        if (pathListContains(paths.items, candidate)) continue;
        try paths.append(allocator, try allocator.dupe(u8, candidate));
    }
}

fn pathListContains(paths: []const []const u8, candidate: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, candidate)) return true;
    return false;
}

fn freePathList(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

fn shellValue(sh: anytype, name: []const u8) ?[]const u8 {
    if (sh.state.getVariable(name)) |variable| return variable.value;
    for (sh.env) |entry| {
        const value = std.mem.span(entry);
        if (value.len <= name.len or value[name.len] != '=') continue;
        if (std.mem.eql(u8, value[0..name.len], name)) return value[name.len + 1 ..];
    }
    return null;
}

fn readFileAlloc(sh: anytype, path: []const u8) ![]const u8 {
    const path_z = try sh.allocator.dupeZ(u8, path);
    defer sh.allocator.free(path_z);
    const fd = try sh.host.openZ(path_z, .{ .access = .read_only });
    defer sh.host.close(fd) catch {};

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(sh.allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        if (output.items.len > max_function_source_bytes) return error.StreamTooLong;
        const read_len = try sh.host.read(fd, &buffer);
        if (read_len == 0) break;
        try output.appendSlice(sh.allocator, buffer[0..read_len]);
    }
    return output.toOwnedSlice(sh.allocator);
}

const OutputDiscard = struct {
    saved_stdout: host.Fd,
    saved_stderr: host.Fd,
    null_fd: host.Fd,
    active: bool = true,

    fn init(real_host: *host.RealHost) !OutputDiscard {
        const null_fd = try real_host.openZ("/dev/null", .{ .access = .write_only });
        errdefer real_host.close(null_fd) catch {};
        const saved_stdout = try real_host.duplicate(.stdout);
        errdefer real_host.close(saved_stdout) catch {};
        const saved_stderr = try real_host.duplicate(.stderr);
        errdefer real_host.close(saved_stderr) catch {};
        try real_host.duplicateTo(null_fd, .stdout);
        errdefer real_host.duplicateTo(saved_stdout, .stdout) catch {};
        try real_host.duplicateTo(null_fd, .stderr);
        return .{
            .saved_stdout = saved_stdout,
            .saved_stderr = saved_stderr,
            .null_fd = null_fd,
        };
    }

    fn restore(self: *OutputDiscard, real_host: *host.RealHost) !void {
        if (!self.active) return;
        self.active = false;
        try real_host.duplicateTo(self.saved_stdout, .stdout);
        try real_host.duplicateTo(self.saved_stderr, .stderr);
        real_host.close(self.saved_stdout) catch {};
        real_host.close(self.saved_stderr) catch {};
        real_host.close(self.null_fd) catch {};
    }
};

fn isFunctionName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '.') return false;
    }
    return true;
}

test "function search dirs follow config before data order" {
    var sh = TestRushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    try sh.state.putVariable(.{ .name = "HOME", .value = "/home/alice" });
    try sh.state.putVariable(.{ .name = "XDG_CONFIG_HOME", .value = "/cfg" });
    try sh.state.putVariable(.{ .name = "XDG_DATA_HOME", .value = "/data-home" });
    try sh.state.putVariable(.{ .name = "XDG_DATA_DIRS", .value = "/data-one:/data-two" });

    var dirs = try functionSearchDirs(std.testing.allocator, &sh);
    defer dirs.deinit();

    try std.testing.expectEqualStrings("/cfg/rush/functions", dirs.paths[0]);
    try std.testing.expectEqualStrings(build_config.sysconfdir ++ "/rush/functions", dirs.paths[1]);
    try std.testing.expectEqualStrings("/data-home/rush/functions", dirs.paths[2]);
    try std.testing.expectEqualStrings("/data-one/rush/functions", dirs.paths[3]);
    try std.testing.expectEqualStrings("/data-two/rush/functions", dirs.paths[4]);
    try std.testing.expectEqualStrings(build_config.datadir ++ "/rush/functions", dirs.paths[5]);
}

test "autoload sources dotted function into current shell and hides load output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(allocator, "rush-test-autoload-{d}", .{std.c.getpid()});
    defer allocator.free(root);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const functions_dir = try std.fs.path.join(allocator, &.{ root, "rush", "functions" });
    defer allocator.free(functions_dir);
    try std.Io.Dir.cwd().createDirPath(io, functions_dir);
    const function_path = try std.fs.path.join(allocator, &.{ functions_dir, "zig_0.16.0.rush" });
    defer allocator.free(function_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = function_path,
        .data =
        \\printf 'autoload noise\n'
        \\zig_0.16.0(){ printf 'hello:%s\n' "$1"; }
        \\
        ,
    });

    var sh = TestRushShell.init(allocator, .{}, .{});
    defer sh.deinit();
    sh.setFunctionAutoload(testAutoload);
    try sh.state.putVariable(.{ .name = "XDG_CONFIG_HOME", .value = root });

    const out_path = try std.fs.path.join(allocator, &.{ root, "out.txt" });
    defer allocator.free(out_path);
    const command = try std.fmt.allocPrint(allocator, "zig_0.16.0 world > {s}", .{out_path});
    defer allocator.free(command);
    const src: shell.source.Source = .{ .id = 1, .kind = .command_string, .name = "test", .text = command };
    const evaluated = try sh.evalSource(src);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 0), evaluated.status);

    const output = try std.Io.Dir.cwd().readFileAlloc(io, out_path, allocator, .limited(1024));
    defer allocator.free(output);
    try std.testing.expectEqualStrings("hello:world\n", output);
    try std.testing.expect(sh.state.getFunction("zig_0.16.0") != null);

    const suppressed_path = try std.fs.path.join(allocator, &.{ root, "suppressed.txt" });
    defer allocator.free(suppressed_path);
    const suppressed_command = try std.fmt.allocPrint(
        allocator,
        "unset -f zig_0.16.0; zig_0.16.0 > {s} 2>&1",
        .{suppressed_path},
    );
    defer allocator.free(suppressed_command);
    const suppressed_src: shell.source.Source = .{
        .id = 2,
        .kind = .command_string,
        .name = "test",
        .text = suppressed_command,
    };
    const suppressed = try sh.evalSource(suppressed_src);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 127), suppressed.status);
    try std.testing.expect(sh.state.getFunction("zig_0.16.0") == null);

    const redefined_path = try std.fs.path.join(allocator, &.{ root, "redefined.txt" });
    defer allocator.free(redefined_path);
    const redefined_command = try std.fmt.allocPrint(
        allocator,
        "zig_0.16.0(){{ printf redefined; }}; zig_0.16.0 > {s}",
        .{redefined_path},
    );
    defer allocator.free(redefined_command);
    const redefined_src: shell.source.Source = .{
        .id = 3,
        .kind = .command_string,
        .name = "test",
        .text = redefined_command,
    };
    const redefined = try sh.evalSource(redefined_src);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 0), redefined.status);
    const redefined_output = try std.Io.Dir.cwd().readFileAlloc(io, redefined_path, allocator, .limited(1024));
    defer allocator.free(redefined_output);
    try std.testing.expectEqualStrings("redefined", redefined_output);
}

test "autoload protects function definition from same-name alias" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(allocator, "rush-test-autoload-alias-{d}", .{std.c.getpid()});
    defer allocator.free(root);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const functions_dir = try std.fs.path.join(allocator, &.{ root, "rush", "functions" });
    defer allocator.free(functions_dir);
    try std.Io.Dir.cwd().createDirPath(io, functions_dir);

    const name = "rush_alias_autoload_test_function";
    const function_path = try std.fs.path.join(allocator, &.{ functions_dir, name ++ ".rush" });
    defer allocator.free(function_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = function_path,
        .data = name ++ "(){ printf '<%s>\\n' \"$1\"; }\n",
    });

    var sh = TestRushShell.init(allocator, .{}, .{ .state = .{ .expand_aliases = true } });
    defer sh.deinit();
    sh.setFunctionAutoload(testAutoload);
    try sh.state.putVariable(.{ .name = "XDG_CONFIG_HOME", .value = root });
    try sh.state.putAlias(.{ .name = name, .value = name ++ " prefixed" });

    const out_path = try std.fs.path.join(allocator, &.{ root, "out.txt" });
    defer allocator.free(out_path);
    const command = try std.fmt.allocPrint(allocator, "{s} > {s}", .{ name, out_path });
    defer allocator.free(command);
    const evaluated = try sh.evalSource(.{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text = command,
    });
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 0), evaluated.status);

    const output = try std.Io.Dir.cwd().readFileAlloc(io, out_path, allocator, .limited(1024));
    defer allocator.free(output);
    try std.testing.expectEqualStrings("<prefixed>\n", output);
    try std.testing.expect(sh.state.getFunction(name) != null);
    try std.testing.expectEqualStrings(name ++ " prefixed", sh.state.getAlias(name).?.value);
}

test "autoload caches misses until function is explicitly defined" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(allocator, "rush-test-autoload-miss-{d}", .{std.c.getpid()});
    defer allocator.free(root);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const functions_dir = try std.fs.path.join(allocator, &.{ root, "rush", "functions" });
    defer allocator.free(functions_dir);
    try std.Io.Dir.cwd().createDirPath(io, functions_dir);

    var sh = TestRushShell.init(allocator, .{}, .{});
    defer sh.deinit();
    sh.setFunctionAutoload(testAutoload);
    try sh.state.putVariable(.{ .name = "XDG_CONFIG_HOME", .value = root });

    const name = "rush_missing_autoload_test_function";
    const missing_command = name ++ " >/dev/null 2>&1";
    const missing_src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text = missing_command,
    };
    const missing = try sh.evalSource(missing_src);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 127), missing.status);
    try std.testing.expect(sh.state.isFunctionAutoloadMissed(name));

    const function_path = try std.fs.path.join(allocator, &.{ functions_dir, name ++ ".rush" });
    defer allocator.free(function_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = function_path,
        .data = name ++ "(){ printf autoloaded; }\n",
    });

    const still_missing = try sh.evalSource(.{
        .id = 2,
        .kind = .command_string,
        .name = "test",
        .text = missing_command,
    });
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 127), still_missing.status);
    try std.testing.expect(sh.state.getFunction(name) == null);

    const out_path = try std.fs.path.join(allocator, &.{ root, "explicit.txt" });
    defer allocator.free(out_path);
    const explicit_command = try std.fmt.allocPrint(
        allocator,
        "{s}(){{ printf explicit; }}; {s} > {s}",
        .{ name, name, out_path },
    );
    defer allocator.free(explicit_command);
    const explicit = try sh.evalSource(.{ .id = 3, .kind = .command_string, .name = "test", .text = explicit_command });
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 0), explicit.status);
    try std.testing.expect(!sh.state.isFunctionAutoloadMissed(name));

    const output = try std.Io.Dir.cwd().readFileAlloc(io, out_path, allocator, .limited(1024));
    defer allocator.free(output);
    try std.testing.expectEqualStrings("explicit", output);
}

test "autoload clears cached misses when search path variables change" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(allocator, "rush-test-autoload-path-{d}", .{std.c.getpid()});
    defer allocator.free(root);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const first_root = try std.fs.path.join(allocator, &.{ root, "first" });
    defer allocator.free(first_root);
    const second_root = try std.fs.path.join(allocator, &.{ root, "second" });
    defer allocator.free(second_root);
    const second_functions_dir = try std.fs.path.join(allocator, &.{ second_root, "rush", "functions" });
    defer allocator.free(second_functions_dir);
    try std.Io.Dir.cwd().createDirPath(io, second_functions_dir);

    var sh = TestRushShell.init(allocator, .{}, .{});
    defer sh.deinit();
    sh.setFunctionAutoload(testAutoload);
    try sh.state.putVariable(.{ .name = "XDG_CONFIG_HOME", .value = first_root });

    const name = "rush_autoload_path_change_test_function";
    const missing_command = name ++ " >/dev/null 2>&1";
    const missing = try sh.evalSource(.{ .id = 1, .kind = .command_string, .name = "test", .text = missing_command });
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 127), missing.status);
    try std.testing.expect(sh.state.isFunctionAutoloadMissed(name));

    const function_path = try std.fs.path.join(allocator, &.{ second_functions_dir, name ++ ".rush" });
    defer allocator.free(function_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = function_path,
        .data = name ++ "(){ printf changed-path; }\n",
    });
    try sh.state.putVariable(.{ .name = "XDG_CONFIG_HOME", .value = second_root });
    try std.testing.expect(!sh.state.isFunctionAutoloadMissed(name));

    const out_path = try std.fs.path.join(allocator, &.{ root, "out.txt" });
    defer allocator.free(out_path);
    const command = try std.fmt.allocPrint(allocator, "{s} > {s}", .{ name, out_path });
    defer allocator.free(command);
    const evaluated = try sh.evalSource(.{ .id = 2, .kind = .command_string, .name = "test", .text = command });
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 0), evaluated.status);

    const output = try std.Io.Dir.cwd().readFileAlloc(io, out_path, allocator, .limited(1024));
    defer allocator.free(output);
    try std.testing.expectEqualStrings("changed-path", output);
}

const TestRushShell = shell.ShellWithBuiltins(host.RealHost, @import("extensions.zig").rush.registry);

fn testAutoload(sh: *TestRushShell, name: []const u8) !bool {
    return autoload(sh, name);
}
