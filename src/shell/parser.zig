//! Builds executable shell ASTs from lexer output, including expansions,
//! compound commands, redirections, and here-documents. AST structure uses the
//! caller's allocator and textual leaves may refer to source or token text, so
//! source text and allocator-backed lexer text must outlive the AST.

const std = @import("std");

const ast = @import("ast.zig");
const builtin = @import("builtin.zig");
const lexer = @import("lexer.zig");
const parse_scan = @import("parse_scan.zig");
const source_mod = @import("source.zig");
const state_mod = @import("state.zig");
const token = @import("token.zig");

pub const ParseError = error{
    ExpectedCommand,
    ExpectedRedirectionTarget,
    IncompleteHereDoc,
    InvalidParameterExpansion,
    UnclosedCommandSubstitution,
    UnclosedQuote,
    UnexpectedToken,
};

const ParserError = std.mem.Allocator.Error || ParseError;

/// Parses a complete token stream into allocator-backed AST storage. The AST
/// borrows source and token text, but does not retain the token slice itself.
// ziglint-ignore: Z015 existing public API error set exposure; preserve API
pub fn parse(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    tokens: []const token.Token,
) ParserError!ast.Program {
    return parseWithAliasState(allocator, src, tokens, null);
}

/// Parses a complete token stream with alias-aware nested parsing. Ownership
/// and input lifetimes match `parse`.
// ziglint-ignore: Z015 existing public API error set exposure; preserve API
pub fn parseWithAliases(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    tokens: []const token.Token,
    shell_state: state_mod.State,
) ParserError!ast.Program {
    return parseWithAliasState(allocator, src, tokens, shell_state);
}

/// Matches `parseWithAliases` ownership while rejecting incomplete here-docs.
// ziglint-ignore: Z015 existing public API error set exposure; preserve API
pub fn parseWithAliasesRequiringCompleteHereDocs(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    tokens: []const token.Token,
    shell_state: state_mod.State,
) ParserError!ast.Program {
    return parseWithAliasStateOptions(allocator, src, tokens, shell_state, .{ .require_complete_here_docs = true });
}

/// Returns an allocator-backed expansion whose textual parts may borrow
/// `raw_content`.
// ziglint-ignore: Z015 existing public API error set exposure; preserve API
pub fn parseBracedParameterExpansion(
    allocator: std.mem.Allocator,
    raw_content: []const u8,
    span: source_mod.Span,
) ParserError!?ast.ParameterExpansion {
    const src: source_mod.Source = .{ .id = 0, .kind = .command_string, .name = "${}", .text = raw_content };
    var parser_state: Parser = .{ .allocator = allocator, .source = src, .tokens = &.{}, .alias_state = null };
    return parser_state.parseBracedParameter(raw_content, span);
}

/// Returns an allocator-backed word whose textual parts may borrow `text`.
// ziglint-ignore: Z015 existing public API error set exposure; preserve API
pub fn parseWordExpansionText(
    allocator: std.mem.Allocator,
    text: []const u8,
    span: source_mod.Span,
) ParserError!ast.Word {
    const src: source_mod.Source = .{ .id = span.source_id, .kind = .command_string, .name = "word", .text = text };
    var parser_state: Parser = .{ .allocator = allocator, .source = src, .tokens = &.{}, .alias_state = null };
    return parser_state.parseWordText(text, span);
}

/// Parses expansion text using the same quoting rules as the contents of a
/// double-quoted word. Quote characters remain literal, while parameter,
/// command, arithmetic, and the applicable backslash expansions stay active.
/// The returned word may borrow `text`.
// ziglint-ignore: Z015 existing public API error set exposure; preserve API
pub fn parseDoubleQuotedExpansionText(
    allocator: std.mem.Allocator,
    text: []const u8,
    span: source_mod.Span,
) ParserError!ast.Word {
    const src: source_mod.Source = .{
        .id = span.source_id,
        .kind = .command_string,
        .name = "double-quoted expansion",
        .text = text,
    };
    var parser_state: Parser = .{ .allocator = allocator, .source = src, .tokens = &.{}, .alias_state = null };
    if (std.mem.indexOfAny(u8, text, "$\\`") == null) {
        const word: ast.Word = .{ .data = .{ .literal = text }, .span = span, .quoted = true };
        word.validate();
        return word;
    }

    var parts: std.ArrayList(ast.WordPart) = .empty;
    errdefer parts.deinit(allocator);
    try parser_state.appendWordParts(&parts, text, 0, text.len, .double, span);
    const word: ast.Word = .{
        .data = .{ .parts = try parts.toOwnedSlice(allocator) },
        .span = span,
        .quoted = true,
    };
    word.validate();
    return word;
}

/// Parses parameter expansions from raw text without applying shell quote
/// semantics. Other expansion forms are skipped as complete units so callers
/// can preserve them literally. The returned slice is allocator-backed and its
/// expansion text may borrow `text`.
// ziglint-ignore: Z015 matches the existing public parse API error set exposure
pub fn parseParameterExpansionText(
    allocator: std.mem.Allocator,
    text: []const u8,
) ParserError![]const ast.ParameterExpansion {
    const src: source_mod.Source = .{ .id = 0, .kind = .command_string, .name = "parameter expansion", .text = text };
    var parser_state: Parser = .{ .allocator = allocator, .source = src, .tokens = &.{}, .alias_state = null };
    var expansions: std.ArrayList(ast.ParameterExpansion) = .empty;
    errdefer expansions.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '`') {
            index = try parse_scan.scanBackquoteSubstitution(text, index, text.len) + 1;
            continue;
        }
        if (text[index] != '$') {
            index += 1;
            continue;
        }

        const name_start = index + 1;
        if (name_start >= text.len) break;
        if (text[name_start] == '\'') {
            index = try parse_scan.scanDollarSingleQuoteEnd(text, name_start + 1, text.len) + 1;
            continue;
        }
        if (name_start + 1 < text.len and text[name_start] == '(' and text[name_start + 1] == '(') {
            index = try parse_scan.scanArithmeticExpansion(text, index, text.len) + 2;
            continue;
        }
        if (text[name_start] == '(') {
            index = try parse_scan.scanCommandSubstitution(text, name_start, text.len) + 1;
            continue;
        }
        if (text[name_start] == '{') {
            const expansion_end = parse_scan.scanBracedParameterEnd(text, name_start, text.len) orelse {
                index += 1;
                continue;
            };
            const expansion_span = Parser.spanFromRelativeOffsets(.{}, text, index, expansion_end + 1);
            const expansion = try parser_state.parseBracedParameter(
                text[name_start + 1 .. expansion_end],
                expansion_span,
            ) orelse return error.InvalidParameterExpansion;
            try expansions.append(allocator, expansion);
            index = expansion_end + 1;
            continue;
        }
        if (parseSingleParameter(text[name_start])) |parameter| {
            try expansions.append(allocator, .{
                .parameter = parameter,
                .span = Parser.spanFromRelativeOffsets(.{}, text, index, name_start + 1),
            });
            index = name_start + 1;
            continue;
        }

        const name_end = scanParameterName(text, name_start, text.len);
        if (name_end == name_start) {
            index += 1;
            continue;
        }
        try expansions.append(allocator, .{
            .parameter = .{ .variable = text[name_start..name_end] },
            .span = Parser.spanFromRelativeOffsets(.{}, text, index, name_end),
        });
        index = name_end;
    }
    return expansions.toOwnedSlice(allocator);
}

fn parseWithAliasState(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    tokens: []const token.Token,
    alias_state: ?state_mod.State,
) ParserError!ast.Program {
    return parseWithAliasStateOptions(allocator, src, tokens, alias_state, .{});
}

pub const ParseOptions = struct {
    require_complete_here_docs: bool = false,
    /// When set, receives the location of the first parse failure so the
    /// caller can report a positioned diagnostic; errors themselves carry
    /// no payload.
    failure: ?*?Failure = null,
};

/// Location details for a parse error, captured from the token the parser
/// stopped at.
pub const Failure = struct {
    line: usize,
    /// Source text of the offending token; null when parsing stopped at
    /// end of input.
    near: ?[]const u8,
};

pub fn isParseError(err: anyerror) bool {
    return switch (err) {
        error.ExpectedCommand,
        error.ExpectedRedirectionTarget,
        error.IncompleteHereDoc,
        error.InvalidParameterExpansion,
        error.UnclosedCommandSubstitution,
        error.UnclosedQuote,
        error.UnexpectedToken,
        => true,
        else => false,
    };
}

/// Alias-aware whole-program parse that also reports failure locations through
/// `ParseOptions.failure`; output ownership and lifetimes match `parse`.
// ziglint-ignore: Z015 matches the existing public parse API error set exposure
pub fn parseWithAliasesAndOptions(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    tokens: []const token.Token,
    shell_state: state_mod.State,
    options: ParseOptions,
) ParserError!ast.Program {
    return parseWithAliasStateOptions(allocator, src, tokens, shell_state, options);
}

fn parseWithAliasStateOptions(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    tokens: []const token.Token,
    alias_state: ?state_mod.State,
    options: ParseOptions,
) ParserError!ast.Program {
    src.validate();
    std.debug.assert(tokens.len != 0);
    var parser: Parser = .{
        .allocator = allocator,
        .source = src,
        .tokens = tokens,
        .alias_state = alias_state,
        .require_complete_here_docs = options.require_complete_here_docs,
    };
    return parser.parseProgram() catch |err| {
        if (options.failure) |out| out.* = parser.currentFailure();
        return err;
    };
}

