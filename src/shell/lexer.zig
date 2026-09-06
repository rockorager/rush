//! Tokenizes shell source, records display trivia, and expands command-position
//! aliases. Token storage uses the caller's allocator, while token text usually
//! refers into the source; normalized words and here-document bodies may use
//! allocator-backed text instead.

const std = @import("std");

const parse_scan = @import("parse_scan.zig");
const source_mod = @import("source.zig");
const state_mod = @import("state.zig");
const token = @import("token.zig");

pub const LexError = error{};

/// Returns allocator-backed token storage and metadata. `src.text` and
/// normalized token text must remain valid while the stream and AST are used;
/// call `deinit` to release only the stream's storage and metadata.
/// Use an arena when normalized text also needs to be reclaimed together.
pub fn lex(allocator: std.mem.Allocator, src: source_mod.Source) std.mem.Allocator.Error!token.Stream {
    return lexWithTokenAllocator(allocator, allocator, src);
}

/// Allocates the returned token storage and metadata with `token_allocator`,
/// independently of normalized text allocated with `allocator`. Deinitialize
/// the stream with `token_allocator`; source and normalized text remain borrowed.
/// A reclaiming token allocator avoids retaining old growable-array buffers
/// when text storage uses an arena.
pub fn lexWithTokenAllocator(
    allocator: std.mem.Allocator,
    token_allocator: std.mem.Allocator,
    src: source_mod.Source,
) std.mem.Allocator.Error!token.Stream {
    src.validate();
    var lexer: Lexer = .{
        .allocator = allocator,
        .token_allocator = token_allocator,
        .source = src,
        .position = .{ .source_id = src.id },
    };
    return lexer.lex();
}

/// Display-oriented lexical regions that carry no grammatical meaning and are
/// therefore absent from the token stream: comments, quoted regions, quoted
/// regions still missing their closing delimiter, and expansions embedded in
/// words. Spans are byte offsets into the source text. Interactive
/// highlighting consumes these so the editor never re-implements quote,
/// comment, or expansion scanning.
pub const Trivia = struct {
    pub const Kind = enum {
        comment,
        quote,
        pending_quote,
        /// Parameter, command, or arithmetic expansion: `$NAME`, `$1`, `$?`,
        /// `${...}`, `$(...)`, `$((...))`, backquotes, and process
        /// substitution. Inner trivia (quotes and comments inside a command
        /// substitution) is emitted first, so it wins span overlap.
        expansion,
    };

    kind: Kind,
    start: usize,
    end: usize,
};

/// Lexes like `lex` while also appending allocator-backed display trivia to
/// `trivia`. Token output has the same ownership and source lifetime as `lex`.
pub fn lexWithTrivia(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    trivia: *std.ArrayList(Trivia),
) std.mem.Allocator.Error!token.Stream {
    src.validate();
    var lexer: Lexer = .{
        .allocator = allocator,
        .token_allocator = allocator,
        .source = src,
        .position = .{ .source_id = src.id },
        .trivia = trivia,
    };
    return lexer.lex();
}

/// Alias-expanded source and its token stream. The returned values may borrow
/// `src`; replacement text and token storage use the supplied allocator and
/// must remain alive together.
pub const AliasLexResult = struct {
    source: source_mod.Source,
    tokens: token.Stream,
};

/// Context supplied by evaluator-owned parsing paths that require a narrow
/// exception to ordinary alias substitution.
pub const AliasOptions = struct {
    /// Protects the selected autoload function's declaration while its source
    /// is parsed. Ordinary shell input must leave this unset: alias eligibility
    /// is determined without considering tokens that follow the candidate. The
    /// name is borrowed for the duration of the lexing call.
    autoload_function_name: ?[]const u8 = null,
};

/// Text introduced by an alias remains marked until recursive alias
/// substitution finishes, so that alias cannot expand itself again while
/// independent occurrences of the same name remain eligible.
const ActiveAliasSpan = struct {
    start: usize,
    end: usize,
    name: []const u8,
};

const AliasExpansion = struct {
    text: []const u8,
    active_alias_spans: []const ActiveAliasSpan,
};

/// Returns allocator-backed tokens for the effective alias-expanded source.
/// Token text may borrow `src` or allocator-backed replacement text.
pub fn lexWithAliases(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    shell_state: state_mod.State,
) std.mem.Allocator.Error!token.Stream {
    return (try lexWithAliasesSource(allocator, src, shell_state)).tokens;
}

/// Returns the effective source together with tokens whose text refers to it.
/// Keep both values, the input source, and allocator-backed alias replacements
/// alive until parsing and AST use are complete.
pub fn lexWithAliasesSource(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    shell_state: state_mod.State,
) std.mem.Allocator.Error!AliasLexResult {
    return lexWithAliasesSourceOptions(allocator, src, shell_state, .{});
}

/// Matches `lexWithAliasesSource` ownership and lifetimes while allowing the
/// evaluator to identify an autoload function declaration that must retain its
/// requested name. Do not set the option for ordinary shell input.
pub fn lexWithAliasesSourceOptions(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    shell_state: state_mod.State,
    options: AliasOptions,
) std.mem.Allocator.Error!AliasLexResult {
    if (options.autoload_function_name) |name| std.debug.assert(name.len != 0);

    var current_src = src;
    var active_alias_spans: []const ActiveAliasSpan = &.{};
    while (true) {
        const tokens = try lex(allocator, current_src);
        const expanded = try aliasExpandedSource(
            allocator,
            current_src,
            tokens,
            shell_state,
            active_alias_spans,
            options,
        ) orelse return .{
            .source = current_src,
            .tokens = tokens,
        };
        current_src = .{ .id = src.id, .kind = src.kind, .name = src.name, .text = expanded.text };
        active_alias_spans = expanded.active_alias_spans;
    }
}

fn aliasExpandedSource(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    tokens: token.Stream,
    shell_state: state_mod.State,
    active_alias_spans: []const ActiveAliasSpan,
    options: AliasOptions,
) std.mem.Allocator.Error!?AliasExpansion {
    if (shell_state.aliases.count() == 0) return null;
    if (!aliasesEnabled(shell_state)) return null;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var rewritten_active_spans: std.ArrayList(ActiveAliasSpan) = .empty;
    errdefer rewritten_active_spans.deinit(allocator);
    var changed = false;
    var cursor: usize = 0;
    var command_position = true;
    var skip_redirection_target = false;

    for (0..tokens.items.len) |index| {
        const tok = tokens.get(index);
        if (tok.kind == .eof) break;
        try appendAliasSourceSlice(
            allocator,
            &output,
            &rewritten_active_spans,
            src,
            active_alias_spans,
            cursor,
            tok.span.start,
        );
        cursor = tok.span.end;

        if (skip_redirection_target and tok.kind == .word) {
            skip_redirection_target = false;
            try appendAliasSourceSlice(
                allocator,
                &output,
                &rewritten_active_spans,
                src,
                active_alias_spans,
                tok.span.start,
                tok.span.end,
            );
            continue;
        }

        if (tok.kind == .word) {
            if (tok.reserved) |reserved| {
                command_position = token.reservedWordStartsCommandList(reserved);
                try appendAliasSourceSlice(
                    allocator,
                    &output,
                    &rewritten_active_spans,
                    src,
                    active_alias_spans,
                    tok.span.start,
                    tok.span.end,
                );
                continue;
            }
            if (command_position and !tok.quoted and !token.isAssignmentWord(tok.text) and
                !isAutoloadFunctionDefinitionName(tokens, index, options.autoload_function_name))
            {
                if (shell_state.getAlias(tok.text)) |alias| {
                    if (!aliasIsActive(active_alias_spans, tok.span.start, tok.span.end, alias.name)) {
                        const replacement_start = output.items.len;
                        try output.appendSlice(allocator, alias.value);
                        try appendReplacementActiveAliases(
                            allocator,
                            &rewritten_active_spans,
                            active_alias_spans,
                            tok.span.start,
                            tok.span.end,
                            replacement_start,
                            output.items.len,
                        );
                        if (alias.value.len != 0) try rewritten_active_spans.append(allocator, .{
                            .start = replacement_start,
                            .end = output.items.len,
                            .name = alias.name,
                        });
                        command_position = aliasEndsWithBlank(alias.value);
                        changed = true;
                        continue;
                    }
                }
            }
            if (command_position and token.isAssignmentWord(tok.text)) {
                command_position = true;
            } else {
                command_position = false;
            }
            try appendAliasSourceSlice(
                allocator,
                &output,
                &rewritten_active_spans,
                src,
                active_alias_spans,
                tok.span.start,
                tok.span.end,
            );
            continue;
        }

        if (token.isRedirectionOperator(tok.kind)) {
            skip_redirection_target = true;
            try appendAliasSourceSlice(
                allocator,
                &output,
                &rewritten_active_spans,
                src,
                active_alias_spans,
                tok.span.start,
                tok.span.end,
            );
            continue;
        }

        command_position = token.startsCommandPosition(tok.kind);
        try appendAliasSourceSlice(
            allocator,
            &output,
            &rewritten_active_spans,
            src,
            active_alias_spans,
            tok.span.start,
            tok.span.end,
        );
    }

    if (!changed) {
        output.deinit(allocator);
        rewritten_active_spans.deinit(allocator);
        return null;
    }
    try appendAliasSourceSlice(
        allocator,
        &output,
        &rewritten_active_spans,
        src,
        active_alias_spans,
        cursor,
        src.text.len,
    );
    const expanded = try output.toOwnedSlice(allocator);
    errdefer allocator.free(expanded);
    return .{
        .text = expanded,
        .active_alias_spans = try rewritten_active_spans.toOwnedSlice(allocator),
    };
}

