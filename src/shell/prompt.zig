//! Bash-compatible prompt escape decoding.

const std = @import("std");

const build_config = @import("build_config");
const prompt_markers = @import("../prompt_markers.zig");
const host_mod = @import("../host.zig");
const state_mod = @import("state.zig");

pub const DecodeMode = enum {
    parameter,
    editor,
};

/// Decodes Bash prompt backslash escapes into scratch-allocated text. Editor
/// mode preserves Readline's non-printing regions as internal width markers;
/// parameter mode returns only shell-visible bytes for `${parameter@P}`.
pub fn decode(shell: anytype, value: []const u8, mode: DecodeMode) ![]const u8 {
    if (std.mem.findScalar(u8, value, '\\') == null) return value;

    const allocator = shell.scratchAllocator();
    var output: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] != '\\' or index + 1 >= value.len) {
            try output.append(allocator, value[index]);
            index += 1;
            continue;
        }

        const escape = value[index + 1];
        if (escape >= '0' and escape <= '7') {
            const octal = parseOctalEscape(value, index + 1);
            // Shell strings cannot contain NUL. Bash drops a decoded NUL
            // rather than exposing it from `${parameter@P}` or PS1. Its
            // parameter transform also removes an octal-encoded internal
            // non-printing-start marker, while preserving a literal `\001`.
            if (octal.value != 0 and !(mode == .parameter and octal.parsed == 0o401)) {
                try output.append(allocator, octal.value);
            }
            index = octal.end;
            continue;
        }
        if (escape == 'D' and index + 2 < value.len and value[index + 2] == '{') {
            if (std.mem.findScalar(u8, value[index + 3 ..], '}')) |relative_end| {
                const end = index + 3 + relative_end;
                const format = value[index + 3 .. end];
                try output.appendSlice(allocator, try formatLocalTime(shell, if (format.len == 0) "%X" else format));
                index = end + 1;
                continue;
            }
            const format = value[index + 3 ..];
            try output.appendSlice(allocator, try formatLocalTime(shell, if (format.len == 0) "%X" else format));
            index = value.len;
            continue;
        }

        switch (escape) {
            'a' => try output.append(allocator, 0x07),
            'd' => try output.appendSlice(allocator, try formatLocalTime(shell, "%a %b %d")),
            'e' => try output.append(allocator, 0x1b),
            'h' => try output.appendSlice(allocator, shortHostname(try hostname(shell))),
            'H' => try output.appendSlice(allocator, try hostname(shell)),
            'j' => try appendInteger(allocator, &output, shell.state.background_jobs.items.len),
            'l' => try output.appendSlice(allocator, try terminalName(shell)),
            'n' => try output.append(allocator, '\n'),
            'r' => try output.append(allocator, '\r'),
            's' => try output.appendSlice(allocator, shellName(shell.state.arg_zero)),
            't' => try output.appendSlice(allocator, try formatLocalTime(shell, "%H:%M:%S")),
            'T' => try output.appendSlice(allocator, try formatLocalTime(shell, "%I:%M:%S")),
            '@' => try output.appendSlice(allocator, try formatLocalTime(shell, "%I:%M %p")),
            'A' => try output.appendSlice(allocator, try formatLocalTime(shell, "%H:%M")),
            'u' => try output.appendSlice(allocator, try username(shell)),
            'v' => try output.appendSlice(
                allocator,
                shortVersion(shellValue(shell, "BASH_VERSION") orelse build_config.version),
            ),
            'V' => try output.appendSlice(
                allocator,
                releaseVersion(shellValue(shell, "BASH_VERSION") orelse build_config.version),
            ),
            'w' => try output.appendSlice(allocator, try workingDirectory(shell, false)),
            'W' => try output.appendSlice(allocator, try workingDirectory(shell, true)),
            '!' => try appendInteger(allocator, &output, shell.state.prompt_history_number),
            '#' => try appendInteger(allocator, &output, shell.state.prompt_command_number),
            '$' => try output.append(allocator, if (effectiveUserId(shell) == 0) '#' else '$'),
            '\\' => try output.append(allocator, '\\'),
            '[' => if (mode == .editor) try output.append(allocator, prompt_markers.nonprinting_start),
            ']' => if (mode == .editor) try output.append(allocator, prompt_markers.nonprinting_end),
            else => {
                try output.append(allocator, '\\');
                try output.append(allocator, escape);
            },
        }
        index += 2;
    }
    return output.toOwnedSlice(allocator);
}

const OctalEscape = struct {
    parsed: u16,
    value: u8,
    end: usize,
};

