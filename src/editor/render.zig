//! Rendering and UI styling for the terminal line editor.

const std = @import("std");
const vaxis = @import("vaxis");

const completion = @import("completion.zig");
const menu = @import("menu.zig");
const prompt_markers = @import("../prompt_markers.zig");

pub const UnderlineStyle = menu.UnderlineStyle;
pub const UiStyle = menu.UiStyle;
pub const UiTheme = menu.UiTheme;
pub const MenuPresentation = menu.Presentation;
pub const appendUiStyleStart = menu.appendUiStyleStart;
pub const appendUiStyleEnd = menu.appendUiStyleEnd;
pub const visibleWidth = menu.visibleWidth;

pub const CursorShape = enum {
    default,
    block,
    beam,
    underline,
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

fn parseUiUnderline(name: []const u8) ?UnderlineStyle {
    if (std.mem.eql(u8, name, "none")) return .none;
    if (std.mem.eql(u8, name, "single")) return .single;
    if (std.mem.eql(u8, name, "double")) return .double;
    if (std.mem.eql(u8, name, "curly")) return .curly;
    if (std.mem.eql(u8, name, "dotted")) return .dotted;
    if (std.mem.eql(u8, name, "dashed")) return .dashed;
    return null;
}

pub fn parseUiColor(name: []const u8) ?vaxis.Color {
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
        return vaxis.Color.rgbFromUint(std.fmt.parseUnsigned(u24, name[1..], 16) catch return null);
    }
    return null;
}

pub const Prompt = struct {
    bytes: []const u8,
    visible_width: ?u16 = null,
};

pub const CompletionFlash = struct {
    start: usize,
    end: usize,
};

pub const Frame = struct {
    lines: []const []const u8,
    input_line_count: usize = 0,
    cursor_row: usize = 0,
    cursor_col: u16 = 0,
    cursor_shape: CursorShape = .default,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
        self.* = undefined;
    }

    pub fn clone(self: Frame, allocator: std.mem.Allocator) !Frame {
        const lines = try allocator.alloc([]const u8, self.lines.len);
        errdefer allocator.free(lines);
        var initialized: usize = 0;
        errdefer for (lines[0..initialized]) |line| allocator.free(line);
        for (self.lines, 0..) |line, index| {
            lines[index] = try allocator.dupe(u8, line);
            initialized += 1;
        }
        return .{
            .lines = lines,
            .input_line_count = self.input_line_count,
            .cursor_row = self.cursor_row,
            .cursor_col = self.cursor_col,
            .cursor_shape = self.cursor_shape,
        };
    }
};

pub const FrameRenderer = struct {
    previous: ?Frame = null,

    pub fn deinit(self: *FrameRenderer, allocator: std.mem.Allocator) void {
        if (self.previous) |*previous| previous.deinit(allocator);
        self.* = undefined;
    }

    pub fn render(
        self: *FrameRenderer,
        allocator: std.mem.Allocator,
        frame: Frame,
        options: FrameRenderOptions,
    ) ![]const u8 {
        const output = if (self.previous) |previous| blk: {
            break :blk try serializeFrameDiff(allocator, previous, frame, options.synchronized_output);
        } else try serializeFullFrame(allocator, frame, options.synchronized_output);
        errdefer allocator.free(output);
        if (self.previous) |*previous| previous.deinit(allocator);
        self.previous = try frame.clone(allocator);
        return output;
    }

    pub fn reset(self: *FrameRenderer, allocator: std.mem.Allocator) void {
        if (self.previous) |*previous| previous.deinit(allocator);
        self.previous = null;
    }

    pub fn clearRowsAfterFirst(self: FrameRenderer, allocator: std.mem.Allocator) ![]const u8 {
        const previous = self.previous orelse return allocator.dupe(u8, "");
        if (previous.lines.len <= 1) return allocator.dupe(u8, "");

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var current_row = previous.cursor_row;
        for (1..previous.lines.len) |row| {
            const move = try cursorMoveFrom(allocator, current_row, row, 0);
            defer allocator.free(move);
            try output.appendSlice(allocator, move);
            try output.appendSlice(allocator, "\x1b[2K");
            current_row = row;
        }
        const restore = try cursorMoveFrom(allocator, current_row, previous.cursor_row, previous.cursor_col);
        defer allocator.free(restore);
        try output.appendSlice(allocator, restore);
        return output.toOwnedSlice(allocator);
    }

    pub fn interruptOutputPrefix(self: FrameRenderer, allocator: std.mem.Allocator) ![]const u8 {
        const previous = self.previous orelse return allocator.dupe(u8, "");

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var current_row = previous.cursor_row;
        for (0..previous.lines.len) |row| {
            const move = try cursorMoveFrom(allocator, current_row, row, 0);
            defer allocator.free(move);
            try output.appendSlice(allocator, move);
            try output.appendSlice(allocator, "\x1b[2K");
            current_row = row;
        }
        const restore = try cursorMoveFrom(allocator, current_row, 0, 0);
        defer allocator.free(restore);
        try output.appendSlice(allocator, restore);
        return output.toOwnedSlice(allocator);
    }

    pub fn submittedHandoff(self: FrameRenderer, allocator: std.mem.Allocator) ![]const u8 {
        const previous = self.previous orelse return allocator.dupe(u8, "");
        const input_line_count = @min(@max(previous.input_line_count, 1), previous.lines.len);

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var current_row = previous.cursor_row;
        if (previous.lines.len > input_line_count) {
            for (input_line_count..previous.lines.len) |row| {
                const move = try cursorMoveFrom(allocator, current_row, row, 0);
                defer allocator.free(move);
                try output.appendSlice(allocator, move);
                try output.appendSlice(allocator, "\x1b[2K");
                current_row = row;
            }
        }
        const move_to_bottom = try cursorMoveFrom(allocator, current_row, input_line_count - 1, 0);
        defer allocator.free(move_to_bottom);
        try output.appendSlice(allocator, move_to_bottom);
        return output.toOwnedSlice(allocator);
    }
};

