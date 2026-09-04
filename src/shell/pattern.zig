//! Pure shell-pattern matching and parameter pattern-search algorithms.

const std = @import("std");
const uucode = @import("uucode");

pub const Pattern = struct {
    text: []const u8,
    special: ?[]const bool = null,

    pub fn slice(pattern: Pattern, start: usize, end: usize) Pattern {
        return .{
            .text = pattern.text[start..end],
            .special = if (pattern.special) |special| special[start..end] else null,
        };
    }

    fn byteIsSpecial(pattern: Pattern, index: usize) bool {
        return pattern.special == null or pattern.special.?[index];
    }
};

pub fn containsMeta(pattern: Pattern) bool {
    var index: usize = 0;
    while (index < pattern.text.len) : (index += utf8SequenceLength(pattern.text[index..])) {
        const byte = pattern.text[index];
        if (!pattern.byteIsSpecial(index)) continue;
        if (byte == '*' or byte == '?') return true;
        if (byte == '[' and bracketExpressionEnd(pattern, index) != null) return true;
    }
    return false;
}

pub fn matches(pattern: Pattern, text: []const u8) bool {
    if (simpleStarMatches(pattern, text)) |result| return result;

    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star_pattern_index: ?usize = null;
    var star_text_index: ?usize = null;

    while (true) {
        if (pattern_index < pattern.text.len and pattern.byteIsSpecial(pattern_index) and
            pattern.text[pattern_index] == '*')
        {
            pattern_index = skipConsecutiveStars(pattern, pattern_index);
            star_pattern_index = pattern_index;
            star_text_index = text_index;
            continue;
        }

        if (pattern_index == pattern.text.len) {
            if (text_index == text.len) return true;
            if (backtrackStar(star_pattern_index, &star_text_index, text)) |next_text| {
                pattern_index = star_pattern_index.?;
                text_index = next_text;
                continue;
            }
            return false;
        }

        if (matchAtom(pattern, pattern_index, text, text_index)) |matched| {
            pattern_index = matched.pattern_index;
            text_index = matched.text_index;
            continue;
        }

        if (backtrackStar(star_pattern_index, &star_text_index, text)) |next_text| {
            pattern_index = star_pattern_index.?;
            text_index = next_text;
            continue;
        }
        return false;
    }
}

pub fn matchesText(pattern: []const u8, text: []const u8) bool {
    return matches(.{ .text = pattern }, text);
}

fn simpleStarMatches(pattern: Pattern, text: []const u8) ?bool {
    var star_start: ?usize = null;
    var star_end: usize = 0;
    var index: usize = 0;
    while (index < pattern.text.len) : (index += 1) {
        if (!pattern.byteIsSpecial(index)) continue;
        switch (pattern.text[index]) {
            '*' => {
                if (star_start != null and index != star_end) return null;
                if (star_start == null) star_start = index;
                star_end = index + 1;
            },
            '?', '[', '\\' => return null,
            else => {},
        }
    }

    const star = star_start orelse return std.mem.eql(u8, pattern.text, text);
    const prefix = pattern.text[0..star];
    const suffix = pattern.text[star_end..];
    return text.len >= prefix.len + suffix.len and
        std.mem.startsWith(u8, text, prefix) and
        std.mem.endsWith(u8, text, suffix);
}

fn skipConsecutiveStars(pattern: Pattern, start: usize) usize {
    std.debug.assert(pattern.byteIsSpecial(start));
    std.debug.assert(pattern.text[start] == '*');
    var index = start + 1;
    while (index < pattern.text.len and pattern.byteIsSpecial(index) and pattern.text[index] == '*') {
        index += 1;
    }
    return index;
}

fn backtrackStar(star_pattern_index: ?usize, star_text_index: *?usize, text: []const u8) ?usize {
    _ = star_pattern_index orelse return null;
    const previous_text = star_text_index.*.?;
    if (previous_text == text.len) return null;
    const next_text = previous_text + utf8SequenceLength(text[previous_text..]);
    star_text_index.* = next_text;
    return next_text;
}

const AtomMatch = struct {
    pattern_index: usize,
    text_index: usize,
};