/// Incremental parser that borrows its source and token stream while parsing
/// and yields allocator-backed, newline-terminated complete commands. Source
/// and allocator-backed token text must remain valid for every returned AST;
/// command boundaries include here-document bodies following the newline.
pub const Incremental = struct {
    parser: Parser,
    started: bool = false,
    last_failure: ?Failure = null,

    pub fn init(
        allocator: std.mem.Allocator,
        src: source_mod.Source,
        tokens: []const token.Token,
        shell_state: state_mod.State,
    ) Incremental {
        return initWithOptions(allocator, src, tokens, shell_state, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        src: source_mod.Source,
        tokens: []const token.Token,
        shell_state: state_mod.State,
        options: ParseOptions,
    ) Incremental {
        src.validate();
        std.debug.assert(tokens.len != 0);
        return .{ .parser = .{
            .allocator = allocator,
            .source = src,
            .tokens = tokens,
            .alias_state = shell_state,
            .require_complete_here_docs = options.require_complete_here_docs,
        } };
    }

    /// True when parsing stopped at end of input, meaning an error from
    /// `next` describes incomplete input rather than a genuine syntax error.
    pub fn atEndOfInput(self: *const Incremental) bool {
        return self.parser.at(.eof);
    }

    /// Returns the next allocator-backed command, or null when only separators
    /// remain. Its textual data follows the source/token-text lifetime of `init`.
    // ziglint-ignore: Z015 matches the existing public parse API error set exposure
    pub fn next(self: *Incremental) ParserError!?ast.Program {
        return self.nextCommand() catch |err| {
            self.last_failure = self.parser.currentFailure();
            return err;
        };
    }

    /// Location of the most recent parse failure from `next`.
    pub fn failure(self: *const Incremental) ?Failure {
        return self.last_failure;
    }

    fn nextCommand(self: *Incremental) ParserError!?ast.Program {
        const p = &self.parser;
        // Leading separators are skipped once, mirroring parseList; between
        // commands only the newlines consumed after each terminator are
        // allowed, so a stray leading semicolon still errors.
        if (!self.started) {
            self.started = true;
            try p.skipSeparators();
        }
        if (p.at(.eof)) return null;

        var entries: std.ArrayList(ast.ListEntry) = .empty;
        errdefer entries.deinit(p.allocator);

        while (!p.at(.eof)) {
            const and_or = try p.parseAndOr();
            var terminator: ?ast.ListTerminator = null;
            if (p.eat(.semicolon) != null) terminator = .sequence;
            if (p.eat(.ampersand) != null) terminator = .background;
            var complete = false;
            if (p.eat(.newline) != null) {
                if (terminator == null) terminator = .sequence;
                try p.parsePendingHereDocs();
                try p.skipLinebreak();
                complete = true;
            } else if (p.atHereDocBody()) {
                // Bodies delimited by end of input arrive without a newline.
                try p.parsePendingHereDocs();
            }
            if (terminator == null and !p.at(.eof)) return error.UnexpectedToken;
            try entries.append(p.allocator, .{ .and_or = and_or, .terminator = terminator });
            if (complete) break;
        }

        const program: ast.Program = .{
            .source_id = p.source.id,
            .body = .{ .entries = try entries.toOwnedSlice(p.allocator) },
        };
        program.validate();
        return program;
    }

    /// Source text offset where the next unparsed command starts.
    pub fn nextOffset(self: *const Incremental) usize {
        const p = &self.parser;
        std.debug.assert(p.index < p.tokens.len);
        if (p.tokens[p.index].kind == .eof) return p.source.text.len;
        return p.tokens[p.index].span.start;
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    tokens: []const token.Token,
    alias_state: ?state_mod.State,
    require_complete_here_docs: bool = false,
    index: usize = 0,
    pending_here_docs: std.ArrayList(PendingHereDoc) = .empty,

    const PendingHereDoc = struct {
        redirection: *ast.Redirection,
    };

    fn parseProgram(self: *Parser) !ast.Program {
        const body = try self.parseList(.eof);
        try self.expect(.eof);
        // The lexer emits a body token for every here-document it saw, so
        // a leftover pending here-document means malformed input.
        if (self.pending_here_docs.items.len != 0) return error.IncompleteHereDoc;
        const program: ast.Program = .{ .source_id = self.source.id, .body = body };
        program.validate();
        return program;
    }

    const ListEnd = enum {
        eof,
        right_brace,
        right_paren,
        esac,
        do,
        done,
        then,
        if_branch,
        fi,
        case_item,
    };

    fn parseList(self: *Parser, end_kind: ListEnd) ParserError!ast.List {
        var entries: std.ArrayList(ast.ListEntry) = .empty;
        errdefer entries.deinit(self.allocator);

        try self.skipSeparators();
        while (!self.atListEnd(end_kind)) {
            const and_or = try self.parseAndOr();
            var terminator: ?ast.ListTerminator = null;
            if (self.eat(.semicolon) != null) terminator = .sequence;
            if (self.eat(.ampersand) != null) terminator = .background;
            if (self.eat(.newline) != null) {
                if (terminator == null) terminator = .sequence;
                try self.parsePendingHereDocs();
                try self.skipLinebreak();
            } else if (self.atHereDocBody()) {
                // Bodies delimited by end of input arrive without a newline.
                try self.parsePendingHereDocs();
            }
            if (terminator == null and !self.atListEnd(end_kind)) return error.UnexpectedToken;
            try entries.append(self.allocator, .{ .and_or = and_or, .terminator = terminator });
        }

        return .{ .entries = try entries.toOwnedSlice(self.allocator) };
    }

    fn parseAndOr(self: *Parser) ParserError!ast.AndOr {
        var pipelines: std.ArrayList(ast.AndOrPipeline) = .empty;
        errdefer pipelines.deinit(self.allocator);

        try pipelines.append(self.allocator, .{ .pipeline = try self.parsePipeline() });
        while (self.eatAndOrOperator()) |operator| {
            try self.skipLinebreak();
            try pipelines.append(self.allocator, .{
                .operator = operator,
                .pipeline = try self.parsePipeline(),
            });
        }

        const and_or: ast.AndOr = .{ .pipelines = try pipelines.toOwnedSlice(self.allocator) };
        return and_or;
    }

    fn parsePipeline(self: *Parser) ParserError!ast.Pipeline {
        const negated = self.eat(.bang) != null;
        var stages: std.ArrayList(ast.Command) = .empty;
        errdefer stages.deinit(self.allocator);

        try stages.append(self.allocator, try self.parseCommand());
        while (self.eatPipelineOperator()) |operator_token| {
            if (operator_token.kind == .pipe_ampersand) try self.appendPipeAndRedirection(&stages, operator_token.span);
            try self.skipLinebreak();
            try stages.append(self.allocator, try self.parseCommand());
        }

        const pipeline: ast.Pipeline = .{ .stages = try stages.toOwnedSlice(self.allocator), .negated = negated };
        return pipeline;
    }

    fn eatPipelineOperator(self: *Parser) ?token.Token {
        if (self.eat(.pipe)) |tok| return tok;
        if (self.at(.pipe_ampersand)) {
            if (self.mode() == .posix) return null;
            return self.eat(.pipe_ampersand).?;
        }
        return null;
    }

    fn appendPipeAndRedirection(self: *Parser, stages: *std.ArrayList(ast.Command), span: source_mod.Span) !void {
        std.debug.assert(stages.items.len != 0);
        const redirection = pipeAndRedirection(span);
        const last = &stages.items[stages.items.len - 1];
        switch (last.*) {
            .simple => |*simple| {
                simple.redirections = try appendRedirection(self.allocator, simple.redirections, redirection);
            },
            .compound => |*compound| {
                compound.redirections = try appendRedirection(self.allocator, compound.redirections, redirection);
            },
            .function_definition => |*definition| {
                definition.redirections = try appendRedirection(self.allocator, definition.redirections, redirection);
            },
        }
    }

    fn parseCommand(self: *Parser) ParserError!ast.Command {
        if (try self.parseFunctionDefinition()) |definition| return .{ .function_definition = definition };
        if (try self.parseCompoundCommand()) |compound| return .{ .compound = compound };
        return .{ .simple = try self.parseSimpleCommand() };
    }

    fn parseFunctionDefinition(self: *Parser) ParserError!?ast.FunctionDefinition {
        if (self.atReserved(.function_kw)) return self.parseBashFunctionDefinition();

        if (!self.at(.word)) return null;
        const name_token = self.tokens[self.index];
        if (name_token.quoted or !isFunctionName(name_token.text, self.mode())) return null;
        if (self.index + 2 >= self.tokens.len) return null;
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        if (self.tokens[self.index + 1].kind != .left_paren or self.tokens[self.index + 2].kind != .right_paren) return null;
        if (name_token.reserved != null) return error.UnexpectedToken;
        if (builtin.lookup(name_token.text)) |definition| {
            if (definition.kind == .special) return error.UnexpectedToken;
        }

        self.index += 3;
        try self.skipSeparators();
        const compound = (try self.parseCompoundCommand()) orelse return error.ExpectedCommand;

        const definition: ast.FunctionDefinition = .{
            .name = name_token.text,
            .body = compound.body,
            .redirections = compound.redirections,
        };
        if (self.canValidateHereDocs()) definition.validate();
        return definition;
    }

    fn parseBashFunctionDefinition(self: *Parser) ParserError!?ast.FunctionDefinition {
        if (self.mode() == .posix) return null;
        _ = self.eatReserved(.function_kw).?;
        try self.skipSeparators();

        const name_token = self.eat(.word) orelse return error.UnexpectedToken;
        if (name_token.quoted or !isFunctionName(name_token.text, self.mode())) return error.UnexpectedToken;

        if (self.eat(.left_paren) != null) {
            try self.expect(.right_paren);
        }
        try self.skipSeparators();
        const compound = (try self.parseCompoundCommand()) orelse return error.ExpectedCommand;

        const definition: ast.FunctionDefinition = .{
            .name = name_token.text,
            .body = compound.body,
            .redirections = compound.redirections,
        };
        if (self.canValidateHereDocs()) definition.validate();
        return definition;
    }

    fn parseCompoundCommand(self: *Parser) ParserError!?ast.CompoundInvocation {
        var body: ast.CompoundCommand = undefined;
        if (try self.parseIfCommand()) |if_command| {
            body = .{ .if_command = if_command };
        } else if (try self.parseLoopCommand()) |loop| {
            body = .{ .loop = loop };
        } else if (try self.parseCForCommand()) |c_for_command| {
            body = .{ .c_for_command = c_for_command };
        } else if (try self.parseForCommand()) |for_command| {
            body = .{ .for_command = for_command };
        } else if (try self.parseArithmeticCommand()) |arithmetic_command| {
            body = .{ .arithmetic_command = arithmetic_command };
        } else if (try self.parseConditionalCommand()) |conditional_command| {
            body = .{ .conditional_command = conditional_command };
        } else if (try self.parseCaseCommand()) |case_command| {
            body = .{ .case_command = case_command };
        } else if (self.eat(.left_paren) != null) {
            body = .{ .subshell = try self.parseList(.right_paren) };
            try self.expect(.right_paren);
        } else if (self.eat(.left_brace) != null) {
            const list = try self.parseList(.right_brace);
            if (list.entries.len == 0 or list.entries[list.entries.len - 1].terminator == null) {
                return error.UnexpectedToken;
            }
            body = .{ .brace_group = list };
            try self.expect(.right_brace);
        } else {
            return null;
        }

        const redirections = try self.parseRedirectionList();
        const invocation: ast.CompoundInvocation = .{ .body = body, .redirections = redirections };
        if (self.canValidateHereDocs()) invocation.validate();
        return invocation;
    }

    fn parseIfCommand(self: *Parser) ParserError!?ast.IfCommand {
        if (self.eatReserved(.if_kw) == null) return null;
        var branches: std.ArrayList(ast.IfBranch) = .empty;
        errdefer branches.deinit(self.allocator);

        while (true) {
            const condition = try self.parseList(.then);
            if (condition.entries.len == 0) return error.UnexpectedToken;
            _ = self.eatReserved(.then_kw) orelse return error.UnexpectedToken;
            const body = try self.parseList(.if_branch);
            if (body.entries.len == 0) return error.UnexpectedToken;
            try branches.append(self.allocator, .{ .condition = condition, .body = body });

            if (self.eatReserved(.elif_kw) != null) continue;
            const else_body = if (self.eatReserved(.else_kw) != null) try self.parseList(.fi) else null;
            _ = self.eatReserved(.fi_kw) orelse return error.UnexpectedToken;
            const command: ast.IfCommand = .{
                .branches = try branches.toOwnedSlice(self.allocator),
                .else_body = else_body,
            };
            if (self.canValidateHereDocs()) command.validate();
            return command;
        }
    }

    fn parseLoopCommand(self: *Parser) ParserError!?ast.LoopCommand {
        const kind: ast.LoopKind = if (self.eatReserved(.while_kw) != null)
            .while_loop
        else if (self.eatReserved(.until_kw) != null)
            .until_loop
        else
            return null;

        const condition = try self.parseList(.do);
        _ = self.eatReserved(.do_kw) orelse return error.UnexpectedToken;
        const body = try self.parseList(.done);
        _ = self.eatReserved(.done_kw) orelse return error.UnexpectedToken;

        const command: ast.LoopCommand = .{ .kind = kind, .condition = condition, .body = body };
        if (self.canValidateHereDocs()) command.validate();
        return command;
    }

    fn parseCForCommand(self: *Parser) ParserError!?ast.CForCommand {
        const start = self.index;
        if (self.eatReserved(.for_kw) == null) return null;
        if (!self.atArithmeticDelimiterStart()) {
            self.index = start;
            return null;
        }
        if (self.mode() == .posix) return error.UnexpectedToken;

        const header = try self.parseArithmeticDelimitedText();
        const sections = try cForSections(header);
        try self.skipSeparators();
        _ = self.eatReserved(.do_kw) orelse return error.UnexpectedToken;
        const body = try self.parseList(.done);
        _ = self.eatReserved(.done_kw) orelse return error.UnexpectedToken;

        const command: ast.CForCommand = .{
            .init = emptyArithmeticSectionAsNull(sections.init),
            .condition = emptyArithmeticSectionAsNull(sections.condition),
            .update = emptyArithmeticSectionAsNull(sections.update),
            .body = body,
        };
        if (self.canValidateHereDocs()) command.validate();
        return command;
    }

    fn parseForCommand(self: *Parser) ParserError!?ast.ForCommand {
        if (self.eatReserved(.for_kw) == null) return null;
        if (self.atArithmeticDelimiterStart()) return error.UnexpectedToken;
        const name_token = self.eat(.word) orelse return error.UnexpectedToken;
        if (name_token.quoted) return error.UnexpectedToken;
        if (!isAssignmentName(name_token.text) and self.mode() == .posix) return error.UnexpectedToken;

        var words: ast.ForWords = .positional_parameters;
        try self.skipSeparators();
        if (self.eatReserved(.in_kw) != null) {
            var word_list: std.ArrayList(ast.Word) = .empty;
            errdefer word_list.deinit(self.allocator);
            while (!self.at(.eof) and !self.at(.semicolon) and !self.at(.newline)) {
                // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                try word_list.append(self.allocator, try self.parseWordToken(self.eatForWordListWord() orelse return error.UnexpectedToken));
            }
            words = .{ .words = try word_list.toOwnedSlice(self.allocator) };
        }

        try self.skipSeparators();
        _ = self.eatReserved(.do_kw) orelse return error.UnexpectedToken;
        const body = try self.parseList(.done);
        _ = self.eatReserved(.done_kw) orelse return error.UnexpectedToken;

        const command: ast.ForCommand = .{ .name = name_token.text, .words = words, .body = body };
        if (self.canValidateHereDocs()) command.validate();
        return command;
    }

    fn parseArithmeticCommand(self: *Parser) ParserError!?ast.ArithmeticCommand {
        if (!self.atArithmeticDelimiterStart()) return null;
        if (self.mode() == .posix) return error.UnexpectedToken;

        const expression = try self.parseArithmeticDelimitedText();
        const command: ast.ArithmeticCommand = .{ .expression = expression };
        if (self.canValidateHereDocs()) command.validate();
        return command;
    }

    fn parseConditionalCommand(self: *Parser) ParserError!?ast.ConditionalCommand {
        if (!self.atConditionalStart()) return null;
        if (self.mode() == .posix) return error.UnexpectedToken;
        self.index += 1;

        const expression = try self.parseConditionalOr();
        if (!self.atConditionalEnd()) return error.UnexpectedToken;
        self.index += 1;

        const command: ast.ConditionalCommand = .{ .expression = expression };
        if (self.canValidateHereDocs()) command.validate();
        return command;
    }

    fn parseConditionalOr(self: *Parser) ParserError!ast.ConditionalExpression {
        var expression = try self.parseConditionalAnd();
        while (self.eat(.pipe_pipe) != null) {
            const left = try self.copyConditionalExpression(expression);
            const right = try self.copyConditionalExpression(try self.parseConditionalAnd());
            expression = .{ .binary = .{ .operator = .or_if, .left = left, .right = right } };
        }
        return expression;
    }

    fn parseConditionalAnd(self: *Parser) ParserError!ast.ConditionalExpression {
        var expression = try self.parseConditionalUnary();
        while (self.eat(.ampersand_ampersand) != null) {
            const left = try self.copyConditionalExpression(expression);
            const right = try self.copyConditionalExpression(try self.parseConditionalUnary());
            expression = .{ .binary = .{ .operator = .and_if, .left = left, .right = right } };
        }
        return expression;
    }

    fn parseConditionalUnary(self: *Parser) ParserError!ast.ConditionalExpression {
        if (self.eat(.bang) != null) {
            return .{ .unary_not = try self.copyConditionalExpression(try self.parseConditionalUnary()) };
        }

        if (self.eat(.left_paren) != null) {
            const expression = try self.parseConditionalOr();
            try self.expect(.right_paren);
            return expression;
        }

        return self.parseConditionalPrimary();
    }

    fn parseConditionalPrimary(self: *Parser) ParserError!ast.ConditionalExpression {
        const left_token = self.eatConditionalWord() orelse return error.UnexpectedToken;
        if (conditionalUnaryTestOperator(left_token)) |operator| {
            if (!self.atConditionalEnd()) {
                const operand_token = self.eatConditionalWord() orelse return error.UnexpectedToken;
                return .{ .unary_test = .{
                    .operator = operator,
                    .operand = try self.parseWordToken(operand_token),
                } };
            }
        }

        const left = try self.parseWordToken(left_token);
        if (self.eatConditionalComparisonOperator()) |operator| {
            const right_token = self.eatConditionalWord() orelse return error.UnexpectedToken;
            return .{ .comparison = .{
                .operator = operator,
                .left = left,
                .right = try self.parseWordToken(right_token),
            } };
        }
        return .{ .word = left };
    }

    fn copyConditionalExpression(
        self: *Parser,
        expression: ast.ConditionalExpression,
    ) !*const ast.ConditionalExpression {
        const copied = try self.allocator.create(ast.ConditionalExpression);
        copied.* = expression;
        return copied;
    }

    fn atConditionalStart(self: Parser) bool {
        if (!self.at(.word)) return false;
        const tok = self.tokens[self.index];
        return !tok.quoted and std.mem.eql(u8, tok.text, "[[");
    }

    fn atConditionalEnd(self: Parser) bool {
        if (!self.at(.word)) return false;
        const tok = self.tokens[self.index];
        return !tok.quoted and std.mem.eql(u8, tok.text, "]]");
    }

    fn eatConditionalWord(self: *Parser) ?token.Token {
        if (self.atConditionalEnd()) return null;
        return self.eat(.word);
    }

    fn eatConditionalComparisonOperator(self: *Parser) ?ast.ConditionalComparisonOperator {
        if (self.eat(.less) != null) return .less;
        if (self.eat(.greater) != null) return .greater;
        if (!self.at(.word)) return null;
        const tok = self.tokens[self.index];
        if (tok.quoted) return null;
        const operator: ast.ConditionalComparisonOperator = if (std.mem.eql(u8, tok.text, "==") or
            std.mem.eql(u8, tok.text, "="))
            .equal
        else if (std.mem.eql(u8, tok.text, "!="))
            .not_equal
        else if (std.mem.eql(u8, tok.text, "-eq"))
            .integer_equal
        else if (std.mem.eql(u8, tok.text, "-ne"))
            .integer_not_equal
        else if (std.mem.eql(u8, tok.text, "-gt"))
            .integer_greater
        else if (std.mem.eql(u8, tok.text, "-ge"))
            .integer_greater_equal
        else if (std.mem.eql(u8, tok.text, "-lt"))
            .integer_less
        else if (std.mem.eql(u8, tok.text, "-le"))
            .integer_less_equal
        else
            return null;
        self.index += 1;
        return operator;
    }

    fn conditionalUnaryTestOperator(tok: token.Token) ?ast.ConditionalUnaryTestOperator {
        if (tok.quoted) return null;
        if (std.mem.eql(u8, tok.text, "-b")) return .block_device;
        if (std.mem.eql(u8, tok.text, "-c")) return .character_device;
        if (std.mem.eql(u8, tok.text, "-d")) return .directory;
        if (std.mem.eql(u8, tok.text, "-e")) return .exists;
        if (std.mem.eql(u8, tok.text, "-f")) return .file;
        if (std.mem.eql(u8, tok.text, "-g")) return .setgid;
        if (std.mem.eql(u8, tok.text, "-h")) return .symlink;
        if (std.mem.eql(u8, tok.text, "-L")) return .symlink;
        if (std.mem.eql(u8, tok.text, "-p")) return .named_pipe;
        if (std.mem.eql(u8, tok.text, "-S")) return .socket;
        if (std.mem.eql(u8, tok.text, "-s")) return .nonempty_file;
        if (std.mem.eql(u8, tok.text, "-u")) return .setuid;
        if (std.mem.eql(u8, tok.text, "-t")) return .terminal;
        if (std.mem.eql(u8, tok.text, "-r")) return .readable;
        if (std.mem.eql(u8, tok.text, "-w")) return .writable;
        if (std.mem.eql(u8, tok.text, "-x")) return .executable;
        if (std.mem.eql(u8, tok.text, "-o")) return .option_enabled;
        if (std.mem.eql(u8, tok.text, "-n")) return .string_nonempty;
        if (std.mem.eql(u8, tok.text, "-z")) return .string_empty;
        if (std.mem.eql(u8, tok.text, "-v")) return .variable_set;
        return null;
    }

    fn parseCaseCommand(self: *Parser) ParserError!?ast.CaseCommand {
        if (self.eatReserved(.case_kw) == null) return null;
        const word = try self.parseWordToken(self.eat(.word) orelse return error.UnexpectedToken);
        try self.skipSeparators();
        _ = self.eatReserved(.in_kw) orelse return error.UnexpectedToken;
        try self.skipSeparators();

        var arms: std.ArrayList(ast.CaseArm) = .empty;
        errdefer arms.deinit(self.allocator);
        while (!self.atReserved(.esac_kw)) {
            try arms.append(self.allocator, try self.parseCaseArm());
            try self.skipSeparators();
        }
        _ = self.eatReserved(.esac_kw).?;

        const command: ast.CaseCommand = .{ .word = word, .arms = try arms.toOwnedSlice(self.allocator) };
        if (self.canValidateHereDocs()) command.validate();
        return command;
    }

    fn parseCaseArm(self: *Parser) ParserError!ast.CaseArm {
        _ = self.eat(.left_paren);

        var patterns: std.ArrayList(ast.Word) = .empty;
        errdefer patterns.deinit(self.allocator);
        while (true) {
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            try patterns.append(self.allocator, try self.parseWordToken(self.eatCasePatternWord() orelse return error.UnexpectedToken));
            if (self.eat(.pipe) == null) break;
        }
        try self.expect(.right_paren);

        const body = try self.parseList(.case_item);
        const fallthrough: ast.Fallthrough = if (self.eat(.double_semicolon) != null)
            .none
        else if (self.eat(.semicolon_ampersand) != null)
            .execute_next
        else if (self.eat(.double_semicolon_ampersand) != null)
            .test_next
        else
            .none;

        const arm: ast.CaseArm = .{
            .patterns = try patterns.toOwnedSlice(self.allocator),
            .body = body,
            .fallthrough = fallthrough,
        };
        if (self.canValidateHereDocs()) arm.validate();
        return arm;
    }

    fn parseSimpleCommand(self: *Parser) ParserError!ast.SimpleCommand {
        var assignments: std.ArrayList(ast.Assignment) = .empty;
        errdefer assignments.deinit(self.allocator);
        var words: std.ArrayList(ast.Word) = .empty;
        errdefer words.deinit(self.allocator);
        var redirections: std.ArrayList(ast.Redirection) = .empty;
        errdefer redirections.deinit(self.allocator);
        var command_span: ?source_mod.Span = null;

        while (true) {
            if (try self.parseRedirection()) |redirection| {
                try redirections.append(self.allocator, redirection);
                command_span = extendCommandSpan(command_span, redirection.span);
                continue;
            }

            const word_token = self.eatSimpleCommandWord(words.items.len != 0) orelse break;
            if (words.items.len == 0) {
                if (try self.parseAssignment(word_token)) |assignment| {
                    try assignments.append(self.allocator, assignment);
                    command_span = extendCommandSpan(command_span, word_token.span);
                    continue;
                }
            } else if (self.simpleCommandStartsDeclarationBuiltin(words.items) and self.at(.left_paren)) {
                if (try self.parseAssignment(word_token)) |assignment| {
                    std.debug.assert(assignment.array_values != null);
                    try words.append(self.allocator, .{
                        .data = .{ .declaration_array_assignment = .{
                            .name = assignment.name,
                            .values = assignment.array_values.?,
                            .append = assignment.append,
                            .span = assignment.span,
                        } },
                        .span = assignment.span,
                    });
                    command_span = extendCommandSpan(command_span, assignment.span);
                    continue;
                }
            }

            const word = try self.parseWordToken(word_token);
            try words.append(self.allocator, word);
            command_span = extendCommandSpan(command_span, word_token.span);
        }

        if (assignments.items.len == 0 and words.items.len == 0 and redirections.items.len == 0) {
            return error.ExpectedCommand;
        }
        const redirection_items = try redirections.toOwnedSlice(self.allocator);
        try self.registerPendingHereDocs(redirection_items);
        const command: ast.SimpleCommand = .{
            .assignments = try assignments.toOwnedSlice(self.allocator),
            .words = try words.toOwnedSlice(self.allocator),
            .redirections = redirection_items,
            .span = command_span.?,
        };
        if (self.canValidateHereDocs()) command.validate();
        return command;
    }

    fn canValidateHereDocs(self: Parser) bool {
        return self.pending_here_docs.items.len == 0;
    }

    fn simpleCommandStartsDeclarationBuiltin(self: Parser, words: []const ast.Word) bool {
        if (self.mode() == .posix or words.len == 0) return false;
        const literal = switch (words[0].data) {
            .literal => |literal| literal,
            else => return false,
        };
        return std.mem.eql(u8, literal, "declare") or
            std.mem.eql(u8, literal, "typeset") or
            std.mem.eql(u8, literal, "local") or
            std.mem.eql(u8, literal, "export") or
            std.mem.eql(u8, literal, "readonly");
    }

    fn parseRedirectionList(self: *Parser) ParserError![]const ast.Redirection {
        var redirections: std.ArrayList(ast.Redirection) = .empty;
        errdefer redirections.deinit(self.allocator);
        while (try self.parseRedirection()) |redirection| {
            try redirections.append(self.allocator, redirection);
        }
        const redirection_items = try redirections.toOwnedSlice(self.allocator);
        try self.registerPendingHereDocs(redirection_items);
        return redirection_items;
    }

    fn registerPendingHereDocs(self: *Parser, redirections: []ast.Redirection) !void {
        for (redirections) |*redirection| {
            if (redirection.op == .here_doc or redirection.op == .here_doc_strip_tabs) {
                try self.pending_here_docs.append(self.allocator, .{ .redirection = redirection });
            }
        }
    }

    fn parseRedirection(self: *Parser) !?ast.Redirection {
        const fd_token = self.eat(.io_number);
        const operator_token = if (self.eatRedirectionOperator()) |tok| tok else {
            if (fd_token != null) return error.UnexpectedToken;
            return null;
        };
        if (redirectionOperatorIsBashOnly(operator_token.kind) and self.mode() == .posix) return error.UnexpectedToken;
        const target_token = self.eat(.word) orelse return error.ExpectedRedirectionTarget;
        const redirection: ast.Redirection = .{
            .fd = if (fd_token) |tok| try parseIoNumber(tok.text) else null,
            .op = redirectionOperator(operator_token.kind),
            .target = try self.parseWordToken(target_token),
            .span = extendCommandSpan(
                if (fd_token) |tok| tok.span else null,
                spanTo(operator_token.span, target_token.span.end),
            ),
        };
        if (redirection.op != .here_doc and redirection.op != .here_doc_strip_tabs) redirection.validate();
        return redirection;
    }

    fn parseAssignment(self: *Parser, word_token: token.Token) !?ast.Assignment {
        const equals_index = std.mem.indexOfScalar(u8, word_token.text, '=') orelse return null;
        const append = equals_index > 0 and word_token.text[equals_index - 1] == '+';
        const name_end = if (append) equals_index - 1 else equals_index;
        const array_index = arrayAssignmentIndex(word_token.text[0..name_end]);
        const name = if (array_index) |index| word_token.text[0..index] else word_token.text[0..name_end];
        if (!isAssignmentName(name)) return null;
        if (append and self.mode() == .posix) return error.UnexpectedToken;
        if ((array_index != null or self.at(.left_paren)) and self.mode() == .posix) return error.UnexpectedToken;

        if (array_index == null and self.at(.left_paren)) {
            const array_values = try self.parseArrayAssignmentValues();
            const assignment: ast.Assignment = .{
                .name = name,
                .value = .{ .data = .{ .literal = "" }, .span = word_token.span },
                .append = append,
                .array_values = array_values,
                .span = word_token.span,
            };
            assignment.validate();
            return assignment;
        }

        const value_span = spanFromRelativeOffsets(
            word_token.span,
            word_token.text,
            equals_index + 1,
            word_token.text.len,
        );
        var value = try self.parseWordText(
            word_token.text[equals_index + 1 ..],
            value_span,
        );
        value.quoted = word_token.quoted;
        value.validate();
        const assignment: ast.Assignment = .{
            .name = name,
            .value = value,
            .append = append,
            .index = if (array_index) |index| try self.parseArrayAssignmentIndex(word_token, index, name_end) else null,
            .span = word_token.span,
        };
        assignment.validate();
        return assignment;
    }

    fn parseArrayAssignmentValues(self: *Parser) ParserError![]const ast.ArrayAssignmentElement {
        try self.expect(.left_paren);
        var values: std.ArrayList(ast.ArrayAssignmentElement) = .empty;
        errdefer values.deinit(self.allocator);
        while (true) {
            try self.skipLinebreak();
            if (self.eat(.right_paren) != null) break;
            const word_token = self.eat(.word) orelse return error.UnexpectedToken;
            try values.append(self.allocator, try self.parseArrayAssignmentElement(word_token));
        }
        return values.toOwnedSlice(self.allocator);
    }

    fn parseArrayAssignmentElement(self: *Parser, word_token: token.Token) ParserError!ast.ArrayAssignmentElement {
        if (compoundArrayElementEqualsIndex(word_token.text)) |equals_index| {
            const index_span = spanFromRelativeOffsets(word_token.span, word_token.text, 1, equals_index - 1);
            const value_span = spanFromRelativeOffsets(
                word_token.span,
                word_token.text,
                equals_index + 1,
                word_token.text.len,
            );
            const element: ast.ArrayAssignmentElement = .{
                .index = try self.parseWordText(word_token.text[1 .. equals_index - 1], index_span),
                .value = try self.parseWordText(word_token.text[equals_index + 1 ..], value_span),
                .span = word_token.span,
            };
            element.validate();
            return element;
        }

        const element: ast.ArrayAssignmentElement = .{
            .value = try self.parseWordToken(word_token),
            .span = word_token.span,
        };
        element.validate();
        return element;
    }

    fn compoundArrayElementEqualsIndex(text: []const u8) ?usize {
        if (text.len < 4 or text[0] != '[') return null;
        const close_index = std.mem.indexOfScalar(u8, text, ']') orelse return null;
        if (close_index == 1 or close_index + 1 >= text.len or text[close_index + 1] != '=') return null;
        return close_index + 1;
    }

    fn parseArrayAssignmentIndex(
        self: *Parser,
        word_token: token.Token,
        open_index: usize,
        name_end: usize,
    ) ParserError!ast.Word {
        std.debug.assert(open_index < name_end);
        std.debug.assert(word_token.text[open_index] == '[');
        std.debug.assert(word_token.text[name_end - 1] == ']');
        const index_start = open_index + 1;
        const index_end = name_end - 1;
        const index_span = spanFromRelativeOffsets(word_token.span, word_token.text, index_start, index_end);
        return self.parseWordText(word_token.text[index_start..index_end], index_span);
    }

    fn parseWordToken(self: *Parser, word_token: token.Token) !ast.Word {
        std.debug.assert(word_token.kind == .word);
        var word = try self.parseWordText(word_token.text, word_token.span);
        word.quoted = word_token.quoted;
        word.validate();
        return word;
    }

    fn parseWordText(
        self: *Parser,
        text: []const u8,
        span: source_mod.Span,
    ) ParserError!ast.Word {
        if (std.mem.indexOfAny(u8, text, "'\"$\\`<>") == null) {
            const word: ast.Word = .{ .data = .{ .literal = text }, .span = span };
            word.validate();
            return word;
        }

        var parts: std.ArrayList(ast.WordPart) = .empty;
        errdefer parts.deinit(self.allocator);
        try self.appendWordParts(&parts, text, 0, text.len, .plain, span);

        const word: ast.Word = .{ .data = .{ .parts = try parts.toOwnedSlice(self.allocator) }, .span = span };
        word.validate();
        return word;
    }

    /// Quoting context for word-part construction. Here-documents follow
    /// double-quote rules except that the double-quote character is
    /// ordinary and backslash escapes only '$', '`', '\', and <newline>
    /// (POSIX 2.7.4).
    const QuoteContext = enum {
        plain,
        double,
        here_doc,
    };

    fn appendWordParts(
        self: *Parser,
        parts: *std.ArrayList(ast.WordPart),
        text: []const u8,
        start: usize,
        end: usize,
        context: QuoteContext,
        span: source_mod.Span,
    ) ParserError!void {
        var index = start;
        var literal_start = start;
        while (index < end) {
            switch (text[index]) {
                '\'' => if (context == .plain) {
                    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                    if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                    const quote_start = index + 1;
                    index = quote_start;
                    while (index < end and text[index] != '\'') index += 1;
                    if (index >= end) return error.UnclosedQuote;
                    try parts.append(self.allocator, .{ .single_quoted = text[quote_start..index] });
                    index += 1;
                    literal_start = index;
                    continue;
                },
                '"' => if (context == .plain) {
                    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                    if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                    const quote_start = index + 1;
                    index = try parse_scan.scanDoubleQuoteEnd(text, quote_start, end);

                    var quoted_parts: std.ArrayList(ast.WordPart) = .empty;
                    errdefer quoted_parts.deinit(self.allocator);
                    try self.appendWordParts(&quoted_parts, text, quote_start, index, .double, span);
                    try parts.append(self.allocator, .{
                        .double_quoted = try quoted_parts.toOwnedSlice(self.allocator),
                    });

                    index += 1;
                    literal_start = index;
                    continue;
                },
                '\\' => {
                    const backslash_literal = switch (context) {
                        .plain => false,
                        .double => index + 1 < end and !doubleQuoteEscapes(text[index + 1]),
                        .here_doc => index + 1 < end and !hereDocEscapes(text[index + 1]),
                    };
                    if (backslash_literal) {
                        index += 1;
                        continue;
                    }
                    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                    if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                    index += 1;
                    if (index >= end) {
                        try parts.append(self.allocator, .{ .escaped = "\\" });
                    } else if (text[index] == '\n') {
                        index += 1;
                    } else {
                        try parts.append(self.allocator, .{ .escaped = text[index .. index + 1] });
                        index += 1;
                    }
                    literal_start = index;
                    continue;
                },
                '`' => {
                    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                    if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                    const substitution_end = try parse_scan.scanBackquoteSubstitution(text, index, end);
                    const source_text = try self.backquoteSourceText(text[index + 1 .. substitution_end]);
                    const line_offset = self.commandSubstitutionLineOffset(span, text, index + 1);
                    const parsed = try self.parseCommandSubstitution(source_text, line_offset);
                    try parts.append(self.allocator, .{
                        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                        .command_substitution = .{ .source_text = source_text, .parsed = parsed, .line_offset = line_offset },
                    });
                    index = substitution_end + 1;
                    literal_start = index;
                    continue;
                },
                '<', '>' => |operator| if (context == .plain and index + 1 < end and text[index + 1] == '(') {
                    if (self.mode() == .posix) return error.UnexpectedToken;
                    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                    if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                    const substitution_end = try parse_scan.scanCommandSubstitution(text, index + 1, end);
                    const source_text = text[index + 2 .. substitution_end];
                    const line_offset = self.commandSubstitutionLineOffset(span, text, index + 2);
                    const parsed = try self.parseCommandSubstitution(source_text, line_offset);
                    try parts.append(self.allocator, .{
                        .process_substitution = .{
                            .kind = if (operator == '<') .input else .output,
                            .source_text = source_text,
                            .parsed = parsed,
                            .line_offset = line_offset,
                        },
                    });
                    index = substitution_end + 1;
                    literal_start = index;
                    continue;
                },
                '$' => {
                    const name_start = index + 1;
                    if (context == .plain and name_start < end and text[name_start] == '\'') {
                        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                        if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                        const quote_start = name_start + 1;
                        const quote_end = try parse_scan.scanDollarSingleQuoteEnd(text, quote_start, end);
                        try parts.append(self.allocator, .{
                            .single_quoted = try self.dollarSingleQuotedText(text[quote_start..quote_end]),
                        });
                        index = quote_end + 1;
                        literal_start = index;
                        continue;
                    }
                    if (name_start + 1 < end and text[name_start] == '(' and text[name_start + 1] == '(') {
                        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                        if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                        const arithmetic_end = try parse_scan.scanArithmeticExpansion(text, index, end);
                        try parts.append(self.allocator, .{ .arithmetic = text[name_start + 2 .. arithmetic_end] });
                        index = arithmetic_end + 2;
                        literal_start = index;
                        continue;
                    }
                    if (name_start < end and text[name_start] == '(') {
                        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                        if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                        const substitution_end = try parse_scan.scanCommandSubstitution(text, name_start, end);
                        const source_text = text[name_start + 1 .. substitution_end];
                        const line_offset = self.commandSubstitutionLineOffset(span, text, name_start + 1);
                        const parsed = try self.parseCommandSubstitution(source_text, line_offset);
                        try parts.append(self.allocator, .{
                            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                            .command_substitution = .{ .source_text = source_text, .parsed = parsed, .line_offset = line_offset },
                        });
                        index = substitution_end + 1;
                        literal_start = index;
                        continue;
                    }
                    if (name_start < end and text[name_start] == '{') {
                        const expansion_end = parse_scan.scanBracedParameterEnd(text, name_start, end) orelse {
                            index += 1;
                            continue;
                        };
                        const expansion_span = spanFromRelativeOffsets(span, text, index, expansion_end + 1);
                        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                        if (try self.parseBracedParameter(text[name_start + 1 .. expansion_end], expansion_span)) |parameter| {
                            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                            if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                            try parts.append(self.allocator, .{ .parameter = parameter });
                            index = expansion_end + 1;
                            literal_start = index;
                            continue;
                        }
                        return error.InvalidParameterExpansion;
                    }
                    if (name_start < end) {
                        if (parseSingleParameter(text[name_start])) |parameter| {
                            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                            if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                            try parts.append(self.allocator, .{
                                .parameter = .{
                                    .parameter = parameter,
                                    .span = spanFromRelativeOffsets(span, text, index, name_start + 1),
                                },
                            });
                            index = name_start + 1;
                            literal_start = index;
                            continue;
                        }
                    }
                    if (name_start < end and text[name_start] == '?') {
                        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                        if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                        try parts.append(self.allocator, .{
                            .parameter = .{
                                .parameter = .{ .special = .question },
                                .span = spanFromRelativeOffsets(span, text, index, name_start + 1),
                            },
                        });
                        index = name_start + 1;
                        literal_start = index;
                        continue;
                    }
                    const name_end = scanParameterName(text, name_start, end);
                    if (name_end == name_start) {
                        index += 1;
                        continue;
                    }
                    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                    if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                    try parts.append(self.allocator, .{
                        .parameter = .{
                            .parameter = .{ .variable = text[name_start..name_end] },
                            .span = spanFromRelativeOffsets(span, text, index, name_end),
                        },
                    });
                    index = name_end;
                    literal_start = index;
                    continue;
                },
                else => {},
            }
            index += 1;
        }

        if (literal_start < end) try parts.append(self.allocator, .{ .literal = text[literal_start..end] });
    }

    fn dollarSingleQuotedText(self: *Parser, text: []const u8) ![]const u8 {
        var output: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (index < text.len) {
            if (text[index] != '\\') {
                try output.append(self.allocator, text[index]);
                index += 1;
                continue;
            }
            index += 1;
            if (index >= text.len) {
                try output.append(self.allocator, '\\');
                break;
            }
            switch (text[index]) {
                'a' => try output.append(self.allocator, 0x07),
                'b' => try output.append(self.allocator, 0x08),
                'e', 'E' => try output.append(self.allocator, 0x1b),
                'f' => try output.append(self.allocator, 0x0c),
                'n' => try output.append(self.allocator, '\n'),
                'r' => try output.append(self.allocator, '\r'),
                't' => try output.append(self.allocator, '\t'),
                'v' => try output.append(self.allocator, 0x0b),
                '\\', '\'', '"', '?' => try output.append(self.allocator, text[index]),
                'x' => {
                    const consumed = try appendHexEscape(self.allocator, &output, text[index + 1 ..]);
                    index += consumed;
                },
                '0'...'7' => {
                    const consumed = try appendOctalEscape(self.allocator, &output, text[index..]);
                    index += consumed - 1;
                },
                '\n' => {},
                else => try output.append(self.allocator, text[index]),
            }
            index += 1;
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn parseBracedParameter(
        self: *Parser,
        raw_content: []const u8,
        span: source_mod.Span,
    ) ParserError!?ast.ParameterExpansion {
        const content = try self.removeBackslashNewlines(raw_content);
        if (parseBracedSimpleParameter(content)) |parameter| return .{ .parameter = parameter, .span = span };
        if (try self.parseBracedArrayParameter(content)) |parameter| return .{ .parameter = parameter, .span = span };
        if (content.len >= 2 and content[0] == '!') {
            if (try self.parseBracedArrayParameter(content[1..])) |parameter| {
                switch (parameter.array.subscript) {
                    .all => return .{
                        .parameter = parameter,
                        .array_indices = true,
                        .span = span,
                    },
                    .index => {},
                }
            }
            return null;
        }
        if (content.len >= 2 and content[0] == '#') {
            const length_parameter = if (try self.parseBracedArrayParameter(content[1..])) |array_parameter|
                array_parameter
            else parameter: {
                const length_prefix = parseBracedParameterPrefix(content[1..]) orelse return null;
                if (length_prefix.end != content.len - 1) return null;
                break :parameter length_prefix.parameter;
            };
            return .{
                .parameter = length_parameter,
                .length = true,
                .span = span,
            };
        }

        const prefix = (try self.parseBracedArrayParameterPrefix(content)) orelse
            (parseBracedParameterPrefix(content) orelse return null);
        const rest = content[prefix.end..];
        if (rest.len == 0) return .{ .parameter = prefix.parameter, .span = span };

        if (self.mode() != .posix and std.mem.eql(u8, rest, "@P")) return .{
            .parameter = prefix.parameter,
            .op = .transform_prompt,
            .span = span,
        };
        if (try self.parseBashSubstring(prefix.parameter, rest, span)) |parameter| return parameter;
        if (try self.parseBashSubstitution(prefix.parameter, rest, span)) |parameter| return parameter;
        if (try self.parsePatternRemoval(prefix.parameter, rest, span)) |parameter| return parameter;

        const colon = rest.len >= 2 and rest[0] == ':' and isParameterOperator(rest[1]);
        if (colon or isParameterOperator(rest[0])) {
            const operator_byte = if (colon) rest[1] else rest[0];
            const word_text = if (colon) rest[2..] else rest[1..];
            return .{
                .parameter = prefix.parameter,
                .colon = colon,
                .op = parameterOperator(operator_byte),
                .word = try self.parseWordText(word_text, .{}),
                .span = span,
            };
        }

        return null;
    }

    fn parseBracedArrayParameter(self: *Parser, content: []const u8) ParserError!?ast.Parameter {
        const prefix = (try self.parseBracedArrayParameterPrefix(content)) orelse return null;
        if (prefix.end != content.len) return null;
        return prefix.parameter;
    }

    fn parseBracedArrayParameterPrefix(self: *Parser, content: []const u8) ParserError!?BracedParameterPrefix {
        if (self.mode() == .posix) return null;
        const open_index = std.mem.indexOfScalar(u8, content, '[') orelse return null;
        if (open_index == 0) return null;
        const close_index = std.mem.indexOfScalarPos(u8, content, open_index + 1, ']') orelse return null;
        const name = content[0..open_index];
        if (!isAssignmentName(name)) return null;
        const subscript = content[open_index + 1 .. close_index];
        if (std.mem.eql(u8, subscript, "@")) return .{
            .parameter = .{ .array = .{ .name = name, .subscript = .{ .all = .at } } },
            .end = close_index + 1,
        };
        if (std.mem.eql(u8, subscript, "*")) return .{
            .parameter = .{ .array = .{ .name = name, .subscript = .{ .all = .star } } },
            .end = close_index + 1,
        };
        return .{
            .parameter = .{ .array = .{
                .name = name,
                .subscript = .{ .index = try self.parseWordText(subscript, .{}) },
            } },
            .end = close_index + 1,
        };
    }

    fn parseBashSubstring(
        self: *Parser,
        parameter: ast.Parameter,
        rest: []const u8,
        span: source_mod.Span,
    ) ParserError!?ast.ParameterExpansion {
        if (self.mode() == .posix or rest.len == 0 or rest[0] != ':') return null;
        if (rest.len >= 2 and isParameterOperator(rest[1])) return null;

        const offset_text = rest[1..];
        const length_start = parse_scan.topLevelParameterColon(offset_text) orelse {
            return .{
                .parameter = parameter,
                .op = .substring,
                .word = try self.parseWordText(offset_text, .{}),
                .span = span,
            };
        };
        return .{
            .parameter = parameter,
            .op = .substring,
            .word = try self.parseWordText(offset_text[0..length_start], .{}),
            .second_word = try self.parseWordText(offset_text[length_start + 1 ..], .{}),
            .span = span,
        };
    }

    fn parseBashSubstitution(
        self: *Parser,
        parameter: ast.Parameter,
        rest: []const u8,
        span: source_mod.Span,
    ) ParserError!?ast.ParameterExpansion {
        if (self.mode() == .posix or rest.len == 0 or rest[0] != '/') return null;

        var operator: ast.ParameterOperator = .substitute_first;
        var pattern_start: usize = 1;
        if (rest.len >= 2) switch (rest[1]) {
            '/' => {
                operator = .substitute_all;
                pattern_start = 2;
            },
            '#' => {
                operator = .substitute_prefix;
                pattern_start = 2;
            },
            '%' => {
                operator = .substitute_suffix;
                pattern_start = 2;
            },
            else => {},
        };

        const replacement_start = parse_scan.topLevelParameterSlash(rest, pattern_start);
        const pattern_text = if (replacement_start) |index| rest[pattern_start..index] else rest[pattern_start..];
        const replacement_text = if (replacement_start) |index| rest[index + 1 ..] else "";
        return .{
            .parameter = parameter,
            .op = operator,
            .word = try self.parseWordText(pattern_text, .{}),
            .second_word = try self.parseWordText(replacement_text, .{}),
            .span = span,
        };
    }

    fn parsePatternRemoval(
        self: *Parser,
        parameter: ast.Parameter,
        rest: []const u8,
        span: source_mod.Span,
    ) ParserError!?ast.ParameterExpansion {
        if (rest.len == 0) return null;
        const PatternRemoval = struct {
            operator: ast.ParameterOperator,
            word_text: []const u8,
        };
        const removal: PatternRemoval = switch (rest[0]) {
            '#' => if (rest.len >= 2 and rest[1] == '#') .{
                .operator = .remove_large_prefix,
                .word_text = rest[2..],
            } else .{
                .operator = .remove_small_prefix,
                .word_text = rest[1..],
            },
            '%' => if (rest.len >= 2 and rest[1] == '%') .{
                .operator = .remove_large_suffix,
                .word_text = rest[2..],
            } else .{
                .operator = .remove_small_suffix,
                .word_text = rest[1..],
            },
            else => return null,
        };
        return .{
            .parameter = parameter,
            .op = removal.operator,
            .word = try self.parseWordText(removal.word_text, .{}),
            .span = span,
        };
    }

    fn removeBackslashNewlines(self: *Parser, text: []const u8) ParserError![]const u8 {
        const first = std.mem.indexOf(u8, text, "\\\n") orelse return text;
        var output: std.ArrayList(u8) = .empty;
        try output.appendSlice(self.allocator, text[0..first]);

        var index = first;
        while (index < text.len) {
            if (index + 1 < text.len and text[index] == '\\' and text[index + 1] == '\n') {
                index += 2;
                continue;
            }
            try output.append(self.allocator, text[index]);
            index += 1;
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn parseCommandSubstitution(self: *Parser, source_text: []const u8, line_offset: usize) !*const ast.Program {
        _ = line_offset;
        const src: source_mod.Source = .{
            .id = self.source.id,
            .kind = .command_string,
            .name = "$()",
            .text = source_text,
        };
        const lexed = if (self.alias_state) |alias_state|
            try lexer.lexWithAliasesSource(self.allocator, src, alias_state)
        else
            lexer.AliasLexResult{ .source = src, .tokens = try lexer.lex(self.allocator, src) };
        const program = try parseWithAliasState(self.allocator, lexed.source, lexed.tokens, self.alias_state);
        const owned = try self.allocator.create(ast.Program);
        owned.* = program;
        return owned;
    }

    fn commandSubstitutionLineOffset(self: *Parser, span: source_mod.Span, text: []const u8, start: usize) usize {
        _ = self;
        const source_start = spanFromRelativeOffsets(span, text, start, start);
        return source_start.start_line - 1;
    }

    fn backquoteSourceText(self: *Parser, raw: []const u8) ParserError![]const u8 {
        var output: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (index < raw.len) {
            if (raw[index] == '\\' and index + 1 < raw.len) {
                switch (raw[index + 1]) {
                    '`' => {
                        try output.append(self.allocator, '`');
                        index += 2;
                    },
                    '\\' => {
                        try output.append(self.allocator, '\\');
                        index += 2;
                    },
                    '\n' => index += 2,
                    else => {
                        try output.append(self.allocator, raw[index]);
                        try output.append(self.allocator, raw[index + 1]);
                        index += 2;
                    },
                }
            } else {
                try output.append(self.allocator, raw[index]);
                index += 1;
            }
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn spanFromRelativeOffsets(span: source_mod.Span, text: []const u8, start: usize, end: usize) source_mod.Span {
        std.debug.assert(start <= end);
        std.debug.assert(end <= text.len);

        var position: source_mod.Position = .{
            .source_id = span.source_id,
            .byte_offset = span.start,
            .line = span.start_line,
            .column = span.start_column,
        };
        position.advance(text[0..start]);
        return source_mod.Span.init(position, span.start + end);
    }

    fn skipSeparators(self: *Parser) ParserError!void {
        while (true) {
            if (self.eat(.newline) != null) {
                try self.parsePendingHereDocs();
                continue;
            }
            if (self.eat(.semicolon) != null) continue;
            return;
        }
    }

    /// Skips newlines between parts of a command, parsing any pending
    /// here-document bodies that begin after each newline (POSIX 2.3: the
    /// body starts after the next NEWLINE token, even one that continues a
    /// pipeline or AND-OR list).
    fn skipLinebreak(self: *Parser) ParserError!void {
        while (self.eat(.newline) != null) {
            try self.parsePendingHereDocs();
        }
    }

    fn atHereDocBody(self: Parser) bool {
        return self.at(.here_doc_body) or self.at(.here_doc_body_unterminated);
    }

    fn atArithmeticDelimiterStart(self: Parser) bool {
        if (!self.at(.left_paren) or self.index + 1 >= self.tokens.len) return false;
        const first = self.tokens[self.index];
        const second = self.tokens[self.index + 1];
        return second.kind == .left_paren and first.span.end == second.span.start;
    }

    fn parseArithmeticDelimitedText(self: *Parser) ParserError![]const u8 {
        std.debug.assert(self.atArithmeticDelimiterStart());
        const open = self.tokens[self.index + 1];
        const content_start = open.span.end;
        self.index += 2;

        var depth: usize = 0;
        while (self.index + 1 < self.tokens.len) : (self.index += 1) {
            const tok = self.tokens[self.index];
            if (tok.kind == .left_paren) {
                depth += 1;
                continue;
            }
            if (tok.kind != .right_paren) continue;
            if (depth != 0) {
                depth -= 1;
                continue;
            }

            const next = self.tokens[self.index + 1];
            if (next.kind == .right_paren and tok.span.end == next.span.start) {
                const content = self.source.text[content_start..tok.span.start];
                self.index += 2;
                return content;
            }
        }
        return error.UnexpectedToken;
    }

    /// Snapshots the location where parsing stopped, for diagnostics. The
    /// token at the current index is the best approximation of the error
    /// position without threading spans through every error return.
    fn currentFailure(self: *const Parser) Failure {
        const tok = self.tokens[@min(self.index, self.tokens.len - 1)];
        return .{
            .line = tok.span.start_line,
            .near = if (tok.kind == .eof) null else self.source.text[tok.span.start..tok.span.end],
        };
    }

    fn expect(self: *Parser, kind: token.Kind) ParseError!void {
        _ = self.eat(kind) orelse return error.UnexpectedToken;
    }

    fn eat(self: *Parser, kind: token.Kind) ?token.Token {
        if (!self.at(kind)) return null;
        defer self.index += 1;
        return self.tokens[self.index];
    }

    fn eatSimpleCommandWord(self: *Parser, after_command_name: bool) ?token.Token {
        if (self.eat(.word)) |word| return word;
        if (!after_command_name) return null;
        return switch (self.tokens[self.index].kind) {
            .bang, .left_brace, .right_brace => token_word: {
                break :token_word self.eatOperatorAsWord();
            },
            else => null,
        };
    }

    fn eatCasePatternWord(self: *Parser) ?token.Token {
        if (self.eat(.word)) |word| return word;
        if (!self.at(.bang)) return null;
        return self.eatOperatorAsWord();
    }

    fn eatForWordListWord(self: *Parser) ?token.Token {
        if (self.eat(.word)) |word| return word;
        return switch (self.tokens[self.index].kind) {
            .bang, .left_brace, .right_brace => self.eatOperatorAsWord(),
            else => null,
        };
    }

    fn eatOperatorAsWord(self: *Parser) token.Token {
        const tok = self.tokens[self.index];
        self.index += 1;
        return .{
            .kind = .word,
            .span = tok.span,
            .text = self.source.text[tok.span.start..tok.span.end],
        };
    }

    fn eatReserved(self: *Parser, reserved: token.ReservedWord) ?token.Token {
        if (!self.atReserved(reserved)) return null;
        defer self.index += 1;
        return self.tokens[self.index];
    }

    fn eatAndOrOperator(self: *Parser) ?ast.AndOrOperator {
        if (self.eat(.ampersand_ampersand) != null) return .and_if;
        if (self.eat(.pipe_pipe) != null) return .or_if;
        return null;
    }

    fn eatRedirectionOperator(self: *Parser) ?token.Token {
        return switch (self.tokens[self.index].kind) {
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
            => self.eat(self.tokens[self.index].kind).?,
            else => null,
        };
    }

    fn mode(self: Parser) state_mod.Mode {
        return if (self.alias_state) |shell_state| shell_state.options.mode else .bash;
    }

    /// Attaches lexer-produced body tokens to the pending here-document
    /// redirections, in operator order, and parses each unquoted body into
    /// word parts for evaluation-time expansion.
    fn parsePendingHereDocs(self: *Parser) ParserError!void {
        if (self.pending_here_docs.items.len == 0) return;

        for (self.pending_here_docs.items) |pending| {
            const body_token = self.eatHereDocBody() orelse return error.IncompleteHereDoc;
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            if (body_token.kind == .here_doc_body_unterminated and self.require_complete_here_docs) return error.IncompleteHereDoc;
            pending.redirection.here_doc = .{
                .body = body_token.text,
                .delimiter_quoted = body_token.quoted,
                .parts = if (body_token.quoted) &.{} else try self.parseHereDocParts(body_token),
            };
        }
        self.pending_here_docs.clearRetainingCapacity();
    }

    fn eatHereDocBody(self: *Parser) ?token.Token {
        if (self.eat(.here_doc_body)) |tok| return tok;
        return self.eat(.here_doc_body_unterminated);
    }

    /// Parses an unquoted here-document body into word parts. POSIX 2.7.4
    /// gives the body double-quote semantics except that the double-quote
    /// character is not special and backslash only escapes '$', '`', '\',
    /// and <newline>. Malformed expansions keep the body literal, matching
    /// the previous evaluation-time leniency.
    fn parseHereDocParts(self: *Parser, body_token: token.Token) ParserError![]const ast.WordPart {
        var parts: std.ArrayList(ast.WordPart) = .empty;
        errdefer parts.deinit(self.allocator);
        self.appendWordParts(&parts, body_token.text, 0, body_token.text.len, .here_doc, body_token.span) catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    parts.clearRetainingCapacity();
                    try parts.append(self.allocator, .{ .literal = body_token.text });
                },
            };
        return parts.toOwnedSlice(self.allocator);
    }

    fn at(self: Parser, kind: token.Kind) bool {
        std.debug.assert(self.index < self.tokens.len);
        return self.tokens[self.index].kind == kind;
    }

    fn atReserved(self: Parser, reserved: token.ReservedWord) bool {
        return self.tokens[self.index].reserved == reserved;
    }

    fn atListEnd(self: Parser, end_kind: ListEnd) bool {
        if (self.at(.eof)) return true;
        return switch (end_kind) {
            .eof => false,
            .right_brace => self.at(.right_brace),
            .right_paren => self.at(.right_paren),
            .esac => self.atReserved(.esac_kw),
            .do => self.atReserved(.do_kw),
            .done => self.atReserved(.done_kw),
            .then => self.atReserved(.then_kw),
            .if_branch => self.atReserved(.elif_kw) or self.atReserved(.else_kw) or self.atReserved(.fi_kw),
            .fi => self.atReserved(.fi_kw),
            .case_item => self.at(.double_semicolon) or
                self.at(.semicolon_ampersand) or
                self.at(.double_semicolon_ampersand) or
                self.atReserved(.esac_kw),
        };
    }
};

fn parseIoNumber(text: []const u8) !u31 {
    return std.fmt.parseInt(u31, text, 10) catch error.UnexpectedToken;
}

const CForSections = struct {
    init: []const u8,
    condition: []const u8,
    update: []const u8,
};

fn cForSections(text: []const u8) ParseError!CForSections {
    const first = parse_scan.topLevelArithmeticSemicolon(text, 0) orelse return error.UnexpectedToken;
    const second = parse_scan.topLevelArithmeticSemicolon(text, first + 1) orelse return error.UnexpectedToken;
    if (parse_scan.topLevelArithmeticSemicolon(text, second + 1) != null) return error.UnexpectedToken;
    return .{
        .init = text[0..first],
        .condition = text[first + 1 .. second],
        .update = text[second + 1 ..],
    };
}

fn emptyArithmeticSectionAsNull(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return if (trimmed.len == 0) null else text;
}

fn redirectionOperator(kind: token.Kind) ast.RedirectionOperator {
    return switch (kind) {
        .less => .input,
        .less_less => .here_doc,
        .less_less_dash => .here_doc_strip_tabs,
        .less_less_less => .here_string,
        .less_ampersand => .duplicate_input,
        .less_greater => .read_write,
        .greater => .output,
        .greater_greater => .append,
        .greater_ampersand => .duplicate_output,
        .ampersand_greater => .output_and_error,
        .ampersand_greater_greater => .append_and_error,
        .clobber => .clobber,
        else => unreachable,
    };
}

fn redirectionOperatorIsBashOnly(kind: token.Kind) bool {
    return switch (kind) {
        .less_less_less, .ampersand_greater, .ampersand_greater_greater => true,
        else => false,
    };
}

fn pipeAndRedirection(span: source_mod.Span) ast.Redirection {
    const target: ast.Word = .{ .data = .{ .literal = "1" }, .span = span };
    const redirection: ast.Redirection = .{
        .fd = 2,
        .op = .duplicate_output,
        .target = target,
        .span = span,
    };
    redirection.validate();
    return redirection;
}

fn appendRedirection(
    allocator: std.mem.Allocator,
    redirections: []const ast.Redirection,
    redirection: ast.Redirection,
) ![]const ast.Redirection {
    const expanded = try allocator.alloc(ast.Redirection, redirections.len + 1);
    @memcpy(expanded[0..redirections.len], redirections);
    expanded[redirections.len] = redirection;
    return expanded;
}

fn extendCommandSpan(existing: ?source_mod.Span, span: source_mod.Span) source_mod.Span {
    return if (existing) |current| .{
        .source_id = current.source_id,
        .start = current.start,
        .end = span.end,
        .start_line = current.start_line,
        .start_column = current.start_column,
    } else span;
}

fn spanTo(start: source_mod.Span, end: usize) source_mod.Span {
    std.debug.assert(end >= start.start);
    return .{
        .source_id = start.source_id,
        .start = start.start,
        .end = end,
        .start_line = start.start_line,
        .start_column = start.start_column,
    };
}

fn isAssignmentName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!isNameStart(name[0])) return false;
    for (name[1..]) |byte| if (!isNameContinue(byte)) return false;
    return true;
}

fn isFunctionName(name: []const u8, mode: state_mod.Mode) bool {
    if (isAssignmentName(name)) return true;
    if (mode == .posix or name.len == 0 or !isNameStart(name[0])) return false;
    for (name[1..]) |byte| if (!isNameContinue(byte) and byte != '.') return false;
    return true;
}

fn arrayAssignmentIndex(text: []const u8) ?usize {
    const open_index = std.mem.indexOfScalar(u8, text, '[') orelse return null;
    if (open_index == 0 or text[text.len - 1] != ']') return null;
    if (std.mem.indexOfScalar(u8, text[open_index + 1 .. text.len - 1], '[') != null) return null;
    return open_index;
}

fn isParameterOperator(byte: u8) bool {
    return byte == '-' or byte == '=' or byte == '+' or byte == '?';
}

fn parameterOperator(byte: u8) ast.ParameterOperator {
    return switch (byte) {
        '-' => .default_value,
        '=' => .assign_default,
        '+' => .alternate_value,
        '?' => .error_if_unset,
        else => unreachable,
    };
}

fn stripLeadingTabs(line: []const u8) []const u8 {
    var index: usize = 0;
    while (index < line.len and line[index] == '\t') index += 1;
    return line[index..];
}

fn scanParameterName(text: []const u8, start: usize, end: usize) usize {
    if (start >= end or !isNameStart(text[start])) return start;
    var index = start + 1;
    while (index < end and isNameContinue(text[index])) index += 1;
    return index;
}

fn parseBracedSimpleParameter(content: []const u8) ?ast.Parameter {
    if (content.len == 0) return null;
    if (parseSpecialParameter(content[0])) |special| {
        if (content.len == 1) return .{ .special = special };
        return null;
    }
    if (!std.ascii.isDigit(content[0])) return null;
    for (content) |byte| if (!std.ascii.isDigit(byte)) return null;
    return .{ .positional = std.fmt.parseInt(u32, content, 10) catch return null };
}

const BracedParameterPrefix = struct {
    parameter: ast.Parameter,
    end: usize,
};

fn parseBracedParameterPrefix(content: []const u8) ?BracedParameterPrefix {
    if (content.len == 0) return null;
    if (parseSpecialParameter(content[0])) |special| return .{ .parameter = .{ .special = special }, .end = 1 };
    if (std.ascii.isDigit(content[0])) {
        var end: usize = 1;
        while (end < content.len and std.ascii.isDigit(content[end])) end += 1;
        return .{
            .parameter = .{ .positional = std.fmt.parseInt(u32, content[0..end], 10) catch return null },
            .end = end,
        };
    }
    const end = scanParameterName(content, 0, content.len);
    if (end == 0) return null;
    return .{ .parameter = .{ .variable = content[0..end] }, .end = end };
}

fn parseSingleParameter(byte: u8) ?ast.Parameter {
    if (parseSpecialParameter(byte)) |special| return .{ .special = special };
    if (std.ascii.isDigit(byte)) return .{ .positional = byte - '0' };
    return null;
}

fn parseSpecialParameter(byte: u8) ?ast.SpecialParameter {
    return switch (byte) {
        '@' => .at,
        '*' => .star,
        '#' => .hash,
        '?' => .question,
        '-' => .hyphen,
        '$' => .dollar,
        '!' => .bang,
        else => null,
    };
}

fn appendHexEscape(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) !usize {
    var value: u16 = 0;
    var consumed: usize = 0;
    while (consumed < text.len and consumed < 2) : (consumed += 1) {
        const digit = std.fmt.charToDigit(text[consumed], 16) catch break;
        value = value * 16 + digit;
    }
    if (consumed == 0) return 0;
    try output.append(allocator, @truncate(value));
    return consumed;
}

fn appendOctalEscape(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) !usize {
    var value: u16 = 0;
    var consumed: usize = 0;
    while (consumed < text.len and consumed < 3) : (consumed += 1) {
        const digit = std.fmt.charToDigit(text[consumed], 8) catch break;
        value = value * 8 + digit;
    }
    std.debug.assert(consumed != 0);
    try output.append(allocator, @truncate(value));
    return consumed;
}

fn doubleQuoteEscapes(byte: u8) bool {
    return switch (byte) {
        '$', '`', '"', '\\', '\n' => true,
        else => false,
    };
}

fn hereDocEscapes(byte: u8) bool {
    return switch (byte) {
        '$', '`', '\\', '\n' => true,
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
    return isNameStart(byte) or switch (byte) {
        '0'...'9' => true,
        else => false,
    };
}

test "parser builds simple colon command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = ":" };
    // ziglint-ignore: Z028 inline import kept local to test/helper; avoid non-semantic refactor
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);

    try std.testing.expectEqual(@as(usize, 1), program.body.entries.len);
}

test "parser builds AND-OR lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "true && ! false || false" };
    // ziglint-ignore: Z028 inline import kept local to test/helper; avoid non-semantic refactor
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);

    const and_or = program.body.entries[0].and_or;
    try std.testing.expectEqual(@as(usize, 3), and_or.pipelines.len);
    try std.testing.expectEqual(@as(?ast.AndOrOperator, null), and_or.pipelines[0].operator);
    try std.testing.expectEqual(ast.AndOrOperator.and_if, and_or.pipelines[1].operator.?);
    try std.testing.expect(and_or.pipelines[1].pipeline.negated);
    try std.testing.expectEqual(ast.AndOrOperator.or_if, and_or.pipelines[2].operator.?);
}

test "parser builds pipeline stages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf x | cat" };
    // ziglint-ignore: Z028 inline import kept local to test/helper; avoid non-semantic refactor
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const pipeline = program.body.entries[0].and_or.pipelines[0].pipeline;

    try std.testing.expectEqual(@as(usize, 2), pipeline.stages.len);
    try std.testing.expectEqualStrings("printf", pipeline.stages[0].simple.words[0].data.literal);
    try std.testing.expectEqualStrings("cat", pipeline.stages[1].simple.words[0].data.literal);
}

