//! Drives an interactive Rush through a pseudo-terminal.
//!
//! Each case in tests/terminal/*.zon starts `rush -i` on the slave side of a
//! fresh pty, with a private HOME and an optional user config, then runs its
//! steps against the master side: send keystrokes, deliver signals, and wait
//! for text to appear in the terminal output with escape sequences removed.
//! The harness answers the terminal queries the line editor waits for.

const std = @import("std");
const builtin = @import("builtin");

const Suite = struct {
    name: []const u8,
    cases: []const Case,
};

const Case = struct {
    name: []const u8,
    /// Written to $XDG_CONFIG_HOME/rush/config.rush; sourced after Rush's
    /// built-in defaults.
    config: []const u8 = default_config,
    steps: []const Step,
};

/// Exactly one field is set.
const Step = struct {
    /// Bytes written to the terminal, as if typed.
    send: ?[]const u8 = null,
    /// Waits until this text appears after the previous match.
    expect: ?[]const u8 = null,
    /// Fails if this text appeared after the previous match.
    absent: ?[]const u8 = null,
    /// Signal name delivered to the shell, such as "INT".
    signal: ?[]const u8 = null,
    sleep_ms: ?u32 = null,
};

const default_config =
    \\rush_prompt() { prompt text '$ '; }
    \\
;

const expect_timeout_ms = 10_000;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var rush_path: ?[]const u8 = null;
    var case_filter: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(allocator);
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--rush") and index + 1 < args.len) {
            index += 1;
            rush_path = args[index];
        } else if (std.mem.eql(u8, args[index], "--case") and index + 1 < args.len) {
            index += 1;
            case_filter = args[index];
        } else {
            try files.append(allocator, args[index]);
        }
    }
    const rush = rush_path orelse {
        std.debug.print("usage: rush-terminal-harness --rush PATH [--case TEXT] [FILE.zon...]\n", .{});
        return 2;
    };
    if (files.items.len == 0) try discoverSuites(allocator, init.arena.allocator(), io, &files);

    var passed: usize = 0;
    var failed: usize = 0;
    for (files.items) |path| {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, arena.allocator(), .unlimited, .of(u8), 0);
        const suite = try std.zon.parse.fromSliceAlloc(Suite, arena.allocator(), source, null, .{});
        for (suite.cases) |case| {
            if (case_filter) |filter| if (std.mem.find(u8, case.name, filter) == null) continue;
            if (try runCase(allocator, io, rush, case)) |failure| {
                defer allocator.free(failure);
                failed += 1;
                std.debug.print("FAIL {s} › {s} › {s}\n{s}\n", .{ path, suite.name, case.name, failure });
            } else passed += 1;
        }
    }
    if (failed != 0) {
        std.debug.print("terminal: failed {d}/{d} case(s)\n", .{ failed, failed + passed });
        return 1;
    }
    std.debug.print("terminal: passed {d} case(s)\n", .{passed});
    return 0;
}

fn discoverSuites(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    files: *std.ArrayList([]const u8),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/terminal", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
        try files.append(allocator, try std.fs.path.join(arena, &.{ "tests/terminal", entry.name }));
    }
    std.mem.sort([]const u8, files.items, {}, lessThanPath);
}