fn matchAtom(pattern: Pattern, pattern_index: usize, text: []const u8, text_index: usize) ?AtomMatch {
    // ziglint-ignore: Z024 preserve existing readable expression shape; behavior-neutral extraction
    if (pattern.byteIsSpecial(pattern_index) and pattern.text[pattern_index] == '\\' and pattern_index + 1 < pattern.text.len) {
        if (text_index == text.len) return null;
        const pattern_len = utf8SequenceLength(pattern.text[pattern_index + 1 ..]);
        if (pattern_index + 1 + pattern_len > pattern.text.len or text_index + pattern_len > text.len) return null;
        if (!std.mem.eql(u8, pattern.text[pattern_index + 1 ..][0..pattern_len], text[text_index..][0..pattern_len])) {
            return null;
        }
        return .{ .pattern_index = pattern_index + 1 + pattern_len, .text_index = text_index + pattern_len };
    }
    if (text_index == text.len) return null;
    const text_len = utf8SequenceLength(text[text_index..]);
    if (pattern.byteIsSpecial(pattern_index) and pattern.text[pattern_index] == '?') {
        return .{ .pattern_index = pattern_index + 1, .text_index = text_index + text_len };
    }
    if (pattern.byteIsSpecial(pattern_index) and pattern.text[pattern_index] == '[') {
        if (bracketExpressionMatches(pattern, pattern_index, text[text_index..][0..text_len])) |matched| {
            if (!matched.matched) return null;
            return .{ .pattern_index = matched.end, .text_index = text_index + text_len };
        }
    }
    const pattern_len = utf8SequenceLength(pattern.text[pattern_index..]);
    if (pattern_index + pattern_len > pattern.text.len or text_index + pattern_len > text.len) return null;
    if (!std.mem.eql(u8, pattern.text[pattern_index..][0..pattern_len], text[text_index..][0..pattern_len])) {
        return null;
    }
    return .{ .pattern_index = pattern_index + pattern_len, .text_index = text_index + pattern_len };
}

const BracketMatch = struct {
    matched: bool,
    end: usize,
};

fn bracketExpressionMatches(pattern: Pattern, start: usize, character: []const u8) ?BracketMatch {
    std.debug.assert(pattern.text[start] == '[');
    var index = start + 1;
    var negated = false;
    if (index < pattern.text.len and (pattern.text[index] == '!' or pattern.text[index] == '^')) {
        negated = true;
        index += 1;
    }
    var matched = false;
    var saw_member = false;
    while (index < pattern.text.len) {
        if (pattern.byteIsSpecial(index) and pattern.text[index] == '\\' and index + 1 < pattern.text.len) {
            index += 1;
            const member_len = utf8SequenceLength(pattern.text[index..]);
            if (index + member_len > pattern.text.len) return null;
            const member = pattern.text[index..][0..member_len];
            index += member_len;
            saw_member = true;
            matched = matched or std.mem.eql(u8, member, character);
            continue;
        }
        if (pattern.text[index] == ']' and saw_member) break;
        if (bracketNamedExpression(pattern.text, &index)) |named| {
            saw_member = true;
            matched = matched or bracketNamedExpressionMatches(named, character);
            continue;
        }
        const member_len = utf8SequenceLength(pattern.text[index..]);
        if (index + member_len > pattern.text.len) return null;
        const member = pattern.text[index..][0..member_len];
        index += member_len;
        saw_member = true;
        if (index < pattern.text.len and pattern.text[index] == '-' and index + 1 < pattern.text.len and
            pattern.text[index + 1] != ']')
        {
            index += 1;
            const end_len = utf8SequenceLength(pattern.text[index..]);
            if (index + end_len > pattern.text.len) return null;
            const end = pattern.text[index..][0..end_len];
            index += end_len;
            matched = matched or bracketRangeMatches(member, end, character);
        } else {
            matched = matched or std.mem.eql(u8, member, character);
        }
    }
    if (!saw_member or index >= pattern.text.len or pattern.text[index] != ']') return null;
    return .{ .matched = if (negated) !matched else matched, .end = index + 1 };
}

