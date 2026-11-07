//! Editor-facing completion model and pure application helpers.

const std = @import("std");

pub const Kind = enum {
    command,
    builtin,
    function,
    file,
    directory,
    variable,
    option,
    subcommand,
    plain,
};

/// Completion payloads are borrowed by matching and application helpers.
/// Candidate slices passed to `freeCandidates` must instead be deeply owned by
/// that allocator.
pub const Candidate = struct {
    value: []const u8,
    display: ?[]const u8 = null,
    insert: ?[]const u8 = null,
    description: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    suffix: ?[]const u8 = null,
    removable_suffix: bool = false,
    priority: i8 = 0,
    kind: Kind = .plain,
    option: ?Option = null,
    replace_start: usize,
    replace_end: usize,
    append_space: bool = true,
    provider_order: ?usize = null,
    source_order: ?usize = null,
};

pub const MatchRank = enum(u8) {
    exact = 0,
    prefix = 1,
    fuzzy = 2,
};

pub const CaseSensitivity = enum {
    sensitive,
    insensitive,
};

pub const MatchMode = enum {
    prefix,
    fuzzy,
};

pub const SeparatorPolicy = enum {
    literal,
    hyphen_underscore_equivalent,
};

pub const PathSegmentPolicy = enum {
    full,
    last,
};

pub const MatcherPolicy = struct {
    case_sensitivity: CaseSensitivity = .insensitive,
    mode: MatchMode = .fuzzy,
    separators: SeparatorPolicy = .hyphen_underscore_equivalent,
    path_segments: PathSegmentPolicy = .full,

    pub fn engineDefault() MatcherPolicy {
        return .{};
    }

    pub fn prefixOnly() MatcherPolicy {
        return .{ .mode = .prefix };
    }
};

pub const MatchSuppressionReason = enum {
    invalid_replace_span,
    no_match,
    prefix_only,
};

pub const CandidateMatchTrace = struct {
    query: []const u8,
    rank: ?MatchRank,
    suppression_reason: ?MatchSuppressionReason,
};

pub const Option = struct {
    long: ?[]const u8 = null,
    short: ?[]const u8 = null,
    spellings: []const []const u8 = &.{},
    argument: ?[]const u8 = null,
    value_count: usize = 0,
    exclusive_group: ?[]const u8 = null,
    excludes: []const OptionExclusion = &.{},
    repeatable: bool = false,
    terminates_options: bool = false,
    no_space: bool = false,
    inherit: bool = true,
};

pub const OptionExclusionKind = enum {
    option,
    operands,
    everything,
};

pub const OptionExclusion = struct {
    kind: OptionExclusionKind,
    selector: ?[]const u8 = null,
};

pub const Edit = struct {
    replace_start: usize,
    replace_end: usize,
    replacement: []const u8,
    suffix: ?[]const u8 = null,
    removable_suffix: bool = false,
    append_space: bool = false,
};

/// Deeply owned completion application data. Applying it only borrows the
/// payload; the receiver must call `deinit` afterward.
pub const Application = union(enum) {
    none,
    edit: Edit,
    ambiguous: []Candidate,

    pub fn deinit(self: Application, allocator: std.mem.Allocator) void {
        switch (self) {
            .edit => |edit| {
                allocator.free(edit.replacement);
                if (edit.suffix) |suffix| allocator.free(suffix);
            },
            .ambiguous => |candidates| freeCandidates(allocator, candidates),
            .none => {},
        }
    }
};

/// Frees the candidate slice and every nested payload with `allocator`.
pub fn freeCandidates(allocator: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |candidate| {
        freeCandidateFields(allocator, candidate);
    }
    allocator.free(candidates);
}

fn freeCandidateFields(allocator: std.mem.Allocator, candidate: Candidate) void {
    allocator.free(candidate.value);
    if (candidate.display) |display| allocator.free(display);
    if (candidate.insert) |insert| allocator.free(insert);
    if (candidate.description) |description| allocator.free(description);
    if (candidate.tag) |tag| allocator.free(tag);
    if (candidate.suffix) |suffix| allocator.free(suffix);
    if (candidate.option) |option| {
        if (option.long) |long| allocator.free(long);
        if (option.short) |short| allocator.free(short);
        if (option.spellings.len != 0) {
            for (option.spellings) |spelling| allocator.free(spelling);
            allocator.free(option.spellings);
        }
        if (option.argument) |argument| allocator.free(argument);
        if (option.exclusive_group) |group| allocator.free(group);
        freeOptionExclusions(allocator, option.excludes);
    }
}

