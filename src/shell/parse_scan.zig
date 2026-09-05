//! Stateless scanners for balanced shell text embedded in parser words.

const std = @import("std");

pub const ScanError = error{
    UnclosedCommandSubstitution,
    UnclosedQuote,
};

pub fn topLevelArithmeticSemicolon(text: []const u8, start: usize) ?usize {
    var index = start;
    var paren_depth: usize = 0;
    while (index < text.len) {
        switch (text[index]) {
            '\'', '"' => |quote| {
                index += 1;
                while (index < text.len) : (index += 1) {
                    if (text[index] == '\\' and index + 1 < text.len) {
                        index += 2;
                        continue;
                    }
                    if (text[index] == quote) {
                        index += 1;
                        break;
                    }
                }
            },
            '\\' => index += if (index + 1 < text.len) 2 else 1,
            '(' => {
                paren_depth += 1;
                index += 1;
            },
            ')' => {
                if (paren_depth != 0) paren_depth -= 1;
                index += 1;
            },
            ';' => {
                if (paren_depth == 0) return index;
                index += 1;
            },
            else => index += 1,
        }
    }
    return null;
}

pub fn topLevelParameterColon(text: []const u8) ?usize {
    return topLevelParameterByte(text, 0, ':');
}

pub fn topLevelParameterSlash(text: []const u8, start: usize) ?usize {
    return topLevelParameterByte(text, start, '/');
}

fn topLevelParameterByte(text: []const u8, start: usize, delimiter: u8) ?usize {
    var index = start;
    var paren_depth: usize = 0;
    while (index < text.len) {
        switch (text[index]) {
            '\'', '"' => |quote| {
                index += 1;
                while (index < text.len and text[index] != quote) {
                    index += if (text[index] == '\\' and index + 1 < text.len) 2 else 1;
                }
                if (index < text.len) index += 1;
            },
            '\\' => index += if (index + 1 < text.len) 2 else 1,
            '$' => if (index + 1 < text.len and text[index + 1] == '{') {
                index = (scanBracedParameterEnd(text, index + 1, text.len) orelse return null) + 1;
            } else if (index + 1 < text.len and text[index + 1] == '(') {
                index = (scanCommandSubstitution(text, index + 1, text.len) catch return null) + 1;
            } else {
                index += 1;
            },
            '(' => {
                paren_depth += 1;
                index += 1;
            },
            ')' => {
                if (paren_depth != 0) paren_depth -= 1;
                index += 1;
            },
            else => |byte| {
                if (paren_depth == 0 and byte == delimiter) return index;
                index += 1;
            },
        }
    }
    return null;
}

pub fn scanDoubleQuoteEnd(text: []const u8, start: usize, end: usize) ScanError!usize {
    var index = start;
    while (index < end) {
        if (text[index] == '"') return index;
        if (text[index] == '\\') {
            index += if (index + 1 < end) 2 else 1;
            continue;
        }
        if (text[index] == '$' and index + 1 < end and text[index + 1] == '(') {
            index = try scanCommandSubstitution(text, index + 1, end);
        } else if (text[index] == '$' and index + 1 < end and text[index + 1] == '{') {
            index = scanBracedParameterEnd(text, index + 1, end) orelse return error.UnclosedQuote;
        } else if (text[index] == '`') {
            index = try scanBackquoteSubstitution(text, index, end);
        }
        index += 1;
    }
    return error.UnclosedQuote;
}

fn scanSingleQuoteEnd(text: []const u8, start: usize, end: usize) ScanError!usize {
    var index = start;
    while (index < end) : (index += 1) {
        if (text[index] == '\'') return index;
    }
    return error.UnclosedQuote;
}

pub fn scanDollarSingleQuoteEnd(text: []const u8, start: usize, end: usize) ScanError!usize {
    var index = start;
    while (index < end) : (index += 1) {
        if (text[index] == '\'') return index;
        if (text[index] == '\\' and index + 1 < end) index += 1;
    }
    return error.UnclosedQuote;
}

pub fn scanBracedParameterEnd(text: []const u8, open_index: usize, end: usize) ?usize {
    std.debug.assert(open_index > 0);
    std.debug.assert(text[open_index] == '{');

    var index = open_index + 1;
    var depth: usize = 1;
    var quote: ?u8 = null;
    while (index < end) {
        const byte = text[index];
        if (quote) |delimiter| {
            if (byte == delimiter) quote = null;
            index += 1;
            continue;
        }
        switch (byte) {
            '\'', '"' => {
                quote = byte;
                index += 1;
            },
            '\\' => index += if (index + 1 < end) 2 else 1,
            '$' => if (index + 1 < end and text[index + 1] == '{') {
                depth += 1;
                index += 2;
            } else if (index + 1 < end and text[index + 1] == '(') {
                index = (scanCommandSubstitution(text, index + 1, end) catch return null) + 1;
            } else {
                index += 1;
            },
            '}' => {
                depth -= 1;
                if (depth == 0) return index;
                index += 1;
            },
            else => index += 1,
        }
    }
    return null;
}

