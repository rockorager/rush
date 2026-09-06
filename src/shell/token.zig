//! Tokens produced by the shell lexer.

const std = @import("std");

const source = @import("source.zig");

pub const Kind = enum {
    word,
    newline,
    semicolon,
    double_semicolon,
    semicolon_ampersand,
    double_semicolon_ampersand,
    ampersand,
    ampersand_greater,
    ampersand_greater_greater,
    pipe,
    pipe_ampersand,
    pipe_pipe,
    ampersand_ampersand,
    bang,
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    less,
    less_less,
    less_less_dash,
    less_less_less,
    less_ampersand,
    less_greater,
    greater,
    greater_greater,
    greater_ampersand,
    clobber,
    io_number,
    /// Processed here-document body emitted after the newline that starts
    /// it. The span covers the raw body including the delimiter line; the
    /// text holds the body with <tab> stripping already applied and the
    /// delimiter line excluded. `quoted` records a quoted delimiter, which
    /// suppresses expansion of the body.
    here_doc_body,
    /// A here-document body whose delimiter line was not found before the
    /// end of input; the body runs to the end of the input.
    here_doc_body_unterminated,
    eof,
};

pub const ReservedWord = enum {
    if_kw,
    then_kw,
    else_kw,
    elif_kw,
    fi_kw,
    do_kw,
    done_kw,
    case_kw,
    esac_kw,
    while_kw,
    until_kw,
    for_kw,
    in_kw,
    function_kw,
};

const ReservedWordMap = std.StaticStringMap(ReservedWord);

pub const reserved_words: ReservedWordMap = .initComptime(.{
    .{ "case", .case_kw },
    .{ "do", .do_kw },
    .{ "done", .done_kw },
    .{ "elif", .elif_kw },
    .{ "else", .else_kw },
    .{ "esac", .esac_kw },
    .{ "fi", .fi_kw },
    .{ "for", .for_kw },
    .{ "function", .function_kw },
    .{ "if", .if_kw },
    .{ "in", .in_kw },
    .{ "then", .then_kw },
    .{ "until", .until_kw },
    .{ "while", .while_kw },
});

pub fn lookupReservedWord(text: []const u8) ?ReservedWord {
    return reserved_words.get(text);
}

/// True when the reserved word is followed by a command list, so the next
/// word is back in command position.
pub fn reservedWordStartsCommandList(reserved: ReservedWord) bool {
    return switch (reserved) {
        .if_kw, .then_kw, .else_kw, .elif_kw, .do_kw, .while_kw, .until_kw => true,
        else => false,
    };
}

/// True when the token ends the current command so the next word is in
/// command position.
pub fn startsCommandPosition(kind: Kind) bool {
    return switch (kind) {
        .newline,
        .semicolon,
        .ampersand,
        .ampersand_greater,
        .ampersand_greater_greater,
        .pipe,
        .pipe_ampersand,
        .pipe_pipe,
        .ampersand_ampersand,
        .bang,
        .left_paren,
        .right_paren,
        .left_brace,
        .here_doc_body,
        .here_doc_body_unterminated,
        => true,
        else => false,
    };
}

/// True when the token is a redirection operator whose next word is the
/// redirection target rather than command text.
pub fn isRedirectionOperator(kind: Kind) bool {
    return switch (kind) {
        .less,
        .less_less,
        .less_less_dash,
        .less_less_less,
        .less_ampersand,
        .less_greater,
        .greater,
        .greater_greater,
        .greater_ampersand,
        .ampersand_greater,
        .ampersand_greater_greater,
        .clobber,
        => true,
        else => false,
    };
}

/// True when the raw word text has the shape of a shell assignment word
/// (`NAME=...` or the Bash-compatible `NAME+=...`).
pub fn isAssignmentWord(text: []const u8) bool {
    const equals_index = std.mem.indexOfScalar(u8, text, '=') orelse return false;
    const name_end = if (equals_index > 0 and text[equals_index - 1] == '+') equals_index - 1 else equals_index;
    const name = text[0..name_end];
    if (name.len == 0) return false;
    if (!isNameStart(name[0])) return false;
    for (name[1..]) |byte| if (!isNameContinue(byte)) return false;
    return true;
}

fn isNameStart(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '_' => true,
        else => false,
    };
}

fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or switch (byte) {
        '0'...'9' => true,
        else => false,
    };
}