fn appendAliasSourceSlice(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    rewritten_active_spans: *std.ArrayList(ActiveAliasSpan),
    src: source_mod.Source,
    active_alias_spans: []const ActiveAliasSpan,
    start: usize,
    end: usize,
) std.mem.Allocator.Error!void {
    std.debug.assert(start <= end);
    std.debug.assert(end <= src.text.len);

    const output_start = output.items.len;
    try output.appendSlice(allocator, src.text[start..end]);
    for (active_alias_spans) |span| {
        const overlap_start = @max(start, span.start);
        const overlap_end = @min(end, span.end);
        if (overlap_start >= overlap_end) continue;
        try rewritten_active_spans.append(allocator, .{
            .start = output_start + overlap_start - start,
            .end = output_start + overlap_end - start,
            .name = span.name,
        });
    }
}

fn appendReplacementActiveAliases(
    allocator: std.mem.Allocator,
    rewritten_active_spans: *std.ArrayList(ActiveAliasSpan),
    active_alias_spans: []const ActiveAliasSpan,
    token_start: usize,
    token_end: usize,
    replacement_start: usize,
    replacement_end: usize,
) std.mem.Allocator.Error!void {
    if (replacement_start == replacement_end) return;
    for (active_alias_spans) |span| {
        if (span.start >= token_end or span.end <= token_start) continue;
        var already_active = false;
        for (rewritten_active_spans.items) |rewritten| {
            if (rewritten.start == replacement_start and
                rewritten.end == replacement_end and
                std.mem.eql(u8, rewritten.name, span.name))
            {
                already_active = true;
                break;
            }
        }
        if (!already_active) try rewritten_active_spans.append(allocator, .{
            .start = replacement_start,
            .end = replacement_end,
            .name = span.name,
        });
    }
}

fn aliasIsActive(
    active_alias_spans: []const ActiveAliasSpan,
    token_start: usize,
    token_end: usize,
    name: []const u8,
) bool {
    for (active_alias_spans) |span| {
        if (span.start < token_end and
            span.end > token_start and
            std.mem.eql(u8, span.name, name)) return true;
    }
    return false;
}

fn isAutoloadFunctionDefinitionName(
    tokens: token.Stream,
    index: usize,
    autoload_function_name: ?[]const u8,
) bool {
    const name = autoload_function_name orelse return false;
    return std.mem.eql(u8, tokens.get(index).text, name) and
        index + 2 < tokens.items.len and
        tokens.items[index + 1].kind == .left_paren and
        tokens.items[index + 2].kind == .right_paren;
}

pub fn aliasesEnabled(shell_state: state_mod.State) bool {
    return shell_state.options.mode == .posix or shell_state.options.interactive or shell_state.options.expand_aliases;
}

fn aliasEndsWithBlank(value: []const u8) bool {
    if (value.len == 0) return false;
    return switch (value[value.len - 1]) {
        ' ', '\t', '\n' => true,
        else => false,
    };
}

const HereDocDelimiter = struct {
    text: []const u8,
    quoted: bool,
};

