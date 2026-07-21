//! Menu state, layout, and line rendering for editor UI popups.

const std = @import("std");
const vaxis = @import("vaxis");

const completion = @import("completion.zig");
const prompt_markers = @import("../prompt_markers.zig");

const default_max_candidate_rows = 16;
const default_max_label_width = 32;

pub const UnderlineStyle = enum { none, single, double, curly, dotted, dashed };

pub const UiStyle = struct {
    fg: ?vaxis.Color = null,
    bg: ?vaxis.Color = null,
    ul: UnderlineStyle = .none,
    ul_color: ?vaxis.Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    reverse: bool = false,
    strike: bool = false,
};

pub const UiTheme = struct {
    selection: UiStyle = .{ .fg = .{ .index = 6 }, .bold = true },
    command: UiStyle = .{},
    plain: UiStyle = .{},
    directory: UiStyle = .{ .fg = .{ .index = 4 } },
    option: UiStyle = .{ .fg = .{ .index = 6 } },
    variable: UiStyle = .{ .fg = .{ .index = 5 } },
    function: UiStyle = .{ .fg = .{ .index = 5 } },
    file: UiStyle = .{ .fg = .{ .index = 7 } },
    muted: UiStyle = .{ .fg = .{ .index = 8 } },
    flash: UiStyle = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } },
    match: UiStyle = .{ .fg = .{ .index = 3 } },
    err: UiStyle = .{ .ul = .curly, .ul_color = .{ .index = 1 } },
    comment: UiStyle = .{ .fg = .{ .index = 8 } },
    quote: UiStyle = .{ .fg = .{ .index = 2 } },
    pending: UiStyle = .{ .fg = .{ .index = 6 } },
    reserved: UiStyle = .{ .fg = .{ .index = 5 } },
    operator: UiStyle = .{ .fg = .{ .index = 8 } },
};

pub const Presentation = struct {
    row_prefix: []const u8 = "  ",
    selected_row_suffix: []const u8 = "  ",
    description_separator: []const u8 = " ",
    ellipsis: []const u8 = "…",
    max_candidate_rows: usize = default_max_candidate_rows,
    max_label_width: usize = default_max_label_width,
    long_option_prefix: []const u8 = "--",
    short_option_prefix: []const u8 = "-",
    option_separator: []const u8 = ",",
    scroll_summary: ScrollSummary = .{},
};

pub const ScrollSummary = struct {
    visible: bool = true,
    prefix: []const u8 = "showing ",
    range_separator: []const u8 = "-",
    count_separator: []const u8 = " of ",
};

pub const State = struct {
    candidates: []completion.Candidate = &.{},
    selected: usize = no_selection,
    window_start: usize = 0,

    pub const no_selection = std.math.maxInt(usize);

    // ziglint-ignore: Z030 reset to a reusable empty state; clear()/replace() read fields after deinit
    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.candidates.len != 0) completion.freeCandidates(allocator, self.candidates);
        self.* = .{};
    }

    pub fn replace(
        self: *State,
        allocator: std.mem.Allocator,
        candidates: []const completion.Candidate,
    ) !void {
        self.deinit(allocator);
        self.candidates = try completion.cloneCandidates(allocator, candidates);
        self.selected = no_selection;
        self.window_start = 0;
    }

    pub fn clear(self: *State, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
    }

    pub fn isOpen(self: State) bool {
        return self.candidates.len != 0;
    }

    pub fn selectPrevious(self: *State) void {
        if (self.candidates.len == 0) return;
        self.selected = if (self.selected == no_selection or self.selected == 0) 0 else self.selected - 1;
    }

    pub fn selectNext(self: *State) void {
        if (self.candidates.len == 0) return;
        self.selected = if (self.selected == no_selection) 0 else @min(self.selected + 1, self.candidates.len - 1);
    }

    pub fn selectIndex(self: *State, index: usize) void {
        if (self.candidates.len == 0) return;
        self.selected = @min(index, self.candidates.len - 1);
    }

    pub fn selectedCandidate(self: State) ?completion.Candidate {
        if (self.candidates.len == 0 or self.selected == no_selection) return null;
        return self.candidates[self.selected];
    }

    pub fn visibleWindowStart(self: *State, max_rows: usize) usize {
        if (self.candidates.len == 0) return 0;
        if (self.selected == no_selection) {
            self.window_start = 0;
            return 0;
        }
        const visible_rows = @max(max_rows, 1);
        if (self.candidates.len <= visible_rows) {
            self.window_start = 0;
            return 0;
        }
        const last_start = self.candidates.len - visible_rows;
        self.window_start = @min(self.window_start, last_start);
        if (self.selected < self.window_start) {
            self.window_start = self.selected;
        } else if (self.selected >= self.window_start + visible_rows) {
            self.window_start = self.selected + 1 - visible_rows;
        }
        return self.window_start;
    }
};