/// Walks a token stream and classifies each word by its grammatical role.
/// This is the single shared notion of "command position" used by the
/// interactive diagnostics and completion analysis.
///
/// Reserved words are only recognized in command position, matching the
/// grammar rather than the lexer's lexical marking. IO numbers preserve
/// command position because redirections may precede the command word.
pub const CommandPositionTracker = struct {
    command_position: bool = true,
    skip_redirection_target: bool = false,

    pub const Class = enum {
        /// Word in command position: the command name of its command.
        command,
        /// Assignment word before the command name; command position persists.
        assignment,
        /// Reserved word recognized in command position.
        reserved,
        /// Word in argument position.
        argument,
        /// Word consumed as the target of a preceding redirection operator.
        redirection_target,
        /// Any non-word token.
        operator,
    };

    pub fn classify(self: *CommandPositionTracker, tok: Token) Class {
        if (tok.kind == .word) {
            if (self.skip_redirection_target) {
                self.skip_redirection_target = false;
                return .redirection_target;
            }
            if (!self.command_position) return .argument;
            if (tok.reserved) |reserved| {
                self.command_position = reservedWordStartsCommandList(reserved);
                return .reserved;
            }
            if (isAssignmentWord(tok.text)) return .assignment;
            self.command_position = false;
            return .command;
        }
        if (tok.kind == .io_number) return .operator;
        if (isRedirectionOperator(tok.kind)) {
            self.skip_redirection_target = true;
            return .operator;
        }
        self.command_position = startsCommandPosition(tok.kind);
        return .operator;
    }
};

pub const Token = struct {
    kind: Kind,
    span: source.Span,
    text: []const u8 = "",
    reserved: ?ReservedWord = null,
    quoted: bool = false,

    pub fn validate(self: Token) void {
        self.span.validate();
        if (self.reserved != null) {
            std.debug.assert(self.kind == .word);
            std.debug.assert(!self.quoted);
            std.debug.assert(self.text.len != 0);
        }
        switch (self.kind) {
            .word, .io_number => std.debug.assert(self.text.len != 0),
            .here_doc_body, .here_doc_body_unterminated => {},
            else => std.debug.assert(!self.quoted),
        }
    }
};

