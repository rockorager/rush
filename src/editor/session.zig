//! Terminal-independent editor session core.

const std = @import("std");
const edit_buffer = @import("buffer.zig");
const completion = @import("completion.zig");
const key_mod = @import("key.zig");
const history_mod = @import("history.zig");
const menu = @import("menu.zig");
const path = @import("path.zig");
const prompt_markers = @import("../prompt_markers.zig");
const render = @import("render.zig");
const request_mod = @import("request.zig");
const shell_lexer = @import("../shell/lexer.zig");
const shell_source = @import("../shell/source.zig");
const shell_token = @import("../shell/token.zig");
const vi = @import("vi.zig");
const vaxis = @import("vaxis");

const max_vi_macro_depth = vi.max_macro_depth;

pub const UnderlineStyle = render.UnderlineStyle;
pub const UiStyle = render.UiStyle;
pub const UiTheme = render.UiTheme;
pub const MenuPresentation = render.MenuPresentation;
pub const CursorShape = render.CursorShape;
pub const Prompt = render.Prompt;
pub const CompletionFlash = render.CompletionFlash;
pub const Frame = render.Frame;
pub const FrameRenderer = render.FrameRenderer;
pub const FrameRenderOptions = render.FrameRenderOptions;
pub const RenderOptions = render.RenderOptions;
pub const DiagnosticSeverity = render.DiagnosticSeverity;
pub const DiagnosticSpan = render.DiagnosticSpan;
pub const DiagnosticRender = render.DiagnosticRender;
// ziglint-ignore: Z006 public re-export keeps existing API spelling
pub const semanticPromptEnd = render.semantic_prompt_end;
pub const parseUiStyle = render.parseUiStyle;
pub const visibleWidth = render.visibleWidth;

const appendUiStyleStart = render.appendUiStyleStart;
const appendUiStyleEnd = render.appendUiStyleEnd;
const completionFlashForCursor = render.completionFlashForCursor;
const renderableInlineText = render.renderableInlineText;
const serializeFullFrame = render.serializeFullFrame;

pub const KeyEvent = key_mod.Event;
pub const Key = key_mod.Key;
pub const Modifiers = key_mod.Modifiers;
pub const keyEventFromVaxis = key_mod.eventFromVaxis;
const keyFromVaxis = key_mod.keyFromVaxis;

const BufferSnapshot = edit_buffer.Snapshot;
pub const EditBuffer = edit_buffer.EditBuffer;
pub const Editor = edit_buffer.Editor;
const previousGraphemeStart = edit_buffer.previousGraphemeStart;
const nextGraphemeEnd = edit_buffer.nextGraphemeEnd;
const previousWordStart = edit_buffer.previousWordStart;
const nextWordEnd = edit_buffer.nextWordEnd;

pub const EditingMode = enum {
    emacs,
    vi,
};

pub const PathExpansionCommand = path.Command;
pub const PathExpansionReplacementStyle = path.ReplacementStyle;
pub const PathExpansionRequest = path.Request;
pub const PathExpansionMatches = path.Matches;
pub const pathExpansionListOutput = path.listOutput;
const currentViBigwordRange = path.currentViBigwordRange;
const pathExpansionReplacementStyle = path.replacementStyle;
const pathExpansionCompletionReplacement = path.completionReplacement;
const pathExpansionAllReplacement = path.allReplacement;

pub const ViState = vi.ViState;
const ViOperator = vi.ViOperator;
const ViFindDirection = vi.ViFindDirection;
const ViHistoryDirection = vi.ViHistoryDirection;
const ViFindPlacement = vi.ViFindPlacement;
const ViFindCommand = vi.ViFindCommand;
const ViPending = vi.ViPending;
const ViMotionResult = vi.ViMotionResult;
const ViMotionRange = vi.ViMotionRange;
const ViWordKind = vi.ViWordKind;
const ViInsertPlacement = vi.ViInsertPlacement;
const ViInsertRepeatCapture = vi.ViInsertRepeatCapture;
const ViInputRepeatMode = vi.ViInputRepeatMode;
const ViInputRepeatOp = vi.ViInputRepeatOp;
const ViInputRepeat = vi.ViInputRepeat;
const ViRepeat = vi.ViRepeat;

const reverseViHistoryDirection = vi.reverseViHistoryDirection;
const isPortableAlphabetic = vi.isPortableAlphabetic;
const viMacroKeyEvent = vi.viMacroKeyEvent;
const viHistoryPatternMatches = vi.viHistoryPatternMatches;
const viMotion = vi.viMotion;
const viOperatorMotionRange = vi.viOperatorMotionRange;
const viChangeWordMotionRange = vi.viChangeWordMotionRange;
const multiplyViCounts = vi.multiplyViCounts;
const firstNonBlank = vi.firstNonBlank;
const previousViWordStart = vi.previousViWordStart;
const viFind = vi.viFind;
const reverseViFind = vi.reverseViFind;
const firstCodepoint = vi.firstCodepoint;
const previousCodepointStart = vi.previousCodepointStart;
const nextCodepointEnd = vi.nextCodepointEnd;
const isAsciiWhitespace = vi.isAsciiWhitespace;
const staticHistoryStart = vi.staticHistoryStart;
const viHistoryBigword = vi.viHistoryBigword;

pub const HistoryView = history_mod.View;
pub const HistorySearchFilters = history_mod.SearchFilters;
pub const ViAliasView = struct {
    context: ?*anyopaque = null,
    lookup: ?*const fn (*anyopaque, std.mem.Allocator, u21) anyerror!?[]const u8 = null,
};

pub const ExternalEditorRequest = request_mod.ExternalEditorRequest;
pub const CompletionMenu = menu.State;