pub const RenderOptions = struct {
    candidates: []const completion.Candidate,
    selected: usize,
    window_start: usize,
    width: u16,
    height: u16,
    label_width_override: ?usize,
    theme: UiTheme,
    presentation: Presentation = .{},
};

pub fn candidateRows(height: u16, presentation: Presentation) usize {
    return @min(@max(@as(usize, @intCast(height)) -| 2, 1), presentation.max_candidate_rows);
}

pub fn appendLines(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    options: RenderOptions,
) !void {
    const candidates = options.candidates;
    if (candidates.len == 0) return;
    const max_rows = candidateRows(options.height, options.presentation);
    const window = visibleWindow(candidates.len, options.selected, options.window_start, max_rows);
    const raw_label_width = options.label_width_override orelse try labelWidth(
        allocator,
        candidates,
        options.width,
        options.presentation,
    );
    const label_width = @min(raw_label_width, terminalLabelWidth(options.width, options.presentation));
    const fixed_width = visibleWidth(options.presentation.row_prefix, .unicode) +
        label_width +
        visibleWidth(options.presentation.description_separator, .unicode) +
        visibleWidth(options.presentation.selected_row_suffix, .unicode);
    const description_width = @as(usize, @intCast(options.width)) -| fixed_width;
    for (candidates[window.start..window.end], window.start..) |candidate, index| {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        const label = try candidateLabel(allocator, candidate, options.presentation);
        defer if (label.owned) |owned| allocator.free(owned);
        if (index == options.selected) {
            try appendUiStyleStart(allocator, &line, options.theme.selection);
            try line.appendSlice(allocator, options.presentation.row_prefix);
            const kind_style = kindStyle(options.theme, candidate.kind);
            try appendUiStyleStart(allocator, &line, kind_style);
            try appendPaddedCell(allocator, &line, label.text, label_width, options.presentation);
            try appendUiStyleEnd(allocator, &line, kind_style);
            try appendUiStyleStart(allocator, &line, options.theme.selection);
            if (candidate.description) |description| {
                if (description.len != 0 and description_width != 0) {
                    try line.appendSlice(allocator, options.presentation.description_separator);
                    try appendUiStyleStart(allocator, &line, options.theme.muted);
                    try appendTruncated(allocator, &line, description, description_width, options.presentation);
                    try appendUiStyleEnd(allocator, &line, options.theme.muted);
                    try appendUiStyleStart(allocator, &line, options.theme.selection);
                }
            }
            try line.appendSlice(allocator, options.presentation.selected_row_suffix);
            try appendUiStyleEnd(allocator, &line, options.theme.selection);
        } else {
            try line.appendSlice(allocator, options.presentation.row_prefix);
            const kind_style = kindStyle(options.theme, candidate.kind);
            try appendUiStyleStart(allocator, &line, kind_style);
            try appendPaddedCell(allocator, &line, label.text, label_width, options.presentation);
            try appendUiStyleEnd(allocator, &line, kind_style);
            if (candidate.description) |description| {
                if (description.len != 0 and description_width != 0) {
                    try line.appendSlice(allocator, options.presentation.description_separator);
                    try appendUiStyleStart(allocator, &line, options.theme.muted);
                    try appendTruncated(allocator, &line, description, description_width, options.presentation);
                    try appendUiStyleEnd(allocator, &line, options.theme.muted);
                }
            }
        }
        try lines.append(allocator, try line.toOwnedSlice(allocator));
    }
    if (options.presentation.scroll_summary.visible and (window.start != 0 or window.end != candidates.len)) {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        try line.appendSlice(allocator, options.presentation.row_prefix);
        try appendUiStyleStart(allocator, &line, options.theme.muted);
        const text = try scrollSummaryText(allocator, window, candidates.len, options.presentation.scroll_summary);
        defer allocator.free(text);
        try line.appendSlice(allocator, text);
        try appendUiStyleEnd(allocator, &line, options.theme.muted);
        try lines.append(allocator, try line.toOwnedSlice(allocator));
    }
}

fn scrollSummaryText(
    allocator: std.mem.Allocator,
    window: Window,
    count: usize,
    summary: ScrollSummary,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}{d}{s}{d}{s}{d}",
        .{ summary.prefix, window.start + 1, summary.range_separator, window.end, summary.count_separator, count },
    );
}

