//! Rush interactive completion service.

const std = @import("std");
const build_config = @import("build_config");

const manifest = @import("completion/manifest.zig");
const completion_path = @import("completion_path.zig");
const editor_completion = @import("editor/completion.zig");
const extensions = @import("extensions.zig");
const history = @import("history.zig");
const host = @import("host.zig");
const shell = @import("shell.zig");

pub const Application = editor_completion.Application;

const max_manifest_bytes = 4 * 1024 * 1024;
const max_companion_bytes = 1024 * 1024;

pub fn complete(
    context: *anyopaque,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    allocator: std.mem.Allocator,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    io: std.Io,
    source: []const u8,
    cursor: usize,
) !Application {
    const sh = rushShellFromOpaque(context);
    var analyzed = try analyzeLine(allocator, source, cursor);
    defer analyzed.deinit(allocator);

    var builder: Builder = .{};
    defer builder.deinit(allocator);

    if (analyzed.kind == .parameter) {
        try appendVariableCandidates(allocator, &builder, sh, analyzed.replace_start, analyzed.replace_end);
        return applyBuiltCandidates(allocator, source, &builder, analyzed);
    }

    if (analyzed.kind == .command) {
        const command_prefix = if (analyzed.literal_prefix) |literal| literal.value else analyzed.prefix;
        if (std.mem.indexOfScalar(u8, command_prefix, '/') == null) {
            try appendCommandCandidates(allocator, &builder, sh, analyzed.replace_start, analyzed.replace_end);
            return applyBuiltCandidates(allocator, source, &builder, analyzed);
        }
        if (analyzed.literal_prefix) |literal| {
            try appendPathCandidates(
                allocator,
                &builder,
                sh,
                literal.value,
                literal.expands_leading_tilde,
                analyzed.replace_start,
                analyzed.replace_end,
                false,
            );
        }
        return applyBuiltCandidates(allocator, source, &builder, analyzed);
    }

    if (!analyzed.completing_redirection_target) {
        if (analyzed.root) |root| {
            if (try completeFromManifest(allocator, io, sh, &builder, &analyzed, root)) |handled| {
                if (handled) return applyBuiltCandidates(allocator, source, &builder, analyzed);
            }
        }
    }

    if (analyzed.literal_prefix) |literal| {
        try appendPathCandidates(
            allocator,
            &builder,
            sh,
            literal.value,
            literal.expands_leading_tilde,
            analyzed.replace_start,
            analyzed.replace_end,
            false,
        );
    }
    return applyBuiltCandidates(allocator, source, &builder, analyzed);
}

fn rushShellFromOpaque(context: *anyopaque) *shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry) {
    return @ptrCast(@alignCast(context));
}

const CompletionKind = enum {
    command,
    argument,
    parameter,
};

const Word = manifest.Word;

const AnalyzedLine = struct {
    words: []Word,
    current_word_index: ?usize,
    replace_start: usize,
    replace_end: usize,
    prefix: []const u8,
    /// Literal value of the typed word up to the cursor. Null when evaluation
    /// would be required to determine it.
    literal_prefix: ?shell.word_quoting.LiteralWord,
    /// Literal value of the full current word, used for candidate matching.
    literal_query: ?shell.word_quoting.LiteralWord,
    kind: CompletionKind,
    root: ?[]const u8,
    command_word_index: ?usize,
    completing_redirection_target: bool,

    fn deinit(self: AnalyzedLine, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
        if (self.literal_prefix) |literal| literal.deinit(allocator);
        if (self.literal_query) |literal| literal.deinit(allocator);
    }
};

fn analyzeLine(allocator: std.mem.Allocator, source: []const u8, raw_cursor: usize) !AnalyzedLine {
    const cursor = @min(raw_cursor, source.len);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const src: shell.source.Source = .{ .id = 0, .kind = .interactive, .name = "completion", .text = source };
    const tokens = try shell.lexer.lex(arena.allocator(), src);

    var words: std.ArrayList(Word) = .empty;
    errdefer words.deinit(allocator);

    var tracker: shell.token.CommandPositionTracker = .{};
    var current_word_index: ?usize = null;
    var current_word_class: ?shell.token.CommandPositionTracker.Class = null;
    var command_word_index: ?usize = null;
    for (tokens) |tok| {
        if (tok.kind == .eof) break;
        if (tok.span.start >= cursor) break;
        const class = tracker.classify(tok);
        if (tok.kind != .word) {
            // A token that reopens command position starts a new command
            // segment, so any previous command word no longer applies.
            if (tracker.command_position) command_word_index = null;
            continue;
        }
        const index = words.items.len;
        try words.append(allocator, .{
            .text = source[tok.span.start..tok.span.end],
            .start = tok.span.start,
            .end = tok.span.end,
            .redirection_target = class == .redirection_target,
        });
        if (class == .command) command_word_index = index;
        if (class == .reserved and tracker.command_position) command_word_index = null;
        if (cursor <= tok.span.end) {
            current_word_index = index;
            current_word_class = class;
        }
    }

    // Completing inside an unterminated command substitution is really
    // completing the inner command line, so analyze that line instead.
    if (current_word_index) |index| {
        const word = words.items[index];
        if (try substitutionInteriorStart(arena.allocator(), source[word.start..cursor])) |relative| {
            const inner_start = word.start + relative;
            words.deinit(allocator);
            words = .empty;
            var inner = try analyzeLine(allocator, source[inner_start..], cursor - inner_start);
            for (inner.words) |*inner_word| {
                inner_word.start += inner_start;
                inner_word.end += inner_start;
            }
            inner.replace_start += inner_start;
            inner.replace_end += inner_start;
            return inner;
        }
    }

    const replace_start = if (current_word_index) |index| words.items[index].start else cursor;
    const replace_end = if (current_word_index) |index| words.items[index].end else cursor;
    const raw_prefix = source[replace_start..cursor];
    // Issue 8 dollar-single-quotes begin with `$'`, but are literal words rather
    // than parameter expansions.
    const parameter = raw_prefix.len != 0 and raw_prefix[0] == '$' and
        (raw_prefix.len == 1 or raw_prefix[1] != '\'');
    const prefix = if (parameter) raw_prefix[1..] else raw_prefix;
    const word_start = if (parameter) replace_start + 1 else replace_start;
    const literal_prefix = try shell.word_quoting.parseLiteralWord(allocator, prefix);
    errdefer if (literal_prefix) |literal| literal.deinit(allocator);
    const literal_query = try shell.word_quoting.parseLiteralWord(allocator, source[word_start..replace_end]);
    errdefer if (literal_query) |literal| literal.deinit(allocator);

    const is_command = if (current_word_class) |class|
        class == .command or class == .reserved
    else
        tracker.command_position and !tracker.skip_redirection_target;
    const kind: CompletionKind = if (parameter) .parameter else if (is_command) .command else .argument;
    const root = if (command_word_index) |index| words.items[index].text else null;
    const completing_redirection_target = if (current_word_class) |class|
        class == .redirection_target
    else
        tracker.skip_redirection_target;

    return .{
        .words = try words.toOwnedSlice(allocator),
        .current_word_index = current_word_index,
        .replace_start = word_start,
        .replace_end = replace_end,
        .prefix = prefix,
        .literal_prefix = literal_prefix,
        .literal_query = literal_query,
        .kind = kind,
        .root = root,
        .command_word_index = command_word_index,
        .completing_redirection_target = completing_redirection_target,
    };
}

fn selectAttachedOptionValue(allocator: std.mem.Allocator, analyzed: *AnalyzedLine, offset: usize) !void {
    std.debug.assert(offset <= analyzed.prefix.len);
    const current_word = analyzed.words[analyzed.current_word_index.?];
    const replace_start = analyzed.replace_start + offset;
    std.debug.assert(replace_start >= current_word.start);
    const word_offset = replace_start - current_word.start;
    std.debug.assert(word_offset <= current_word.text.len);

    const prefix = analyzed.prefix[offset..];
    const literal_prefix = try shell.word_quoting.parseLiteralWord(allocator, prefix);
    errdefer if (literal_prefix) |literal| literal.deinit(allocator);
    const literal_query = try shell.word_quoting.parseLiteralWord(allocator, current_word.text[word_offset..]);

    if (analyzed.literal_prefix) |literal| literal.deinit(allocator);
    if (analyzed.literal_query) |literal| literal.deinit(allocator);
    analyzed.replace_start = replace_start;
    analyzed.prefix = prefix;
    analyzed.literal_prefix = literal_prefix;
    analyzed.literal_query = literal_query;
}

/// Returns the offset just past the opener of the innermost `$(` or backquote
/// substitution left unclosed in `text`, or null when every substitution is
/// closed. Single quotes suppress openers; double quotes do not.
fn substitutionInteriorStart(allocator: std.mem.Allocator, text: []const u8) !?usize {
    var open_interiors: std.ArrayList(usize) = .empty;
    defer open_interiors.deinit(allocator);
    var backquote: ?usize = null;
    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (quote) |delimiter| {
            if (byte == delimiter) {
                quote = null;
                continue;
            }
            // Single quotes suppress substitutions; double quotes do not.
            if (delimiter == '\'') continue;
        }
        switch (byte) {
            '\\' => index += 1,
            '\'', '"' => if (quote == null) {
                quote = byte;
            },
            '`' => backquote = if (backquote == null) index + 1 else null,
            '$' => if (index + 1 < text.len and text[index + 1] == '(') {
                try open_interiors.append(allocator, index + 2);
                index += 1;
            },
            ')' => _ = open_interiors.pop(),
            else => {},
        }
    }
    const deepest = open_interiors.getLastOrNull();
    if (deepest != null and backquote != null) return @max(deepest.?, backquote.?);
    return deepest orelse backquote;
}

const Builder = struct {
    candidates: std.ArrayList(editor_completion.Candidate) = .empty,
    next_source_order: usize = 0,

    fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        if (self.candidates.items.len != 0) {
            const candidates = self.candidates.toOwnedSlice(allocator) catch unreachable;
            editor_completion.freeCandidates(allocator, candidates);
        } else self.candidates.deinit(allocator);
        self.* = undefined;
    }

    fn append(self: *Builder, allocator: std.mem.Allocator, candidate: editor_completion.Candidate) !void {
        if (self.contains(candidate)) return;
        var owned = candidate;
        owned.value = try allocator.dupe(u8, candidate.value);
        errdefer allocator.free(owned.value);
        if (candidate.display) |display| owned.display = try allocator.dupe(u8, display);
        errdefer if (owned.display) |display| allocator.free(display);
        if (candidate.insert) |insert| owned.insert = try allocator.dupe(u8, insert);
        errdefer if (owned.insert) |insert| allocator.free(insert);
        if (candidate.description) |description| owned.description = try allocator.dupe(u8, description);
        errdefer if (owned.description) |description| allocator.free(description);
        if (candidate.tag) |tag| owned.tag = try allocator.dupe(u8, tag);
        errdefer if (owned.tag) |tag| allocator.free(tag);
        if (candidate.suffix) |suffix| owned.suffix = try allocator.dupe(u8, suffix);
        errdefer if (owned.suffix) |suffix| allocator.free(suffix);
        owned.source_order = self.next_source_order;
        self.next_source_order += 1;
        try self.candidates.append(allocator, owned);
    }

    fn contains(self: Builder, candidate: editor_completion.Candidate) bool {
        for (self.candidates.items) |existing| {
            if (existing.replace_start == candidate.replace_start and
                existing.replace_end == candidate.replace_end and
                std.mem.eql(u8, existing.value, candidate.value)) return true;
        }
        return false;
    }

    fn take(self: *Builder, allocator: std.mem.Allocator) ![]editor_completion.Candidate {
        editor_completion.sortCandidates(self.candidates.items);
        const candidates = try self.candidates.toOwnedSlice(allocator);
        self.candidates = .empty;
        return candidates;
    }
};