test "parser splits single quoted word parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf '%s\\n' hello" };
    // ziglint-ignore: Z028 inline import kept local to test/helper; avoid non-semantic refactor
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const words = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.words;

    try std.testing.expectEqual(@as(usize, 3), words.len);
    try std.testing.expectEqualStrings("printf", words[0].data.literal);
    try std.testing.expectEqualStrings("%s\\n", words[1].data.parts[0].single_quoted);
    try std.testing.expectEqualStrings("hello", words[2].data.literal);
}

test "parser removes unquoted backslash escapes from word text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf \\'3 a\\ b" };
    // ziglint-ignore: Z028 inline import kept local to test/helper; avoid non-semantic refactor
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const words = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.words;

    try std.testing.expectEqual(@as(usize, 3), words.len);
    try std.testing.expectEqualStrings("'", words[1].data.parts[0].escaped);
    try std.testing.expectEqualStrings("3", words[1].data.parts[1].literal);
    try std.testing.expectEqualStrings("a", words[2].data.parts[0].literal);
    try std.testing.expectEqualStrings(" ", words[2].data.parts[1].escaped);
    try std.testing.expectEqualStrings("b", words[2].data.parts[2].literal);
}

test "parser preserves non-escaper backslashes inside double quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "-c",
        .text = "printf \"a\\ b\" \"ok\\n\"",
    };
    // ziglint-ignore: Z028 inline import kept local to test/helper; avoid non-semantic refactor
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const words = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.words;

    try std.testing.expectEqualStrings("a\\ b", words[1].data.parts[0].double_quoted[0].literal);
    try std.testing.expectEqualStrings("ok\\n", words[2].data.parts[0].double_quoted[0].literal);
}