fn parseOctalEscape(value: []const u8, start: usize) OctalEscape {
    std.debug.assert(start < value.len);
    std.debug.assert(value[start] >= '0');
    std.debug.assert(value[start] <= '7');
    var parsed: u16 = 0;
    var end = start;
    while (end < value.len and end - start < 3 and value[end] >= '0' and value[end] <= '7') : (end += 1) {
        parsed = parsed * 8 + value[end] - '0';
    }
    return .{ .parsed = parsed, .value = @truncate(parsed), .end = end };
}

fn appendInteger(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: anytype) !void {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{}", .{value});
    try output.appendSlice(allocator, text);
}

fn username(shell: anytype) ![]const u8 {
    if (shell.state.promptMetadata(.username)) |cached| return cached;
    const host_type = HostType(@TypeOf(shell.host));
    if (comptime @hasDecl(host_type, "effectiveUserName")) {
        const resolved = shell.host.effectiveUserName(shell.scratchAllocator()) catch return fallbackUsername(shell);
        return shell.state.cachePromptMetadata(.username, resolved);
    }
    return fallbackUsername(shell);
}

fn fallbackUsername(shell: anytype) []const u8 {
    return shellValue(shell, "USER") orelse shellValue(shell, "LOGNAME") orelse "unknown";
}

fn hostname(shell: anytype) ![]const u8 {
    if (shell.state.promptMetadata(.hostname)) |cached| return cached;
    const host_type = HostType(@TypeOf(shell.host));
    if (comptime @hasDecl(host_type, "hostname")) {
        const resolved = shell.host.hostname(shell.scratchAllocator()) catch return fallbackHostname(shell);
        return shell.state.cachePromptMetadata(.hostname, resolved);
    }
    return fallbackHostname(shell);
}

fn fallbackHostname(shell: anytype) []const u8 {
    return shellValue(shell, "HOSTNAME") orelse "localhost";
}

fn shortHostname(name: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, name, '.') orelse name.len;
    return name[0..end];
}

fn terminalName(shell: anytype) ![]const u8 {
    if (shell.state.promptMetadata(.terminal_name)) |cached| return cached;
    const host_type = HostType(@TypeOf(shell.host));
    if (comptime @hasDecl(host_type, "terminalName")) {
        const fd = shell.state.controlling_tty orelse host_mod.Fd.stdin;
        const path = shell.host.terminalName(shell.scratchAllocator(), fd) catch return "";
        return shell.state.cachePromptMetadata(.terminal_name, std.fs.path.basename(path));
    }
    return "";
}

fn formatLocalTime(shell: anytype, format: []const u8) ![]const u8 {
    const host_type = HostType(@TypeOf(shell.host));
    if (comptime @hasDecl(host_type, "formatLocalTime")) {
        const seconds = @divFloor(currentWallTimeNs(shell), std.time.ns_per_s);
        return shell.host.formatLocalTime(shell.scratchAllocator(), @intCast(seconds), format);
    }
    return "";
}

fn currentWallTimeNs(shell: anytype) i128 {
    const host_type = HostType(@TypeOf(shell.host));
    if (comptime @hasDecl(host_type, "wallTimeNs")) return shell.host.wallTimeNs();
    return shell.state.start_time_ns;
}

fn effectiveUserId(shell: anytype) u32 {
    const host_type = HostType(@TypeOf(shell.host));
    if (comptime @hasDecl(host_type, "effectiveUserId")) return @intCast(shell.host.effectiveUserId());
    const text = shellValue(shell, "EUID") orelse shellValue(shell, "UID") orelse return 1;
    return std.fmt.parseInt(u32, text, 10) catch 1;
}

fn workingDirectory(shell: anytype, basename_only: bool) ![]const u8 {
    const allocator = shell.scratchAllocator();
    const pwd = shellValue(shell, "PWD") orelse pwd: {
        const host_type = HostType(@TypeOf(shell.host));
        if (comptime @hasDecl(host_type, "currentDir")) break :pwd try shell.host.currentDir(allocator);
        break :pwd "";
    };
    const home = shellValue(shell, "HOME");
    if (basename_only) {
        if (home) |path| if (std.mem.eql(u8, pwd, path)) return "~";
        if (std.mem.eql(u8, pwd, "/")) return "/";
        return std.fs.path.basename(pwd);
    }

    const display = if (home) |path|
        if (std.mem.eql(u8, pwd, path))
            "~"
        else if (path.len != 0 and std.mem.startsWith(u8, pwd, path) and pwd.len > path.len and pwd[path.len] == '/')
            try std.fmt.allocPrint(allocator, "~{s}", .{pwd[path.len..]})
        else
            pwd
    else
        pwd;
    const trim = std.fmt.parseInt(usize, shellValue(shell, "PROMPT_DIRTRIM") orelse "0", 10) catch 0;
    return trimWorkingDirectory(allocator, display, trim);
}