fn applyBuiltCandidates(
    allocator: std.mem.Allocator,
    source: []const u8,
    builder: *Builder,
    analyzed: AnalyzedLine,
) !Application {
    const candidates = try builder.take(allocator);
    defer editor_completion.freeCandidates(allocator, candidates);

    var matches: std.ArrayList(editor_completion.Candidate) = .empty;
    defer matches.deinit(allocator);
    for (candidates) |*candidate| {
        try preparePathCandidateInsert(allocator, candidate, analyzed);
        const query = if (analyzed.literal_query) |literal|
            if (candidate.replace_start == analyzed.replace_start and
                candidate.replace_end == analyzed.replace_end)
                literal.value
            else
                source[candidate.replace_start..candidate.replace_end]
        else
            source[candidate.replace_start..candidate.replace_end];
        if (editor_completion.candidateMatchRank(candidate.*, query, .prefixOnly()) != null) {
            try matches.append(allocator, candidate.*);
        }
    }
    return editor_completion.applyCandidates(allocator, matches.items);
}

fn preparePathCandidateInsert(
    allocator: std.mem.Allocator,
    candidate: *editor_completion.Candidate,
    analyzed: AnalyzedLine,
) error{OutOfMemory}!void {
    if (candidate.insert != null or (candidate.kind != .file and candidate.kind != .directory)) return;

    const escaped_value: ?[]const u8 = if (analyzed.literal_prefix) |literal|
        if (literal.open_quote) |style|
            try shell.word_quoting.quote(allocator, candidate.value, style, .{
                .close = candidate.kind != .directory or candidate.suffix != null,
            })
        else
            try shell.word_quoting.escapeIfNeeded(allocator, candidate.value, .{
                .preserve_leading_tilde = literal.expands_leading_tilde,
            })
    else
        try shell.word_quoting.escapeIfNeeded(allocator, candidate.value, .{});
    const owned_value = escaped_value orelse return;

    if (candidate.suffix) |suffix| {
        defer allocator.free(owned_value);
        candidate.insert = try std.mem.concat(allocator, u8, &.{ owned_value, suffix });
    } else {
        candidate.insert = owned_value;
    }
}

fn completeFromManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    sh: anytype,
    builder: *Builder,
    analyzed: *AnalyzedLine,
    root: []const u8,
) !?bool {
    const manifest_path = try findCompletionFile(allocator, sh, root, ".json") orelse return null;
    defer allocator.free(manifest_path);
    const companion_path = try findCompletionFile(allocator, sh, root, ".rush");
    defer if (companion_path) |path| allocator.free(path);

    const contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        allocator,
        .limited(max_manifest_bytes),
    ) catch return null;
    defer allocator.free(contents);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return null;
    defer parsed.deinit();
    const command = jsonObjectField(parsed.value, "command") orelse return null;
    const providers = jsonObjectField(command, "providers");

    const command_word_index = analyzed.command_word_index orelse return null;
    const current_relative_word_index = if (analyzed.current_word_index) |index|
        if (index > command_word_index) index - command_word_index - 1 else 0
    else
        null;
    const command_path = manifest.selectedCommandPath(
        command,
        analyzed.words[command_word_index + 1 ..],
        current_relative_word_index,
        providers,
    );
    const current = command_path.command();
    const semantic = manifest.semanticContext(
        analyzed.words,
        analyzed.current_word_index,
        analyzed.prefix,
        command_word_index,
        command,
    );

    if (semantic.complete_options) {
        try appendOptionCandidates(
            allocator,
            builder,
            command_path.commands(),
            analyzed.replace_start,
            analyzed.replace_end,
        );
        try appendOptionProviderCandidates(
            allocator,
            io,
            sh,
            builder,
            analyzed.*,
            semantic,
            command_path.commands(),
            command,
            current,
            providers,
            companion_path,
        );
        return true;
    }

    if (semantic.option_value_provider) |provider| {
        if (semantic.attached_option_value_offset) |offset| {
            try selectAttachedOptionValue(allocator, analyzed, offset);
        }
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try appendProviderCandidates(
            allocator,
            io,
            sh,
            builder,
            analyzed.*,
            semantic,
            command,
            current,
            providers,
            provider,
            companion_path,
        );
        return true;
    }

    if (semantic.complete_subcommands) {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try appendSubcommandCandidates(allocator, builder, current, providers, analyzed.replace_start, analyzed.replace_end);
        if (jsonArrayField(current, "dynamicSubcommands")) |provider_refs| {
            for (provider_refs.items) |provider_ref| {
                try appendProviderCandidates(
                    allocator,
                    io,
                    sh,
                    builder,
                    analyzed.*,
                    semantic,
                    command,
                    current,
                    providers,
                    provider_ref,
                    companion_path,
                );
            }
        }
        return true;
    }

    if (manifest.argumentProvider(current, semantic.operand_index)) |provider| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try appendProviderCandidates(
            allocator,
            io,
            sh,
            builder,
            analyzed.*,
            semantic,
            command,
            current,
            providers,
            provider,
            companion_path,
        );
        return true;
    }
    return false;
}

fn appendOptionCandidates(
    allocator: std.mem.Allocator,
    builder: *Builder,
    command_path: []const std.json.Value,
    replace_start: usize,
    replace_end: usize,
) !void {
    var command_index = command_path.len;
    while (command_index > 0) {
        command_index -= 1;
        const options = jsonArrayField(command_path[command_index], "options") orelse continue;
        for (options.items) |option| {
            if (command_index + 1 != command_path.len and !(jsonBoolField(option, "inherit") orelse true)) continue;
            try appendOptionCandidate(allocator, builder, option, replace_start, replace_end);
        }
    }
}

fn appendOptionProviderCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    sh: anytype,
    builder: *Builder,
    analyzed: AnalyzedLine,
    semantic: manifest.Semantic,
    command_path: []const std.json.Value,
    root_command: std.json.Value,
    command: std.json.Value,
    providers: ?std.json.Value,
    companion_path: ?[]const u8,
) !void {
    var command_index = command_path.len;
    while (command_index > 0) {
        command_index -= 1;
        const options = jsonArrayField(command_path[command_index], "options") orelse continue;
        for (options.items) |option| {
            if (command_index + 1 != command_path.len and !(jsonBoolField(option, "inherit") orelse true)) continue;
            const provider = jsonField(option, "provider") orelse continue;
            try appendProviderCandidates(
                allocator,
                io,
                sh,
                builder,
                analyzed,
                semantic,
                root_command,
                command,
                providers,
                provider,
                companion_path,
            );
        }
    }
}

fn appendOptionCandidate(
    allocator: std.mem.Allocator,
    builder: *Builder,
    option: std.json.Value,
    replace_start: usize,
    replace_end: usize,
) !void {
    const object = jsonObject(option) orelse return;
    if (object.get("provider")) |_| return;
    const description = jsonStringField(option, "description");
    const priority = jsonI8Field(option, "priority") orelse 0;
    if (jsonStringField(option, "long")) |long| {
        const value = try std.fmt.allocPrint(allocator, "--{s}", .{long});
        defer allocator.free(value);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try builder.append(allocator, .{ .value = value, .description = description, .kind = .option, .priority = priority, .replace_start = replace_start, .replace_end = replace_end });
    }
    if (jsonStringField(option, "short")) |short| {
        const value = try std.fmt.allocPrint(allocator, "-{s}", .{short});
        defer allocator.free(value);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try builder.append(allocator, .{ .value = value, .description = description, .kind = .option, .priority = priority, .replace_start = replace_start, .replace_end = replace_end });
    }
    if (jsonArrayField(option, "spellings")) |spellings| {
        for (spellings.items) |spelling_value| {
            const spelling = jsonString(spelling_value) orelse continue;
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            try builder.append(allocator, .{ .value = spelling, .description = description, .kind = .option, .priority = priority, .replace_start = replace_start, .replace_end = replace_end });
        }
    }
}

fn appendSubcommandCandidates(
    allocator: std.mem.Allocator,
    builder: *Builder,
    command: std.json.Value,
    providers: ?std.json.Value,
    replace_start: usize,
    replace_end: usize,
) !void {
    const subcommands = jsonArrayField(command, "subcommands") orelse return;
    for (subcommands.items) |subcommand| {
        if (jsonObjectField(subcommand, "provider")) |provider| {
            _ = provider;
            _ = providers;
            continue;
        }
        const name = manifest.commandName(subcommand) orelse continue;
        try builder.append(allocator, .{
            .value = name,
            .description = jsonStringField(subcommand, "description"),
            .kind = .subcommand,
            .priority = jsonI8Field(subcommand, "priority") orelse 0,
            .replace_start = replace_start,
            .replace_end = replace_end,
        });
    }
}

