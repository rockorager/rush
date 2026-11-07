//! Path expansion requests, matches, and shell quoting helpers.

const std = @import("std");

const word_quoting = @import("../shell/word_quoting.zig");

pub const Command = enum {
    list,
    complete,
    expand_all,
};

pub const ReplacementStyle = enum {
    unquoted,
    single_quoted,
    double_quoted,
    backslash_escaped,
};

pub const Request = struct {
    command: Command,
    word: []const u8,
    replace_start: usize,
    replace_end: usize,
    replacement_style: ReplacementStyle = .unquoted,

    pub fn deinit(self: Request, allocator: std.mem.Allocator) void {
        allocator.free(self.word);
    }
};

pub const Matches = struct {
    items: []const []const u8,

    pub fn deinit(self: Matches, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        allocator.free(self.items);
    }
};

pub const ByteRange = struct {
    start: usize,
    end: usize,
};

pub fn currentViBigwordRange(text: []const u8, cursor: usize) ?ByteRange {
    if (text.len == 0) return null;

    const target = @min(cursor, text.len);
    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len and isAsciiWhitespace(text[index])) : (index += 1) {}
        if (index >= text.len) return null;

        const start = index;
        var quote: ?u8 = null;
        var escaped = false;
        while (index < text.len) : (index += 1) {
            const byte = text[index];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (quote) |active| {
                if (active != '\'' and byte == '\\') {
                    escaped = true;
                } else if (byte == active) {
                    quote = null;
                }
                continue;
            }
            switch (byte) {
                '\\' => escaped = true,
                '\'', '"' => quote = byte,
                else => if (isAsciiWhitespace(byte)) break,
            }
        }
        const end = index;
        if (target >= start and target <= end) return .{ .start = start, .end = end };
    }
    return null;
}

pub fn replacementStyle(word: []const u8) ReplacementStyle {
    var has_single_quote = false;
    var has_double_quote = false;
    var has_backslash = false;
    for (word) |byte| switch (byte) {
        '\'' => has_single_quote = true,
        '"' => has_double_quote = true,
        '\\' => has_backslash = true,
        else => {},
    };
    if (has_double_quote and !has_single_quote) return .double_quoted;
    if (has_single_quote) return .single_quoted;
    if (has_backslash) return .backslash_escaped;
    return .unquoted;
}

/// Escalates an unquoted replacement style to backslash escaping when any
/// match would otherwise split into multiple shell words. Styles derived from
/// quoted input keep their existing convention.
pub fn effectiveReplacementStyle(style: ReplacementStyle, matches: []const []const u8) ReplacementStyle {
    if (style != .unquoted) return style;
    for (matches) |match| {
        if (word_quoting.needsEscaping(match, .{})) return .backslash_escaped;
    }
    return .unquoted;
}

fn quoteMatches(allocator: std.mem.Allocator, matches: []const []const u8, style: ReplacementStyle) ![][]const u8 {
    const quoted = try allocator.alloc([]const u8, matches.len);
    errdefer allocator.free(quoted);
    var initialized: usize = 0;
    errdefer for (quoted[0..initialized]) |item| allocator.free(item);

    for (matches, 0..) |match, index| {
        quoted[index] = try shellQuoteMatch(allocator, match, style);
        initialized += 1;
    }
    return quoted;
}

fn shellQuoteMatch(allocator: std.mem.Allocator, text: []const u8, style: ReplacementStyle) ![]const u8 {
    return switch (style) {
        .unquoted => allocator.dupe(u8, text),
        .single_quoted => word_quoting.singleQuote(allocator, text),
        .double_quoted => word_quoting.doubleQuote(allocator, text),
        .backslash_escaped => word_quoting.escape(allocator, text, .{}),
    };
}

pub fn completionReplacement(
    allocator: std.mem.Allocator,
    word: []const u8,
    matches: []const []const u8,
    style: ReplacementStyle,
) ![]const u8 {
    std.debug.assert(matches.len != 0);
    if (matches.len == 1) {
        const match = matches[0];
        const quoted = try shellQuoteMatch(allocator, match, style);
        if (std.mem.endsWith(u8, match, "/")) return quoted;
        defer allocator.free(quoted);
        return allocator.print("{s} ", .{quoted});
    }

    const quoted_matches = try quoteMatches(allocator, matches, style);
    defer {
        for (quoted_matches) |match| allocator.free(match);
        allocator.free(quoted_matches);
    }
    const prefix = commonPrefix(quoted_matches);
    if (prefix.len <= word.len) return allocator.dupe(u8, word);
    return allocator.dupe(u8, prefix);
}

fn commonPrefix(matches: []const []const u8) []const u8 {
    var prefix = matches[0];
    for (matches[1..]) |match| {
        var index: usize = 0;
        const end = @min(prefix.len, match.len);
        while (index < end and prefix[index] == match[index]) index += 1;
        prefix = prefix[0..index];
    }
    return prefix;
}

pub fn allReplacement(allocator: std.mem.Allocator, matches: []const []const u8, style: ReplacementStyle) ![]const u8 {
    var replacement: std.ArrayList(u8) = .empty;
    errdefer replacement.deinit(allocator);
    for (matches, 0..) |match, index| {
        if (index != 0) try replacement.append(allocator, ' ');
        const quoted = try shellQuoteMatch(allocator, match, style);
        defer allocator.free(quoted);
        try replacement.appendSlice(allocator, quoted);
    }
    return replacement.toOwnedSlice(allocator);
}

pub fn listOutput(allocator: std.mem.Allocator, matches: Matches) ![]const u8 {
    if (matches.items.len == 0) return allocator.dupe(u8, "");
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (matches.items, 0..) |match, index| {
        if (index != 0) try output.append(allocator, ' ');
        try output.appendSlice(allocator, match);
    }
    try output.append(allocator, '\n');
    return output.toOwnedSlice(allocator);
}

fn isAsciiWhitespace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

test "effective replacement style escalates only from unquoted" {
    const spacey_matches = [_][]const u8{"rush vi file"};
    const safe_matches = [_][]const u8{"rush-vi-file"};

    try std.testing.expectEqual(
        ReplacementStyle.backslash_escaped,
        effectiveReplacementStyle(.unquoted, &spacey_matches),
    );
    try std.testing.expectEqual(
        ReplacementStyle.unquoted,
        effectiveReplacementStyle(.unquoted, &safe_matches),
    );
    try std.testing.expectEqual(
        ReplacementStyle.single_quoted,
        effectiveReplacementStyle(.single_quoted, &spacey_matches),
    );
}
