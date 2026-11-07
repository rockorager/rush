//! Program Status Protocol (OSC 7501) report encoding.
//!
//! A report tells the terminal what a program is doing: idle, working, waiting
//! on the user, done, or failed. The terminal keeps one record per id, and each
//! report replaces its record completely, so a report must repeat every key the
//! record should keep. Reports that break the protocol's grammar or limits are
//! discarded whole by terminals; `validate` rejects them before encoding.
//!
//! Specification: https://www.superlogical.com/rex/docs/build/program-status

const std = @import("std");

pub const State = enum { idle, working, done, blocked, @"error", clear };

/// What a `blocked` record waits for.
pub const Kind = enum { permission, question, auth };

/// Maximum decoded UTF-8 bytes of `msg`.
pub const max_message_len = 2048;
/// Maximum decoded UTF-8 bytes of `title`.
pub const max_title_len = 192;
pub const max_app_len = 32;
pub const max_id_len = 128;
pub const max_id_segment_len = 32;
pub const max_id_depth = 8;
pub const max_progress = 100;

/// Longest encoded report; the protocol caps a whole sequence at 4096 bytes.
pub const max_sequence_len = 4096;

pub const Report = struct {
    state: State,
    /// Slash-separated record path; null addresses the root record.
    id: ?[]const u8 = null,
    app: ?[]const u8 = null,
    /// Only valid with `blocked`.
    kind: ?Kind = null,
    /// Percent complete; only valid with `working` and `blocked`.
    progress: ?u8 = null,
    /// UTF-8 text, base64-encoded on the wire.
    title: ?[]const u8 = null,
    /// UTF-8 text, base64-encoded on the wire.
    msg: ?[]const u8 = null,
};

pub const TextError = error{ TooLong, InvalidUtf8, ControlCharacter };

pub const ValidationError = error{
    InvalidId,
    InvalidApp,
    InvalidProgress,
    KindRequiresBlocked,
    ProgressRequiresActiveState,
    ClearTakesOnlyId,
    InvalidTitle,
    InvalidMessage,
};

pub fn validate(report: Report) ValidationError!void {
    if (report.id) |id| if (!isValidId(id)) return error.InvalidId;
    if (report.state == .clear) {
        const extra = report.app != null or report.kind != null or report.progress != null or
            report.title != null or report.msg != null;
        if (extra) return error.ClearTakesOnlyId;
        return;
    }
    if (report.app) |app| if (!isValidApp(app)) return error.InvalidApp;
    if (report.kind != null and report.state != .blocked) return error.KindRequiresBlocked;
    if (report.progress) |progress| {
        if (report.state != .working and report.state != .blocked) return error.ProgressRequiresActiveState;
        if (progress > max_progress) return error.InvalidProgress;
    }
    if (report.title) |title| validateText(title, max_title_len) catch return error.InvalidTitle;
    if (report.msg) |msg| validateText(msg, max_message_len) catch return error.InvalidMessage;
}

/// Writes `report` as one complete OSC 7501 sequence terminated by `ESC \`.
/// Asserts that `report` passes `validate`.
pub fn write(writer: *std.Io.Writer, report: Report) std.Io.Writer.Error!void {
    validate(report) catch unreachable;
    try writer.print("\x1b]7501;state={s}", .{@tagName(report.state)});
    if (report.kind) |kind| try writer.print(":kind={s}", .{@tagName(kind)});
    if (report.id) |id| try writer.print(":id={s}", .{id});
    if (report.app) |app| try writer.print(":app={s}", .{app});
    if (report.progress) |progress| try writer.print(":progress={d}", .{progress});
    if (report.title) |title| try writeText(writer, "title", title);
    if (report.msg) |msg| try writeText(writer, "msg", msg);
    try writer.writeAll("\x1b\\");
}

fn writeText(writer: *std.Io.Writer, key: []const u8, text: []const u8) std.Io.Writer.Error!void {
    try writer.print(":{s}=", .{key});
    try std.base64.standard.Encoder.encodeWriter(writer, text);
}

pub fn isValidId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    var depth: usize = 0;
    var segments = std.mem.splitScalar(u8, id, '/');
    while (segments.next()) |segment| {
        depth += 1;
        if (depth > max_id_depth) return false;
        if (!isValidName(segment, max_id_segment_len)) return false;
    }
    return true;
}

pub fn isValidApp(app: []const u8) bool {
    return isValidName(app, max_app_len);
}

fn isValidName(name: []const u8, max_len: usize) bool {
    if (name.len == 0 or name.len > max_len) return false;
    for (name) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '.', '+', '-' => {},
        else => return false,
    };
    return true;
}

/// Checks free text (`title` or `msg`) before base64 encoding: at most
/// `max_len` bytes of valid UTF-8 without C0, DEL, or C1 control characters.
pub fn validateText(text: []const u8, max_len: usize) TextError!void {
    if (text.len > max_len) return error.TooLong;
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (isControl(codepoint)) return error.ControlCharacter;
    }
}

fn isControl(codepoint: u21) bool {
    return codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f);
}