/// Retained lexer output. Source identity and line starts are shared, and only
/// text that differs from its raw source range needs a separate slice. Offsets
/// and indices remain native-sized. `get` materializes a full token by value;
/// lookahead can inspect `items` without reconstructing diagnostic locations.
/// Source and normalized text are borrowed and must outlive the stream and AST.
pub const Stream = struct {
    source_id: source.SourceId = 0,
    source_text: []const u8 = "",
    items: []const StoredToken = &.{},
    lines: []const Line = &.{},
    text_overrides: []const []const u8 = &.{},

    const no_text_override = std.math.maxInt(usize);

    // Only lines on which tokens start need entries. Multiline words and
    // here-documents must not allocate metadata for every embedded newline.
    const Line = struct {
        start: usize,
        number: usize,
    };

    const StoredToken = struct {
        start: usize,
        end: usize,
        text_index: usize = no_text_override,
        kind: Kind,
        reserved: ?ReservedWord,
        quoted: bool,
    };

    /// Releases storage and metadata, not borrowed source or normalized text.
    /// All copies of this stream become invalid; previously decoded text stays valid.
    pub fn deinit(self: Stream, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        allocator.free(self.lines);
        allocator.free(self.text_overrides);
    }

    pub fn get(self: Stream, index: usize) Token {
        const stored = self.items[index];
        const line_index = std.sort.upperBound(Line, self.lines, stored.start, compareOffset);
        std.debug.assert(line_index != 0);
        const line = self.lines[line_index - 1];
        return .{
            .kind = stored.kind,
            .span = .{
                .source_id = self.source_id,
                .start = stored.start,
                .end = stored.end,
                .start_line = line.number,
                .start_column = stored.start - line.start + 1,
            },
            .text = if (stored.text_index != no_text_override)
                self.text_overrides[stored.text_index]
            else switch (stored.kind) {
                .word,
                .io_number,
                .here_doc_body,
                .here_doc_body_unterminated,
                => self.source_text[stored.start..stored.end],
                else => "",
            },
            .reserved = stored.reserved,
            .quoted = stored.quoted,
        };
    }

    fn compareOffset(offset: usize, line: Line) std.math.Order {
        return std.math.order(offset, line.start);
    }

    /// Builds compact storage directly, without first retaining full tokens.
    pub const Builder = struct {
        src: source.Source,
        items: std.ArrayList(StoredToken) = .empty,
        lines: std.ArrayList(Line) = .empty,
        text_overrides: std.ArrayList([]const u8) = .empty,

        // ziglint-ignore: Z023 nested builder method receiver precedes allocator
        pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
            self.lines.deinit(allocator);
            self.text_overrides.deinit(allocator);
            self.* = undefined;
        }

        /// Appends tokens in source order and borrows their text. Appending may
        /// invalidate slices; after allocation failure, discard the builder.
        // ziglint-ignore: Z023 nested builder method receiver precedes allocator
        pub fn append(self: *Builder, allocator: std.mem.Allocator, tok: Token) !void {
            tok.validate();
            std.debug.assert(tok.span.source_id == self.src.id);
            std.debug.assert(tok.span.end <= self.src.text.len);
            std.debug.assert(tok.span.start_column - 1 <= tok.span.start);
            const line: Line = .{
                .start = tok.span.start - (tok.span.start_column - 1),
                .number = tok.span.start_line,
            };
            if (self.lines.getLastOrNull()) |previous| {
                std.debug.assert(line.number >= previous.number);
                if (line.number == previous.number) {
                    std.debug.assert(line.start == previous.start);
                } else {
                    std.debug.assert(line.start > previous.start);
                    try self.lines.append(allocator, line);
                }
            } else {
                try self.lines.append(allocator, line);
            }
            var stored: StoredToken = .{
                .start = tok.span.start,
                .end = tok.span.end,
                .kind = tok.kind,
                .reserved = tok.reserved,
                .quoted = tok.quoted,
            };
            switch (tok.kind) {
                .word, .io_number, .here_doc_body, .here_doc_body_unterminated => {
                    const raw = self.src.text[stored.start..stored.end];
                    if (tok.text.ptr != raw.ptr or tok.text.len != raw.len) {
                        stored.text_index = self.text_overrides.items.len;
                        try self.text_overrides.append(allocator, tok.text);
                    }
                },
                else => std.debug.assert(tok.text.len == 0),
            }
            try self.items.append(allocator, stored);
        }

        /// Transfers storage to the caller, leaving the builder empty. Line
        /// locations come from the lexer's raw spans, never normalized text.
        // ziglint-ignore: Z023 nested builder method receiver precedes allocator
        pub fn toOwnedStream(self: *Builder, allocator: std.mem.Allocator) !Stream {
            std.debug.assert(self.lines.items.len <= self.items.items.len);
            const lines = try self.lines.toOwnedSlice(allocator);
            errdefer allocator.free(lines);
            const items = try self.items.toOwnedSlice(allocator);
            errdefer allocator.free(items);
            return .{
                .source_id = self.src.id,
                .source_text = self.src.text,
                .items = items,
                .lines = lines,
                .text_overrides = try self.text_overrides.toOwnedSlice(allocator),
            };
        }
    };
};

const test_lexer = @import("lexer.zig");

test "command position tracker classifies assignments redirections and segments" {
    const src = "FOO=bar cached < nope; if tr";
    const source_file: source.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = src };
    const tokens = try test_lexer.lex(std.testing.allocator, source_file);
    defer tokens.deinit(std.testing.allocator);

    var tracker: CommandPositionTracker = .{};
    var classes: std.ArrayList(CommandPositionTracker.Class) = .empty;
    defer classes.deinit(std.testing.allocator);
    for (0..tokens.items.len) |index| {
        const tok = tokens.get(index);
        if (tok.kind == .eof) break;
        try classes.append(std.testing.allocator, tracker.classify(tok));
    }

    const expected = [_]CommandPositionTracker.Class{
        .assignment, // FOO=bar
        .command, // cached
        .operator, // <
        .redirection_target, // nope
        .operator, // ;
        .reserved, // if
        .command, // tr
    };
    try std.testing.expectEqualSlices(CommandPositionTracker.Class, &expected, classes.items);
}

test "command position tracker treats reserved words as arguments outside command position" {
    const src = "echo if foo";
    const source_file: source.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = src };
    const tokens = try test_lexer.lex(std.testing.allocator, source_file);
    defer tokens.deinit(std.testing.allocator);

    var tracker: CommandPositionTracker = .{};
    try std.testing.expectEqual(CommandPositionTracker.Class.command, tracker.classify(tokens.get(0)));
    try std.testing.expectEqual(CommandPositionTracker.Class.argument, tracker.classify(tokens.get(1)));
    try std.testing.expectEqual(CommandPositionTracker.Class.argument, tracker.classify(tokens.get(2)));
}