const PendingRemovableSuffix = struct {
    start: usize,
    end: usize,
    text: []u8,

    fn deinit(self: PendingRemovableSuffix, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

const UndoKind = enum {
    insertion,
    delete_backward,
    delete_forward,
    edit,
};

const UndoEntry = struct {
    before: BufferSnapshot,
    after: BufferSnapshot,
    kind: UndoKind,

    fn deinit(self: UndoEntry, allocator: std.mem.Allocator) void {
        self.before.deinit(allocator);
        self.after.deinit(allocator);
    }
};

pub const HistoryRequest = request_mod.HistoryRequest;
pub const HistoryResult = request_mod.HistoryResult;
const LineRequestOutbox = request_mod.Outbox;

pub const MouseClick = struct {
    row: usize,
    col: usize,
    frame: Frame,
    width: u16,
    height: u16,
    width_method: vaxis.gwidth.Method,
    menu_presentation: MenuPresentation = .{},
};

/// Readline uses SOH/STX to bracket non-printing prompt bytes. The editor
/// parses terminal escapes itself, so those markers must not reach either its
/// width calculations or the terminal output stream.
fn copyPromptBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var marker_count: usize = 0;
    for (bytes) |byte| if (prompt_markers.isMarker(byte)) {
        marker_count += 1;
    };
    if (marker_count == 0) return allocator.dupe(u8, bytes);

    const copy = try allocator.alloc(u8, bytes.len - marker_count);
    var index: usize = 0;
    for (bytes) |byte| {
        if (prompt_markers.isMarker(byte)) continue;
        copy[index] = byte;
        index += 1;
    }
    std.debug.assert(index == copy.len);
    return copy;
}

/// Owns editable state, copied prompts, queued requests, accepted history and
/// completion data, and any submitted line until `takeSubmittedLine`.
/// `HistoryView` callback context and static entries remain caller-owned and
/// must outlive the session.
pub const LineSession = struct {
    allocator: std.mem.Allocator,
    prompt: Prompt,
    right_prompt: Prompt = .{ .bytes = "" },
    requests: LineRequestOutbox = .{},
    editing_mode: EditingMode = .emacs,
    vi_state: ViState = .insert,
    vi_pending: ViPending = .none,
    vi_count: ?usize = null,
    vi_last_find: ?ViFindCommand = null,
    vi_undo: ?BufferSnapshot = null,
    vi_line_undo: ?BufferSnapshot = null,
    vi_last_repeat: ?ViRepeat = null,
    vi_insert_repeat: ?ViInsertRepeatCapture = null,
    vi_insert_repeat_ops: std.ArrayList(ViInputRepeatOp) = .empty,
    vi_replaying_repeat: bool = false,
    vi_macro_depth: usize = 0,
    editor: Editor,
    history: HistoryView = .{},
    history_index: ?i64 = null,
    saved_edit: std.ArrayList(u8) = .empty,
    history_search_query: std.ArrayList(u8) = .empty,
    history_search_original: std.ArrayList(u8) = .empty,
    history_search_matches: std.ArrayList(HistoryView.HistoryEntry) = .empty,
    history_search_selected: usize = 0,
    history_search_filters: HistorySearchFilters = .{},
    history_search_direction: ViHistoryDirection = .backward,
    autosuggestion: ?HistoryView.HistoryEntry = null,
    vi_history_search_query: std.ArrayList(u8) = .empty,
    vi_last_history_search_pattern: std.ArrayList(u8) = .empty,
    vi_last_history_search_direction: ?ViHistoryDirection = null,
    kill_ring: std.ArrayList(u8) = .empty,
    completion_menu: CompletionMenu = .{},
    state: State = .editing,
    submitted_line: ?[]const u8 = null,
    paste_depth: usize = 0,
    completion_flash: ?CompletionFlash = null,
    pending_removable_suffix: ?PendingRemovableSuffix = null,
    undo_stack: std.ArrayList(UndoEntry) = .empty,
    redo_stack: std.ArrayList(UndoEntry) = .empty,

    pub const State = enum {
        editing,
        history_search,
        external_editor,
        submitted,
        canceled,
        eof,
    };

    pub fn init(allocator: std.mem.Allocator, prompt: []const u8) !LineSession {
        return initWithOptions(allocator, .{ .bytes = prompt }, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, prompt: Prompt, history: HistoryView) !LineSession {
        return initWithEditingMode(allocator, prompt, history, .emacs);
    }

    /// Copies `prompt.bytes`; borrows `history` callback context and entries.
    pub fn initWithEditingMode(
        allocator: std.mem.Allocator,
        prompt: Prompt,
        history: HistoryView,
        editing_mode: EditingMode,
    ) !LineSession {
        return .{
            .allocator = allocator,
            .prompt = .{
                .bytes = try copyPromptBytes(allocator, prompt.bytes),
                .visible_width = prompt.visible_width,
            },
            .editing_mode = editing_mode,
            .editor = .init(allocator),
            .history = history,
        };
    }

    pub fn deinit(self: *LineSession) void {
        if (self.submitted_line) |line| self.allocator.free(line);
        self.requests.deinit(self.allocator);
        self.clearPendingRemovableSuffix();
        self.clearHistorySearchMatches();
        self.clearAutosuggestion();
        self.history_search_matches.deinit(self.allocator);
        self.history_search_original.deinit(self.allocator);
        self.history_search_query.deinit(self.allocator);
        self.vi_last_history_search_pattern.deinit(self.allocator);
        self.vi_history_search_query.deinit(self.allocator);
        self.completion_menu.deinit(self.allocator);
        self.kill_ring.deinit(self.allocator);
        self.saved_edit.deinit(self.allocator);
        self.clearViLastRepeat();
        self.clearViInsertRepeatCapture();
        self.vi_insert_repeat_ops.deinit(self.allocator);
        self.clearViUndo();
        self.clearViLineUndo();
        self.clearUndoHistory();
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
        self.editor.deinit();
        self.allocator.free(self.prompt.bytes);
        if (self.right_prompt.bytes.len != 0) self.allocator.free(self.right_prompt.bytes);
        self.* = undefined;
    }

    pub fn handleKey(self: *LineSession, event: KeyEvent) !void {
        const undo_kind = self.undoKindForEvent(event);
        const before = if (undo_kind != null) try self.snapshotBuffer() else null;
        errdefer if (before) |snapshot| snapshot.deinit(self.allocator);

        try self.handleKeyInner(event);

        if (before) |snapshot| try self.commitUndo(snapshot, undo_kind.?);
    }

    fn undoKindForEvent(self: LineSession, event: KeyEvent) ?UndoKind {
        if (self.state != .editing) return null;
        if (self.paste_depth != 0) {
            return switch (event.key) {
                .text, .enter => .edit,
                else => null,
            };
        }
        if (self.editing_mode == .vi) return self.viUndoKindForEvent(event);
        return switch (event.key) {
            .text => if (event.text.len == 0) null else .insertion,
            .enter => if (event.modifiers.shift) .insertion else null,
            .backspace => .delete_backward,
            .delete,
            .ctrl_d,
            => .delete_forward,
            .ctrl_c,
            .delete_to_start,
            .delete_to_end,
            .delete_previous_word,
            .delete_next_word,
            .delete_previous_argument,
            .delete_next_argument,
            .yank,
            .transpose_chars,
            => .edit,
            else => null,
        };
    }

    fn viUndoKindForEvent(self: LineSession, event: KeyEvent) ?UndoKind {
        return switch (self.vi_state) {
            .insert, .replace => switch (event.key) {
                .text => if (event.text.len == 0) null else .insertion,
                .enter => if (event.modifiers.shift) .insertion else null,
                .backspace => .delete_backward,
                .ctrl_d => .delete_forward,
                .ctrl_c,
                .delete_previous_word,
                .delete_next_word,
                .delete_to_start,
                .delete_previous_argument,
                .delete_next_argument,
                => .edit,
                else => null,
            },
            .command => viCommandUndoKind(self.vi_pending, event),
        };
    }

    fn viCommandUndoKind(pending: ViPending, event: KeyEvent) ?UndoKind {
        if (event.key == .ctrl_r or event.key == .undo or event.key == .redo) return null;
        if (event.key != .text or event.text.len == 0) return null;
        const command = firstCodepoint(event.text) orelse return null;
        switch (pending) {
            .replace, .operator => return .edit,
            .none, .find, .alias, .history_search => {},
        }
        return switch (command) {
            'x' => .delete_forward,
            'X' => .delete_backward,
            'r', 'D', 'C', 'S', 'd', 'c', 'p', 'P', '~', '_', '.', '#' => .edit,
            else => null,
        };
    }

    fn handleKeyInner(self: *LineSession, event: KeyEvent) !void {
        if (self.state != .editing and self.state != .history_search) return;
        if (self.paste_depth != 0) {
            if (event.key == .text or event.key == .enter) {
                const text = if (event.key == .enter) "\n" else event.text;
                try self.editor.handleKey(.{ .key = .text, .text = text });
                self.completion_menu.clear(self.allocator);
                self.clearPendingRemovableSuffix();
            }
            return;
        }
        if (self.state == .history_search) return self.handleHistorySearchKey(event);
        if (try self.consumePendingRemovableSuffix(event)) return;
        if (self.editing_mode == .vi) return self.handleViKey(event);
        switch (event.key) {
            .enter => {
                if (event.modifiers.shift) return self.insertLiteralNewline();
                if (self.completion_menu.selectedCandidate()) |candidate| {
                    try self.applyCompletionCandidate(candidate);
                    return;
                }
                self.completion_menu.clear(self.allocator);
                std.debug.assert(self.submitted_line == null);
                self.submitted_line = try self.allocator.dupe(u8, self.editor.buffer.text());
                self.state = .submitted;
            },
            .escape => {
                self.completion_menu.clear(self.allocator);
            },
            .ctrl_c => {
                try self.clearInput();
            },
            .ctrl_d => {
                self.completion_menu.clear(self.allocator);
                if (self.editor.buffer.text().len == 0) {
                    self.state = .eof;
                } else {
                    self.editor.buffer.deleteNext();
                }
            },
            .ctrl_r => try self.beginHistorySearch(.backward),
            .undo => try self.undoEdit(),
            .redo => try self.redoEdit(),
            .clear_screen => {
                self.completion_menu.clear(self.allocator);
                self.requests.put(self.allocator, .clear_screen);
            },
            .backspace => {
                self.editor.buffer.deletePrevious();
                self.completion_menu.clear(self.allocator);
            },
            .delete => {
                self.editor.buffer.deleteNext();
                self.completion_menu.clear(self.allocator);
            },
            .delete_to_start => {
                try self.killRange(0, self.editor.buffer.cursor_byte, 0);
                self.completion_menu.clear(self.allocator);
            },
            .delete_to_end => {
                try self.killRange(
                    self.editor.buffer.cursor_byte,
                    self.editor.buffer.text().len,
                    self.editor.buffer.cursor_byte,
                );
                self.completion_menu.clear(self.allocator);
            },
            .delete_previous_word => {
                const start = previousWordStart(self.editor.buffer.text(), self.editor.buffer.cursor_byte);
                try self.killRange(start, self.editor.buffer.cursor_byte, start);
                self.completion_menu.clear(self.allocator);
            },
            .delete_next_word => {
                const end = nextWordEnd(self.editor.buffer.text(), self.editor.buffer.cursor_byte);
                try self.killRange(self.editor.buffer.cursor_byte, end, self.editor.buffer.cursor_byte);
                self.completion_menu.clear(self.allocator);
            },
            .argument_left => {
                try self.movePreviousArgument();
            },
            .argument_right => {
                try self.moveNextArgument();
            },
            .delete_previous_argument => {
                try self.killPreviousArgument();
            },
            .delete_next_argument => {
                try self.killNextArgument();
            },
            .yank => {
                if (self.kill_ring.items.len != 0) {
                    try self.editor.buffer.insertText(self.kill_ring.items);
                    self.completion_menu.clear(self.allocator);
                }
            },
            .left, .home, .word_left, .word_right => {
                try self.editor.handleKey(event);
                self.completion_menu.clear(self.allocator);
            },
            .right, .end => {
                if (self.editor.buffer.cursor_byte == self.editor.buffer.text().len and
                    try self.acceptAutosuggestion())
                {
                    self.completion_menu.clear(self.allocator);
                    return;
                }
                try self.editor.handleKey(event);
                self.completion_menu.clear(self.allocator);
            },
            .up => if (self.completion_menu.isOpen())
                self.completion_menu.selectPrevious()
            else
                try self.historyPrevious(),
            .down => if (self.completion_menu.isOpen()) self.completion_menu.selectNext() else try self.historyNext(),
            .tab => if (self.completion_menu.isOpen()) {
                if (event.modifiers.shift) self.completion_menu.selectPrevious() else self.completion_menu.selectNext();
            },
            else => {
                try self.editor.handleKey(event);
                if (!self.completion_menu.isOpen()) self.completion_menu.clear(self.allocator);
            },
        }
    }

    fn handleViKey(self: *LineSession, event: KeyEvent) !void {
        switch (self.vi_state) {
            .insert => return self.handleViInsertKey(event),
            .replace => return self.handleViReplaceKey(event),
            .command => return self.handleViCommandKey(event),
        }
    }

    fn handleViInsertKey(self: *LineSession, event: KeyEvent) !void {
        switch (event.key) {
            .escape => {
                try self.finishViInsertRepeat();
                self.enterViCommandMode();
            },
            .ctrl_c => {
                self.clearViInsertRepeatCapture();
                try self.clearInput();
            },
            .undo => try self.undoEdit(),
            .redo => try self.redoEdit(),
            .enter => {
                if (event.modifiers.shift) {
                    try self.insertLiteralNewline();
                    return self.appendViInputRepeatText("\n");
                }
                self.clearViInsertRepeatCapture();
                try self.submitInput();
            },
            .backspace => {
                self.editor.buffer.deletePrevious();
                try self.appendViInputRepeatKey(.backspace);
                self.completion_menu.clear(self.allocator);
            },
            .delete_previous_word => {
                const start = previousViWordStart(self.editor.buffer.text(), self.editor.buffer.cursor_byte, .word);
                try self.killRange(start, self.editor.buffer.cursor_byte, start);
                try self.appendViInputRepeatKey(.delete_previous_word);
            },
            .delete_next_word => {
                const end = nextWordEnd(self.editor.buffer.text(), self.editor.buffer.cursor_byte);
                try self.killRange(self.editor.buffer.cursor_byte, end, self.editor.buffer.cursor_byte);
                try self.appendViInputRepeatKey(.delete_next_word);
            },
            .delete_previous_argument => {
                try self.killPreviousArgument();
                try self.appendViInputRepeatKey(.delete_previous_argument);
            },
            .delete_next_argument => {
                try self.killNextArgument();
                try self.appendViInputRepeatKey(.delete_next_argument);
            },
            .delete_to_start => {
                try self.killRange(0, self.editor.buffer.cursor_byte, 0);
                try self.appendViInputRepeatKey(.delete_to_start);
            },
            .ctrl_d => {
                self.completion_menu.clear(self.allocator);
                if (self.editor.buffer.text().len == 0) {
                    self.state = .eof;
                } else {
                    self.editor.buffer.deleteNext();
                }
            },
            .clear_screen => {
                self.completion_menu.clear(self.allocator);
                self.requests.put(self.allocator, .clear_screen);
            },
            .right, .end => {
                // Same accept contract as emacs mode: only at EOL with a suggestion.
                if (self.editor.buffer.cursor_byte == self.editor.buffer.text().len and
                    try self.acceptAutosuggestion())
                {
                    return;
                }
                try self.editor.handleKey(event);
                try self.appendViInputRepeatKey(event.key);
                self.completion_menu.clear(self.allocator);
            },
            .left, .home, .word_left, .word_right, .argument_left, .argument_right => {
                if (event.key == .argument_left) {
                    try self.movePreviousArgument();
                } else if (event.key == .argument_right) {
                    try self.moveNextArgument();
                } else {
                    try self.editor.handleKey(event);
                }
                try self.appendViInputRepeatKey(event.key);
                self.completion_menu.clear(self.allocator);
            },
            .text => {
                if (event.text.len == 0) return;
                try self.editor.buffer.insertText(event.text);
                try self.appendViInputRepeatText(event.text);
                self.completion_menu.clear(self.allocator);
            },
            else => {},
        }
    }

    fn insertLiteralNewline(self: *LineSession) !void {
        try self.editor.buffer.insertText("\n");
        self.completion_menu.clear(self.allocator);
        self.clearPendingRemovableSuffix();
    }

    fn handleViReplaceKey(self: *LineSession, event: KeyEvent) !void {
        switch (event.key) {
            .escape => {
                try self.finishViInsertRepeat();
                self.enterViCommandMode();
            },
            .ctrl_c => {
                self.clearViInsertRepeatCapture();
                try self.clearInput();
            },
            .undo => try self.undoEdit(),
            .redo => try self.redoEdit(),
            .enter => {
                if (event.modifiers.shift) {
                    try self.insertLiteralNewline();
                    return self.appendViInputRepeatText("\n");
                }
                self.clearViInsertRepeatCapture();
                try self.submitInput();
            },
            .backspace => {
                self.editor.buffer.deletePrevious();
                try self.appendViInputRepeatKey(.backspace);
                self.completion_menu.clear(self.allocator);
            },
            .text => {
                if (event.text.len == 0) return;
                try self.viReplaceInputText(event.text);
                try self.appendViInputRepeatText(event.text);
                self.completion_menu.clear(self.allocator);
            },
            else => try self.handleViInsertKey(event),
        }
    }

    fn handleViCommandKey(self: *LineSession, event: KeyEvent) !void {
        switch (self.vi_pending) {
            .history_search => |direction| return self.handleViHistorySearchKey(direction, event),
            .alias => return self.handleViAliasKey(event),
            else => {},
        }

        switch (event.key) {
            .enter => return self.submitInput(),
            .ctrl_c => return self.clearInput(),
            .clear_screen => {
                self.requests.put(self.allocator, .clear_screen);
                return;
            },
            .escape => {
                self.resetViCommandPrefix();
                return;
            },
            .left => return self.applyViMotionCommand('h'),
            .right => return self.applyViMotionCommand('l'),
            .up => return self.viHistoryPrevious(self.takeViCountOrDefault(1)),
            .down => return self.viHistoryNext(self.takeViCountOrDefault(1)),
            .home => return self.applyViMotionCommand('0'),
            .end => return self.applyViMotionCommand('$'),
            .backspace => return self.applyViMotionCommand('h'),
            .ctrl_r, .redo => return self.redoEdit(),
            .undo => return self.undoEdit(),
            .ctrl_d => return,
            .text => {},
            else => return,
        }

        if (event.text.len == 0) return;
        const command = firstCodepoint(event.text) orelse return;

        switch (self.vi_pending) {
            .none => {},
            .replace => {
                const count = self.takeViCountOrDefault(1);
                if (try self.viReplaceCharacters(event.text, count) and !self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .replace = .{
                        .text = try self.allocator.dupe(u8, event.text),
                        .count = count,
                    } });
                }
                self.vi_pending = .none;
                return;
            },
            .operator => |pending| {
                if (command >= '1' and command <= '9') {
                    self.vi_count = (self.vi_count orelse 0) * 10 + (command - '0');
                    return;
                }
                if (command == '0' and self.vi_count != null) {
                    self.vi_count = (self.vi_count orelse 0) * 10;
                    return;
                }
                const motion_count = self.takeViCountOrDefault(1);
                try self.applyViOperator(pending.operator, command, multiplyViCounts(pending.count, motion_count));
                self.vi_pending = .none;
                return;
            },
            .find => |find| {
                try self.applyViFind(
                    .{ .direction = find.direction, .placement = find.placement, .char = command },
                    self.takeViCountOrDefault(1),
                );
                self.vi_pending = .none;
                return;
            },
            .alias => unreachable,
            .history_search => unreachable,
        }

        if (command >= '1' and command <= '9') {
            self.vi_count = (self.vi_count orelse 0) * 10 + (command - '0');
            return;
        }

        switch (command) {
            '0', '^', '$', '|', 'h', 'l', ' ', 'w', 'W', 'e', 'E', 'b', 'B' => try self.applyViMotionCommand(command),
            'f' => self.vi_pending = .{ .find = .{ .direction = .forward, .placement = .on_character } },
            'F' => self.vi_pending = .{ .find = .{ .direction = .backward, .placement = .on_character } },
            't' => self.vi_pending = .{ .find = .{ .direction = .forward, .placement = .before_character } },
            'T' => self.vi_pending = .{ .find = .{ .direction = .backward, .placement = .after_character } },
            ';' => if (self.vi_last_find) |find| try self.applyViFind(find, self.takeViCountOrDefault(1)),
            ',' => if (self.vi_last_find) |find|
                try self.applyViFind(reverseViFind(find), self.takeViCountOrDefault(1)),
            'i' => {
                const count = self.takeViCountOrDefault(1);
                try self.saveViUndo();
                try self.beginViInsertRepeat(.{ .insert = .{ .placement = .at_cursor, .text_count = count } });
                self.enterViInsertModeAtCursor();
            },
            'I' => {
                const count = self.takeViCountOrDefault(1);
                self.editor.buffer.cursor_byte = firstNonBlank(self.editor.buffer.text());
                try self.saveViUndo();
                try self.beginViInsertRepeat(.{ .insert = .{ .placement = .line_start, .text_count = count } });
                self.enterViInsertModeAtCursor();
            },
            'a' => {
                const count = self.takeViCountOrDefault(1);
                if (self.editor.buffer.text().len != 0) self.editor.buffer.moveRight();
                try self.saveViUndo();
                try self.beginViInsertRepeat(.{ .insert = .{ .placement = .after_cursor, .text_count = count } });
                self.enterViInsertModeAtCursor();
            },
            'A' => {
                const count = self.takeViCountOrDefault(1);
                self.editor.buffer.moveEnd();
                try self.saveViUndo();
                try self.beginViInsertRepeat(.{ .insert = .{ .placement = .line_end, .text_count = count } });
                self.enterViInsertModeAtCursor();
            },
            'R' => {
                try self.saveViUndo();
                try self.beginViInsertRepeat(.replace_session);
                try self.captureViLineUndo();
                self.vi_state = .replace;
                self.resetViCommandPrefix();
            },
            'r' => self.vi_pending = .replace,
            'x' => {
                const count = self.takeViCountOrDefault(1);
                if (try self.viDeleteForward(count) and !self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .delete_forward = count });
                }
            },
            'X' => {
                const count = self.takeViCountOrDefault(1);
                if (try self.viDeleteBackward(count) and !self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .delete_backward = count });
                }
            },
            'D' => if (try self.viDeleteRange(
                self.editor.buffer.cursor_byte,
                self.editor.buffer.text().len,
                self.editor.buffer.cursor_byte,
            ) and !self.vi_replaying_repeat) try self.setViLastRepeat(.delete_to_end),
            'C' => {
                _ = try self.viDeleteRangeWithCursorPolicy(
                    self.editor.buffer.cursor_byte,
                    self.editor.buffer.text().len,
                    self.editor.buffer.cursor_byte,
                    false,
                );
                try self.beginViInsertRepeat(.change_to_end);
                self.enterViInsertModeAtCursor();
            },
            'S' => {
                _ = try self.viClearLine(false);
                try self.beginViInsertRepeat(.clear_line_change);
                self.enterViInsertModeAtCursor();
            },
            '_' => try self.viInsertPreviousBigword(self.takeViCount()),
            'd' => self.vi_pending = .{ .operator = .{ .operator = .delete, .count = self.takeViCountOrDefault(1) } },
            'c' => self.vi_pending = .{ .operator = .{ .operator = .change, .count = self.takeViCountOrDefault(1) } },
            'y' => self.vi_pending = .{ .operator = .{ .operator = .yank, .count = self.takeViCountOrDefault(1) } },
            'Y' => try self.viYankRange(self.editor.buffer.cursor_byte, self.editor.buffer.text().len),
            'p' => {
                const count = self.takeViCountOrDefault(1);
                if (try self.viPutAfter(count) and !self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .put_after = count });
                }
            },
            'P' => {
                const count = self.takeViCountOrDefault(1);
                if (try self.viPutBefore(count) and !self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .put_before = count });
                }
            },
            'u' => try self.undoEdit(),
            'U' => try self.restoreViLineUndo(),
            '~' => {
                const count = self.takeViCountOrDefault(1);
                if (try self.viToggleCase(count) and !self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .toggle_case = count });
                }
            },
            'k', '-' => try self.viHistoryPrevious(self.takeViCountOrDefault(1)),
            'j', '+' => try self.viHistoryNext(self.takeViCountOrDefault(1)),
            'G' => try self.viHistoryOldestOrNumber(self.vi_count),
            // Open the shared history-search TUI (same menu as emacs Ctrl-R).
            // The silent POSIX /? prompt path remains available via n/N after a
            // successful search that stored a last pattern, and for pure unit
            // tests of the pattern walker.
            '/' => try self.beginViHistorySearchUi(.backward),
            '?' => try self.beginViHistorySearchUi(.forward),
            'n' => try self.repeatViHistorySearch(false),
            'N' => try self.repeatViHistorySearch(true),
            '@' => self.vi_pending = .alias,
            'v' => try self.requestExternalEditor(self.takeViCount()),
            '=' => try self.requestPathExpansion(.list),
            '\\' => try self.requestPathExpansion(.complete),
            '*' => try self.requestPathExpansion(.expand_all),
            '.' => try self.repeatViLastChange(),
            '#' => try self.viCommentAndSubmit(),
            else => self.resetViCommandPrefix(),
        }
    }

    fn submitInput(self: *LineSession) !void {
        self.completion_menu.clear(self.allocator);
        std.debug.assert(self.submitted_line == null);
        self.submitted_line = try self.allocator.dupe(u8, self.editor.buffer.text());
        self.state = .submitted;
    }

    fn requestExternalEditor(self: *LineSession, maybe_number: ?usize) !void {
        const text = if (maybe_number) |number| blk: {
            const entry = try self.historyEntryByNumber(number) orelse {
                self.resetViCommandPrefix();
                return;
            };
            defer entry.deinit(self.allocator);
            break :blk try self.allocator.dupe(u8, entry.text);
        } else try self.allocator.dupe(u8, self.editor.buffer.text());
        errdefer self.allocator.free(text);

        self.requests.put(self.allocator, .{ .external_editor = .{ .text = text, .number = maybe_number } });
        self.state = .external_editor;
        self.resetViCommandPrefix();
        self.completion_menu.clear(self.allocator);
    }

    fn requestPathExpansion(self: *LineSession, command: PathExpansionCommand) !void {
        const range = currentViBigwordRange(self.editor.buffer.text(), self.editor.buffer.cursor_byte) orelse {
            self.resetViCommandPrefix();
            return;
        };
        const word = try self.allocator.dupe(u8, self.editor.buffer.text()[range.start..range.end]);
        errdefer self.allocator.free(word);
        self.clearPathExpansionRequest();
        self.requests.put(self.allocator, .{ .path_expansion = .{
            .command = command,
            .word = word,
            .replace_start = range.start,
            .replace_end = range.end,
            .replacement_style = pathExpansionReplacementStyle(word),
        } });
        self.resetViCommandPrefix();
        self.completion_menu.clear(self.allocator);
    }

    /// Transfers ownership of the queued request to the caller.
    pub fn takePathExpansionRequest(self: *LineSession) ?PathExpansionRequest {
        return switch (self.requests.take(.path_expansion) orelse return null) {
            .path_expansion => |request| request,
            else => unreachable,
        };
    }

    fn clearPathExpansionRequest(self: *LineSession) void {
        self.requests.clear(self.allocator, .path_expansion);
    }

    /// Borrows the request and matches for the duration of the call.
    pub fn applyPathExpansion(self: *LineSession, request: PathExpansionRequest, matches: PathExpansionMatches) !bool {
        if (request.command == .list or matches.items.len == 0) return false;
        const replacement = switch (request.command) {
            .list => unreachable,
            .complete => try pathExpansionCompletionReplacement(
                self.allocator,
                request.word,
                matches.items,
                request.replacement_style,
            ),
            .expand_all => try pathExpansionAllReplacement(self.allocator, matches.items, request.replacement_style),
        };
        defer self.allocator.free(replacement);
        if (std.mem.eql(u8, request.word, replacement)) return false;

        const before = try self.snapshotBuffer();
        errdefer before.deinit(self.allocator);
        try self.saveViUndo();
        try self.editor.buffer.replaceRange(request.replace_start, request.replace_end, replacement);
        try self.commitUndo(before, .edit);
        self.completion_menu.clear(self.allocator);
        return true;
    }

    fn historyEntryByNumber(self: *LineSession, number: usize) !?HistoryView.HistoryEntry {
        if (number == 0) return null;
        if (self.history.context != null and self.history.by_number != null) {
            self.requests.put(self.allocator, .{ .history = .{ .by_number = number } });
            return null;
        }
        const index = number - 1;
        if (index >= self.history.entries.len) return null;
        return .{ .id = @intCast(index), .text = try self.allocator.dupe(u8, self.history.entries[index]) };
    }

    /// Transfers ownership of the queued request to the caller.
    pub fn takeExternalEditorRequest(self: *LineSession) ?ExternalEditorRequest {
        return switch (self.requests.take(.external_editor) orelse return null) {
            .external_editor => |request| request,
            else => unreachable,
        };
    }

    /// Copies `text` into the edit buffer and an owned submitted line.
    pub fn acceptExternalEditorResult(self: *LineSession, text: []const u8) !void {
        self.completion_menu.clear(self.allocator);
        try self.editor.buffer.replace(text);
        std.debug.assert(self.submitted_line == null);
        self.submitted_line = try self.allocator.dupe(u8, self.editor.buffer.text());
        self.state = .submitted;
    }

    pub fn resumeEditingAfterExternalEditor(self: *LineSession) void {
        if (self.state == .external_editor) self.state = .editing;
    }

    fn enterViCommandMode(self: *LineSession) void {
        self.vi_state = .command;
        self.resetViCommandPrefix();
        // Leaving insert/replace for command mode always steps onto the previous
        // grapheme (classic vi). At column 0 the cursor stays put so `i`/`a` at
        // the start of the line remain usable.
        if (self.editor.buffer.cursor_byte != 0) {
            self.editor.buffer.moveLeft();
        }
        // ziglint-ignore: Z026 best-effort undo snapshot for mode transition
        self.captureViLineUndo() catch {};
        self.completion_menu.clear(self.allocator);
    }

    fn enterViInsertModeAtCursor(self: *LineSession) void {
        self.vi_state = .insert;
        self.resetViCommandPrefix();
        // ziglint-ignore: Z026 best-effort undo snapshot for mode transition
        self.captureViLineUndo() catch {};
        self.completion_menu.clear(self.allocator);
    }

    fn resetViCommandPrefix(self: *LineSession) void {
        self.vi_count = null;
        self.vi_pending = .none;
    }

    fn takeViCountOrDefault(self: *LineSession, default: usize) usize {
        const count = self.vi_count orelse default;
        self.vi_count = null;
        return @max(count, 1);
    }

    fn takeViCount(self: *LineSession) ?usize {
        const count = self.vi_count;
        self.vi_count = null;
        return if (count) |value| @max(value, 1) else null;
    }

    fn beginViInsertRepeat(self: *LineSession, capture: ViInsertRepeatCapture) !void {
        if (self.vi_replaying_repeat) return;
        self.clearViInsertRepeatCapture();
        self.vi_insert_repeat = capture;
        self.clearViInputRepeatOps();
    }

    fn appendViInputRepeatText(self: *LineSession, text: []const u8) !void {
        if (self.vi_insert_repeat == null or self.vi_replaying_repeat) return;
        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        try self.vi_insert_repeat_ops.append(self.allocator, .{ .text = copy });
    }

    fn appendViInputRepeatKey(self: *LineSession, key: Key) !void {
        if (self.vi_insert_repeat == null or self.vi_replaying_repeat) return;
        try self.vi_insert_repeat_ops.append(self.allocator, .{ .key = key });
    }

    fn finishViInsertRepeat(self: *LineSession) !void {
        const capture = self.vi_insert_repeat orelse return;
        self.vi_insert_repeat = null;
        var input = try self.takeViInputRepeat();
        var stored = false;
        defer if (!stored) input.deinit(self.allocator);

        switch (capture) {
            .insert => |insert| {
                if (!input.changesBuffer()) return;
                var remaining = insert.text_count -| 1;
                while (remaining != 0) : (remaining -= 1) try self.applyViInputRepeat(input, .insert);
                if (!self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .insert = .{
                        .placement = insert.placement,
                        .input = input,
                        .text_count = insert.text_count,
                    } });
                    stored = true;
                }
            },
            .replace_session => {
                if (!input.changesBuffer()) return;
                if (!self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .replace_session = input });
                    stored = true;
                }
            },
            .change_to_end => {
                if (!self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .change_to_end = input });
                    stored = true;
                }
            },
            .clear_line_change => {
                if (!self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .clear_line_change = input });
                    stored = true;
                }
            },
            .operator_change => |change| {
                if (!self.vi_replaying_repeat) {
                    try self.setViLastRepeat(.{ .operator_change = .{
                        .motion_command = change.motion_command,
                        .count = change.count,
                        .input = input,
                    } });
                    stored = true;
                }
            },
        }
    }

    fn clearViInsertRepeatCapture(self: *LineSession) void {
        self.vi_insert_repeat = null;
        self.clearViInputRepeatOps();
    }

    fn clearViInputRepeatOps(self: *LineSession) void {
        for (self.vi_insert_repeat_ops.items) |op| op.deinit(self.allocator);
        self.vi_insert_repeat_ops.clearRetainingCapacity();
    }

    fn takeViInputRepeat(self: *LineSession) !ViInputRepeat {
        return .{ .ops = try self.vi_insert_repeat_ops.toOwnedSlice(self.allocator) };
    }

    fn clearViLastRepeat(self: *LineSession) void {
        if (self.vi_last_repeat) |repeat| repeat.deinit(self.allocator);
        self.vi_last_repeat = null;
    }

    fn setViLastRepeat(self: *LineSession, repeat: ViRepeat) !void {
        self.clearViLastRepeat();
        self.vi_last_repeat = repeat;
    }

    fn repeatViLastChange(self: *LineSession) !void {
        const repeat = self.vi_last_repeat orelse {
            self.resetViCommandPrefix();
            return;
        };
        const count = self.takeViCountOrDefault(1);
        self.vi_replaying_repeat = true;
        defer self.vi_replaying_repeat = false;
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) try self.applyViRepeat(repeat);
        self.resetViCommandPrefix();
    }

    fn applyViRepeat(self: *LineSession, repeat: ViRepeat) !void {
        switch (repeat) {
            .insert => |insert| {
                try self.saveViUndo();
                self.applyViInsertPlacement(insert.placement);
                var remaining = insert.text_count;
                while (remaining != 0) : (remaining -= 1) try self.applyViInputRepeat(insert.input, .insert);
                self.finishViInputRepeat(insert.input);
            },
            .replace => |replace| _ = try self.viReplaceCharacters(replace.text, replace.count),
            .replace_session => |input| {
                try self.saveViUndo();
                try self.applyViInputRepeat(input, .replace);
                self.finishViInputRepeat(input);
            },
            .delete_forward => |count| _ = try self.viDeleteForward(count),
            .delete_backward => |count| _ = try self.viDeleteBackward(count),
            .delete_to_end => _ = try self.viDeleteRange(
                self.editor.buffer.cursor_byte,
                self.editor.buffer.text().len,
                self.editor.buffer.cursor_byte,
            ),
            .change_to_end => |input| {
                _ = try self.viDeleteRangeWithCursorPolicy(
                    self.editor.buffer.cursor_byte,
                    self.editor.buffer.text().len,
                    self.editor.buffer.cursor_byte,
                    false,
                );
                try self.applyViInputRepeat(input, .insert);
                self.finishViInputRepeat(input);
            },
            .clear_line_delete => _ = try self.viClearLine(false),
            .clear_line_change => |input| {
                _ = try self.viClearLine(false);
                try self.applyViInputRepeat(input, .insert);
                self.finishViInputRepeat(input);
            },
            .operator_delete => |operator| try self.applyViOperator(.delete, operator.motion_command, operator.count),
            .operator_change => |operator| {
                const range = self.viOperatorRange(.change, operator.motion_command, operator.count) orelse return;
                if (!try self.viDeleteRangeWithCursorPolicy(
                    range.start,
                    range.end,
                    range.cursor_after_delete,
                    false,
                )) return;
                try self.applyViInputRepeat(operator.input, .insert);
                self.finishViInputRepeat(operator.input);
            },
            .put_after => |count| _ = try self.viPutAfter(count),
            .put_before => |count| _ = try self.viPutBefore(count),
            .toggle_case => |count| _ = try self.viToggleCase(count),
        }
    }

    fn applyViInsertPlacement(self: *LineSession, placement: ViInsertPlacement) void {
        switch (placement) {
            .at_cursor => {},
            .after_cursor => if (self.editor.buffer.text().len != 0) self.editor.buffer.moveRight(),
            .line_start => self.editor.buffer.cursor_byte = firstNonBlank(self.editor.buffer.text()),
            .line_end => self.editor.buffer.moveEnd(),
        }
    }

    fn applyViInputRepeat(self: *LineSession, input: ViInputRepeat, mode: ViInputRepeatMode) !void {
        for (input.ops) |op| {
            switch (op) {
                .text => |text| switch (mode) {
                    .insert => try self.editor.buffer.insertText(text),
                    .replace => try self.viReplaceInputText(text),
                },
                .key => |key| try self.applyViInputRepeatKey(key),
            }
        }
        self.completion_menu.clear(self.allocator);
    }

    fn applyViInputRepeatKey(self: *LineSession, key: Key) !void {
        switch (key) {
            .backspace => self.editor.buffer.deletePrevious(),
            .delete_previous_word => {
                const start = previousViWordStart(self.editor.buffer.text(), self.editor.buffer.cursor_byte, .word);
                try self.killRange(start, self.editor.buffer.cursor_byte, start);
            },
            .delete_next_word => {
                const end = nextWordEnd(self.editor.buffer.text(), self.editor.buffer.cursor_byte);
                try self.killRange(self.editor.buffer.cursor_byte, end, self.editor.buffer.cursor_byte);
            },
            .delete_previous_argument => try self.killPreviousArgument(),
            .delete_next_argument => try self.killNextArgument(),
            .delete_to_start => try self.killRange(0, self.editor.buffer.cursor_byte, 0),
            .left, .right, .home, .end, .word_left, .word_right => try self.editor.handleKey(.{ .key = key }),
            .argument_left => try self.movePreviousArgument(),
            .argument_right => try self.moveNextArgument(),
            else => {},
        }
    }

    fn finishViInputRepeat(self: *LineSession, input: ViInputRepeat) void {
        if (input.changesBuffer()) self.editor.buffer.moveLeft();
        self.completion_menu.clear(self.allocator);
    }

    fn applyViMotionCommand(self: *LineSession, command: u21) !void {
        const count = self.takeViCountOrDefault(1);
        const motion = viMotion(
            self.editor.buffer.text(),
            self.editor.buffer.cursor_byte,
            command,
            count,
        ) orelse return;
        self.editor.buffer.cursor_byte = motion.cursor;
    }

    fn applyViOperator(self: *LineSession, operator: ViOperator, motion_command: u21, count: usize) !void {
        if ((operator == .delete and motion_command == 'd') or
            (operator == .change and motion_command == 'c') or
            (operator == .yank and motion_command == 'y'))
        {
            switch (operator) {
                .delete => if (try self.viClearLine(false) and !self.vi_replaying_repeat)
                    try self.setViLastRepeat(.clear_line_delete),
                .change => {
                    _ = try self.viClearLine(false);
                    try self.beginViInsertRepeat(.clear_line_change);
                    self.enterViInsertModeAtCursor();
                },
                .yank => try self.viYankRange(0, self.editor.buffer.text().len),
            }
            return;
        }
        const range = self.viOperatorRange(operator, motion_command, count) orelse return;
        switch (operator) {
            .delete => if (try self.viDeleteRange(range.start, range.end, range.cursor_after_delete) and
                !self.vi_replaying_repeat)
                try self.setViLastRepeat(.{ .operator_delete = .{
                    .motion_command = motion_command,
                    .count = count,
                } }),
            .change => {
                // Change enters insert next: do not clamp past EOL so the insertion
                // point can sit after a preserved trailing blank (e.g. final-word cw).
                if (!try self.viDeleteRangeWithCursorPolicy(
                    range.start,
                    range.end,
                    range.cursor_after_delete,
                    false,
                )) return;
                try self.beginViInsertRepeat(.{ .operator_change = .{
                    .motion_command = motion_command,
                    .count = count,
                } });
                self.enterViInsertModeAtCursor();
            },
            .yank => try self.viYankRange(range.start, range.end),
        }
    }

    /// Resolve an operator motion range. Change-word skips computing exclusive w/W.
    fn viOperatorRange(
        self: *LineSession,
        operator: ViOperator,
        motion_command: u21,
        count: usize,
    ) ?ViMotionRange {
        if (operator == .change and (motion_command == 'w' or motion_command == 'W')) {
            return viChangeWordMotionRange(
                self.editor.buffer.text(),
                self.editor.buffer.cursor_byte,
                motion_command,
                count,
            );
        }
        const motion = viMotion(
            self.editor.buffer.text(),
            self.editor.buffer.cursor_byte,
            motion_command,
            count,
        ) orelse return null;
        return viOperatorMotionRange(
            self.editor.buffer.text(),
            self.editor.buffer.cursor_byte,
            operator,
            motion_command,
            count,
            motion,
        );
    }

    fn applyViFind(self: *LineSession, find: ViFindCommand, count: usize) !void {
        const cursor = viFind(self.editor.buffer.text(), self.editor.buffer.cursor_byte, find, count) orelse return;
        self.editor.buffer.cursor_byte = cursor;
        self.vi_last_find = find;
    }

    fn handleViAliasKey(self: *LineSession, event: KeyEvent) !void {
        self.vi_pending = .none;
        if (event.key != .text or event.text.len == 0) return;
        const letter = firstCodepoint(event.text) orelse return;
        self.requestViAliasLookup(letter);
    }

    fn requestViAliasLookup(self: *LineSession, letter: u21) void {
        if (!isPortableAlphabetic(letter)) return;
        if (self.vi_macro_depth >= max_vi_macro_depth) return;
        self.vi_macro_depth += 1;
        self.requests.put(self.allocator, .{ .vi_alias_lookup = letter });
    }

    pub fn takeViAliasLookupRequest(self: *LineSession) ?u21 {
        return switch (self.requests.take(.vi_alias_lookup) orelse return null) {
            .vi_alias_lookup => |letter| letter,
            else => unreachable,
        };
    }

    pub fn applyViAliasResult(self: *LineSession, letter: u21, value: ?[]const u8) !void {
        _ = letter;
        std.debug.assert(self.vi_macro_depth != 0);
        defer {
            if (!self.requests.contains(.vi_alias_lookup)) self.vi_macro_depth = 0;
        }
        const bytes = value orelse return;
        try self.feedViMacroBytes(bytes);
    }

    /// Transfers ownership of the queued request to the caller.
    pub fn takeHistoryRequest(self: *LineSession) ?HistoryRequest {
        return switch (self.requests.take(.history) orelse return null) {
            .history => |request| request,
            else => unreachable,
        };
    }

    /// Borrows `request` and consumes the deeply owned `result`.
    pub fn applyHistoryResult(self: *LineSession, request: HistoryRequest, result: HistoryResult) !void {
        switch (request) {
            .previous => |previous| try self.applyPreviousHistoryResult(
                previous.prefix,
                previous.before,
                historyResultEntry(result),
            ),
            .next => |next| try self.applyNextHistoryResult(next.prefix, next.after, historyResultEntry(result)),
            .by_number => |number| try self.applyHistoryByNumberResult(number, historyResultEntry(result)),
            .search => |search| try self.applyHistorySearchResult(search.query, search.filters, result),
            .search_next => |search| try self.applyHistorySearchResult(search.query, search.filters, result),
            .suggest => |prefix| try self.applyAutosuggestionResult(prefix, historyResultEntry(result)),
        }
    }

    fn historyResultEntry(result: HistoryResult) ?HistoryView.HistoryEntry {
        return switch (result) {
            .entry => |entry| entry,
            .entries => unreachable,
        };
    }

    fn historyResultEntries(result: HistoryResult) []HistoryView.HistoryEntry {
        return switch (result) {
            .entries => |entries| entries,
            .entry => unreachable,
        };
    }

    fn applyHistoryByNumberResult(self: *LineSession, number: usize, maybe_entry: ?HistoryView.HistoryEntry) !void {
        const entry = maybe_entry orelse {
            self.resetViCommandPrefix();
            return;
        };
        defer entry.deinit(self.allocator);
        const text = try self.allocator.dupe(u8, entry.text);
        errdefer self.allocator.free(text);
        self.requests.put(self.allocator, .{ .external_editor = .{ .text = text, .number = number } });
        self.state = .external_editor;
        self.resetViCommandPrefix();
        self.completion_menu.clear(self.allocator);
    }

    fn feedViMacro(self: *LineSession, bytes: []const u8) !void {
        if (self.vi_macro_depth >= max_vi_macro_depth) return;
        self.vi_macro_depth += 1;
        defer self.vi_macro_depth -= 1;

        try self.feedViMacroBytes(bytes);
    }

    fn feedViMacroBytes(self: *LineSession, bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len and self.state == .editing) {
            const event = viMacroKeyEvent(bytes, &index) orelse return;
            try self.handleKey(event);
        }
    }

    fn viReplaceInputText(self: *LineSession, text: []const u8) !void {
        var cursor: usize = 0;
        while (cursor < text.len) {
            const next = nextGraphemeEnd(text, cursor);
            if (next == cursor) return error.InvalidUtf8;
            try self.editor.buffer.replaceGrapheme(text[cursor..next]);
            cursor = next;
        }
        self.completion_menu.clear(self.allocator);
    }

    fn viReplaceCharacters(self: *LineSession, replacement: []const u8, count: usize) !bool {
        if (self.editor.buffer.text().len == 0) return false;
        try self.saveViUndo();
        var remaining = count;
        while (remaining != 0 and self.editor.buffer.cursor_byte < self.editor.buffer.text().len) : (remaining -= 1) {
            try self.editor.buffer.replaceGrapheme(replacement);
        }
        self.editor.buffer.moveLeft();
        self.completion_menu.clear(self.allocator);
        return remaining != count;
    }

    fn viDeleteForward(self: *LineSession, count: usize) !bool {
        if (self.editor.buffer.text().len == 0) return false;
        var end = self.editor.buffer.cursor_byte;
        var remaining = count;
        while (remaining != 0 and end < self.editor.buffer.text().len) : (remaining -= 1) {
            end = nextGraphemeEnd(self.editor.buffer.text(), end);
        }
        return self.viDeleteRange(self.editor.buffer.cursor_byte, end, self.editor.buffer.cursor_byte);
    }

    fn viDeleteBackward(self: *LineSession, count: usize) !bool {
        if (self.editor.buffer.text().len <= 1 or self.editor.buffer.cursor_byte == 0) return false;
        var start = self.editor.buffer.cursor_byte;
        var remaining = count;
        while (remaining != 0 and start != 0) : (remaining -= 1) {
            start = previousGraphemeStart(self.editor.buffer.text(), start);
        }
        return self.viDeleteRange(start, self.editor.buffer.cursor_byte, start);
    }

    /// Delete `[start, end)` and clamp the cursor for command mode when it would
    /// sit past the last character.
    fn viDeleteRange(self: *LineSession, start: usize, end: usize, cursor_after_delete: usize) !bool {
        return self.viDeleteRangeWithCursorPolicy(start, end, cursor_after_delete, true);
    }

    /// Like `viDeleteRange`, but `clamp_to_command_cursor` controls whether a
    /// post-delete end-of-line cursor is pulled left. Change operators pass
    /// false because insert may legally sit at `len`.
    fn viDeleteRangeWithCursorPolicy(
        self: *LineSession,
        start: usize,
        end: usize,
        cursor_after_delete: usize,
        clamp_to_command_cursor: bool,
    ) !bool {
        if (start >= end) return false;
        try self.saveViUndo();
        self.kill_ring.clearRetainingCapacity();
        try self.kill_ring.appendSlice(self.allocator, self.editor.buffer.text()[start..end]);
        try self.editor.buffer.replaceRange(start, end, "");
        self.editor.buffer.cursor_byte = @min(cursor_after_delete, self.editor.buffer.text().len);
        if (clamp_to_command_cursor and self.editor.buffer.cursor_byte == self.editor.buffer.text().len) {
            self.editor.buffer.moveLeft();
        }
        self.completion_menu.clear(self.allocator);
        return true;
    }

    fn viYankRange(self: *LineSession, start: usize, end: usize) !void {
        if (start >= end) return;
        self.kill_ring.clearRetainingCapacity();
        try self.kill_ring.appendSlice(self.allocator, self.editor.buffer.text()[start..end]);
    }

    fn viClearLine(self: *LineSession, insert_after: bool) !bool {
        const changed = self.editor.buffer.text().len != 0;
        try self.saveViUndo();
        self.kill_ring.clearRetainingCapacity();
        try self.kill_ring.appendSlice(self.allocator, self.editor.buffer.text());
        try self.editor.buffer.replace("");
        if (insert_after) self.enterViInsertModeAtCursor();
        self.completion_menu.clear(self.allocator);
        return changed;
    }

    fn viPutAfter(self: *LineSession, count: usize) !bool {
        if (self.kill_ring.items.len == 0) return false;
        try self.saveViUndo();
        if (self.editor.buffer.text().len != 0) self.editor.buffer.moveRight();
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) try self.editor.buffer.insertText(self.kill_ring.items);
        self.editor.buffer.moveLeft();
        self.completion_menu.clear(self.allocator);
        return true;
    }

    fn viPutBefore(self: *LineSession, count: usize) !bool {
        if (self.kill_ring.items.len == 0) return false;
        try self.saveViUndo();
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) try self.editor.buffer.insertText(self.kill_ring.items);
        self.editor.buffer.moveLeft();
        self.completion_menu.clear(self.allocator);
        return true;
    }

    fn viToggleCase(self: *LineSession, count: usize) !bool {
        if (self.editor.buffer.text().len == 0) return false;
        try self.saveViUndo();
        const start_cursor = self.editor.buffer.cursor_byte;
        var remaining = count;
        while (remaining != 0 and self.editor.buffer.cursor_byte < self.editor.buffer.text().len) : (remaining -= 1) {
            const cursor = self.editor.buffer.cursor_byte;
            const byte = self.editor.buffer.text()[cursor];
            if (std.ascii.isAlphabetic(byte)) {
                self.editor.buffer.bytes.items[cursor] = if (std.ascii.isLower(byte))
                    std.ascii.toUpper(byte)
                else
                    std.ascii.toLower(byte);
            }
            if (self.editor.buffer.cursor_byte == self.editor.buffer.text().len - 1) break;
            self.editor.buffer.moveRight();
        }
        self.completion_menu.clear(self.allocator);
        return self.editor.buffer.cursor_byte != start_cursor or count != 0;
    }

    fn viHistoryPrevious(self: *LineSession, count: usize) !void {
        if (self.history_index == null) {
            self.saved_edit.clearRetainingCapacity();
            try self.saved_edit.appendSlice(self.allocator, self.editor.buffer.text());
        }
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) {
            if (try self.queryPreviousHistory("")) |entry| {
                defer entry.deinit(self.allocator);
                self.history_index = entry.id;
                try self.editor.buffer.replace(entry.text);
            } else if (self.history.entries.len != 0) {
                const start: usize = if (self.history_index) |index| @intCast(index) else self.history.entries.len;
                if (start == 0) break;
                const index = start - 1;
                self.history_index = @intCast(index);
                try self.editor.buffer.replace(self.history.entries[index]);
            }
        }
        self.editor.buffer.moveHome();
        // ziglint-ignore: Z026 best-effort undo snapshot for history navigation
        self.captureViLineUndo() catch {};
        self.completion_menu.clear(self.allocator);
    }

    fn viHistoryNext(self: *LineSession, count: usize) !void {
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) {
            const index = self.history_index orelse break;
            if (try self.queryNextHistory("", index)) |entry| {
                defer entry.deinit(self.allocator);
                self.history_index = entry.id;
                try self.editor.buffer.replace(entry.text);
            } else if (self.history.context != null) {
                self.history_index = null;
                try self.editor.buffer.replace(self.saved_edit.items);
                self.saved_edit.clearRetainingCapacity();
                break;
            } else {
                const next_index = @as(usize, @intCast(index)) + 1;
                if (next_index >= self.history.entries.len) {
                    self.history_index = null;
                    try self.editor.buffer.replace(self.saved_edit.items);
                    self.saved_edit.clearRetainingCapacity();
                    break;
                }
                self.history_index = @intCast(next_index);
                try self.editor.buffer.replace(self.history.entries[next_index]);
            }
        }
        self.editor.buffer.moveHome();
        // ziglint-ignore: Z026 best-effort undo snapshot for history navigation
        self.captureViLineUndo() catch {};
        self.completion_menu.clear(self.allocator);
    }

    fn viHistoryOldestOrNumber(self: *LineSession, maybe_number: ?usize) !void {
        const index = if (maybe_number) |number| if (number == 0) return else number - 1 else 0;
        self.vi_count = null;
        if (index >= self.history.entries.len) return;
        if (self.history_index == null) {
            self.saved_edit.clearRetainingCapacity();
            try self.saved_edit.appendSlice(self.allocator, self.editor.buffer.text());
        }
        self.history_index = @intCast(index);
        try self.editor.buffer.replace(self.history.entries[index]);
        self.editor.buffer.moveHome();
        // ziglint-ignore: Z026 best-effort undo snapshot for history navigation
        self.captureViLineUndo() catch {};
        self.completion_menu.clear(self.allocator);
    }

    fn beginViHistorySearch(self: *LineSession, direction: ViHistoryDirection) void {
        self.vi_history_search_query.clearRetainingCapacity();
        self.vi_pending = .{ .history_search = direction };
        self.completion_menu.clear(self.allocator);
    }

    /// Interactive vi history search: reuse the emacs-style match menu so the
    /// user sees candidates while typing instead of a silent pending state.
    fn beginViHistorySearchUi(self: *LineSession, direction: ViHistoryDirection) !void {
        self.resetViCommandPrefix();
        try self.beginHistorySearch(direction);
        // Leave command mode so escape/cancel returns to a normal editing
        // surface; accept still leaves the matched line ready to edit.
        self.vi_state = .insert;
    }

    fn handleViHistorySearchKey(self: *LineSession, direction: ViHistoryDirection, event: KeyEvent) !void {
        switch (event.key) {
            .enter => {
                const count = self.takeViCountOrDefault(1);
                const typed_pattern = self.vi_history_search_query.items;
                if (typed_pattern.len == 0 and self.vi_last_history_search_pattern.items.len == 0) {
                    self.vi_history_search_query.clearRetainingCapacity();
                    self.vi_pending = .none;
                    return;
                }
                const pattern = if (typed_pattern.len == 0) self.vi_last_history_search_pattern.items else blk: {
                    self.vi_last_history_search_pattern.clearRetainingCapacity();
                    try self.vi_last_history_search_pattern.appendSlice(self.allocator, typed_pattern);
                    self.vi_last_history_search_direction = direction;
                    break :blk self.vi_last_history_search_pattern.items;
                };
                self.vi_history_search_query.clearRetainingCapacity();
                self.vi_pending = .none;
                try self.applyViHistoryPatternSearch(direction, pattern, count);
            },
            .escape => {
                self.vi_history_search_query.clearRetainingCapacity();
                self.resetViCommandPrefix();
            },
            .ctrl_c => {
                self.vi_history_search_query.clearRetainingCapacity();
                self.resetViCommandPrefix();
                try self.clearInput();
            },
            .backspace => {
                if (self.vi_history_search_query.items.len != 0) {
                    const start = previousCodepointStart(
                        self.vi_history_search_query.items,
                        self.vi_history_search_query.items.len,
                    );
                    self.vi_history_search_query.items.len = start;
                }
            },
            .text => {
                if (event.text.len != 0) try self.vi_history_search_query.appendSlice(self.allocator, event.text);
            },
            else => {},
        }
    }

    fn repeatViHistorySearch(self: *LineSession, reverse: bool) !void {
        const last_direction = self.vi_last_history_search_direction orelse {
            self.resetViCommandPrefix();
            return;
        };
        if (self.vi_last_history_search_pattern.items.len == 0) {
            self.resetViCommandPrefix();
            return;
        }
        const direction = if (reverse) reverseViHistoryDirection(last_direction) else last_direction;
        try self.applyViHistoryPatternSearch(
            direction,
            self.vi_last_history_search_pattern.items,
            self.takeViCountOrDefault(1),
        );
    }

    fn applyViHistoryPatternSearch(
        self: *LineSession,
        direction: ViHistoryDirection,
        pattern: []const u8,
        count: usize,
    ) !void {
        if (pattern.len == 0) return;
        if (self.history_index == null) {
            self.saved_edit.clearRetainingCapacity();
            try self.saved_edit.appendSlice(self.allocator, self.editor.buffer.text());
        }

        var cursor = self.history_index;
        var selected: ?HistoryView.HistoryEntry = null;
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) {
            const entry = try self.findViHistoryPatternMatch(direction, pattern, cursor) orelse break;
            if (selected) |old| old.deinit(self.allocator);
            cursor = entry.id;
            selected = entry;
        }
        const entry = selected orelse return;
        defer entry.deinit(self.allocator);
        self.history_index = entry.id;
        try self.editor.buffer.replace(entry.text);
        self.editor.buffer.moveHome();
        // ziglint-ignore: Z026 best-effort undo snapshot for history search
        self.captureViLineUndo() catch {};
        self.completion_menu.clear(self.allocator);
    }

    fn findViHistoryPatternMatch(
        self: *LineSession,
        direction: ViHistoryDirection,
        pattern: []const u8,
        cursor: ?i64,
    ) !?HistoryView.HistoryEntry {
        if (self.history.context != null) {
            switch (direction) {
                .backward => if (self.history.previous != null)
                    return self.queryViHistoryPatternMatch(direction, pattern, cursor),
                .forward => if (self.history.next != null)
                    return self.queryViHistoryPatternMatch(direction, pattern, cursor),
            }
        }
        return self.findStaticViHistoryPatternMatch(direction, pattern, cursor);
    }

    fn queryViHistoryPatternMatch(
        self: *LineSession,
        direction: ViHistoryDirection,
        pattern: []const u8,
        start_cursor: ?i64,
    ) !?HistoryView.HistoryEntry {
        var cursor = start_cursor;
        while (true) {
            const entry = switch (direction) {
                .backward => try self.queryPreviousHistoryBefore("", cursor),
                .forward => if (cursor) |after| try self.queryNextHistory("", after) else null,
            } orelse return null;
            cursor = entry.id;
            if (viHistoryPatternMatches(pattern, entry.text)) return entry;
            entry.deinit(self.allocator);
        }
    }

    fn findStaticViHistoryPatternMatch(
        self: LineSession,
        direction: ViHistoryDirection,
        pattern: []const u8,
        cursor: ?i64,
    ) !?HistoryView.HistoryEntry {
        const index = switch (direction) {
            .backward => self.findPreviousHistoryPatternMatch(
                staticHistoryStart(self.history.entries.len, cursor),
                pattern,
            ),
            .forward => if (cursor) |after|
                self.findNextHistoryPatternMatch(@as(usize, @intCast(after)) + 1, pattern)
            else
                null,
        } orelse return null;
        return .{ .id = @intCast(index), .text = try self.allocator.dupe(u8, self.history.entries[index]) };
    }

    fn findPreviousHistoryPatternMatch(self: LineSession, start: usize, pattern: []const u8) ?usize {
        var index = start;
        while (index > 0) {
            index -= 1;
            if (self.historyEntryPatternMatches(index, pattern)) return index;
        }
        return null;
    }

    fn findNextHistoryPatternMatch(self: LineSession, start: usize, pattern: []const u8) ?usize {
        var index = start;
        while (index < self.history.entries.len) : (index += 1) {
            if (self.historyEntryPatternMatches(index, pattern)) return index;
        }
        return null;
    }

    fn historyEntryPatternMatches(self: LineSession, index: usize, pattern: []const u8) bool {
        if (!viHistoryPatternMatches(pattern, self.history.entries[index])) return false;
        const entry = self.history.entries[index];
        for (self.history.entries[index + 1 ..]) |newer| {
            if (!std.mem.eql(u8, newer, entry)) continue;
            if (viHistoryPatternMatches(pattern, newer)) return false;
        }
        return true;
    }

    fn viInsertPreviousBigword(self: *LineSession, maybe_count: ?usize) !void {
        const entry = try self.previousViHistoryEntry() orelse return;
        defer entry.deinit(self.allocator);
        const bigword = viHistoryBigword(entry.text, maybe_count) orelse return;

        try self.saveViUndo();
        if (self.editor.buffer.text().len != 0) {
            if (self.editor.buffer.cursor_byte < self.editor.buffer.text().len) self.editor.buffer.moveRight();
            try self.editor.buffer.insertText(" ");
        }
        try self.editor.buffer.insertText(bigword);
        self.vi_state = .insert;
        self.resetViCommandPrefix();
        self.completion_menu.clear(self.allocator);
    }

    fn previousViHistoryEntry(self: *LineSession) !?HistoryView.HistoryEntry {
        if (self.history.context != null and self.history.previous != null) {
            return self.queryPreviousHistoryBefore("", self.history_index);
        }
        const index = self.findPreviousHistoryMatch(
            staticHistoryStart(self.history.entries.len, self.history_index),
            "",
        ) orelse return null;
        return .{ .id = @intCast(index), .text = try self.allocator.dupe(u8, self.history.entries[index]) };
    }

    fn viCommentAndSubmit(self: *LineSession) !void {
        try self.saveViUndo();
        try self.editor.buffer.replaceRange(0, 0, "#");
        try self.submitInput();
    }

    fn saveViUndo(self: *LineSession) !void {
        const snapshot = try self.snapshotBuffer();
        if (self.vi_undo) |old| old.deinit(self.allocator);
        self.vi_undo = snapshot;
    }

    fn captureViLineUndo(self: *LineSession) !void {
        if (self.vi_line_undo != null) return;
        self.vi_line_undo = try self.snapshotBuffer();
    }

    fn snapshotBuffer(self: LineSession) !BufferSnapshot {
        return .{
            .text = try self.allocator.dupe(u8, self.editor.buffer.text()),
            .cursor_byte = self.editor.buffer.cursor_byte,
        };
    }

    fn snapshotsEqual(a: BufferSnapshot, b: BufferSnapshot) bool {
        return a.cursor_byte == b.cursor_byte and std.mem.eql(u8, a.text, b.text);
    }

    fn restoreSnapshot(self: *LineSession, snapshot: BufferSnapshot) !void {
        try self.editor.buffer.replace(snapshot.text);
        self.editor.buffer.cursor_byte = @min(snapshot.cursor_byte, self.editor.buffer.text().len);
        self.completion_menu.clear(self.allocator);
        self.clearPendingRemovableSuffix();
    }

    fn clearUndoHistory(self: *LineSession) void {
        for (self.undo_stack.items) |entry| entry.deinit(self.allocator);
        self.undo_stack.clearRetainingCapacity();
        self.clearRedoHistory();
    }

    fn clearRedoHistory(self: *LineSession) void {
        for (self.redo_stack.items) |entry| entry.deinit(self.allocator);
        self.redo_stack.clearRetainingCapacity();
    }

    fn commitUndo(self: *LineSession, before: BufferSnapshot, kind: UndoKind) !void {
        const after = try self.snapshotBuffer();
        errdefer after.deinit(self.allocator);
        if (std.mem.eql(u8, before.text, after.text)) {
            before.deinit(self.allocator);
            after.deinit(self.allocator);
            return;
        }

        self.clearRedoHistory();
        if (undoKindCoalesces(kind) and self.undo_stack.items.len != 0) {
            const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (last.kind == kind and snapshotsEqual(last.after, before)) {
                last.after.deinit(self.allocator);
                last.after = after;
                before.deinit(self.allocator);
                return;
            }
        }
        try self.undo_stack.append(self.allocator, .{ .before = before, .after = after, .kind = kind });
    }

    fn undoKindCoalesces(kind: UndoKind) bool {
        return switch (kind) {
            .insertion, .delete_backward, .delete_forward => true,
            .edit => false,
        };
    }

    fn undoEdit(self: *LineSession) !void {
        if (self.undo_stack.items.len == 0) return;
        const entry = self.undo_stack.pop().?;
        errdefer entry.deinit(self.allocator);
        try self.restoreSnapshot(entry.before);
        try self.redo_stack.append(self.allocator, entry);
    }

    fn redoEdit(self: *LineSession) !void {
        if (self.redo_stack.items.len == 0) return;
        const entry = self.redo_stack.pop().?;
        errdefer entry.deinit(self.allocator);
        try self.restoreSnapshot(entry.after);
        try self.undo_stack.append(self.allocator, entry);
    }

    fn restoreViUndo(self: *LineSession) !void {
        const snapshot = self.vi_undo orelse return;
        try self.editor.buffer.replace(snapshot.text);
        self.editor.buffer.cursor_byte = @min(snapshot.cursor_byte, self.editor.buffer.text().len);
        self.vi_undo = null;
        snapshot.deinit(self.allocator);
        self.completion_menu.clear(self.allocator);
    }

    fn restoreViLineUndo(self: *LineSession) !void {
        const snapshot = self.vi_line_undo orelse return;
        try self.editor.buffer.replace(snapshot.text);
        self.editor.buffer.cursor_byte = @min(snapshot.cursor_byte, self.editor.buffer.text().len);
        self.vi_line_undo = null;
        snapshot.deinit(self.allocator);
        self.completion_menu.clear(self.allocator);
    }

    fn clearViUndo(self: *LineSession) void {
        if (self.vi_undo) |snapshot| snapshot.deinit(self.allocator);
        self.vi_undo = null;
    }

    fn clearViLineUndo(self: *LineSession) void {
        if (self.vi_line_undo) |snapshot| snapshot.deinit(self.allocator);
        self.vi_line_undo = null;
    }

    pub fn cancel(self: *LineSession) !void {
        if (self.state != .editing and self.state != .history_search) return;
        self.completion_menu.clear(self.allocator);
        try self.editor.buffer.replace("");
        self.state = .canceled;
    }

    fn clearInput(self: *LineSession) !void {
        if (self.state != .editing) return;
        self.completion_menu.clear(self.allocator);
        if (self.editor.buffer.text().len == 0) return;
        try self.editor.buffer.replace("");
    }

    pub fn takeClearScreenRequest(self: *LineSession) bool {
        return self.requests.take(.clear_screen) != null;
    }

    pub fn invalidatePrompt(self: *LineSession) void {
        self.requests.put(self.allocator, .refresh_prompt);
    }

    pub fn takePromptInvalidation(self: *LineSession) bool {
        return self.requests.take(.refresh_prompt) != null;
    }

    /// Copies the prompt bytes before replacing the session-owned prompt.
    pub fn replacePrompt(self: *LineSession, prompt: Prompt) !void {
        const bytes = try copyPromptBytes(self.allocator, prompt.bytes);
        self.allocator.free(self.prompt.bytes);
        self.prompt = .{
            .bytes = bytes,
            .visible_width = prompt.visible_width,
        };
        self.requests.clear(self.allocator, .refresh_prompt);
    }

    /// Copies the prompt bytes before replacing the session-owned prompt.
    pub fn replaceRightPrompt(self: *LineSession, prompt: Prompt) !void {
        const bytes = try copyPromptBytes(self.allocator, prompt.bytes);
        if (self.right_prompt.bytes.len != 0) self.allocator.free(self.right_prompt.bytes);
        self.right_prompt = .{
            .bytes = bytes,
            .visible_width = prompt.visible_width,
        };
    }

    /// Borrows `application`; the caller remains responsible for its `deinit`.
    pub fn applyCompletion(self: *LineSession, application: completion.Application) !void {
        switch (application) {
            .edit => |edit| {
                const before = try self.snapshotBuffer();
                errdefer before.deinit(self.allocator);
                try self.editor.buffer.applyCompletionEdit(edit);
                try self.commitUndo(before, .edit);
                try self.setPendingRemovableSuffix(edit);
                self.completion_menu.clear(self.allocator);
                self.completion_flash = null;
            },
            .ambiguous => |candidates| {
                if (candidates.len == 0) {
                    self.completion_menu.clear(self.allocator);
                    self.completion_flash = completionFlashForCursor(
                        self.editor.buffer.text(),
                        self.editor.buffer.cursor_byte,
                    );
                } else {
                    try self.completion_menu.replace(self.allocator, candidates);
                    self.completion_flash = null;
                }
            },
            .none => {
                self.completion_menu.clear(self.allocator);
                self.completion_flash = completionFlashForCursor(
                    self.editor.buffer.text(),
                    self.editor.buffer.cursor_byte,
                );
            },
        }
    }

    pub fn hasCompletionMenu(self: LineSession) bool {
        return self.completion_menu.isOpen();
    }

    pub fn hasCompletionFlash(self: LineSession) bool {
        return self.completion_flash != null;
    }

    pub fn beginPaste(self: *LineSession) void {
        self.paste_depth += 1;
    }

    pub fn endPaste(self: *LineSession) void {
        if (self.paste_depth != 0) self.paste_depth -= 1;
    }

    pub fn handlePaste(self: *LineSession, text: []const u8) !void {
        if (self.state != .editing and self.state != .history_search) return;
        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(self.allocator);
        const pasted = try normalizePastedText(self.allocator, &normalized, text);
        try self.editor.buffer.insertText(pasted);
        self.completion_menu.clear(self.allocator);
        if (self.state == .history_search) {
            if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshCurrentHistorySearch(null);
        }
    }

    pub fn handleMouseClick(self: *LineSession, click: MouseClick) !bool {
        if (self.state != .editing and self.state != .history_search) return false;
        if (try self.handleCompletionMenuClick(click)) return true;
        if (click.row >= click.frame.input_line_count) return false;

        const cursor = cursorByteForPromptCell(
            self.prompt,
            self.editor.buffer.text(),
            click.row,
            click.col,
            click.width,
            click.width_method,
        );
        if (self.editor.buffer.cursor_byte == cursor) return true;
        self.editor.buffer.cursor_byte = cursor;
        if (self.state == .editing) self.completion_menu.clear(self.allocator);
        self.clearPendingRemovableSuffix();
        return true;
    }

    fn handleCompletionMenuClick(self: *LineSession, click: MouseClick) !bool {
        const max_rows = menu.candidateRows(click.height, click.menu_presentation);
        switch (self.state) {
            .editing => {
                const count = self.completion_menu.candidates.len;
                if (count == 0) return false;
                const window = menu.visibleWindow(
                    count,
                    self.completion_menu.selected,
                    self.completion_menu.window_start,
                    max_rows,
                );
                const menu_start = menuStartRow(click.frame, window, count, click.menu_presentation);
                if (click.row < menu_start or click.row >= menu_start + (window.end - window.start)) return false;
                self.completion_menu.selectIndex(window.start + click.row - menu_start);
                if (self.completion_menu.selectedCandidate()) |candidate| try self.applyCompletionCandidate(candidate);
                return true;
            },
            .history_search => {
                const count = @max(self.history_search_matches.items.len, 1);
                const window = menu.visibleWindow(count, self.history_search_selected, 0, max_rows);
                const menu_start = menuStartRow(click.frame, window, count, click.menu_presentation);
                if (click.row < menu_start or click.row >= menu_start + (window.end - window.start)) return false;
                self.history_search_selected = window.start + click.row - menu_start;
                return true;
            },
            else => return false,
        }
    }

    /// Returns a deeply owned frame that the caller must deinitialize.
    pub fn renderFrame(self: *LineSession, allocator: std.mem.Allocator, options: RenderOptions) !Frame {
        var render_options = options;
        var suggestion_suffix: ?[]const u8 = null;
        defer if (suggestion_suffix) |suffix| allocator.free(suffix);
        render_options.prompt = self.prompt;
        render_options.right_prompt = if (self.state == .editing or self.state == .history_search)
            self.right_prompt
        else
            .{ .bytes = "" };
        render_options.cursor_shape = self.cursorShape();
        render_options.completion_menu = self.completion_menu.candidates;
        render_options.completion_selection = self.completion_menu.selected;
        render_options.completion_window_start = self.completion_menu.visibleWindowStart(
            render_options.menuCandidateRows(),
        );
        render_options.completion_flash = self.completion_flash;
        self.completion_flash = null;
        if (self.state == .history_search) {
            if (historySearchStatusLine(self.history_search_filters)) |line| render_options.status_line = line;
            var history_candidates: std.ArrayList(completion.Candidate) = .empty;
            defer history_candidates.deinit(allocator);
            var styled_labels: std.ArrayList([]const u8) = .empty;
            var history_label_width: usize = 0;
            defer {
                for (styled_labels.items) |label| allocator.free(label);
                styled_labels.deinit(allocator);
            }
            if (self.history_search_matches.items.len != 0) {
                for (self.history_search_matches.items) |entry| {
                    const label = try styledHistorySearchLabel(
                        allocator,
                        entry.text,
                        self.history_search_query.items,
                        render_options.theme,
                    );
                    try styled_labels.append(allocator, label);
                    history_label_width = @max(history_label_width, visibleWidth(label, render_options.width_method));
                    const description = try historySearchDescription(allocator, self.history.now, entry.when);
                    history_candidates.append(allocator, .{
                        .value = entry.text,
                        .display = label,
                        .description = description,
                        .kind = .plain,
                        .replace_start = 0,
                        .replace_end = self.editor.buffer.text().len,
                    }) catch |err| {
                        if (description) |owned| allocator.free(owned);
                        return err;
                    };
                    if (description) |owned| {
                        styled_labels.append(allocator, owned) catch |err| {
                            allocator.free(owned);
                            return err;
                        };
                    }
                }
            } else {
                history_label_width = visibleWidth("No history matches", render_options.width_method);
                try history_candidates.append(allocator, .{
                    .value = self.history_search_query.items,
                    .display = "No history matches",
                    .kind = .plain,
                    .replace_start = 0,
                    .replace_end = self.editor.buffer.text().len,
                });
            }
            render_options.completion_menu = history_candidates.items;
            render_options.completion_selection = self.history_search_selected;
            render_options.completion_window_start = 0;
            render_options.completion_label_width = @min(
                history_label_width,
                @as(usize, @intCast(render_options.width)) -| 3,
            );
            return frameFromLine(allocator, self.editor, render_options);
        } else if (self.state == .editing) {
            // Ghost suggestions are editing aids; an accepted line must show
            // only the text that actually runs.
            if (self.autosuggestion) |suggestion| {
                const text = self.editor.buffer.text();
                if (std.mem.startsWith(u8, suggestion.text, text) and renderableInlineText(suggestion.text)) {
                    suggestion_suffix = try allocator.dupe(u8, suggestion.text[text.len..]);
                    render_options.suggestion = suggestion_suffix.?;
                }
            }
        }
        return frameFromLine(allocator, self.editor, render_options);
    }

    fn cursorShape(self: LineSession) CursorShape {
        if (self.state != .editing) return .default;
        if (self.editing_mode != .vi) return .default;
        return switch (self.vi_state) {
            .insert => .beam,
            .replace => .underline,
            .command => .block,
        };
    }

    /// Returns serialized frame bytes owned by `allocator`.
    pub fn render(self: *LineSession, allocator: std.mem.Allocator, options: RenderOptions) ![]const u8 {
        var frame = try self.renderFrame(allocator, options);
        defer frame.deinit(allocator);
        return serializeFullFrame(allocator, frame, options.synchronized_output);
    }

    /// Transfers ownership of the submitted line to the caller.
    pub fn takeSubmittedLine(self: *LineSession) ?[]const u8 {
        const line = self.submitted_line orelse return null;
        self.submitted_line = null;
        return line;
    }

    fn historyPrevious(self: *LineSession) !void {
        const prefix = try self.historyPrefix();
        if (try self.queryPreviousHistory(prefix)) |_| return;
        try self.applyStaticPreviousHistory(prefix);
    }

    fn applyPreviousHistoryResult(
        self: *LineSession,
        prefix: []const u8,
        before: ?i64,
        maybe_entry: ?HistoryView.HistoryEntry,
    ) !void {
        _ = before;
        if (maybe_entry) |entry| {
            defer entry.deinit(self.allocator);
            self.history_index = entry.id;
            try self.editor.buffer.replace(entry.text);
            self.completion_menu.clear(self.allocator);
            return;
        }
        try self.applyStaticPreviousHistory(prefix);
    }

    fn applyStaticPreviousHistory(self: *LineSession, prefix: []const u8) !void {
        if (self.history.entries.len == 0) return;
        const start: usize = if (self.history_index) |index| @intCast(index) else self.history.entries.len;
        const index = self.findPreviousHistoryMatch(start, prefix) orelse return;
        self.history_index = @intCast(index);
        try self.editor.buffer.replace(self.history.entries[index]);
        self.completion_menu.clear(self.allocator);
    }

    fn historyNext(self: *LineSession) !void {
        const index = self.history_index orelse return;
        const prefix = self.saved_edit.items;
        if (try self.queryNextHistory(prefix, index)) |_| return;
        try self.applyStaticNextHistory(prefix, index);
    }

    fn applyNextHistoryResult(
        self: *LineSession,
        prefix: []const u8,
        after: i64,
        maybe_entry: ?HistoryView.HistoryEntry,
    ) !void {
        if (maybe_entry) |entry| {
            defer entry.deinit(self.allocator);
            self.history_index = entry.id;
            try self.editor.buffer.replace(entry.text);
            self.completion_menu.clear(self.allocator);
            return;
        }
        try self.applyStaticNextHistory(prefix, after);
    }

    fn applyStaticNextHistory(self: *LineSession, prefix: []const u8, index: i64) !void {
        if (self.history.context != null) {
            self.history_index = null;
            try self.editor.buffer.replace(self.saved_edit.items);
            self.saved_edit.clearRetainingCapacity();
            self.completion_menu.clear(self.allocator);
            return;
        }
        const next_index = self.findNextHistoryMatch(@as(usize, @intCast(index)) + 1, prefix) orelse {
            self.history_index = null;
            try self.editor.buffer.replace(self.saved_edit.items);
            self.saved_edit.clearRetainingCapacity();
            self.completion_menu.clear(self.allocator);
            return;
        };
        self.history_index = @intCast(next_index);
        try self.editor.buffer.replace(self.history.entries[next_index]);
        self.completion_menu.clear(self.allocator);
    }

    fn queryPreviousHistory(self: *LineSession, prefix: []const u8) !?HistoryView.HistoryEntry {
        return self.queryPreviousHistoryBefore(prefix, self.history_index);
    }

    fn queryPreviousHistoryBefore(self: *LineSession, prefix: []const u8, before: ?i64) !?HistoryView.HistoryEntry {
        if (self.history.context == null or self.history.previous == null) return null;
        self.requests.put(self.allocator, .{ .history = .{ .previous = .{
            .prefix = try self.allocator.dupe(u8, prefix),
            .before = before,
        } } });
        return null;
    }

    fn queryNextHistory(self: *LineSession, prefix: []const u8, after: i64) !?HistoryView.HistoryEntry {
        if (self.history.context == null or self.history.next == null) return null;
        self.requests.put(self.allocator, .{ .history = .{ .next = .{
            .prefix = try self.allocator.dupe(u8, prefix),
            .after = after,
        } } });
        return null;
    }

    fn beginHistorySearch(self: *LineSession, direction: ViHistoryDirection) !void {
        self.history_search_query.clearRetainingCapacity();
        self.history_search_original.clearRetainingCapacity();
        try self.history_search_original.appendSlice(self.allocator, self.editor.buffer.text());
        try self.history_search_query.appendSlice(self.allocator, self.editor.buffer.text());
        self.history_search_filters = .{};
        self.history_search_direction = direction;
        self.state = .history_search;
        try self.refreshCurrentHistorySearch(null);
        self.completion_menu.clear(self.allocator);
    }

    fn handleHistorySearchKey(self: *LineSession, event: KeyEvent) !void {
        if (try self.handleHistorySearchFilterKey(event)) return;
        switch (event.key) {
            .enter => {
                if (self.selectedHistorySearchMatch()) |entry| {
                    try self.editor.buffer.replace(entry.text);
                    try self.rememberAcceptedViHistorySearch();
                }
                self.finishHistorySearch();
            },
            .tab => if (event.modifiers.shift)
                self.selectPreviousHistorySearchMatch()
            else
                self.selectNextHistorySearchMatch(),
            .escape, .ctrl_c => {
                try self.editor.buffer.replace(self.history_search_original.items);
                self.finishHistorySearch();
            },
            .ctrl_r, .down => self.selectNextHistorySearchMatch(),
            .up => self.selectPreviousHistorySearchMatch(),
            .backspace => {
                self.editor.buffer.deletePrevious();
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshCurrentHistorySearch(null);
            },
            .delete => {
                self.editor.buffer.deleteNext();
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshCurrentHistorySearch(null);
            },
            .text => {
                if (event.text.len == 0) return;
                try self.editor.handleKey(event);
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshCurrentHistorySearch(null);
            },
            .left, .right, .home, .end, .word_left, .word_right => try self.editor.handleKey(event),
            .argument_left => self.editor.buffer.cursor_byte = try previousShellArgumentStart(
                self.allocator,
                self.editor.buffer.text(),
                self.editor.buffer.cursor_byte,
            ),
            .argument_right => self.editor.buffer.cursor_byte = try nextShellArgumentEnd(
                self.allocator,
                self.editor.buffer.text(),
                self.editor.buffer.cursor_byte,
            ),
            .delete_to_start => {
                self.editor.buffer.deleteToStart();
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshCurrentHistorySearch(null);
            },
            .delete_to_end => {
                self.editor.buffer.deleteToEnd();
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshCurrentHistorySearch(null);
            },
            .delete_previous_word => {
                self.editor.buffer.deletePreviousWord();
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshCurrentHistorySearch(null);
            },
            .delete_next_word => {
                self.editor.buffer.deleteNextWord();
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshCurrentHistorySearch(null);
            },
            .delete_previous_argument => {
                const start = try previousShellArgumentStart(
                    self.allocator,
                    self.editor.buffer.text(),
                    self.editor.buffer.cursor_byte,
                );
                try self.editor.buffer.replaceRange(start, self.editor.buffer.cursor_byte, "");
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshCurrentHistorySearch(null);
            },
            .delete_next_argument => {
                const end = try nextShellArgumentEnd(
                    self.allocator,
                    self.editor.buffer.text(),
                    self.editor.buffer.cursor_byte,
                );
                try self.editor.buffer.replaceRange(self.editor.buffer.cursor_byte, end, "");
                if (try self.syncHistorySearchQueryFromBuffer()) try self.refreshCurrentHistorySearch(null);
            },
            else => {},
        }
    }

    fn handleHistorySearchFilterKey(self: *LineSession, event: KeyEvent) !bool {
        if (!event.modifiers.alt or event.key != .text or event.text.len == 0) return false;
        const command = firstCodepoint(event.text) orelse return false;
        switch (command) {
            'c', 'C' => self.history_search_filters.cwd = !self.history_search_filters.cwd,
            's', 'S' => self.history_search_filters.successful = !self.history_search_filters.successful,
            't', 'T' => self.history_search_filters.session = !self.history_search_filters.session,
            else => return false,
        }
        try self.refreshCurrentHistorySearch(null);
        return true;
    }

    fn syncHistorySearchQueryFromBuffer(self: *LineSession) !bool {
        if (std.mem.eql(u8, self.history_search_query.items, self.editor.buffer.text())) return false;
        self.history_search_query.clearRetainingCapacity();
        try self.history_search_query.appendSlice(self.allocator, self.editor.buffer.text());
        return true;
    }

    fn refreshCurrentHistorySearch(self: *LineSession, cursor: ?i64) !void {
        return switch (self.history_search_direction) {
            .backward => self.refreshHistorySearch(cursor),
            .forward => self.refreshHistorySearchNext(cursor),
        };
    }

    fn refreshHistorySearch(self: *LineSession, before: ?i64) !void {
        self.clearHistorySearchMatches();
        self.history_search_selected = 0;
        self.requests.put(self.allocator, .{ .history = .{ .search = .{
            .query = try self.allocator.dupe(u8, self.history_search_query.items),
            .filters = self.history_search_filters,
            .before = before,
        } } });
    }

    fn refreshHistorySearchNext(self: *LineSession, after: ?i64) !void {
        self.clearHistorySearchMatches();
        self.history_search_selected = 0;
        self.requests.put(self.allocator, .{ .history = .{ .search_next = .{
            .query = try self.allocator.dupe(u8, self.history_search_query.items),
            .filters = self.history_search_filters,
            .after = after,
        } } });
    }

    fn applyHistorySearchResult(
        self: *LineSession,
        query: []const u8,
        filters: HistorySearchFilters,
        result: HistoryResult,
    ) !void {
        if (!std.mem.eql(u8, query, self.history_search_query.items) or filters != self.history_search_filters) {
            result.deinit(self.allocator);
            return;
        }
        const entries = historyResultEntries(result);
        errdefer {
            for (entries) |entry| entry.deinit(self.allocator);
            self.allocator.free(entries);
        }
        try self.history_search_matches.appendSlice(self.allocator, entries);
        self.allocator.free(entries);
    }

    fn selectedHistorySearchMatch(self: LineSession) ?HistoryView.HistoryEntry {
        if (self.history_search_matches.items.len == 0) return null;
        return self.history_search_matches.items[
            @min(self.history_search_selected, self.history_search_matches.items.len - 1)
        ];
    }

    fn selectNextHistorySearchMatch(self: *LineSession) void {
        if (self.history_search_matches.items.len == 0) return;
        self.history_search_selected = @min(
            self.history_search_selected + 1,
            self.history_search_matches.items.len - 1,
        );
    }

    fn selectPreviousHistorySearchMatch(self: *LineSession) void {
        if (self.history_search_matches.items.len == 0) return;
        self.history_search_selected = if (self.history_search_selected == 0) 0 else self.history_search_selected - 1;
    }

    fn clearHistorySearchMatches(self: *LineSession) void {
        for (self.history_search_matches.items) |entry| entry.deinit(self.allocator);
        self.history_search_matches.clearRetainingCapacity();
    }

    fn rememberAcceptedViHistorySearch(self: *LineSession) !void {
        if (self.editing_mode != .vi or self.history_search_query.items.len == 0) return;
        self.vi_last_history_search_pattern.clearRetainingCapacity();
        try self.vi_last_history_search_pattern.appendSlice(self.allocator, self.history_search_query.items);
        self.vi_last_history_search_direction = self.history_search_direction;
    }

    fn finishHistorySearch(self: *LineSession) void {
        self.clearHistorySearchMatches();
        self.history_search_query.clearRetainingCapacity();
        self.history_search_original.clearRetainingCapacity();
        self.state = .editing;
    }

    pub fn requestAutosuggestion(self: *LineSession) !void {
        self.clearAutosuggestion();
        if (self.state != .editing) return;
        if (self.completion_menu.isOpen()) return;
        if (self.editor.buffer.cursor_byte != self.editor.buffer.text().len) return;
        if (self.editor.buffer.text().len == 0) return;
        self.requests.put(self.allocator, .{ .history = .{
            .suggest = try self.allocator.dupe(u8, self.editor.buffer.text()),
        } });
    }

    fn applyAutosuggestionResult(self: *LineSession, prefix: []const u8, maybe_entry: ?HistoryView.HistoryEntry) !void {
        self.clearAutosuggestion();
        const entry = maybe_entry orelse return;
        errdefer entry.deinit(self.allocator);
        if (!std.mem.eql(u8, prefix, self.editor.buffer.text())) {
            entry.deinit(self.allocator);
            return;
        }
        if (!std.mem.startsWith(u8, entry.text, prefix)) {
            entry.deinit(self.allocator);
            return;
        }
        self.autosuggestion = entry;
    }

    fn clearAutosuggestion(self: *LineSession) void {
        if (self.autosuggestion) |entry| entry.deinit(self.allocator);
        self.autosuggestion = null;
    }

    fn acceptAutosuggestion(self: *LineSession) !bool {
        if (self.autosuggestion) |suggestion| {
            if (!renderableInlineText(suggestion.text)) return false;
            const before = try self.snapshotBuffer();
            errdefer before.deinit(self.allocator);
            try self.editor.buffer.replace(suggestion.text);
            try self.commitUndo(before, .edit);
            self.clearAutosuggestion();
            self.completion_menu.clear(self.allocator);
            return true;
        }
        return false;
    }

    fn historyPrefix(self: *LineSession) ![]const u8 {
        if (self.history_index == null) {
            self.saved_edit.clearRetainingCapacity();
            try self.saved_edit.appendSlice(self.allocator, self.editor.buffer.text());
        }
        return self.saved_edit.items;
    }

    fn findPreviousHistoryMatch(self: LineSession, start: usize, prefix: []const u8) ?usize {
        var index = start;
        while (index > 0) {
            index -= 1;
            if (self.historyEntryMatches(index, prefix)) return index;
        }
        return null;
    }

    fn findNextHistoryMatch(self: LineSession, start: usize, prefix: []const u8) ?usize {
        var index = start;
        while (index < self.history.entries.len) : (index += 1) {
            if (self.historyEntryMatches(index, prefix)) return index;
        }
        return null;
    }

    fn historyEntryMatches(self: LineSession, index: usize, prefix: []const u8) bool {
        const entry = self.history.entries[index];
        if (prefix.len != 0 and !std.mem.startsWith(u8, entry, prefix)) return false;
        return self.isNewestMatchingCommand(index, prefix);
    }

    fn isNewestMatchingCommand(self: LineSession, index: usize, prefix: []const u8) bool {
        const entry = self.history.entries[index];
        for (self.history.entries[index + 1 ..]) |newer| {
            if (prefix.len != 0 and !std.mem.startsWith(u8, newer, prefix)) continue;
            if (std.mem.eql(u8, newer, entry)) return false;
        }
        return true;
    }

    fn applyCompletionCandidate(self: *LineSession, candidate: completion.Candidate) !void {
        const replacement = try completion.candidateEditReplacement(self.allocator, candidate);
        defer self.allocator.free(replacement);
        const suffix = try completion.candidateEditSuffix(self.allocator, candidate);
        defer if (suffix) |owned_suffix| self.allocator.free(owned_suffix);
        const edit: completion.Edit = .{
            .replace_start = candidate.replace_start,
            .replace_end = candidate.replace_end,
            .replacement = replacement,
            .suffix = suffix,
            .removable_suffix = candidate.removable_suffix,
            .append_space = candidate.append_space,
        };
        const before = try self.snapshotBuffer();
        errdefer before.deinit(self.allocator);
        try self.editor.buffer.applyCompletionEdit(.{
            .replace_start = candidate.replace_start,
            .replace_end = candidate.replace_end,
            .replacement = replacement,
            .suffix = suffix,
            .removable_suffix = candidate.removable_suffix,
            .append_space = candidate.append_space,
        });
        try self.commitUndo(before, .edit);
        try self.setPendingRemovableSuffix(edit);
        self.completion_menu.clear(self.allocator);
    }

    fn setPendingRemovableSuffix(self: *LineSession, edit: completion.Edit) !void {
        self.clearPendingRemovableSuffix();
        if (!edit.removable_suffix) return;
        const suffix = edit.suffix orelse return;
        if (suffix.len == 0 or edit.replacement.len < suffix.len) return;
        const suffix_end = edit.replace_start + edit.replacement.len;
        const suffix_start = suffix_end - suffix.len;
        if (suffix_end > self.editor.buffer.text().len) return;
        if (!std.mem.eql(u8, self.editor.buffer.text()[suffix_start..suffix_end], suffix)) return;
        self.pending_removable_suffix = .{
            .start = suffix_start,
            .end = suffix_end,
            .text = try self.allocator.dupe(u8, suffix),
        };
    }

    fn clearPendingRemovableSuffix(self: *LineSession) void {
        if (self.pending_removable_suffix) |pending| pending.deinit(self.allocator);
        self.pending_removable_suffix = null;
    }

    fn consumePendingRemovableSuffix(self: *LineSession, event: KeyEvent) !bool {
        const pending = self.pending_removable_suffix orelse return false;
        if (pending.end > self.editor.buffer.text().len or
            self.editor.buffer.cursor_byte != pending.end or
            !std.mem.eql(u8, self.editor.buffer.text()[pending.start..pending.end], pending.text))
        {
            self.clearPendingRemovableSuffix();
            return false;
        }
        if (event.key == .text and event.text.len != 0) {
            if (std.mem.eql(u8, event.text, pending.text)) {
                self.clearPendingRemovableSuffix();
                self.completion_menu.clear(self.allocator);
                return true;
            }
            if (isRemovableSuffixTerminator(event)) {
                try self.removePendingRemovableSuffix();
                return false;
            }
            self.clearPendingRemovableSuffix();
            return false;
        }
        if (isRemovableSuffixTerminator(event)) {
            try self.removePendingRemovableSuffix();
            return false;
        }
        self.clearPendingRemovableSuffix();
        return false;
    }

    fn removePendingRemovableSuffix(self: *LineSession) !void {
        const pending = self.pending_removable_suffix orelse return;
        const start = pending.start;
        const end = pending.end;
        self.clearPendingRemovableSuffix();
        try self.editor.buffer.replaceRange(start, end, "");
    }

    fn movePreviousArgument(self: *LineSession) !void {
        self.editor.buffer.cursor_byte = try previousShellArgumentStart(
            self.allocator,
            self.editor.buffer.text(),
            self.editor.buffer.cursor_byte,
        );
        self.completion_menu.clear(self.allocator);
    }

    fn moveNextArgument(self: *LineSession) !void {
        self.editor.buffer.cursor_byte = try nextShellArgumentEnd(
            self.allocator,
            self.editor.buffer.text(),
            self.editor.buffer.cursor_byte,
        );
        self.completion_menu.clear(self.allocator);
    }

    fn killPreviousArgument(self: *LineSession) !void {
        const start = try previousShellArgumentStart(
            self.allocator,
            self.editor.buffer.text(),
            self.editor.buffer.cursor_byte,
        );
        try self.killRange(start, self.editor.buffer.cursor_byte, start);
    }

    fn killNextArgument(self: *LineSession) !void {
        const end = try nextShellArgumentEnd(
            self.allocator,
            self.editor.buffer.text(),
            self.editor.buffer.cursor_byte,
        );
        try self.killRange(self.editor.buffer.cursor_byte, end, self.editor.buffer.cursor_byte);
    }

    fn killRange(self: *LineSession, start: usize, end: usize, cursor_byte: usize) !void {
        if (start == end) return;
        self.kill_ring.clearRetainingCapacity();
        try self.kill_ring.appendSlice(self.allocator, self.editor.buffer.text()[start..end]);
        try self.editor.buffer.replaceRange(start, end, "");
        self.editor.buffer.cursor_byte = cursor_byte;
        self.completion_menu.clear(self.allocator);
        self.clearPendingRemovableSuffix();
    }
};

