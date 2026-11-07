//! Rush's own Program Status Protocol reports for long interactive commands.
//!
//! When `rush_program_status_threshold` holds a whole number of seconds, a foreground
//! command line that runs at least that long leaves a `done` or `error` record
//! under the `rush` id. The child id keeps Rush from replacing the root record
//! that the command itself may have reported. Rush clears its record when the
//! next command line starts, because the user is back at this terminal.

const std = @import("std");

const program_status = @import("../program_status.zig");
const shell = @import("../shell.zig");

pub const record_id = "rush";
pub const threshold_variable = "rush_program_status_threshold";

const app = "rush";
const max_exit_suffix = " (exit 255)";

/// Parses the threshold setting; null disables reports.
pub fn parseThreshold(value: []const u8) ?u32 {
    if (value.len == 0) return null;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(u32, value, 10) catch null;
}

/// Builds the report for a finished command line, borrowing `line`-derived
/// text from `buffer`. Returns null for short commands and for commands the
/// user interrupted or stopped from the keyboard, since the user is present.
pub fn finishedReport(
    buffer: *[program_status.max_message_len]u8,
    line: []const u8,
    status: shell.result.ExitStatus,
    duration_ms: i64,
    threshold_seconds: u32,
) ?program_status.Report {
    std.debug.assert(duration_ms >= 0);
    if (duration_ms < @as(i64, threshold_seconds) * std.time.ms_per_s) return null;
    if (isKeyboardSignal(status)) return null;

    const command = program_status.sanitizeText(buffer[0 .. buffer.len - max_exit_suffix.len], line);
    if (status == 0) {
        return .{ .state = .done, .id = record_id, .app = app, .msg = if (command.len != 0) command else null };
    }
    const suffix = std.fmt.bufPrint(buffer[command.len..], " (exit {d})", .{status}) catch unreachable;
    const msg = std.mem.trimStart(u8, buffer[0 .. command.len + suffix.len], " ");
    return .{ .state = .@"error", .id = record_id, .app = app, .msg = msg };
}

fn isKeyboardSignal(status: shell.result.ExitStatus) bool {
    if (status <= 128) return false;
    const signal = status - 128;
    return signal == shell.builtin.signalNumber("INT") or signal == shell.builtin.signalNumber("TSTP");
}

test "command status threshold accepts whole seconds only" {
    try std.testing.expectEqual(@as(?u32, 0), parseThreshold("0"));
    try std.testing.expectEqual(@as(?u32, 30), parseThreshold("30"));
    try std.testing.expectEqual(@as(?u32, null), parseThreshold(""));
    try std.testing.expectEqual(@as(?u32, null), parseThreshold("1.5"));
    try std.testing.expectEqual(@as(?u32, null), parseThreshold("-1"));
    try std.testing.expectEqual(@as(?u32, null), parseThreshold("10s"));
    try std.testing.expectEqual(@as(?u32, null), parseThreshold("99999999999"));
}

test "command status reports long commands as done or error" {
    var buffer: [program_status.max_message_len]u8 = undefined;
    try std.testing.expectEqual(null, finishedReport(&buffer, "make", 0, 9_000, 10));

    const done = finishedReport(&buffer, "make\n  test", 0, 10_000, 10).?;
    try std.testing.expectEqual(program_status.State.done, done.state);
    try std.testing.expectEqualStrings("rush", done.id.?);
    try std.testing.expectEqualStrings("rush", done.app.?);
    try std.testing.expectEqualStrings("make test", done.msg.?);
    try program_status.validate(done);

    const failed = finishedReport(&buffer, "cargo build", 101, 60_000, 10).?;
    try std.testing.expectEqual(program_status.State.@"error", failed.state);
    try std.testing.expectEqualStrings("cargo build (exit 101)", failed.msg.?);
    try program_status.validate(failed);

    const blank = finishedReport(&buffer, "\t", 1, 0, 0).?;
    try std.testing.expectEqualStrings("(exit 1)", blank.msg.?);
}

test "command status skips commands interrupted or stopped from the keyboard" {
    var buffer: [program_status.max_message_len]u8 = undefined;
    const interrupt = 128 + shell.builtin.signalNumber("INT").?;
    const stop = 128 + shell.builtin.signalNumber("TSTP").?;
    const terminate = 128 + shell.builtin.signalNumber("TERM").?;
    try std.testing.expectEqual(null, finishedReport(&buffer, "sleep 60", interrupt, 60_000, 0));
    try std.testing.expectEqual(null, finishedReport(&buffer, "sleep 60", stop, 60_000, 0));
    try std.testing.expect(finishedReport(&buffer, "sleep 60", terminate, 60_000, 0) != null);
}

test "command status truncates long command lines within the message limit" {
    var buffer: [program_status.max_message_len]u8 = undefined;
    const line: []const u8 = &@as([program_status.max_message_len * 2]u8, @splat('x'));
    const report = finishedReport(&buffer, line, 255, 0, 0).?;
    try std.testing.expect(std.mem.endsWith(u8, report.msg.?, "x (exit 255)"));
    try std.testing.expectEqual(program_status.max_message_len, report.msg.?.len);
    try program_status.validate(report);
}