pub fn scanBackquoteSubstitution(text: []const u8, open_index: usize, end: usize) ScanError!usize {
    std.debug.assert(text[open_index] == '`');
    var index = open_index + 1;
    while (index < end) {
        if (text[index] == '\\' and index + 1 < end) {
            index += 2;
            continue;
        }
        if (text[index] == '`') return index;
        index += 1;
    }
    return error.UnclosedCommandSubstitution;
}

pub fn scanArithmeticExpansion(text: []const u8, dollar_index: usize, end: usize) ScanError!usize {
    std.debug.assert(dollar_index + 2 < end);
    std.debug.assert(text[dollar_index] == '$');
    std.debug.assert(text[dollar_index + 1] == '(');
    std.debug.assert(text[dollar_index + 2] == '(');

    var index = dollar_index + 3;
    var paren_depth: usize = 0;
    while (index < end) {
        switch (text[index]) {
            '\'', '"' => |quote| {
                index += 1;
                while (index < end and text[index] != quote) index += 1;
                if (index >= end) return error.UnclosedQuote;
                index += 1;
            },
            '\\' => index += if (index + 1 < end) 2 else 1,
            '(' => {
                paren_depth += 1;
                index += 1;
            },
            ')' => if (paren_depth != 0) {
                paren_depth -= 1;
                index += 1;
            } else if (index + 1 < end and text[index + 1] == ')') {
                return index;
            } else {
                index += 1;
            },
            else => index += 1,
        }
    }
    return error.UnclosedCommandSubstitution;
}

pub fn scanCommandSubstitution(text: []const u8, open_index: usize, end: usize) ScanError!usize {
    std.debug.assert(open_index > 0);
    std.debug.assert(text[open_index] == '(');

    var index = open_index + 1;
    var depth: usize = 1;
    while (index < end) {
        if (startsReservedWordAt(text, index, "case") and startsCommandAt(text, open_index + 1, index)) {
            index = try scanCaseCommandText(text, index, end);
            continue;
        }
        if (text[index] == '#' and commentStartsAt(text, index)) {
            index = skipCommentText(text, index, end);
            continue;
        }
        switch (text[index]) {
            '\'' => index = try scanSingleQuoteEnd(text, index + 1, end),
            '"' => index = try scanDoubleQuoteEnd(text, index + 1, end),
            '\\' => if (index + 1 < end) {
                index += 1;
            },
            '$' => if (index + 1 < end and text[index + 1] == '(') {
                depth += 1;
                index += 1;
            },
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return index;
            },
            else => {},
        }
        index += 1;
    }
    return error.UnclosedCommandSubstitution;
}

fn skipCommentText(text: []const u8, start: usize, end: usize) usize {
    std.debug.assert(start < end);
    std.debug.assert(text[start] == '#');

    var index = start;
    while (index < end and text[index] != '\n') index += 1;
    return index;
}

fn commentStartsAt(text: []const u8, index: usize) bool {
    std.debug.assert(index < text.len);
    if (index == 0) return true;
    return switch (text[index - 1]) {
        ' ', '\t', '\n', '\r', ';', '&', '|', '(', ')' => true,
        else => false,
    };
}

fn scanCaseCommandText(text: []const u8, start: usize, end: usize) ScanError!usize {
    var index = start + "case".len;
    while (index < end) {
        if (text[index] == '#' and commentStartsAt(text, index)) {
            index = skipCommentText(text, index, end);
            continue;
        }
        if (text[index] == '\\') {
            index += if (index + 1 < end) 2 else 1;
            continue;
        }
        if (text[index] == '\'' or text[index] == '"') {
            index = if (text[index] == '\'')
                try scanSingleQuoteEnd(text, index + 1, end)
            else
                try scanDoubleQuoteEnd(text, index + 1, end);
            index += 1;
            continue;
        }
        if (text[index] == '$' and index + 1 < end and text[index + 1] == '(') {
            index = try scanCommandSubstitution(text, index + 1, end);
            index += 1;
            continue;
        }
        if (startsReservedWordAt(text, index, "esac")) {
            index += "esac".len;
            return index;
        }
        index += 1;
    }
    return error.UnclosedCommandSubstitution;
}

pub fn startsReservedWordAt(text: []const u8, index: usize, word: []const u8) bool {
    if (index + word.len > text.len) return false;
    if (!std.mem.eql(u8, text[index..][0..word.len], word)) return false;
    if (index != 0 and !isTokenBoundary(text[index - 1])) return false;
    if (index + word.len < text.len and !isTokenBoundary(text[index + word.len])) return false;
    return true;
}

fn isTokenBoundary(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n', ';', '&', '|', '(', ')' => true,
        else => false,
    };
}