fn lessThanPath(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// Returns null when the case passes, otherwise an owned failure report.
fn runCase(allocator: std.mem.Allocator, io: std.Io, rush: []const u8, case: Case) !?[]const u8 {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var random: u64 = undefined;
    io.random(std.mem.asBytes(&random));
    const home = try std.fmt.allocPrint(arena, "/tmp/rush-terminal-{x}", .{random});
    const config_dir = try std.fs.path.join(arena, &.{ home, ".config", "rush" });
    try std.Io.Dir.cwd().createDirPath(io, config_dir);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const config_path = try std.fs.path.join(arena, &.{ config_dir, "config.rush" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = case.config });

    var session = try Session.start(arena, rush, home);
    defer session.stop();

    for (case.steps, 0..) |step, step_index| {
        if (step.send) |bytes| {
            try session.send(bytes);
        } else if (step.expect) |text| {
            if (!try session.waitFor(arena, text, expect_timeout_ms)) {
                return try session.report(allocator, step_index, "timed out waiting for", text);
            }
        } else if (step.absent) |text| {
            try session.pump(arena, 0);
            if (session.unmatchedContains(text)) {
                return try session.report(allocator, step_index, "unexpected", text);
            }
        } else if (step.signal) |name| {
            try session.signal(name);
        } else if (step.sleep_ms) |ms| {
            try session.pump(arena, ms);
        } else unreachable;
    }
    return null;
}

const Session = struct {
    pid: std.c.pid_t,
    master: std.c.fd_t,
    raw: std.ArrayList(u8) = .empty,
    /// Output with escape sequences and carriage returns removed.
    text: std.ArrayList(u8) = .empty,
    /// Bytes of `raw` already scanned for queries and copied into `text`.
    scanned: usize = 0,
    /// Start of the text that `expect` and `absent` look at.
    cursor: usize = 0,

    fn start(arena: std.mem.Allocator, rush: []const u8, home: []const u8) !Session {
        const master = posix_openpt(@bitCast(std.c.O{ .ACCMODE = .RDWR, .NOCTTY = true }));
        if (master < 0) return error.PtyUnavailable;
        errdefer _ = std.c.close(master);
        if (grantpt(master) != 0 or unlockpt(master) != 0) return error.PtyUnavailable;
        const slave_path = try arena.dupeZ(u8, std.mem.span(ptsname(master) orelse return error.PtyUnavailable));

        const rush_z = try arena.dupeZ(u8, rush);
        const argv = [_:null]?[*:0]const u8{ rush_z, "-i" };
        const envp = [_:null]?[*:0]const u8{
            (try std.fmt.allocPrintSentinel(arena, "HOME={s}", .{home}, 0)).ptr,
            (try std.fmt.allocPrintSentinel(arena, "XDG_CONFIG_HOME={s}/.config", .{home}, 0)).ptr,
            (try std.fmt.allocPrintSentinel(arena, "XDG_STATE_HOME={s}/state", .{home}, 0)).ptr,
            (try std.fmt.allocPrintSentinel(arena, "XDG_DATA_HOME={s}/data", .{home}, 0)).ptr,
            "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM=xterm-256color",
            "LANG=C.UTF-8",
        };

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // The new session's first opened terminal becomes its controlling
            // terminal on Linux; BSDs and macOS need TIOCSCTTY.
            _ = std.c.setsid();
            const slave = std.c.open(slave_path, .{ .ACCMODE = .RDWR });
            if (slave < 0) std.c._exit(126);
            _ = ioctl(slave, tiocsctty, @as(c_int, 0));
            // macOS resets a size set on the master before the slave opens.
            const size: std.posix.winsize = .{ .row = 24, .col = 100, .xpixel = 0, .ypixel = 0 };
            _ = ioctl(slave, tiocswinsz, &size);
            for ([_]std.c.fd_t{ 0, 1, 2 }) |fd| _ = std.c.dup2(slave, fd);
            if (slave > 2) _ = std.c.close(slave);
            _ = std.c.close(master);
            // A background launcher may hand down ignored INT and QUIT.
            const default_action: std.posix.Sigaction = .{
                .handler = .{ .handler = std.posix.SIG.DFL },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            for ([_]std.posix.SIG{ .INT, .QUIT, .TSTP, .TTIN, .TTOU, .PIPE }) |sig| {
                std.posix.sigaction(sig, &default_action, null);
            }
            _ = std.c.execve(rush_z, &argv, &envp);
            std.c._exit(127);
        }
        return .{ .pid = pid, .master = master };
    }

    fn stop(self: *Session) void {
        _ = std.c.kill(self.pid, .KILL);
        _ = std.c.waitpid(self.pid, null, 0);
        _ = std.c.close(self.master);
    }

    fn send(self: *Session, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const rc = std.c.write(self.master, bytes[written..].ptr, bytes.len - written);
            if (rc < 0) return error.WriteFailed;
            written += @intCast(rc);
        }
    }

    fn signal(self: *Session, name: []const u8) !void {
        inline for (@typeInfo(std.posix.SIG).@"enum".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                _ = std.c.kill(self.pid, @field(std.posix.SIG, field.name));
                return;
            }
        }
        return error.UnknownSignal;
    }

    /// Reads output for up to `timeout_ms`, answering terminal queries.
    fn pump(self: *Session, arena: std.mem.Allocator, timeout_ms: u32) !void {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            const remaining = deadline -| nowMs();
            var fds = [_]std.posix.pollfd{.{ .fd = self.master, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = try std.posix.poll(&fds, @intCast(@min(remaining, 50)));
            if (ready != 0) {
                var buffer: [4096]u8 = undefined;
                const rc = std.c.read(self.master, &buffer, buffer.len);
                // EIO means the shell closed the terminal.
                if (rc <= 0) return;
                try self.raw.appendSlice(arena, buffer[0..@intCast(rc)]);
                try self.process(arena);
                continue;
            }
            if (remaining == 0) return;
        }
    }

    fn waitFor(self: *Session, arena: std.mem.Allocator, needle: []const u8, timeout_ms: u32) !bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (std.mem.find(u8, self.text.items[self.cursor..], needle)) |offset| {
                self.cursor += offset + needle.len;
                return true;
            }
            const remaining = deadline -| nowMs();
            if (remaining == 0) return false;
            try self.pump(arena, @intCast(@min(remaining, 50)));
        }
    }

    fn unmatchedContains(self: *Session, needle: []const u8) bool {
        return std.mem.find(u8, self.text.items[self.cursor..], needle) != null;
    }

    /// Answers queries and appends visible text from newly read output.
    fn process(self: *Session, arena: std.mem.Allocator) !void {
        const raw = self.raw.items;
        var index = self.scanned;
        while (index < raw.len) {
            const byte = raw[index];
            if (byte != 0x1b) {
                if (byte != '\r') try self.text.append(arena, byte);
                index += 1;
                continue;
            }
            const end = escapeEnd(raw, index) orelse break;
            const sequence = raw[index..end];
            if (std.mem.eql(u8, sequence, "\x1b[6n")) try self.send("\x1b[1;1R");
            if (std.mem.eql(u8, sequence, "\x1b[c")) try self.send("\x1b[?62;22c");
            index = end;
        }
        self.scanned = index;
    }

    fn report(
        self: *Session,
        allocator: std.mem.Allocator,
        step_index: usize,
        what: []const u8,
        text: []const u8,
    ) ![]const u8 {
        const unmatched = self.text.items[self.cursor..];
        const tail = unmatched[unmatched.len -| 1500..];
        return std.fmt.allocPrint(
            allocator,
            "  step {d}: {s} \"{s}\"\n  terminal text after the last match:\n{s}",
            .{ step_index + 1, what, text, tail },
        );
    }
};