pub const FrameRenderOptions = struct {
    synchronized_output: bool = true,
};

pub const RenderOptions = struct {
    prompt: Prompt = .{ .bytes = "" },
    right_prompt: Prompt = .{ .bytes = "" },
    completion_menu: []const completion.Candidate = &.{},
    completion_selection: usize = 0,
    completion_window_start: usize = 0,
    completion_label_width: ?usize = null,
    menu_presentation: MenuPresentation = .{},
    suggestion: []const u8 = "",
    status_line: []const u8 = "",
    diagnostic_line: []const u8 = "",
    diagnostic_spans: []const DiagnosticSpan = &.{},
    completion_flash: ?CompletionFlash = null,
    theme: UiTheme = .{},
    semantic_prompt_marks: bool = false,
    width: u16 = 80,
    height: u16 = 24,
    width_method: vaxis.gwidth.Method = .unicode,
    synchronized_output: bool = true,
    cursor_shape: CursorShape = .default,

    pub fn menuCandidateRows(self: RenderOptions) usize {
        return menu.candidateRows(self.height, self.menu_presentation);
    }
};

pub const DiagnosticSeverity = enum {
    warning,
    err,
    command_invalid,
    comment,
    quote,
    pending,
    command,
    reserved,
    operator,
    assignment_operator,
    assignment,
    expansion,
    option,
};

pub const DiagnosticSpan = struct {
    start: usize,
    end: usize,
    severity: DiagnosticSeverity,
};

pub const DiagnosticRender = struct {
    line: []const u8 = "",
    spans: []const DiagnosticSpan = &.{},

    pub fn deinit(self: DiagnosticRender, allocator: std.mem.Allocator) void {
        if (self.line.len != 0) allocator.free(self.line);
        allocator.free(self.spans);
    }
};

pub const semantic_prompt_end = "\x1b]133;B\x07";

pub const Input = struct {
    text: []const u8,
    cursor_byte: usize,
};

pub fn renderLine(allocator: std.mem.Allocator, input: Input, options: RenderOptions) ![]const u8 {
    var frame = try frameFromInput(allocator, input, options);
    defer frame.deinit(allocator);
    return serializeFullFrame(allocator, frame, options.synchronized_output);
}