fn isRemovableSuffixTerminator(event: KeyEvent) bool {
    return switch (event.key) {
        .enter => true,
        .text => std.mem.eql(u8, event.text, " ") or std.mem.eql(u8, event.text, "\n"),
        else => false,
    };
}

fn previousShellArgumentStart(allocator: std.mem.Allocator, text: []const u8, cursor_byte: usize) !usize {
    std.debug.assert(cursor_byte <= text.len);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const src: shell_source.Source = .{ .id = 0, .kind = .interactive, .name = "editor", .text = text };
    const tokens = try shell_lexer.lex(arena.allocator(), src);
    var start: ?usize = null;
    for (tokens) |tok| {
        if (tok.kind == .eof) break;
        if (!isShellArgumentToken(tok.kind)) continue;
        if (tok.span.start < cursor_byte) start = tok.span.start;
    }
    return start orelse cursor_byte;
}

fn nextShellArgumentEnd(allocator: std.mem.Allocator, text: []const u8, cursor_byte: usize) !usize {
    std.debug.assert(cursor_byte <= text.len);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const src: shell_source.Source = .{ .id = 0, .kind = .interactive, .name = "editor", .text = text };
    const tokens = try shell_lexer.lex(arena.allocator(), src);
    for (tokens) |tok| {
        if (tok.kind == .eof) break;
        if (!isShellArgumentToken(tok.kind)) continue;
        if (tok.span.end > cursor_byte) return tok.span.end;
    }
    return cursor_byte;
}

