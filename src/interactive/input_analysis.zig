//! Interactive input diagnostics and command-resolution highlighting.

const std = @import("std");

const editor = @import("../editor.zig");
const extensions = @import("../extensions.zig");
const host = @import("../host.zig");
const shell = @import("../shell.zig");

const RushShell = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry);

pub fn analyze(
    allocator: std.mem.Allocator,
    sh: *RushShell,
    command_cache: *PathCommandCache,
    text: []const u8,
) !?editor.render.DiagnosticRender {
    if (text.len == 0) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const src: shell.source.Source = .{ .id = 0, .kind = .interactive, .name = "interactive", .text = text };
    var trivia: std.ArrayList(shell.lexer.Trivia) = .empty;
    const tokens = try shell.lexer.lexWithTrivia(arena.allocator(), src, &trivia);
    defer tokens.deinit(arena.allocator());

    var spans: std.ArrayList(editor.render.DiagnosticSpan) = .empty;
    errdefer spans.deinit(allocator);
    for (trivia.items) |item| {
        try spans.append(allocator, .{
            .start = item.start,
            .end = item.end,
            .severity = triviaSeverity(item.kind),
        });
    }
    try appendTokenSpans(allocator, &spans, sh, command_cache, tokens);

    if (spans.items.len == 0) return null;
    return .{ .spans = try spans.toOwnedSlice(allocator) };
}

fn triviaSeverity(kind: shell.lexer.Trivia.Kind) editor.render.DiagnosticSeverity {
    return switch (kind) {
        .comment => .comment,
        .quote => .quote,
        .pending_quote => .pending,
        .expansion => .expansion,
    };
}

fn appendTokenSpans(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(editor.render.DiagnosticSpan),
    sh: *RushShell,
    command_cache: *PathCommandCache,
    tokens: shell.token.Stream,
) !void {
    var tracker: shell.token.CommandPositionTracker = .{};
    for (0..tokens.items.len) |index| {
        const tok = tokens.get(index);
        if (tok.kind == .eof) break;
        const severity: editor.render.DiagnosticSeverity = switch (tracker.classify(tok)) {
            .command => if (try commandResolves(allocator, sh, command_cache, tok.text))
                .command
            else
                .command_invalid,
            .reserved => .reserved,
            .assignment => {
                try appendAssignmentSpans(allocator, spans, tok);
                continue;
            },
            .argument => {
                if (!tok.quoted and tok.text.len != 0 and tok.text[0] == '-') {
                    try spans.append(allocator, .{
                        .start = tok.span.start,
                        .end = tok.span.end,
                        .severity = .option,
                    });
                }
                continue;
            },
            .redirection_target => continue,
            .operator => switch (tok.kind) {
                .newline, .here_doc_body, .here_doc_body_unterminated => continue,
                else => .operator,
            },
        };
        try spans.append(allocator, .{
            .start = tok.span.start,
            .end = tok.span.end,
            .severity = severity,
        });
    }
}

/// Styles `NAME` as a variable, `=` (or `+=`) as muted syntax, and any
/// unquoted value text as a variable. Quote trivia is appended before these
/// token spans, so quoted values keep string styling.
fn appendAssignmentSpans(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(editor.render.DiagnosticSpan),
    tok: shell.Token,
) !void {
    const equals_index = std.mem.indexOfScalar(u8, tok.text, '=') orelse return;
    const name_end = if (equals_index > 0 and tok.text[equals_index - 1] == '+') equals_index - 1 else equals_index;
    const name_span_end = @min(tok.span.start + name_end, tok.span.end);
    if (tok.span.start != name_span_end) {
        try spans.append(allocator, .{
            .start = tok.span.start,
            .end = name_span_end,
            .severity = .assignment,
        });
    }

    const operator_start = tok.span.start + name_end;
    const operator_end = @min(tok.span.start + equals_index + 1, tok.span.end);
    if (operator_start < operator_end) {
        try spans.append(allocator, .{
            .start = operator_start,
            .end = operator_end,
            .severity = .assignment_operator,
        });
    }

    const value_start = operator_end;
    if (value_start < tok.span.end) {
        try spans.append(allocator, .{
            .start = value_start,
            .end = tok.span.end,
            .severity = .assignment,
        });
    }
}