pub fn frameFromInput(allocator: std.mem.Allocator, input: Input, options: RenderOptions) !Frame {
    std.debug.assert(input.cursor_byte <= input.text.len);

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    var input_line: std.ArrayList(u8) = .empty;
    errdefer input_line.deinit(allocator);
    try input_line.appendSlice(allocator, options.prompt.bytes);
    if (options.semantic_prompt_marks) try input_line.appendSlice(allocator, semantic_prompt_end);
    try appendStyledInput(
        allocator,
        &input_line,
        input.text,
        options.diagnostic_spans,
        options.completion_flash,
        options.theme,
    );
    if (options.suggestion.len != 0 and renderableInlineText(options.suggestion)) {
        try appendUiStyleStart(allocator, &input_line, options.theme.muted);
        try input_line.appendSlice(allocator, options.suggestion);
        try appendUiStyleEnd(allocator, &input_line, options.theme.muted);
    }
    const input_line_bytes = try input_line.toOwnedSlice(allocator);
    defer allocator.free(input_line_bytes);

    const wrap_width = @max(options.width, 1);
    var cursor_prefix: std.ArrayList(u8) = .empty;
    defer cursor_prefix.deinit(allocator);
    try cursor_prefix.appendSlice(allocator, options.prompt.bytes);
    try cursor_prefix.appendSlice(allocator, input.text[0..input.cursor_byte]);
    const cursor_position = wrappedPosition(cursor_prefix.items, wrap_width, options.width_method);

    try appendWrappedLine(allocator, &lines, input_line_bytes, wrap_width, options.width_method);
    if (cursor_position.row == lines.items.len) try lines.append(allocator, try allocator.dupe(u8, ""));
    try appendRightPrompt(
        allocator,
        lines.items,
        options.prompt.bytes,
        options.right_prompt.bytes,
        wrap_width,
        options.width_method,
    );
    const input_line_count = lines.items.len;
    if (options.status_line.len != 0) {
        try appendWrappedLine(allocator, &lines, options.status_line, wrap_width, options.width_method);
    }
    if (options.diagnostic_line.len != 0) {
        try appendWrappedLine(allocator, &lines, options.diagnostic_line, wrap_width, options.width_method);
    }
    try menu.appendLines(allocator, &lines, .{
        .candidates = options.completion_menu,
        .selected = options.completion_selection,
        .window_start = options.completion_window_start,
        .width = options.width,
        .height = options.height,
        .label_width_override = options.completion_label_width,
        .theme = options.theme,
        .presentation = options.menu_presentation,
    });

    return .{
        .lines = try lines.toOwnedSlice(allocator),
        .input_line_count = input_line_count,
        .cursor_row = cursor_position.row,
        .cursor_col = cursor_position.col,
        .cursor_shape = options.cursor_shape,
    };
}

fn appendRightPrompt(
    allocator: std.mem.Allocator,
    lines: [][]const u8,
    prompt_bytes: []const u8,
    right_prompt_bytes: []const u8,
    width: u16,
    method: vaxis.gwidth.Method,
) !void {
    if (right_prompt_bytes.len == 0 or lines.len == 0) return;
    const line_width: usize = width;
    const right_width: usize = visibleWidth(right_prompt_bytes, method);
    if (right_width == 0 or right_width >= line_width) return;

    const input_start = wrappedPosition(prompt_bytes, width, method);
    if (input_start.row >= lines.len) return;

    const row = lines[input_start.row];
    const left_width: usize = visibleWidth(row, method);
    if (left_width + right_width >= line_width) return;

    var padded: std.ArrayList(u8) = .empty;
    errdefer padded.deinit(allocator);
    try padded.appendSlice(allocator, row);
    for (left_width..line_width - right_width) |_| try padded.append(allocator, ' ');
    try padded.appendSlice(allocator, right_prompt_bytes);

    allocator.free(row);
    lines[input_start.row] = try padded.toOwnedSlice(allocator);
}

fn appendStyledInput(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    spans: []const DiagnosticSpan,
    flash: ?CompletionFlash,
    theme: UiTheme,
) !void {
    if (spans.len == 0 and flash == null) {
        try out.appendSlice(allocator, text);
        return;
    }

    var active: ?DiagnosticSeverity = null;
    var flash_active = false;
    var i: usize = 0;
    while (i < text.len) {
        var iter = vaxis.unicode.graphemeIterator(text[i..]);
        const grapheme = iter.next() orelse break;
        const grapheme_end = i + grapheme.len;
        const should_flash = completionFlashAt(flash, i, grapheme_end);
        if (flash_active != should_flash) {
            if (flash_active) try appendUiStyleEnd(allocator, out, theme.flash);
            if (should_flash) try appendUiStyleStart(allocator, out, theme.flash);
            // Toggling flash resets attributes the active span also uses, so
            // re-apply the span style on top.
            if (active) |value| try appendUiStyleStart(allocator, out, diagnosticStyle(theme, value));
            flash_active = should_flash;
        }
        const severity = diagnosticSeverityAt(spans, i, grapheme_end);
        if (active != severity) {
            if (active) |previous| {
                try appendUiStyleEnd(allocator, out, diagnosticStyle(theme, previous));
                if (flash_active) try appendUiStyleStart(allocator, out, theme.flash);
            }
            if (severity) |value| try appendUiStyleStart(allocator, out, diagnosticStyle(theme, value));
            active = severity;
        }
        try out.appendSlice(allocator, text[i..grapheme_end]);
        i = grapheme_end;
    }
    if (active) |previous| try appendUiStyleEnd(allocator, out, diagnosticStyle(theme, previous));
    if (flash_active) try appendUiStyleEnd(allocator, out, theme.flash);
    if (i < text.len) try out.appendSlice(allocator, text[i..]);
}