fn trimWorkingDirectory(allocator: std.mem.Allocator, path: []const u8, retain: usize) ![]const u8 {
    if (retain == 0) return path;
    var component_count: usize = 0;
    var index = path.len;
    while (index > 0) {
        index -= 1;
        if (path[index] != '/') continue;
        component_count += 1;
        if (component_count != retain) continue;
        const prefix = path[0..index];
        if (prefix.len == 0 or std.mem.eql(u8, prefix, "~")) return path;
        const home_prefix = if (std.mem.startsWith(u8, path, "~/")) "~/" else "";
        return std.fmt.allocPrint(allocator, "{s}.../{s}", .{ home_prefix, path[index + 1 ..] });
    }
    return path;
}

fn shellName(arg_zero: []const u8) []const u8 {
    if (arg_zero.len == 0) return "rush";
    return std.fs.path.basename(arg_zero);
}

fn shortVersion(version: []const u8) []const u8 {
    const first = std.mem.findScalar(u8, version, '.') orelse return version;
    const relative_second = std.mem.findScalar(u8, version[first + 1 ..], '.') orelse return version;
    const second = first + 1 + relative_second;
    return version[0..second];
}

fn releaseVersion(version: []const u8) []const u8 {
    const first = std.mem.findScalar(u8, version, '.') orelse return version;
    const relative_second = std.mem.findScalar(u8, version[first + 1 ..], '.') orelse return version;
    const second = first + 1 + relative_second;
    var end = second + 1;
    while (end < version.len and std.ascii.isDigit(version[end])) : (end += 1) {}
    return version[0..end];
}

fn HostType(comptime host_field: type) type {
    return switch (@typeInfo(host_field)) {
        .pointer => |pointer| pointer.child,
        else => host_field,
    };
}