pub fn startsCommandAt(text: []const u8, start: usize, index: usize) bool {
    var cursor = index;
    while (cursor > start and (text[cursor - 1] == ' ' or text[cursor - 1] == '\t' or text[cursor - 1] == '\r')) {
        cursor -= 1;
    }
    if (cursor == start) return true;
    switch (text[cursor - 1]) {
        '\n', ';', '&', '|', '(' => return true,
        else => {},
    }
    const word_end = cursor;
    while (cursor > start and !isTokenBoundary(text[cursor - 1])) cursor -= 1;
    const previous = text[cursor..word_end];
    for ([_][]const u8{ "if", "then", "elif", "else", "while", "until", "do", "!", "{" }) |word| {
        if (std.mem.eql(u8, previous, word)) return startsCommandAt(text, start, cursor);
    }
    return false;
}

test "balanced scanners preserve exact closing offsets" {
    const command = "$(echo $(printf ')') done)tail";
    try std.testing.expectEqual(@as(usize, 25), try scanCommandSubstitution(command, 1, command.len));

    const braced = "${outer:-${inner:-'}'} $(echo })}tail";
    try std.testing.expectEqual(@as(?usize, 32), scanBracedParameterEnd(braced, 1, braced.len));

    const arithmetic = "$((1 + (2 * 3)))tail";
    try std.testing.expectEqual(@as(usize, 14), try scanArithmeticExpansion(arithmetic, 0, arithmetic.len));
}

test "balanced scanners ignore escaped delimiters and comments" {
    const backquote = "`echo \\`still \\` here`tail";
    try std.testing.expectEqual(@as(usize, 21), try scanBackquoteSubstitution(backquote, 0, backquote.len));

    const command = "$(echo start # ) ignored\nprintf done)tail";
    try std.testing.expectEqual(@as(usize, 36), try scanCommandSubstitution(command, 1, command.len));

    const dollar_quote = "escaped\\'quote'end";
    try std.testing.expectEqual(@as(usize, 14), try scanDollarSingleQuoteEnd(dollar_quote, 0, dollar_quote.len));
}

test "balanced scanners handle case text and top-level delimiters" {
    const command = "$(case x in x) echo $(printf ')');; esac)tail";
    try std.testing.expectEqual(@as(usize, 40), try scanCommandSubstitution(command, 1, command.len));

    try std.testing.expectEqual(@as(?usize, 13), topLevelParameterColon("$(printf ':'):$x"));
    try std.testing.expectEqual(@as(?usize, 5), topLevelParameterSlash("(a/b)/c/d", 0));
    try std.testing.expectEqual(@as(?usize, 8), topLevelArithmeticSemicolon("f('a;b'); x", 0));
}

test "command substitution recognizes case only in reserved-word position" {
    const commands = [_][]const u8{
        "$(printf -- --ignore-case MYTAG)tail",
        "$(printf '%s' case)tail",
        "$(printf '%s' x; case x in x) :;; esac)tail",
        "$(\ncase x in x) :;; esac)tail",
    };
    for (commands) |command| {
        try std.testing.expectEqual(command.len - "tail".len - 1, try scanCommandSubstitution(command, 1, command.len));
    }
}

test "command substitution quotes preserve escapes and nested substitutions" {
    const commands = [_][]const u8{
        \\$(printf '%s' "\"x\"")tail
        ,
        \\$(case x in x) printf '%s' "\"x\"";; esac)tail
        ,
        \\$(printf '%s' "$(printf '%s' ")")")tail
        ,
        \\$(case x in x) printf '%s' "$(printf '%s' "esac)")";; esac)tail
        ,
        \\$(printf '%s' '\')tail
        ,
    };
    for (commands) |command| {
        try std.testing.expectEqual(command.len - "tail".len - 1, try scanCommandSubstitution(command, 1, command.len));
    }
}

test "balanced scanners retain incomplete construct errors" {
    try std.testing.expectError(error.UnclosedQuote, scanDoubleQuoteEnd("text", 0, 4));
    try std.testing.expectError(error.UnclosedQuote, scanSingleQuoteEnd("text", 0, 4));
    try std.testing.expectError(error.UnclosedCommandSubstitution, scanBackquoteSubstitution("`text", 0, 5));
    try std.testing.expectError(error.UnclosedCommandSubstitution, scanArithmeticExpansion("$((1 + 2)", 0, 9));
    try std.testing.expectError(error.UnclosedCommandSubstitution, scanCommandSubstitution("$(echo", 1, 6));
    try std.testing.expectEqual(@as(?usize, null), scanBracedParameterEnd("${value", 1, 7));
}

test "balanced scanners respect bounded text regions" {
    const command = "$(echo) suffix";
    try std.testing.expectError(error.UnclosedCommandSubstitution, scanCommandSubstitution(command, 1, 6));

    const braced = "${value} suffix";
    try std.testing.expectEqual(@as(?usize, null), scanBracedParameterEnd(braced, 1, 7));
}