fn labelWidth(
    allocator: std.mem.Allocator,
    candidates: []const completion.Candidate,
    width: u16,
    presentation: Presentation,
) !usize {
    const max_width = @min(presentation.max_label_width, terminalLabelWidth(width, presentation));
    var widest: usize = 0;
    for (candidates) |candidate| {
        const label = try candidateLabel(allocator, candidate, presentation);
        defer if (label.owned) |owned| allocator.free(owned);
        widest = @max(widest, visibleWidth(label.text, .unicode));
    }
    return @min(widest, max_width);
}

fn terminalLabelWidth(width: u16, presentation: Presentation) usize {
    return @as(usize, @intCast(width)) -|
        (visibleWidth(presentation.row_prefix, .unicode) + visibleWidth(presentation.selected_row_suffix, .unicode));
}

const CandidateLabel = struct {
    text: []const u8,
    owned: ?[]const u8 = null,
};

fn candidateLabel(
    allocator: std.mem.Allocator,
    candidate: completion.Candidate,
    presentation: Presentation,
) !CandidateLabel {
    if (candidate.display) |display| return .{ .text = display };
    if (candidate.kind != .option) return .{ .text = candidate.value };
    const option = candidate.option orelse return .{ .text = candidate.value };
    if (option.long) |long| {
        if (option.short) |short| {
            const owned = try std.fmt.allocPrint(
                allocator,
                "{s}{s}{s}{s}{s}",
                .{
                    presentation.long_option_prefix,
                    long,
                    presentation.option_separator,
                    presentation.short_option_prefix,
                    short,
                },
            );
            return .{ .text = owned, .owned = owned };
        }
    }
    return .{ .text = candidate.value };
}

fn kindStyle(theme: UiTheme, kind: completion.Kind) UiStyle {
    return switch (kind) {
        .command, .builtin, .subcommand => theme.command,
        .plain => theme.plain,
        .function => theme.function,
        .file => theme.file,
        .directory => theme.directory,
        .variable => theme.variable,
        .option => theme.option,
    };
}

pub const Window = struct {
    start: usize,
    end: usize,
};

pub fn visibleWindow(count: usize, selected: usize, window_start: usize, max_rows: usize) Window {
    if (count <= max_rows) return .{ .start = 0, .end = count };
    if (selected == State.no_selection) {
        const start = @min(window_start, count - max_rows);
        return .{ .start = start, .end = @min(start + max_rows, count) };
    }
    const selected_row = @min(selected, count - 1);
    var start = @min(window_start, count - max_rows);
    if (selected_row < start) {
        start = selected_row;
    } else if (selected_row >= start + max_rows) {
        start = selected_row + 1 - max_rows;
    }
    if (start + max_rows > count) start = count - max_rows;
    return .{ .start = start, .end = start + max_rows };
}

fn appendPaddedCell(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    text: []const u8,
    width: usize,
    presentation: Presentation,
) !void {
    const before = output.items.len;
    try appendTruncated(allocator, output, text, width, presentation);
    const written = visibleWidth(output.items[before..], .unicode);
    if (written < width) try output.appendNTimes(allocator, ' ', width - written);
}

fn appendTruncated(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    text: []const u8,
    width: usize,
    presentation: Presentation,
) !void {
    if (width == 0) return;
    if (visibleWidth(text, .unicode) <= width) {
        try output.appendSlice(allocator, text);
        return;
    }
    if (width == 1) {
        try output.appendSlice(allocator, presentation.ellipsis);
        return;
    }
    var written: usize = 0;
    var i: usize = 0;
    while (i < text.len and written < width - 1) {
        if (escapeSequenceEnd(text, i)) |end| {
            try output.appendSlice(allocator, text[i..end]);
            i = end;
            continue;
        }
        try output.append(allocator, text[i]);
        i += 1;
        written += 1;
    }
    try output.appendSlice(allocator, presentation.ellipsis);
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
    color: vaxis.Color,
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
                const sequence = try std.fmt.allocPrint(allocator, "\x1b[{d}m", .{base + index % 8});
                defer allocator.free(sequence);
                try out.appendSlice(allocator, sequence);
                return;
            }
            const prefix = switch (kind) {
                .fg => "38",
                .bg => "48",
                .ul => "58",
            };
            const sequence = try std.fmt.allocPrint(
                allocator,
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
            const sequence = try std.fmt.allocPrint(
                allocator,
                "\x1b[{s}:2:{d}:{d}:{d}m",
                .{ prefix, rgb[0], rgb[1], rgb[2] },
            );
            defer allocator.free(sequence);
            try out.appendSlice(allocator, sequence);
        },
    }
}