fn appendProviderCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    sh: anytype,
    builder: *Builder,
    analyzed: AnalyzedLine,
    semantic: manifest.Semantic,
    root_command: std.json.Value,
    command: std.json.Value,
    providers: ?std.json.Value,
    provider_ref: std.json.Value,
    companion_path: ?[]const u8,
) !void {
    if (jsonArray(provider_ref)) |provider_refs| {
        for (provider_refs.items) |item| {
            try appendProviderCandidates(
                allocator,
                io,
                sh,
                builder,
                analyzed,
                semantic,
                root_command,
                command,
                providers,
                item,
                companion_path,
            );
        }
        return;
    }
    if (providerValue(providers, provider_ref)) |provider| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        if (jsonStringField(provider, "builtin")) |name| return appendBuiltinProvider(allocator, builder, sh, analyzed, name);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        if (jsonArrayField(provider, "values")) |values| return appendStaticValues(allocator, builder, analyzed, values);
        if (jsonStringField(provider, "function")) |function_name| {
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            return appendFunctionProvider(
                allocator,
                io,
                sh,
                builder,
                analyzed,
                semantic,
                root_command,
                function_name,
                companion_path,
            );
        }
    } else if (jsonString(provider_ref)) |builtin_name| {
        if (std.mem.startsWith(u8, builtin_name, "builtin.")) {
            return appendBuiltinProvider(allocator, builder, sh, analyzed, builtin_name["builtin.".len..]);
        }
    }
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendBuiltinProvider(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, analyzed: AnalyzedLine, name: []const u8) !void {
    if (std.mem.eql(u8, name, "files")) {
        const literal = analyzed.literal_prefix orelse return;
        return appendPathCandidates(
            allocator,
            builder,
            sh,
            literal.value,
            literal.expands_leading_tilde,
            analyzed.replace_start,
            analyzed.replace_end,
            false,
        );
    }
    if (std.mem.eql(u8, name, "directories")) {
        const literal = analyzed.literal_prefix orelse return;
        return appendPathCandidates(
            allocator,
            builder,
            sh,
            literal.value,
            literal.expands_leading_tilde,
            analyzed.replace_start,
            analyzed.replace_end,
            true,
        );
    }
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (std.mem.eql(u8, name, "executables")) return appendPathExecutableCandidates(allocator, builder, sh, analyzed.replace_start, analyzed.replace_end);
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (std.mem.eql(u8, name, "variables")) return appendVariableCandidates(allocator, builder, sh, analyzed.replace_start, analyzed.replace_end);
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (std.mem.eql(u8, name, "aliases")) return appendAliasCandidates(allocator, builder, sh, analyzed.replace_start, analyzed.replace_end);
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (std.mem.eql(u8, name, "functions")) return appendFunctionCandidates(allocator, builder, sh, analyzed.replace_start, analyzed.replace_end);
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (std.mem.eql(u8, name, "jobs")) return appendJobCandidates(allocator, builder, sh, analyzed.replace_start, analyzed.replace_end);
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendStaticValues(allocator: std.mem.Allocator, builder: *Builder, analyzed: AnalyzedLine, values: std.json.Array) !void {
    for (values.items) |value| {
        if (jsonString(value)) |text| {
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            try builder.append(allocator, .{ .value = text, .replace_start = analyzed.replace_start, .replace_end = analyzed.replace_end });
            continue;
        }
        const text = jsonStringField(value, "value") orelse continue;
        try builder.append(allocator, .{
            .value = text,
            .display = jsonStringField(value, "display"),
            .description = jsonStringField(value, "description"),
            .tag = jsonStringField(value, "tag"),
            .suffix = jsonStringField(value, "suffix"),
            .removable_suffix = jsonBoolField(value, "removableSuffix") orelse false,
            .priority = jsonI8Field(value, "priority") orelse 0,
            .append_space = !(jsonBoolField(value, "noSpace") orelse false),
            .replace_start = analyzed.replace_start,
            .replace_end = analyzed.replace_end,
        });
    }
}

const CandidateChannel = struct {
    fd: host.Fd,

    fn init(allocator: std.mem.Allocator, io: std.Io, real_host: *host.RealHost) !CandidateChannel {
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            var random: u64 = undefined;
            io.random(std.mem.asBytes(&random));
            const path = try std.fmt.allocPrintSentinel(
                allocator,
                "/tmp/rush-completion-{x}.jsonl",
                .{random},
                0,
            );
            const opened_fd = real_host.openZ(path, .{
                .access = .read_write,
                .create = true,
                .append = true,
                .exclusive = true,
                .mode = 0o600,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(path);
                    continue;
                },
                else => {
                    allocator.free(path);
                    return err;
                },
            };
            const fd = real_host.duplicateAtLeast(opened_fd, 3) catch |err| {
                // ziglint-ignore: Z026 best-effort cleanup while returning the primary error
                real_host.close(opened_fd) catch {};
                // ziglint-ignore: Z026 best-effort cleanup while returning the primary error
                real_host.deleteFileZ(path) catch {};
                allocator.free(path);
                return err;
            };
            real_host.close(opened_fd) catch {
                // ziglint-ignore: Z026 best-effort cleanup while returning the close error
                real_host.close(fd) catch {};
                // ziglint-ignore: Z026 best-effort cleanup while returning the close error
                real_host.deleteFileZ(path) catch {};
                allocator.free(path);
                return error.Unexpected;
            };
            real_host.deleteFileZ(path) catch {
                // ziglint-ignore: Z026 best-effort cleanup while returning the unlink error
                real_host.close(fd) catch {};
                allocator.free(path);
                return error.Unexpected;
            };
            allocator.free(path);
            return .{ .fd = fd };
        }
        return error.PathAlreadyExists;
    }

    fn deinit(self: *CandidateChannel, real_host: *host.RealHost) void {
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve primary completion result
        real_host.close(self.fd) catch {};
        self.* = undefined;
    }
};

test "candidate channel never occupies a standard descriptor" {
    var real_host: host.RealHost = .{};
    const saved_stdin = try real_host.duplicate(.stdin);
    defer {
        real_host.duplicateTo(saved_stdin, .stdin) catch unreachable;
        real_host.close(saved_stdin) catch unreachable;
    }
    try real_host.close(.stdin);

    var channel = try CandidateChannel.init(std.testing.allocator, std.testing.io, &real_host);
    defer channel.deinit(&real_host);
    try std.testing.expect(channel.fd.raw() >= 3);
}

fn appendFunctionProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    sh: anytype,
    builder: *Builder,
    analyzed: AnalyzedLine,
    semantic: manifest.Semantic,
    root_command: std.json.Value,
    function_name: []const u8,
    companion_path: ?[]const u8,
) !void {
    try sh.state.pushVariableSnapshot();
    defer sh.state.popVariableSnapshot();

    if (companion_path) |path| try sourceCompanionIfNeeded(allocator, io, sh, path);

    const parsed_options = try parsedOptionsForProvider(allocator, analyzed, root_command);
    defer allocator.free(parsed_options);
    const operands = try operandsForProvider(allocator, analyzed, root_command);
    defer allocator.free(operands);
    const provider_prefix = if (analyzed.literal_prefix) |literal| literal.value else analyzed.prefix;
    var provider_context = extensions.rush.CompletionContext.init(
        allocator,
        provider_prefix,
        if (analyzed.literal_prefix) |literal| literal.expands_leading_tilde else false,
        analyzed.replace_start,
        analyzed.replace_end,
        semantic.operand_index,
        semantic.options_terminated,
        if (semantic.option_value_provider != null) "value" else "item",
        parsed_options,
        operands,
    );
    defer provider_context.deinit();
    var candidate_channel = try CandidateChannel.init(allocator, io, &sh.host);
    defer candidate_channel.deinit(&sh.host);
    provider_context.candidate_fd = candidate_channel.fd;

    const previous_context = sh.extensions.completion_context;
    sh.extensions.completion_context = &provider_context;
    defer sh.extensions.completion_context = previous_context;

    const argument_index = try std.fmt.allocPrint(allocator, "{d}", .{semantic.operand_index});
    defer allocator.free(argument_index);
    sh.state.removeVariable("rush_completion_prefix");
    sh.state.removeVariable("rush_completion_argument_index");
    sh.state.removeVariable("rush_completion_options_terminated");
    sh.state.removeVariable("rush_completion_value_position");
    try sh.state.putVariable(.{ .name = "rush_completion_prefix", .value = provider_prefix });
    try sh.state.putVariable(.{ .name = "rush_completion_argument_index", .value = argument_index });
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    try sh.state.putVariable(.{ .name = "rush_completion_options_terminated", .value = if (semantic.options_terminated) "true" else "false" });
    try sh.state.putVariable(.{ .name = "rush_completion_value_position", .value = provider_context.value_position });

    var discard = OutputDiscard.init(&sh.host) catch null;
    defer if (discard) |*active| active.restore(&sh.host) catch {};
    const src: shell.source.Source = .{ .id = 0, .kind = .command_string, .name = "completion", .text = function_name };
    const evaluated = sh.evalSourceNested(src) catch return;
    if (evaluated.status != 0 or evaluated.flow != .normal) return;

    try sh.host.seekTo(candidate_channel.fd, 0);
    try appendCandidateChannel(allocator, sh, builder, analyzed, candidate_channel.fd);

    const candidates = try provider_context.takeCandidates();
    defer editor_completion.freeCandidates(allocator, candidates);
    for (candidates) |candidate| try builder.append(allocator, candidate);
}

fn appendCandidateChannel(
    allocator: std.mem.Allocator,
    sh: anytype,
    builder: *Builder,
    analyzed: AnalyzedLine,
    fd: host.Fd,
) !void {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_len = try sh.host.read(fd, &buffer);
        if (read_len == 0) break;
        try input.appendSlice(allocator, buffer[0..read_len]);
    }

    var lines = std.mem.splitScalar(u8, input.items, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(extensions.rush.CompletionCandidateWire, allocator, line, .{});
        defer parsed.deinit();
        const wire = parsed.value;
        try builder.append(allocator, .{
            .value = wire.value,
            .display = wire.display,
            .insert = wire.insert,
            .description = wire.description,
            .tag = wire.tag,
            .suffix = wire.suffix,
            .removable_suffix = wire.removable_suffix,
            .priority = wire.priority,
            .kind = wire.kind,
            .replace_start = analyzed.replace_start,
            .replace_end = analyzed.replace_end,
            .append_space = wire.append_space,
        });
    }
}

fn parsedOptionsForProvider(
    allocator: std.mem.Allocator,
    analyzed: AnalyzedLine,
    root_command: std.json.Value,
) ![]extensions.rush.CompletionParsedOption {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const command_index = analyzed.command_word_index orelse return allocator.alloc(extensions.rush.CompletionParsedOption, 0);
    var options: std.ArrayList(extensions.rush.CompletionParsedOption) = .empty;
    errdefer options.deinit(allocator);
    var pending_index: ?usize = null;
    var pending_values: usize = 0;
    var options_terminated = false;
    var command = root_command;
    var command_path: [16]std.json.Value = undefined;
    command_path[0] = command;
    var command_path_len: usize = 1;
    const current_word_index = analyzed.current_word_index orelse analyzed.words.len;
    for (analyzed.words[command_index + 1 ..], command_index + 1..) |word, absolute_index| {
        if (absolute_index >= current_word_index) break;
        if (word.redirection_target) continue;
        if (pending_index) |index| {
            if (options.items[index].value == null) {
                options.items[index].value = word.text;
            } else {
                const option = options.items[index];
                try options.append(allocator, .{
                    .spelling = option.spelling,
                    .name = option.name,
                    .key = option.key,
                    .value = word.text,
                });
            }
            pending_values -= 1;
            if (pending_values == 0) pending_index = null;
            continue;
        }
        if (std.mem.eql(u8, word.text, "--")) {
            options_terminated = true;
            continue;
        }
        if (!options_terminated and std.mem.startsWith(u8, word.text, "-")) {
            const parsed = manifest.optionTokenForContext(command_path[0..command_path_len], word.text) orelse continue;
            const name = optionName(parsed.option, word.text);
            try options.append(allocator, .{
                .spelling = word.text,
                .name = name,
                .key = name,
                .value = parsed.value,
            });
            const consumed_values: usize = if (parsed.value != null) 1 else 0;
            pending_values = manifest.optionValueCount(parsed.option) - consumed_values;
            if (pending_values != 0) {
                pending_index = options.items.len - 1;
            }
            continue;
        }
        if (!options_terminated) {
            if (manifest.subcommandForName(command, null, word.text)) |subcommand| {
                command = subcommand;
                if (command_path_len == command_path.len) break;
                command_path[command_path_len] = command;
                command_path_len += 1;
            }
        }
    }
    return options.toOwnedSlice(allocator);
}