/// Performs quote removal on a raw here-document delimiter word.
///
/// Expansions inside the delimiter are unspecified by POSIX and are kept
/// as literal text here.
fn hereDocDelimiter(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!HereDocDelimiter {
    if (std.mem.indexOfAny(u8, raw, "'\"\\") == null) return .{ .text = raw, .quoted = false };

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var quoted = false;
    var index: usize = 0;
    while (index < raw.len) {
        switch (raw[index]) {
            '\'' => {
                quoted = true;
                index += 1;
                while (index < raw.len and raw[index] != '\'') : (index += 1) {
                    try text.append(allocator, raw[index]);
                }
                if (index < raw.len) index += 1;
            },
            '"' => {
                quoted = true;
                index += 1;
                while (index < raw.len and raw[index] != '"') {
                    if (raw[index] == '\\' and index + 1 < raw.len) {
                        switch (raw[index + 1]) {
                            '$', '`', '"', '\\' => index += 1,
                            '\n' => {
                                index += 2;
                                continue;
                            },
                            else => {},
                        }
                    }
                    try text.append(allocator, raw[index]);
                    index += 1;
                }
                if (index < raw.len) index += 1;
            },
            '\\' => {
                if (index + 1 < raw.len and raw[index + 1] == '\n') {
                    index += 2;
                    continue;
                }
                quoted = true;
                index += 1;
                if (index < raw.len) {
                    try text.append(allocator, raw[index]);
                    index += 1;
                }
            },
            else => {
                try text.append(allocator, raw[index]);
                index += 1;
            },
        }
    }
    return .{ .text = try text.toOwnedSlice(allocator), .quoted = quoted };
}

fn stripLeadingTabs(line: []const u8) []const u8 {
    var index: usize = 0;
    while (index < line.len and line[index] == '\t') index += 1;
    return line[index..];
}

const Lexer = struct {
    allocator: std.mem.Allocator,
    token_allocator: std.mem.Allocator,
    source: source_mod.Source,
    position: source_mod.Position,
    pending_here_docs: std.ArrayList(PendingHereDoc) = .empty,
    here_doc_delimiter_expected: ?bool = null,
    trivia: ?*std.ArrayList(Trivia) = null,
    bare_expansion_end: usize = 0,

    const PendingHereDoc = struct {
        delimiter: []const u8,
        strip_tabs: bool,
        quoted: bool,
    };

    fn lex(self: *Lexer) std.mem.Allocator.Error!token.Stream {
        var tokens: token.Stream.Builder = .{ .src = self.source };
        errdefer tokens.deinit(self.token_allocator);
        defer self.pending_here_docs.deinit(self.allocator);

        while (!self.atEnd()) {
            const count_before = tokens.items.items.len;
            try self.lexOne(&tokens);
            try self.trackHereDocs(&tokens, count_before);
        }
        // Here-document bodies delimited by end of input (no trailing
        // newline) still get body tokens so the parser never scans text.
        if (self.pending_here_docs.items.len != 0) try self.lexHereDocBodies(&tokens);

        try tokens.append(self.token_allocator, .{
            .kind = .eof,
            .span = source_mod.Span.init(self.position, self.position.byte_offset),
        });
        return tokens.toOwnedStream(self.token_allocator);
    }

    fn lexOne(self: *Lexer, tokens: *token.Stream.Builder) std.mem.Allocator.Error!void {
        switch (self.peek()) {
            ' ', '\t', '\r' => self.advanceOne(),
            '\n' => try self.appendSingle(tokens, .newline),
            '\\' => if (self.peekNextIs('\n'))
                self.skipLineContinuation()
            else if (self.startsIoNumber())
                try self.appendIoNumber(tokens)
            else
                try self.appendWord(tokens),
            ';' => try self.appendSemicolon(tokens),
            '&' => try self.appendAmpersand(tokens),
            '|' => try self.appendPipe(tokens),
            '!' => if (self.peekByte(1)) |next|
                if (isWordTerminator(next)) try self.appendSingle(tokens, .bang) else try self.appendWord(tokens)
            else
                try self.appendSingle(tokens, .bang),
            '(' => try self.appendSingle(tokens, .left_paren),
            ')' => try self.appendSingle(tokens, .right_paren),
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            '{' => if (self.nextStartsWord()) try self.appendWord(tokens) else try self.appendSingle(tokens, .left_brace),
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            '}' => if (self.nextStartsWord()) try self.appendWord(tokens) else try self.appendSingle(tokens, .right_brace),
            '<', '>' => if (self.startsProcessSubstitution())
                try self.appendWord(tokens)
            else
                try self.appendRedirectionOperator(tokens),
            '#' => try self.skipComment(),
            else => if (self.startsIoNumber()) try self.appendIoNumber(tokens) else try self.appendWord(tokens),
        }
    }

    /// Follows here-document operators through the token stream: the word
    /// after `<<` or `<<-` is the delimiter, and the bodies for every
    /// pending here-document start on the line after the next newline
    /// token. Bodies are lexed immediately as dedicated tokens so no body
    /// byte is ever tokenized as command text (or alias-substituted).
    fn trackHereDocs(
        self: *Lexer,
        tokens: *token.Stream.Builder,
        first_new: usize,
    ) std.mem.Allocator.Error!void {
        var index = first_new;
        while (index < tokens.items.items.len) : (index += 1) {
            const tok = tokens.items.items[index];
            if (self.here_doc_delimiter_expected) |strip_tabs| {
                self.here_doc_delimiter_expected = null;
                if (tok.kind == .word) {
                    const raw = self.source.text[tok.start..tok.end];
                    const delimiter = try hereDocDelimiter(self.allocator, raw);
                    try self.pending_here_docs.append(self.allocator, .{
                        .delimiter = delimiter.text,
                        .strip_tabs = strip_tabs,
                        .quoted = delimiter.quoted,
                    });
                }
            }
            switch (tok.kind) {
                .less_less => self.here_doc_delimiter_expected = false,
                .less_less_dash => self.here_doc_delimiter_expected = true,
                .newline => if (self.pending_here_docs.items.len != 0) {
                    try self.lexHereDocBodies(tokens);
                },
                else => {},
            }
        }
    }

    fn lexHereDocBodies(self: *Lexer, tokens: *token.Stream.Builder) std.mem.Allocator.Error!void {
        for (self.pending_here_docs.items) |pending| {
            try self.lexHereDocBody(tokens, pending);
        }
        self.pending_here_docs.clearRetainingCapacity();
    }

    fn lexHereDocBody(
        self: *Lexer,
        tokens: *token.Stream.Builder,
        pending: PendingHereDoc,
    ) std.mem.Allocator.Error!void {
        const text = self.source.text;
        const start = self.position;

        var stripped: std.ArrayList(u8) = .empty;
        errdefer stripped.deinit(self.allocator);
        var offset = start.byte_offset;
        var body_end = offset;
        var terminated = false;
        var continued = false;
        while (offset <= text.len) {
            const line_start = offset;
            const newline_index = std.mem.findScalarPos(u8, text, offset, '\n');
            const line_end = newline_index orelse text.len;
            const next_offset = if (newline_index) |newline| newline + 1 else text.len;
            const raw_line = text[line_start..line_end];
            const strip = pending.strip_tabs and !continued;
            const candidate = if (strip) stripLeadingTabs(raw_line) else raw_line;
            if (!continued and std.mem.eql(u8, candidate, pending.delimiter)) {
                terminated = true;
                offset = next_offset;
                break;
            }

            if (pending.strip_tabs) {
                try stripped.appendSlice(self.allocator, candidate);
                if (newline_index != null) try stripped.append(self.allocator, '\n');
            }
            var trailing_backslashes: usize = 0;
            while (trailing_backslashes < candidate.len and
                candidate[candidate.len - trailing_backslashes - 1] == '\\')
            {
                trailing_backslashes += 1;
            }
            continued = !pending.quoted and trailing_backslashes % 2 == 1;
            body_end = next_offset;
            if (next_offset == offset) break;
            offset = next_offset;
        }
        if (!terminated) offset = text.len;

        const body: []const u8 = if (pending.strip_tabs)
            try stripped.toOwnedSlice(self.allocator)
        else
            text[start.byte_offset..body_end];
        self.position.advance(text[start.byte_offset..offset]);

        const tok: token.Token = .{
            .kind = if (terminated) .here_doc_body else .here_doc_body_unterminated,
            .span = source_mod.Span.init(start, offset),
            .text = body,
            .quoted = pending.quoted,
        };
        tok.validate();
        try tokens.append(self.token_allocator, tok);
    }

    fn atEnd(self: Lexer) bool {
        return self.position.byte_offset >= self.source.text.len;
    }

    fn peek(self: Lexer) u8 {
        std.debug.assert(!self.atEnd());
        return self.source.text[self.position.byte_offset];
    }

    fn advanceOne(self: *Lexer) void {
        std.debug.assert(!self.atEnd());
        self.position.advance(self.source.text[self.position.byte_offset .. self.position.byte_offset + 1]);
    }

    fn appendSingle(self: *Lexer, tokens: *token.Stream.Builder, kind: token.Kind) !void {
        const start = self.position;
        self.advanceOne();
        const tok: token.Token = .{ .kind = kind, .span = source_mod.Span.init(start, self.position.byte_offset) };
        tok.validate();
        try tokens.append(self.token_allocator, tok);
    }

    fn appendSemicolon(self: *Lexer, tokens: *token.Stream.Builder) !void {
        const start = self.position;
        self.advanceOne();
        const kind: token.Kind = if (!self.atEnd()) switch (self.peek()) {
            ';' => kind: {
                self.advanceOne();
                if (!self.atEnd() and self.peek() == '&') {
                    self.advanceOne();
                    break :kind .double_semicolon_ampersand;
                }
                break :kind .double_semicolon;
            },
            '&' => kind: {
                self.advanceOne();
                break :kind .semicolon_ampersand;
            },
            else => .semicolon,
        } else .semicolon;
        const tok: token.Token = .{ .kind = kind, .span = source_mod.Span.init(start, self.position.byte_offset) };
        tok.validate();
        try tokens.append(self.token_allocator, tok);
    }

    fn appendAmpersand(self: *Lexer, tokens: *token.Stream.Builder) !void {
        const start = self.position;
        self.advanceOne();
        const kind: token.Kind = if (!self.atEnd()) switch (self.peek()) {
            '&' => kind: {
                self.advanceOne();
                break :kind .ampersand_ampersand;
            },
            '>' => kind: {
                self.advanceOne();
                if (!self.atEnd() and self.peek() == '>') {
                    self.advanceOne();
                    break :kind .ampersand_greater_greater;
                }
                break :kind .ampersand_greater;
            },
            else => .ampersand,
        } else .ampersand;
        const tok: token.Token = .{ .kind = kind, .span = source_mod.Span.init(start, self.position.byte_offset) };
        tok.validate();
        try tokens.append(self.token_allocator, tok);
    }

    fn appendPipe(self: *Lexer, tokens: *token.Stream.Builder) !void {
        const start = self.position;
        self.advanceOne();
        const kind: token.Kind = if (!self.atEnd()) switch (self.peek()) {
            '|' => kind: {
                self.advanceOne();
                break :kind .pipe_pipe;
            },
            '&' => kind: {
                self.advanceOne();
                break :kind .pipe_ampersand;
            },
            else => .pipe,
        } else .pipe;
        const tok: token.Token = .{ .kind = kind, .span = source_mod.Span.init(start, self.position.byte_offset) };
        tok.validate();
        try tokens.append(self.token_allocator, tok);
    }

    fn appendRedirectionOperator(self: *Lexer, tokens: *token.Stream.Builder) !void {
        const start = self.position;
        const first = self.peek();
        self.advanceOne();
        const kind: token.Kind = switch (first) {
            '<' => if (!self.atEnd()) switch (self.peek()) {
                '<' => kind: {
                    self.advanceOne();
                    if (!self.atEnd() and self.peek() == '<') {
                        self.advanceOne();
                        break :kind .less_less_less;
                    }
                    if (!self.atEnd() and self.peek() == '-') {
                        self.advanceOne();
                        break :kind .less_less_dash;
                    }
                    break :kind .less_less;
                },
                '&' => kind: {
                    self.advanceOne();
                    break :kind .less_ampersand;
                },
                '>' => kind: {
                    self.advanceOne();
                    break :kind .less_greater;
                },
                else => .less,
            } else .less,
            '>' => if (!self.atEnd()) switch (self.peek()) {
                '>' => kind: {
                    self.advanceOne();
                    break :kind .greater_greater;
                },
                '&' => kind: {
                    self.advanceOne();
                    break :kind .greater_ampersand;
                },
                '|' => kind: {
                    self.advanceOne();
                    break :kind .clobber;
                },
                else => .greater,
            } else .greater,
            else => unreachable,
        };
        const tok: token.Token = .{ .kind = kind, .span = source_mod.Span.init(start, self.position.byte_offset) };
        tok.validate();
        try tokens.append(self.token_allocator, tok);
    }

    fn appendIoNumber(self: *Lexer, tokens: *token.Stream.Builder) !void {
        const start = self.position;
        const start_offset = self.position.byte_offset;
        while (!self.atEnd() and isDigit(self.peek())) self.advanceOne();
        const tok: token.Token = .{
            .kind = .io_number,
            .span = source_mod.Span.init(start, self.position.byte_offset),
            .text = self.source.text[start_offset..self.position.byte_offset],
        };
        tok.validate();
        try tokens.append(self.token_allocator, tok);
    }

    fn emitTrivia(self: *Lexer, kind: Trivia.Kind, start: usize, end: usize) std.mem.Allocator.Error!void {
        const list = self.trivia orelse return;
        std.debug.assert(start < end);
        try list.append(self.allocator, .{ .kind = kind, .start = start, .end = end });
    }

    /// Emits an expansion span for a bare `$NAME`, `$1`, or `$?` style
    /// parameter at the current position. Lookahead only: the caller's
    /// scanning is unchanged, so token output stays identical.
    fn emitParameterExpansionTrivia(self: *Lexer) std.mem.Allocator.Error!void {
        if (self.trivia == null) return;
        const start = self.position.byte_offset;
        // A `$` inside an already-emitted span (`$$x`) is not a new expansion.
        if (start < self.bare_expansion_end) return;
        const length = parameterExpansionLength(self.source.text, start) orelse return;
        self.bare_expansion_end = start + length;
        try self.emitTrivia(.expansion, start, start + length);
    }

    fn skipComment(self: *Lexer) std.mem.Allocator.Error!void {
        const start = self.position.byte_offset;
        while (!self.atEnd() and self.peek() != '\n') self.advanceOne();
        try self.emitTrivia(.comment, start, self.position.byte_offset);
    }

    fn skipLineContinuation(self: *Lexer) void {
        std.debug.assert(self.peek() == '\\');
        std.debug.assert(self.peekNextIs('\n'));
        self.advanceOne();
        self.advanceOne();
    }

    fn appendWord(self: *Lexer, tokens: *token.Stream.Builder) !void {
        const start = self.position;
        const start_offset = self.position.byte_offset;
        var quoted = false;
        var quote: ?u8 = null;
        var quote_start: usize = 0;
        while (!self.atEnd()) {
            const byte = self.peek();
            if (quote) |delimiter| {
                if (delimiter == '"' and byte == '\\') {
                    self.advanceOne();
                    if (!self.atEnd()) self.advanceOne();
                    continue;
                }
                if (delimiter == '"' and byte == '$' and self.peekNextIs('(')) {
                    const expansion_start = self.position.byte_offset;
                    self.advanceOne();
                    self.advanceOne();
                    try self.skipCommandSubstitution();
                    try self.emitTrivia(.expansion, expansion_start, self.position.byte_offset);
                    continue;
                }
                if (delimiter == '"' and byte == '$' and self.peekNextIs('{')) {
                    const expansion_start = self.position.byte_offset;
                    self.advanceOne();
                    self.advanceOne();
                    try self.skipBracedParameter();
                    try self.emitTrivia(.expansion, expansion_start, self.position.byte_offset);
                    continue;
                }
                if (delimiter == '"' and byte == '`') {
                    const expansion_start = self.position.byte_offset;
                    self.advanceOne();
                    try self.skipBackquoteSubstitution();
                    try self.emitTrivia(.expansion, expansion_start, self.position.byte_offset);
                    continue;
                }
                if (delimiter == '"' and byte == '$') {
                    try self.emitParameterExpansionTrivia();
                }
                if (byte == delimiter) {
                    quote = null;
                    self.advanceOne();
                    try self.emitTrivia(.quote, quote_start, self.position.byte_offset);
                    continue;
                }
                self.advanceOne();
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quoted = true;
                quote = byte;
                quote_start = self.position.byte_offset;
                self.advanceOne();
                continue;
            }
            if (byte == '\\') {
                if (!self.peekNextIs('\n')) quoted = true;
                self.advanceOne();
                if (!self.atEnd()) self.advanceOne();
                continue;
            }
            if (byte == '$' and self.peekNextIs('(') and self.peekByte(2) == '(') {
                const expansion_start = self.position.byte_offset;
                self.advanceOne();
                self.advanceOne();
                self.advanceOne();
                try self.skipArithmeticExpansion();
                try self.emitTrivia(.expansion, expansion_start, self.position.byte_offset);
                continue;
            }
            if (byte == '$' and self.peekNextIs('\'')) {
                quoted = true;
                const dollar_quote_start = self.position.byte_offset;
                self.advanceOne();
                self.advanceOne();
                try self.skipDollarSingleQuote(dollar_quote_start);
                continue;
            }
            if (byte == '$' and self.peekNextIs('(')) {
                const expansion_start = self.position.byte_offset;
                self.advanceOne();
                self.advanceOne();
                try self.skipCommandSubstitution();
                try self.emitTrivia(.expansion, expansion_start, self.position.byte_offset);
                continue;
            }
            if (byte == '$' and self.peekNextIs('{')) {
                const expansion_start = self.position.byte_offset;
                self.advanceOne();
                self.advanceOne();
                try self.skipBracedParameter();
                try self.emitTrivia(.expansion, expansion_start, self.position.byte_offset);
                continue;
            }
            if (byte == '`') {
                const expansion_start = self.position.byte_offset;
                self.advanceOne();
                try self.skipBackquoteSubstitution();
                try self.emitTrivia(.expansion, expansion_start, self.position.byte_offset);
                continue;
            }
            if (self.startsProcessSubstitution()) {
                const expansion_start = self.position.byte_offset;
                self.advanceOne();
                self.advanceOne();
                try self.skipCommandSubstitution();
                try self.emitTrivia(.expansion, expansion_start, self.position.byte_offset);
                continue;
            }
            if (byte == '[' and self.skipBracketExpression()) continue;
            if (isWordTerminator(byte)) break;
            if (byte == '$') try self.emitParameterExpansionTrivia();
            self.advanceOne();
        }
        if (quote != null) try self.emitTrivia(.pending_quote, quote_start, self.position.byte_offset);
        const raw_text = self.source.text[start_offset..self.position.byte_offset];
        const text = try self.wordText(raw_text);
        const tok: token.Token = .{
            .kind = .word,
            .span = source_mod.Span.init(start, self.position.byte_offset),
            .text = text,
            .reserved = if (quoted) null else token.lookupReservedWord(text),
            .quoted = quoted,
        };
        tok.validate();
        try tokens.append(self.token_allocator, tok);
    }

    fn wordText(self: Lexer, raw_text: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, raw_text, "\\\n") == null) return raw_text;

        var output: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        var quote: ?u8 = null;
        while (index < raw_text.len) {
            const byte = raw_text[index];
            if (quote) |delimiter| {
                if (byte == delimiter) quote = null;
                if (delimiter == '"' and byte == '\\' and index + 1 < raw_text.len) {
                    const escaped = raw_text[index + 1];
                    if (escaped == '\n') {
                        index += 2;
                        continue;
                    }
                    if (doubleQuoteEscapes(escaped)) {
                        try output.append(self.allocator, byte);
                        try output.append(self.allocator, escaped);
                        index += 2;
                        continue;
                    }
                }
                if (delimiter == '"' and byte == '$' and index + 1 < raw_text.len and raw_text[index + 1] == '(') {
                    const close_index = scanCommandSubstitutionText(raw_text, index + 1) orelse raw_text.len - 1;
                    try output.appendSlice(self.allocator, raw_text[index .. close_index + 1]);
                    index = close_index + 1;
                    continue;
                }
                try output.append(self.allocator, byte);
                index += 1;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                try output.append(self.allocator, byte);
                index += 1;
                continue;
            }
            if (byte == '\\') {
                if (index + 1 < raw_text.len and raw_text[index + 1] == '\n') {
                    index += 2;
                    continue;
                }
                try output.append(self.allocator, byte);
                index += 1;
                if (index < raw_text.len) {
                    try output.append(self.allocator, raw_text[index]);
                    index += 1;
                }
                continue;
            }
            if (byte == '$' and index + 1 < raw_text.len and raw_text[index + 1] == '(') {
                const close_index = scanCommandSubstitutionText(raw_text, index + 1) orelse raw_text.len - 1;
                try output.appendSlice(self.allocator, raw_text[index .. close_index + 1]);
                index = close_index + 1;
                continue;
            }
            try output.append(self.allocator, byte);
            index += 1;
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn scanCommandSubstitutionText(text: []const u8, open_index: usize) ?usize {
        return parse_scan.scanCommandSubstitution(text, open_index, text.len) catch null;
    }

    fn doubleQuoteEscapes(byte: u8) bool {
        return switch (byte) {
            '$', '`', '"', '\\', '\n' => true,
            else => false,
        };
    }

    fn startsIoNumber(self: Lexer) bool {
        if (!isDigit(self.peek())) return false;
        var offset = self.position.byte_offset;
        while (offset < self.source.text.len and isDigit(self.source.text[offset])) offset += 1;
        while (offset + 1 < self.source.text.len and self.source.text[offset] == '\\' and
            self.source.text[offset + 1] == '\n')
        {
            offset += 2;
        }
        return offset < self.source.text.len and isRedirectionStart(self.source.text[offset]);
    }

    fn peekNextIs(self: Lexer, byte: u8) bool {
        const next = self.position.byte_offset + 1;
        return next < self.source.text.len and self.source.text[next] == byte;
    }

    fn peekByte(self: Lexer, offset: usize) ?u8 {
        const index = self.position.byte_offset + offset;
        if (index >= self.source.text.len) return null;
        return self.source.text[index];
    }

    fn nextStartsWord(self: Lexer) bool {
        if (self.peekByte(1)) |next| return !isWordTerminator(next);
        return false;
    }

    fn startsProcessSubstitution(self: Lexer) bool {
        const byte = self.peek();
        return (byte == '<' or byte == '>') and self.peekNextIs('(');
    }

    fn skipArithmeticExpansion(self: *Lexer) std.mem.Allocator.Error!void {
        var paren_depth: usize = 0;
        while (!self.atEnd()) {
            const byte = self.peek();
            if (byte == '\\') {
                self.advanceOne();
                if (!self.atEnd()) self.advanceOne();
                continue;
            }
            if (byte == '\'' or byte == '"') {
                const quote = byte;
                const quote_start = self.position.byte_offset;
                self.advanceOne();
                while (!self.atEnd() and self.peek() != quote) self.advanceOne();
                if (!self.atEnd()) {
                    self.advanceOne();
                    try self.emitTrivia(.quote, quote_start, self.position.byte_offset);
                } else {
                    try self.emitTrivia(.pending_quote, quote_start, self.position.byte_offset);
                }
                continue;
            }
            if (byte == '(') {
                paren_depth += 1;
                self.advanceOne();
                continue;
            }
            if (byte == ')') {
                if (paren_depth != 0) {
                    paren_depth -= 1;
                    self.advanceOne();
                } else {
                    self.advanceOne();
                    if (!self.atEnd() and self.peek() == ')') self.advanceOne();
                    return;
                }
                continue;
            }
            self.advanceOne();
        }
    }

    fn skipCommandSubstitution(self: *Lexer) std.mem.Allocator.Error!void {
        const start = self.position.byte_offset;
        var depth: usize = 1;
        while (!self.atEnd() and depth != 0) {
            if (parse_scan.startsReservedWordAt(self.source.text, self.position.byte_offset, "case") and
                parse_scan.startsCommandAt(self.source.text, start, self.position.byte_offset))
            {
                try self.skipCaseCommandText();
                continue;
            }
            const byte = self.peek();
            if (byte == '#' and self.commentStartsAtCurrentOffset()) {
                try self.skipComment();
                continue;
            }
            if (byte == '\\') {
                self.advanceOne();
                if (!self.atEnd()) self.advanceOne();
                continue;
            }
            if (byte == '\'' or byte == '"') {
                try self.skipQuotedText();
                continue;
            }
            if (byte == '$' and self.peekNextIs('(')) {
                depth += 1;
                self.advanceOne();
                self.advanceOne();
                continue;
            }
            if (byte == '(') depth += 1;
            if (byte == ')') depth -= 1;
            self.advanceOne();
        }
    }

    fn skipQuotedText(self: *Lexer) std.mem.Allocator.Error!void {
        const quote = self.peek();
        std.debug.assert(quote == '\'' or quote == '"');
        const start = self.position.byte_offset;
        self.advanceOne();
        if (quote == '"') {
            const end = parse_scan.scanDoubleQuoteEnd(
                self.source.text,
                self.position.byte_offset,
                self.source.text.len,
            ) catch {
                self.advanceBytes(self.source.text.len - self.position.byte_offset);
                try self.emitTrivia(.pending_quote, start, self.position.byte_offset);
                return;
            };
            self.advanceBytes(end - self.position.byte_offset);
        } else {
            while (!self.atEnd() and self.peek() != quote) self.advanceOne();
        }
        if (!self.atEnd()) {
            self.advanceOne();
            try self.emitTrivia(.quote, start, self.position.byte_offset);
        } else {
            try self.emitTrivia(.pending_quote, start, self.position.byte_offset);
        }
    }

    fn commentStartsAtCurrentOffset(self: Lexer) bool {
        const offset = self.position.byte_offset;
        if (offset == 0) return true;
        return switch (self.source.text[offset - 1]) {
            ' ', '\t', '\n', '\r', ';', '&', '|', '(', ')' => true,
            else => false,
        };
    }

    fn skipCaseCommandText(self: *Lexer) std.mem.Allocator.Error!void {
        self.advanceBytes("case".len);
        while (!self.atEnd()) {
            if (parse_scan.startsReservedWordAt(self.source.text, self.position.byte_offset, "esac")) {
                self.advanceBytes("esac".len);
                return;
            }

            const byte = self.peek();
            if (byte == '#' and self.commentStartsAtCurrentOffset()) {
                try self.skipComment();
                continue;
            }
            if (byte == '\\') {
                self.advanceOne();
                if (!self.atEnd()) self.advanceOne();
                continue;
            }
            if (byte == '\'' or byte == '"') {
                try self.skipQuotedText();
                continue;
            }
            if (byte == '$' and self.peekNextIs('(')) {
                self.advanceOne();
                self.advanceOne();
                try self.skipCommandSubstitution();
                continue;
            }
            self.advanceOne();
        }
    }

    fn advanceBytes(self: *Lexer, count: usize) void {
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) self.advanceOne();
    }

    fn skipBracedParameter(self: *Lexer) std.mem.Allocator.Error!void {
        var depth: usize = 1;
        var quote: ?u8 = null;
        var quote_start: usize = 0;
        while (!self.atEnd()) {
            const byte = self.peek();
            if (quote) |delimiter| {
                if (byte == delimiter) {
                    quote = null;
                    self.advanceOne();
                    try self.emitTrivia(.quote, quote_start, self.position.byte_offset);
                    continue;
                }
                self.advanceOne();
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                quote_start = self.position.byte_offset;
                self.advanceOne();
                continue;
            }
            if (byte == '\\') {
                self.advanceOne();
                if (!self.atEnd()) self.advanceOne();
                continue;
            }
            if (byte == '$' and self.peekNextIs('{')) {
                depth += 1;
                self.advanceOne();
                self.advanceOne();
                continue;
            }
            if (byte == '$' and self.peekNextIs('(')) {
                self.advanceOne();
                self.advanceOne();
                try self.skipCommandSubstitution();
                continue;
            }
            self.advanceOne();
            if (byte == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (quote != null) try self.emitTrivia(.pending_quote, quote_start, self.position.byte_offset);
    }

    /// Quote state is tracked only to emit trivia; it must not affect where
    /// the substitution closes, so the token scan matches the plain lexer.
    fn skipBackquoteSubstitution(self: *Lexer) std.mem.Allocator.Error!void {
        var quote: ?u8 = null;
        var quote_start: usize = 0;
        while (!self.atEnd()) {
            const byte = self.peek();
            self.advanceOne();
            if (byte == '\\' and !self.atEnd()) {
                self.advanceOne();
                continue;
            }
            if (byte == '`') {
                if (quote != null) try self.emitTrivia(.pending_quote, quote_start, self.position.byte_offset - 1);
                return;
            }
            if (quote) |delimiter| {
                if (byte == delimiter) {
                    quote = null;
                    try self.emitTrivia(.quote, quote_start, self.position.byte_offset);
                }
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                quote_start = self.position.byte_offset - 1;
            }
        }
        if (quote != null) try self.emitTrivia(.pending_quote, quote_start, self.position.byte_offset);
    }

    fn skipBracketExpression(self: *Lexer) bool {
        std.debug.assert(!self.atEnd());
        std.debug.assert(self.peek() == '[');

        var index = self.position.byte_offset + 1;
        if (index >= self.source.text.len or isWordTerminator(self.source.text[index])) return false;
        if (index < self.source.text.len and (self.source.text[index] == '!' or self.source.text[index] == '^')) {
            index += 1;
        }
        var saw_member = false;
        while (index < self.source.text.len) {
            const byte = self.source.text[index];
            if (byte == '\\' and index + 1 < self.source.text.len) {
                index += 2;
                saw_member = true;
                continue;
            }
            if (byte == ']' and saw_member) {
                self.advanceBytes(index + 1 - self.position.byte_offset);
                return true;
            }
            if (isWordTerminator(byte)) return false;
            if (byte == '\n' or byte == '\r') return false;
            saw_member = true;
            index += 1;
        }
        return false;
    }

    fn skipDollarSingleQuote(self: *Lexer, quote_start: usize) std.mem.Allocator.Error!void {
        while (!self.atEnd()) {
            const byte = self.peek();
            self.advanceOne();
            if (byte == '\\' and !self.atEnd()) {
                self.advanceOne();
                continue;
            }
            if (byte == '\'') {
                try self.emitTrivia(.quote, quote_start, self.position.byte_offset);
                return;
            }
        }
        try self.emitTrivia(.pending_quote, quote_start, self.position.byte_offset);
    }
};

fn isWordTerminator(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n', ';', '&', '|', '(', ')', '<', '>' => true,
        else => false,
    };
}

/// Length of the bare parameter expansion starting at the `$` at `index`:
/// `$NAME`, a single-digit positional like `$1`, or a special parameter like
/// `$?`. Returns null when the `$` starts no expansion.
fn parameterExpansionLength(text: []const u8, index: usize) ?usize {
    std.debug.assert(text[index] == '$');
    if (index + 1 >= text.len) return null;
    const next = text[index + 1];
    if (isNameStart(next)) {
        var end = index + 2;
        while (end < text.len and isNameContinue(text[end])) end += 1;
        return end - index;
    }
    return switch (next) {
        '0'...'9', '@', '*', '#', '?', '-', '$', '!' => 2,
        else => null,
    };
}

fn isDigit(byte: u8) bool {
    return switch (byte) {
        '0'...'9' => true,
        else => false,
    };
}

fn isNameStart(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '_' => true,
        else => false,
    };
}

fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or isDigit(byte);
}

fn isRedirectionStart(byte: u8) bool {
    return byte == '<' or byte == '>';
}

test "token storage can be freed independently of normalized word and here-document text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src: source_mod.Source = .{
        .id = 1,
        .kind = .script_file,
        .name = "test",
        .text = "echo foo\\\nbar\ncat <<-E\n\tbody\n\tE\n",
    };
    const normalized, const body = text: {
        const tokens = try lexWithTokenAllocator(arena.allocator(), std.testing.allocator, src);
        defer tokens.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 9), tokens.items.len);
        try std.testing.expectEqual(token.Kind.here_doc_body, tokens.get(7).kind);
        break :text .{ tokens.get(1).text, tokens.get(7).text };
    };
    try std.testing.expectEqualStrings("foobar", normalized);
    try std.testing.expectEqualStrings("body\n", body);
}

test "lexWithTrivia reports comments quotes and pending quotes" {
    const text = "printf 'ok' \"a b\" # note\nprintf \"pending";
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = text };
    var trivia: std.ArrayList(Trivia) = .empty;
    defer trivia.deinit(std.testing.allocator);
    const tokens = try lexWithTrivia(std.testing.allocator, src, &trivia);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), trivia.items.len);
    try std.testing.expectEqual(Trivia.Kind.quote, trivia.items[0].kind);
    try std.testing.expectEqualStrings("'ok'", text[trivia.items[0].start..trivia.items[0].end]);
    try std.testing.expectEqual(Trivia.Kind.quote, trivia.items[1].kind);
    try std.testing.expectEqualStrings("\"a b\"", text[trivia.items[1].start..trivia.items[1].end]);
    try std.testing.expectEqual(Trivia.Kind.comment, trivia.items[2].kind);
    try std.testing.expectEqualStrings("# note", text[trivia.items[2].start..trivia.items[2].end]);
    try std.testing.expectEqual(Trivia.Kind.pending_quote, trivia.items[3].kind);
    try std.testing.expectEqualStrings("\"pending", text[trivia.items[3].start..trivia.items[3].end]);
}

