//! Interactive startup file and path handling.

const std = @import("std");
const build_config = @import("build_config");
const default_config = @embedFile("default_config");

const file_util = @import("../file_util.zig");
const shell = @import("../shell.zig");

pub fn source(
    sh: anytype,
    source_id: *shell.source.SourceId,
    login: bool,
) !?u8 {
    // Do not let inherited environment paths execute code with elevated IDs.
    // Guard Rush startup files too, not just the POSIX ENV file.
    if (!sh.host.credentialsMatch()) return null;

    if (try sourceText(sh, source_id, "default_config", default_config)) |status| return status;

    if (envValue(sh.env, "ENV")) |env_path| {
        if (env_path.len != 0) {
            const expanded_env_path = try expandEnvPath(sh, env_path);
            defer sh.allocator.free(expanded_env_path);
            if (expanded_env_path.len != 0) {
                if (try sourceFileIfExists(sh, source_id, expanded_env_path)) |status| return status;
            }
        }
    }

    if (login) {
        const system_profile = try std.fs.path.join(
            sh.allocator,
            &.{ build_config.sysconfdir, "rush", "profile.rush" },
        );
        defer sh.allocator.free(system_profile);
        if (try sourceFileIfExists(sh, source_id, system_profile)) |status| return status;

        const user_profile = try userConfigPath(sh.allocator, sh.env, "profile.rush");
        defer if (user_profile) |path| sh.allocator.free(path);
        if (user_profile) |path| {
            if (try sourceFileIfExists(sh, source_id, path)) |status| return status;
        }
    }

    const system_config = try std.fs.path.join(sh.allocator, &.{ build_config.sysconfdir, "rush", "config.rush" });
    defer sh.allocator.free(system_config);
    if (try sourceFileIfExists(sh, source_id, system_config)) |status| return status;

    const user_config = try userConfigPath(sh.allocator, sh.env, "config.rush");
    defer if (user_config) |path| sh.allocator.free(path);
    if (user_config) |path| {
        if (try sourceFileIfExists(sh, source_id, path)) |status| return status;
    }

    return null;
}

fn expandEnvPath(sh: anytype, path: []const u8) ![]const u8 {
    const scratch = try sh.beginScratchScope();
    defer scratch.end();
    const expanded = try shell.eval.expandParametersScalar(sh, path);
    return sh.allocator.dupe(u8, expanded);
}

fn sourceFileIfExists(
    sh: anytype,
    source_id: *shell.source.SourceId,
    path: []const u8,
) !?u8 {
    const path_z = try sh.allocator.dupeZ(u8, path);
    defer sh.allocator.free(path_z);
    if (!sh.host.fileAccessZ(path_z, .read)) return null;

    const text = file_util.readFileAlloc(sh.allocator, &sh.host, path) catch {
        const message = try std.fmt.allocPrint(sh.scratchAllocator(), "rush: cannot read {s}\n", .{path});
        try sh.host.writeAll(.stderr, message);
        return null;
    };
    defer sh.allocator.free(text);
    return sourceText(sh, source_id, path, text);
}

fn sourceText(
    sh: anytype,
    source_id: *shell.source.SourceId,
    name: []const u8,
    text: []const u8,
) !?u8 {
    const src: shell.source.Source = .{
        .id = source_id.*,
        .kind = .sourced_file,
        .name = name,
        .text = text,
    };
    source_id.* +%= 1;

    const evaluated = sh.evalSource(src) catch {
        const message = try std.fmt.allocPrint(sh.scratchAllocator(), "rush: error while sourcing {s}\n", .{name});
        try sh.host.writeAll(.stderr, message);
        return null;
    };
    return switch (evaluated.flow) {
        .exit => |status| shell.eval.runExitTrap(sh, status) catch 2,
        else => null,
    };
}

pub fn userConfigPath(allocator: std.mem.Allocator, env: []const [*:0]const u8, file_name: []const u8) !?[]const u8 {
    if (envValue(env, "XDG_CONFIG_HOME")) |xdg_config_home| {
        if (xdg_config_home.len != 0) return try std.fs.path.join(allocator, &.{ xdg_config_home, "rush", file_name });
    }

    const home = envValue(env, "HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(allocator, &.{ home, ".config", "rush", file_name });
}

pub fn historyPath(allocator: std.mem.Allocator, env: []const [*:0]const u8) !?[]const u8 {
    if (envValue(env, "XDG_STATE_HOME")) |xdg_state_home| {
        if (xdg_state_home.len != 0) return try std.fs.path.join(allocator, &.{
            xdg_state_home,
            "rush",
            "history.sqlite",
        });
    }
    const home = envValue(env, "HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(allocator, &.{ home, ".local", "state", "rush", "history.sqlite" });
}

pub fn envValue(env: []const [*:0]const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len != 0);
    for (env) |entry_ptr| {
        const entry = std.mem.span(entry_ptr);
        if (entry.len <= name.len or entry[name.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

test "interactive startup paths follow XDG variables" {
    const env = [_][:0]const u8{
        "HOME=/home/test",
        "XDG_CONFIG_HOME=/tmp/config",
        "XDG_STATE_HOME=/tmp/state",
    };
    const env_ptrs = [_][*:0]const u8{ env[0].ptr, env[1].ptr, env[2].ptr };

    const config_path = (try userConfigPath(std.testing.allocator, &env_ptrs, "config.rush")).?;
    defer std.testing.allocator.free(config_path);
    try std.testing.expectEqualStrings("/tmp/config/rush/config.rush", config_path);

    const history_path = (try historyPath(std.testing.allocator, &env_ptrs)).?;
    defer std.testing.allocator.free(history_path);
    try std.testing.expectEqualStrings("/tmp/state/rush/history.sqlite", history_path);
}

test "interactive startup paths fall back to HOME" {
    const env = [_][:0]const u8{"HOME=/home/test"};
    const env_ptrs = [_][*:0]const u8{env[0].ptr};

    const config_path = (try userConfigPath(std.testing.allocator, &env_ptrs, "profile.rush")).?;
    defer std.testing.allocator.free(config_path);
    try std.testing.expectEqualStrings("/home/test/.config/rush/profile.rush", config_path);

    const history_path = (try historyPath(std.testing.allocator, &env_ptrs)).?;
    defer std.testing.allocator.free(history_path);
    try std.testing.expectEqualStrings("/home/test/.local/state/rush/history.sqlite", history_path);
}

test {
    std.testing.refAllDecls(@This());
}