fn operandsForProvider(
    allocator: std.mem.Allocator,
    analyzed: AnalyzedLine,
    root_command: std.json.Value,
) ![]extensions.rush.CompletionParsedOperand {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const command_index = analyzed.command_word_index orelse return allocator.alloc(extensions.rush.CompletionParsedOperand, 0);
    var operands: std.ArrayList(extensions.rush.CompletionParsedOperand) = .empty;
    errdefer operands.deinit(allocator);
    var operand_index: usize = 0;
    var pending_option_values: usize = 0;
    var options_terminated = false;
    var command = root_command;
    var command_path: [16]std.json.Value = undefined;
    command_path[0] = command;
    var command_path_len: usize = 1;
    const current_word_index = analyzed.current_word_index orelse analyzed.words.len;
    for (analyzed.words[command_index + 1 ..], command_index + 1..) |word, absolute_index| {
        if (absolute_index >= current_word_index) break;
        if (word.redirection_target) continue;
        if (pending_option_values != 0) {
            pending_option_values -= 1;
            continue;
        }
        if (std.mem.eql(u8, word.text, "--")) {
            options_terminated = true;
            continue;
        }
        if (!options_terminated and std.mem.startsWith(u8, word.text, "-")) {
            if (manifest.optionTokenForContext(command_path[0..command_path_len], word.text)) |parsed| {
                const consumed_values: usize = if (parsed.value != null) 1 else 0;
                pending_option_values = manifest.optionValueCount(parsed.option) - consumed_values;
            }
            continue;
        }
        if (!options_terminated) {
            if (manifest.subcommandForName(command, null, word.text)) |subcommand| {
                command = subcommand;
                if (command_path_len == command_path.len) break;
                command_path[command_path_len] = command;
                command_path_len += 1;
                operands.clearRetainingCapacity();
                operand_index = 0;
                continue;
            }
        }
        try operands.append(allocator, .{ .value = word.text, .index = operand_index });
        operand_index += 1;
    }
    return operands.toOwnedSlice(allocator);
}

fn optionName(option: std.json.Value, spelling: []const u8) []const u8 {
    if (jsonStringField(option, "long")) |long| return long;
    if (jsonStringField(option, "short")) |short| return short;
    return spelling;
}

fn sourceCompanionIfNeeded(allocator: std.mem.Allocator, io: std.Io, sh: anytype, path: []const u8) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes)) catch return;
    defer allocator.free(text);
    const src: shell.source.Source = .{ .id = 0, .kind = .sourced_file, .name = path, .text = text };
    _ = sh.evalSourceNested(src) catch return;
}

fn providerValue(providers: ?std.json.Value, ref: std.json.Value) ?std.json.Value {
    if (jsonString(ref)) |name| {
        const provider_object = providers orelse return null;
        return jsonField(provider_object, name);
    }
    return ref;
}

fn findCompletionFile(allocator: std.mem.Allocator, sh: anytype, root: []const u8, extension: []const u8) !?[]const u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root, extension });
    defer allocator.free(file_name);
    if (try findCompletionFileUnder(allocator, sh, "share", file_name)) |path| return path;
    if (shellValue(sh, "XDG_CONFIG_HOME")) |xdg_config_home| {
        if (xdg_config_home.len != 0) {
            if (try findCompletionFileUnder(allocator, sh, xdg_config_home, file_name)) |path| return path;
        }
    }
    if (shellValue(sh, "HOME")) |home| {
        if (home.len != 0) {
            const config_home = try std.fs.path.join(allocator, &.{ home, ".config" });
            defer allocator.free(config_home);
            if (try findCompletionFileUnder(allocator, sh, config_home, file_name)) |path| return path;
        }
    }
    const xdg_data_home = shellValue(sh, "XDG_DATA_HOME");
    if (xdg_data_home) |data_home| {
        if (data_home.len != 0) {
            if (try findCompletionFileUnder(allocator, sh, data_home, file_name)) |path| return path;
        }
    }
    if (xdg_data_home == null or xdg_data_home.?.len == 0) {
        if (shellValue(sh, "HOME")) |home| {
            if (home.len != 0) {
                const data_home = try std.fs.path.join(allocator, &.{ home, ".local", "share" });
                defer allocator.free(data_home);
                if (try findCompletionFileUnder(allocator, sh, data_home, file_name)) |path| return path;
            }
        }
    }
    const data_dirs = shellValue(sh, "XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var parts = std.mem.splitScalar(u8, data_dirs, ':');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (try findCompletionFileUnder(allocator, sh, part, file_name)) |path| return path;
    }
    if (try findCompletionFileUnder(allocator, sh, build_config.datadir, file_name)) |path| return path;
    return null;
}

fn findCompletionFileUnder(
    allocator: std.mem.Allocator,
    sh: anytype,
    data_dir: []const u8,
    file_name: []const u8,
) !?[]const u8 {
    const path = try std.fs.path.join(allocator, &.{ data_dir, "rush", "completions", file_name });
    if (try fileExists(sh, path)) return path;
    allocator.free(path);
    return null;
}

fn fileExists(sh: anytype, path: []const u8) !bool {
    const path_z = try sh.allocator.dupeZ(u8, path);
    defer sh.allocator.free(path_z);
    return sh.host.existsZ(path_z);
}

test "completion files use the XDG user data fallback" {
    const TestState = struct {
        const Self = @This();

        fn getVariable(_: Self, name: []const u8) ?shell.state.Variable {
            if (std.mem.eql(u8, name, "HOME")) return .{ .name = "HOME", .value = "/home/alice" };
            if (std.mem.eql(u8, name, "XDG_DATA_DIRS")) {
                return .{ .name = "XDG_DATA_DIRS", .value = "/usr/local/share:/usr/share" };
            }
            return null;
        }
    };
    const TestHost = struct {
        const Self = @This();

        fn existsZ(_: Self, path: [:0]const u8) bool {
            return std.mem.eql(u8, path, "/home/alice/.local/share/rush/completions/open.json");
        }
    };
    const TestShell = struct {
        allocator: std.mem.Allocator,
        host: TestHost = .{},
        state: TestState = .{},
        env: []const [*:0]const u8 = &.{},
    };

    var sh: TestShell = .{ .allocator = std.testing.allocator };
    const path = (try findCompletionFile(std.testing.allocator, &sh, "open", ".json")).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/alice/.local/share/rush/completions/open.json", path);
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendCommandCandidates(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, replace_start: usize, replace_end: usize) !void {
    try appendAliasCandidates(allocator, builder, sh, replace_start, replace_end);
    try appendFunctionCandidates(allocator, builder, sh, replace_start, replace_end);
    inline for (core_completion_builtin_names) |name| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try builder.append(allocator, .{ .value = name, .kind = .builtin, .replace_start = replace_start, .replace_end = replace_end });
    }
    inline for (extensions.rush.definitions) |definition| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try builder.append(allocator, .{ .value = definition.name, .kind = .builtin, .replace_start = replace_start, .replace_end = replace_end });
    }
    try appendPathExecutableCandidates(allocator, builder, sh, replace_start, replace_end);
}

