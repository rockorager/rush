//! The `program_status` builtin: writes Program Status Protocol (OSC 7501) reports to
//! standard output so scripts can tell the terminal what they are doing.

const std = @import("std");

const host = @import("../host.zig");
const program_status = @import("../program_status.zig");
const shell = @import("../shell.zig");

const result = shell.result;

const usage = "usage: program_status [-a app] [-i id] [-k kind] [-p percent] [-t title] state [message ...]\n";

pub fn eval(sh: anytype, args: []const []const u8) !result.EvalResult {
    std.debug.assert(args.len != 0);
    var report: program_status.Report = .{ .state = .idle };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        const value = if (arg.len > 2) arg[2..] else value: {
            index += 1;
            if (index == args.len) return fail("option requires an argument: {s}\n", sh, .{arg});
            break :value args[index];
        };
        switch (arg[1]) {
            'a' => report.app = value,
            'i' => report.id = value,
            't' => report.title = value,
            'k' => report.kind = std.meta.stringToEnum(program_status.Kind, value) orelse
                return fail("unknown kind: {s} (expected permission, question, or auth)\n", sh, .{value}),
            'p' => report.progress = parseProgress(value) orelse
                return fail("invalid progress: {s} (expected an integer from 0 to 100)\n", sh, .{value}),
            else => return fail("invalid option: -{c}\n" ++ usage, sh, .{arg[1]}),
        }
    }

    const operands = args[index..];
    if (operands.len == 0) return fail("missing state\n" ++ usage, sh, .{});
    report.state = std.meta.stringToEnum(program_status.State, operands[0]) orelse return fail(
        "unknown state: {s} (expected idle, working, done, blocked, error, or clear)\n",
        sh,
        .{operands[0]},
    );
    if (operands.len > 1) {
        const msg = try std.mem.join(sh.scratchAllocator(), " ", operands[1..]);
        if (msg.len != 0) report.msg = msg;
    }

    program_status.validate(report) catch |err| return fail("{s}\n", sh, .{validationMessage(err)});

    var buffer: [program_status.max_sequence_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    // Validated reports always fit within the protocol's sequence limit.
    program_status.write(&writer, report) catch unreachable;
    sh.host.writeAll(.stdout, writer.buffered()) catch {
        diagnose("write failed\n", sh, .{});
        return .{ .status = 1 };
    };
    return .{};
}

fn parseProgress(text: []const u8) ?u8 {
    for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
    const progress = std.fmt.parseInt(u8, text, 10) catch return null;
    if (progress > program_status.max_progress) return null;
    return progress;
}

fn validationMessage(err: program_status.ValidationError) []const u8 {
    return switch (err) {
        error.InvalidId => "invalid id: use 1-8 slash-separated segments of 1-32 characters from " ++
            "A-Z a-z 0-9 _ . + - (128 bytes at most)",
        error.InvalidApp => "invalid app: use 1-32 characters from A-Z a-z 0-9 _ . + -",
        error.InvalidProgress => "invalid progress: expected an integer from 0 to 100",
        error.KindRequiresBlocked => "-k is only valid with the blocked state",
        error.ProgressRequiresActiveState => "-p is only valid with the working and blocked states",
        error.ClearTakesOnlyId => "clear only accepts -i",
        error.InvalidTitle => std.fmt.comptimePrint(
            "invalid title: expected at most {d} bytes of UTF-8 without control characters",
            .{program_status.max_title_len},
        ),
        error.InvalidMessage => std.fmt.comptimePrint(
            "invalid message: expected at most {d} bytes of UTF-8 without control characters",
            .{program_status.max_message_len},
        ),
    };
}

/// Reports a usage error and returns the usage status.
fn fail(comptime format: []const u8, sh: anytype, args: anytype) result.EvalResult {
    diagnose(format, sh, args);
    return .{ .status = 2 };
}

fn diagnose(comptime format: []const u8, sh: anytype, args: anytype) void {
    const message = std.fmt.allocPrint(sh.scratchAllocator(), "program_status: " ++ format, args) catch return;
    // Diagnostics are best effort; the exit status still reports the failure.
    sh.host.writeAll(.stderr, message) catch {};
}