test "parser decodes dollar single quoted words as quoted literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf $'a\\nb' $'\\101' $'$x'" };
    // ziglint-ignore: Z028 inline import kept local to test/helper; avoid non-semantic refactor
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const words = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.words;

    try std.testing.expectEqualStrings("a\nb", words[1].data.parts[0].single_quoted);
    try std.testing.expectEqualStrings("A", words[2].data.parts[0].single_quoted);
    try std.testing.expectEqualStrings("$x", words[3].data.parts[0].single_quoted);
}

test "parser recognizes leading assignment words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "x=hello printf x=arg" };
    // ziglint-ignore: Z028 inline import kept local to test/helper; avoid non-semantic refactor
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const command = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple;

    try std.testing.expectEqual(@as(usize, 1), command.assignments.len);
    try std.testing.expectEqualStrings("x", command.assignments[0].name);
    try std.testing.expectEqualStrings("hello", command.assignments[0].value.data.literal);
    try std.testing.expectEqual(@as(usize, 2), command.words.len);
    try std.testing.expectEqualStrings("x=arg", command.words[1].data.literal);
}

test "parser recognizes bash redirection shorthand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "a &>out |& b" };
    // ziglint-ignore: Z028 inline import kept local to test/helper; avoid non-semantic refactor
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const pipeline = program.body.entries[0].and_or.pipelines[0].pipeline;

    try std.testing.expectEqual(@as(usize, 2), pipeline.stages.len);
    const left = pipeline.stages[0].simple;
    try std.testing.expectEqual(@as(usize, 2), left.redirections.len);
    try std.testing.expectEqual(ast.RedirectionOperator.output_and_error, left.redirections[0].op);
    try std.testing.expectEqual(ast.RedirectionOperator.duplicate_output, left.redirections[1].op);
    try std.testing.expectEqual(@as(?u31, 2), left.redirections[1].fd);
    try std.testing.expectEqualStrings("1", left.redirections[1].target.data.literal);
}