fn isShellArgumentToken(kind: shell_token.Kind) bool {
    return kind == .word;
}

const historySearchDescription = history_mod.description;
pub const relativeAge = history_mod.relativeAge;

fn normalizePastedText(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\r') == null) return text;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\r') {
            try buffer.append(allocator, '\n');
            if (index + 1 < text.len and text[index + 1] == '\n') index += 1;
        } else {
            try buffer.append(allocator, text[index]);
        }
    }
    return buffer.items;
}

fn styledHistorySearchLabel(
    allocator: std.mem.Allocator,
    text: []const u8,
    query: []const u8,
    theme: UiTheme,
) ![]const u8 {
    const display_text = try singleLineHistorySearchText(allocator, text);
    defer allocator.free(display_text);

    const positions = (try completion.fuzzyMatchPositions(allocator, display_text, query)) orelse
        return try allocator.dupe(u8, display_text);
    defer allocator.free(positions);
    if (positions.len == 0) return allocator.dupe(u8, display_text);

    var label: std.ArrayList(u8) = .empty;
    errdefer label.deinit(allocator);
    var position_index: usize = 0;
    for (display_text, 0..) |byte, index| {
        if (position_index < positions.len and positions[position_index] == index) {
            try appendUiStyleStart(allocator, &label, theme.match);
            try label.append(allocator, byte);
            try appendUiStyleEnd(allocator, &label, theme.match);
            position_index += 1;
        } else {
            try label.append(allocator, byte);
        }
    }
    return label.toOwnedSlice(allocator);
}

