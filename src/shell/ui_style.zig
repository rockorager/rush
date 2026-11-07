//! ANSI UI style parsing and encoding used by shell diagnostics.
//!
//! Independent of vaxis so the evaluator can compile for wasm. The
//! interactive editor converts its vaxis styles through this module so
//! sequences stay in one place.

const std = @import("std");

pub const UnderlineStyle = enum { none, single, double, curly, dotted, dashed };

pub const Color = union(enum) {
    default,
    index: u8,
    rgb: [3]u8,
};

pub const UiStyle = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    ul: UnderlineStyle = .none,
    ul_color: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    reverse: bool = false,
    strike: bool = false,
};

pub const UiTheme = struct {
    directory: UiStyle = .{ .fg = .{ .index = 4 } },
};

pub fn parseUiStyle(text: []const u8) ?UiStyle {
    var style: UiStyle = .{};
    var iter = std.mem.splitScalar(u8, text, ',');
    while (iter.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, "bold")) {
            style.bold = true;
        } else if (std.mem.eql(u8, part, "dim")) {
            style.dim = true;
        } else if (std.mem.eql(u8, part, "italic")) {
            style.italic = true;
        } else if (std.mem.eql(u8, part, "reverse")) {
            style.reverse = true;
        } else if (std.mem.eql(u8, part, "strike")) {
            style.strike = true;
        } else if (std.mem.startsWith(u8, part, "fg=")) {
            style.fg = parseUiColor(part["fg=".len..]) orelse return null;
        } else if (std.mem.startsWith(u8, part, "bg=")) {
            style.bg = parseUiColor(part["bg=".len..]) orelse return null;
        } else if (std.mem.startsWith(u8, part, "ul_color=")) {
            style.ul_color = parseUiColor(part["ul_color=".len..]) orelse return null;
        } else if (std.mem.startsWith(u8, part, "ul=")) {
            style.ul = parseUiUnderline(part["ul=".len..]) orelse return null;
        } else return null;
    }
    return style;
}

pub fn parseUiColor(name: []const u8) ?Color {
    if (std.mem.eql(u8, name, "default")) return .default;
    if (std.mem.eql(u8, name, "black")) return .{ .index = 0 };
    if (std.mem.eql(u8, name, "red")) return .{ .index = 1 };
    if (std.mem.eql(u8, name, "green")) return .{ .index = 2 };
    if (std.mem.eql(u8, name, "yellow")) return .{ .index = 3 };
    if (std.mem.eql(u8, name, "blue")) return .{ .index = 4 };
    if (std.mem.eql(u8, name, "magenta")) return .{ .index = 5 };
    if (std.mem.eql(u8, name, "cyan")) return .{ .index = 6 };
    if (std.mem.eql(u8, name, "white")) return .{ .index = 7 };
    if (std.mem.eql(u8, name, "bright-black")) return .{ .index = 8 };
    if (std.mem.eql(u8, name, "bright-red")) return .{ .index = 9 };
    if (std.mem.eql(u8, name, "bright-green")) return .{ .index = 10 };
    if (std.mem.eql(u8, name, "bright-yellow")) return .{ .index = 11 };
    if (std.mem.eql(u8, name, "bright-blue")) return .{ .index = 12 };
    if (std.mem.eql(u8, name, "bright-magenta")) return .{ .index = 13 };
    if (std.mem.eql(u8, name, "bright-cyan")) return .{ .index = 14 };
    if (std.mem.eql(u8, name, "bright-white")) return .{ .index = 15 };
    if (std.mem.startsWith(u8, name, "index:")) {
        return .{ .index = std.fmt.parseUnsigned(u8, name["index:".len..], 10) catch return null };
    }
    if (name.len != 0 and std.ascii.isDigit(name[0])) {
        return .{ .index = std.fmt.parseUnsigned(u8, name, 10) catch return null };
    }
    if (name.len == 7 and name[0] == '#') {
        const rgb = std.fmt.parseUnsigned(u24, name[1..], 16) catch return null;
        return .{ .rgb = .{
            @intCast(rgb >> 16),
            @intCast((rgb >> 8) & 0xff),
            @intCast(rgb & 0xff),
        } };
    }
    return null;
}

fn parseUiUnderline(name: []const u8) ?UnderlineStyle {
    if (std.mem.eql(u8, name, "none")) return .none;
    if (std.mem.eql(u8, name, "single")) return .single;
    if (std.mem.eql(u8, name, "double")) return .double;
    if (std.mem.eql(u8, name, "curly")) return .curly;
    if (std.mem.eql(u8, name, "dotted")) return .dotted;
    if (std.mem.eql(u8, name, "dashed")) return .dashed;
    return null;
}