fn completionFlashAt(flash: ?CompletionFlash, start: usize, end: usize) bool {
    const span = flash orelse return false;
    return start < span.end and end > span.start;
}

pub fn completionFlashForCursor(text: []const u8, cursor: usize) CompletionFlash {
    if (text.len == 0) return .{ .start = 0, .end = 0 };
    var end = @min(cursor, text.len);
    if (end < text.len and !std.ascii.isWhitespace(text[end])) {
        var start = end;
        while (start > 0 and !std.ascii.isWhitespace(text[start - 1])) : (start -= 1) {}
        while (end < text.len and !std.ascii.isWhitespace(text[end])) : (end += 1) {}
        return .{ .start = start, .end = end };
    }
    while (end > 0 and std.ascii.isWhitespace(text[end - 1])) : (end -= 1) {}
    var start = end;
    while (start > 0 and !std.ascii.isWhitespace(text[start - 1])) : (start -= 1) {}
    if (start == end and start != 0) start -= 1;
    return .{ .start = start, .end = end };
}

fn diagnosticStyle(theme: UiTheme, severity: DiagnosticSeverity) UiStyle {
    return switch (severity) {
        .warning, .err, .command_invalid => theme.err,
        .comment => theme.comment,
        .quote => theme.quote,
        .pending => theme.pending,
        .command => theme.command,
        .reserved => theme.reserved,
        .operator => theme.operator,
        .assignment_operator => theme.muted,
        .assignment, .expansion => theme.variable,
        .option => theme.option,
    };
}

fn diagnosticSeverityAt(spans: []const DiagnosticSpan, start: usize, end: usize) ?DiagnosticSeverity {
    for (spans) |span| {
        const span_end = @max(span.end, span.start + 1);
        if (start < span_end and end > span.start) return span.severity;
    }
    return null;
}

pub fn renderableInlineText(bytes: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(bytes)) return false;
    for (bytes) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

pub fn serializeFullFrame(allocator: std.mem.Allocator, frame: Frame, synchronized_output: bool) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    if (synchronized_output) try output.appendSlice(allocator, "\x1b[?2026h");
    if (frame.cursor_shape != .default) try output.appendSlice(allocator, cursorShapeSequence(frame.cursor_shape));
    try output.appendSlice(allocator, "\r\x1b[2K");
    if (frame.lines.len != 0) try appendSerializedLine(allocator, &output, frame.lines[0]);
    for (frame.lines[1..]) |line| {
        try output.appendSlice(allocator, "\r\n\x1b[2K");
        try appendSerializedLine(allocator, &output, line);
    }
    const cursor_sequence = try cursorMoveFrom(allocator, frame.lines.len -| 1, frame.cursor_row, frame.cursor_col);
    defer allocator.free(cursor_sequence);
    try output.appendSlice(allocator, cursor_sequence);
    if (synchronized_output) try output.appendSlice(allocator, "\x1b[?2026l");

    return output.toOwnedSlice(allocator);
}

