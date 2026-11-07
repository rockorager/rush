//! Literal shell-word analysis and safe word spelling.
//!
//! Completion uses the real lexer and word parser to derive semantic values
//! from partially typed literal words. Quote and escape syntax is discarded
//! only for matching and lookup; insertion may restore and close a simple
//! leading open quote. Dynamic expansions are deliberately rejected because
//! their values are unavailable until evaluation.

const std = @import("std");

const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const source = @import("source.zig");

/// A shell word whose value is fully determined by its literal and quoted
/// parts. `value` is allocator-owned.
pub const LiteralWord = struct {
    value: []const u8,
    /// Whether the supported leading `~` or `~/` spelling is unquoted and may
    /// be expanded during filesystem lookup and later shell evaluation.
    expands_leading_tilde: bool,
    /// A pending quote style that can be restored when spelling a completion.
    /// Only a quote beginning the word is preserved; mixed quoting deliberately
    /// falls back to canonical escaping.
    open_quote: ?QuoteStyle,

    pub fn deinit(self: LiteralWord, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

/// Derives the semantic value of a possibly incomplete literal shell word.
/// Pending single, double, and dollar-single quotes are closed only in temporary
/// parser input and recorded in `open_quote` for later insertion. Returns null
/// when evaluation would be required or the input is not one literal word.
pub fn parseLiteralWord(
    allocator: std.mem.Allocator,
    raw: []const u8,
) error{OutOfMemory}!?LiteralWord {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const pending_quote = try findPendingQuote(arena_allocator, raw);
    const parse_text = try closePendingQuoteForParsing(arena_allocator, raw, pending_quote);
    const word = parser.parseWordExpansionText(arena_allocator, parse_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };

    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(allocator);
    if (!try appendLiteralWord(allocator, &value, word)) {
        value.deinit(allocator);
        return null;
    }
    if (std.mem.indexOfScalar(u8, value.items, 0) != null) {
        value.deinit(allocator);
        return null;
    }
    return .{
        .value = try value.toOwnedSlice(allocator),
        .expands_leading_tilde = expandsLeadingTilde(raw),
        .open_quote = if (pending_quote) |pending|
            if (pending.start == 0) pending.style else null
        else
            null,
    };
}

pub const QuoteStyle = enum {
    single,
    double,
    dollar_single,
};

const PendingQuote = struct {
    start: usize,
    delimiter: u8,
    style: QuoteStyle,
};

fn findPendingQuote(allocator: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!?PendingQuote {
    const src: source.Source = .{ .id = 0, .kind = .interactive, .name = "literal word", .text = raw };
    var trivia: std.ArrayList(lexer.Trivia) = .empty;
    defer trivia.deinit(allocator);
    _ = try lexer.lexWithTrivia(allocator, src, &trivia);

    for (trivia.items) |item| {
        if (item.kind != .pending_quote or item.end != raw.len or item.start >= item.end) continue;
        const opener = raw[item.start];
        if (opener == '$') {
            std.debug.assert(item.start + 1 < raw.len);
            std.debug.assert(raw[item.start + 1] == '\'');
            return .{ .start = item.start, .delimiter = '\'', .style = .dollar_single };
        }
        std.debug.assert(opener == '\'' or opener == '"');
        return .{
            .start = item.start,
            .delimiter = opener,
            .style = if (opener == '\'') .single else .double,
        };
    }
    return null;
}

fn closePendingQuoteForParsing(
    allocator: std.mem.Allocator,
    raw: []const u8,
    pending_quote: ?PendingQuote,
) error{OutOfMemory}![]const u8 {
    const pending = pending_quote orelse return raw;
    return allocator.print("{s}{c}", .{ raw, pending.delimiter });
}

fn appendLiteralWord(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    word: ast.Word,
) error{OutOfMemory}!bool {
    return switch (word.data) {
        .literal => |literal| appendLiteralBytes(allocator, output, literal),
        .parts => |parts| appendLiteralParts(allocator, output, parts),
        .declaration_array_assignment => false,
    };
}

fn appendLiteralParts(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    parts: []const ast.WordPart,
) error{OutOfMemory}!bool {
    for (parts) |part| switch (part) {
        .literal, .escaped, .single_quoted => |literal| {
            try output.appendSlice(allocator, literal);
        },
        .double_quoted => |quoted| if (!try appendLiteralParts(allocator, output, quoted)) return false,
        .parameter, .command_substitution, .process_substitution, .arithmetic => return false,
    };
    return true;
}

fn appendLiteralBytes(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    literal: []const u8,
) error{OutOfMemory}!bool {
    try output.appendSlice(allocator, literal);
    return true;
}

fn expandsLeadingTilde(raw: []const u8) bool {
    return raw.len != 0 and raw[0] == '~' and (raw.len == 1 or raw[1] == '/');
}

pub const EscapeOptions = struct {
    /// Preserve a supported leading `~` or `~/` so later shell evaluation
    /// performs the same expansion used for completion lookup.
    preserve_leading_tilde: bool = false,
};

/// True when `text` cannot be inserted verbatim as one literal shell word.
pub fn needsEscaping(text: []const u8, options: EscapeOptions) bool {
    if (text.len == 0) return true;
    const tilde_prefix_len = preservedTildePrefixLength(text, options);
    var index: usize = 0;
    while (index < text.len) {
        if (utf8SequenceLengthAt(text, index)) |sequence_len| {
            index += sequence_len;
            continue;
        }
        const byte = text[index];
        const leading_special = index == 0 and
            ((byte == '~' and tilde_prefix_len == 0) or byte == '#');
        if (leading_special or !isSafeUnquotedByte(byte)) return true;
        index += 1;
    }
    return false;
}

/// Returns an allocator-owned safe spelling of `text`. Newlines use single
/// quotes because an unquoted backslash-newline pair would disappear. When
/// requested, a leading tilde prefix remains outside any generated quotes.
pub fn escape(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: EscapeOptions,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(std.mem.indexOfScalar(u8, text, 0) == null);
    if (!needsEscaping(text, options)) return allocator.dupe(u8, text);
    if (text.len == 0) return allocator.dupe(u8, "''");

    const tilde_prefix_len = preservedTildePrefixLength(text, options);
    if (std.mem.indexOfScalar(u8, text, '\n') != null) {
        const quoted = try singleQuote(allocator, text[tilde_prefix_len..]);
        defer allocator.free(quoted);
        return std.mem.concat(allocator, u8, &.{ text[0..tilde_prefix_len], quoted });
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        if (utf8SequenceLengthAt(text, index)) |sequence_len| {
            try output.appendSlice(allocator, text[index .. index + sequence_len]);
            index += sequence_len;
            continue;
        }
        const byte = text[index];
        const leading_special = index == 0 and
            ((byte == '~' and tilde_prefix_len == 0) or byte == '#');
        if (leading_special or !isSafeUnquotedByte(byte)) try output.append(allocator, '\\');
        try output.append(allocator, byte);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

/// Returns an escaped allocator-owned spelling only when `text` cannot be
/// inserted verbatim.
pub fn escapeIfNeeded(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: EscapeOptions,
) error{OutOfMemory}!?[]const u8 {
    if (!needsEscaping(text, options)) return null;
    return try escape(allocator, text, options);
}

/// Returns an allocator-owned single-quoted spelling of `text`.
pub fn singleQuote(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    return singleQuoteWithClosure(allocator, text, true);
}

fn singleQuoteWithClosure(
    allocator: std.mem.Allocator,
    text: []const u8,
    close: bool,
) error{OutOfMemory}![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '\'');
    for (text) |byte| {
        if (byte == '\'') {
            try output.appendSlice(allocator, "'\\''");
        } else {
            try output.append(allocator, byte);
        }
    }
    if (close) try output.append(allocator, '\'');
    return output.toOwnedSlice(allocator);
}

/// Returns an allocator-owned double-quoted spelling of `text`.
pub fn doubleQuote(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    return doubleQuoteWithClosure(allocator, text, true);
}

fn doubleQuoteWithClosure(
    allocator: std.mem.Allocator,
    text: []const u8,
    close: bool,
) error{OutOfMemory}![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '"');
    for (text) |byte| {
        switch (byte) {
            '$', '`', '"', '\\' => {
                try output.append(allocator, '\\');
                try output.append(allocator, byte);
            },
            else => try output.append(allocator, byte),
        }
    }
    if (close) try output.append(allocator, '"');
    return output.toOwnedSlice(allocator);
}

/// Returns an allocator-owned dollar-single-quoted spelling of `text`.
pub fn dollarSingleQuote(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    return dollarSingleQuoteWithClosure(allocator, text, true);
}

fn dollarSingleQuoteWithClosure(
    allocator: std.mem.Allocator,
    text: []const u8,
    close: bool,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(std.mem.indexOfScalar(u8, text, 0) == null);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "$'");
    for (text) |byte| switch (byte) {
        '\'' => try output.appendSlice(allocator, "\\'"),
        '\\' => try output.appendSlice(allocator, "\\\\"),
        '\n' => try output.appendSlice(allocator, "\\n"),
        '\r' => try output.appendSlice(allocator, "\\r"),
        '\t' => try output.appendSlice(allocator, "\\t"),
        0x07 => try output.appendSlice(allocator, "\\a"),
        0x08 => try output.appendSlice(allocator, "\\b"),
        0x0b => try output.appendSlice(allocator, "\\v"),
        0x0c => try output.appendSlice(allocator, "\\f"),
        0x1b => try output.appendSlice(allocator, "\\e"),
        0x01...0x06, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {
            const hex = "0123456789ABCDEF";
            try output.appendSlice(allocator, "\\x");
            try output.append(allocator, hex[byte >> 4]);
            try output.append(allocator, hex[byte & 0x0f]);
        },
        else => try output.append(allocator, byte),
    };
    if (close) try output.append(allocator, '\'');
    return output.toOwnedSlice(allocator);
}

pub const QuoteOptions = struct {
    /// Close the generated quote. Leave false only when more literal pathname
    /// segments will be appended to the same shell word.
    close: bool = true,
};

/// Returns an allocator-owned quoted spelling using `style` and `options`.
pub fn quote(
    allocator: std.mem.Allocator,
    text: []const u8,
    style: QuoteStyle,
    options: QuoteOptions,
) error{OutOfMemory}![]const u8 {
    return switch (style) {
        .single => singleQuoteWithClosure(allocator, text, options.close),
        .double => doubleQuoteWithClosure(allocator, text, options.close),
        .dollar_single => dollarSingleQuoteWithClosure(allocator, text, options.close),
    };
}

fn preservedTildePrefixLength(text: []const u8, options: EscapeOptions) usize {
    if (!options.preserve_leading_tilde or text.len == 0 or text[0] != '~') return 0;
    if (text.len == 1) return 1;
    return if (text[1] == '/') 2 else 0;
}

fn utf8SequenceLengthAt(text: []const u8, index: usize) ?usize {
    if (text[index] < 0x80) return null;
    const sequence_len: usize = std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
    const end = index + sequence_len;
    if (end > text.len or !std.unicode.utf8ValidateSlice(text[index..end])) return null;
    return sequence_len;
}

fn isSafeUnquotedByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '/', '.', '_', '-', '+', ',', ':', '@', '%', '=', '~', '#' => true,
        else => false,
    };
}