fn commandResolves(
    allocator: std.mem.Allocator,
    sh: *RushShell,
    command_cache: *PathCommandCache,
    command: []const u8,
) !bool {
    std.debug.assert(command.len != 0);
    if (std.mem.indexOfScalar(u8, command, '/') != null) return existingCommandPath(allocator, sh, command);
    if (sh.lookupBuiltin(command) != null) return true;
    if (sh.state.getFunction(command) != null and !sh.state.isFunctionAutoloadSuppressed(command)) return true;
    if (sh.state.getAlias(command) != null) return true;
    if (sh.extensions.getAbbreviation(command) != null) return true;
    if (sh.state.command_hashes.contains(command)) return true;
    return command_cache.resolves(allocator, sh, command);
}

fn existingCommandPath(allocator: std.mem.Allocator, sh: *RushShell, command: []const u8) bool {
    const command_z = allocator.dupeZ(u8, command) catch return false;
    defer allocator.free(command_z);
    if (!sh.host.fileAccessZ(command_z, .execute)) return false;
    const status = sh.host.fileTestStatusZ(command_z, true) orelse return false;
    return status.kind != .directory;
}

/// Caches exact external-command lookups instead of eagerly enumerating PATH,
/// which can block the first prompt when PATH contains slow mounted filesystems.
pub const PathCommandCache = struct {
    path_key: []const u8 = "",
    cwd_key: []const u8 = "",
    commands: std.StringHashMapUnmanaged(bool) = .empty,

    // ziglint-ignore: Z030 deinit intentionally leaves reusable/test-local state shape
    pub fn deinit(self: *PathCommandCache, allocator: std.mem.Allocator) void {
        allocator.free(self.path_key);
        allocator.free(self.cwd_key);
        var iterator = self.commands.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        self.commands.deinit(allocator);
        self.* = .{};
    }

    pub fn refresh(self: *PathCommandCache, allocator: std.mem.Allocator, sh: anytype) !void {
        const path = interactivePathValue(sh) orelse "";
        const cwd = sh.host.currentDir(allocator) catch try allocator.dupe(u8, "");
        defer allocator.free(cwd);
        if (std.mem.eql(u8, self.path_key, path) and std.mem.eql(u8, self.cwd_key, cwd)) return;

        const path_key = try allocator.dupe(u8, path);
        errdefer allocator.free(path_key);
        const cwd_key = try allocator.dupe(u8, cwd);
        errdefer allocator.free(cwd_key);

        self.deinit(allocator);
        self.path_key = path_key;
        self.cwd_key = cwd_key;
    }

    fn resolves(self: *PathCommandCache, allocator: std.mem.Allocator, sh: anytype, name: []const u8) !bool {
        if (self.commands.get(name)) |resolved| return resolved;
        const resolved = try pathCommandResolves(allocator, sh, name);
        try putCommandResolution(allocator, &self.commands, name, resolved);
        return resolved;
    }
};

fn putCommandResolution(
    allocator: std.mem.Allocator,
    commands: *std.StringHashMapUnmanaged(bool),
    name: []const u8,
    resolved: bool,
) !void {
    if (commands.getPtr(name)) |existing| {
        existing.* = resolved;
        return;
    }
    const owned = try allocator.dupe(u8, name);
    errdefer allocator.free(owned);
    try commands.put(allocator, owned, resolved);
}