fn freeOptionExclusions(allocator: std.mem.Allocator, excludes: []const OptionExclusion) void {
    if (excludes.len == 0) return;
    for (excludes) |exclusion| if (exclusion.selector) |selector| allocator.free(selector);
    allocator.free(excludes);
}

/// Borrows `candidates` and returns a deep-owned application.
pub fn applyCandidates(allocator: std.mem.Allocator, candidates: []const Candidate) !Application {
    if (candidates.len == 0) return .none;
    for (candidates) |candidate| {
        std.debug.assert(candidate.replace_start <= candidate.replace_end);
    }

    if (candidates.len == 1) {
        const candidate = candidates[0];
        const replacement = try candidateEditReplacement(allocator, candidate);
        errdefer allocator.free(replacement);
        const suffix = try candidateEditSuffix(allocator, candidate);
        errdefer if (suffix) |owned_suffix| allocator.free(owned_suffix);
        return .{ .edit = .{
            .replace_start = candidate.replace_start,
            .replace_end = candidate.replace_end,
            .replacement = replacement,
            .suffix = suffix,
            .removable_suffix = candidate.removable_suffix,
            .append_space = candidate.append_space,
        } };
    }

    return .{ .ambiguous = try cloneCandidates(allocator, candidates) };
}

pub fn sortCandidates(candidates: []Candidate) void {
    std.mem.sort(Candidate, candidates, {}, lessThanCandidate);
}

fn lessThanCandidate(_: void, a: Candidate, b: Candidate) bool {
    if (a.priority != b.priority) return a.priority > b.priority;
    const a_class = candidateSortClass(a);
    const b_class = candidateSortClass(b);
    if (a_class != b_class) return a_class < b_class;
    const a_provider_order = candidateProviderOrder(a);
    const b_provider_order = candidateProviderOrder(b);
    if (a_provider_order != b_provider_order) return a_provider_order < b_provider_order;
    const a_source_order = candidateSourceOrder(a);
    const b_source_order = candidateSourceOrder(b);
    if (a_source_order != b_source_order) return a_source_order < b_source_order;
    return std.mem.lessThan(u8, candidateSortKey(a), candidateSortKey(b));
}

fn candidateProviderOrder(candidate: Candidate) usize {
    return candidate.provider_order orelse std.math.maxInt(usize);
}

fn candidateSourceOrder(candidate: Candidate) usize {
    return candidate.source_order orelse std.math.maxInt(usize);
}

fn candidateSortClass(candidate: Candidate) u8 {
    if (candidate.kind == .directory) return 0;
    if (candidate.kind == .file) return 1;
    if (candidate.kind != .option) return 2;
    if (candidate.option) |option| {
        if (option.long == null and option.short != null) return 3;
    }
    return 4;
}

fn candidateSortKey(candidate: Candidate) []const u8 {
    if (candidate.kind == .option) {
        if (candidate.option) |option| {
            if (option.long) |long| return long;
            if (option.short) |short| return short;
            if (option.spellings.len != 0) return option.spellings[0];
        }
    }
    return candidate.display orelse candidate.value;
}

test "candidate sorting uses priority and source order before lexical fallback" {
    var candidates = [_]Candidate{
        .{ .value = "alpha", .replace_start = 0, .replace_end = 0, .source_order = 1 },
        .{ .value = "zebra", .priority = 10, .replace_start = 0, .replace_end = 0, .source_order = 2 },
        .{ .value = "beta", .replace_start = 0, .replace_end = 0, .source_order = 0 },
    };

    sortCandidates(&candidates);

    try std.testing.expectEqualStrings("zebra", candidates[0].value);
    try std.testing.expectEqualStrings("beta", candidates[1].value);
    try std.testing.expectEqualStrings("alpha", candidates[2].value);
}

pub fn candidateInsertText(candidate: Candidate) []const u8 {
    return candidate.insert orelse candidate.value;
}

pub fn candidateEditReplacement(allocator: std.mem.Allocator, candidate: Candidate) ![]const u8 {
    if (candidate.insert) |insert| return allocator.dupe(u8, insert);
    if (candidate.suffix) |suffix| return std.mem.concat(allocator, u8, &.{ candidate.value, suffix });
    return allocator.dupe(u8, candidate.value);
}

pub fn candidateEditSuffix(allocator: std.mem.Allocator, candidate: Candidate) !?[]const u8 {
    const suffix = candidate.suffix orelse return null;
    const owned = try allocator.dupe(u8, suffix);
    return owned;
}

pub fn candidateFuzzyMatchRank(candidate: Candidate, query: []const u8) ?MatchRank {
    return candidateMatchRank(candidate, query, .engineDefault());
}