fn singleLineHistorySearchText(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var label: std.ArrayList(u8) = .empty;
    errdefer label.deinit(allocator);
    for (text) |byte| {
        try label.append(allocator, switch (byte) {
            '\r', '\n' => ' ',
            else => byte,
        });
    }
    return label.toOwnedSlice(allocator);
}

pub fn renderLine(allocator: std.mem.Allocator, editor: Editor, options: RenderOptions) ![]const u8 {
    return render.renderLine(allocator, .{
        .text = editor.buffer.text(),
        .cursor_byte = editor.buffer.cursor_byte,
    }, options);
}

pub fn frameFromLine(allocator: std.mem.Allocator, editor: Editor, options: RenderOptions) !Frame {
    return render.frameFromInput(allocator, .{
        .text = editor.buffer.text(),
        .cursor_byte = editor.buffer.cursor_byte,
    }, options);
}

fn menuStartRow(frame: Frame, window: menu.Window, count: usize, presentation: MenuPresentation) usize {
    const candidate_rows = window.end - window.start;
    const summary_rows: usize = if (presentation.scroll_summary.visible and
        (window.start != 0 or window.end != count)) 1 else 0;
    return frame.lines.len -| (candidate_rows + summary_rows);
}

fn historySearchStatusLine(filters: HistorySearchFilters) ?[]const u8 {
    const bits: u3 = @bitCast(filters);
    if (bits == 0) return null;
    if (filters.cwd and filters.successful and filters.session) return "history filters: cwd, successful, session";
    if (filters.cwd and filters.successful) return "history filters: cwd, successful";
    if (filters.cwd and filters.session) return "history filters: cwd, session";
    if (filters.successful and filters.session) return "history filters: successful, session";
    if (filters.cwd) return "history filters: cwd";
    if (filters.successful) return "history filters: successful";
    if (filters.session) return "history filters: session";
    unreachable;
}

fn cursorByteForPromptCell(
    prompt: Prompt,
    text: []const u8,
    row: usize,
    col: usize,
    width: u16,
    width_method: vaxis.gwidth.Method,
) usize {
    const wrap_width = @max(@as(usize, @intCast(width)), 1);
    const prompt_width = if (prompt.visible_width) |visible| @as(usize, @intCast(visible)) else visibleWidth(
        prompt.bytes,
        width_method,
    );
    var current_row = prompt_width / wrap_width;
    var current_col = prompt_width % wrap_width;
    if (row < current_row or (row == current_row and col <= current_col)) return 0;

    var i: usize = 0;
    while (i < text.len) {
        var iter = vaxis.unicode.graphemeIterator(text[i..]);
        const grapheme = iter.next() orelse break;
        const start = i + grapheme.start;
        const end = start + grapheme.len;
        if (text[start] == '\n') {
            if (row < current_row or (row == current_row and col >= current_col)) return start;
            current_row += 1;
            current_col = 0;
            i = end;
            continue;
        }

        const width_delta = vaxis.gwidth.gwidth(text[start..end], width_method);
        if (current_col != 0 and current_col + width_delta > wrap_width) {
            if (row == current_row and col >= current_col) return start;
            current_row += 1;
            current_col = 0;
        }
        if (row < current_row or (row == current_row and col <= current_col)) return start;
        if (row == current_row and col < current_col + width_delta) return start;
        current_col += width_delta;
        i = end;
        if (current_col == wrap_width) {
            current_row += 1;
            current_col = 0;
        }
    }
    return text.len;
}

test "line session yanks last killed text" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git checkout main" });
    try session.handleKey(.{ .key = .word_left });
    try session.handleKey(.{ .key = .delete_to_end });
    try std.testing.expectEqualStrings("git checkout ", session.editor.buffer.text());
    try session.handleKey(.{ .key = .yank });
    try std.testing.expectEqualStrings("git checkout main", session.editor.buffer.text());
}

test "line session yanks killed previous and next words" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git checkout main" });
    try session.handleKey(.{ .key = .word_left });
    try session.handleKey(.{ .key = .delete_previous_word });
    try std.testing.expectEqualStrings("git main", session.editor.buffer.text());
    try session.handleKey(.{ .key = .yank });
    try std.testing.expectEqualStrings("git checkout main", session.editor.buffer.text());
    try session.handleKey(.{ .key = .home });
    try session.handleKey(.{ .key = .delete_next_word });
    try std.testing.expectEqualStrings(" checkout main", session.editor.buffer.text());
    try session.handleKey(.{ .key = .yank });
    try std.testing.expectEqualStrings("git checkout main", session.editor.buffer.text());
}

test "line session moves and kills shell arguments" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "cmd \"two words\" tail" });
    try session.handleKey(.{ .key = .argument_left });
    try std.testing.expectEqual(@as(usize, "cmd \"two words\" ".len), session.editor.buffer.cursor_byte);
    try session.handleKey(.{ .key = .argument_left });
    try std.testing.expectEqual(@as(usize, "cmd ".len), session.editor.buffer.cursor_byte);

    try session.handleKey(.{ .key = .argument_right });
    try std.testing.expectEqual(@as(usize, "cmd \"two words\"".len), session.editor.buffer.cursor_byte);
    try session.handleKey(.{ .key = .delete_previous_argument });
    try std.testing.expectEqualStrings("cmd  tail", session.editor.buffer.text());
    try session.handleKey(.{ .key = .yank });
    try std.testing.expectEqualStrings("cmd \"two words\" tail", session.editor.buffer.text());

    session.editor.buffer.cursor_byte = "cmd ".len;
    try session.handleKey(.{ .key = .delete_next_argument });
    try std.testing.expectEqualStrings("cmd  tail", session.editor.buffer.text());
}

test "line session emacs control keys edit command line" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = keyFromVaxis('f', .{ .ctrl = true }) });
    try session.handleKey(.{ .key = .text, .text = "abcd ef" });
    try session.handleKey(.{ .key = keyFromVaxis('a', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 0), session.editor.buffer.cursor_byte);
    try session.handleKey(.{ .key = keyFromVaxis('f', .{ .ctrl = true }) });
    try session.handleKey(.{ .key = keyFromVaxis('f', .{ .ctrl = true }) });
    try session.handleKey(.{ .key = keyFromVaxis('t', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("bacd ef", session.editor.buffer.text());
    try session.handleKey(.{ .key = keyFromVaxis('k', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("ba", session.editor.buffer.text());
    try session.handleKey(.{ .key = keyFromVaxis('y', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("bacd ef", session.editor.buffer.text());
    try session.handleKey(.{ .key = keyFromVaxis('e', .{ .ctrl = true }) });
    try session.handleKey(.{ .key = keyFromVaxis('b', .{ .ctrl = true }) });
    try session.handleKey(.{ .key = keyFromVaxis('w', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("bacd f", session.editor.buffer.text());
    try session.handleKey(.{ .key = keyFromVaxis('u', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("f", session.editor.buffer.text());
}

test "line session undo coalesces consecutive text insertions and supports redo" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "a" });
    try session.handleKey(.{ .key = .text, .text = "b" });
    try session.handleKey(.{ .key = .text, .text = "c" });

    try std.testing.expectEqualStrings("abc", session.editor.buffer.text());
    try session.handleKey(.{ .key = .undo });
    try std.testing.expectEqualStrings("", session.editor.buffer.text());
    try session.handleKey(.{ .key = .redo });
    try std.testing.expectEqualStrings("abc", session.editor.buffer.text());
}

test "line session undo coalesces consecutive character deletes" {
    var backward = try LineSession.init(std.testing.allocator, "");
    defer backward.deinit();

    try backward.handleKey(.{ .key = .text, .text = "a" });
    try backward.handleKey(.{ .key = .text, .text = "b" });
    try backward.handleKey(.{ .key = .text, .text = "c" });
    try backward.handleKey(.{ .key = .backspace });
    try backward.handleKey(.{ .key = .backspace });

    try std.testing.expectEqualStrings("a", backward.editor.buffer.text());
    try backward.handleKey(.{ .key = .undo });
    try std.testing.expectEqualStrings("abc", backward.editor.buffer.text());
    try backward.handleKey(.{ .key = .undo });
    try std.testing.expectEqualStrings("", backward.editor.buffer.text());

    var forward = try LineSession.init(std.testing.allocator, "");
    defer forward.deinit();
    try forward.editor.buffer.replace("abc");
    forward.editor.buffer.moveHome();

    try forward.handleKey(.{ .key = .delete });
    try forward.handleKey(.{ .key = .delete });

    try std.testing.expectEqualStrings("c", forward.editor.buffer.text());
    try forward.handleKey(.{ .key = .undo });
    try std.testing.expectEqualStrings("abc", forward.editor.buffer.text());
}

test "line session undo restores completion edits as one step" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();
    try session.editor.buffer.replace("git st");

    try session.applyCompletion(.{ .edit = .{
        .replace_start = "git ".len,
        .replace_end = "git st".len,
        .replacement = "status",
    } });

    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try session.handleKey(.{ .key = .undo });
    try std.testing.expectEqualStrings("git st", session.editor.buffer.text());
    try session.handleKey(.{ .key = .redo });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
}

test "line session undo restores accepted autosuggestions as one step" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "g" });
    try session.handleKey(.{ .key = .text, .text = "i" });
    try session.handleKey(.{ .key = .text, .text = "t" });
    try session.applyAutosuggestionResult("git", .{
        .id = 1,
        .text = try std.testing.allocator.dupe(u8, "git status"),
    });

    try session.handleKey(.{ .key = .right });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try session.handleKey(.{ .key = .undo });
    try std.testing.expectEqualStrings("git", session.editor.buffer.text());
    try session.handleKey(.{ .key = .undo });
    try std.testing.expectEqualStrings("", session.editor.buffer.text());
}

test "vi insert mode accepts autosuggestion with right and end at eol" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "" }, .{}, .vi);
    defer session.deinit();
    try std.testing.expectEqual(ViState.insert, session.vi_state);

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.applyAutosuggestionResult("git", .{
        .id = 1,
        .text = try std.testing.allocator.dupe(u8, "git status"),
    });
    try session.handleKey(.{ .key = .right });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try std.testing.expect(session.autosuggestion == null);

    try session.handleKey(.{ .key = .undo });
    try std.testing.expectEqualStrings("git", session.editor.buffer.text());
    try session.applyAutosuggestionResult("git", .{
        .id = 2,
        .text = try std.testing.allocator.dupe(u8, "git status --short"),
    });
    try session.handleKey(.{ .key = .end });
    try std.testing.expectEqualStrings("git status --short", session.editor.buffer.text());
}

test "vi insert mode right at mid-line does not accept autosuggestion" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "" }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git " });
    try session.handleKey(.{ .key = .text, .text = "st" });
    try session.applyAutosuggestionResult("git st", .{
        .id = 1,
        .text = try std.testing.allocator.dupe(u8, "git status"),
    });
    // Cursor mid-line: left twice from "git st"
    try session.handleKey(.{ .key = .left });
    try session.handleKey(.{ .key = .left });
    try std.testing.expectEqual(@as(usize, "git ".len), session.editor.buffer.cursor_byte);
    try session.handleKey(.{ .key = .right });
    try std.testing.expectEqualStrings("git st", session.editor.buffer.text());
    try std.testing.expect(session.autosuggestion != null);
    try std.testing.expectEqual(@as(usize, "git s".len), session.editor.buffer.cursor_byte);
}

test "line session records clear screen requests" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = .clear_screen });
    try std.testing.expect(session.takeClearScreenRequest());
    try std.testing.expect(!session.takeClearScreenRequest());
}

test "editor handles readline movement and deletion keys" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    try editor.handleKey(.{ .key = .text, .text = "git checkout main" });
    try editor.handleKey(.{ .key = .word_left });
    try std.testing.expectEqual(@as(usize, "git checkout ".len), editor.buffer.cursor_byte);
    try editor.handleKey(.{ .key = .delete_to_end });
    try std.testing.expectEqualStrings("git checkout ", editor.buffer.text());
    try editor.handleKey(.{ .key = .delete_previous_word });
    try std.testing.expectEqualStrings("git ", editor.buffer.text());
    try std.testing.expectEqual(@as(usize, "git ".len), editor.buffer.cursor_byte);
}

test "line session applies completion edit" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();
    try session.editor.buffer.replace("git st");

    const application: completion.Application = .{ .edit = .{
        .replace_start = 4,
        .replace_end = 6,
        .replacement = "status",
        .append_space = true,
    } };
    try session.applyCompletion(application);

    try std.testing.expectEqualStrings("git status ", session.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, "git status ".len), session.editor.buffer.cursor_byte);
}

test "line session leaves ambiguous and empty completions unchanged" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();
    try session.editor.buffer.replace("git ");

    try session.applyCompletion(.{ .ambiguous = &.{} });
    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
    try session.applyCompletion(.none);
    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
}

test "line session flashes current word when completion has empty handled candidates" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git add ");

    try session.applyCompletion(.{ .ambiguous = &.{} });
    const flashed = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(flashed);
    try std.testing.expect(std.mem.indexOf(u8, flashed, "git \x1b[30m\x1b[47madd\x1b[49m\x1b[39m ") != null);
}

test "line session flashes current word when completion has no candidates" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git zzz");

    try session.applyCompletion(.none);
    const flashed = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(flashed);
    try std.testing.expect(std.mem.indexOf(u8, flashed, "git \x1b[30m\x1b[47mzzz\x1b[49m\x1b[39m") != null);

    const normal = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(normal);
    try std.testing.expect(std.mem.indexOf(u8, normal, "\x1b[30m\x1b[47mzzz") == null);
}

test "line session renders ambiguous completion menu" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git che");
    var candidates = [_]completion.Candidate{
        .{
            .value = "checkout",
            .description = "switch branches",
            .kind = .subcommand,
            .replace_start = 4,
            .replace_end = 7,
        },
        .{
            .value = "cherry-pick",
            .display = "cherry",
            .description = "apply commits",
            .kind = .subcommand,
            .replace_start = 4,
            .replace_end = 7,
        },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "checkout") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cherry") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "switch branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "apply commits") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[1m\x1b[36m❯") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[90mswitch branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "git che") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[2A") != null);
}

test "completion menu styles candidates by kind" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "--help", .description = "show help", .kind = .option, .replace_start = 0, .replace_end = 0 },
        .{ .value = "$HOME", .description = "home directory", .kind = .variable, .replace_start = 0, .replace_end = 0 },
        .{
            .value = "src/",
            .description = "source directory",
            .kind = .directory,
            .replace_start = 0,
            .replace_end = 0,
        },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[36m--help") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[35m$HOME") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[34msrc/") != null);
}

test "ui style parser supports colors and attributes" {
    const spec = "fg=bright-blue,bg=#112233,ul=dashed,ul_color=red,bold,dim,italic,reverse,strike";
    const style = parseUiStyle(spec) orelse return error.MissingStyle;
    // ziglint-ignore: Z010 expectEqual cannot infer the anonymous struct type from peer resolution
    try std.testing.expectEqual(vaxis.Color{ .index = 12 }, style.fg.?);
    try std.testing.expectEqual(vaxis.Color.rgbFromUint(0x112233), style.bg.?);
    try std.testing.expectEqual(UnderlineStyle.dashed, style.ul);
    // ziglint-ignore: Z010 expectEqual cannot infer the anonymous struct type from peer resolution
    try std.testing.expectEqual(vaxis.Color{ .index = 1 }, style.ul_color.?);
    try std.testing.expect(style.bold);
    try std.testing.expect(style.dim);
    try std.testing.expect(style.italic);
    try std.testing.expect(style.reverse);
    try std.testing.expect(style.strike);
    try std.testing.expect(parseUiStyle("fg=nope") == null);
}

test "completion menu renders paired option spellings" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{.{
        .value = "--interactive",
        .description = "add modified contents interactively",
        .kind = .option,
        .option = .{ .long = "interactive", .short = "i" },
        .replace_start = 0,
        .replace_end = 0,
    }};
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--interactive,-i") != null);
}

test "completion menu does not render trailing scrollbar border" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "three", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 3 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "┃") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "│") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "showing 1-1 of 3") != null);
}

test "completion menu selection accepts selected candidate" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git che");
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = .enter });

    try std.testing.expectEqualStrings("git cherry-pick ", session.editor.buffer.text());
    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.candidates.len);
}

test "mouse click moves cursor within rendered input" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("abcdef");

    var frame = try session.renderFrame(std.testing.allocator, .{ .width = 80, .height = 24 });
    defer frame.deinit(std.testing.allocator);
    const handled = try session.handleMouseClick(.{
        .row = 0,
        .col = 5,
        .frame = frame,
        .width = 80,
        .height = 24,
        .width_method = .unicode,
    });

    try std.testing.expect(handled);
    try std.testing.expectEqual(@as(usize, 3), session.editor.buffer.cursor_byte);
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.candidates.len);
}

test "mouse click maps rendered newlines and wide grapheme wrapping" {
    var newline = try LineSession.init(std.testing.allocator, "");
    defer newline.deinit();
    try newline.editor.buffer.replace("a\nb");
    var newline_frame = try newline.renderFrame(std.testing.allocator, .{ .width = 80, .height = 24 });
    defer newline_frame.deinit(std.testing.allocator);
    try std.testing.expect(try newline.handleMouseClick(.{
        .row = 1,
        .col = 0,
        .frame = newline_frame,
        .width = 80,
        .height = 24,
        .width_method = .unicode,
    }));
    try std.testing.expectEqual(@as(usize, 2), newline.editor.buffer.cursor_byte);

    var wrapped = try LineSession.init(std.testing.allocator, "");
    defer wrapped.deinit();
    try wrapped.editor.buffer.replace("ab界c");
    var wrapped_frame = try wrapped.renderFrame(std.testing.allocator, .{ .width = 3, .height = 24 });
    defer wrapped_frame.deinit(std.testing.allocator);
    try std.testing.expect(try wrapped.handleMouseClick(.{
        .row = 1,
        .col = 2,
        .frame = wrapped_frame,
        .width = 3,
        .height = 24,
        .width_method = .unicode,
    }));
    try std.testing.expectEqual("ab界".len, wrapped.editor.buffer.cursor_byte);
}

test "mouse click accepts completion menu candidate" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git che");
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    var frame = try session.renderFrame(std.testing.allocator, .{ .width = 80, .height = 24 });
    defer frame.deinit(std.testing.allocator);
    const handled = try session.handleMouseClick(.{
        .row = 2,
        .col = 2,
        .frame = frame,
        .width = 80,
        .height = 24,
        .width_method = .unicode,
    });

    try std.testing.expect(handled);
    try std.testing.expectEqualStrings("git cherry-pick ", session.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.candidates.len);
}

test "mouse click selects history search match without accepting it" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);

    var frame = try session.renderFrame(std.testing.allocator, .{ .width = 80, .height = 24 });
    defer frame.deinit(std.testing.allocator);
    try std.testing.expect(try session.handleMouseClick(.{
        .row = 2,
        .col = 2,
        .frame = frame,
        .width = 80,
        .height = 24,
        .width_method = .unicode,
    }));

    try std.testing.expectEqual(@as(usize, 1), session.history_search_selected);
    try std.testing.expectEqualStrings("git", session.editor.buffer.text());
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);
}