test "parser recognizes bash append assignment words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "-c",
        .text = "x+=hello printf x+=arg",
    };
    // ziglint-ignore: Z028 inline import kept local to test/helper; avoid non-semantic refactor
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const command = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple;

    try std.testing.expectEqual(@as(usize, 1), command.assignments.len);
    try std.testing.expectEqualStrings("x", command.assignments[0].name);
    try std.testing.expect(command.assignments[0].append);
    try std.testing.expectEqualStrings("hello", command.assignments[0].value.data.literal);
    try std.testing.expectEqual(@as(usize, 2), command.words.len);
    try std.testing.expectEqualStrings("x+=arg", command.words[1].data.literal);
}

test "parser rejects append assignment words in POSIX mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "x+=hello" };
    // ziglint-ignore: Z028 inline import kept local to test/helper; avoid non-semantic refactor
    const tokens = try @import("lexer.zig").lex(allocator, src);
    var shell_state = state_mod.State.init(std.testing.allocator, .{ .mode = .posix });
    defer shell_state.deinit();

    try std.testing.expectError(error.UnexpectedToken, parseWithAliases(allocator, src, tokens, shell_state));
}

test "parser builds parameter parts inside double quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf \"$x\"" };
    // ziglint-ignore: Z028 inline import kept local to test/helper; avoid non-semantic refactor
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const word = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.words[1];

    const quoted_parts = word.data.parts[0].double_quoted;
    try std.testing.expectEqualStrings("x", quoted_parts[0].parameter.parameter.variable);
}