test "reserved word lookup uses static map" {
    try std.testing.expectEqual(ReservedWord.if_kw, lookupReservedWord("if").?);
    try std.testing.expectEqual(ReservedWord.then_kw, lookupReservedWord("then").?);
    try std.testing.expectEqual(ReservedWord.done_kw, lookupReservedWord("done").?);
    try std.testing.expectEqual(@as(?ReservedWord, null), lookupReservedWord("printf"));
}

test "compact stream reconstructs raw locations including normalized tokens and EOF" {
    const inputs = [_][]const u8{
        "",
        "\n",
        "# comment\n\n",
        "\té\r\nif true; then :; fi",
        "echo foo\\\nbar\ncat <<-E\n\tbody\n\tE\necho next\n",
        "cat <<'E'\nE\ncat <<E\nunterminated",
        "echo 'multiple\nlines' $(printf x\n) 2>out &>>log",
    };
    for (inputs) |text| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src: source.Source = .{ .id = 37, .kind = .script_file, .name = "test", .text = text };
        const stream = try test_lexer.lexWithTokenAllocator(arena.allocator(), std.testing.allocator, src);
        defer stream.deinit(std.testing.allocator);
        var position: source.Position = .{ .source_id = src.id };
        for (0..stream.items.len) |index| {
            const tok = stream.get(index);
            position.advance(text[position.byte_offset..tok.span.start]);
            try std.testing.expectEqualDeep(source.Span.init(position, tok.span.end), tok.span);
            tok.validate();
        }
        const eof = stream.get(stream.items.len - 1);
        try std.testing.expectEqual(Kind.eof, eof.kind);
        try std.testing.expectEqual(text.len, eof.span.end);
    }
}

test "compact stream preserves full token values and sparse text overrides" {
    const text = "if foo\\\nbar\n";
    const src: source.Source = .{ .id = 4, .kind = .script_file, .name = "test", .text = text };
    const expected = [_]Token{
        .{ .kind = .word, .span = .{ .source_id = 4, .end = 2 }, .text = text[0..2], .reserved = .if_kw },
        .{
            .kind = .word,
            .span = .{ .source_id = 4, .start = 3, .end = 11, .start_column = 4 },
            .text = "foobar",
        },
        .{
            .kind = .newline,
            .span = .{ .source_id = 4, .start = 11, .end = 12, .start_line = 2, .start_column = 4 },
        },
        .{ .kind = .eof, .span = .{ .source_id = 4, .start = 12, .end = 12, .start_line = 3 } },
    };
    var builder: Stream.Builder = .{ .src = src };
    defer builder.deinit(std.testing.allocator);
    for (expected) |tok| try builder.append(std.testing.allocator, tok);
    const stream = try builder.toOwnedStream(std.testing.allocator);
    defer stream.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), stream.text_overrides.len);
    for (expected, 0..) |tok, index| try std.testing.expectEqualDeep(tok, stream.get(index));
    try std.testing.expect(@sizeOf(Stream.StoredToken) * 2 <= @sizeOf(Token));
}

test "compact stream bounds line metadata for large here-documents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src: source.Source = .{
        .id = 1,
        .kind = .script_file,
        .name = "test",
        .text = "cat <<E\n" ++ ("\n" ** 4096) ++ "E\n",
    };
    const stream = try test_lexer.lex(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 6), stream.items.len);
    try std.testing.expectEqual(@as(usize, 3), stream.lines.len);
    try std.testing.expectEqual(@as(usize, 4096), stream.get(4).text.len);
    try std.testing.expectEqual(@as(usize, 4099), stream.get(5).span.start_line);
}

test "compact stream reclaims storage on allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var text_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer text_arena.deinit();
            const src: source.Source = .{
                .id = 8,
                .kind = .script_file,
                .name = "test",
                .text = "echo foo\\\nbar\ncat <<-E\n\tbody\n\tE\n" ** 32,
            };
            const stream = try test_lexer.lexWithTokenAllocator(text_arena.allocator(), allocator, src);
            defer stream.deinit(allocator);
        }
    }.run, .{});
}