const core_completion_builtin_names = [_][]const u8{
    "[",
    "alias",
    "bg",
    "break",
    "cd",
    ":",
    ".",
    "command",
    "continue",
    "eval",
    "exec",
    "export",
    "exit",
    "false",
    "fg",
    "getopts",
    "hash",
    "jobs",
    "kill",
    "local",
    "printf",
    "pwd",
    "read",
    "readonly",
    "return",
    "set",
    "shift",
    "shopt",
    "source",
    "test",
    "times",
    "trap",
    "true",
    "type",
    "ulimit",
    "umask",
    "unalias",
    "unset",
    "wait",
};

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendAliasCandidates(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, replace_start: usize, replace_end: usize) !void {
    var iterator = sh.state.aliases.iterator();
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    while (iterator.next()) |entry| try builder.append(allocator, .{ .value = entry.key_ptr.*, .kind = .command, .description = "alias", .replace_start = replace_start, .replace_end = replace_end });
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendVariableCandidates(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, replace_start: usize, replace_end: usize) !void {
    var iterator = sh.state.bindings.iterator();
    while (iterator.next()) |entry| {
        const variable = entry.value_ptr.variable() orelse continue;
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try builder.append(allocator, .{ .value = variable.name, .kind = .variable, .replace_start = replace_start, .replace_end = replace_end, .append_space = false });
    }
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendFunctionCandidates(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, replace_start: usize, replace_end: usize) !void {
    var iterator = sh.state.functions.iterator();
    while (iterator.next()) |entry| {
        if (!sh.state.isFunctionAutoloadSuppressed(entry.key_ptr.*)) {
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            try builder.append(allocator, .{ .value = entry.key_ptr.*, .kind = .function, .description = "function", .replace_start = replace_start, .replace_end = replace_end });
        }
    }
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendJobCandidates(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, replace_start: usize, replace_end: usize) !void {
    for (sh.state.background_jobs.items) |job| {
        const value = try std.fmt.allocPrint(allocator, "%{d}", .{job.id});
        defer allocator.free(value);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try builder.append(allocator, .{ .value = value, .kind = .plain, .description = "job", .replace_start = replace_start, .replace_end = replace_end });
    }
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendPathExecutableCandidates(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, replace_start: usize, replace_end: usize) !void {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const path_value = if (sh.state.getVariable("PATH")) |variable| variable.value else shellValue(sh, "PATH") orelse return;
    var dirs = std.mem.splitScalar(u8, path_value, ':');
    while (dirs.next()) |raw_dir| {
        const dir = if (raw_dir.len == 0) "." else raw_dir;
        var entries = sh.host.listDir(allocator, dir) catch continue;
        defer entries.deinit();
        for (entries.entries) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (entry.kind == .directory) continue;
            const full_path = try std.fs.path.join(allocator, &.{ dir, entry.name });
            defer allocator.free(full_path);
            const full_path_z = try allocator.dupeZ(u8, full_path);
            defer allocator.free(full_path_z);
            if (!sh.host.fileAccessZ(full_path_z, .execute)) continue;
            const insert = try shell.word_quoting.escapeIfNeeded(allocator, entry.name, .{});
            defer if (insert) |owned| allocator.free(owned);
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            try builder.append(allocator, .{ .value = entry.name, .insert = insert, .kind = .command, .replace_start = replace_start, .replace_end = replace_end });
        }
    }
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendPathCandidates(
    allocator: std.mem.Allocator,
    builder: *Builder,
    sh: anytype,
    prefix: []const u8,
    expand_leading_tilde: bool,
    replace_start: usize,
    replace_end: usize,
    directories_only: bool,
) !void {
    // ziglint-ignore: Z011 deprecated API left unchanged to avoid semantic drift in lint-only pass
    const slash = std.mem.lastIndexOfScalar(u8, prefix, '/');
    const dir_prefix = if (slash) |index| prefix[0 .. index + 1] else "";
    const entry_prefix = if (slash) |index| prefix[index + 1 ..] else prefix;
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const unexpanded_dir_path = if (dir_prefix.len == 0) "." else if (std.mem.eql(u8, dir_prefix, "/")) "/" else std.mem.trimEnd(u8, dir_prefix, "/");
    const dir_path = if (expand_leading_tilde)
        try completion_path.expandLeadingTilde(allocator, unexpanded_dir_path, shellValue(sh, "HOME"))
    else
        try allocator.dupe(u8, unexpanded_dir_path);
    defer allocator.free(dir_path);
    var entries = sh.host.listDir(allocator, dir_path) catch return;
    defer entries.deinit();
    const include_hidden = std.mem.startsWith(u8, entry_prefix, ".");
    for (entries.entries) |entry| {
        if (entry.name.len == 0 or std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (!include_hidden and entry.name[0] == '.') continue;
        const is_directory = try completion_path.pathCandidateIsDirectory(
            allocator,
            sh,
            dir_prefix,
            expand_leading_tilde,
            shellValue(sh, "HOME"),
            entry,
        );
        if (directories_only and !is_directory) continue;
        const value = if (is_directory)
            try std.fmt.allocPrint(allocator, "{s}{s}/", .{ dir_prefix, entry.name })
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_prefix, entry.name });
        defer allocator.free(value);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try builder.append(allocator, .{ .value = value, .display = entry.name, .kind = if (is_directory) .directory else .file, .replace_start = replace_start, .replace_end = replace_end, .append_space = !is_directory });
    }
}

fn shellValue(sh: anytype, name: []const u8) ?[]const u8 {
    if (sh.state.getVariable(name)) |variable| return variable.value;
    for (sh.env) |entry_ptr| {
        const entry = std.mem.span(entry_ptr);
        if (entry.len <= name.len or entry[name.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

fn jsonField(value: std.json.Value, name: []const u8) ?std.json.Value {
    const object = jsonObject(value) orelse return null;
    return object.get(name);
}

fn jsonObjectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    const field = jsonField(value, name) orelse return null;
    _ = jsonObject(field) orelse return null;
    return field;
}

fn jsonArrayField(value: std.json.Value, name: []const u8) ?std.json.Array {
    return jsonArray(jsonField(value, name) orelse return null);
}

fn jsonStringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    return jsonString(jsonField(value, name) orelse return null);
}

fn jsonBoolField(value: std.json.Value, name: []const u8) ?bool {
    return switch (jsonField(value, name) orelse return null) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn jsonI8Field(value: std.json.Value, name: []const u8) ?i8 {
    return switch (jsonField(value, name) orelse return null) {
        .integer => |integer| std.math.cast(i8, integer),
        else => null,
    };
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

const OutputDiscard = struct {
    saved_stdout: host.Fd,
    saved_stderr: host.Fd,
    null_fd: host.Fd,
    active: bool = true,

    fn init(real_host: *host.RealHost) !OutputDiscard {
        const null_fd = try real_host.openZ("/dev/null", .{ .access = .write_only });
        errdefer real_host.close(null_fd) catch {};
        const saved_stdout = try real_host.duplicate(.stdout);
        errdefer real_host.close(saved_stdout) catch {};
        const saved_stderr = try real_host.duplicate(.stderr);
        errdefer real_host.close(saved_stderr) catch {};
        try real_host.duplicateTo(null_fd, .stdout);
        errdefer real_host.duplicateTo(saved_stdout, .stdout) catch {};
        try real_host.duplicateTo(null_fd, .stderr);
        return .{ .saved_stdout = saved_stdout, .saved_stderr = saved_stderr, .null_fd = null_fd };
    }

    fn restore(self: *OutputDiscard, real_host: *host.RealHost) !void {
        if (!self.active) return;
        self.active = false;
        try real_host.duplicateTo(self.saved_stdout, .stdout);
        try real_host.duplicateTo(self.saved_stderr, .stderr);
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        real_host.close(self.saved_stdout) catch {};
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        real_host.close(self.saved_stderr) catch {};
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        real_host.close(self.null_fd) catch {};
    }
};

test "completion analyzes command and argument words" {
    const analyzed = try analyzeLine(std.testing.allocator, "zig bu", "zig bu".len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqualStrings("zig", analyzed.root.?);
    try std.testing.expectEqualStrings("bu", analyzed.prefix);
}

test "completion analyzes command positions after separators" {
    const analyzed = try analyzeLine(std.testing.allocator, "true; zi", "true; zi".len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.command, analyzed.kind);
    try std.testing.expectEqualStrings("zi", analyzed.prefix);
}

test "completion keeps command position after assignment prefixes" {
    const analyzed = try analyzeLine(std.testing.allocator, "FOO=bar ", "FOO=bar ".len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.command, analyzed.kind);
    try std.testing.expectEqualStrings("", analyzed.prefix);
}

test "completion treats redirection targets as arguments" {
    const analyzed = try analyzeLine(std.testing.allocator, "true; > ", "true; > ".len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqual(@as(?[]const u8, null), analyzed.root);
    try std.testing.expect(analyzed.completing_redirection_target);
}

test "completion keeps escaped spaces inside a single word" {
    const line = "cat foo\\ bar";
    const analyzed = try analyzeLine(std.testing.allocator, line, line.len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqualStrings("foo\\ bar", analyzed.prefix);
    try std.testing.expectEqualStrings("cat", analyzed.root.?);
}

test "completion analyzes the inner line of an open command substitution" {
    const line = "echo $(git ch";
    const analyzed = try analyzeLine(std.testing.allocator, line, line.len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqualStrings("git", analyzed.root.?);
    try std.testing.expectEqualStrings("ch", analyzed.prefix);
    try std.testing.expectEqual(@as(usize, "echo $(git ".len), analyzed.replace_start);
    try std.testing.expectEqual(@as(usize, line.len), analyzed.replace_end);
}

test "completion analyzes substitutions opened inside double quotes" {
    const line = "echo \"$(git ch";
    const analyzed = try analyzeLine(std.testing.allocator, line, line.len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqualStrings("git", analyzed.root.?);
    try std.testing.expectEqualStrings("ch", analyzed.prefix);
    try std.testing.expectEqual(@as(usize, "echo \"$(git ".len), analyzed.replace_start);
}

test "completion ignores substitution openers inside single quotes" {
    const line = "echo '$(li";
    const analyzed = try analyzeLine(std.testing.allocator, line, line.len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqualStrings("echo", analyzed.root.?);
    try std.testing.expectEqualStrings("'$(li", analyzed.prefix);
}

test "completion completes commands right after a substitution opener" {
    const line = "echo $(";
    const analyzed = try analyzeLine(std.testing.allocator, line, line.len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.command, analyzed.kind);
    try std.testing.expectEqualStrings("", analyzed.prefix);
}

test "completion ignores closed command substitutions" {
    const line = "echo $(id) ar";
    const analyzed = try analyzeLine(std.testing.allocator, line, line.len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqualStrings("echo", analyzed.root.?);
    try std.testing.expectEqualStrings("ar", analyzed.prefix);
}

test "completion recognizes reserved words as command prefixes" {
    const analyzed = try analyzeLine(std.testing.allocator, "if tr", "if tr".len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.command, analyzed.kind);
    try std.testing.expectEqualStrings("tr", analyzed.prefix);
}

test "completion loads manifest subcommands" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const application = try complete(&sh, std.testing.allocator, std.testing.io, "zig ", "zig ".len);
    defer application.deinit(std.testing.allocator);
    const candidates = switch (application) {
        .ambiguous => |candidates| candidates,
        else => return error.ExpectedSubcommandCandidates,
    };
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, "build")) return;
    }
    return error.ExpectedZigBuildCandidate;
}

test "redirection targets bypass manifest argument completion" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const source = "zig > agents";
    var application = try complete(&sh, std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);
    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedRedirectionPathCompletion,
    };
    try std.testing.expectEqualStrings("AGENTS.md", edit.replacement);
}

test "completion offers inherited options within nested subcommands" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(allocator, "rush-test-inherited-options-{d}", .{std.c.getpid()});
    defer allocator.free(root);
    // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const completions_dir = try std.fs.path.join(allocator, &.{ root, "rush", "completions" });
    defer allocator.free(completions_dir);
    try std.Io.Dir.cwd().createDirPath(io, completions_dir);
    const manifest_path = try std.fs.path.join(allocator, &.{ completions_dir, "nested-options.json" });
    defer allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = manifest_path,
        .data =
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "nested-options",
        \\    "options": [
        \\      { "long": "global" },
        \\      { "long": "root-only", "inherit": false }
        \\    ],
        \\    "subcommands": [ {
        \\      "name": "middle",
        \\      "options": [ { "long": "middle" } ],
        \\      "subcommands": [ {
        \\        "name": "leaf",
        \\        "options": [ { "long": "leaf" } ]
        \\      } ]
        \\    } ]
        \\  }
        \\}
        ,
    });

    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(allocator, .{}, .{});
    defer sh.deinit();
    try sh.state.putVariable(.{ .name = "XDG_DATA_HOME", .value = root });

    const source = "nested-options middle leaf --";
    var application = try complete(&sh, allocator, io, source, source.len);
    defer application.deinit(allocator);
    const candidates = switch (application) {
        .ambiguous => |candidates| candidates,
        else => return error.ExpectedInheritedOptionCandidates,
    };
    var found_global = false;
    var found_middle = false;
    var found_leaf = false;
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, "--global")) found_global = true;
        if (std.mem.eql(u8, candidate.value, "--middle")) found_middle = true;
        if (std.mem.eql(u8, candidate.value, "--leaf")) found_leaf = true;
        try std.testing.expect(!std.mem.eql(u8, candidate.value, "--root-only"));
    }
    try std.testing.expect(found_global);
    try std.testing.expect(found_middle);
    try std.testing.expect(found_leaf);
}

test "completion loads dynamic subcommands from manifest providers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(allocator, "rush-test-completion-{d}", .{std.c.getpid()});
    defer allocator.free(root);
    // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const completions_dir = try std.fs.path.join(allocator, &.{ root, "rush", "completions" });
    defer allocator.free(completions_dir);
    try std.Io.Dir.cwd().createDirPath(io, completions_dir);
    const manifest_path = try std.fs.path.join(allocator, &.{ completions_dir, "rush-test-dynamic.json" });
    defer allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = manifest_path,
        .data =
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "rush-test-dynamic",
        \\    "providers": {
        \\      "commands": { "values": [
        \\        { "value": "generated", "description": "dynamic command" }
        \\      ] }
        \\    },
        \\    "dynamicSubcommands": ["commands"]
        \\  }
        \\}
        ,
    });

    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(allocator, .{}, .{});
    defer sh.deinit();
    try sh.state.putVariable(.{ .name = "XDG_DATA_HOME", .value = root });

    const source = "rush-test-dynamic ";
    var application = try complete(&sh, allocator, io, source, source.len);
    defer application.deinit(allocator);
    const candidates = switch (application) {
        .edit => |edit| {
            try std.testing.expectEqualStrings("generated", edit.replacement);
            return;
        },
        .ambiguous => |candidates| candidates,
        else => return error.ExpectedDynamicSubcommandCandidate,
    };
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, "generated")) return;
    }
    return error.ExpectedDynamicSubcommandCandidate;
}