/// Returns the end of the escape sequence at `start`, or null if incomplete.
fn escapeEnd(raw: []const u8, start: usize) ?usize {
    std.debug.assert(raw[start] == 0x1b);
    if (start + 1 >= raw.len) return null;
    switch (raw[start + 1]) {
        '[' => {
            var index = start + 2;
            while (index < raw.len) : (index += 1) {
                if (raw[index] >= 0x40 and raw[index] <= 0x7e) return index + 1;
            }
            return null;
        },
        ']', '_', 'P', '^', 'X' => {
            var index = start + 2;
            while (index < raw.len) : (index += 1) {
                if (raw[index] == 0x07) return index + 1;
                if (raw[index] == 0x1b and index + 1 < raw.len and raw[index + 1] == '\\') return index + 2;
            }
            return null;
        },
        else => return start + 2,
    }
}

fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

// std.c.T lacks these on macOS; the BSD values are shared by macOS and FreeBSD.
const tiocswinsz: c_ulong = if (builtin.os.tag == .linux) std.os.linux.T.IOCSWINSZ else 0x80087467;
const tiocsctty: c_ulong = if (builtin.os.tag == .linux) std.os.linux.T.IOCSCTTY else 0x20007461;

/// std.c declares the request as c_int, which sign-extends requests with the
/// high bit set, such as TIOCSWINSZ on macOS; the C prototype takes an
/// unsigned long.
const ioctl = @extern(*const fn (c_int, c_ulong, ...) callconv(.c) c_int, .{ .name = "ioctl" });

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