test "completion menu acceptance uses insertion text while rendering display text" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("cat two\\ w");
    var candidates = [_]completion.Candidate{
        .{
            .value = "two words",
            .display = "two words",
            .insert = "two\\ words",
            .kind = .file,
            .replace_start = 4,
            .replace_end = "cat two\\ w".len,
        },
        .{
            .value = "two ways",
            .display = "two ways",
            .insert = "two\\ ways",
            .kind = .file,
            .replace_start = 4,
            .replace_end = "cat two\\ w".len,
        },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "two words") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "two\\ words") == null);

    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .enter });

    try std.testing.expectEqualStrings("cat two\\ words ", session.editor.buffer.text());
    try std.testing.expectEqual(LineSession.State.editing, session.state);
}

test "accepting completion clears previously rendered menu rows" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git che");
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const menu_frame = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_frame);
    try std.testing.expect(std.mem.indexOf(u8, menu_frame, "checkout") != null);

    try session.handleKey(.{ .key = .tab });
    try session.handleKey(.{ .key = .enter });
    const accepted_frame = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(accepted_frame);
    try std.testing.expect(std.mem.indexOf(u8, accepted_frame, "git checkout ") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_frame, "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_frame, "\x1b[2A") == null);
}

test "completion menu selection clamps with arrow keys" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
}

test "completion menu moves selection with tab and shift tab" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git ");
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "switch", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "stash", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
    };

    try session.applyCompletion(.{ .ambiguous = &candidates });
    try std.testing.expect(session.hasCompletionMenu());
    try std.testing.expect(session.completion_menu.selectedCandidate() == null);

    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = .tab, .modifiers = .{ .shift = true } });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 2), session.completion_menu.selected);
    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 2), session.completion_menu.selected);
    try session.handleKey(.{ .key = keyFromVaxis('p', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = keyFromVaxis('p', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);

    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
    try session.handleKey(.{ .key = .enter });
    try std.testing.expectEqualStrings("git status ", session.editor.buffer.text());
}

test "completion menu remains open across text edits and modifier-only events" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git s");
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 5 },
        .{ .value = "switch", .kind = .subcommand, .replace_start = 4, .replace_end = 5 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .text, .text = "t" });
    try std.testing.expectEqualStrings("git st", session.editor.buffer.text());
    try std.testing.expect(session.hasCompletionMenu());
    try session.handleKey(.{ .key = .text, .text = "" });
    try std.testing.expectEqualStrings("git st", session.editor.buffer.text());
    try std.testing.expect(session.hasCompletionMenu());

    try session.handleKey(.{ .key = .escape });
    try std.testing.expect(!session.hasCompletionMenu());
}

test "completion menu closes on deletion edits" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git st");
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
        .{ .value = "stash", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .backspace });
    try std.testing.expectEqualStrings("git s", session.editor.buffer.text());
    try std.testing.expect(!session.hasCompletionMenu());

    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .delete_previous_word });
    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
    try std.testing.expect(!session.hasCompletionMenu());
}

test "completion menu closes on cursor movement" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git st");
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
        .{ .value = "stash", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .left });
    try std.testing.expectEqual(@as(usize, "git s".len), session.editor.buffer.cursor_byte);
    try std.testing.expect(!session.hasCompletionMenu());

    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .home });
    try std.testing.expectEqual(@as(usize, 0), session.editor.buffer.cursor_byte);
    try std.testing.expect(!session.hasCompletionMenu());
}

test "completion edit clears rendered menu" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git st");
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.candidates.len);

    try session.applyCompletion(.{ .edit = .{
        .replace_start = 4,
        .replace_end = 6,
        .replacement = "status",
        .append_space = true,
    } });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.candidates.len);
    try std.testing.expectEqualStrings("git status ", session.editor.buffer.text());
}

test "removable completion suffix keeps remove and types through" {
    var keep = try LineSession.init(std.testing.allocator, "$ ");
    defer keep.deinit();
    try keep.editor.buffer.replace("tool bl");
    try keep.applyCompletion(.{ .edit = .{
        .replace_start = "tool ".len,
        .replace_end = "tool bl".len,
        .replacement = "blue,",
        .suffix = ",",
        .removable_suffix = true,
    } });
    try std.testing.expectEqualStrings("tool blue,", keep.editor.buffer.text());
    try keep.handleKey(.{ .key = .text, .text = "," });
    try std.testing.expectEqualStrings("tool blue,", keep.editor.buffer.text());

    var remove = try LineSession.init(std.testing.allocator, "$ ");
    defer remove.deinit();
    try remove.editor.buffer.replace("tool bl");
    try remove.applyCompletion(.{ .edit = .{
        .replace_start = "tool ".len,
        .replace_end = "tool bl".len,
        .replacement = "blue,",
        .suffix = ",",
        .removable_suffix = true,
    } });
    try remove.handleKey(.{ .key = .text, .text = " " });
    try std.testing.expectEqualStrings("tool blue ", remove.editor.buffer.text());

    var accept = try LineSession.init(std.testing.allocator, "$ ");
    defer accept.deinit();
    try accept.editor.buffer.replace("tool bl");
    try accept.applyCompletion(.{ .edit = .{
        .replace_start = "tool ".len,
        .replace_end = "tool bl".len,
        .replacement = "blue,",
        .suffix = ",",
        .removable_suffix = true,
    } });
    try accept.handleKey(.{ .key = .enter });
    try std.testing.expectEqualStrings("tool blue", accept.submitted_line.?);

    var typed = try LineSession.init(std.testing.allocator, "$ ");
    defer typed.deinit();
    try typed.editor.buffer.replace("tool bl");
    try typed.applyCompletion(.{ .edit = .{
        .replace_start = "tool ".len,
        .replace_end = "tool bl".len,
        .replacement = "blue,",
        .suffix = ",",
        .removable_suffix = true,
    } });
    try typed.handleKey(.{ .key = .text, .text = "x" });
    try std.testing.expectEqualStrings("tool blue,x", typed.editor.buffer.text());
}

test "completion menu respects render height" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git ");
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "three", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 3 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "two") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "showing 1-1 of 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[2A") != null);
}

test "completion menu caps visible candidates at sixteen rows" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "item00", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item01", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item02", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item03", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item04", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item05", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item06", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item07", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item08", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item09", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item10", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item11", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item12", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item13", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item14", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item15", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item16", .kind = .plain, .replace_start = 0, .replace_end = 0 },
        .{ .value = "item17", .kind = .plain, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 40 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "item15") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "item16") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "showing 1-16 of 18") != null);
}

test "completion menu visible window follows selection" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git ");
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "three", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .down });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 3 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[1m\x1b[36m  three") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "showing 3-3 of 3") != null);
}

test "completion menu only pins selection to bottom while scrolling down" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "three", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "four", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .down });

    const scrolled_down = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 4 });
    defer std.testing.allocator.free(scrolled_down);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_down, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_down, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_down, "\x1b[1m\x1b[36m  three") != null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_down, "showing 2-3 of 4") != null);

    try session.handleKey(.{ .key = .up });
    const moved_up = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 4 });
    defer std.testing.allocator.free(moved_up);
    try std.testing.expect(std.mem.indexOf(u8, moved_up, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, moved_up, "\x1b[1m\x1b[36m  two") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved_up, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved_up, "showing 2-3 of 4") != null);
}

test "completion menu truncates long columns to terminal width" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{.{
        .value = "extraordinarily-long-subcommand-name",
        .description = "this description is intentionally too long for the menu",
        .kind = .subcommand,
        .replace_start = 0,
        .replace_end = 0,
    }};
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .width = 32 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "extraordinarily-long-subcom…") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "intentionally") == null);
}

test "line session submits an owned copy on enter" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "echo hi" });
    try session.handleKey(.{ .key = .enter });

    try std.testing.expectEqual(LineSession.State.submitted, session.state);
    const line = session.takeSubmittedLine().?;
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("echo hi", line);
}

test "line session inserts newline on shift-enter" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };

    try session.handleKey(.{ .key = .text, .text = "echo" });
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .enter, .modifiers = .{ .shift = true } });
    try session.handleKey(.{ .key = .text, .text = "hi" });

    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expect(!session.hasCompletionMenu());
    try std.testing.expectEqualStrings("echo\nhi", session.editor.buffer.text());
    try std.testing.expect(session.takeSubmittedLine() == null);
}

test "line session keeps input and clears menu on escape" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "d" });

    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expect(!session.hasCompletionMenu());
    try std.testing.expectEqualStrings("abcd", session.editor.buffer.text());
}

test "line session clears input and menu on ctrl-c" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .ctrl_c });

    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expect(!session.hasCompletionMenu());
    try std.testing.expectEqualStrings("", session.editor.buffer.text());
    try std.testing.expect(session.takeSubmittedLine() == null);

    try session.handleKey(.{ .key = .ctrl_c });
    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings("", session.editor.buffer.text());
}

test "line session treats ctrl-d as eof only on empty buffer" {
    var empty = try LineSession.init(std.testing.allocator, "$ ");
    defer empty.deinit();
    try empty.handleKey(.{ .key = .ctrl_d });
    try std.testing.expectEqual(LineSession.State.eof, empty.state);

    var non_empty = try LineSession.init(std.testing.allocator, "$ ");
    defer non_empty.deinit();
    try non_empty.handleKey(.{ .key = .text, .text = "ab" });
    non_empty.editor.buffer.moveLeft();
    try non_empty.handleKey(.{ .key = .ctrl_d });
    try std.testing.expectEqual(LineSession.State.editing, non_empty.state);
    try std.testing.expectEqualStrings("a", non_empty.editor.buffer.text());
}

test "vi line session switches modes and edits in command mode" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.handleKey(.{ .key = .escape });
    try std.testing.expectEqual(ViState.command, session.vi_state);
    try std.testing.expectEqual(@as(usize, 2), session.editor.buffer.cursor_byte);

    try session.handleKey(.{ .key = .text, .text = "h" });
    try session.handleKey(.{ .key = .text, .text = "x" });
    try std.testing.expectEqualStrings("ac", session.editor.buffer.text());
    try session.handleKey(.{ .key = .text, .text = "u" });
    try std.testing.expectEqualStrings("abc", session.editor.buffer.text());
    try session.handleKey(.{ .key = .ctrl_r });
    try std.testing.expectEqualStrings("ac", session.editor.buffer.text());
    try session.handleKey(.{ .key = .text, .text = "u" });
    try std.testing.expectEqualStrings("abc", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "i" });
    try std.testing.expectEqual(ViState.insert, session.vi_state);
    try session.handleKey(.{ .key = .text, .text = "B" });
    try std.testing.expectEqualStrings("aBbc", session.editor.buffer.text());
}

test "vi leave-insert steps onto previous character" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "abcd" });
    try session.handleKey(.{ .key = .escape });
    // After typing at EOL, ESC lands on the last character.
    try std.testing.expectEqual(@as(usize, 3), session.editor.buffer.cursor_byte);

    // Bare i ESC i ESC from mid-line: each ESC steps left from the insert point.
    try session.handleKey(.{ .key = .text, .text = "0" });
    try session.handleKey(.{ .key = .text, .text = "l" });
    try session.handleKey(.{ .key = .text, .text = "l" });
    try std.testing.expectEqual(@as(usize, 2), session.editor.buffer.cursor_byte); // on 'c'
    try session.handleKey(.{ .key = .text, .text = "i" });
    try session.handleKey(.{ .key = .escape });
    try std.testing.expectEqual(@as(usize, 1), session.editor.buffer.cursor_byte); // on 'b'
    try session.handleKey(.{ .key = .text, .text = "i" });
    try session.handleKey(.{ .key = .escape });
    try std.testing.expectEqual(@as(usize, 0), session.editor.buffer.cursor_byte); // on 'a'

    // a ESC a ESC leaves the cursor unmoved: append steps right, ESC steps left.
    try session.handleKey(.{ .key = .text, .text = "l" });
    try std.testing.expectEqual(@as(usize, 1), session.editor.buffer.cursor_byte);
    try session.handleKey(.{ .key = .text, .text = "a" });
    try session.handleKey(.{ .key = .escape });
    try std.testing.expectEqual(@as(usize, 1), session.editor.buffer.cursor_byte);
    try session.handleKey(.{ .key = .text, .text = "a" });
    try session.handleKey(.{ .key = .escape });
    try std.testing.expectEqual(@as(usize, 1), session.editor.buffer.cursor_byte);
    try std.testing.expectEqualStrings("abcd", session.editor.buffer.text());
}

test "vi insert mode inserts newline on shift-enter and kills next word" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "echo there friend" });
    try session.handleKey(.{ .key = .home });
    try session.handleKey(.{ .key = .word_right });
    try session.handleKey(.{ .key = .delete_next_word });
    try std.testing.expectEqualStrings("echo friend", session.editor.buffer.text());
    try session.handleKey(.{ .key = .enter, .modifiers = .{ .shift = true } });
    try session.handleKey(.{ .key = .text, .text = "hi" });

    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings("echo\nhi friend", session.editor.buffer.text());
}

test "vi line session deletes to end and puts killed text" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git status" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "b" });
    try session.handleKey(.{ .key = .text, .text = "D" });
    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
    try session.handleKey(.{ .key = .text, .text = "p" });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
}

test "vi line session repeats insert replace and delete changes with dot" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "ab" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "I" });
    try session.handleKey(.{ .key = .text, .text = "x" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("xxab", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "l" });
    try session.handleKey(.{ .key = .text, .text = "r" });
    try session.handleKey(.{ .key = .text, .text = "Y" });
    try session.handleKey(.{ .key = .text, .text = "l" });
    try session.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("xYYb", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "0" });
    try session.handleKey(.{ .key = .text, .text = "2" });
    try session.handleKey(.{ .key = .text, .text = "x" });
    try std.testing.expectEqualStrings("Yb", session.editor.buffer.text());
    try session.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("", session.editor.buffer.text());
}

test "vi line session repeats counted insert text" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "ab" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "0" });
    try session.handleKey(.{ .key = .text, .text = "3" });
    try session.handleKey(.{ .key = .text, .text = "i" });
    try session.handleKey(.{ .key = .text, .text = "x" });
    try session.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("xxxab", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("xxxxxxab", session.editor.buffer.text());
}

test "vi line session repeats insert editing controls" {
    var counted = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer counted.deinit();

    try counted.handleKey(.{ .key = .text, .text = "ab" });
    try counted.handleKey(.{ .key = .escape });
    try counted.handleKey(.{ .key = .text, .text = "0" });
    try counted.handleKey(.{ .key = .text, .text = "2" });
    try counted.handleKey(.{ .key = .text, .text = "i" });
    try counted.handleKey(.{ .key = .text, .text = "xy" });
    try counted.handleKey(.{ .key = .backspace });
    try counted.handleKey(.{ .key = .text, .text = "z" });
    try counted.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("xzxzab", counted.editor.buffer.text());
    // ESC leaves the cursor on the last inserted character, so `.` replays at
    // that column rather than after the insert.
    try std.testing.expectEqual(@as(usize, 3), counted.editor.buffer.cursor_byte);

    try counted.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("xzxxzxzzab", counted.editor.buffer.text());

    var edited = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer edited.deinit();

    try edited.handleKey(.{ .key = .text, .text = "end" });
    try edited.handleKey(.{ .key = .escape });
    try edited.handleKey(.{ .key = .text, .text = "0" });
    try edited.handleKey(.{ .key = .text, .text = "i" });
    try edited.handleKey(.{ .key = .text, .text = "one two" });
    try edited.handleKey(.{ .key = .delete_previous_word });
    try edited.handleKey(.{ .key = .text, .text = "three " });
    try edited.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("one three end", edited.editor.buffer.text());
    // ESC steps onto the space before "end", so `.` replays from that column.
    try std.testing.expectEqual(@as(usize, 9), edited.editor.buffer.cursor_byte);

    try edited.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("one threeone three  end", edited.editor.buffer.text());

    var moved = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer moved.deinit();

    try moved.handleKey(.{ .key = .text, .text = "ab" });
    try moved.handleKey(.{ .key = .escape });
    try moved.handleKey(.{ .key = .text, .text = "0" });
    try moved.handleKey(.{ .key = .text, .text = "i" });
    try moved.handleKey(.{ .key = .text, .text = "xy" });
    try moved.handleKey(.{ .key = .left });
    try moved.handleKey(.{ .key = .text, .text = "Z" });
    try moved.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("xZyab", moved.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 1), moved.editor.buffer.cursor_byte);

    try moved.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("xxZyZyab", moved.editor.buffer.text());
}

test "vi line session repeats replace mode sessions" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "abcdef" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "0" });
    try session.handleKey(.{ .key = .text, .text = "R" });
    try session.handleKey(.{ .key = .text, .text = "XY" });
    try session.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("XYcdef", session.editor.buffer.text());
    // ESC from replace lands on the last replaced character.
    try std.testing.expectEqual(@as(usize, 1), session.editor.buffer.cursor_byte);

    try session.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("XXYdef", session.editor.buffer.text());
}

test "vi line session multiplies operator and motion counts" {
    var before_operator = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer before_operator.deinit();
    try before_operator.handleKey(.{ .key = .text, .text = "one two three" });
    try before_operator.handleKey(.{ .key = .escape });
    try before_operator.handleKey(.{ .key = .text, .text = "0" });
    try before_operator.handleKey(.{ .key = .text, .text = "2" });
    try before_operator.handleKey(.{ .key = .text, .text = "c" });
    try before_operator.handleKey(.{ .key = .text, .text = "w" });
    try before_operator.handleKey(.{ .key = .text, .text = "X" });
    try before_operator.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("X three", before_operator.editor.buffer.text());

    var after_operator = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer after_operator.deinit();
    try after_operator.handleKey(.{ .key = .text, .text = "one two three" });
    try after_operator.handleKey(.{ .key = .escape });
    try after_operator.handleKey(.{ .key = .text, .text = "0" });
    try after_operator.handleKey(.{ .key = .text, .text = "c" });
    try after_operator.handleKey(.{ .key = .text, .text = "2" });
    try after_operator.handleKey(.{ .key = .text, .text = "w" });
    try after_operator.handleKey(.{ .key = .text, .text = "X" });
    try after_operator.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("X three", after_operator.editor.buffer.text());

    var multiplied = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer multiplied.deinit();
    try multiplied.handleKey(.{ .key = .text, .text = "one two three four" });
    try multiplied.handleKey(.{ .key = .escape });
    try multiplied.handleKey(.{ .key = .text, .text = "0" });
    try multiplied.handleKey(.{ .key = .text, .text = "2" });
    try multiplied.handleKey(.{ .key = .text, .text = "d" });
    try multiplied.handleKey(.{ .key = .text, .text = "2" });
    try multiplied.handleKey(.{ .key = .text, .text = "w" });
    try std.testing.expectEqualStrings("", multiplied.editor.buffer.text());
}

test "vi line session repeats operator changes and preserves change-word blanks" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "one two three" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "0" });
    try session.handleKey(.{ .key = .text, .text = "c" });
    try session.handleKey(.{ .key = .text, .text = "w" });
    try session.handleKey(.{ .key = .text, .text = "X" });
    try session.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("X two three", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "w" });
    try session.handleKey(.{ .key = .text, .text = "." });
    try std.testing.expectEqualStrings("X X three", session.editor.buffer.text());

    var blank = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer blank.deinit();
    try blank.handleKey(.{ .key = .text, .text = "one  two" });
    try blank.handleKey(.{ .key = .escape });
    try blank.handleKey(.{ .key = .text, .text = "0" });
    try blank.handleKey(.{ .key = .text, .text = "l" });
    try blank.handleKey(.{ .key = .text, .text = "l" });
    try blank.handleKey(.{ .key = .text, .text = "l" });
    try blank.handleKey(.{ .key = .text, .text = "c" });
    try blank.handleKey(.{ .key = .text, .text = "w" });
    try blank.handleKey(.{ .key = .text, .text = "X" });
    try blank.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("oneX two", blank.editor.buffer.text());

    // When the next word is a single character at EOL, w lands on lastGraphemeStart.
    // cw must still act like ce and preserve the blank before that word.
    var short_last = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer short_last.deinit();
    try short_last.handleKey(.{ .key = .text, .text = "a b" });
    try short_last.handleKey(.{ .key = .escape });
    try short_last.handleKey(.{ .key = .text, .text = "0" });
    try short_last.handleKey(.{ .key = .text, .text = "c" });
    try short_last.handleKey(.{ .key = .text, .text = "w" });
    try short_last.handleKey(.{ .key = .text, .text = "X" });
    try short_last.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("X b", short_last.editor.buffer.text());

    // cw on the final word should replace only that word.
    var last_word = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer last_word.deinit();
    try last_word.handleKey(.{ .key = .text, .text = "hello world" });
    try last_word.handleKey(.{ .key = .escape });
    try last_word.handleKey(.{ .key = .text, .text = "b" });
    try last_word.handleKey(.{ .key = .text, .text = "c" });
    try last_word.handleKey(.{ .key = .text, .text = "w" });
    try last_word.handleKey(.{ .key = .text, .text = "X" });
    try last_word.handleKey(.{ .key = .escape });
    try std.testing.expectEqualStrings("hello X", last_word.editor.buffer.text());
}

test "vi line session leaves out-of-range operator motions unchanged" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "d" });
    try session.handleKey(.{ .key = .text, .text = "l" });
    try std.testing.expectEqualStrings("abc", session.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 2), session.editor.buffer.cursor_byte);

    try session.handleKey(.{ .key = .text, .text = "2" });
    try session.handleKey(.{ .key = .text, .text = "$" });
    try std.testing.expectEqualStrings("abc", session.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 2), session.editor.buffer.cursor_byte);
}

test "vi line session inserts previous history bigwords with underscore" {
    const entries = [_][]const u8{ "echo first", "git commit --amend" };
    var session = try LineSession.initWithEditingMode(
        std.testing.allocator,
        .{ .bytes = "$ " },
        .{ .entries = &entries },
        .vi,
    );
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "run" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "_" });
    try std.testing.expectEqual(ViState.insert, session.vi_state);
    try std.testing.expectEqualStrings("run --amend", session.editor.buffer.text());

    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "0" });
    try session.handleKey(.{ .key = .text, .text = "2" });
    try session.handleKey(.{ .key = .text, .text = "_" });
    try std.testing.expectEqualStrings("r commitun --amend", session.editor.buffer.text());
}

test "vi line session searches history with POSIX patterns and n N" {
    const entries = [_][]const u8{ "echo one", "git status", "echo two", "git commit --amend" };
    var session = try LineSession.initWithEditingMode(
        std.testing.allocator,
        .{ .bytes = "$ " },
        .{ .entries = &entries },
        .vi,
    );
    defer session.deinit();

    // Silent POSIX pattern path (still used by n/N and pure unit coverage).
    try session.handleKey(.{ .key = .escape });
    session.beginViHistorySearch(.backward);
    try session.handleKey(.{ .key = .text, .text = "git *" });
    try session.handleKey(.{ .key = .enter });
    try std.testing.expectEqualStrings("git commit --amend", session.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 0), session.editor.buffer.cursor_byte);

    try session.handleKey(.{ .key = .text, .text = "n" });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "N" });
    try std.testing.expectEqualStrings("git commit --amend", session.editor.buffer.text());

    session.beginViHistorySearch(.backward);
    try session.handleKey(.{ .key = .text, .text = "^echo" });
    try session.handleKey(.{ .key = .enter });
    try std.testing.expectEqualStrings("echo two", session.editor.buffer.text());
}

test "vi line session question mark searches history forward" {
    const entries = [_][]const u8{ "echo one", "git status", "echo two", "git commit --amend" };
    var session = try LineSession.initWithEditingMode(
        std.testing.allocator,
        .{ .bytes = "$ " },
        .{ .entries = &entries },
        .vi,
    );
    defer session.deinit();

    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "G" });
    try std.testing.expectEqualStrings("echo one", session.editor.buffer.text());

    session.beginViHistorySearch(.forward);
    try session.handleKey(.{ .key = .text, .text = "git*" });
    try session.handleKey(.{ .key = .enter });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "n" });
    try std.testing.expectEqualStrings("git commit --amend", session.editor.buffer.text());
}