test "parser builds command substitution word parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "x=$(exit 7)" };
    // ziglint-ignore: Z028 inline import kept local to test/helper; avoid non-semantic refactor
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const assignment = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.assignments[0];

    try std.testing.expectEqualStrings("x", assignment.name);
    const substitution = assignment.value.data.parts[0].command_substitution;
    try std.testing.expectEqualStrings("exit 7", substitution.source_text);
    try std.testing.expect(substitution.parsed != null);
}

test "incremental parser yields one complete command per call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var shell_state = state_mod.State.init(std.testing.allocator, .{});
    defer shell_state.deinit();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .script_file,
        .name = "test",
        .text = "echo one; echo two\nif true\nthen echo three\nfi\necho four\n",
    };
    const tokens = try lexer.lex(allocator, src);
    var incremental: Incremental = .init(allocator, src, tokens, shell_state);

    const first = (try incremental.next()).?;
    try std.testing.expectEqual(@as(usize, 2), first.body.entries.len);
    try std.testing.expectEqual(std.mem.indexOf(u8, src.text, "if").?, incremental.nextOffset());

    const second = (try incremental.next()).?;
    try std.testing.expectEqual(@as(usize, 1), second.body.entries.len);
    try std.testing.expectEqual(std.mem.indexOf(u8, src.text, "echo four").?, incremental.nextOffset());

    const third = (try incremental.next()).?;
    try std.testing.expectEqual(@as(usize, 1), third.body.entries.len);
    try std.testing.expectEqual(src.text.len, incremental.nextOffset());

    try std.testing.expectEqual(@as(?ast.Program, null), try incremental.next());
}