pub fn candidateMatchRank(candidate: Candidate, query: []const u8, policy: MatcherPolicy) ?MatchRank {
    const value_rank = matchRank(candidate.value, query, policy);
    const display_rank = if (candidate.display) |display| matchRank(display, query, policy) else null;
    if (value_rank) |value| {
        if (display_rank) |display| return if (@backingInt(display) < @backingInt(value)) display else value;
        return value;
    }
    return display_rank;
}

pub fn candidateMatchTrace(source: []const u8, candidate: Candidate, policy: MatcherPolicy) CandidateMatchTrace {
    if (candidate.replace_start > candidate.replace_end or candidate.replace_end > source.len) {
        return .{ .query = "", .rank = null, .suppression_reason = .invalid_replace_span };
    }
    const query = source[candidate.replace_start..candidate.replace_end];
    const rank = candidateMatchRank(candidate, query, policy);
    return .{
        .query = query,
        .rank = rank,
        .suppression_reason = if (rank == null) candidateSuppressionReason(candidate, query, policy) else null,
    };
}

pub fn candidateSuppressionReason(
    candidate: Candidate,
    query: []const u8,
    policy: MatcherPolicy,
) MatchSuppressionReason {
    if (policy.mode == .prefix) {
        var fuzzy_policy = policy;
        fuzzy_policy.mode = .fuzzy;
        if (candidateMatchRank(candidate, query, fuzzy_policy)) |rank| {
            if (rank == .fuzzy) return .prefix_only;
        }
    }
    return .no_match;
}

pub fn fuzzyMatchRank(text: []const u8, query: []const u8) ?MatchRank {
    return matchRank(text, query, .engineDefault());
}

pub fn matchRank(text: []const u8, query: []const u8, policy: MatcherPolicy) ?MatchRank {
    const input = pathMatchInput(text, query, policy);
    const match_text = input.text;
    const match_query = input.query;
    if (match_query.len == 0) return .prefix;
    if (eqlWithPolicy(match_text, match_query, policy)) return .exact;
    if (startsWithPolicy(match_text, match_query, policy)) return .prefix;
    if (policy.mode == .prefix) return null;

    var text_index: usize = 0;
    for (match_query) |query_byte| {
        var matched = false;
        while (text_index < match_text.len) : (text_index += 1) {
            if (bytesEqual(match_text[text_index], query_byte, policy)) {
                text_index += 1;
                matched = true;
                break;
            }
        }
        if (!matched) return null;
    }
    return .fuzzy;
}

const PathMatchInput = struct {
    text: []const u8,
    query: []const u8,
};

fn pathMatchInput(text: []const u8, query: []const u8, policy: MatcherPolicy) PathMatchInput {
    if (policy.path_segments == .full) return .{ .text = text, .query = query };
    const query_slash = std.mem.lastIndexOfScalar(u8, query, '/') orelse return .{
        .text = lastPathSegment(text),
        .query = query,
    };
    const query_dir = query[0 .. query_slash + 1];
    if (!startsWithPolicy(text, query_dir, policy)) return .{ .text = "", .query = query };
    return .{ .text = text[query_dir.len..], .query = query[query_slash + 1 ..] };
}

fn lastPathSegment(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    const slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse return path[0..end];
    return path[slash + 1 .. end];
}

fn eqlWithPolicy(a: []const u8, b: []const u8, policy: MatcherPolicy) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_byte, b_byte| {
        if (!bytesEqual(a_byte, b_byte, policy)) return false;
    }
    return true;
}

fn startsWithPolicy(text: []const u8, query: []const u8, policy: MatcherPolicy) bool {
    if (query.len > text.len) return false;
    for (text[0..query.len], query) |text_byte, query_byte| {
        if (!bytesEqual(text_byte, query_byte, policy)) return false;
    }
    return true;
}

fn bytesEqual(a: u8, b: u8, policy: MatcherPolicy) bool {
    return normalizeMatchByte(a, policy) == normalizeMatchByte(b, policy);
}

fn normalizeMatchByte(byte: u8, policy: MatcherPolicy) u8 {
    const c = switch (policy.case_sensitivity) {
        .sensitive => byte,
        .insensitive => std.ascii.toLower(byte),
    };
    return switch (policy.separators) {
        .literal => c,
        .hyphen_underscore_equivalent => if (c == '_') '-' else c,
    };
}

pub fn fuzzyMatchPositions(allocator: std.mem.Allocator, text: []const u8, query: []const u8) !?[]usize {
    return matchPositions(allocator, text, query, .engineDefault());
}