test "completion companion assignments do not mutate shell variables" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(allocator, "rush-test-companion-state-{d}", .{std.c.getpid()});
    defer allocator.free(root);
    // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const completions_dir = try std.fs.path.join(allocator, &.{ root, "rush", "completions" });
    defer allocator.free(completions_dir);
    try std.Io.Dir.cwd().createDirPath(io, completions_dir);
    const manifest_path = try std.fs.path.join(allocator, &.{ completions_dir, "rush-test-state.json" });
    defer allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = manifest_path,
        .data =
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "rush-test-state",
        \\    "providers": {
        \\      "values": { "function": "__rush_test_state_values" }
        \\    },
        \\    "arguments": { "states": [
        \\      { "name": "value", "index": 0, "provider": "values" }
        \\    ] }
        \\  }
        \\}
        ,
    });
    const companion_path = try std.fs.path.join(allocator, &.{ completions_dir, "rush-test-state.rush" });
    defer allocator.free(companion_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = companion_path,
        .data =
        \\existing=changed
        \\created=leaked
        \\__rush_test_state_values() {
        \\  rush_complete candidate isolated --kind plain
        \\}
        ,
    });

    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(allocator, .{}, .{});
    defer sh.deinit();
    try sh.state.putVariable(.{ .name = "XDG_DATA_HOME", .value = root });
    try sh.state.putVariable(.{ .name = "existing", .value = "original" });

    const source = "rush-test-state ";
    var application = try complete(&sh, allocator, io, source, source.len);
    defer application.deinit(allocator);
    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedCompanionCandidate,
    };
    try std.testing.expectEqualStrings("isolated", edit.replacement);
    try std.testing.expectEqualStrings("original", sh.state.getVariable("existing").?.value);
    try std.testing.expectEqual(null, sh.state.getVariable("created"));
}

test "yay target providers retain candidates from package command output" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const fixture: shell.source.Source = .{
        .id = 0,
        .kind = .command_string,
        .name = "yay completion fixture",
        .text =
        \\pacman() {
        \\  rush_complete candidate producer-stage --kind plain --description producer
        \\  case "$1" in
        \\    -Slq) printf 'available-one\navailable-two\n' ;;
        \\    -Sgq) printf 'group-one\n' ;;
        \\    -Qq) printf 'installed-one\ninstalled-two\n' ;;
        \\  esac
        \\}
        ,
    };
    const evaluated = try sh.evalSourceNested(fixture);
    try std.testing.expectEqual(@as(u8, 0), evaluated.status);

    const cases = [_]struct {
        source: []const u8,
        expected: [3][]const u8,
    }{
        .{ .source = "yay -S ", .expected = .{ "producer-stage", "available-one", "available-two" } },
        .{ .source = "yay -R ", .expected = .{ "producer-stage", "installed-one", "installed-two" } },
    };
    for (cases) |case| {
        var application = try complete(&sh, std.testing.allocator, std.testing.io, case.source, case.source.len);
        defer application.deinit(std.testing.allocator);
        const candidates = switch (application) {
            .ambiguous => |candidates| candidates,
            else => return error.ExpectedYayPackageCandidates,
        };
        for (case.expected) |expected| {
            for (candidates) |candidate| {
                if (std.mem.eql(u8, candidate.value, expected)) break;
            } else return error.ExpectedYayPackageCandidate;
        }
    }
}

test "zmx attach provider retains candidates from session list output" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const fixture: shell.source.Source = .{
        .id = 0,
        .kind = .command_string,
        .name = "zmx completion fixture",
        .text =
        \\zmx() {
        \\  printf 'name=dev\tpid=1\tclients=0\tcreated=0\tcwd=/tmp/dev\n'
        \\  printf 'name=work\tpid=2\tclients=1\tcreated=0\tcwd=/tmp/work\n'
        \\}
        ,
    };
    const evaluated = try sh.evalSourceNested(fixture);
    try std.testing.expectEqual(@as(u8, 0), evaluated.status);

    const source = "zmx attach ";
    var application = try complete(&sh, std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);
    const candidates = switch (application) {
        .ambiguous => |candidates| candidates,
        else => return error.ExpectedZmxSessionCandidates,
    };
    var found_dev = false;
    var found_work = false;
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, "dev")) {
            try std.testing.expectEqualStrings("active session, /tmp/dev", candidate.description.?);
            try std.testing.expectEqual(@as(i8, 20), candidate.priority);
            found_dev = true;
        }
        if (std.mem.eql(u8, candidate.value, "work")) {
            try std.testing.expectEqualStrings("active session, 1 client, /tmp/work", candidate.description.?);
            try std.testing.expectEqual(@as(i8, 30), candidate.priority);
            found_work = true;
        }
    }
    try std.testing.expect(found_dev);
    try std.testing.expect(found_work);
}

test "completion includes dynamic option provider candidates" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    try sh.state.putVariable(.{
        .name = "rush_completion_prefix",
        .value = "original",
        .readonly = true,
    });
    try sh.state.putVariable(.{ .name = "project_option_count", .value = "original" });

    const source = "zig build -Doptimize=";
    var application = try complete(&sh, std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);
    const candidates = switch (application) {
        .ambiguous => |candidates| candidates,
        else => return error.ExpectedDynamicOptionCandidates,
    };
    var found_release_safe = false;
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, "-Doptimize=ReleaseSafe")) {
            try std.testing.expectEqual(editor_completion.Kind.option, candidate.kind);
            try std.testing.expectEqualStrings("safe release build", candidate.description.?);
            found_release_safe = true;
        }
    }
    try std.testing.expect(found_release_safe);
    try std.testing.expectEqualStrings("original", sh.state.getVariable("rush_completion_prefix").?.value);
    try std.testing.expect(sh.state.getVariable("rush_completion_prefix").?.readonly);
    try std.testing.expectEqualStrings("original", sh.state.getVariable("project_option_count").?.value);
    try std.testing.expectEqual(@as(?shell.state.Variable, null), sh.state.getVariable("tmp"));
    try std.testing.expectEqual(@as(?shell.state.Variable, null), sh.state.getVariable("in_project_options"));
}

test "completion provides values attached to a long option" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const source = "zig build --color=o";
    var application = try complete(&sh, std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);
    const candidates = switch (application) {
        .ambiguous => |candidates| candidates,
        else => return error.ExpectedAttachedOptionValueCandidates,
    };
    var found_off = false;
    var found_on = false;
    for (candidates) |candidate| {
        try std.testing.expectEqual(@as(usize, "zig build --color=".len), candidate.replace_start);
        if (std.mem.eql(u8, candidate.value, "off")) found_off = true;
        if (std.mem.eql(u8, candidate.value, "on")) found_on = true;
    }
    try std.testing.expect(found_off);
    try std.testing.expect(found_on);
}

test "provider context preserves root options before a subcommand" {
    const manifest_text =
        \\{
        \\  "name": "tool",
        \\  "options": [
        \\    { "long": "user", "inherit": false },
        \\    { "long": "host", "inherit": false, "value": { "name": "host" } }
        \\  ],
        \\  "subcommands": [
        \\    { "name": "stop", "arguments": { "states": [
        \\      { "name": "unit", "index": 0, "repeatable": true }
        \\    ] } }
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, manifest_text, .{});
    defer parsed.deinit();

    const source = "tool --user --host example stop alpha ";
    const analyzed = try analyzeLine(std.testing.allocator, source, source.len);
    defer analyzed.deinit(std.testing.allocator);

    const semantic = manifest.semanticContext(
        analyzed.words,
        analyzed.current_word_index,
        analyzed.prefix,
        analyzed.command_word_index.?,
        parsed.value,
    );
    try std.testing.expectEqual(@as(usize, 1), semantic.operand_index);

    const options = try parsedOptionsForProvider(std.testing.allocator, analyzed, parsed.value);
    defer std.testing.allocator.free(options);
    try std.testing.expectEqual(@as(usize, 2), options.len);
    try std.testing.expectEqualStrings("user", options[0].name);
    try std.testing.expectEqualStrings("host", options[1].name);
    try std.testing.expectEqualStrings("example", options[1].value.?);

    const operands = try operandsForProvider(std.testing.allocator, analyzed, parsed.value);
    defer std.testing.allocator.free(operands);
    try std.testing.expectEqual(@as(usize, 1), operands.len);
    try std.testing.expectEqualStrings("alpha", operands[0].value);
    try std.testing.expectEqual(@as(usize, 0), operands[0].index);
}

test "manifest selection accepts attached root option values before a subcommand" {
    const manifest_text =
        \\{
        \\  "name": "tool",
        \\  "options": [
        \\    { "long": "host", "value": { "name": "host" } }
        \\  ],
        \\  "subcommands": [ { "name": "stop" } ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, manifest_text, .{});
    defer parsed.deinit();

    const source = "tool --host=example stop ";
    const analyzed = try analyzeLine(std.testing.allocator, source, source.len);
    defer analyzed.deinit(std.testing.allocator);
    const words = analyzed.words[analyzed.command_word_index.? + 1 ..];
    const current = manifest.selectedCommand(parsed.value, words, null, null).?;
    try std.testing.expectEqualStrings("stop", manifest.commandName(current).?);

    const options = try parsedOptionsForProvider(std.testing.allocator, analyzed, parsed.value);
    defer std.testing.allocator.free(options);
    try std.testing.expectEqual(@as(usize, 1), options.len);
    try std.testing.expectEqualStrings("example", options[0].value.?);
}

test "completion semantics consume multi-word option values" {
    const manifest_text =
        \\{
        \\  "name": "tool",
        \\  "options": [
        \\    { "long": "pair", "value": [
        \\      { "name": "first", "provider": "first-values" },
        \\      { "name": "second", "provider": "second-values" }
        \\    ] }
        \\  ],
        \\  "subcommands": [ { "name": "run" } ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, manifest_text, .{});
    defer parsed.deinit();

    const pending_source = "tool --pair one >ignored ";
    const pending = try analyzeLine(std.testing.allocator, pending_source, pending_source.len);
    defer pending.deinit(std.testing.allocator);
    const pending_semantic = manifest.semanticContext(
        pending.words,
        pending.current_word_index,
        pending.prefix,
        pending.command_word_index.?,
        parsed.value,
    );
    try std.testing.expectEqualStrings("second-values", pending_semantic.option_value_provider.?.string);

    const source = "tool --pair=one two run argument ";
    const analyzed = try analyzeLine(std.testing.allocator, source, source.len);
    defer analyzed.deinit(std.testing.allocator);
    const words = analyzed.words[analyzed.command_word_index.? + 1 ..];
    const current = manifest.selectedCommand(parsed.value, words, null, null).?;
    try std.testing.expectEqualStrings("run", manifest.commandName(current).?);

    const options = try parsedOptionsForProvider(std.testing.allocator, analyzed, parsed.value);
    defer std.testing.allocator.free(options);
    try std.testing.expectEqual(@as(usize, 2), options.len);
    try std.testing.expectEqualStrings("one", options[0].value.?);
    try std.testing.expectEqualStrings("two", options[1].value.?);

    const operands = try operandsForProvider(std.testing.allocator, analyzed, parsed.value);
    defer std.testing.allocator.free(operands);
    try std.testing.expectEqual(@as(usize, 1), operands.len);
    try std.testing.expectEqualStrings("argument", operands[0].value);
    try std.testing.expectEqual(@as(usize, 0), operands[0].index);
}

test "z completion uses Rush frecent directory history" {
    var command_history = try history.History.init(std.testing.allocator);
    defer command_history.deinit();
    command_history.current_cwd = "/work/mywebsite";
    try command_history.addCommand(std.testing.io, "first", 0, 10, 1);
    try command_history.addCommand(std.testing.io, "second", 0, 20, 1);
    command_history.current_cwd = "/work/web-docs";
    try command_history.addCommand(std.testing.io, "third", 0, 30, 1);
    command_history.current_cwd = "work-web";
    try command_history.addCommand(std.testing.io, "corrupt", 0, 40, 1);

    var history_service = history.InteractiveHistoryService.init(&command_history);
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    sh.setCommandHistory(history_service.commandHistory(std.testing.io));
    try sh.state.putVariable(.{ .name = "PWD", .value = "/work/current" });
    try sh.state.putVariable(.{ .name = "HOME", .value = "/work" });

    const source = "z work web";
    var application = try complete(&sh, std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);
    const candidates = switch (application) {
        .ambiguous => |candidates| candidates,
        else => return error.ExpectedDirectoryHistoryCandidates,
    };

    try std.testing.expect(candidates.len >= 2);
    try std.testing.expectEqualStrings("website", candidates[0].value);
    try std.testing.expectEqualStrings("mywebsite", candidates[0].display.?);
    try std.testing.expectEqualStrings("~/mywebsite", candidates[0].description.?);
    try std.testing.expect(candidates[0].append_space);
    for (candidates) |candidate| {
        if (candidate.display) |display| try std.testing.expect(!std.mem.eql(u8, display, "work-web"));
    }
}

test "completion uses provider arrays from nvim manifest" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const source = "nvim ";
    var application = try complete(&sh, std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);
    const candidates = switch (application) {
        .ambiguous => |candidates| candidates,
        else => return error.ExpectedNvimPathCandidates,
    };

    var saw_file = false;
    var saw_directory = false;
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, "AGENTS.md") and candidate.kind == .file) saw_file = true;
        if (std.mem.eql(u8, candidate.value, "src/") and candidate.kind == .directory) saw_directory = true;
    }
    try std.testing.expect(saw_file);
    try std.testing.expect(saw_directory);
}