pub fn visibleWidth(bytes: []const u8, method: vaxis.gwidth.Method) u16 {
    var width: u16 = 0;
    var plain_start: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (prompt_markers.isMarker(bytes[i])) {
            width += vaxis.gwidth.gwidth(bytes[plain_start..i], method);
            i += 1;
            plain_start = i;
            continue;
        }
        if (bytes[i] != 0x1b) {
            i += 1;
            continue;
        }
        width += vaxis.gwidth.gwidth(bytes[plain_start..i], method);
        if (i + 1 >= bytes.len) return width;
        if (bytes[i + 1] == '[') {
            i += 2;
            while (i < bytes.len and !(bytes[i] >= 0x40 and bytes[i] <= 0x7e)) i += 1;
            if (i < bytes.len) i += 1;
        } else if (bytes[i + 1] == ']') {
            i += 2;
            while (i < bytes.len) : (i += 1) {
                if (bytes[i] == 0x07) {
                    i += 1;
                    break;
                }
                if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') {
                    i += 2;
                    break;
                }
            }
        } else {
            i += 2;
        }
        plain_start = i;
    }
    width += vaxis.gwidth.gwidth(bytes[plain_start..], method);
    return width;
}

test "visible width ignores Readline non-printing markers" {
    try std.testing.expectEqual(@as(u16, 3), visibleWidth("\x01\x1b[31m\x02red\x01\x1b[0m\x02", .unicode));
}

fn escapeSequenceEnd(bytes: []const u8, index: usize) ?usize {
    if (index >= bytes.len or bytes[index] != 0x1b) return null;
    if (index + 1 >= bytes.len) return bytes.len;
    if (bytes[index + 1] == '[') {
        var i = index + 2;
        while (i < bytes.len and !(bytes[i] >= 0x40 and bytes[i] <= 0x7e)) i += 1;
        return if (i < bytes.len) i + 1 else bytes.len;
    }
    if (bytes[index + 1] == ']') {
        var i = index + 2;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == 0x07) return i + 1;
            if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') return i + 2;
        }
        return bytes.len;
    }
    return index + 2;
}

test "menu state selection clamps and reports candidate" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "two", .kind = .plain, .replace_start = 0, .replace_end = 0 },
    };

    try state.replace(std.testing.allocator, &candidates);
    try std.testing.expect(state.selectedCandidate() == null);
    state.selectNext();
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    try std.testing.expectEqualStrings("one", state.selectedCandidate().?.value);
    state.selectNext();
    state.selectNext();
    try std.testing.expectEqual(@as(usize, 1), state.selected);
    state.selectPrevious();
    try std.testing.expectEqual(@as(usize, 0), state.selected);
}

test "menu visible window follows selection" {
    const first: Window = .{ .start = 0, .end = 3 };
    const scrolled: Window = .{ .start = 1, .end = 4 };
    const last: Window = .{ .start = 2, .end = 5 };

    try std.testing.expectEqual(first, visibleWindow(5, 0, 0, 3));
    try std.testing.expectEqual(scrolled, visibleWindow(5, 3, 0, 3));
    try std.testing.expectEqual(last, visibleWindow(5, 4, 2, 3));
    try std.testing.expectEqual(scrolled, visibleWindow(5, State.no_selection, 1, 3));
}

test "menu append lines renders selected row and scroll summary" {
    const candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "two", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "three", .kind = .plain, .replace_start = 0, .replace_end = 0 },
    };
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| std.testing.allocator.free(line);
        lines.deinit(std.testing.allocator);
    }

    try appendLines(std.testing.allocator, &lines, .{
        .candidates = &candidates,
        .selected = 1,
        .window_start = 0,
        .width = 20,
        .height = 3,
        .label_width_override = null,
        .theme = .{},
    });

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "\x1b[1m") != null);
    try std.testing.expectEqualStrings("  \x1b[90mshowing 2-2 of 3\x1b[39m", lines.items[1]);
}