/// Copies arbitrary bytes into `buffer` as report text: runs of whitespace and
/// control characters collapse to one space, leading and trailing ones are
/// dropped, invalid UTF-8 becomes U+FFFD, and the result is cut at a code point
/// boundary when it does not fit. The result always passes
/// `validateText(result, buffer.len)`.
pub fn sanitizeText(buffer: []u8, bytes: []const u8) []const u8 {
    var len: usize = 0;
    var pending_space = false;
    var index: usize = 0;
    while (index < bytes.len) {
        const decoded = decodeCodepoint(bytes[index..]);
        const piece: []const u8 = if (decoded) |value| bytes[index..][0..value.len] else "\u{FFFD}";
        index += if (decoded) |value| value.len else 1;

        if (decoded) |value| if (value.codepoint == ' ' or isControl(value.codepoint)) {
            pending_space = len != 0;
            continue;
        };
        const needed = piece.len + @intFromBool(pending_space);
        if (len + needed > buffer.len) break;
        if (pending_space) {
            buffer[len] = ' ';
            len += 1;
            pending_space = false;
        }
        @memcpy(buffer[len..][0..piece.len], piece);
        len += piece.len;
    }
    return buffer[0..len];
}

const Decoded = struct { codepoint: u21, len: u3 };

fn decodeCodepoint(bytes: []const u8) ?Decoded {
    std.debug.assert(bytes.len != 0);
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (len > bytes.len) return null;
    const codepoint: u21 = switch (len) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*) catch return null,
        3 => std.unicode.utf8Decode3(bytes[0..3].*) catch return null,
        4 => std.unicode.utf8Decode4(bytes[0..4].*) catch return null,
        else => unreachable,
    };
    return .{ .codepoint = codepoint, .len = len };
}

fn expectReport(expected: []const u8, report: Report) !void {
    var buffer: [max_sequence_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(&writer, report);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "program status writes state, keys, and base64 text" {
    try expectReport("\x1b]7501;state=idle\x1b\\", .{ .state = .idle });
    try expectReport(
        "\x1b]7501;state=blocked:kind=permission:app=terraform:" ++
            "msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/\x1b\\",
        .{
            .state = .blocked,
            .kind = .permission,
            .app = "terraform",
            .msg = "Apply 3 to add, 1 to change, 0 to destroy?",
        },
    );
    try expectReport(
        "\x1b]7501;state=working:id=us-east:progress=40:title=VVMgRWFzdA==:msg=UHVzaGluZyBpbWFnZQ==\x1b\\",
        .{ .state = .working, .id = "us-east", .progress = 40, .title = "US East", .msg = "Pushing image" },
    );
    try expectReport("\x1b]7501;state=error\x1b\\", .{ .state = .@"error" });
    try expectReport("\x1b]7501;state=clear:id=build/test\x1b\\", .{ .state = .clear, .id = "build/test" });
}

test "program status validation enforces the protocol grammar and limits" {
    try validate(.{ .state = .blocked, .kind = .auth, .progress = 100 });
    try std.testing.expectError(error.KindRequiresBlocked, validate(.{ .state = .working, .kind = .question }));
    try std.testing.expectError(error.ProgressRequiresActiveState, validate(.{ .state = .done, .progress = 1 }));
    try std.testing.expectError(error.InvalidProgress, validate(.{ .state = .working, .progress = 101 }));
    try std.testing.expectError(error.ClearTakesOnlyId, validate(.{ .state = .clear, .msg = "x" }));
    try std.testing.expectError(error.InvalidApp, validate(.{ .state = .idle, .app = "my app" }));
    try std.testing.expectError(error.InvalidMessage, validate(.{ .state = .idle, .msg = "line\nbreak" }));
    try std.testing.expectError(error.InvalidTitle, validate(.{ .state = .idle, .title = "\xc2\x85" }));

    try std.testing.expect(isValidId("a/b-1/c.d+e_f"));
    try std.testing.expect(!isValidId(""));
    try std.testing.expect(!isValidId("a//b"));
    try std.testing.expect(!isValidId("a/"));
    try std.testing.expect(!isValidId("a:b"));
    try std.testing.expect(!isValidId(&@as([33]u8, @splat('a'))));
    try std.testing.expect(isValidId("a/a/a/a/a/a/a/a"));
    try std.testing.expect(!isValidId("a/a/a/a/a/a/a/a/a"));

    try validateText(comptime text: {
        const chars: [max_title_len / 2][2]u8 = @splat("é".*);
        break :text @ptrCast(&chars);
    }, max_title_len);
    try std.testing.expectError(error.TooLong, validateText(&@as([max_title_len + 1]u8, @splat('x')), max_title_len));
    try std.testing.expectError(error.InvalidUtf8, validateText("\xff", max_title_len));
    try std.testing.expectError(error.ControlCharacter, validateText("\x7f", max_title_len));
}

test "program status sanitizes arbitrary text into valid report text" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("for x; do echo", sanitizeText(&buffer, "  for x;\n\tdo  echo\x1b  "));
    try std.testing.expectEqualStrings("a \u{FFFD} b", sanitizeText(&buffer, "a \xff b"));
    try std.testing.expectEqualStrings("a\u{FFFD}\u{FFFD}", sanitizeText(&buffer, "a\xe2\x82"));
    try std.testing.expectEqualStrings("a b", sanitizeText(&buffer, "a\xc2\x85b"));

    var small: [5]u8 = undefined;
    const cut = sanitizeText(&small, "abcé");
    try std.testing.expectEqualStrings("abcé", cut);
    const cut_inside = sanitizeText(&small, "abcdé");
    try std.testing.expectEqualStrings("abcd", cut_inside);
    try validateText(cut_inside, small.len);
}