test "vi slash opens shared history search TUI" {
    const entries = [_][]const u8{ "echo one", "git status", "echo two", "git commit --amend" };
    var history_search: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithEditingMode(
        std.testing.allocator,
        .{ .bytes = "$ " },
        .{
            .entries = &entries,
            .context = &history_search,
            .search = testSearchHistoryEntry,
            .search_next = testSearchNextHistoryEntry,
        },
        .vi,
    );
    defer session.deinit();

    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "/" });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqual(ViState.insert, session.vi_state);
    try applyTestHistoryRequests(&session);

    try session.handleKey(.{ .key = .text, .text = "git" });
    try applyTestHistoryRequests(&session);
    try std.testing.expect(session.history_search_matches.items.len != 0);

    try session.handleKey(.{ .key = .enter });
    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings("git commit --amend", session.editor.buffer.text());
    try std.testing.expectEqualStrings("git", session.vi_last_history_search_pattern.items);
}

test "vi question mark opens forward shared history search TUI" {
    const entries = [_][]const u8{ "echo one", "git status", "echo two", "git commit --amend" };
    var history_search: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithEditingMode(
        std.testing.allocator,
        .{ .bytes = "$ " },
        .{
            .entries = &entries,
            .context = &history_search,
            .search = testSearchHistoryEntry,
            .search_next = testSearchNextHistoryEntry,
        },
        .vi,
    );
    defer session.deinit();

    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "?" });
    try applyTestHistoryRequests(&session);

    try session.handleKey(.{ .key = .text, .text = "git" });
    try applyTestHistoryRequests(&session);
    try std.testing.expect(session.history_search_matches.items.len != 0);

    try session.handleKey(.{ .key = .enter });
    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try std.testing.expectEqualStrings("git", session.vi_last_history_search_pattern.items);
    try std.testing.expectEqual(ViHistoryDirection.forward, session.vi_last_history_search_direction.?);
}

test "canceling vi shared history search preserves previous repeat pattern" {
    const entries = [_][]const u8{ "echo one", "git status", "echo two", "git commit --amend" };
    var history_search: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithEditingMode(
        std.testing.allocator,
        .{ .bytes = "$ " },
        .{
            .entries = &entries,
            .context = &history_search,
            .search = testSearchHistoryEntry,
            .search_next = testSearchNextHistoryEntry,
        },
        .vi,
    );
    defer session.deinit();

    try session.vi_last_history_search_pattern.appendSlice(std.testing.allocator, "git");
    session.vi_last_history_search_direction = .forward;
    try session.editor.buffer.replace("draft command");

    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "/" });
    try applyTestHistoryRequests(&session);
    try session.handleKey(.{ .key = .text, .text = "echo" });
    try applyTestHistoryRequests(&session);
    try session.handleKey(.{ .key = .escape });

    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings("draft command", session.editor.buffer.text());
    try std.testing.expectEqualStrings("git", session.vi_last_history_search_pattern.items);
    try std.testing.expectEqual(ViHistoryDirection.forward, session.vi_last_history_search_direction.?);
}

const TestViAliasSet = struct {
    entries: []const Entry,

    const Entry = struct {
        letter: u21,
        value: []const u8,
    };
};

// ziglint-ignore: Z023 parameter order is fixed by the ViAliasView.lookup callback signature
fn testLookupViAlias(context: *anyopaque, allocator: std.mem.Allocator, letter: u21) !?[]const u8 {
    const aliases: *const TestViAliasSet = @ptrCast(@alignCast(context));
    for (aliases.entries) |entry| {
        if (entry.letter == letter) {
            const copy = try allocator.dupe(u8, entry.value);
            return copy;
        }
    }
    return null;
}

fn testApplyViAliasRequest(session: *LineSession, aliases: TestViAliasSet) !bool {
    const letter = session.takeViAliasLookupRequest() orelse return false;
    const value = try testLookupViAlias(@constCast(&aliases), std.testing.allocator, letter);
    defer if (value) |bytes| std.testing.allocator.free(bytes);
    try session.applyViAliasResult(letter, value);
    return true;
}

test "vi line session expands command aliases as editing input" {
    const alias_entries = [_]TestViAliasSet.Entry{
        .{ .letter = 'a', .value = "Igit \x1b" },
        .{ .letter = 'd', .value = "0dw" },
    };
    const aliases: TestViAliasSet = .{ .entries = &alias_entries };
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "status" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "@" });
    try session.handleKey(.{ .key = .text, .text = "a" });
    try std.testing.expect(try testApplyViAliasRequest(&session, aliases));
    try std.testing.expectEqual(ViState.command, session.vi_state);
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());

    try session.handleKey(.{ .key = .text, .text = "@" });
    try session.handleKey(.{ .key = .text, .text = "d" });
    try std.testing.expect(try testApplyViAliasRequest(&session, aliases));
    try std.testing.expectEqualStrings("status", session.editor.buffer.text());
}

test "vi line session applies missing command aliases as no-ops" {
    const aliases: TestViAliasSet = .{ .entries = &.{} };
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "@" });
    try session.handleKey(.{ .key = .text, .text = "z" });
    try std.testing.expect(try testApplyViAliasRequest(&session, aliases));

    try std.testing.expectEqualStrings("abc", session.editor.buffer.text());
    try std.testing.expectEqual(ViState.command, session.vi_state);
}

test "vi alias request seam preserves recursive macro limit" {
    const alias_entries = [_]TestViAliasSet.Entry{.{ .letter = 'a', .value = "@a" }};
    const aliases: TestViAliasSet = .{ .entries = &alias_entries };
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "@" });
    try session.handleKey(.{ .key = .text, .text = "a" });

    var applications: usize = 0;
    while (try testApplyViAliasRequest(&session, aliases)) applications += 1;

    try std.testing.expectEqual(@as(usize, max_vi_macro_depth), applications);
    try std.testing.expectEqual(@as(usize, 0), session.vi_macro_depth);
}

test "vi line session requests external editor for current and numbered history commands" {
    const entries = [_][]const u8{ "echo one", "echo two" };
    var current = try LineSession.initWithEditingMode(
        std.testing.allocator,
        .{ .bytes = "$ " },
        .{ .entries = &entries },
        .vi,
    );
    defer current.deinit();
    try current.handleKey(.{ .key = .text, .text = "echo draft" });
    try current.handleKey(.{ .key = .escape });
    try current.handleKey(.{ .key = .text, .text = "v" });
    try std.testing.expectEqual(LineSession.State.external_editor, current.state);
    const current_request = current.takeExternalEditorRequest() orelse return error.MissingExternalEditorRequest;
    defer current_request.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo draft", current_request.text);
    current.resumeEditingAfterExternalEditor();

    var numbered = try LineSession.initWithEditingMode(
        std.testing.allocator,
        .{ .bytes = "$ " },
        .{ .entries = &entries },
        .vi,
    );
    defer numbered.deinit();
    try numbered.handleKey(.{ .key = .escape });
    try numbered.handleKey(.{ .key = .text, .text = "2" });
    try numbered.handleKey(.{ .key = .text, .text = "v" });
    try std.testing.expectEqual(LineSession.State.external_editor, numbered.state);
    const numbered_request = numbered.takeExternalEditorRequest() orelse return error.MissingExternalEditorRequest;
    defer numbered_request.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo two", numbered_request.text);
    try std.testing.expectEqual(@as(?usize, 2), numbered_request.number);
}

test "vi line session requests pathname expansion for current bigword" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "cat rush-path" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "=" });

    const request = session.takePathExpansionRequest() orelse return error.MissingPathExpansionRequest;
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(PathExpansionCommand.list, request.command);
    try std.testing.expectEqualStrings("rush-path", request.word);
    try std.testing.expectEqual(@as(usize, "cat ".len), request.replace_start);
    try std.testing.expectEqual(@as(usize, "cat rush-path".len), request.replace_end);
}

test "vi line session pathname request keeps quoted shell words together" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "cat 'rush path" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "=" });

    const request = session.takePathExpansionRequest() orelse return error.MissingPathExpansionRequest;
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(PathExpansionCommand.list, request.command);
    try std.testing.expectEqualStrings("'rush path", request.word);
    try std.testing.expectEqual(@as(usize, "cat ".len), request.replace_start);
    try std.testing.expectEqual(@as(usize, "cat 'rush path".len), request.replace_end);
    try std.testing.expectEqual(PathExpansionReplacementStyle.single_quoted, request.replacement_style);
}

test "vi pathname completion applies common prefixes and complete matches" {
    var common = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer common.deinit();
    try common.editor.buffer.replace("cat rush-vi-al");
    try std.testing.expect(try common.applyPathExpansion(.{
        .command = .complete,
        .word = "rush-vi-al",
        .replace_start = "cat ".len,
        .replace_end = "cat rush-vi-al".len,
    }, .{ .items = &.{ "rush-vi-alpha", "rush-vi-alpine" } }));
    try std.testing.expectEqualStrings("cat rush-vi-alp", common.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, "cat rush-vi-alp".len), common.editor.buffer.cursor_byte);

    var file = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer file.deinit();
    try file.editor.buffer.replace("cat rush-vi-alpha");
    try std.testing.expect(try file.applyPathExpansion(.{
        .command = .complete,
        .word = "rush-vi-alpha",
        .replace_start = "cat ".len,
        .replace_end = "cat rush-vi-alpha".len,
    }, .{ .items = &.{"rush-vi-alpha"} }));
    try std.testing.expectEqualStrings("cat rush-vi-alpha ", file.editor.buffer.text());

    var dir = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer dir.deinit();
    try dir.editor.buffer.replace("cd rush-vi-dir");
    try std.testing.expect(try dir.applyPathExpansion(.{
        .command = .complete,
        .word = "rush-vi-dir",
        .replace_start = "cd ".len,
        .replace_end = "cd rush-vi-dir".len,
    }, .{ .items = &.{"rush-vi-dir/"} }));
    try std.testing.expectEqualStrings("cd rush-vi-dir/", dir.editor.buffer.text());
}

test "vi pathname completion requotes replacements for quoted shell words" {
    var file = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer file.deinit();
    try file.editor.buffer.replace("cat 'rush vi file");
    try std.testing.expect(try file.applyPathExpansion(.{
        .command = .complete,
        .word = "'rush vi file",
        .replace_start = "cat ".len,
        .replace_end = "cat 'rush vi file".len,
        .replacement_style = .single_quoted,
    }, .{ .items = &.{"rush vi file"} }));
    try std.testing.expectEqualStrings("cat 'rush vi file' ", file.editor.buffer.text());

    var double = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer double.deinit();
    try double.editor.buffer.replace("cat \"rush vi file");
    try std.testing.expect(try double.applyPathExpansion(.{
        .command = .complete,
        .word = "\"rush vi file",
        .replace_start = "cat ".len,
        .replace_end = "cat \"rush vi file".len,
        .replacement_style = .double_quoted,
    }, .{ .items = &.{"rush vi file"} }));
    try std.testing.expectEqualStrings("cat \"rush vi file\" ", double.editor.buffer.text());

    var escaped = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer escaped.deinit();
    try escaped.editor.buffer.replace("cat rush\\ vi");
    try std.testing.expect(try escaped.applyPathExpansion(.{
        .command = .complete,
        .word = "rush\\ vi",
        .replace_start = "cat ".len,
        .replace_end = "cat rush\\ vi".len,
        .replacement_style = .backslash_escaped,
    }, .{ .items = &.{"rush vi file"} }));
    try std.testing.expectEqualStrings("cat rush\\ vi\\ file ", escaped.editor.buffer.text());

    var all = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer all.deinit();
    try all.editor.buffer.replace("printf rush\\ vi*");
    try std.testing.expect(try all.applyPathExpansion(.{
        .command = .expand_all,
        .word = "rush\\ vi*",
        .replace_start = "printf ".len,
        .replace_end = "printf rush\\ vi*".len,
        .replacement_style = .backslash_escaped,
    }, .{ .items = &.{ "rush vi a", "rush vi b" } }));
    try std.testing.expectEqualStrings("printf rush\\ vi\\ a rush\\ vi\\ b", all.editor.buffer.text());

    var dir = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer dir.deinit();
    try dir.editor.buffer.replace("cd \"rush vi dir");
    try std.testing.expect(try dir.applyPathExpansion(.{
        .command = .complete,
        .word = "\"rush vi dir",
        .replace_start = "cd ".len,
        .replace_end = "cd \"rush vi dir".len,
        .replacement_style = .double_quoted,
    }, .{ .items = &.{"rush vi dir/"} }));
    try std.testing.expectEqualStrings("cd \"rush vi dir/\"", dir.editor.buffer.text());
}

test "vi pathname star expands all matches and listing formats matches" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();
    try session.editor.buffer.replace("printf rush-vi-* ");
    try std.testing.expect(try session.applyPathExpansion(.{
        .command = .expand_all,
        .word = "rush-vi-*",
        .replace_start = "printf ".len,
        .replace_end = "printf rush-vi-*".len,
    }, .{ .items = &.{ "rush-vi-a", "rush-vi-b/", "rush-vi-c" } }));
    try std.testing.expectEqualStrings("printf rush-vi-a rush-vi-b/ rush-vi-c ", session.editor.buffer.text());

    const output = try pathExpansionListOutput(std.testing.allocator, .{
        .items = &.{ "rush-vi-a", "rush-vi-b/", "rush-vi-c" },
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("rush-vi-a rush-vi-b/ rush-vi-c\n", output);
}

test "vi line session renders beam block and underline cursors" {
    var session = try LineSession.initWithEditingMode(std.testing.allocator, .{ .bytes = "$ " }, .{}, .vi);
    defer session.deinit();

    const insert = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(insert);
    try std.testing.expect(std.mem.startsWith(u8, insert, "\x1b[6 q"));

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.handleKey(.{ .key = .escape });
    const command = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(command);
    try std.testing.expect(std.mem.startsWith(u8, command, "\x1b[2 q"));

    try session.handleKey(.{ .key = .text, .text = "R" });
    const replace = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(replace);
    try std.testing.expect(std.mem.startsWith(u8, replace, "\x1b[4 q"));
}

test "line session renders with its prompt" {
    var session = try LineSession.init(std.testing.allocator, "rush> ");
    defer session.deinit();
    try session.handleKey(.{ .key = .text, .text = "x" });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2Krush> x\r\x1b[7C", rendered);
}

test "line session removes Readline non-printing markers from prompt surfaces" {
    const marked = "\x01\x1b[31m\x02red\x01\x1b[0m\x02";
    const expected = "\x1b[31mred\x1b[0m";
    var session = try LineSession.init(std.testing.allocator, marked);
    defer session.deinit();
    try session.replaceRightPrompt(.{ .bytes = marked });

    try std.testing.expectEqualStrings(expected, session.prompt.bytes);
    try std.testing.expectEqualStrings(expected, session.right_prompt.bytes);
}

test "line session renders right prompt flush right" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.replaceRightPrompt(.{ .bytes = "RIGHT" });
    try session.editor.buffer.replace("echo");

    var frame = try session.renderFrame(std.testing.allocator, .{
        .width = 20,
        .synchronized_output = false,
    });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("$ echo         RIGHT", frame.lines[0]);
}

test "line session hides right prompt on collision" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.replaceRightPrompt(.{ .bytes = "RIGHT" });
    try session.editor.buffer.replace("echo abcdefghijk");

    var frame = try session.renderFrame(std.testing.allocator, .{
        .width = 20,
        .synchronized_output = false,
    });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("$ echo abcdefghijk", frame.lines[0]);
}

test "line session omits right prompt after submit" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.replaceRightPrompt(.{ .bytes = "RIGHT" });
    try session.editor.buffer.replace("echo");
    try session.handleKey(.{ .key = .enter });

    var frame = try session.renderFrame(std.testing.allocator, .{
        .width = 20,
        .synchronized_output = false,
    });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("$ echo", frame.lines[0]);
}

test "render line styles diagnostic spans without moving cursor" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.buffer.replace("git comit");

    const spans = [_]DiagnosticSpan{.{ .start = 4, .end = 9, .severity = .err }};
    const rendered = try renderLine(std.testing.allocator, editor, .{
        .prompt = .{ .bytes = "$ " },
        .diagnostic_spans = &spans,
        .synchronized_output = false,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2K$ git \x1b[4:3m\x1b[58:5:1mcomit\x1b[24;59m\r\x1b[11C", rendered);
}

test "render line wraps styled diagnostic spans" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.buffer.replace("git commit --amend");

    const spans = [_]DiagnosticSpan{.{ .start = 11, .end = 18, .severity = .warning }};
    const rendered = try renderLine(std.testing.allocator, editor, .{
        .prompt = .{ .bytes = "$ " },
        .diagnostic_spans = &spans,
        .width = 12,
        .synchronized_output = false,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[4:3m\x1b[58:5:1m--amend\x1b[24;59m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "\r\x1b[8C"));
}

test "frame renderer diffs wrapped styled continuation with style prefix" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var first_editor = Editor.init(std.testing.allocator);
    defer first_editor.deinit();
    try first_editor.buffer.replace("foo \"this line is wrapped\"");
    const first_spans = [_]DiagnosticSpan{.{
        .start = 4,
        .end = first_editor.buffer.text().len,
        .severity = .quote,
    }};
    var first = try frameFromLine(std.testing.allocator, first_editor, .{
        .prompt = .{ .bytes = "$ " },
        .diagnostic_spans = &first_spans,
        .width = 16,
        .synchronized_output = false,
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), first.lines.len);
    const first_output = try renderer.render(std.testing.allocator, first, .{ .synchronized_output = false });
    defer std.testing.allocator.free(first_output);

    var second_editor = Editor.init(std.testing.allocator);
    defer second_editor.deinit();
    try second_editor.buffer.replace("foo \"this line was wrapped\"");
    const second_spans = [_]DiagnosticSpan{.{
        .start = 4,
        .end = second_editor.buffer.text().len,
        .severity = .quote,
    }};
    var second = try frameFromLine(std.testing.allocator, second_editor, .{
        .prompt = .{ .bytes = "$ " },
        .diagnostic_spans = &second_spans,
        .width = 16,
        .synchronized_output = false,
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), second.lines.len);

    const second_output = try renderer.render(std.testing.allocator, second, .{ .synchronized_output = false });
    defer std.testing.allocator.free(second_output);

    try std.testing.expect(std.mem.indexOf(u8, second_output, "$ foo") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\x1b[32m was wrapped") != null);
}

test "relative age formats compact units" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("30s", relativeAge(&buffer, 100, 70));
    try std.testing.expectEqualStrings("12m", relativeAge(&buffer, 12 * 60 + 5, 5));
    try std.testing.expectEqualStrings("1h", relativeAge(&buffer, 60 * 60 + 10, 10));
    try std.testing.expectEqualStrings("3d", relativeAge(&buffer, 3 * 24 * 60 * 60 + 9, 9));
    try std.testing.expectEqualStrings("0s", relativeAge(&buffer, 10, 20));
}

test "line session navigates full history from empty buffer" {
    const entries = [_][]const u8{ "echo one", "echo two" };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries });
    defer session.deinit();

    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("echo two", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("echo one", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("echo two", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("", session.editor.buffer.text());
}

test "line session searches history by draft prefix" {
    const entries = [_][]const u8{ "echo one", "git status", "echo two", "git diff" };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git diff", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("git diff", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("git", session.editor.buffer.text());
}

const TestHistorySearch = struct {
    entries: []const []const u8,
    whens: []const i64 = &.{},

    fn when(self: TestHistorySearch, index: usize) i64 {
        return if (index < self.whens.len) self.whens[index] else 0;
    }
};

fn testSearchHistoryEntry(
    context: *anyopaque,
    // ziglint-ignore: Z023 parameter order is fixed by the HistoryView.search callback signature
    allocator: std.mem.Allocator,
    query: []const u8,
    filters: HistorySearchFilters,
    before: ?i64,
) !?HistoryView.HistoryEntry {
    _ = filters;
    const history: *TestHistorySearch = @ptrCast(@alignCast(context));
    var index = if (before) |id| @as(usize, @intCast(id)) else history.entries.len;
    while (index > 0) {
        index -= 1;
        const entry = history.entries[index];
        if (completion.fuzzyMatchRank(entry, query) != null) {
            return .{ .id = @intCast(index), .text = try allocator.dupe(u8, entry), .when = history.when(index) };
        }
    }
    return null;
}

fn testSearchNextHistoryEntry(
    context: *anyopaque,
    // ziglint-ignore: Z023 parameter order is fixed by the HistoryView.search_next callback signature
    allocator: std.mem.Allocator,
    query: []const u8,
    filters: HistorySearchFilters,
    after: ?i64,
) !?HistoryView.HistoryEntry {
    _ = filters;
    const history: *TestHistorySearch = @ptrCast(@alignCast(context));
    var index = if (after) |id| @as(usize, @intCast(id)) + 1 else 0;
    while (index < history.entries.len) : (index += 1) {
        const entry = history.entries[index];
        if (completion.fuzzyMatchRank(entry, query) != null) {
            return .{ .id = @intCast(index), .text = try allocator.dupe(u8, entry), .when = history.when(index) };
        }
    }
    return null;
}

fn applyTestHistoryRequests(session: *LineSession) !void {
    while (session.takeHistoryRequest()) |request| {
        defer request.deinit(std.testing.allocator);
        const result = try resolveTestHistoryRequest(session.history, request);
        try session.applyHistoryResult(request, result);
    }
}

fn resolveTestHistoryRequest(history: HistoryView, request: HistoryRequest) !HistoryResult {
    const context = history.context orelse return switch (request) {
        .search, .search_next => .{ .entries = try std.testing.allocator.alloc(HistoryView.HistoryEntry, 0) },
        .previous,
        .next,
        .by_number,
        .suggest,
        => .{ .entry = null },
    };
    return switch (request) {
        .previous => |previous| .{ .entry = if (history.previous) |callback|
            try callback(context, std.testing.allocator, previous.prefix, previous.before)
        else
            null },
        .next => |next| .{ .entry = if (history.next) |callback|
            try callback(context, std.testing.allocator, next.prefix, next.after)
        else
            null },
        .by_number => |number| .{ .entry = if (history.by_number) |callback|
            try callback(context, std.testing.allocator, number)
        else
            null },
        .search => |search| .{ .entries = try resolveTestHistorySearch(
            history,
            context,
            search.query,
            search.filters,
            search.before,
        ) },
        .search_next => |search| .{ .entries = try resolveTestHistorySearchNext(
            history,
            context,
            search.query,
            search.filters,
            search.after,
        ) },
        .suggest => |prefix| .{ .entry = if (history.suggest) |callback|
            try callback(context, std.testing.allocator, prefix)
        else
            null },
    };
}

fn resolveTestHistorySearch(
    history: HistoryView,
    context: *anyopaque,
    query: []const u8,
    filters: HistorySearchFilters,
    before: ?i64,
) ![]HistoryView.HistoryEntry {
    const search = history.search orelse return std.testing.allocator.alloc(HistoryView.HistoryEntry, 0);
    var matches: std.ArrayList(HistoryView.HistoryEntry) = .empty;
    errdefer {
        for (matches.items) |entry| entry.deinit(std.testing.allocator);
        matches.deinit(std.testing.allocator);
    }
    try appendTestHistorySearchEntries(&matches, search, context, query, filters, before);
    if (matches.items.len == 0 and before != null) {
        try appendTestHistorySearchEntries(&matches, search, context, query, filters, null);
    }
    return matches.toOwnedSlice(std.testing.allocator);
}

fn resolveTestHistorySearchNext(
    history: HistoryView,
    context: *anyopaque,
    query: []const u8,
    filters: HistorySearchFilters,
    after: ?i64,
) ![]HistoryView.HistoryEntry {
    const search_next = history.search_next orelse
        return resolveTestHistorySearch(history, context, query, filters, null);
    var matches: std.ArrayList(HistoryView.HistoryEntry) = .empty;
    errdefer {
        for (matches.items) |entry| entry.deinit(std.testing.allocator);
        matches.deinit(std.testing.allocator);
    }
    try appendTestHistorySearchEntries(&matches, search_next, context, query, filters, after);
    if (matches.items.len == 0 and after != null) {
        try appendTestHistorySearchEntries(&matches, search_next, context, query, filters, null);
    }
    return matches.toOwnedSlice(std.testing.allocator);
}

const TestHistorySearchCallback = *const fn (
    *anyopaque,
    std.mem.Allocator,
    []const u8,
    HistorySearchFilters,
    ?i64,
) anyerror!?HistoryView.HistoryEntry;

fn appendTestHistorySearchEntries(
    matches: *std.ArrayList(HistoryView.HistoryEntry),
    callback: TestHistorySearchCallback,
    context: *anyopaque,
    query: []const u8,
    filters: HistorySearchFilters,
    start_cursor: ?i64,
) !void {
    var cursor = start_cursor;
    while (matches.items.len < 20) {
        const entry = try callback(context, std.testing.allocator, query, filters, cursor) orelse break;
        cursor = entry.id;
        try matches.append(std.testing.allocator, entry);
    }
}

test "history search seeds query from current buffer and renders menu-style match" {
    const entries = [_][]const u8{ "echo one", "git status", "git diff" };
    const whens = [_]i64{ 10, 60, 90 };
    var history: TestHistorySearch = .{ .entries = &entries, .whens = &whens };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .now = 120,
        .context = &history,
        .search = testSearchHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);

    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git", session.history_search_query.items);
    try std.testing.expectEqualStrings("git", session.editor.buffer.text());

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[1m\x1b[36m  ") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "diff") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[33mg\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "30s") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "history") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "history `") == null);
}

test "history search renders clean no-match menu state" {
    const entries = [_][]const u8{ "echo one", "git status" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "missing" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);

    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("missing", session.history_search_query.items);
    try std.testing.expectEqualStrings("missing", session.editor.buffer.text());

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "No history matches") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[2mmissing") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "history `") == null);
}

test "history search filter toggles refresh the current query" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });

    if (session.takeHistoryRequest()) |request| {
        defer request.deinit(std.testing.allocator);
        const expected_filters: HistorySearchFilters = .{};
        try std.testing.expectEqual(expected_filters, request.search.filters);
    } else return error.TestExpectedEqual;

    try session.handleKey(.{ .key = .text, .text = "c", .modifiers = .{ .alt = true } });
    try std.testing.expectEqualStrings("git", session.history_search_query.items);
    if (session.takeHistoryRequest()) |request| {
        defer request.deinit(std.testing.allocator);
        try std.testing.expect(request.search.filters.cwd);
        try std.testing.expect(!request.search.filters.successful);
        try std.testing.expect(!request.search.filters.session);
    } else return error.TestExpectedEqual;

    try session.handleKey(.{ .key = .text, .text = "s", .modifiers = .{ .alt = true } });
    try session.handleKey(.{ .key = .text, .text = "t", .modifiers = .{ .alt = true } });
    if (session.takeHistoryRequest()) |request| {
        defer request.deinit(std.testing.allocator);
        try std.testing.expect(request.search.filters.cwd);
        try std.testing.expect(request.search.filters.successful);
        try std.testing.expect(request.search.filters.session);
    } else return error.TestExpectedEqual;

    var frame = try session.renderFrame(std.testing.allocator, .{ .width = 80, .height = 24 });
    defer frame.deinit(std.testing.allocator);
    var rendered_status = false;
    for (frame.lines) |line| {
        if (std.mem.indexOf(u8, line, "history filters: cwd, successful, session") != null) {
            rendered_status = true;
        }
    }
    try std.testing.expect(rendered_status);
}

test "history search cancel restores original and enter accepts match" {
    const entries = [_][]const u8{ "echo one", "git status", "git diff" };
    var history: TestHistorySearch = .{ .entries = &entries };

    var cancel = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
    });
    defer cancel.deinit();
    try cancel.handleKey(.{ .key = .text, .text = "git" });
    try cancel.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&cancel);
    try cancel.handleKey(.{ .key = .escape });
    try std.testing.expectEqual(LineSession.State.editing, cancel.state);
    try std.testing.expectEqualStrings("git", cancel.editor.buffer.text());

    var accept = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
    });
    defer accept.deinit();
    try accept.handleKey(.{ .key = .text, .text = "git" });
    try accept.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&accept);
    try accept.handleKey(.{ .key = .enter });
    try std.testing.expectEqual(LineSession.State.editing, accept.state);
    try std.testing.expectEqualStrings("git diff", accept.editor.buffer.text());
}

