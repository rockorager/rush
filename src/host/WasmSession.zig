//! Persistent shell session for the wasm embed ABI.
//!
//! Each `evalScript` is one REPL command. EXIT traps run on `exit` / fatal
//! flow, and once from `finish` if they have not already run.

const WasmSession = @This();

const std = @import("std");

const shell_mod = @import("../shell.zig");
const WasmHost = @import("WasmHost.zig");

const RushShell = shell_mod.Shell(WasmHost);
const shell_error_message = "rush: shell error\n";

shell: RushShell,
finished: bool = false,
exit_status: u8 = 0,

pub fn init(allocator: std.mem.Allocator) !WasmSession {
    const wasm_host = try WasmHost.init(allocator);
    return .{
        .shell = RushShell.init(allocator, wasm_host, .{
            .arg_zero = "rush",
            .initial_pwd = "/",
        }),
    };
}

pub fn deinit(self: *WasmSession) void {
    self.shell.host.deinit();
    self.shell.deinit();
    self.* = undefined;
}

pub fn evalScript(self: *WasmSession, text: []const u8) u8 {
    self.shell.host.clearOutput();
    if (self.finished) return self.exit_status;

    self.shell.resetForTopLevelCommand();
    const src: shell_mod.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "wasm",
        .text = text,
    };
    const evaluated = self.shell.evalSource(src) catch |err| return self.reportEvalError(err);
    return switch (evaluated.flow) {
        .exit, .fatal => self.runExitOnce(evaluated.status),
        else => evaluated.status,
    };
}

pub fn finish(self: *WasmSession) u8 {
    return self.runExitOnce(self.shell.state.last_status);
}

fn runExitOnce(self: *WasmSession, status: u8) u8 {
    if (self.finished) return self.exit_status;
    self.finished = true;
    const final_status = shell_mod.eval.runExitTrap(&self.shell, status) catch {
        self.exit_status = 2;
        return self.reportEvalError(error.Unexpected);
    };
    self.exit_status = final_status;
    return final_status;
}

fn reportEvalError(self: *WasmSession, err: anyerror) u8 {
    if (!shell_mod.parser.isParseError(err)) {
        // Diagnostic write is best-effort; the status is already 2.
        self.shell.host.writeAll(.stderr, shell_error_message) catch {};
    }
    return 2;
}

test "persistent session runs EXIT once on teardown" {
    var session = try WasmSession.init(std.testing.allocator);
    defer session.deinit();

    try std.testing.expectEqual(@as(u8, 0), session.evalScript("trap 'echo bye' EXIT"));
    try std.testing.expectEqualStrings("", session.shell.host.stdoutSlice());

    try std.testing.expectEqual(@as(u8, 0), session.evalScript("echo hi"));
    try std.testing.expectEqualStrings("hi\n", session.shell.host.stdoutSlice());

    try std.testing.expectEqual(@as(u8, 0), session.finish());
    try std.testing.expectEqualStrings("hi\nbye\n", session.shell.host.stdoutSlice());
    try std.testing.expectEqual(@as(u8, 0), session.finish());
    try std.testing.expectEqualStrings("hi\nbye\n", session.shell.host.stdoutSlice());
}

test "persistent session runs EXIT on exit builtin and ignores later eval" {
    var session = try WasmSession.init(std.testing.allocator);
    defer session.deinit();

    try std.testing.expectEqual(@as(u8, 0), session.evalScript("trap 'echo bye' EXIT"));
    try std.testing.expectEqual(@as(u8, 7), session.evalScript("exit 7"));
    try std.testing.expectEqualStrings("bye\n", session.shell.host.stdoutSlice());
    try std.testing.expectEqual(@as(u8, 7), session.evalScript("echo still"));
    try std.testing.expectEqualStrings("", session.shell.host.stdoutSlice());
    try std.testing.expectEqual(@as(u8, 7), session.finish());
}

test "persistent session reports unavailable pipelines" {
    var session = try WasmSession.init(std.testing.allocator);
    defer session.deinit();

    try std.testing.expectEqual(@as(u8, 2), session.evalScript("echo a | echo b"));
    try std.testing.expectEqualStrings("rush: shell error\n", session.shell.host.stderrSlice());
}

test "persistent session routes standard descriptor redirections" {
    var session = try WasmSession.init(std.testing.allocator);
    defer session.deinit();

    try std.testing.expectEqual(@as(u8, 0), session.evalScript("echo error >&2"));
    try std.testing.expectEqualStrings("", session.shell.host.stdoutSlice());
    try std.testing.expectEqualStrings("error\n", session.shell.host.stderrSlice());
}

test "persistent session honors temporary and persistent descriptor closure" {
    var session = try WasmSession.init(std.testing.allocator);
    defer session.deinit();

    try std.testing.expectEqual(@as(u8, 0), session.evalScript("echo hidden >&-; echo visible"));
    try std.testing.expectEqualStrings("visible\n", session.shell.host.stdoutSlice());

    try std.testing.expectEqual(@as(u8, 0), session.evalScript("exec 1>&-"));
    try std.testing.expect(session.evalScript("echo hidden") != 0);
    try std.testing.expectEqualStrings("", session.shell.host.stdoutSlice());
}

test "persistent session retains an EXIT trap failure status" {
    var session = try WasmSession.init(std.testing.allocator);
    defer session.deinit();

    try std.testing.expectEqual(@as(u8, 2), session.evalScript("trap 'echo a | echo b' EXIT; exit 7"));
    try std.testing.expectEqualStrings("rush: shell error\n", session.shell.host.stderrSlice());
    try std.testing.expectEqual(@as(u8, 2), session.evalScript("echo still"));
    try std.testing.expectEqualStrings("", session.shell.host.stderrSlice());
}