test "basic colors use simple SGR and extended colors use subparameters" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try appendAnsiColor(std.testing.allocator, &output, .fg, .{ .index = 1 });
    try appendAnsiColor(std.testing.allocator, &output, .bg, .{ .index = 2 });
    try appendAnsiColor(std.testing.allocator, &output, .fg, .{ .index = 9 });
    try appendAnsiColor(std.testing.allocator, &output, .bg, .{ .index = 10 });
    try appendAnsiColor(std.testing.allocator, &output, .fg, .{ .index = 16 });
    try appendAnsiColor(std.testing.allocator, &output, .bg, .{ .index = 17 });
    try appendAnsiColor(std.testing.allocator, &output, .ul, .{ .index = 3 });
    try appendAnsiColor(std.testing.allocator, &output, .fg, .{ .rgb = .{ 1, 2, 3 } });
    try appendAnsiColor(std.testing.allocator, &output, .bg, .{ .rgb = .{ 4, 5, 6 } });
    try appendAnsiColor(std.testing.allocator, &output, .ul, .{ .rgb = .{ 7, 8, 9 } });

    try std.testing.expectEqualStrings(
        "\x1b[31m\x1b[42m\x1b[91m\x1b[102m" ++
            "\x1b[38:5:16m\x1b[48:5:17m\x1b[58:5:3m" ++
            "\x1b[38:2:1:2:3m\x1b[48:2:4:5:6m\x1b[58:2:7:8:9m",
        output.items,
    );
}

test "menu presentation customizes spacing summary and option labels" {
    const candidates = [_]completion.Candidate{
        .{
            .value = "--verbose",
            .kind = .option,
            .option = .{ .long = "verbose", .short = "v" },
            .description = "turn on very verbose diagnostics",
            .replace_start = 0,
            .replace_end = 0,
        },
        .{ .value = "second", .kind = .plain, .replace_start = 0, .replace_end = 0 },
    };
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| std.testing.allocator.free(line);
        lines.deinit(std.testing.allocator);
    }

    try appendLines(std.testing.allocator, &lines, .{
        .candidates = &candidates,
        .selected = 0,
        .window_start = 0,
        .width = 18,
        .height = 3,
        .label_width_override = 8,
        .theme = .{},
        .presentation = .{
            .row_prefix = "> ",
            .selected_row_suffix = " <",
            .description_separator = " :: ",
            .ellipsis = "~",
            .long_option_prefix = "+",
            .short_option_prefix = "/",
            .option_separator = "|",
            .scroll_summary = .{
                .prefix = "rows ",
                .range_separator = "..",
                .count_separator = "/",
            },
        },
    });

    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "> ") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "+verbos~") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], " :: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], " <") != null);
    try std.testing.expectEqualStrings("> \x1b[90mrows 1..1/2\x1b[39m", lines.items[1]);
}

test "menu presentation can hide scroll summary and cap rows" {
    const candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "two", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "three", .kind = .plain, .replace_start = 0, .replace_end = 0 },
    };
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| std.testing.allocator.free(line);
        lines.deinit(std.testing.allocator);
    }

    try appendLines(std.testing.allocator, &lines, .{
        .candidates = &candidates,
        .selected = 0,
        .window_start = 0,
        .width = 20,
        .height = 20,
        .label_width_override = null,
        .theme = .{},
        .presentation = .{ .max_candidate_rows = 1, .scroll_summary = .{ .visible = false } },
    });

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "one") != null);
}

test "menu label column uses all candidates and caps outliers" {
    const candidates = [_]completion.Candidate{
        .{
            .value = "one",
            .description = "first",
            .kind = .plain,
            .replace_start = 0,
            .replace_end = 0,
        },
        .{
            .value = "much-longer-label",
            .kind = .plain,
            .replace_start = 0,
            .replace_end = 0,
        },
        .{
            .value = "an-outlier-label-that-should-not-own-the-menu-width",
            .kind = .plain,
            .replace_start = 0,
            .replace_end = 0,
        },
    };
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| std.testing.allocator.free(line);
        lines.deinit(std.testing.allocator);
    }

    try appendLines(std.testing.allocator, &lines, .{
        .candidates = &candidates,
        .selected = State.no_selection,
        .window_start = 0,
        .width = 80,
        .height = 3,
        .label_width_override = null,
        .theme = .{ .muted = .{} },
        .presentation = .{ .max_label_width = 8, .scroll_summary = .{ .visible = false } },
    });

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("  one      first", lines.items[0]);
}

test "menu label column truncates before terminal overflow" {
    const candidates = [_]completion.Candidate{.{
        .value = "extraordinarily-long-label",
        .kind = .plain,
        .replace_start = 0,
        .replace_end = 0,
    }};
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| std.testing.allocator.free(line);
        lines.deinit(std.testing.allocator);
    }

    try appendLines(std.testing.allocator, &lines, .{
        .candidates = &candidates,
        .selected = 0,
        .window_start = 0,
        .width = 12,
        .height = 24,
        .label_width_override = null,
        .theme = .{},
    });

    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "extraor…") != null);
    try std.testing.expectEqual(@as(u16, 12), visibleWidth(lines.items[0], .unicode));
}