fn pathCommandResolves(allocator: std.mem.Allocator, sh: anytype, command: []const u8) !bool {
    const path = interactivePathValue(sh) orelse return false;
    var candidate_buffer: std.ArrayList(u8) = .empty;
    defer candidate_buffer.deinit(allocator);
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |raw_dir| {
        const dir = if (raw_dir.len == 0) "." else raw_dir;
        candidate_buffer.clearRetainingCapacity();
        try candidate_buffer.appendSlice(allocator, dir);
        if (!std.mem.endsWith(u8, dir, "/")) try candidate_buffer.append(allocator, '/');
        try candidate_buffer.appendSlice(allocator, command);
        try candidate_buffer.append(allocator, 0);
        const candidate = candidate_buffer.items[0 .. candidate_buffer.items.len - 1 :0];
        if (!sh.host.fileAccessZ(candidate, .execute)) continue;
        const status = sh.host.fileTestStatusZ(candidate, true) orelse continue;
        if (status.kind != .directory) return true;
    }
    return false;
}

fn interactivePathValue(sh: anytype) ?[]const u8 {
    if (sh.state.getVariable("PATH")) |variable| return variable.value;
    for (sh.env) |entry_ptr| {
        const entry = std.mem.span(entry_ptr);
        if (entry.len <= "PATH".len or entry["PATH".len] != '=') continue;
        if (std.mem.eql(u8, entry[0.."PATH".len], "PATH")) return entry["PATH".len + 1 ..];
    }
    return "/bin:/usr/bin";
}

test "interactive path command cache resolves exact names lazily" {
    const TestHost = struct {
        const Self = @This();

        file_access_calls: usize = 0,
        list_dir_calls: usize = 0,

        fn currentDir(_: *Self, allocator: std.mem.Allocator) ![]const u8 {
            return allocator.dupe(u8, "/work");
        }

        fn fileAccessZ(self: *Self, path: [:0]const u8, _: host.FileAccess) bool {
            self.file_access_calls += 1;
            return std.mem.eql(u8, path, "/commands/tool");
        }

        fn fileTestStatusZ(_: *Self, _: [:0]const u8, _: bool) ?host.FileStatus {
            return .{ .kind = .file };
        }

        fn listDir(self: *Self, _: std.mem.Allocator, _: []const u8) !host.ListDirResult {
            self.list_dir_calls += 1;
            return error.FileNotFound;
        }
    };
    const TestShell = struct {
        host: *TestHost,
        state: shell.state.State,
        env: []const [*:0]const u8 = &.{},
    };

    var test_host: TestHost = .{};
    var test_shell: TestShell = .{
        .host = &test_host,
        .state = .init(std.testing.allocator, .{}),
    };
    defer test_shell.state.deinit();
    try test_shell.state.putVariable(.{ .name = "PATH", .value = "/commands:/mnt/c/Windows/System32" });

    var command_cache: PathCommandCache = .{};
    defer command_cache.deinit(std.testing.allocator);
    try command_cache.refresh(std.testing.allocator, &test_shell);

    try std.testing.expectEqual(@as(usize, 0), test_host.list_dir_calls);
    try std.testing.expectEqual(@as(usize, 0), command_cache.commands.count());
    try std.testing.expect(try command_cache.resolves(std.testing.allocator, &test_shell, "tool"));
    try std.testing.expectEqual(@as(usize, 1), test_host.file_access_calls);
    try std.testing.expect(try command_cache.resolves(std.testing.allocator, &test_shell, "tool"));
    try std.testing.expectEqual(@as(usize, 1), test_host.file_access_calls);
    try std.testing.expect(!try command_cache.resolves(std.testing.allocator, &test_shell, "missing"));
    try std.testing.expectEqual(@as(usize, 3), test_host.file_access_calls);
    try std.testing.expectEqual(@as(usize, 0), test_host.list_dir_calls);

    try test_shell.state.putVariable(.{ .name = "PATH", .value = "/other" });
    try command_cache.refresh(std.testing.allocator, &test_shell);
    try std.testing.expectEqual(@as(usize, 0), command_cache.commands.count());
}