pub fn matchPositions(
    allocator: std.mem.Allocator,
    text: []const u8,
    query: []const u8,
    policy: MatcherPolicy,
) !?[]usize {
    if (matchRank(text, query, policy) == null) return null;
    var positions: std.ArrayList(usize) = .empty;
    errdefer positions.deinit(allocator);
    if (query.len == 0) return try positions.toOwnedSlice(allocator);

    const input = pathMatchInput(text, query, policy);
    const match_text = input.text;
    const match_query = input.query;
    const offset = @intFromPtr(match_text.ptr) - @intFromPtr(text.ptr);
    var text_index: usize = 0;
    for (match_query) |query_byte| {
        while (text_index < match_text.len) : (text_index += 1) {
            if (bytesEqual(match_text[text_index], query_byte, policy)) {
                try positions.append(allocator, offset + text_index);
                text_index += 1;
                break;
            }
        }
    }
    return try positions.toOwnedSlice(allocator);
}

/// Deep-copies candidates for later release with `freeCandidates`.
pub fn cloneCandidates(allocator: std.mem.Allocator, candidates: []const Candidate) ![]Candidate {
    const cloned = try allocator.alloc(Candidate, candidates.len);
    errdefer allocator.free(cloned);
    var initialized: usize = 0;
    errdefer for (cloned[0..initialized]) |candidate| freeCandidateFields(allocator, candidate);
    for (candidates, 0..) |candidate, index| {
        cloned[index] = try cloneCandidate(allocator, candidate);
        initialized += 1;
    }
    return cloned;
}

fn cloneCandidate(allocator: std.mem.Allocator, candidate: Candidate) !Candidate {
    var cloned = candidate;
    cloned.value = try allocator.dupe(u8, candidate.value);
    errdefer allocator.free(cloned.value);
    if (candidate.display) |display| cloned.display = try allocator.dupe(u8, display);
    errdefer if (cloned.display) |display| allocator.free(display);
    if (candidate.insert) |insert| cloned.insert = try allocator.dupe(u8, insert);
    errdefer if (cloned.insert) |insert| allocator.free(insert);
    if (candidate.description) |description| cloned.description = try allocator.dupe(u8, description);
    errdefer if (cloned.description) |description| allocator.free(description);
    if (candidate.tag) |tag| cloned.tag = try allocator.dupe(u8, tag);
    errdefer if (cloned.tag) |tag| allocator.free(tag);
    if (candidate.suffix) |suffix| cloned.suffix = try allocator.dupe(u8, suffix);
    errdefer if (cloned.suffix) |suffix| allocator.free(suffix);
    if (candidate.option) |option| {
        cloned.option = .{
            .long = if (option.long) |long| try allocator.dupe(u8, long) else null,
            .short = if (option.short) |short| try allocator.dupe(u8, short) else null,
            .spellings = try cloneStringSlice(allocator, option.spellings),
            .argument = if (option.argument) |argument| try allocator.dupe(u8, argument) else null,
            .exclusive_group = if (option.exclusive_group) |group| try allocator.dupe(u8, group) else null,
            .excludes = try cloneOptionExclusions(allocator, option.excludes),
            .repeatable = option.repeatable,
            .terminates_options = option.terminates_options,
            .no_space = option.no_space,
            .inherit = option.inherit,
        };
    }
    errdefer if (cloned.option) |option| {
        if (option.long) |long| allocator.free(long);
        if (option.short) |short| allocator.free(short);
        if (option.spellings.len != 0) {
            for (option.spellings) |spelling| allocator.free(spelling);
            allocator.free(option.spellings);
        }
        if (option.argument) |argument| allocator.free(argument);
        if (option.exclusive_group) |group| allocator.free(group);
        freeOptionExclusions(allocator, option.excludes);
    };
    return cloned;
}

fn cloneOptionExclusions(allocator: std.mem.Allocator, excludes: []const OptionExclusion) ![]const OptionExclusion {
    if (excludes.len == 0) return &.{};
    const cloned = try allocator.alloc(OptionExclusion, excludes.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |exclusion| if (exclusion.selector) |selector| allocator.free(selector);
        allocator.free(cloned);
    }
    for (excludes, 0..) |exclusion, index| {
        cloned[index] = .{
            .kind = exclusion.kind,
            .selector = if (exclusion.selector) |selector| try allocator.dupe(u8, selector) else null,
        };
        initialized += 1;
    }
    return cloned;
}

fn cloneStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    if (values.len == 0) return &.{};
    const cloned = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(cloned);
    var initialized: usize = 0;
    errdefer for (cloned[0..initialized]) |value| allocator.free(value);
    for (values, 0..) |value, index| {
        cloned[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return cloned;
}