test "literal word parsing derives semantic values from shell spelling" {
    const Case = struct {
        raw: []const u8,
        value: []const u8,
        expands_leading_tilde: bool = false,
        open_quote: ?QuoteStyle = null,
    };
    const cases = [_]Case{
        .{ .raw = "notes.md", .value = "notes.md" },
        .{ .raw = "my\\ file", .value = "my file" },
        .{ .raw = "'my file", .value = "my file", .open_quote = .single },
        .{ .raw = "\"my file", .value = "my file", .open_quote = .double },
        .{ .raw = "$'my\\x20file", .value = "my file", .open_quote = .dollar_single },
        .{ .raw = "~/'my file'", .value = "~/my file", .expands_leading_tilde = true },
        .{ .raw = "\\~/file", .value = "~/file" },
        .{ .raw = "\"~/file", .value = "~/file", .open_quote = .double },
        .{ .raw = "prefix\"open", .value = "prefixopen" },
        .{ .raw = "'closed'", .value = "closed" },
        .{ .raw = "'\\$HOME'/file", .value = "\\$HOME/file" },
    };
    for (cases) |case| {
        const parsed = (try parseLiteralWord(std.testing.allocator, case.raw)).?;
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.value, parsed.value);
        try std.testing.expectEqual(case.expands_leading_tilde, parsed.expands_leading_tilde);
        try std.testing.expectEqual(case.open_quote, parsed.open_quote);
    }
}