test "parsers reject adjacent commands without a list separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var shell_state = state_mod.State.init(std.testing.allocator, .{});
    defer shell_state.deinit();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "-c",
        .text = "printf bad (printf nope)",
    };
    const tokens = try lexer.lex(allocator, src);

    try std.testing.expectError(error.UnexpectedToken, parse(allocator, src, tokens));

    var incremental: Incremental = .init(allocator, src, tokens, shell_state);
    try std.testing.expectError(error.UnexpectedToken, incremental.next());
}

test "incremental parser consumes here-document bodies within command boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var shell_state = state_mod.State.init(std.testing.allocator, .{});
    defer shell_state.deinit();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .script_file,
        .name = "test",
        .text = "cat <<E\nbody\nE\necho after\n",
    };
    const tokens = try lexer.lex(allocator, src);
    var incremental: Incremental = .init(allocator, src, tokens, shell_state);

    const first = (try incremental.next()).?;
    const redirection = first.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.redirections[0];
    try std.testing.expectEqualStrings("body\n", redirection.here_doc.?.body);
    try std.testing.expectEqual(std.mem.indexOf(u8, src.text, "echo after").?, incremental.nextOffset());

    const second = (try incremental.next()).?;
    try std.testing.expectEqual(@as(usize, 1), second.body.entries.len);
    try std.testing.expectEqual(@as(?ast.Program, null), try incremental.next());
}