pub fn appendUiStyleStart(allocator: std.mem.Allocator, out: *std.ArrayList(u8), style: UiStyle) !void {
    if (style.bold) try out.appendSlice(allocator, "\x1b[1m");
    if (style.dim) try out.appendSlice(allocator, "\x1b[2m");
    if (style.italic) try out.appendSlice(allocator, "\x1b[3m");
    switch (style.ul) {
        .none => {},
        .single => try out.appendSlice(allocator, "\x1b[4m"),
        .double => try out.appendSlice(allocator, "\x1b[4:2m"),
        .curly => try out.appendSlice(allocator, "\x1b[4:3m"),
        .dotted => try out.appendSlice(allocator, "\x1b[4:4m"),
        .dashed => try out.appendSlice(allocator, "\x1b[4:5m"),
    }
    if (style.reverse) try out.appendSlice(allocator, "\x1b[7m");
    if (style.strike) try out.appendSlice(allocator, "\x1b[9m");
    if (style.fg) |color| try appendAnsiColor(allocator, out, .fg, color);
    if (style.bg) |color| try appendAnsiColor(allocator, out, .bg, color);
    if (style.ul_color) |color| try appendAnsiColor(allocator, out, .ul, color);
}

pub fn appendUiStyleEnd(allocator: std.mem.Allocator, out: *std.ArrayList(u8), style: UiStyle) !void {
    if (style.strike) try out.appendSlice(allocator, "\x1b[29m");
    if (style.reverse) try out.appendSlice(allocator, "\x1b[27m");
    if (style.ul != .none or style.ul_color != null) try out.appendSlice(allocator, "\x1b[24;59m");
    if (style.italic) try out.appendSlice(allocator, "\x1b[23m");
    if (style.bold or style.dim) try out.appendSlice(allocator, "\x1b[22m");
    if (style.bg != null) try out.appendSlice(allocator, "\x1b[49m");
    if (style.fg != null) try out.appendSlice(allocator, "\x1b[39m");
}

fn appendAnsiColor(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    kind: enum { fg, bg, ul },
    color: Color,
) !void {
    switch (color) {
        .default => switch (kind) {
            .fg => try out.appendSlice(allocator, "\x1b[39m"),
            .bg => try out.appendSlice(allocator, "\x1b[49m"),
            .ul => try out.appendSlice(allocator, "\x1b[59m"),
        },
        .index => |index| {
            if (kind != .ul and index < 16) {
                const base: u8 = switch (kind) {
                    .fg => if (index < 8) 30 else 90,
                    .bg => if (index < 8) 40 else 100,
                    .ul => unreachable,
                };
                const sequence = try allocator.print("\x1b[{d}m", .{base + index % 8});
                defer allocator.free(sequence);
                try out.appendSlice(allocator, sequence);
                return;
            }
            const prefix = switch (kind) {
                .fg => "38",
                .bg => "48",
                .ul => "58",
            };
            const sequence = try allocator.print(
                "\x1b[{s}:5:{d}m",
                .{ prefix, index },
            );
            defer allocator.free(sequence);
            try out.appendSlice(allocator, sequence);
        },
        .rgb => |rgb| {
            const prefix = switch (kind) {
                .fg => "38",
                .bg => "48",
                .ul => "58",
            };
            const sequence = try allocator.print(
                "\x1b[{s}:2:{d}:{d}:{d}m",
                .{ prefix, rgb[0], rgb[1], rgb[2] },
            );
            defer allocator.free(sequence);
            try out.appendSlice(allocator, sequence);
        },
    }
}

test "parseUiStyle accepts bold and named foreground colors" {
    const style = parseUiStyle("fg=red") orelse return error.ParseFailed;
    try std.testing.expect(style.fg != null);
    try std.testing.expectEqual(@as(u8, 1), style.fg.?.index);
    try std.testing.expect(!style.bold);
}

test "appendUiStyleStart emits bold red then reset" {
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(std.testing.allocator);
    const style: UiStyle = .{ .fg = .{ .index = 1 }, .bold = true };
    try appendUiStyleStart(std.testing.allocator, &message, style);
    try message.appendSlice(std.testing.allocator, "repos/rush");
    try appendUiStyleEnd(std.testing.allocator, &message, style);
    try std.testing.expectEqualStrings("\x1b[1m\x1b[31mrepos/rush\x1b[22m\x1b[39m", message.items);
}