test "interactive input analysis marks unresolved command tokens only" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    try sh.state.putAlias(.{ .name = "ll", .value = "ls -l" });

    var command_cache: PathCommandCache = .{};
    defer command_cache.deinit(std.testing.allocator);
    try putCommandResolution(std.testing.allocator, &command_cache.commands, "cached", true);

    const text = "echo ok\nll\nnope arg\nFOO=bar cached < nope\n";
    const analyzed = (try analyze(std.testing.allocator, &sh, &command_cache, text)).?;
    defer analyzed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 8), analyzed.spans.len);
    const Severity = editor.render.DiagnosticSeverity;
    try std.testing.expectEqual(Severity.command, analyzed.spans[0].severity); // echo
    try std.testing.expectEqual(Severity.command, analyzed.spans[1].severity); // ll alias
    try std.testing.expectEqual(Severity.command_invalid, analyzed.spans[2].severity);
    try std.testing.expectEqualStrings("nope", text[analyzed.spans[2].start..analyzed.spans[2].end]);
    try std.testing.expectEqual(Severity.assignment, analyzed.spans[3].severity);
    try std.testing.expectEqualStrings("FOO", text[analyzed.spans[3].start..analyzed.spans[3].end]);
    try std.testing.expectEqual(Severity.assignment_operator, analyzed.spans[4].severity);
    try std.testing.expectEqualStrings("=", text[analyzed.spans[4].start..analyzed.spans[4].end]);
    try std.testing.expectEqual(Severity.assignment, analyzed.spans[5].severity);
    try std.testing.expectEqualStrings("bar", text[analyzed.spans[5].start..analyzed.spans[5].end]);
    try std.testing.expectEqual(Severity.command, analyzed.spans[6].severity);
    try std.testing.expectEqualStrings("cached", text[analyzed.spans[6].start..analyzed.spans[6].end]);
    try std.testing.expectEqual(Severity.operator, analyzed.spans[7].severity);
    try std.testing.expectEqualStrings("<", text[analyzed.spans[7].start..analyzed.spans[7].end]);
}

test "interactive input analysis requires command paths to be executable files" {
    const tmpdir = "rush-input-analysis-command-test-tmp";
    try std.Io.Dir.cwd().deleteTree(std.testing.io, tmpdir);
    try std.Io.Dir.cwd().createDir(std.testing.io, tmpdir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tmpdir) catch {};

    const plain = try std.Io.Dir.cwd().createFile(std.testing.io, tmpdir ++ "/plain", .{
        .permissions = @enumFromInt(0o600),
    });
    plain.close(std.testing.io);
    const executable = try std.Io.Dir.cwd().createFile(std.testing.io, tmpdir ++ "/executable", .{
        .permissions = @enumFromInt(0o700),
    });
    executable.close(std.testing.io);
    try std.Io.Dir.cwd().createDir(std.testing.io, tmpdir ++ "/directory", .default_dir);

    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    var command_cache: PathCommandCache = .{};
    defer command_cache.deinit(std.testing.allocator);

    const text = tmpdir ++ "/plain\n" ++ tmpdir ++ "/executable\n" ++ tmpdir ++ "/directory";
    const analyzed = (try analyze(std.testing.allocator, &sh, &command_cache, text)).?;
    defer analyzed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), analyzed.spans.len);
    try std.testing.expectEqual(editor.render.DiagnosticSeverity.command_invalid, analyzed.spans[0].severity);
    try std.testing.expectEqual(editor.render.DiagnosticSeverity.command, analyzed.spans[1].severity);
    try std.testing.expectEqual(editor.render.DiagnosticSeverity.command_invalid, analyzed.spans[2].severity);
}

test "interactive input analysis styles assignment operator and expanded value separately" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    var command_cache: PathCommandCache = .{};
    defer command_cache.deinit(std.testing.allocator);

    const text = "FOO=$HOME/foo";
    const analyzed = (try analyze(std.testing.allocator, &sh, &command_cache, text)).?;
    defer analyzed.deinit(std.testing.allocator);

    const Severity = editor.render.DiagnosticSeverity;
    const expected = [_]struct { severity: Severity, text: []const u8 }{
        .{ .severity = .expansion, .text = "$HOME" },
        .{ .severity = .assignment, .text = "FOO" },
        .{ .severity = .assignment_operator, .text = "=" },
        .{ .severity = .assignment, .text = "$HOME/foo" },
    };
    try std.testing.expectEqual(expected.len, analyzed.spans.len);
    for (expected, analyzed.spans) |want, span| {
        try std.testing.expectEqual(want.severity, span.severity);
        try std.testing.expectEqualStrings(want.text, text[span.start..span.end]);
    }
}