test "literal word parsing rejects dynamic expansions" {
    try std.testing.expect((try parseLiteralWord(std.testing.allocator, "$HOME/file")) == null);
    try std.testing.expect((try parseLiteralWord(std.testing.allocator, "\"$HOME/file")) == null);
    try std.testing.expect((try parseLiteralWord(std.testing.allocator, "$(pwd)/file")) == null);
    try std.testing.expect((try parseLiteralWord(std.testing.allocator, "$((1 + 1))/file")) == null);
    try std.testing.expect((try parseLiteralWord(std.testing.allocator, "$'\\0'")) == null);
}

test "escaping produces one literal shell word" {
    const Case = struct {
        value: []const u8,
        options: EscapeOptions = .{},
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .value = "notes.md", .expected = "notes.md" },
        .{ .value = "my file", .expected = "my\\ file" },
        .{ .value = "it's", .expected = "it\\'s" },
        .{ .value = "a$b", .expected = "a\\$b" },
        .{ .value = "a\\b", .expected = "a\\\\b" },
        .{ .value = "tab\tname", .expected = "tab\\\tname" },
        .{ .value = "glob*[x]?", .expected = "glob\\*\\[x\\]\\?" },
        .{ .value = "semi;&|<>()", .expected = "semi\\;\\&\\|\\<\\>\\(\\)" },
        .{ .value = "café.txt", .expected = "café.txt" },
        .{ .value = "bad\xff name", .expected = "bad\\\xff\\ name" },
        .{ .value = "#notes", .expected = "\\#notes" },
        .{ .value = "dir/#notes", .expected = "dir/#notes" },
        .{ .value = "~/my file", .expected = "\\~/my\\ file" },
        .{
            .value = "~/my file",
            .options = .{ .preserve_leading_tilde = true },
            .expected = "~/my\\ file",
        },
        .{ .value = "line\nbreak", .expected = "'line\nbreak'" },
        .{
            .value = "~/line\nbreak",
            .options = .{ .preserve_leading_tilde = true },
            .expected = "~/'line\nbreak'",
        },
        .{ .value = "", .expected = "''" },
    };
    for (cases) |case| {
        const escaped = try escape(std.testing.allocator, case.value, case.options);
        defer std.testing.allocator.free(escaped);
        try std.testing.expectEqualStrings(case.expected, escaped);

        const parsed = (try parseLiteralWord(std.testing.allocator, escaped)).?;
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.value, parsed.value);
    }
}