test "lexWithTrivia spans dollar single quotes" {
    const text = "printf $'a\\'b' $'open";
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = text };
    var trivia: std.ArrayList(Trivia) = .empty;
    defer trivia.deinit(std.testing.allocator);
    const tokens = try lexWithTrivia(std.testing.allocator, src, &trivia);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), trivia.items.len);
    try std.testing.expectEqual(Trivia.Kind.quote, trivia.items[0].kind);
    try std.testing.expectEqualStrings("$'a\\'b'", text[trivia.items[0].start..trivia.items[0].end]);
    try std.testing.expectEqual(Trivia.Kind.pending_quote, trivia.items[1].kind);
    try std.testing.expectEqualStrings("$'open", text[trivia.items[1].start..trivia.items[1].end]);
}

test "lexWithTrivia ignores quotes inside here-document bodies" {
    const text = "cat <<EOF\nit's fine\nEOF\n";
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = text };
    var trivia: std.ArrayList(Trivia) = .empty;
    defer trivia.deinit(std.testing.allocator);
    const tokens = try lexWithTrivia(std.testing.allocator, src, &trivia);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), trivia.items.len);
}

test "lexWithTrivia reports quotes and comments inside command substitution" {
    const text = "echo $(grep 'pat' file # inner\n)";
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = text };
    var trivia: std.ArrayList(Trivia) = .empty;
    defer trivia.deinit(std.testing.allocator);
    const tokens = try lexWithTrivia(std.testing.allocator, src, &trivia);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), trivia.items.len);
    try std.testing.expectEqual(Trivia.Kind.quote, trivia.items[0].kind);
    try std.testing.expectEqualStrings("'pat'", text[trivia.items[0].start..trivia.items[0].end]);
    try std.testing.expectEqual(Trivia.Kind.comment, trivia.items[1].kind);
    try std.testing.expectEqualStrings("# inner", text[trivia.items[1].start..trivia.items[1].end]);
    try std.testing.expectEqual(Trivia.Kind.expansion, trivia.items[2].kind);
    const expansion = text[trivia.items[2].start..trivia.items[2].end];
    try std.testing.expectEqualStrings("$(grep 'pat' file # inner\n)", expansion);
}