test "interactive input analysis lets quoted assignment values keep quote styling" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    var command_cache: PathCommandCache = .{};
    defer command_cache.deinit(std.testing.allocator);

    const text = "FOO='val'";
    const analyzed = (try analyze(std.testing.allocator, &sh, &command_cache, text)).?;
    defer analyzed.deinit(std.testing.allocator);

    const Severity = editor.render.DiagnosticSeverity;
    const expected = [_]struct { severity: Severity, text: []const u8 }{
        .{ .severity = .quote, .text = "'val'" },
        .{ .severity = .assignment, .text = "FOO" },
        .{ .severity = .assignment_operator, .text = "=" },
        .{ .severity = .assignment, .text = "'val'" },
    };
    try std.testing.expectEqual(expected.len, analyzed.spans.len);
    for (expected, analyzed.spans) |want, span| {
        try std.testing.expectEqual(want.severity, span.severity);
        try std.testing.expectEqualStrings(want.text, text[span.start..span.end]);
    }
}

test "interactive input analysis styles comments quotes and pending quote" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    var command_cache: PathCommandCache = .{};
    defer command_cache.deinit(std.testing.allocator);

    const text = "printf 'ok' # comment\nprintf \"pending";
    const analyzed = (try analyze(std.testing.allocator, &sh, &command_cache, text)).?;
    defer analyzed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), analyzed.spans.len);
    try std.testing.expectEqual(editor.render.DiagnosticSeverity.quote, analyzed.spans[0].severity);
    try std.testing.expectEqualStrings("'ok'", text[analyzed.spans[0].start..analyzed.spans[0].end]);
    try std.testing.expectEqual(editor.render.DiagnosticSeverity.comment, analyzed.spans[1].severity);
    try std.testing.expectEqualStrings("# comment", text[analyzed.spans[1].start..analyzed.spans[1].end]);
    try std.testing.expectEqual(editor.render.DiagnosticSeverity.pending, analyzed.spans[2].severity);
    try std.testing.expectEqualStrings("\"pending", text[analyzed.spans[2].start..analyzed.spans[2].end]);
    try std.testing.expectEqual(editor.render.DiagnosticSeverity.command, analyzed.spans[3].severity);
    try std.testing.expectEqualStrings("printf", text[analyzed.spans[3].start..analyzed.spans[3].end]);
    try std.testing.expectEqual(editor.render.DiagnosticSeverity.command, analyzed.spans[4].severity);
}

test "interactive input analysis styles reserved words operators options and expansions" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    var command_cache: PathCommandCache = .{};
    defer command_cache.deinit(std.testing.allocator);
    try putCommandResolution(std.testing.allocator, &command_cache.commands, "grep", true);

    const text = "if grep -q $HOME f; then echo $(id); fi";
    const analyzed = (try analyze(std.testing.allocator, &sh, &command_cache, text)).?;
    defer analyzed.deinit(std.testing.allocator);

    const Severity = editor.render.DiagnosticSeverity;
    const expected = [_]struct { severity: Severity, text: []const u8 }{
        .{ .severity = .expansion, .text = "$HOME" },
        .{ .severity = .expansion, .text = "$(id)" },
        .{ .severity = .reserved, .text = "if" },
        .{ .severity = .command, .text = "grep" },
        .{ .severity = .option, .text = "-q" },
        .{ .severity = .operator, .text = ";" },
        .{ .severity = .reserved, .text = "then" },
        .{ .severity = .command, .text = "echo" },
        .{ .severity = .operator, .text = ";" },
        .{ .severity = .reserved, .text = "fi" },
    };
    try std.testing.expectEqual(expected.len, analyzed.spans.len);
    for (expected, analyzed.spans) |want, span| {
        try std.testing.expectEqual(want.severity, span.severity);
        try std.testing.expectEqualStrings(want.text, text[span.start..span.end]);
    }
}