fn shellValue(shell: anytype, name: []const u8) ?[]const u8 {
    if (shell.state.getVariable(name)) |variable| return variable.value;
    for (shell.env) |entry_ptr| {
        const entry = std.mem.span(entry_ptr);
        if (entry.len <= name.len or entry[name.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

test "decode expands Bash prompt escapes" {
    const TestHost = struct {
        const Self = @This();

        // ziglint-ignore: Z023 parameter order follows Host method shape
        fn effectiveUserName(_: Self, allocator: std.mem.Allocator) ![]const u8 {
            return allocator.dupe(u8, "tester");
        }

        // ziglint-ignore: Z023 parameter order follows Host method shape
        fn hostname(_: Self, allocator: std.mem.Allocator) ![]const u8 {
            return allocator.dupe(u8, "host.example");
        }

        // ziglint-ignore: Z023 parameter order follows Host method shape
        fn terminalName(_: Self, allocator: std.mem.Allocator, _: host_mod.Fd) ![]const u8 {
            return allocator.dupe(u8, "/dev/ttys001");
        }

        // ziglint-ignore: Z023 parameter order follows Host method shape
        fn formatLocalTime(_: Self, allocator: std.mem.Allocator, _: i64, format: []const u8) ![]const u8 {
            return std.fmt.allocPrint(allocator, "<{s}>", .{format});
        }

        fn effectiveUserId(_: Self) u32 {
            return 0;
        }

        fn wallTimeNs(_: Self) i128 {
            return 0;
        }
    };
    const TestShell = struct {
        const Self = @This();

        host: TestHost = .{},
        state: state_mod.State,
        env: []const [*:0]const u8 = &.{},
        scratch: std.mem.Allocator,

        fn scratchAllocator(self: *Self) std.mem.Allocator {
            return self.scratch;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var shell: TestShell = .{
        .state = state_mod.State.init(std.testing.allocator, .{}),
        .scratch = arena.allocator(),
    };
    defer shell.state.deinit();
    try shell.state.putVariable(.{ .name = "PWD", .value = "/Users/tester/src/rush" });
    try shell.state.putVariable(.{ .name = "HOME", .value = "/Users/tester" });
    try shell.state.putVariable(.{ .name = "BASH_VERSION", .value = "5.3.0(1)-release" });
    shell.state.prompt_command_number = 4;
    shell.state.prompt_history_number = 9;

    const actual = try decode(&shell,
        \\u=\u h=\h H=\H j=\j l=\l s=\s v=\v V=\V w=\w W=\W n=\# bang=\! root=\$ octal=\101
    , .editor);
    try std.testing.expectEqualStrings(
        "u=tester h=host H=host.example j=0 l=ttys001 s=rush v=5.3 V=5.3.0 " ++
            "w=~/src/rush W=rush n=4 bang=9 root=# octal=A",
        actual,
    );
}

test "decode caches stable host prompt metadata" {
    const Calls = struct {
        username: usize = 0,
        hostname: usize = 0,
        terminal_name: usize = 0,
    };
    const TestHost = struct {
        const Self = @This();

        calls: *Calls,

        // ziglint-ignore: Z023 parameter order follows Host method shape
        fn effectiveUserName(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
            self.calls.username += 1;
            return allocator.dupe(u8, "tester");
        }

        // ziglint-ignore: Z023 parameter order follows Host method shape
        fn hostname(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
            self.calls.hostname += 1;
            return allocator.dupe(u8, "host.example");
        }

        // ziglint-ignore: Z023 parameter order follows Host method shape
        fn terminalName(self: *Self, allocator: std.mem.Allocator, _: host_mod.Fd) ![]const u8 {
            self.calls.terminal_name += 1;
            return allocator.dupe(u8, "/dev/ttys001");
        }
    };
    const TestShell = struct {
        const Self = @This();

        host: TestHost,
        state: state_mod.State,
        env: []const [*:0]const u8 = &.{},
        scratch: std.mem.Allocator,

        fn scratchAllocator(self: *Self) std.mem.Allocator {
            return self.scratch;
        }
    };

    var calls: Calls = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var shell: TestShell = .{
        .host = .{ .calls = &calls },
        .state = state_mod.State.init(std.testing.allocator, .{}),
        .scratch = arena.allocator(),
    };
    defer shell.state.deinit();

    try std.testing.expectEqualStrings("tester host.example ttys001", try decode(&shell, "\\u \\H \\l", .editor));
    try std.testing.expectEqualStrings("tester host.example ttys001", try decode(&shell, "\\u \\H \\l", .editor));
    try std.testing.expectEqual(@as(usize, 1), calls.username);
    try std.testing.expectEqual(@as(usize, 1), calls.hostname);
    try std.testing.expectEqual(@as(usize, 1), calls.terminal_name);
}

test "decode expands Bash prompt time and control escapes" {
    const TestHost = struct {
        const Self = @This();

        // ziglint-ignore: Z023 parameter order follows Host method shape
        fn formatLocalTime(_: Self, allocator: std.mem.Allocator, _: i64, format: []const u8) ![]const u8 {
            return std.fmt.allocPrint(allocator, "<{s}>", .{format});
        }
    };
    const TestShell = struct {
        const Self = @This();

        host: TestHost = .{},
        state: state_mod.State,
        env: []const [*:0]const u8 = &.{},
        scratch: std.mem.Allocator,

        fn scratchAllocator(self: *Self) std.mem.Allocator {
            return self.scratch;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var shell: TestShell = .{
        .state = state_mod.State.init(std.testing.allocator, .{}),
        .scratch = arena.allocator(),
    };
    defer shell.state.deinit();

    const actual = try decode(
        &shell,
        "\\d|\\D{%Y}|\\D{}|\\t|\\T|\\@|\\A|\\a|\\e|\\n|\\r|\\\\|\\[x\\]",
        .editor,
    );
    try std.testing.expectEqualStrings(
        "<%a %b %d>|<%Y>|<%X>|<%H:%M:%S>|<%I:%M:%S>|<%I:%M %p>|<%H:%M>|\x07|\x1b|\n|\r|\\|\x01x\x02",
        actual,
    );
    try std.testing.expectEqualStrings("<%m>", try decode(&shell, "\\D{%m", .editor));
    try std.testing.expectEqualStrings("<%X>", try decode(&shell, "\\D{", .editor));
    try std.testing.expectEqualStrings("\x1b[31mred", try decode(&shell, "\\[\\e[31m\\]red", .parameter));
    try std.testing.expectEqualStrings("XX\x02X", try decode(&shell, "\\400X\\401X\\402X", .parameter));
}

test "working directory trimming keeps the requested trailing components" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings("/a/b", try trimWorkingDirectory(arena.allocator(), "/a/b", 2));
    try std.testing.expectEqualStrings("~/a/b", try trimWorkingDirectory(arena.allocator(), "~/a/b", 2));
    try std.testing.expectEqualStrings(".../b/c", try trimWorkingDirectory(arena.allocator(), "/a/b/c", 2));
    try std.testing.expectEqualStrings("~/.../c/d", try trimWorkingDirectory(arena.allocator(), "~/a/b/c/d", 2));
}