test "lexWithTrivia reports quotes inside backquote substitutions" {
    const text = "echo `grep 'pat' f` `x \"open";
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = text };
    var trivia: std.ArrayList(Trivia) = .empty;
    defer trivia.deinit(std.testing.allocator);
    const tokens = try lexWithTrivia(std.testing.allocator, src, &trivia);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), trivia.items.len);
    try std.testing.expectEqual(Trivia.Kind.quote, trivia.items[0].kind);
    try std.testing.expectEqualStrings("'pat'", text[trivia.items[0].start..trivia.items[0].end]);
    try std.testing.expectEqual(Trivia.Kind.expansion, trivia.items[1].kind);
    try std.testing.expectEqualStrings("`grep 'pat' f`", text[trivia.items[1].start..trivia.items[1].end]);
    try std.testing.expectEqual(Trivia.Kind.pending_quote, trivia.items[2].kind);
    try std.testing.expectEqualStrings("\"open", text[trivia.items[2].start..trivia.items[2].end]);
    try std.testing.expectEqual(Trivia.Kind.expansion, trivia.items[3].kind);
    try std.testing.expectEqualStrings("`x \"open", text[trivia.items[3].start..trivia.items[3].end]);
}

test "lexWithTrivia reports expansions inside and outside double quotes" {
    const text = "echo $HOME $? ${PATH} $(id -u) $((1+2)) `date` \"pre $USER $(pwd) post\"";
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = text };
    var trivia: std.ArrayList(Trivia) = .empty;
    defer trivia.deinit(std.testing.allocator);
    const tokens = try lexWithTrivia(std.testing.allocator, src, &trivia);
    defer tokens.deinit(std.testing.allocator);

    var expansions: std.ArrayList([]const u8) = .empty;
    defer expansions.deinit(std.testing.allocator);
    for (trivia.items) |item| {
        if (item.kind != .expansion) continue;
        try expansions.append(std.testing.allocator, text[item.start..item.end]);
    }

    const expected = [_][]const u8{
        "$HOME", "$?", "${PATH}", "$(id -u)", "$((1+2))", "`date`", "$USER", "$(pwd)",
    };
    try std.testing.expectEqual(expected.len, expansions.items.len);
    for (expected, expansions.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "lexWithTrivia reports double dollar as one expansion" {
    const text = "echo $$x";
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = text };
    var trivia: std.ArrayList(Trivia) = .empty;
    defer trivia.deinit(std.testing.allocator);
    const tokens = try lexWithTrivia(std.testing.allocator, src, &trivia);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), trivia.items.len);
    try std.testing.expectEqual(Trivia.Kind.expansion, trivia.items[0].kind);
    try std.testing.expectEqualStrings("$$", text[trivia.items[0].start..trivia.items[0].end]);
}