fn serializeFrameDiff(
    allocator: std.mem.Allocator,
    previous: Frame,
    frame: Frame,
    synchronized_output: bool,
) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    if (synchronized_output) try output.appendSlice(allocator, "\x1b[?2026h");
    if (previous.cursor_shape != frame.cursor_shape) {
        try output.appendSlice(allocator, cursorShapeSequence(frame.cursor_shape));
    }

    var current_row = previous.cursor_row;
    const max_lines = @max(previous.lines.len, frame.lines.len);
    for (0..max_lines) |row| {
        const old_line = if (row < previous.lines.len) previous.lines[row] else null;
        const new_line = if (row < frame.lines.len) frame.lines[row] else null;
        const changed = if (old_line) |old|
            if (new_line) |new| !std.mem.eql(u8, old, new) else true
        else
            new_line != null;
        if (!changed) continue;
        const move = if (row >= previous.lines.len and row > current_row)
            try cursorLineFeedFrom(allocator, current_row, row)
        else
            try cursorMoveFrom(allocator, current_row, row, 0);
        defer allocator.free(move);
        try output.appendSlice(allocator, move);
        try output.appendSlice(allocator, "\x1b[2K");
        if (new_line) |line| try appendSerializedLine(allocator, &output, line);
        current_row = row;
    }

    const cursor_sequence = try cursorMoveFrom(allocator, current_row, frame.cursor_row, frame.cursor_col);
    defer allocator.free(cursor_sequence);
    try output.appendSlice(allocator, cursor_sequence);
    if (synchronized_output) try output.appendSlice(allocator, "\x1b[?2026l");
    return output.toOwnedSlice(allocator);
}

fn appendSerializedLine(allocator: std.mem.Allocator, output: *std.ArrayList(u8), line: []const u8) !void {
    var start: usize = 0;
    for (line, 0..) |byte, index| {
        if (!prompt_markers.isMarker(byte)) continue;
        try output.appendSlice(allocator, line[start..index]);
        start = index + 1;
    }
    try output.appendSlice(allocator, line[start..]);
}

fn cursorShapeSequence(shape: CursorShape) []const u8 {
    return switch (shape) {
        .default => "\x1b[0 q",
        .block => "\x1b[2 q",
        .beam => "\x1b[6 q",
        .underline => "\x1b[4 q",
    };
}

fn cursorMoveFrom(allocator: std.mem.Allocator, from_row: usize, to_row: usize, col: u16) ![]const u8 {
    if (col == 0) {
        if (from_row > to_row) return std.fmt.allocPrint(allocator, "\x1b[{d}A\r", .{from_row - to_row});
        if (to_row > from_row) return std.fmt.allocPrint(allocator, "\x1b[{d}B\r", .{to_row - from_row});
        return allocator.dupe(u8, "\r");
    }
    if (from_row > to_row) {
        return std.fmt.allocPrint(allocator, "\x1b[{d}A\r\x1b[{d}C", .{ from_row - to_row, col });
    }
    if (to_row > from_row) {
        return std.fmt.allocPrint(allocator, "\x1b[{d}B\r\x1b[{d}C", .{ to_row - from_row, col });
    }
    return std.fmt.allocPrint(allocator, "\r\x1b[{d}C", .{col});
}

fn cursorLineFeedFrom(allocator: std.mem.Allocator, from_row: usize, to_row: usize) ![]const u8 {
    std.debug.assert(to_row > from_row);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (from_row..to_row) |_| try output.appendSlice(allocator, "\r\n");
    return output.toOwnedSlice(allocator);
}

fn appendWrappedLine(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    bytes: []const u8,
    width: u16,
    method: vaxis.gwidth.Method,
) !void {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(allocator);
    var active_sgr: std.ArrayList(u8) = .empty;
    defer active_sgr.deinit(allocator);
    var row_width: u16 = 0;
    var i: usize = 0;
    var nonprinting = false;
    while (i < bytes.len) {
        if (bytes[i] == prompt_markers.nonprinting_start) {
            nonprinting = true;
            try row.append(allocator, bytes[i]);
            i += 1;
            continue;
        }
        if (bytes[i] == prompt_markers.nonprinting_end) {
            nonprinting = false;
            try row.append(allocator, bytes[i]);
            i += 1;
            continue;
        }
        if (nonprinting) {
            if (escapeSequenceEnd(bytes, i)) |end| {
                try row.appendSlice(allocator, bytes[i..end]);
                try updateActiveSgr(allocator, &active_sgr, bytes[i..end]);
                i = end;
            } else {
                try row.append(allocator, bytes[i]);
                i += 1;
            }
            continue;
        }
        if (bytes[i] == '\n') {
            try lines.append(allocator, try row.toOwnedSlice(allocator));
            row = .empty;
            try row.appendSlice(allocator, active_sgr.items);
            row_width = 0;
            i += 1;
            continue;
        }
        if (escapeSequenceEnd(bytes, i)) |end| {
            try row.appendSlice(allocator, bytes[i..end]);
            try updateActiveSgr(allocator, &active_sgr, bytes[i..end]);
            i = end;
            continue;
        }

        var iter = vaxis.unicode.graphemeIterator(bytes[i..]);
        const grapheme = iter.next() orelse break;
        const grapheme_bytes = bytes[i .. i + grapheme.len];
        const grapheme_width = vaxis.gwidth.gwidth(grapheme_bytes, method);
        if (row_width != 0 and row_width + grapheme_width > width) {
            try lines.append(allocator, try row.toOwnedSlice(allocator));
            row = .empty;
            try row.appendSlice(allocator, active_sgr.items);
            row_width = 0;
        }
        try row.appendSlice(allocator, grapheme_bytes);
        row_width += grapheme_width;
        i += grapheme.len;
        if (row_width == width and i < bytes.len) {
            try lines.append(allocator, try row.toOwnedSlice(allocator));
            row = .empty;
            try row.appendSlice(allocator, active_sgr.items);
            row_width = 0;
        }
    }
    try lines.append(allocator, try row.toOwnedSlice(allocator));
}