test "history search edits query while staying open" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);
    try session.handleKey(.{ .key = .text, .text = " s" });
    try applyTestHistoryRequests(&session);

    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git s", session.history_search_query.items);
    try std.testing.expectEqualStrings("git s", session.editor.buffer.text());
    try std.testing.expect(session.selectedHistorySearchMatch() != null);
    try std.testing.expectEqualStrings("git show", session.selectedHistorySearchMatch().?.text);

    try session.handleKey(.{ .key = .text, .text = "t" });
    try applyTestHistoryRequests(&session);
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git st", session.history_search_query.items);
    try std.testing.expectEqualStrings("git status", session.selectedHistorySearchMatch().?.text);
}

test "history search deletion edits query while staying open" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git st" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);
    try session.handleKey(.{ .key = .backspace });
    try applyTestHistoryRequests(&session);

    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git s", session.history_search_query.items);
    try std.testing.expectEqualStrings("git s", session.editor.buffer.text());
    try std.testing.expectEqualStrings("git show", session.selectedHistorySearchMatch().?.text);

    session.editor.buffer.moveLeft();
    try session.handleKey(.{ .key = .delete });
    try applyTestHistoryRequests(&session);
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git ", session.history_search_query.items);
    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
}

test "history search transitions from no match to match as query changes" {
    const entries = [_][]const u8{ "git status", "git diff" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "missing" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expect(session.selectedHistorySearchMatch() == null);

    try session.handleKey(.{ .key = .delete_to_start });
    try applyTestHistoryRequests(&session);
    try session.handleKey(.{ .key = .text, .text = "git d" });
    try applyTestHistoryRequests(&session);
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git d", session.history_search_query.items);
    try std.testing.expect(session.selectedHistorySearchMatch() != null);
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);
}

test "history search uses fuzzy query matching" {
    const entries = [_][]const u8{ "git status", "git checkout", "git diff" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
        .search_next = testSearchNextHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "gco" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("gco", session.history_search_query.items);
    try std.testing.expect(session.selectedHistorySearchMatch() != null);
    try std.testing.expectEqualStrings("git checkout", session.selectedHistorySearchMatch().?.text);
    try std.testing.expectEqual(@as(usize, 1), session.history_search_matches.items.len);

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[33mg\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[33mc\x1b[39m") != null);

    try session.handleKey(.{ .key = .delete_to_start });
    try applyTestHistoryRequests(&session);
    try session.handleKey(.{ .key = .text, .text = "zz" });
    try applyTestHistoryRequests(&session);
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expect(session.selectedHistorySearchMatch() == null);
    try std.testing.expectEqual(@as(usize, 0), session.history_search_matches.items.len);
}

test "history search first tab advances the already-open menu" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
        .search_next = testSearchNextHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);
    try std.testing.expectEqualStrings("git show", session.selectedHistorySearchMatch().?.text);
    try std.testing.expectEqual(@as(usize, 3), session.history_search_matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.history_search_selected);

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "show") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "diff") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[33mg\x1b[39m") != null);

    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git", session.editor.buffer.text());
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);
    try std.testing.expectEqual(@as(usize, 1), session.history_search_selected);

    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("git status", session.selectedHistorySearchMatch().?.text);
    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqualStrings("git status", session.selectedHistorySearchMatch().?.text);

    try session.handleKey(.{ .key = .enter });
    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
}

test "history search renders multiline commands as single menu rows" {
    const entries = [_][]const u8{ "printf one\ntwo", "printf three" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "printf" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);

    var frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer frame.deinit(std.testing.allocator);

    var multiline_row: ?[]const u8 = null;
    for (frame.lines) |line| {
        if (std.mem.indexOf(u8, line, "one two") != null) {
            multiline_row = line;
            break;
        }
    }

    try std.testing.expect(multiline_row != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, multiline_row.?, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, multiline_row.?, '\r') == null);
}

test "history search menu line-feeds when diff adds rows" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
        .search_next = testSearchNextHistoryEntry,
    });
    defer session.deinit();
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var input_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer input_frame.deinit(std.testing.allocator);
    const input_output = try renderer.render(std.testing.allocator, input_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(input_output);

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);
    var menu_frame = try session.renderFrame(std.testing.allocator, .{ .height = 8, .synchronized_output = false });
    defer menu_frame.deinit(std.testing.allocator);
    const menu_output = try renderer.render(std.testing.allocator, menu_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_output);

    try std.testing.expect(std.mem.indexOf(u8, menu_output, "\r\n\x1b[2K") != null);
    try std.testing.expect(std.mem.indexOf(u8, menu_output, "show") != null);

    try session.handleKey(.{ .key = .down });
    var moved_frame = try session.renderFrame(std.testing.allocator, .{ .height = 8, .synchronized_output = false });
    defer moved_frame.deinit(std.testing.allocator);
    const moved_output = try renderer.render(std.testing.allocator, moved_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(moved_output);

    try std.testing.expect(std.mem.indexOf(u8, moved_output, "\r\n\x1b[2K") == null);
    try std.testing.expect(std.mem.indexOf(u8, moved_output, "\x1b[1B\r\x1b[2K") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved_output, "diff") != null);
}

test "history search menu caps visible candidates at sixteen rows" {
    const entries = [_][]const u8{
        "cmd00", "cmd01", "cmd02", "cmd03", "cmd04", "cmd05",
        "cmd06", "cmd07", "cmd08", "cmd09", "cmd10", "cmd11",
        "cmd12", "cmd13", "cmd14", "cmd15", "cmd16", "cmd17",
    };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 40 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cmd17") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cmd02") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cmd01") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "showing 1-16 of 18") != null);
}

test "history search ignores modifier-only text events" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
        .search_next = testSearchNextHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);
    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqual(@as(usize, 1), session.history_search_selected);
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);

    try session.handleKey(.{ .key = .text, .text = "", .modifiers = .{ .shift = true } });

    try std.testing.expectEqual(@as(usize, 1), session.history_search_selected);
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);
    try std.testing.expectEqualStrings("git", session.editor.buffer.text());
}

test "history search refreshes only when query changes" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
        .search_next = testSearchNextHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);
    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqual(@as(usize, 1), session.history_search_selected);
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);

    try session.handleKey(.{ .key = .delete });

    try std.testing.expectEqual(@as(usize, 1), session.history_search_selected);
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);
    try std.testing.expectEqualStrings("git", session.history_search_query.items);
}

test "history search shift tab clamps at first match" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
        .search_next = testSearchNextHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);
    try std.testing.expectEqualStrings("git show", session.selectedHistorySearchMatch().?.text);

    try session.handleKey(.{ .key = .tab, .modifiers = .{ .shift = true } });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git show", session.selectedHistorySearchMatch().?.text);

    try session.handleKey(.{ .key = keyFromVaxis('p', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("git show", session.selectedHistorySearchMatch().?.text);

    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);
}

test "history search ctrl n and ctrl p clamp like completion" {
    const entries = [_][]const u8{ "git status", "git diff", "git show" };
    var history: TestHistorySearch = .{ .entries = &entries };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{
        .context = &history,
        .search = testSearchHistoryEntry,
        .search_next = testSearchNextHistoryEntry,
    });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .ctrl_r });
    try applyTestHistoryRequests(&session);
    try std.testing.expectEqualStrings("git show", session.selectedHistorySearchMatch().?.text);

    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);

    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("git status", session.selectedHistorySearchMatch().?.text);

    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqualStrings("git status", session.selectedHistorySearchMatch().?.text);

    try session.handleKey(.{ .key = keyFromVaxis('p', .{ .ctrl = true }) });
    try std.testing.expectEqual(LineSession.State.history_search, session.state);
    try std.testing.expectEqualStrings("git diff", session.selectedHistorySearchMatch().?.text);
}

test "line session hides older duplicate history commands" {
    const entries = [_][]const u8{ "git status", "echo hi", "git status", "git diff" };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git diff", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
}

test "line session inserts enter literally during paste" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();

    session.beginPaste();
    try session.handleKey(.{ .key = .text, .text = "echo" });
    try session.handleKey(.{ .key = .enter });
    try session.handleKey(.{ .key = .text, .text = "hi" });
    session.endPaste();

    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings("echo\nhi", session.editor.buffer.text());
}

test "line session inserts and renders pasted newlines" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();

    try session.handlePaste("echo one\r\necho two");

    try std.testing.expectEqualStrings("echo one\necho two", session.editor.buffer.text());
    var frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), frame.input_line_count);
    try std.testing.expectEqualStrings("$ echo one", frame.lines[0]);
    try std.testing.expectEqualStrings("echo two", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 8), frame.cursor_col);
}

test "prompt invalidation preserves edit state and redraws through session" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git status" });
    try session.handleKey(.{ .key = .word_left });
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 10 },
        .{ .value = "stash", .kind = .subcommand, .replace_start = 4, .replace_end = 10 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    session.invalidatePrompt();
    try std.testing.expect(session.takePromptInvalidation());
    try session.replacePrompt(.{ .bytes = "\x1b[34mrush> \x1b[0m", .visible_width = 6 });

    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 4), session.editor.buffer.cursor_byte);
    try std.testing.expectEqual(@as(usize, 2), session.completion_menu.candidates.len);

    const rendered = try session.render(std.testing.allocator, .{
        .synchronized_output = false,
        .semantic_prompt_marks = true,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered,
        "\x1b[34mrush> \x1b[0m" ++ semanticPromptEnd ++ "git status",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "stash") != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "\r\x1b[10C"));
}

test "render line redraws prompt and buffer inside synchronized output" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "abc" });
    editor.buffer.moveLeft();

    const rendered = try renderLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "$ " } });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\x1b[?2026h\r\x1b[2K$ abc\r\x1b[4C\x1b[?2026l", rendered);
}

test "render line can omit synchronized output" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "界" });

    const rendered = try renderLine(std.testing.allocator, editor, .{
        .prompt = .{ .bytes = "> " },
        .synchronized_output = false,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2K> 界\r\x1b[4C", rendered);
}

test "render line ignores ansi prompt bytes for cursor placement" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "x" });

    const rendered = try renderLine(std.testing.allocator, editor, .{
        .prompt = .{ .bytes = "\x1b[34mrush> \x1b[0m" },
        .synchronized_output = false,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2K\x1b[34mrush> \x1b[0mx\r\x1b[7C", rendered);
}

test "frame wraps long input at terminal width" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "abcdef" });

    var frame = try frameFromLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "$ " }, .width = 5 });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.lines.len);
    try std.testing.expectEqualStrings("$ abc", frame.lines[0]);
    try std.testing.expectEqualStrings("def", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 3), frame.cursor_col);
}

test "frame wrapping keeps cursor on trailing empty row at exact width" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "abc" });

    var frame = try frameFromLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "$ " }, .width = 5 });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.lines.len);
    try std.testing.expectEqualStrings("$ abc", frame.lines[0]);
    try std.testing.expectEqualStrings("", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), frame.cursor_col);
}

test "frame wrapping preserves prompt escape sequences" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "abcd" });

    var frame = try frameFromLine(std.testing.allocator, editor, .{
        .prompt = .{ .bytes = "\x1b[34m$ \x1b[0m", .visible_width = 2 },
        .width = 4,
    });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.lines.len);
    try std.testing.expectEqualStrings("\x1b[34m$ \x1b[0mab", frame.lines[0]);
    try std.testing.expectEqualStrings("cd", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), frame.cursor_col);
}

test "frame wrapping computes cursor with wide graphemes" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "ab界" });

    var frame = try frameFromLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "$ " }, .width = 5 });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.lines.len);
    try std.testing.expectEqualStrings("$ ab", frame.lines[0]);
    try std.testing.expectEqualStrings("界", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), frame.cursor_col);
}

test "frame renderer diffs changed input line" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var first_editor = Editor.init(std.testing.allocator);
    defer first_editor.deinit();
    try first_editor.handleKey(.{ .key = .text, .text = "a" });
    var first = try frameFromLine(std.testing.allocator, first_editor, .{
        .prompt = .{ .bytes = "$ " },
        .synchronized_output = false,
    });
    defer first.deinit(std.testing.allocator);
    const first_output = try renderer.render(std.testing.allocator, first, .{ .synchronized_output = false });
    defer std.testing.allocator.free(first_output);
    try std.testing.expect(std.mem.indexOf(u8, first_output, "\x1b[J") == null);

    var second_editor = Editor.init(std.testing.allocator);
    defer second_editor.deinit();
    try second_editor.handleKey(.{ .key = .text, .text = "ab" });
    var second = try frameFromLine(std.testing.allocator, second_editor, .{
        .prompt = .{ .bytes = "$ " },
        .synchronized_output = false,
    });
    defer second.deinit(std.testing.allocator);
    const second_output = try renderer.render(std.testing.allocator, second, .{ .synchronized_output = false });
    defer std.testing.allocator.free(second_output);

    try std.testing.expect(std.mem.indexOf(u8, second_output, "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\x1b[2K$ ab") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\r\x1b[0C") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\r\x1b[4C") != null);
}

test "frame renderer clears current frame before interrupt output" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    var frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer frame.deinit(std.testing.allocator);
    const rendered = try renderer.render(std.testing.allocator, frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    const prefix = try renderer.interruptOutputPrefix(std.testing.allocator);
    defer std.testing.allocator.free(prefix);
    try std.testing.expectEqual(frame.lines.len, std.mem.count(u8, prefix, "\x1b[2K"));
    try std.testing.expect(std.mem.endsWith(u8, prefix, "\r"));
}

test "frame renderer line-feeds when diff adds rows" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    var input_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer input_frame.deinit(std.testing.allocator);
    const input_output = try renderer.render(std.testing.allocator, input_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(input_output);

    try session.applyCompletion(.{ .ambiguous = &candidates });
    var menu_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer menu_frame.deinit(std.testing.allocator);
    const menu_output = try renderer.render(std.testing.allocator, menu_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_output);

    try std.testing.expect(std.mem.indexOf(u8, menu_output, "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, menu_output, "\r\n\x1b[2K") != null);
    try std.testing.expect(std.mem.indexOf(u8, menu_output, "checkout") != null);
}

test "frame renderer diffs added third wrapped row" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var first_editor = Editor.init(std.testing.allocator);
    defer first_editor.deinit();
    try first_editor.buffer.replace("abcdef");
    var first = try frameFromLine(std.testing.allocator, first_editor, .{
        .prompt = .{ .bytes = "$ " },
        .width = 5,
        .synchronized_output = false,
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), first.lines.len);
    try std.testing.expectEqual(@as(usize, 1), first.cursor_row);
    const first_output = try renderer.render(std.testing.allocator, first, .{ .synchronized_output = false });
    defer std.testing.allocator.free(first_output);

    var second_editor = Editor.init(std.testing.allocator);
    defer second_editor.deinit();
    try second_editor.buffer.replace("abcdefgh");
    var second = try frameFromLine(std.testing.allocator, second_editor, .{
        .prompt = .{ .bytes = "$ " },
        .width = 5,
        .synchronized_output = false,
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), second.lines.len);

    const second_output = try renderer.render(std.testing.allocator, second, .{ .synchronized_output = false });
    defer std.testing.allocator.free(second_output);

    try std.testing.expect(std.mem.startsWith(u8, second_output, "\r\x1b[2Kdefgh"));
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\r\n\x1b[2K\r") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "$ abc") == null);
}

test "frame renderer diffs when frame removes lines" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    var menu_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer menu_frame.deinit(std.testing.allocator);
    const menu_output = try renderer.render(std.testing.allocator, menu_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_output);

    try session.handleKey(.{ .key = .tab });
    try session.handleKey(.{ .key = .enter });
    var accepted_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer accepted_frame.deinit(std.testing.allocator);
    const accepted_output = try renderer.render(std.testing.allocator, accepted_frame, .{
        .synchronized_output = false,
    });
    defer std.testing.allocator.free(accepted_output);

    try std.testing.expect(std.mem.indexOf(u8, accepted_output, "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_output, "\x1b[2K$ checkout ") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_output, "\x1b[1B\r\x1b[2K") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, accepted_output, "\x1b[1B\r\x1b[2K"));
    try std.testing.expect(std.mem.indexOf(u8, accepted_output, "cherry-pick") == null);
}

test "frame renderer clears old wrapped row when input shrinks" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var first_editor = Editor.init(std.testing.allocator);
    defer first_editor.deinit();
    try first_editor.buffer.replace("abcdefgh");
    var first = try frameFromLine(std.testing.allocator, first_editor, .{
        .prompt = .{ .bytes = "$ " },
        .width = 5,
        .synchronized_output = false,
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), first.lines.len);
    const first_output = try renderer.render(std.testing.allocator, first, .{ .synchronized_output = false });
    defer std.testing.allocator.free(first_output);

    var second_editor = Editor.init(std.testing.allocator);
    defer second_editor.deinit();
    try second_editor.buffer.replace("abcdef");
    var second = try frameFromLine(std.testing.allocator, second_editor, .{
        .prompt = .{ .bytes = "$ " },
        .width = 5,
        .synchronized_output = false,
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), second.lines.len);

    const second_output = try renderer.render(std.testing.allocator, second, .{ .synchronized_output = false });
    defer std.testing.allocator.free(second_output);

    try std.testing.expect(std.mem.startsWith(u8, second_output, "\x1b[1A\r\x1b[2Kdef"));
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\x1b[1B\r\x1b[2K") != null);
    try std.testing.expect(std.mem.endsWith(u8, second_output, "\x1b[1A\r\x1b[3C"));
}

test "frame renderer clears menu rows when escape closes completion menu" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git ch");
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    var menu_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer menu_frame.deinit(std.testing.allocator);
    const menu_output = try renderer.render(std.testing.allocator, menu_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_output);

    try session.handleKey(.{ .key = .escape });
    try std.testing.expect(!session.hasCompletionMenu());
    var closed_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer closed_frame.deinit(std.testing.allocator);
    const clear_output = try renderer.render(std.testing.allocator, closed_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(clear_output);

    try std.testing.expect(std.mem.indexOf(u8, clear_output, "\x1b[J") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, clear_output, "\x1b[2K"));
    try std.testing.expect(std.mem.indexOf(u8, clear_output, "\x1b[2K$ git ch") == null);
    try std.testing.expect(std.mem.indexOf(u8, clear_output, "checkout") == null);
    try std.testing.expect(std.mem.indexOf(u8, clear_output, "cherry-pick") == null);
}

test "line session cancel discards rendered input and menu state" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git ch");
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    var menu_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer menu_frame.deinit(std.testing.allocator);
    const menu_output = try renderer.render(std.testing.allocator, menu_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_output);

    try session.cancel();
    try std.testing.expect(!session.hasCompletionMenu());
    try std.testing.expectEqualStrings("", session.editor.buffer.text());
    try std.testing.expectEqual(LineSession.State.canceled, session.state);
}

test "submitted handoff moves to bottom of wrapped input without clearing it" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.buffer.replace("abcdef");
    editor.buffer.moveHome();

    var frame = try frameFromLine(std.testing.allocator, editor, .{
        .prompt = .{ .bytes = "$ " },
        .width = 5,
        .synchronized_output = false,
    });
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), frame.input_line_count);
    const rendered = try renderer.render(std.testing.allocator, frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    const handoff = try renderer.submittedHandoff(std.testing.allocator);
    defer std.testing.allocator.free(handoff);

    try std.testing.expectEqualStrings("\x1b[1B\r", handoff);
    try std.testing.expect(std.mem.indexOf(u8, handoff, "\x1b[2K") == null);
    try std.testing.expect(std.mem.indexOf(u8, handoff, "\x1b[J") == null);
}

test "submitted prompt can be replaced before handoff" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("echo ok");

    var first_frame = try session.renderFrame(std.testing.allocator, .{
        .width = 80,
        .synchronized_output = false,
    });
    defer first_frame.deinit(std.testing.allocator);
    const first_output = try renderer.render(std.testing.allocator, first_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(first_output);

    try session.handleKey(.{ .key = .enter });
    try session.replacePrompt(.{ .bytes = "● " });
    var transient_frame = try session.renderFrame(std.testing.allocator, .{
        .width = 80,
        .synchronized_output = false,
    });
    defer transient_frame.deinit(std.testing.allocator);
    const transient_output = try renderer.render(
        std.testing.allocator,
        transient_frame,
        .{ .synchronized_output = false },
    );
    defer std.testing.allocator.free(transient_output);

    try std.testing.expect(std.mem.indexOf(u8, transient_output, "\x1b[2K● echo ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, transient_output, "$ echo ok") == null);
}

test "submitted handoff clears completion rows but preserves wrapped input rows" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git checkout");
    session.editor.buffer.moveHome();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 4, .replace_end = 12 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 4, .replace_end = 12 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    var frame = try session.renderFrame(std.testing.allocator, .{ .width = 8, .synchronized_output = false });
    defer frame.deinit(std.testing.allocator);
    try std.testing.expect(frame.input_line_count > 1);
    try std.testing.expect(frame.lines.len > frame.input_line_count);
    const rendered = try renderer.render(std.testing.allocator, frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    const handoff = try renderer.submittedHandoff(std.testing.allocator);
    defer std.testing.allocator.free(handoff);

    try std.testing.expect(std.mem.indexOf(u8, handoff, "\x1b[J") == null);
    try std.testing.expectEqual(frame.lines.len - frame.input_line_count, std.mem.count(u8, handoff, "\x1b[2K"));
    try std.testing.expect(std.mem.endsWith(u8, handoff, "\r"));
}