test "lexWithTrivia does not report literal dollars as expansions" {
    const text = "echo a$ '$HOME' $% cost\\$5";
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = text };
    var trivia: std.ArrayList(Trivia) = .empty;
    defer trivia.deinit(std.testing.allocator);
    const tokens = try lexWithTrivia(std.testing.allocator, src, &trivia);
    defer tokens.deinit(std.testing.allocator);

    for (trivia.items) |item| {
        try std.testing.expect(item.kind != .expansion);
    }
}

test "lexWithTrivia produces identical tokens to lex" {
    const text = "FOO=bar cat <<EOF 2>err # c\nbody\nEOF\necho $((1+2)) \"x $(y 'z')\"";
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = text };
    var trivia: std.ArrayList(Trivia) = .empty;
    defer trivia.deinit(std.testing.allocator);
    const with_trivia = try lexWithTrivia(std.testing.allocator, src, &trivia);
    defer with_trivia.deinit(std.testing.allocator);
    const plain = try lex(std.testing.allocator, src);
    defer plain.deinit(std.testing.allocator);

    try std.testing.expectEqual(plain.items.len, with_trivia.items.len);
    for (0..plain.items.len) |index| {
        const expected = plain.get(index);
        const actual = with_trivia.get(index);
        try std.testing.expectEqual(expected.kind, actual.kind);
        try std.testing.expectEqual(expected.span.start, actual.span.start);
        try std.testing.expectEqual(expected.span.end, actual.span.end);
        try std.testing.expectEqualStrings(expected.text, actual.text);
    }
}

test "lexer tokenizes colon command" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = ":" };
    const tokens = try lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(token.Kind.word, tokens.get(0).kind);
    try std.testing.expectEqualStrings(":", tokens.get(0).text);
    try std.testing.expectEqual(token.Kind.eof, tokens.get(1).kind);
}

test "lexer tokenizes AND-OR operators" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "true&&false||! true" };
    const tokens = try lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(token.Kind.word, tokens.get(0).kind);
    try std.testing.expectEqualStrings("true", tokens.get(0).text);
    try std.testing.expectEqual(token.Kind.ampersand_ampersand, tokens.get(1).kind);
    try std.testing.expectEqual(token.Kind.word, tokens.get(2).kind);
    try std.testing.expectEqualStrings("false", tokens.get(2).text);
    try std.testing.expectEqual(token.Kind.pipe_pipe, tokens.get(3).kind);
    try std.testing.expectEqual(token.Kind.bang, tokens.get(4).kind);
    try std.testing.expectEqual(token.Kind.word, tokens.get(5).kind);
    try std.testing.expectEqualStrings("true", tokens.get(5).text);
    try std.testing.expectEqual(token.Kind.eof, tokens.get(6).kind);
}

test "lexer tokenizes bash redirection shorthand operators" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = ": &>out &>>log |& cat" };
    const tokens = try lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(token.Kind.ampersand_greater, tokens.get(1).kind);
    try std.testing.expectEqualStrings("out", tokens.get(2).text);
    try std.testing.expectEqual(token.Kind.ampersand_greater_greater, tokens.get(3).kind);
    try std.testing.expectEqualStrings("log", tokens.get(4).text);
    try std.testing.expectEqual(token.Kind.pipe_ampersand, tokens.get(5).kind);
}