const TestShell = struct {
    arena: std.heap.ArenaAllocator,
    host: TestHost = .{},

    const TestHost = struct {
        stdout: std.ArrayList(u8) = .empty,
        stderr: std.ArrayList(u8) = .empty,

        pub fn writeAll(self: *@This(), fd: host.Fd, bytes: []const u8) !void {
            const target = if (fd == .stderr) &self.stderr else &self.stdout;
            try target.appendSlice(std.testing.allocator, bytes);
        }
    };

    fn init() TestShell {
        return .{ .arena = .init(std.testing.allocator) };
    }

    fn deinit(self: *TestShell) void {
        self.host.stdout.deinit(std.testing.allocator);
        self.host.stderr.deinit(std.testing.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn scratchAllocator(self: *@This()) std.mem.Allocator {
        return self.arena.allocator();
    }
};

test "program_status writes a report built from options, state, and message words" {
    var sh: TestShell = .init();
    defer sh.deinit();

    const evaluated = try eval(&sh, &.{ "program_status", "-a", "rsync", "-p40", "working", "Syncing", "photos" });
    try std.testing.expectEqual(@as(result.ExitStatus, 0), evaluated.status);
    try std.testing.expectEqualStrings(
        "\x1b]7501;state=working:app=rsync:progress=40:msg=U3luY2luZyBwaG90b3M=\x1b\\",
        sh.host.stdout.items,
    );
    try std.testing.expectEqualStrings("", sh.host.stderr.items);
}

test "program_status writes blocked, clear, and option-terminated reports" {
    var sh: TestShell = .init();
    defer sh.deinit();

    _ = try eval(&sh, &.{ "program_status", "-k", "auth", "-i", "deploy/eu", "-t", "EU", "blocked" });
    _ = try eval(&sh, &.{ "program_status", "-i", "deploy", "clear" });
    _ = try eval(&sh, &.{ "program_status", "--", "done", "-p" });
    try std.testing.expectEqualStrings(
        "\x1b]7501;state=blocked:kind=auth:id=deploy/eu:title=RVU=\x1b\\" ++
            "\x1b]7501;state=clear:id=deploy\x1b\\" ++
            "\x1b]7501;state=done:msg=LXA=\x1b\\",
        sh.host.stdout.items,
    );
}

test "program_status rejects invalid reports without writing" {
    const cases = [_]struct { args: []const []const u8, diagnostic: []const u8 }{
        .{ .args = &.{"program_status"}, .diagnostic = "missing state\n" },
        .{ .args = &.{ "program_status", "busy" }, .diagnostic = "unknown state: busy" },
        .{ .args = &.{ "program_status", "-x", "idle" }, .diagnostic = "invalid option: -x\n" },
        .{ .args = &.{ "program_status", "-i" }, .diagnostic = "option requires an argument: -i\n" },
        .{ .args = &.{ "program_status", "-k", "money", "blocked" }, .diagnostic = "unknown kind: money" },
        .{ .args = &.{ "program_status", "-p", "+5", "working" }, .diagnostic = "invalid progress: +5" },
        .{ .args = &.{ "program_status", "-p", "101", "working" }, .diagnostic = "invalid progress: 101" },
        .{ .args = &.{ "program_status", "-p", "5", "done" }, .diagnostic = "-p is only valid" },
        .{ .args = &.{ "program_status", "-k", "auth", "idle" }, .diagnostic = "-k is only valid" },
        .{ .args = &.{ "program_status", "clear", "message" }, .diagnostic = "clear only accepts -i\n" },
        .{ .args = &.{ "program_status", "-i", "a//b", "idle" }, .diagnostic = "invalid id:" },
        .{ .args = &.{ "program_status", "-a", "my app", "idle" }, .diagnostic = "invalid app:" },
        .{ .args = &.{ "program_status", "idle", "a\nb" }, .diagnostic = "invalid message:" },
        .{ .args = &.{ "program_status", "-t", "\xff", "idle" }, .diagnostic = "invalid title:" },
    };
    for (cases) |case| {
        var sh: TestShell = .init();
        defer sh.deinit();
        try std.testing.expectEqual(@as(result.ExitStatus, 2), (try eval(&sh, case.args)).status);
        try std.testing.expectEqualStrings("", sh.host.stdout.items);
        const prefix = "program_status: ";
        try std.testing.expect(std.mem.startsWith(u8, sh.host.stderr.items, prefix));
        try std.testing.expect(std.mem.startsWith(u8, sh.host.stderr.items[prefix.len..], case.diagnostic));
    }
}