test "path completion matches file names case insensitively" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const source = "nvim agents";
    var application = try complete(&sh, std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);

    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedCaseInsensitivePathCompletion,
    };
    try std.testing.expectEqualStrings("AGENTS.md", edit.replacement);
}

test "cd directory completion appends slash without trailing space" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const source = "cd sr";
    var application = try complete(&sh, std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);

    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedCdDirectoryCompletion,
    };
    try std.testing.expectEqualStrings("src/", edit.replacement);
    try std.testing.expect(!edit.append_space);
}

test "path completion follows symlinked directories before appending space" {
    const TestState = struct {
        const Self = @This();

        fn getVariable(_: Self, _: []const u8) ?shell.state.Variable {
            return null;
        }
    };
    const TestHost = struct {
        const Self = @This();

        pub fn listDir(_: *Self, allocator: std.mem.Allocator, path: []const u8) !host.ListDirResult {
            try std.testing.expectEqualStrings(".config", path);
            const entries = try allocator.alloc(host.DirectoryEntry, 1);
            errdefer allocator.free(entries);
            entries[0] = .{ .name = try allocator.dupe(u8, "rush"), .kind = .symlink };
            return .{ .allocator = allocator, .entries = entries };
        }

        pub fn fileTestStatusZ(_: *Self, path: [:0]const u8, follow_symlinks: bool) ?host.FileStatus {
            std.testing.expect(follow_symlinks) catch unreachable;
            std.testing.expectEqualStrings(".config/rush", path) catch unreachable;
            return .{ .kind = .directory };
        }
    };
    const TestShell = struct {
        host: TestHost,
        state: TestState,
        env: []const [*:0]const u8 = &.{},
    };

    const source = "nvim .config/ru";
    const analyzed = try analyzeLine(std.testing.allocator, source, source.len);
    defer analyzed.deinit(std.testing.allocator);
    const literal = analyzed.literal_prefix orelse return error.ExpectedLiteralPath;
    var sh: TestShell = .{ .host = .{}, .state = .{} };
    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);

    try appendPathCandidates(
        std.testing.allocator,
        &builder,
        &sh,
        literal.value,
        literal.expands_leading_tilde,
        analyzed.replace_start,
        analyzed.replace_end,
        false,
    );
    var application = try applyBuiltCandidates(std.testing.allocator, source, &builder, analyzed);
    defer application.deinit(std.testing.allocator);

    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedSingleSymlinkDirectoryCompletion,
    };
    try std.testing.expectEqualStrings(".config/rush/", edit.replacement);
    try std.testing.expect(!edit.append_space);
}

test "path completion treats file and broken symlinks as files" {
    const TestState = struct {
        const Self = @This();

        fn getVariable(_: Self, _: []const u8) ?shell.state.Variable {
            return null;
        }
    };
    const TestHost = struct {
        const Self = @This();

        pub fn listDir(_: *Self, allocator: std.mem.Allocator, path: []const u8) !host.ListDirResult {
            try std.testing.expectEqualStrings(".", path);
            const entries = try allocator.alloc(host.DirectoryEntry, 2);
            errdefer allocator.free(entries);
            entries[0] = .{ .name = try allocator.dupe(u8, "linkfile"), .kind = .symlink };
            entries[1] = .{ .name = try allocator.dupe(u8, "broken"), .kind = .symlink };
            return .{ .allocator = allocator, .entries = entries };
        }

        pub fn fileTestStatusZ(_: *Self, path: [:0]const u8, follow_symlinks: bool) ?host.FileStatus {
            std.testing.expect(follow_symlinks) catch unreachable;
            if (std.mem.eql(u8, path, "linkfile")) return .{ .kind = .file };
            return null;
        }
    };
    const TestShell = struct {
        host: TestHost,
        state: TestState,
        env: []const [*:0]const u8 = &.{},
    };

    const source = "cat linkf";
    const analyzed = try analyzeLine(std.testing.allocator, source, source.len);
    defer analyzed.deinit(std.testing.allocator);
    const literal = analyzed.literal_prefix orelse return error.ExpectedLiteralPath;
    var sh: TestShell = .{ .host = .{}, .state = .{} };
    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);

    try appendPathCandidates(
        std.testing.allocator,
        &builder,
        &sh,
        literal.value,
        literal.expands_leading_tilde,
        analyzed.replace_start,
        analyzed.replace_end,
        false,
    );
    var application = try applyBuiltCandidates(std.testing.allocator, source, &builder, analyzed);
    defer application.deinit(std.testing.allocator);

    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedSingleFileSymlinkCompletion,
    };
    try std.testing.expectEqualStrings("linkfile", edit.replacement);
    try std.testing.expect(edit.append_space);
}

test "directory-only path completion includes symlink directories" {
    const TestState = struct {
        const Self = @This();

        fn getVariable(_: Self, _: []const u8) ?shell.state.Variable {
            return null;
        }
    };
    const TestHost = struct {
        const Self = @This();

        pub fn listDir(_: *Self, allocator: std.mem.Allocator, path: []const u8) !host.ListDirResult {
            try std.testing.expectEqualStrings(".", path);
            const entries = try allocator.alloc(host.DirectoryEntry, 2);
            errdefer allocator.free(entries);
            entries[0] = .{ .name = try allocator.dupe(u8, "linkdir"), .kind = .symlink };
            entries[1] = .{ .name = try allocator.dupe(u8, "linkfile"), .kind = .symlink };
            return .{ .allocator = allocator, .entries = entries };
        }

        pub fn fileTestStatusZ(_: *Self, path: [:0]const u8, follow_symlinks: bool) ?host.FileStatus {
            std.testing.expect(follow_symlinks) catch unreachable;
            if (std.mem.eql(u8, path, "linkdir")) return .{ .kind = .directory };
            if (std.mem.eql(u8, path, "linkfile")) return .{ .kind = .file };
            return null;
        }
    };
    const TestShell = struct {
        host: TestHost,
        state: TestState,
        env: []const [*:0]const u8 = &.{},
    };

    const source = "cd link";
    const analyzed = try analyzeLine(std.testing.allocator, source, source.len);
    defer analyzed.deinit(std.testing.allocator);
    const literal = analyzed.literal_prefix orelse return error.ExpectedLiteralPath;
    var sh: TestShell = .{ .host = .{}, .state = .{} };
    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);

    try appendPathCandidates(
        std.testing.allocator,
        &builder,
        &sh,
        literal.value,
        literal.expands_leading_tilde,
        analyzed.replace_start,
        analyzed.replace_end,
        true,
    );
    var application = try applyBuiltCandidates(std.testing.allocator, source, &builder, analyzed);
    defer application.deinit(std.testing.allocator);

    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedSingleSymlinkDirectoryCompletion,
    };
    try std.testing.expectEqualStrings("linkdir/", edit.replacement);
    try std.testing.expect(!edit.append_space);
}

test "path completion expands tilde for lookup and preserves it in candidates" {
    const TestState = struct {
        const Self = @This();

        fn getVariable(_: Self, name: []const u8) ?shell.state.Variable {
            if (!std.mem.eql(u8, name, "HOME")) return null;
            return .{ .name = "HOME", .value = "/home/alice" };
        }
    };
    const TestHost = struct {
        const Self = @This();

        pub fn listDir(_: *Self, allocator: std.mem.Allocator, path: []const u8) !host.ListDirResult {
            try std.testing.expectEqualStrings("/home/alice/.config", path);
            const entries = try allocator.alloc(host.DirectoryEntry, 1);
            errdefer allocator.free(entries);
            entries[0] = .{ .name = try allocator.dupe(u8, "rush"), .kind = .directory };
            return .{ .allocator = allocator, .entries = entries };
        }

        pub fn fileTestStatusZ(_: *Self, _: [:0]const u8, _: bool) ?host.FileStatus {
            unreachable;
        }
    };
    const TestShell = struct {
        host: TestHost,
        state: TestState,
        env: []const [*:0]const u8 = &.{},
    };

    const source = "nvim ~/.config/ru";
    const analyzed = try analyzeLine(std.testing.allocator, source, source.len);
    defer analyzed.deinit(std.testing.allocator);
    const literal = analyzed.literal_prefix orelse return error.ExpectedLiteralPath;
    var sh: TestShell = .{ .host = .{}, .state = .{} };
    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);

    try appendPathCandidates(
        std.testing.allocator,
        &builder,
        &sh,
        literal.value,
        literal.expands_leading_tilde,
        analyzed.replace_start,
        analyzed.replace_end,
        false,
    );
    var application = try applyBuiltCandidates(std.testing.allocator, source, &builder, analyzed);
    defer application.deinit(std.testing.allocator);

    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedTildePathCompletion,
    };
    try std.testing.expectEqualStrings("~/.config/rush/", edit.replacement);
    try std.testing.expect(!edit.append_space);
}