fn bracketExpressionEnd(pattern: Pattern, start: usize) ?usize {
    std.debug.assert(pattern.text[start] == '[');
    var index = start + 1;
    if (index < pattern.text.len and (pattern.text[index] == '!' or pattern.text[index] == '^')) index += 1;
    var saw_member = false;
    while (index < pattern.text.len) {
        if (pattern.byteIsSpecial(index) and pattern.text[index] == '\\' and index + 1 < pattern.text.len) {
            index += 1;
            const member_len = utf8SequenceLength(pattern.text[index..]);
            if (index + member_len > pattern.text.len) return null;
            index += member_len;
            saw_member = true;
            continue;
        }
        if (pattern.text[index] == ']' and saw_member) break;
        if (bracketNamedExpression(pattern.text, &index) != null) {
            saw_member = true;
            continue;
        }
        const member_len = utf8SequenceLength(pattern.text[index..]);
        if (index + member_len > pattern.text.len) return null;
        index += member_len;
        saw_member = true;
        if (index < pattern.text.len and pattern.text[index] == '-' and index + 1 < pattern.text.len and
            pattern.text[index + 1] != ']')
        {
            index += 1;
            const end_len = utf8SequenceLength(pattern.text[index..]);
            if (index + end_len > pattern.text.len) return null;
            index += end_len;
        }
    }
    if (!saw_member or index >= pattern.text.len or pattern.text[index] != ']') return null;
    return index + 1;
}

fn bracketRangeMatches(start: []const u8, end: []const u8, character: []const u8) bool {
    if (start.len != 1 or end.len != 1 or character.len != 1) return false;
    return start[0] <= character[0] and character[0] <= end[0];
}

const BracketNamedExpression = struct {
    kind: u8,
    name: []const u8,
};

fn bracketNamedExpression(text: []const u8, index: *usize) ?BracketNamedExpression {
    if (index.* + 3 >= text.len or text[index.*] != '[') return null;
    const kind = text[index.* + 1];
    const close = switch (kind) {
        ':', '.', '=' => kind,
        else => return null,
    };
    const name_start = index.* + 2;
    var cursor = name_start;
    while (cursor + 1 < text.len) : (cursor += 1) {
        if (text[cursor] == close and text[cursor + 1] == ']') {
            const named: BracketNamedExpression = .{ .kind = kind, .name = text[name_start..cursor] };
            index.* = cursor + 2;
            return named;
        }
    }
    return null;
}

fn bracketNamedExpressionMatches(named: BracketNamedExpression, character: []const u8) bool {
    return switch (named.kind) {
        ':' => characterClassMatches(named.name, character),
        '.', '=' => std.mem.eql(u8, named.name, character),
        else => false,
    };
}

fn characterClassMatches(name: []const u8, character: []const u8) bool {
    const class = std.meta.stringToEnum(CharacterClass, name) orelse return false;
    // ziglint-ignore: Z011 deprecated API left unchanged to avoid semantic drift
    const codepoint = std.unicode.utf8Decode(character) catch return false;
    const category = uucode.get(.general_category, codepoint);
    return switch (class) {
        .digit => category == .number_decimal_digit,
        .alpha => isCategoryLetter(category),
        .alnum => isCategoryLetter(category) or category == .number_decimal_digit,
        .blank => codepoint == '\t' or category == .separator_space,
        .cntrl => category == .other_control,
        .graph => isPrintableCategory(category) and category != .separator_space,
        .lower => category == .letter_lowercase,
        .print => isPrintableCategory(category),
        .upper => category == .letter_uppercase,
        .punct => switch (category) {
            .punctuation_connector,
            .punctuation_dash,
            .punctuation_open,
            .punctuation_close,
            .punctuation_initial_quote,
            .punctuation_final_quote,
            .punctuation_other,
            => true,
            else => false,
        },
        .space => switch (category) {
            .separator_space,
            .separator_line,
            .separator_paragraph,
            => true,
            // ziglint-ignore: Z024 preserve existing readable expression shape; behavior-neutral extraction
            else => codepoint == '\t' or codepoint == '\n' or codepoint == '\r' or codepoint == 0x0b or codepoint == 0x0c,
        },
        .xdigit => codepoint <= std.math.maxInt(u8) and std.ascii.isHex(@intCast(codepoint)),
    };
}

const CharacterClass = enum {
    alnum,
    alpha,
    blank,
    cntrl,
    digit,
    graph,
    lower,
    print,
    punct,
    space,
    upper,
    xdigit,
};

fn isCategoryLetter(category: uucode.types.GeneralCategory) bool {
    return switch (category) {
        .letter_uppercase,
        .letter_lowercase,
        .letter_titlecase,
        .letter_modifier,
        .letter_other,
        => true,
        else => false,
    };
}