test "quote styles round trip literal bytes" {
    const Case = struct {
        style: QuoteStyle,
        value: []const u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .style = .single, .value = "it's here", .expected = "'it'\\''s here'" },
        .{ .style = .double, .value = "a$b`c\"d\\e", .expected = "\"a\\$b\\`c\\\"d\\\\e\"" },
        .{
            .style = .dollar_single,
            .value = "line\nquote'\ttail\x01",
            .expected = "$'line\\nquote\\'\\ttail\\x01'",
        },
    };
    for (cases) |case| {
        const quoted = try quote(std.testing.allocator, case.value, case.style, .{});
        defer std.testing.allocator.free(quoted);
        try std.testing.expectEqualStrings(case.expected, quoted);

        const parsed = (try parseLiteralWord(std.testing.allocator, quoted)).?;
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.value, parsed.value);
    }
}

test "open quote styles remain parseable for another path segment" {
    const Case = struct {
        style: QuoteStyle,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .style = .single, .expected = "'my dir/" },
        .{ .style = .double, .expected = "\"my dir/" },
        .{ .style = .dollar_single, .expected = "$'my dir/" },
    };
    for (cases) |case| {
        const quoted = try quote(std.testing.allocator, "my dir/", case.style, .{ .close = false });
        defer std.testing.allocator.free(quoted);
        try std.testing.expectEqualStrings(case.expected, quoted);

        const parsed = (try parseLiteralWord(std.testing.allocator, quoted)).?;
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("my dir/", parsed.value);
        try std.testing.expectEqual(case.style, parsed.open_quote.?);
    }
}