test "parser accepts here-document delimited by end of input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "cat <<E" };
    const tokens = try lexer.lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const redirection = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.redirections[0];

    try std.testing.expectEqualStrings("", redirection.here_doc.?.body);
}

test "here-document bodies parse into word parts with here-doc quoting rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .script_file,
        .name = "test",
        .text = "cat <<E\n$X \"q\" \\$Y \\a\nE\n",
    };
    const tokens = try lexer.lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const here_doc = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.redirections[0].here_doc.?;

    try std.testing.expect(!here_doc.delimiter_quoted);
    try std.testing.expectEqualStrings("$X \"q\" \\$Y \\a\n", here_doc.body);
    try std.testing.expectEqualStrings("X", here_doc.parts[0].parameter.parameter.variable);
    // The double-quote character is not special inside a here-document.
    try std.testing.expectEqualStrings(" \"q\" ", here_doc.parts[1].literal);
    // Backslash escapes '$' but stays literal before other characters.
    try std.testing.expectEqualStrings("$", here_doc.parts[2].escaped);
    try std.testing.expectEqualStrings("Y \\a\n", here_doc.parts[3].literal);
}

test "quoted here-document delimiters keep the body literal with no parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .script_file,
        .name = "test",
        .text = "cat <<'E'\n$X `cmd`\nE\n",
    };
    const tokens = try lexer.lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const here_doc = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.redirections[0].here_doc.?;

    try std.testing.expect(here_doc.delimiter_quoted);
    try std.testing.expectEqualStrings("$X `cmd`\n", here_doc.body);
    try std.testing.expectEqual(@as(usize, 0), here_doc.parts.len);
}

test "incremental parser records failure locations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var shell_state = state_mod.State.init(std.testing.allocator, .{});
    defer shell_state.deinit();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .script_file,
        .name = "test",
        .text = "echo ok\n)\n",
    };
    const tokens = try lexer.lex(allocator, src);
    var incremental: Incremental = .init(allocator, src, tokens, shell_state);

    _ = (try incremental.next()).?;
    try std.testing.expectError(error.ExpectedCommand, incremental.next());
    const parse_failure = incremental.failure().?;
    try std.testing.expectEqual(@as(usize, 2), parse_failure.line);
    try std.testing.expectEqualStrings(")", parse_failure.near.?);
}

test "whole-program parse reports failure at end of input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var shell_state = state_mod.State.init(std.testing.allocator, .{});
    defer shell_state.deinit();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .script_file,
        .name = "test",
        .text = "if true\nthen echo x\n",
    };
    const tokens = try lexer.lex(allocator, src);
    var parse_failure: ?Failure = null;
    const parsed = parseWithAliasesAndOptions(allocator, src, tokens, shell_state, .{ .failure = &parse_failure });

    try std.testing.expectError(error.UnexpectedToken, parsed);
    try std.testing.expectEqual(@as(usize, 3), parse_failure.?.line);
    try std.testing.expectEqual(@as(?[]const u8, null), parse_failure.?.near);
}

test "parameter-only parser skips other substitution forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const text = "'$USER':${MISSING:-$USER}:$(printf '$USER'):`printf '$USER'`:$((1 + $USER)):$'$USER'";
    const expansions = try parseParameterExpansionText(arena.allocator(), text);

    try std.testing.expectEqual(@as(usize, 2), expansions.len);
    try std.testing.expectEqualStrings("$USER", text[expansions[0].span.start..expansions[0].span.end]);
    try std.testing.expectEqualStrings("USER", expansions[0].parameter.variable);
    try std.testing.expectEqualStrings(
        "${MISSING:-$USER}",
        text[expansions[1].span.start..expansions[1].span.end],
    );
    try std.testing.expectEqualStrings("MISSING", expansions[1].parameter.variable);
}

test "parser preserves balanced scanner error tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.UnclosedCommandSubstitution,
        parseWordExpansionText(arena.allocator(), "$(echo", .{}),
    );
    try std.testing.expectError(error.UnclosedQuote, parseWordExpansionText(arena.allocator(), "\"value", .{}));
}