fn isPrintableCategory(category: uucode.types.GeneralCategory) bool {
    return switch (category) {
        .separator_line,
        .separator_paragraph,
        .other_control,
        .other_format,
        .other_surrogate,
        .other_private_use,
        .other_not_assigned,
        => false,
        else => true,
    };
}

pub const RemovalSize = enum {
    small,
    large,
};

pub fn removePrefix(value: []const u8, pattern: []const u8, size: RemovalSize) []const u8 {
    // Escapes and possible pattern operators retain the general matcher.
    if (std.mem.findAny(u8, pattern, "*?[\\") == null) {
        if (!std.mem.startsWith(u8, value, pattern)) return value;
        const cut = pattern.len;
        return if (removalBoundaryReachable(value, cut, size == .large)) value[cut..] else value;
    }
    switch (size) {
        .small => {
            var cut: usize = 0;
            while (cut <= value.len) : (cut = nextCut(value, cut)) {
                if (matchesText(pattern, value[0..cut])) return value[cut..];
                if (cut == value.len) break;
            }
        },
        .large => {
            var cut = value.len;
            while (true) {
                if (matchesText(pattern, value[0..cut])) return value[cut..];
                if (cut == 0) break;
                cut = previousCut(value, cut);
            }
        },
    }
    return value;
}

pub fn removeSuffix(value: []const u8, pattern: []const u8, size: RemovalSize) []const u8 {
    if (std.mem.findAny(u8, pattern, "*?[\\") == null) {
        if (!std.mem.endsWith(u8, value, pattern)) return value;
        const cut = value.len - pattern.len;
        return if (removalBoundaryReachable(value, cut, size == .small)) value[0..cut] else value;
    }
    switch (size) {
        .small => {
            var cut = value.len;
            while (true) {
                if (matchesText(pattern, value[cut..])) return value[0..cut];
                if (cut == 0) break;
                cut = previousCut(value, cut);
            }
        },
        .large => {
            var cut: usize = 0;
            while (cut <= value.len) : (cut = nextCut(value, cut)) {
                if (matchesText(pattern, value[cut..])) return value[0..cut];
                if (cut == value.len) break;
            }
        },
    }
    return value;
}

fn removalBoundaryReachable(value: []const u8, target: usize, backwards: bool) bool {
    std.debug.assert(target <= value.len);
    if (target == 0 or target == value.len) return true;
    // Literal matching determines one candidate cut. Preserve the matcher's
    // character boundaries, including its directional treatment of malformed UTF-8.
    if (backwards) {
        var cut = value.len;
        while (cut > target) cut = previousCut(value, cut);
        return cut == target;
    }
    var cut: usize = 0;
    while (cut < target) cut = nextCut(value, cut);
    return cut == target;
}

pub const Match = struct {
    start: usize,
    end: usize,
};

pub fn firstMatch(value: []const u8, pattern: []const u8) ?Match {
    return firstMatchFrom(value, pattern, 0);
}

pub fn firstMatchFrom(value: []const u8, pattern: []const u8, start: usize) ?Match {
    var cursor = start;
    while (cursor <= value.len) : (cursor = nextCut(value, cursor)) {
        if (longestMatchFrom(value, pattern, cursor)) |matched| return matched;
        if (cursor == value.len) break;
    }
    return null;
}

pub fn prefixMatch(value: []const u8, pattern: []const u8) ?Match {
    return longestMatchFrom(value, pattern, 0);
}

pub fn suffixMatch(value: []const u8, pattern: []const u8) ?Match {
    var start: usize = 0;
    while (start <= value.len) : (start = nextCut(value, start)) {
        if (matchesText(pattern, value[start..])) return .{ .start = start, .end = value.len };
        if (start == value.len) break;
    }
    return null;
}

fn longestMatchFrom(value: []const u8, pattern: []const u8, start: usize) ?Match {
    var end = value.len;
    while (true) {
        if (matchesText(pattern, value[start..end])) return .{ .start = start, .end = end };
        if (end == start) break;
        end = previousCut(value, end);
    }
    return null;
}

pub fn nextCut(value: []const u8, cut: usize) usize {
    if (cut >= value.len) return value.len + 1;
    return cut + utf8SequenceLength(value[cut..]);
}

fn previousCut(value: []const u8, cut: usize) usize {
    std.debug.assert(cut <= value.len);
    if (cut == 0) return 0;
    var previous = cut - 1;
    while (previous > 0 and (value[previous] & 0xc0) == 0x80) previous -= 1;
    return previous;
}