const PathCompletionTestState = struct {
    home: ?[]const u8 = null,

    fn getVariable(self: PathCompletionTestState, name: []const u8) ?shell.state.Variable {
        if (!std.mem.eql(u8, name, "HOME")) return null;
        const home = self.home orelse return null;
        return .{ .name = "HOME", .value = home };
    }
};

const PathCompletionTestHost = struct {
    expected_path: []const u8,
    entry_name: []const u8,
    entry_kind: host.FileKind,

    pub fn listDir(self: *PathCompletionTestHost, allocator: std.mem.Allocator, path: []const u8) !host.ListDirResult {
        try std.testing.expectEqualStrings(self.expected_path, path);
        const entries = try allocator.alloc(host.DirectoryEntry, 1);
        errdefer allocator.free(entries);
        entries[0] = .{
            .name = try allocator.dupe(u8, self.entry_name),
            .kind = self.entry_kind,
        };
        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn fileTestStatusZ(_: *PathCompletionTestHost, _: [:0]const u8, _: bool) ?host.FileStatus {
        unreachable;
    }
};

const PathCompletionTestShell = struct {
    host: PathCompletionTestHost,
    state: PathCompletionTestState,
    env: []const [*:0]const u8 = &.{},
};

fn expectPathCompletion(
    source_text: []const u8,
    expected_lookup_path: []const u8,
    entry_name: []const u8,
    entry_kind: host.FileKind,
    home: ?[]const u8,
    expected_replacement: []const u8,
    expected_append_space: bool,
) !void {
    const analyzed = try analyzeLine(std.testing.allocator, source_text, source_text.len);
    defer analyzed.deinit(std.testing.allocator);
    const literal = analyzed.literal_prefix orelse return error.ExpectedLiteralPath;

    var sh: PathCompletionTestShell = .{
        .host = .{
            .expected_path = expected_lookup_path,
            .entry_name = entry_name,
            .entry_kind = entry_kind,
        },
        .state = .{ .home = home },
    };
    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);
    try appendPathCandidates(
        std.testing.allocator,
        &builder,
        &sh,
        literal.value,
        literal.expands_leading_tilde,
        analyzed.replace_start,
        analyzed.replace_end,
        false,
    );

    var application = try applyBuiltCandidates(std.testing.allocator, source_text, &builder, analyzed);
    defer application.deinit(std.testing.allocator);
    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedSinglePathCompletion,
    };
    try std.testing.expectEqualStrings(expected_replacement, edit.replacement);
    try std.testing.expectEqual(expected_append_space, edit.append_space);
}

test "path completion preserves a simple open quote and safely respells fallbacks" {
    const Case = struct {
        source: []const u8,
        lookup_path: []const u8,
        entry_name: []const u8,
        entry_kind: host.FileKind = .file,
        home: ?[]const u8 = null,
        replacement: []const u8,
        append_space: bool = true,
    };
    const cases = [_]Case{
        .{
            .source = "cat my",
            .lookup_path = ".",
            .entry_name = "my file.txt",
            .replacement = "my\\ file.txt",
        },
        .{
            .source = "cat my\\ f",
            .lookup_path = ".",
            .entry_name = "my file.txt",
            .replacement = "my\\ file.txt",
        },
        .{
            .source = "cat 'my f",
            .lookup_path = ".",
            .entry_name = "my file.txt",
            .replacement = "'my file.txt'",
        },
        .{
            .source = "cat \"my f",
            .lookup_path = ".",
            .entry_name = "my file.txt",
            .replacement = "\"my file.txt\"",
        },
        .{
            .source = "cat $'my\\x20f",
            .lookup_path = ".",
            .entry_name = "my file.txt",
            .replacement = "$'my file.txt'",
        },
        .{
            .source = "cat 'it",
            .lookup_path = ".",
            .entry_name = "it's here",
            .replacement = "'it'\\''s here'",
        },
        .{
            .source = "cat \"cash",
            .lookup_path = ".",
            .entry_name = "cash$ file",
            .replacement = "\"cash\\$ file\"",
        },
        .{
            .source = "cat $'line",
            .lookup_path = ".",
            .entry_name = "line\nbreak",
            .replacement = "$'line\\nbreak'",
        },
        .{
            .source = "cat pre\"my f",
            .lookup_path = ".",
            .entry_name = "premy file",
            .replacement = "premy\\ file",
        },
        .{
            .source = "cat 'my 'f",
            .lookup_path = ".",
            .entry_name = "my file",
            .replacement = "my\\ file",
        },
        .{
            .source = "cat my\\ dir/ch",
            .lookup_path = "my dir",
            .entry_name = "child file",
            .replacement = "my\\ dir/child\\ file",
        },
        .{
            .source = "cat 'my dir/ch",
            .lookup_path = "my dir",
            .entry_name = "child file",
            .replacement = "'my dir/child file'",
        },
        .{
            .source = "cat ~/my",
            .lookup_path = "/home/alice",
            .entry_name = "my file",
            .home = "/home/alice",
            .replacement = "~/my\\ file",
        },
        .{
            .source = "cat ~/\"my",
            .lookup_path = "/home/alice",
            .entry_name = "my file",
            .home = "/home/alice",
            .replacement = "~/my\\ file",
        },
        .{
            .source = "cat '~/my",
            .lookup_path = "~",
            .entry_name = "my file",
            .replacement = "'~/my file'",
        },
        .{
            .source = "cat \\~/my",
            .lookup_path = "~",
            .entry_name = "my file",
            .replacement = "\\~/my\\ file",
        },
        .{
            .source = "cd my",
            .lookup_path = ".",
            .entry_name = "my dir",
            .entry_kind = .directory,
            .replacement = "my\\ dir/",
            .append_space = false,
        },
        .{
            .source = "cd 'my",
            .lookup_path = ".",
            .entry_name = "my dir",
            .entry_kind = .directory,
            .replacement = "'my dir/",
            .append_space = false,
        },
    };
    for (cases) |case| {
        try expectPathCompletion(
            case.source,
            case.lookup_path,
            case.entry_name,
            case.entry_kind,
            case.home,
            case.replacement,
            case.append_space,
        );
    }
}

test "ambiguous path candidates preserve open quoting in their insert text" {
    const source_text = "cat 'my";
    const analyzed = try analyzeLine(std.testing.allocator, source_text, source_text.len);
    defer analyzed.deinit(std.testing.allocator);

    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);
    for ([_][]const u8{ "my file", "my folder" }) |value| {
        try builder.append(std.testing.allocator, .{
            .value = value,
            .kind = .file,
            .replace_start = analyzed.replace_start,
            .replace_end = analyzed.replace_end,
        });
    }

    var application = try applyBuiltCandidates(std.testing.allocator, source_text, &builder, analyzed);
    defer application.deinit(std.testing.allocator);
    const candidates = switch (application) {
        .ambiguous => |candidates| candidates,
        else => return error.ExpectedAmbiguousPathCompletion,
    };
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("my file", candidates[0].value);
    try std.testing.expectEqualStrings("'my file'", candidates[0].insert.?);
    try std.testing.expectEqualStrings("my folder", candidates[1].value);
    try std.testing.expectEqualStrings("'my folder'", candidates[1].insert.?);
}

test "provider file candidates receive shell-safe inserts at the shared boundary" {
    const source_text = "git add my";
    const analyzed = try analyzeLine(std.testing.allocator, source_text, source_text.len);
    defer analyzed.deinit(std.testing.allocator);

    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);
    try builder.append(std.testing.allocator, .{
        .value = "my file",
        .kind = .file,
        .replace_start = analyzed.replace_start,
        .replace_end = analyzed.replace_end,
    });

    var application = try applyBuiltCandidates(std.testing.allocator, source_text, &builder, analyzed);
    defer application.deinit(std.testing.allocator);
    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedProviderPathCompletion,
    };
    try std.testing.expectEqualStrings("my\\ file", edit.replacement);
}

test "literal provider prefixes match plain candidates by semantic value" {
    const source_text = "tool 'ma";
    const analyzed = try analyzeLine(std.testing.allocator, source_text, source_text.len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ma", analyzed.literal_prefix.?.value);

    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);
    try builder.append(std.testing.allocator, .{
        .value = "main",
        .kind = .plain,
        .replace_start = analyzed.replace_start,
        .replace_end = analyzed.replace_end,
    });

    var application = try applyBuiltCandidates(std.testing.allocator, source_text, &builder, analyzed);
    defer application.deinit(std.testing.allocator);
    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedProviderCompletion,
    };
    try std.testing.expectEqualStrings("main", edit.replacement);
}

test "provider-supplied inserts remain authoritative" {
    const source_text = "git add my";
    const analyzed = try analyzeLine(std.testing.allocator, source_text, source_text.len);
    defer analyzed.deinit(std.testing.allocator);

    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);
    try builder.append(std.testing.allocator, .{
        .value = "my file",
        .insert = "'my file'",
        .kind = .file,
        .replace_start = analyzed.replace_start,
        .replace_end = analyzed.replace_end,
    });

    var application = try applyBuiltCandidates(std.testing.allocator, source_text, &builder, analyzed);
    defer application.deinit(std.testing.allocator);
    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedProviderPathCompletion,
    };
    try std.testing.expectEqualStrings("'my file'", edit.replacement);
}

test "quoted path candidates keep provider suffixes outside the quote" {
    const source_text = "git add 'my";
    const analyzed = try analyzeLine(std.testing.allocator, source_text, source_text.len);
    defer analyzed.deinit(std.testing.allocator);

    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);
    try builder.append(std.testing.allocator, .{
        .value = "my file",
        .suffix = ",",
        .removable_suffix = true,
        .kind = .file,
        .replace_start = analyzed.replace_start,
        .replace_end = analyzed.replace_end,
    });

    var application = try applyBuiltCandidates(std.testing.allocator, source_text, &builder, analyzed);
    defer application.deinit(std.testing.allocator);
    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedProviderPathCompletion,
    };
    try std.testing.expectEqualStrings("'my file',", edit.replacement);
    try std.testing.expectEqualStrings(",", edit.suffix.?);
    try std.testing.expect(edit.removable_suffix);
}