test "lexer keeps exclamation mark words together" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "test x != y; ! false" };
    const tokens = try lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(token.Kind.word, tokens.get(0).kind);
    try std.testing.expectEqualStrings("test", tokens.get(0).text);
    try std.testing.expectEqual(token.Kind.word, tokens.get(1).kind);
    try std.testing.expectEqualStrings("x", tokens.get(1).text);
    try std.testing.expectEqual(token.Kind.word, tokens.get(2).kind);
    try std.testing.expectEqualStrings("!=", tokens.get(2).text);
    try std.testing.expectEqual(token.Kind.word, tokens.get(3).kind);
    try std.testing.expectEqualStrings("y", tokens.get(3).text);
    try std.testing.expectEqual(token.Kind.semicolon, tokens.get(4).kind);
    try std.testing.expectEqual(token.Kind.bang, tokens.get(5).kind);
}

test "lexer marks reserved words" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "if true; then :; fi" };
    const tokens = try lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(token.ReservedWord.if_kw, tokens.get(0).reserved.?);
    try std.testing.expectEqual(@as(?token.ReservedWord, null), tokens.get(1).reserved);
    try std.testing.expectEqual(token.ReservedWord.then_kw, tokens.get(3).reserved.?);
    try std.testing.expectEqual(token.ReservedWord.fi_kw, tokens.get(6).reserved.?);
}

test "lexer marks quoted words as non-reserved" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "'if'" };
    const tokens = try lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expect(tokens.get(0).quoted);
    try std.testing.expectEqual(@as(?token.ReservedWord, null), tokens.get(0).reserved);
}

test "lexer keeps quoted spaces inside words" {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf \"hello world\"" };
    const tokens = try lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(token.Kind.word, tokens.get(0).kind);
    try std.testing.expectEqualStrings("printf", tokens.get(0).text);
    try std.testing.expectEqual(token.Kind.word, tokens.get(1).kind);
    try std.testing.expect(tokens.get(1).quoted);
    try std.testing.expectEqualStrings("\"hello world\"", tokens.get(1).text);
}

test "lexer treats backslash escaped quote as word text" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf \\'3" };
    const tokens = try lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try std.testing.expectEqual(token.Kind.word, tokens.get(1).kind);
    try std.testing.expectEqualStrings("\\'3", tokens.get(1).text);
    try std.testing.expect(tokens.get(1).quoted);
}

test "lexer removes top-level line continuations before comments" {
    const src: source_mod.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "-c",
        .text =
        \\printf foo \
        \\# comment
        \\printf bar
        ,
    };
    const tokens = try lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("printf", tokens.get(0).text);
    try std.testing.expectEqualStrings("foo", tokens.get(1).text);
    try std.testing.expectEqual(token.Kind.newline, tokens.get(2).kind);
    try std.testing.expectEqualStrings("printf", tokens.get(3).text);
    try std.testing.expectEqualStrings("bar", tokens.get(4).text);
}

test "lexer removes line continuations inside word tokens" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "-c",
        .text =
        \\f\
        \\(){ :; }
        ,
    };
    const tokens = try lex(arena.allocator(), src);

    try std.testing.expectEqual(token.Kind.word, tokens.get(0).kind);
    try std.testing.expectEqualStrings("f", tokens.get(0).text);
    try std.testing.expect(!tokens.get(0).quoted);
    try std.testing.expectEqual(token.Kind.left_paren, tokens.get(1).kind);
}

test "lexer preserves escaped backslash before double quoted newline" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "-c",
        .text = "printf \"\\\\\n\"",
    };
    const tokens = try lex(arena.allocator(), src);

    try std.testing.expectEqual(token.Kind.word, tokens.get(1).kind);
    try std.testing.expectEqualStrings("\"\\\\\n\"", tokens.get(1).text);
    try std.testing.expect(tokens.get(1).quoted);
}

test "lexer preserves single quoted newline after escaped single quote" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "-c",
        .text = "v='a'\\''\\\\\\\nZ'",
    };
    const tokens = try lex(arena.allocator(), src);

    try std.testing.expectEqual(token.Kind.word, tokens.get(0).kind);
    try std.testing.expectEqualStrings("v='a'\\''\\\\\\\nZ'", tokens.get(0).text);
    try std.testing.expect(tokens.get(0).quoted);
}

test "lexer keeps dollar single quoted words separate" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf $'\\'' $'\\\\'" };
    const tokens = try lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("$'\\''", tokens.get(1).text);
    try std.testing.expect(tokens.get(1).quoted);
    try std.testing.expectEqualStrings("$'\\\\'", tokens.get(2).text);
    try std.testing.expect(tokens.get(2).quoted);
}

test "lexer keeps command substitutions inside words" {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "x=$(printf a; printf b)" };
    const tokens = try lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(token.Kind.word, tokens.get(0).kind);
    try std.testing.expectEqualStrings("x=$(printf a; printf b)", tokens.get(0).text);
    try std.testing.expectEqual(token.Kind.eof, tokens.get(1).kind);
}

test "lexer keeps brace characters inside word tokens" {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf {} x{} {}x a{b}" };
    const tokens = try lex(std.testing.allocator, src);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("{}", tokens.get(1).text);
    try std.testing.expectEqualStrings("x{}", tokens.get(2).text);
    try std.testing.expectEqualStrings("{}x", tokens.get(3).text);
    try std.testing.expectEqualStrings("a{b}", tokens.get(4).text);
}

test "lexer emits here-document bodies as dedicated tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .script_file,
        .name = "test",
        .text = "cat <<-E\n\tbody\n\tE\necho next\n",
    };
    const tokens = try lex(allocator, src);

    var body: ?token.Token = null;
    for (0..tokens.items.len) |index| {
        const tok = tokens.get(index);
        if (tok.kind == .here_doc_body) body = tok;
        // No body byte may leak into ordinary word tokens.
        if (tok.kind == .word) try std.testing.expect(!std.mem.eql(u8, tok.text, "body"));
    }
    const body_token = body orelse return error.ExpectedHereDocBody;
    try std.testing.expectEqualStrings("body\n", body_token.text);
    try std.testing.expect(!body_token.quoted);
    // The span covers the raw body including tabs and the delimiter line.
    try std.testing.expectEqualStrings("\tbody\n\tE\n", src.text[body_token.span.start..body_token.span.end]);
}

test "alias substitution copies here-document bodies verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var shell_state = state_mod.State.init(std.testing.allocator, .{ .mode = .posix });
    defer shell_state.deinit();
    try shell_state.putAlias(.{ .name = "hi", .value = "printf hi" });

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .script_file,
        .name = "test",
        .text = "cat <<E\nhi\nE\nhi\n",
    };
    const lexed = try lexWithAliasesSource(allocator, src, shell_state);

    // The command-position `hi` after the body expands; the body line does not.
    try std.testing.expectEqualStrings("cat <<E\nhi\nE\nprintf hi\n", lexed.source.text);
}

test "self-referential alias expands only once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var shell_state = state_mod.State.init(std.testing.allocator, .{ .mode = .posix });
    defer shell_state.deinit();
    try shell_state.putAlias(.{ .name = "ls", .value = "ls -lhv --color --group-directories-first" });

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .script_file,
        .name = "test",
        .text = "ls\n",
    };
    const lexed = try lexWithAliasesSource(allocator, src, shell_state);

    try std.testing.expectEqualStrings("ls -lhv --color --group-directories-first\n", lexed.source.text);
}

test "autoload function definition name bypasses alias substitution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var shell_state = state_mod.State.init(std.testing.allocator, .{ .interactive = true });
    defer shell_state.deinit();
    try shell_state.putAlias(.{ .name = "ls", .value = "ls -lhv --color --group-directories-first" });

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .sourced_file,
        .name = "test",
        .text = "ls() { printf hi; }\n",
    };
    const lexed = try lexWithAliasesSourceOptions(allocator, src, shell_state, .{ .autoload_function_name = "ls" });

    try std.testing.expectEqualStrings(src.text, lexed.source.text);
}