fn utf8SequenceLength(text: []const u8) usize {
    if (text.len == 0) return 0;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
    return @min(len, text.len);
}

test "escaped metacharacters and special masks remain literal" {
    try std.testing.expect(matchesText("a\\*b\\?c", "a*b?c"));
    try std.testing.expect(!containsMeta(.{ .text = "*?[a]", .special = &.{ false, false, false, false, false } }));
    try std.testing.expect(matches(.{ .text = "*", .special = &.{false} }, "*"));
}

test "consecutive stars backtrack across empty and non-empty text" {
    try std.testing.expect(matchesText("a***b**c", "abc"));
    try std.testing.expect(matchesText("a***b**c", "axbyc"));
    try std.testing.expect(!matchesText("a***b**c", "axby"));
}

test "bracket negation ranges and named classes retain matching behavior" {
    try std.testing.expect(matchesText("[!a-c]", "z"));
    try std.testing.expect(!matchesText("[^a-c]", "b"));
    try std.testing.expect(matchesText("[[:digit:]]", "7"));
    try std.testing.expect(matchesText("[[:alpha:]]", "λ"));
}

test "malformed brackets are literals rather than pattern metadata" {
    try std.testing.expect(!containsMeta(.{ .text = "a[b" }));
    try std.testing.expect(matchesText("a[b", "a[b"));
    try std.testing.expect(!matchesText("a[b", "ab"));
}

test "matching treats multibyte and empty input consistently" {
    try std.testing.expect(matchesText("?", "å"));
    try std.testing.expect(matchesText("[å]", "å"));
    try std.testing.expect(matchesText("*", ""));
    try std.testing.expect(matchesText("", ""));
    try std.testing.expect(!matchesText("?", ""));
}

test "prefix and suffix removal preserve shortest and longest semantics" {
    try std.testing.expectEqualStrings("one/two/three", removePrefix("/one/two/three", "*/", .small));
    try std.testing.expectEqualStrings("three", removePrefix("/one/two/three", "*/", .large));
    try std.testing.expectEqualStrings("posix/src", removeSuffix("posix/src/std", "/*", .small));
    try std.testing.expectEqualStrings("posix", removeSuffix("posix/src/std", "/*", .large));
    try std.testing.expectEqualStrings("", removePrefix("", "*", .small));
    try std.testing.expectEqualStrings("", removeSuffix("", "*", .large));
}

test "literal removal agrees with the matcher at byte and Unicode boundaries" {
    const Reference = struct {
        fn remove(value: []const u8, pattern: []const u8, size: RemovalSize, prefix: bool) []const u8 {
            const backwards = prefix == (size == .large);
            var cut: usize = if (backwards) value.len else 0;
            while (true) {
                if (matchesText(pattern, if (prefix) value[0..cut] else value[cut..])) {
                    return if (prefix) value[cut..] else value[0..cut];
                }
                if (backwards) {
                    if (cut == 0) break;
                    cut = previousCut(value, cut);
                } else {
                    if (cut == value.len) break;
                    cut = nextCut(value, cut);
                }
            }
            return value;
        }
    };
    const values = [_][]const u8{ "", "abc", "abcabc", "åbç", "*?[", "\\x", "x\x80", "\xc3x", "\xc3", "\xa5" };
    const patterns = [_][]const u8{
        "",     "a",    "abc",  "c", "x", "missing",
        "å",
        "ç",
        "\xc3", "\xa5", "\x80", "*", "?", "[a-c]",
        "[",    "\\*",  "\\\\",
    };
    for (values) |value| {
        for (patterns) |pattern| {
            for ([_]RemovalSize{ .small, .large }) |size| {
                try std.testing.expectEqualStrings(
                    Reference.remove(value, pattern, size, true),
                    removePrefix(value, pattern, size),
                );
                try std.testing.expectEqualStrings(
                    Reference.remove(value, pattern, size, false),
                    removeSuffix(value, pattern, size),
                );
            }
        }
    }
}

test "prefix and suffix match searches select longest matches" {
    const expected: Match = .{ .start = 0, .end = 6 };
    try std.testing.expectEqual(expected, prefixMatch("abcabc", "a*c").?);
    try std.testing.expectEqual(expected, suffixMatch("abcabc", "a*c").?);
}