fn updateActiveSgr(allocator: std.mem.Allocator, active_sgr: *std.ArrayList(u8), sequence: []const u8) !void {
    if (!isSgrSequence(sequence)) return;
    if (isFullSgrReset(sequence)) {
        active_sgr.clearRetainingCapacity();
        return;
    }
    try active_sgr.appendSlice(allocator, sequence);
}

fn isSgrSequence(sequence: []const u8) bool {
    return sequence.len >= 3 and sequence[0] == 0x1b and sequence[1] == '[' and sequence[sequence.len - 1] == 'm';
}

fn isFullSgrReset(sequence: []const u8) bool {
    std.debug.assert(isSgrSequence(sequence));

    const parameters = sequence[2 .. sequence.len - 1];
    return parameters.len == 0 or std.mem.eql(u8, parameters, "0");
}

const WrappedPosition = struct {
    row: usize,
    col: u16,
};

fn wrappedPosition(bytes: []const u8, width: u16, method: vaxis.gwidth.Method) WrappedPosition {
    var row: usize = 0;
    var col: u16 = 0;
    var i: usize = 0;
    var nonprinting = false;
    while (i < bytes.len) {
        if (bytes[i] == prompt_markers.nonprinting_start) {
            nonprinting = true;
            i += 1;
            continue;
        }
        if (bytes[i] == prompt_markers.nonprinting_end) {
            nonprinting = false;
            i += 1;
            continue;
        }
        if (nonprinting) {
            i += 1;
            continue;
        }
        if (bytes[i] == '\n') {
            row += 1;
            col = 0;
            i += 1;
            continue;
        }
        if (escapeSequenceEnd(bytes, i)) |end| {
            i = end;
            continue;
        }
        var iter = vaxis.unicode.graphemeIterator(bytes[i..]);
        const grapheme = iter.next() orelse break;
        const grapheme_width = vaxis.gwidth.gwidth(bytes[i .. i + grapheme.len], method);
        if (col != 0 and col + grapheme_width > width) {
            row += 1;
            col = 0;
        }
        col += grapheme_width;
        i += grapheme.len;
        if (col == width) {
            row += 1;
            col = 0;
        }
    }
    return .{ .row = row, .col = col };
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

test "marked arbitrary prompt bytes render without affecting layout" {
    var frame = try frameFromInput(std.testing.allocator, .{ .text = "x", .cursor_byte = 1 }, .{
        .prompt = .{ .bytes = "\x01arbitrary-control\x02> " },
        .synchronized_output = false,
    });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 3), frame.cursor_col);
    const rendered = try serializeFullFrame(std.testing.allocator, frame, false);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "arbitrary-control> x") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered, prompt_markers.nonprinting_start) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered, prompt_markers.nonprinting_end) == null);
}

test "marked prompt regions do not displace a right prompt" {
    var frame = try frameFromInput(std.testing.allocator, .{ .text = "", .cursor_byte = 0 }, .{
        .prompt = .{ .bytes = "\x01left-control\x02> " },
        .right_prompt = .{ .bytes = "\x01right-control\x02R" },
        .width = 10,
        .synchronized_output = false,
    });
    defer frame.deinit(std.testing.allocator);

    const rendered = try serializeFullFrame(std.testing.allocator, frame, false);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "left-control>        right-controlR",
    ) != null);
}
