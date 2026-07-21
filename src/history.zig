//! Command history storage and editor history adapters.

const std = @import("std");
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

const line_editor = @import("editor.zig").line;
const shell_lexer = @import("shell/lexer.zig");
const shell_source = @import("shell/source.zig");

const ExitStatus = u8;

/// Query result whose command text is owned by the allocator supplied to the
/// query or callback. Returned entry slices are separately owned by it.
pub const HistoryEntry = struct {
    number: i64,
    command: []const u8,
};

pub const DirectoryHistory = struct {
    entries: []DirectoryEntry,

    pub const DirectoryEntry = struct {
        path: []const u8,
    };

    pub fn deinit(self: *DirectoryHistory, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| allocator.free(entry.path);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

/// Shell history callback interface. `list` and `search` return deeply owned
/// entry slices; `jump` returns an owned path; `directories` returns a deeply
/// owned result. Each uses the allocator passed to that callback.
pub const CommandHistory = struct {
    context: *anyopaque,
    io: std.Io,
    list: *const fn (*anyopaque, std.mem.Allocator) anyerror![]HistoryEntry,
    append: ?*const fn (*anyopaque, std.Io, []const u8, ExitStatus, i64, i64) anyerror!void = null,
    jump: ?*const fn (*anyopaque, std.mem.Allocator, []const []const u8, []const u8, i64) anyerror!?[]const u8 = null,
    directories: ?*const fn (
        *anyopaque,
        std.mem.Allocator,
        []const []const u8,
        []const u8,
        i64,
    ) anyerror!DirectoryHistory = null,
    suppress_next_append: ?*const fn (*anyopaque) void = null,
    search: ?*const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]HistoryEntry = null,
    delete_id: ?*const fn (*anyopaque, i64) anyerror!bool = null,
    clear: ?*const fn (*anyopaque) anyerror!void = null,
};

fn unixTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

pub const History = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    hostname: []const u8,
    session_id: []const u8 = "",
    current_cwd: []const u8 = "",
    /// Rowid snapshot taken when the database is opened. Arrow-key navigation
    /// sees this session's commands plus rows that already existed at startup,
    /// so concurrent sessions do not interleave into each other mid-session.
    session_start_id: i64 = 0,
    active_command: ?CommandHandle = null,

    pub const CommandHandle = i64;

    const HistoryRecord = struct {
        cmd: []const u8,
        when: i64 = 0,
        status: ExitStatus = 0,
        exit_signal: ?u8 = null,
        cwd: []const u8 = "",
        duration_ms: ?i64 = null,
        hostname: []const u8 = "",
        session_id: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator) !History {
        const db = try openHistoryDb(allocator, ":memory:");
        errdefer _ = sqlite.sqlite3_close(db);
        return .{
            .allocator = allocator,
            .db = db,
            .hostname = try localHostname(allocator),
        };
    }

    pub fn deinit(self: *History) void {
        _ = sqlite.sqlite3_close(self.db);
        self.allocator.free(self.hostname);
        self.* = undefined;
    }

    /// Persists an interactive command before evaluation begins. The temporary
    /// failure status keeps an interrupted command out of successful-only
    /// searches; `finishCommand` replaces it with the actual result.
    pub fn startCommand(
        self: *History,
        io: std.Io,
        line: []const u8,
        started_at: i64,
    ) !?CommandHandle {
        if (line.len == 0 or line[0] == ' ') return null;
        std.debug.assert(self.active_command == null);

        var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const record: HistoryRecord = .{
            .cmd = line,
            .when = started_at,
            .status = 1,
            .cwd = self.commandCwd(io, &cwd_buffer),
            .hostname = self.hostname,
            .session_id = self.session_id,
        };
        const handle = try insertHistoryRecordWithAllocator(self.allocator, self.db, record);
        self.active_command = handle;
        return handle;
    }

    // ziglint-ignore: Z012 existing public API type exposure; preserve API
    pub fn finishCommand(
        self: *History,
        handle: CommandHandle,
        status: ExitStatus,
        duration_ms: i64,
    ) !void {
        std.debug.assert(duration_ms >= 0);
        std.debug.assert(self.active_command != null);
        std.debug.assert(self.active_command.? == handle);
        defer self.active_command = null;
        try updateHistoryRecordResult(self.db, handle, status, duration_ms);
    }

    pub fn discardCommand(self: *History, handle: CommandHandle) !void {
        std.debug.assert(self.active_command != null);
        std.debug.assert(self.active_command.? == handle);
        defer self.active_command = null;
        // The history builtin may already have removed the active row through
        // `clear` or an explicit deletion.
        _ = try deleteHistoryRecordById(self.db, handle);
    }

    // ziglint-ignore: Z012 existing public API type exposure; preserve API
    pub fn addCommand(
        self: *History,
        io: std.Io,
        line: []const u8,
        status: ExitStatus,
        started_at: i64,
        duration_ms: i64,
    ) !void {
        // A leading space keeps the command out of history entirely, so
        // secrets are never persisted (fish behavior, bash ignorespace).
        if (line.len != 0 and line[0] == ' ') return;
        try self.appendCommand(io, line, status, started_at, duration_ms);
    }

    // ziglint-ignore: Z012 existing public API type exposure; preserve API
    pub fn appendCommand(
        self: *History,
        io: std.Io,
        line: []const u8,
        status: ExitStatus,
        started_at: i64,
        duration_ms: i64,
    ) !void {
        if (line.len == 0) return;
        var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const record: HistoryRecord = .{
            .cmd = line,
            .when = started_at,
            .status = status,
            .exit_signal = exitSignalFromStatus(status),
            .cwd = self.commandCwd(io, &cwd_buffer),
            .duration_ms = duration_ms,
            .hostname = self.hostname,
            .session_id = self.session_id,
        };
        _ = try insertHistoryRecordWithAllocator(self.allocator, self.db, record);
    }

    fn commandCwd(
        self: *History,
        io: std.Io,
        buffer: *[std.Io.Dir.max_path_bytes]u8,
    ) []const u8 {
        if (self.current_cwd.len != 0) return self.current_cwd;
        const cwd_len = std.Io.Dir.cwd().realPath(io, buffer) catch 0;
        return buffer[0..cwd_len];
    }

    pub fn jumpDirectory(
        self: *History,
        allocator: std.mem.Allocator,
        terms: []const []const u8,
        exclude: []const u8,
        now: i64,
    ) !?[]const u8 {
        if (terms.len == 0) return null;
        return queryJumpDirectory(
            allocator,
            self.db,
            terms,
            exclude,
            now,
            self.active_command,
        );
    }

    pub fn rankDirectories(
        self: *History,
        allocator: std.mem.Allocator,
        terms: []const []const u8,
        exclude: []const u8,
        now: i64,
    ) !DirectoryHistory {
        return queryJumpDirectories(
            allocator,
            self.db,
            terms,
            exclude,
            now,
            self.active_command,
        );
    }

    pub fn load(self: *History, io: std.Io, path: []const u8) !void {
        std.debug.assert(self.active_command == null);
        if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        const db = try openHistoryDb(self.allocator, path);
        errdefer _ = sqlite.sqlite3_close(db);
        const session_start_id = try queryMaxHistoryId(db);
        _ = sqlite.sqlite3_close(self.db);
        self.db = db;
        self.session_start_id = session_start_id;
    }

    pub fn previousEntry(
        self: *History,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        before: ?i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        return queryHistoryEntry(allocator, self.db, prefix, self.session_id, self.session_start_id, before, .previous);
    }

    pub fn nextEntry(
        self: *History,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        after: i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        return queryHistoryEntry(allocator, self.db, prefix, self.session_id, self.session_start_id, after, .next);
    }

    pub fn numberedEntry(
        self: *History,
        allocator: std.mem.Allocator,
        number: usize,
    ) !?line_editor.HistoryView.HistoryEntry {
        if (number == 0) return null;
        return queryHistoryEntryByNumber(allocator, self.db, number);
    }

    /// Returns a deeply owned entry slice allocated by `allocator`.
    pub fn fcEntries(self: *History, allocator: std.mem.Allocator) ![]HistoryEntry {
        return queryFcHistoryEntries(
            allocator,
            self.db,
            fc_history_limit,
            self.active_command,
        );
    }

    /// Returns a deeply owned entry slice for a case-insensitive substring
    /// search. Results are newest-bounded without duplicate hiding because
    /// deletion needs every matching row visible.
    pub fn searchEntries(self: *History, allocator: std.mem.Allocator, text: []const u8) ![]HistoryEntry {
        return queryHistoryEntriesContaining(
            allocator,
            self.db,
            text,
            fc_history_limit,
            self.active_command,
        );
    }

    pub fn deleteEntry(self: *History, id: i64) !bool {
        return deleteHistoryRecordById(self.db, id);
    }

    pub fn clearEntries(self: *History) !void {
        return sqliteExec(self.db, "delete from history;");
    }

    pub fn searchEntry(
        self: *History,
        allocator: std.mem.Allocator,
        query: []const u8,
        cwd: []const u8,
        session_id: []const u8,
        filters: line_editor.HistorySearchFilters,
        before: ?i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        return queryHistorySearchEntry(allocator, self.db, query, cwd, session_id, filters, before, .previous);
    }

    pub fn searchNextEntry(
        self: *History,
        allocator: std.mem.Allocator,
        query: []const u8,
        cwd: []const u8,
        session_id: []const u8,
        filters: line_editor.HistorySearchFilters,
        after: ?i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        return queryHistorySearchEntry(allocator, self.db, query, cwd, session_id, filters, after, .next);
    }

    pub fn suggestEntry(
        self: *History,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        cwd: []const u8,
        session_id: []const u8,
        previous_command: []const u8,
    ) !?line_editor.HistoryView.HistoryEntry {
        return queryHistorySuggestion(allocator, self.db, prefix, cwd, session_id, previous_command);
    }

    /// Returns command text owned by `allocator`.
    pub fn latestCommand(
        self: *History,
        allocator: std.mem.Allocator,
        session_id: []const u8,
    ) !?[]const u8 {
        return queryLatestCommand(allocator, self.db, session_id);
    }

    /// Returns the one-based number that the next persisted command receives.
    pub fn nextCommandNumber(self: *History) !i64 {
        var stmt: ?*sqlite.sqlite3_stmt = null;
        try sqliteCheck(sqlite.sqlite3_prepare_v2(
            self.db,
            "select coalesce(max(id), 0) + 1 from history",
            -1,
            &stmt,
            null,
        ), self.db);
        defer _ = sqlite.sqlite3_finalize(stmt);
        try sqliteCheck(sqlite.sqlite3_step(stmt), self.db);
        return sqlite.sqlite3_column_int64(stmt, 0);
    }
};

pub const InteractiveHistoryService = struct {
    history: *History,
    suppress_next_append: bool = false,

    pub fn init(history: *History) InteractiveHistoryService {
        return .{ .history = history };
    }

    pub fn lineEditorView(self: *InteractiveHistoryService, io: std.Io) line_editor.HistoryView {
        return .{
            .now = unixTimestamp(io),
            .context = self,
            .previous = previousHistoryEntry,
            .next = nextHistoryEntry,
            .by_number = numberedHistoryEntry,
            .search = searchHistoryEntry,
            .search_next = searchNextHistoryEntry,
            .suggest = suggestHistoryEntry,
        };
    }

    pub fn commandHistory(self: *InteractiveHistoryService, io: std.Io) CommandHistory {
        return .{
            .context = self,
            .io = io,
            .list = listFcEntries,
            .append = appendFcCommand,
            .jump = jumpDirectory,
            .directories = rankDirectories,
            .suppress_next_append = suppressNextFcAppend,
            .search = searchCommandEntries,
            .delete_id = deleteCommandEntry,
            .clear = clearCommandEntries,
        };
    }

    // ziglint-ignore: Z012 existing public API type exposure; preserve API
    pub fn addCommand(
        self: *InteractiveHistoryService,
        io: std.Io,
        line: []const u8,
        status: ExitStatus,
        started_at: i64,
        duration_ms: i64,
    ) !void {
        try self.history.addCommand(io, line, status, started_at, duration_ms);
    }

    pub fn startCommand(
        self: *InteractiveHistoryService,
        io: std.Io,
        line: []const u8,
        started_at: i64,
    ) !?History.CommandHandle {
        return self.history.startCommand(io, line, started_at);
    }

    pub fn nextCommandNumber(self: *InteractiveHistoryService) !i64 {
        return self.history.nextCommandNumber();
    }

    // ziglint-ignore: Z012 existing public API type exposure; preserve API
    pub fn completeCommand(
        self: *InteractiveHistoryService,
        handle: ?History.CommandHandle,
        status: ExitStatus,
        duration_ms: i64,
    ) !void {
        const suppress = self.consumeSuppressNextAppend();
        const active = handle orelse return;
        if (suppress) return self.history.discardCommand(active);
        return self.history.finishCommand(active, status, duration_ms);
    }

    pub fn suppressNextAppend(self: *InteractiveHistoryService) void {
        self.suppress_next_append = true;
    }

    pub fn consumeSuppressNextAppend(self: *InteractiveHistoryService) bool {
        const suppress = self.suppress_next_append;
        self.suppress_next_append = false;
        return suppress;
    }

    fn previousEntry(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        before: ?i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        return self.history.previousEntry(allocator, prefix, before);
    }

    fn nextEntry(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        after: i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        return self.history.nextEntry(allocator, prefix, after);
    }

    fn numberedEntry(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        number: usize,
    ) !?line_editor.HistoryView.HistoryEntry {
        return self.history.numberedEntry(allocator, number);
    }

    fn fcEntries(self: *InteractiveHistoryService, allocator: std.mem.Allocator) ![]HistoryEntry {
        return self.history.fcEntries(allocator);
    }

    fn jumpDirectoryPath(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        terms: []const []const u8,
        exclude: []const u8,
        now: i64,
    ) !?[]const u8 {
        return self.history.jumpDirectory(allocator, terms, exclude, now);
    }

    fn rankedDirectoryHistory(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        terms: []const []const u8,
        exclude: []const u8,
        now: i64,
    ) !DirectoryHistory {
        return self.history.rankDirectories(allocator, terms, exclude, now);
    }

    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    fn listFcEntries(context: *anyopaque, allocator: std.mem.Allocator) ![]HistoryEntry {
        const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
        return history_service.fcEntries(allocator);
    }

    fn appendFcCommand(
        context: *anyopaque,
        // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
        io: std.Io,
        line: []const u8,
        status: ExitStatus,
        started_at: i64,
        duration_ms: i64,
    ) !void {
        const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
        try history_service.history.appendCommand(io, line, status, started_at, duration_ms);
    }

    fn jumpDirectory(
        context: *anyopaque,
        // ziglint-ignore: Z023 parameter order follows CommandHistory.jump callback shape
        allocator: std.mem.Allocator,
        terms: []const []const u8,
        exclude: []const u8,
        now: i64,
    ) !?[]const u8 {
        const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
        return history_service.jumpDirectoryPath(allocator, terms, exclude, now);
    }

    fn rankDirectories(
        context: *anyopaque,
        // ziglint-ignore: Z023 parameter order follows CommandHistory.directories callback shape
        allocator: std.mem.Allocator,
        terms: []const []const u8,
        exclude: []const u8,
        now: i64,
    ) !DirectoryHistory {
        const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
        return history_service.rankedDirectoryHistory(allocator, terms, exclude, now);
    }

    fn suppressNextFcAppend(context: *anyopaque) void {
        const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
        history_service.suppressNextAppend();
    }

    // ziglint-ignore: Z023 parameter order follows CommandHistory.search callback shape
    fn searchCommandEntries(context: *anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]HistoryEntry {
        const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
        return history_service.history.searchEntries(allocator, text);
    }

    fn deleteCommandEntry(context: *anyopaque, id: i64) !bool {
        const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
        return history_service.history.deleteEntry(id);
    }

    fn clearCommandEntries(context: *anyopaque) !void {
        const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
        return history_service.history.clearEntries();
    }

    fn searchEntry(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        query: []const u8,
        filters: line_editor.HistorySearchFilters,
        before: ?i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        return self.history.searchEntry(
            allocator,
            query,
            self.history.current_cwd,
            self.history.session_id,
            filters,
            before,
        );
    }

    fn searchNextEntry(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        query: []const u8,
        filters: line_editor.HistorySearchFilters,
        after: ?i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        return self.history.searchNextEntry(
            allocator,
            query,
            self.history.current_cwd,
            self.history.session_id,
            filters,
            after,
        );
    }

    fn suggestEntry(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        prefix: []const u8,
    ) !?line_editor.HistoryView.HistoryEntry {
        return self.history.suggestEntry(
            allocator,
            prefix,
            self.history.current_cwd,
            self.history.session_id,
            "",
        );
    }
};

fn previousHistoryEntry(
    context: *anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    prefix: []const u8,
    before: ?i64,
) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.previousEntry(allocator, prefix, before);
}

fn nextHistoryEntry(
    context: *anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    prefix: []const u8,
    after: i64,
) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.nextEntry(allocator, prefix, after);
}

fn numberedHistoryEntry(
    context: *anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    number: usize,
) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.numberedEntry(allocator, number);
}

fn searchHistoryEntry(
    context: *anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    query: []const u8,
    filters: line_editor.HistorySearchFilters,
    before: ?i64,
) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.searchEntry(allocator, query, filters, before);
}

fn searchNextHistoryEntry(
    context: *anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    query: []const u8,
    filters: line_editor.HistorySearchFilters,
    after: ?i64,
) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.searchNextEntry(allocator, query, filters, after);
}

fn suggestHistoryEntry(
    context: *anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    prefix: []const u8,
) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.suggestEntry(allocator, prefix);
}

fn applyLineHistoryRequest(session: *line_editor.LineSession, history: line_editor.HistoryView) !void {
    const request = session.takeHistoryRequest() orelse return;
    defer request.deinit(std.testing.allocator);
    const context = history.context orelse return try session.applyHistoryResult(request, .{ .entry = null });
    const result: line_editor.HistoryResult = switch (request) {
        .previous => |previous| if (history.previous) |callback|
            .{ .entry = try callback(context, std.testing.allocator, previous.prefix, previous.before) }
        else
            .{ .entry = null },
        .next => |next| if (history.next) |callback|
            .{ .entry = try callback(context, std.testing.allocator, next.prefix, next.after) }
        else
            .{ .entry = null },
        .by_number => |number| if (history.by_number) |callback|
            .{ .entry = try callback(context, std.testing.allocator, number) }
        else
            .{ .entry = null },
        .search,
        .search_next,
        => .{ .entries = &.{} },
        .suggest => .{ .entry = null },
    };
    try session.applyHistoryResult(request, result);
}

const HistoryDirection = enum { previous, next };

const DirectoryJumpCandidate = struct {
    path: []const u8,
    visits: i64 = 0,
    last_seen: i64 = 0,
};

fn exitSignalFromStatus(status: ExitStatus) ?u8 {
    if (status < 128) return null;
    return status - 128;
}

fn queryJumpDirectory(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    terms: []const []const u8,
    exclude: []const u8,
    now: i64,
    excluded_id: ?i64,
) !?[]const u8 {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try prepareJumpDirectoryQuery(db, &stmt, excluded_id);
    defer _ = sqlite.sqlite3_finalize(stmt);

    var best: ?DirectoryJumpCandidate = null;
    var best_path: ?[]const u8 = null;
    errdefer if (best_path) |path| allocator.free(path);
    while (true) {
        const rc = sqlite.sqlite3_step(stmt);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
        const cwd_text = sqlite.sqlite3_column_text(stmt, 0) orelse continue;
        const candidate: DirectoryJumpCandidate = .{
            .path = std.mem.span(cwd_text),
            .visits = sqlite.sqlite3_column_int64(stmt, 1),
            .last_seen = sqlite.sqlite3_column_int64(stmt, 2),
        };
        if (std.mem.eql(u8, candidate.path, exclude)) continue;
        if (!directoryJumpMatches(candidate.path, terms)) continue;
        if (best == null or directoryJumpCandidateBefore(now, candidate, best.?)) {
            const path = try allocator.dupe(u8, candidate.path);
            if (best_path) |old_path| allocator.free(old_path);
            best_path = path;
            best = .{ .path = path, .visits = candidate.visits, .last_seen = candidate.last_seen };
        }
    }
    _ = best orelse return null;
    const path = best_path.?;
    best_path = null;
    return path;
}

fn queryJumpDirectories(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    terms: []const []const u8,
    exclude: []const u8,
    now: i64,
    excluded_id: ?i64,
) !DirectoryHistory {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try prepareJumpDirectoryQuery(db, &stmt, excluded_id);
    defer _ = sqlite.sqlite3_finalize(stmt);

    var candidates: std.ArrayList(DirectoryJumpCandidate) = .empty;
    errdefer {
        for (candidates.items) |candidate| allocator.free(candidate.path);
        candidates.deinit(allocator);
    }
    while (true) {
        const rc = sqlite.sqlite3_step(stmt);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
        const cwd_text = sqlite.sqlite3_column_text(stmt, 0) orelse continue;
        const path = std.mem.span(cwd_text);
        if (std.mem.eql(u8, path, exclude)) continue;
        if (!directoryJumpMatches(path, terms)) continue;
        const owned_path = try allocator.dupe(u8, path);
        candidates.append(allocator, .{
            .path = owned_path,
            .visits = sqlite.sqlite3_column_int64(stmt, 1),
            .last_seen = sqlite.sqlite3_column_int64(stmt, 2),
        }) catch |err| {
            allocator.free(owned_path);
            return err;
        };
    }
    std.mem.sort(DirectoryJumpCandidate, candidates.items, now, directoryJumpCandidateBefore);
    return directoryHistoryFromCandidates(allocator, &candidates);
}

fn prepareJumpDirectoryQuery(db: *sqlite.sqlite3, stmt: *?*sqlite.sqlite3_stmt, excluded_id: ?i64) !void {
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        \\select cwd, count(*), max(started_at) from history
        \\where cwd <> '' and (?1 is null or id <> ?1)
        \\group by cwd
    ,
        -1,
        stmt,
        null,
    ), db);
    errdefer _ = sqlite.sqlite3_finalize(stmt.*);
    if (excluded_id) |id| {
        try sqliteCheck(sqlite.sqlite3_bind_int64(stmt.*, 1, id), db);
    } else {
        try sqliteCheck(sqlite.sqlite3_bind_null(stmt.*, 1), db);
    }
}

fn directoryJumpCandidateBefore(
    now: i64,
    candidate: DirectoryJumpCandidate,
    best: DirectoryJumpCandidate,
) bool {
    const candidate_score = directoryJumpFrecencyScore(candidate, now);
    const best_score = directoryJumpFrecencyScore(best, now);
    if (candidate_score != best_score) return candidate_score > best_score;
    return false;
}

fn directoryHistoryFromCandidates(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(DirectoryJumpCandidate),
) !DirectoryHistory {
    const entries = try allocator.alloc(DirectoryHistory.DirectoryEntry, candidates.items.len);
    for (candidates.items, entries) |candidate, *entry| {
        entry.* = .{ .path = candidate.path };
    }
    candidates.deinit(allocator);
    candidates.* = .empty;
    return .{ .entries = entries };
}

fn directoryJumpFrecencyScore(candidate: DirectoryJumpCandidate, now: i64) f64 {
    return @as(f64, @floatFromInt(candidate.visits)) * directoryJumpRecencyMultiplier(candidate.last_seen, now);
}

fn directoryJumpRecencyMultiplier(last_seen: i64, now: i64) f64 {
    const age = @max(now - last_seen, 0);
    if (age < 60 * 60) return 4.0;
    if (age < 24 * 60 * 60) return 2.0;
    if (age < 7 * 24 * 60 * 60) return 0.5;
    return 0.25;
}

fn directoryJumpMatches(path: []const u8, terms: []const []const u8) bool {
    if (terms.len == 0) return true;
    var search_end = path.len;
    var term_index = terms.len;
    while (term_index > 0) {
        term_index -= 1;
        const term = terms[term_index];
        if (term.len == 0) continue;
        const index = lastIndexOfIgnoreCase(path[0..search_end], term) orelse return false;
        if (term_index == terms.len - 1 and pathComponentSeparatorAfter(path, index + term.len)) return false;
        search_end = index;
    }
    return true;
}

fn lastIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return haystack.len;
    if (needle.len > haystack.len) return null;
    var end = haystack.len - needle.len + 1;
    while (end > 0) {
        end -= 1;
        if (std.ascii.eqlIgnoreCase(haystack[end..][0..needle.len], needle)) return end;
    }
    return null;
}

fn pathComponentSeparatorAfter(path: []const u8, start: usize) bool {
    return std.mem.indexOfScalar(u8, path[start..], '/') != null;
}

fn queryHistoryEntry(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    prefix: []const u8,
    session_id: []const u8,
    session_start_id: i64,
    cursor: ?i64,
    direction: HistoryDirection,
) !?line_editor.HistoryView.HistoryEntry {
    var like_pattern: std.ArrayList(u8) = .empty;
    defer like_pattern.deinit(allocator);
    try appendSqlLikePrefix(allocator, &like_pattern, prefix);

    // Navigation walks by pure recency over this session's commands plus the
    // rows that existed at session start; duplicates keep only their most
    // recent visible occurrence.
    const sql = switch (direction) {
        .previous =>
        \\select id, command, started_at from history h
        \\where (?1 is null or id < ?1)
        \\  and (?2 = '' or command like ?2 escape '\')
        \\  and (h.session_id = ?3 or h.id <= ?4)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.id > h.id and newer.command_key = h.command_key
        \\      and (?2 = '' or newer.command like ?2 escape '\')
        \\      and (newer.session_id = ?3 or newer.id <= ?4)
        \\  )
        \\order by id desc limit 1
        ,
        .next =>
        \\select id, command, started_at from history h
        \\where id > ?1
        \\  and (?2 = '' or command like ?2 escape '\')
        \\  and (h.session_id = ?3 or h.id <= ?4)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.id > h.id and newer.command_key = h.command_key
        \\      and (?2 = '' or newer.command like ?2 escape '\')
        \\      and (newer.session_id = ?3 or newer.id <= ?4)
        \\  )
        \\order by id asc limit 1
        ,
    };
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    if (cursor) |id| {
        try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 1, id), db);
    } else {
        try sqliteCheck(sqlite.sqlite3_bind_null(stmt, 1), db);
    }
    try sqliteCheck(sqlite.sqlite3_bind_text(
        stmt,
        2,
        like_pattern.items.ptr,
        @intCast(like_pattern.items.len),
        null,
    ), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 3, session_id.ptr, @intCast(session_id.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 4, session_start_id), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse return null;
    return .{
        .id = sqlite.sqlite3_column_int64(stmt, 0),
        .text = try allocator.dupe(u8, std.mem.span(command_text)),
        .when = sqlite.sqlite3_column_int64(stmt, 2),
    };
}

fn queryMaxHistoryId(db: *sqlite.sqlite3) !i64 {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        "select coalesce(max(id), 0) from history",
        -1,
        &stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    return sqlite.sqlite3_column_int64(stmt, 0);
}

fn queryHistoryEntryByNumber(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    number: usize,
) !?line_editor.HistoryView.HistoryEntry {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        "select id, command, started_at from history where id = ?1",
        -1,
        &stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 1, @intCast(number)), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse return null;
    return .{
        .id = sqlite.sqlite3_column_int64(stmt, 0),
        .text = try allocator.dupe(u8, std.mem.span(command_text)),
        .when = sqlite.sqlite3_column_int64(stmt, 2),
    };
}

/// Window of recent entries visible to fc. Command numbers are absolute
/// rowids, so bounding the window only makes entries older than the window
/// unaddressable, mirroring HISTSIZE limits in other shells.
const fc_history_limit: i64 = 10_000;

fn queryFcHistoryEntries(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    limit: i64,
    excluded_id: ?i64,
) ![]HistoryEntry {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        \\select id, command from (
        \\  select id, command from history
        \\  where (?2 is null or id <> ?2)
        \\  order by id desc limit ?1
        \\) recent
        \\order by id asc
    ,
        -1,
        &stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 1, limit), db);
    if (excluded_id) |id| {
        try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 2, id), db);
    } else {
        try sqliteCheck(sqlite.sqlite3_bind_null(stmt, 2), db);
    }

    var entries: std.ArrayList(HistoryEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.command);
        entries.deinit(allocator);
    }
    while (true) {
        const rc = sqlite.sqlite3_step(stmt);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
        const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse continue;
        try entries.append(allocator, .{
            .number = sqlite.sqlite3_column_int64(stmt, 0),
            .command = try allocator.dupe(u8, std.mem.span(command_text)),
        });
    }
    return entries.toOwnedSlice(allocator);
}

fn queryHistoryEntriesContaining(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    text: []const u8,
    limit: i64,
    excluded_id: ?i64,
) ![]HistoryEntry {
    var like_pattern: std.ArrayList(u8) = .empty;
    defer like_pattern.deinit(allocator);
    try appendSqlLikeSubstring(allocator, &like_pattern, text);

    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        \\select id, command from (
        \\  select id, command from history
        \\  where command like ?1 escape '\' and (?3 is null or id <> ?3)
        \\  order by id desc limit ?2
        \\) recent
        \\order by id asc
    ,
        -1,
        &stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_text(
        stmt,
        1,
        like_pattern.items.ptr,
        @intCast(like_pattern.items.len),
        null,
    ), db);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 2, limit), db);
    if (excluded_id) |id| {
        try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 3, id), db);
    } else {
        try sqliteCheck(sqlite.sqlite3_bind_null(stmt, 3), db);
    }

    var entries: std.ArrayList(HistoryEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.command);
        entries.deinit(allocator);
    }
    while (true) {
        const rc = sqlite.sqlite3_step(stmt);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
        const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse continue;
        try entries.append(allocator, .{
            .number = sqlite.sqlite3_column_int64(stmt, 0),
            .command = try allocator.dupe(u8, std.mem.span(command_text)),
        });
    }
    return entries.toOwnedSlice(allocator);
}

fn deleteHistoryRecordById(db: *sqlite.sqlite3, id: i64) !bool {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        "delete from history where id = ?1",
        -1,
        &stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 1, id), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc != sqlite.SQLITE_DONE) try sqliteCheck(rc, db);
    return sqlite.sqlite3_changes(db) > 0;
}

fn queryLatestCommand(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    session_id: []const u8,
) !?[]const u8 {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    const sql = if (session_id.len == 0)
        "select command from history order by id desc limit 1"
    else
        "select command from history where session_id = ?1 order by id desc limit 1";
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    if (session_id.len != 0) {
        try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 1, session_id.ptr, @intCast(session_id.len), null), db);
    }
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 0) orelse return null;
    return try allocator.dupe(u8, std.mem.span(command_text));
}

fn queryHistorySuggestion(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    prefix: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    previous_command: []const u8,
) !?line_editor.HistoryView.HistoryEntry {
    _ = session_id;
    _ = previous_command;
    if (prefix.len == 0) return null;
    var like_pattern: std.ArrayList(u8) = .empty;
    defer like_pattern.deinit(allocator);
    try appendSqlLikePrefix(allocator, &like_pattern, prefix);

    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        \\select h.id, h.command, h.started_at
        \\from history h
        \\where h.command like ?1 escape '\'
        \\  and length(cast(h.command as blob)) > ?2
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command_key = h.command_key
        \\      and (
        \\        (newer.cwd = ?3 and h.cwd <> ?3) or
        \\        ((newer.cwd = ?3) = (h.cwd = ?3) and newer.id > h.id)
        \\      )
        \\  )
        \\order by (h.cwd = ?3) desc, h.id desc
        \\limit 1
    ,
        -1,
        &stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_text(
        stmt,
        1,
        like_pattern.items.ptr,
        @intCast(like_pattern.items.len),
        null,
    ), db);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 2, @intCast(prefix.len)), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 3, cwd.ptr, @intCast(cwd.len), null), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse return null;
    return .{
        .id = sqlite.sqlite3_column_int64(stmt, 0),
        .text = try allocator.dupe(u8, std.mem.span(command_text)),
        .when = sqlite.sqlite3_column_int64(stmt, 2),
    };
}

fn appendSqlLikePrefix(allocator: std.mem.Allocator, pattern: *std.ArrayList(u8), prefix: []const u8) !void {
    for (prefix) |byte| switch (byte) {
        '%', '_', '\\' => {
            try pattern.append(allocator, '\\');
            try pattern.append(allocator, byte);
        },
        else => try pattern.append(allocator, byte),
    };
    try pattern.append(allocator, '%');
}

fn appendSqlLikeSubstring(allocator: std.mem.Allocator, pattern: *std.ArrayList(u8), query: []const u8) !void {
    try pattern.append(allocator, '%');
    try appendSqlLikePrefix(allocator, pattern, query);
}

fn queryHistorySearchEntry(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    query: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    filters: line_editor.HistorySearchFilters,
    cursor: ?i64,
    direction: HistoryDirection,
) !?line_editor.HistoryView.HistoryEntry {
    // FTS can only express word-prefix matches, so queries with punctuation
    // (flags, paths, operators) switch to a literal substring match instead
    // of silently dropping the bytes FTS cannot tokenize.
    if (historySearchNeedsSubstring(query)) {
        return queryHistorySubstringSearchEntry(allocator, db, query, cwd, session_id, filters, cursor, direction);
    }
    var fts_query: std.ArrayList(u8) = .empty;
    defer fts_query.deinit(allocator);
    try appendHistoryFtsQuery(allocator, &fts_query, query);
    if (fts_query.items.len == 0) {
        return queryHistoryListEntry(allocator, db, cwd, session_id, filters, cursor, direction);
    }

    var stmt: ?*sqlite.sqlite3_stmt = null;
    const offset = if (cursor) |value| @max(value, 0) else 0;
    const sql = switch (direction) {
        .previous =>
        \\select h.id, h.command, h.started_at
        \\from history_fts f
        \\join history h on h.id = f.rowid
        \\where history_fts match ?1
        \\  and (?4 = 0 or h.cwd = ?2)
        \\  and (?5 = 0 or h.status = 0)
        \\  and (?6 = 0 or h.session_id = ?7)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command_key = h.command_key
        \\      and (?5 = 0 or newer.status = 0)
        \\      and (?6 = 0 or newer.session_id = ?7)
        \\      and (
        \\        (?4 <> 0 and newer.cwd = ?2 and newer.id > h.id) or
        \\        (?4 = 0 and (
        \\          (newer.cwd = ?2 and h.cwd <> ?2) or
        \\          ((newer.cwd = ?2) = (h.cwd = ?2) and newer.id > h.id)
        \\        ))
        \\      )
        \\  )
        \\order by (h.cwd = ?2) desc, h.id desc
        \\limit 1 offset ?3
        ,
        .next =>
        \\select h.id, h.command, h.started_at
        \\from history_fts f
        \\join history h on h.id = f.rowid
        \\where history_fts match ?1
        \\  and (?4 = 0 or h.cwd = ?2)
        \\  and (?5 = 0 or h.status = 0)
        \\  and (?6 = 0 or h.session_id = ?7)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command_key = h.command_key
        \\      and (?5 = 0 or newer.status = 0)
        \\      and (?6 = 0 or newer.session_id = ?7)
        \\      and (
        \\        (?4 <> 0 and newer.cwd = ?2 and newer.id > h.id) or
        \\        (?4 = 0 and (
        \\          (newer.cwd = ?2 and h.cwd <> ?2) or
        \\          ((newer.cwd = ?2) = (h.cwd = ?2) and newer.id > h.id)
        \\        ))
        \\      )
        \\  )
        \\order by (h.cwd = ?2) asc, h.id asc
        \\limit 1 offset ?3
        ,
    };
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 1, fts_query.items.ptr, @intCast(fts_query.items.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 2, cwd.ptr, @intCast(cwd.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 3, offset), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 4, @intFromBool(filters.cwd)), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 5, @intFromBool(filters.successful)), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 6, @intFromBool(filters.session)), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 7, session_id.ptr, @intCast(session_id.len), null), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse return null;
    return .{
        .id = offset + 1,
        .text = try allocator.dupe(u8, std.mem.span(command_text)),
        .when = sqlite.sqlite3_column_int64(stmt, 2),
    };
}

fn historySearchNeedsSubstring(query: []const u8) bool {
    for (query) |byte| {
        if (!historyFtsTokenByte(byte) and byte != ' ' and byte != '\t') return true;
    }
    return false;
}

fn queryHistorySubstringSearchEntry(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    query: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    filters: line_editor.HistorySearchFilters,
    cursor: ?i64,
    direction: HistoryDirection,
) !?line_editor.HistoryView.HistoryEntry {
    var like_pattern: std.ArrayList(u8) = .empty;
    defer like_pattern.deinit(allocator);
    try appendSqlLikeSubstring(allocator, &like_pattern, query);

    var stmt: ?*sqlite.sqlite3_stmt = null;
    const offset = if (cursor) |value| @max(value, 0) else 0;
    const sql = switch (direction) {
        .previous =>
        \\select h.id, h.command, h.started_at
        \\from history h
        \\where h.command like ?1 escape '\'
        \\  and (?4 = 0 or h.cwd = ?2)
        \\  and (?5 = 0 or h.status = 0)
        \\  and (?6 = 0 or h.session_id = ?7)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command_key = h.command_key
        \\      and (?5 = 0 or newer.status = 0)
        \\      and (?6 = 0 or newer.session_id = ?7)
        \\      and (
        \\        (?4 <> 0 and newer.cwd = ?2 and newer.id > h.id) or
        \\        (?4 = 0 and (
        \\          (newer.cwd = ?2 and h.cwd <> ?2) or
        \\          ((newer.cwd = ?2) = (h.cwd = ?2) and newer.id > h.id)
        \\        ))
        \\      )
        \\  )
        \\order by (h.cwd = ?2) desc, h.id desc
        \\limit 1 offset ?3
        ,
        .next =>
        \\select h.id, h.command, h.started_at
        \\from history h
        \\where h.command like ?1 escape '\'
        \\  and (?4 = 0 or h.cwd = ?2)
        \\  and (?5 = 0 or h.status = 0)
        \\  and (?6 = 0 or h.session_id = ?7)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command_key = h.command_key
        \\      and (?5 = 0 or newer.status = 0)
        \\      and (?6 = 0 or newer.session_id = ?7)
        \\      and (
        \\        (?4 <> 0 and newer.cwd = ?2 and newer.id > h.id) or
        \\        (?4 = 0 and (
        \\          (newer.cwd = ?2 and h.cwd <> ?2) or
        \\          ((newer.cwd = ?2) = (h.cwd = ?2) and newer.id > h.id)
        \\        ))
        \\      )
        \\  )
        \\order by (h.cwd = ?2) asc, h.id asc
        \\limit 1 offset ?3
        ,
    };
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_text(
        stmt,
        1,
        like_pattern.items.ptr,
        @intCast(like_pattern.items.len),
        null,
    ), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 2, cwd.ptr, @intCast(cwd.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 3, offset), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 4, @intFromBool(filters.cwd)), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 5, @intFromBool(filters.successful)), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 6, @intFromBool(filters.session)), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 7, session_id.ptr, @intCast(session_id.len), null), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse return null;
    return .{
        .id = offset + 1,
        .text = try allocator.dupe(u8, std.mem.span(command_text)),
        .when = sqlite.sqlite3_column_int64(stmt, 2),
    };
}

fn queryHistoryListEntry(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    cwd: []const u8,
    session_id: []const u8,
    filters: line_editor.HistorySearchFilters,
    cursor: ?i64,
    direction: HistoryDirection,
) !?line_editor.HistoryView.HistoryEntry {
    const offset = if (cursor) |value| @max(value, 0) else 0;
    const sql = switch (direction) {
        .previous =>
        \\select h.id, h.command, h.started_at
        \\from history h
        \\where (?1 = 0 or h.cwd = ?2)
        \\  and (?3 = 0 or h.status = 0)
        \\  and (?4 = 0 or h.session_id = ?5)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command_key = h.command_key
        \\      and (?1 = 0 or newer.cwd = ?2)
        \\      and (?3 = 0 or newer.status = 0)
        \\      and (?4 = 0 or newer.session_id = ?5)
        \\      and newer.id > h.id
        \\  )
        \\order by (h.cwd = ?2) desc, h.id desc
        \\limit 1 offset ?6
        ,
        .next =>
        \\select h.id, h.command, h.started_at
        \\from history h
        \\where (?1 = 0 or h.cwd = ?2)
        \\  and (?3 = 0 or h.status = 0)
        \\  and (?4 = 0 or h.session_id = ?5)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command_key = h.command_key
        \\      and (?1 = 0 or newer.cwd = ?2)
        \\      and (?3 = 0 or newer.status = 0)
        \\      and (?4 = 0 or newer.session_id = ?5)
        \\      and newer.id > h.id
        \\  )
        \\order by (h.cwd = ?2) asc, h.id asc
        \\limit 1 offset ?6
        ,
    };
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 1, @intFromBool(filters.cwd)), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 2, cwd.ptr, @intCast(cwd.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 3, @intFromBool(filters.successful)), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 4, @intFromBool(filters.session)), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 5, session_id.ptr, @intCast(session_id.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 6, offset), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse return null;
    return .{
        .id = offset + 1,
        .text = try allocator.dupe(u8, std.mem.span(command_text)),
        .when = sqlite.sqlite3_column_int64(stmt, 2),
    };
}

fn appendHistoryFtsQuery(allocator: std.mem.Allocator, output: *std.ArrayList(u8), query: []const u8) !void {
    var token_start: ?usize = null;
    for (query, 0..) |byte, index| {
        if (historyFtsTokenByte(byte)) {
            if (token_start == null) token_start = index;
        } else if (token_start) |start| {
            try appendHistoryFtsQueryToken(allocator, output, query[start..index]);
            token_start = null;
        }
    }
    if (token_start) |start| try appendHistoryFtsQueryToken(allocator, output, query[start..]);
}

fn historyFtsTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn appendHistoryFtsQueryToken(allocator: std.mem.Allocator, output: *std.ArrayList(u8), token: []const u8) !void {
    if (token.len == 0) return;
    if (output.items.len != 0) try output.append(allocator, ' ');
    try output.append(allocator, '"');
    try output.appendSlice(allocator, token);
    try output.appendSlice(allocator, "\"*");
}

fn openHistoryDb(allocator: std.mem.Allocator, path: []const u8) !*sqlite.sqlite3 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var db: ?*sqlite.sqlite3 = null;
    try sqliteCheck(sqlite.sqlite3_open_v2(
        path_z.ptr,
        &db,
        sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_NOMUTEX,
        null,
    ), db);
    errdefer if (db) |handle| {
        _ = sqlite.sqlite3_close(handle);
    };
    const handle = db.?;
    try configureHistoryDb(handle);
    try initHistorySchema(handle);
    try migrateHistoryCommandKeys(allocator, handle);
    return handle;
}

fn configureHistoryDb(db: *sqlite.sqlite3) !void {
    try sqliteExec(db,
        \\pragma busy_timeout = 5000;
        \\pragma journal_mode = wal;
        \\pragma synchronous = normal;
        \\pragma foreign_keys = on;
        \\pragma temp_store = memory;
    );
}

fn initHistorySchema(db: *sqlite.sqlite3) !void {
    if (sqlite.sqlite3_compileoption_used("ENABLE_FTS5") == 0) return error.SqliteFts5Unavailable;
    try sqliteExec(db,
        \\create table if not exists history (
        \\  id integer primary key,
        \\  command text not null,
        \\  command_key text not null default '',
        \\  cwd text not null,
        \\  status integer not null,
        \\  exit_signal integer,
        \\  started_at integer not null,
        \\  duration_ms integer,
        \\  hostname text not null default '',
        \\  session_id text not null default ''
        \\);
        \\create virtual table if not exists history_fts using fts5(
        \\  command,
        \\  content='history',
        \\  content_rowid='id'
        \\);
        \\create trigger if not exists history_ai after insert on history begin
        \\  insert into history_fts(rowid, command) values (new.id, new.command);
        \\end;
        \\create trigger if not exists history_ad after delete on history begin
        \\  insert into history_fts(history_fts, rowid, command) values('delete', old.id, old.command);
        \\end;
        \\drop trigger if exists history_au;
        \\create trigger history_au after update of command on history begin
        \\  insert into history_fts(history_fts, rowid, command) values('delete', old.id, old.command);
        \\  insert into history_fts(rowid, command) values (new.id, new.command);
        \\end;
    );
    try ensureHistoryCommandKeyColumn(db);
    try sqliteExec(db,
        \\create index if not exists history_started_idx on history(started_at);
        \\create index if not exists history_command_started_idx on history(command, started_at);
        \\create index if not exists history_command_id_idx on history(command, id);
        \\create index if not exists history_command_key_id_idx on history(command_key, id);
        \\create index if not exists history_command_nocase_id_idx on history(command collate nocase, id);
        \\create index if not exists history_cwd_id_idx on history(cwd, id);
        \\create index if not exists history_status_id_idx on history(status, id);
        \\create index if not exists history_session_id_idx on history(session_id, id);
    );
}

fn ensureHistoryCommandKeyColumn(db: *sqlite.sqlite3) !void {
    if (try historyColumnExists(db, "command_key")) return;
    try sqliteExec(db, "alter table history add column command_key text not null default '';");
}

fn historyColumnExists(db: *sqlite.sqlite3, name: []const u8) !bool {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, "pragma table_info(history)", -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);

    while (true) {
        const rc = sqlite.sqlite3_step(stmt);
        if (rc == sqlite.SQLITE_DONE) return false;
        if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
        const column_name = sqlite.sqlite3_column_text(stmt, 1) orelse continue;
        if (std.mem.eql(u8, std.mem.span(column_name), name)) return true;
    }
}

fn deleteFileIfExists(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn deleteHistoryDbFilesIfExists(io: std.Io, path: []const u8) !void {
    var wal_buffer: [4096]u8 = undefined;
    var shm_buffer: [4096]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_buffer, "{s}-wal", .{path});
    const shm_path = try std.fmt.bufPrint(&shm_buffer, "{s}-shm", .{path});

    try deleteFileIfExists(io, path);
    try deleteFileIfExists(io, wal_path);
    try deleteFileIfExists(io, shm_path);
}

fn migrateHistoryCommandKeys(allocator: std.mem.Allocator, db: *sqlite.sqlite3) !void {
    var select_stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        "select id, command from history where command_key = ''",
        -1,
        &select_stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(select_stmt);

    var update_stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        "update history set command_key = ?1 where id = ?2",
        -1,
        &update_stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(update_stmt);

    while (true) {
        const rc = sqlite.sqlite3_step(select_stmt);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
        const command_text = sqlite.sqlite3_column_text(select_stmt, 1) orelse continue;
        const command = std.mem.span(command_text);
        const command_key = try historyCommandKey(allocator, command);
        defer allocator.free(command_key);

        try sqliteCheck(sqlite.sqlite3_bind_text(
            update_stmt,
            1,
            command_key.ptr,
            @intCast(command_key.len),
            null,
        ), db);
        try sqliteCheck(sqlite.sqlite3_bind_int64(update_stmt, 2, sqlite.sqlite3_column_int64(select_stmt, 0)), db);
        const update_rc = sqlite.sqlite3_step(update_stmt);
        if (update_rc != sqlite.SQLITE_DONE) try sqliteCheck(update_rc, db);
        try sqliteCheck(sqlite.sqlite3_reset(update_stmt), db);
        try sqliteCheck(sqlite.sqlite3_clear_bindings(update_stmt), db);
    }
}

fn insertHistoryRecord(db: *sqlite.sqlite3, record: History.HistoryRecord) !void {
    _ = try insertHistoryRecordWithAllocator(std.testing.allocator, db, record);
}

fn insertHistoryRecordWithAllocator(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    record: History.HistoryRecord,
) !i64 {
    const command_key = try historyCommandKey(allocator, record.cmd);
    defer allocator.free(command_key);

    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        \\insert into history(command, command_key, cwd, status, exit_signal,
        \\  started_at, duration_ms, hostname, session_id)
        \\values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
    ,
        -1,
        &stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 1, record.cmd.ptr, @intCast(record.cmd.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 2, command_key.ptr, @intCast(command_key.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 3, record.cwd.ptr, @intCast(record.cwd.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 4, record.status), db);
    if (record.exit_signal) |signal| {
        try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 5, signal), db);
    } else {
        try sqliteCheck(sqlite.sqlite3_bind_null(stmt, 5), db);
    }
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 6, record.when), db);
    if (record.duration_ms) |duration_ms| {
        try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 7, duration_ms), db);
    } else {
        try sqliteCheck(sqlite.sqlite3_bind_null(stmt, 7), db);
    }
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 8, record.hostname.ptr, @intCast(record.hostname.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(
        stmt,
        9,
        record.session_id.ptr,
        @intCast(record.session_id.len),
        null,
    ), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc != sqlite.SQLITE_DONE) try sqliteCheck(rc, db);
    const id = sqlite.sqlite3_last_insert_rowid(db);
    std.debug.assert(id > 0);
    return id;
}

fn updateHistoryRecordResult(
    db: *sqlite.sqlite3,
    id: i64,
    status: ExitStatus,
    duration_ms: i64,
) !void {
    std.debug.assert(id > 0);
    std.debug.assert(duration_ms >= 0);
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        \\update history
        \\set status = ?1, exit_signal = ?2, duration_ms = ?3
        \\where id = ?4
    ,
        -1,
        &stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 1, status), db);
    if (exitSignalFromStatus(status)) |signal| {
        try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 2, signal), db);
    } else {
        try sqliteCheck(sqlite.sqlite3_bind_null(stmt, 2), db);
    }
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 3, duration_ms), db);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 4, id), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc != sqlite.SQLITE_DONE) try sqliteCheck(rc, db);
}

fn historyCommandKey(allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const src: shell_source.Source = .{ .id = 0, .kind = .interactive, .name = "history", .text = command };
    const tokens = try shell_lexer.lex(arena.allocator(), src);

    var key: std.ArrayList(u8) = .empty;
    errdefer key.deinit(allocator);
    for (tokens) |tok| {
        if (tok.kind == .eof) break;
        if (key.items.len != 0) try key.append(allocator, ' ');
        try key.appendSlice(allocator, command[tok.span.start..tok.span.end]);
    }
    if (key.items.len == 0) return allocator.dupe(u8, command);
    return key.toOwnedSlice(allocator);
}

fn sqliteExec(db: *sqlite.sqlite3, sql: [:0]const u8) !void {
    var message: [*c]u8 = null;
    const rc = sqlite.sqlite3_exec(db, sql.ptr, null, null, &message);
    if (message) |text| sqlite.sqlite3_free(text);
    try sqliteCheck(rc, db);
}

fn sqliteCheck(rc: c_int, db: ?*sqlite.sqlite3) !void {
    switch (rc) {
        sqlite.SQLITE_OK, sqlite.SQLITE_ROW, sqlite.SQLITE_DONE => {},
        else => {
            _ = db;
            return error.SqliteError;
        },
    }
}

fn historyFtsMatchCount(db: *sqlite.sqlite3, query: []const u8) !c_int {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        "select count(*) from history_fts where history_fts match ?1",
        -1,
        &stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 1, query.ptr, @intCast(query.len), null), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    return sqlite.sqlite3_column_int(stmt, 0);
}

fn expectLatestHistoryRecord(db: *sqlite.sqlite3, expected: History.HistoryRecord) !void {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        "select command, status, exit_signal, duration_ms, cwd from history order by id desc limit 1",
        -1,
        &stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command = sqlite.sqlite3_column_text(stmt, 0) orelse return error.ExpectedHistoryCommand;
    const cwd = sqlite.sqlite3_column_text(stmt, 4) orelse return error.ExpectedHistoryCwd;
    const exit_signal: ?u8 = if (sqlite.sqlite3_column_type(stmt, 2) == sqlite.SQLITE_NULL)
        null
    else
        @intCast(sqlite.sqlite3_column_int(stmt, 2));
    const duration_ms: ?i64 = if (sqlite.sqlite3_column_type(stmt, 3) == sqlite.SQLITE_NULL)
        null
    else
        sqlite.sqlite3_column_int64(stmt, 3);
    try std.testing.expectEqualStrings(expected.cmd, std.mem.span(command));
    try std.testing.expectEqual(expected.status, @as(ExitStatus, @intCast(sqlite.sqlite3_column_int(stmt, 1))));
    try std.testing.expectEqual(expected.exit_signal, exit_signal);
    try std.testing.expectEqual(expected.duration_ms, duration_ms);
    try std.testing.expectEqualStrings(expected.cwd, std.mem.span(cwd));
}

pub fn localHostname(allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&buffer) catch return allocator.dupe(u8, "");
    return allocator.dupe(u8, hostname);
}

pub fn sessionId(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const pid = std.c.getpid();
    const started_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
    return std.fmt.allocPrint(allocator, "{d}:{d}", .{ pid, started_ns });
}

pub fn defaultPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !?[]const u8 {
    if (environ_map.get("XDG_STATE_HOME")) |xdg_state_home| {
        if (xdg_state_home.len != 0)
            return try std.fs.path.join(allocator, &.{ xdg_state_home, "rush", "history.sqlite" });
    }
    if (environ_map.get("HOME")) |home| {
        if (home.len != 0)
            return try std.fs.path.join(allocator, &.{ home, ".local", "state", "rush", "history.sqlite" });
    }
    return null;
}

test "in-memory history stores commands and suggests by prefix" {
    var history = try History.init(std.testing.allocator);
    defer history.deinit();

    try history.addCommand(std.testing.io, "echo first", 0, 1, 1);
    try history.addCommand(std.testing.io, "git status", 0, 2, 1);
    try history.addCommand(std.testing.io, "echo second", 0, 3, 1);

    const suggestion = (try history.suggestEntry(std.testing.allocator, "ec", "", "", "")).?;
    defer suggestion.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo second", suggestion.text);
    try std.testing.expect((try history.suggestEntry(std.testing.allocator, "missing", "", "", "")) == null);
}

test "history reload keeps commands in chronological order" {
    const path = "rush-history-recent-order-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try history.addCommand(std.testing.io, "echo old", 0, 10, 1);
    try history.addCommand(std.testing.io, "echo new", 0, 20, 1);

    var reloaded = try History.init(std.testing.allocator);
    defer reloaded.deinit();
    try reloaded.load(std.testing.io, path);
    const entries = try reloaded.fcEntries(std.testing.allocator);
    defer {
        for (entries) |entry| std.testing.allocator.free(entry.command);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("echo old", entries[0].command);
    try std.testing.expectEqualStrings("echo new", entries[1].command);

    var service = InteractiveHistoryService.init(&reloaded);
    const menu_entry = (try service.searchEntry(std.testing.allocator, "", .{}, null)).?;
    defer menu_entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo new", menu_entry.text);
}

test "history writes commands through to sqlite fts" {
    const path = "rush-history-fts-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try history.addCommand(std.testing.io, "git checkout feature", 130, 1234, 55);

    var reloaded = try History.init(std.testing.allocator);
    defer reloaded.deinit();
    try reloaded.load(std.testing.io, path);
    try expectLatestHistoryRecord(reloaded.db, .{
        .cmd = "git checkout feature",
        .status = 130,
        .exit_signal = 2,
        .duration_ms = 55,
    });

    const count = try historyFtsMatchCount(reloaded.db, "checkout");
    try std.testing.expectEqual(@as(c_int, 1), count);
}

test "history persists commands before execution and updates their result" {
    const path = "rush-history-command-lifecycle-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    history.current_cwd = "/repo";
    history.session_id = "session-a";

    const handle = (try history.startCommand(std.testing.io, "sleep 100", 1234)).?;

    // The executing command is hidden from this session, so `fc` and the
    // history builtin retain their pre-execution view.
    const active_entries = try history.fcEntries(std.testing.allocator);
    defer std.testing.allocator.free(active_entries);
    try std.testing.expectEqual(@as(usize, 0), active_entries.len);

    // A separate history instance models a new shell after an abrupt exit:
    // the committed row is already present without a completion update.
    {
        var interrupted = try History.init(std.testing.allocator);
        defer interrupted.deinit();
        try interrupted.load(std.testing.io, path);
        try expectLatestHistoryRecord(interrupted.db, .{
            .cmd = "sleep 100",
            .status = 1,
            .cwd = "/repo",
        });
    }

    try history.finishCommand(handle, 130, 55);

    const finished_entries = try history.fcEntries(std.testing.allocator);
    defer {
        for (finished_entries) |entry| std.testing.allocator.free(entry.command);
        std.testing.allocator.free(finished_entries);
    }
    try std.testing.expectEqual(@as(usize, 1), finished_entries.len);
    try std.testing.expectEqualStrings("sleep 100", finished_entries[0].command);

    var completed = try History.init(std.testing.allocator);
    defer completed.deinit();
    try completed.load(std.testing.io, path);
    try expectLatestHistoryRecord(completed.db, .{
        .cmd = "sleep 100",
        .status = 130,
        .exit_signal = 2,
        .duration_ms = 55,
        .cwd = "/repo",
    });
}

test "history can discard a suppressed active command" {
    const path = "rush-history-command-discard-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    const handle = (try history.startCommand(std.testing.io, "history clear", 10)).?;
    try history.discardCommand(handle);

    const entries = try history.fcEntries(std.testing.allocator);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
    try std.testing.expectEqual(@as(c_int, 0), try historyFtsMatchCount(history.db, "history"));
}

test "in-memory sqlite active command identity survives deletion and append" {
    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.addCommand(std.testing.io, "echo older", 0, 1, 1);

    const handle = (try history.startCommand(std.testing.io, "fc -s", 2)).?;
    try std.testing.expect(try history.deleteEntry(1));
    try history.appendCommand(std.testing.io, "echo reexecuted", 0, 3, 1);

    const active_entries = try history.fcEntries(std.testing.allocator);
    defer {
        for (active_entries) |entry| std.testing.allocator.free(entry.command);
        std.testing.allocator.free(active_entries);
    }
    try std.testing.expectEqual(@as(usize, 1), active_entries.len);
    try std.testing.expectEqualStrings("echo reexecuted", active_entries[0].command);

    var service = InteractiveHistoryService.init(&history);
    service.suppressNextAppend();
    try service.completeCommand(handle, 2, 1);
    try std.testing.expect(!service.consumeSuppressNextAppend());
    const remaining_entries = try history.fcEntries(std.testing.allocator);
    defer {
        for (remaining_entries) |entry| std.testing.allocator.free(entry.command);
        std.testing.allocator.free(remaining_entries);
    }
    try std.testing.expectEqual(@as(usize, 1), remaining_entries.len);
    try std.testing.expectEqualStrings("echo reexecuted", remaining_entries[0].command);
}

test "history exposes POSIX fc command numbers from sqlite" {
    const path = "rush-history-fc-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try history.addCommand(std.testing.io, "printf 'one\\n'", 0, 10, 1);
    try history.addCommand(std.testing.io, "printf 'two\\n'", 0, 20, 1);

    const entries = try history.fcEntries(std.testing.allocator);
    defer {
        for (entries) |entry| std.testing.allocator.free(entry.command);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(i64, 1), entries[0].number);
    try std.testing.expectEqualStrings("printf 'one\\n'", entries[0].command);
    try std.testing.expectEqual(@as(i64, 2), entries[1].number);
    try std.testing.expectEqualStrings("printf 'two\\n'", entries[1].command);
}

test "history reports the next command number" {
    var history = try History.init(std.testing.allocator);
    defer history.deinit();

    try std.testing.expectEqual(@as(i64, 1), try history.nextCommandNumber());
    try history.addCommand(std.testing.io, "echo one", 0, 1, 1);
    try std.testing.expectEqual(@as(i64, 2), try history.nextCommandNumber());
}

test "history search filters with fts and orders newest first" {
    const path = "rush-history-fts-search-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try history.addCommand(std.testing.io, "git status", 0, 10, 1);
    try history.addCommand(std.testing.io, "git switch feature", 0, 20, 1);
    try history.addCommand(std.testing.io, "git status", 0, 30, 1);
    try history.addCommand(std.testing.io, "echo git status", 0, 40, 1);

    const first = (try history.searchEntry(std.testing.allocator, "git sta", "", "", .{}, null)).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo git status", first.text);
    try std.testing.expectEqual(@as(i64, 40), first.when);

    const second = (try history.searchEntry(std.testing.allocator, "git sta", "", "", .{}, first.id)).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("git status", second.text);
    try std.testing.expectEqual(@as(i64, 30), second.when);

    try std.testing.expect(try history.searchEntry(std.testing.allocator, "gco", "", "", .{}, null) == null);
}

test "history search matches punctuation queries as substrings" {
    const path = "rush-history-substring-search-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try insertHistoryRecord(history.db, .{ .cmd = "ls -la", .when = 10 });
    try insertHistoryRecord(history.db, .{ .cmd = "echo la la", .when = 20 });
    try insertHistoryRecord(history.db, .{ .cmd = "git push --force", .when = 30 });

    const force = (try history.searchEntry(std.testing.allocator, "--force", "", "", .{}, null)).?;
    defer force.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("git push --force", force.text);
    try std.testing.expect(try history.searchEntry(std.testing.allocator, "--force", "", "", .{}, force.id) == null);

    // "-la" is a literal substring: it matches the flag, not the word "la".
    const flag = (try history.searchEntry(std.testing.allocator, "-la", "", "", .{}, null)).?;
    defer flag.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ls -la", flag.text);

    // Word-only queries keep FTS token-prefix semantics.
    const word = (try history.searchEntry(std.testing.allocator, "la", "", "", .{}, null)).?;
    defer word.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo la la", word.text);
}

test "history fc entries are bounded to the most recent window" {
    const path = "rush-history-fc-window-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try insertHistoryRecord(history.db, .{ .cmd = "echo one", .when = 10 });
    try insertHistoryRecord(history.db, .{ .cmd = "echo two", .when = 20 });
    try insertHistoryRecord(history.db, .{ .cmd = "echo three", .when = 30 });

    const entries = try queryFcHistoryEntries(std.testing.allocator, history.db, 2, null);
    defer {
        for (entries) |entry| std.testing.allocator.free(entry.command);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("echo two", entries[0].command);
    try std.testing.expectEqual(@as(i64, 2), entries[0].number);
    try std.testing.expectEqualStrings("echo three", entries[1].command);
    try std.testing.expectEqual(@as(i64, 3), entries[1].number);
}

test "history search ranks current cwd first while deduping commands globally" {
    const path = "rush-history-fts-cwd-search-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try insertHistoryRecord(history.db, .{ .cmd = "git status", .cwd = "/repo", .when = 10 });
    try insertHistoryRecord(history.db, .{ .cmd = "git switch feature", .cwd = "/repo", .when = 20 });
    try insertHistoryRecord(history.db, .{ .cmd = "git status", .cwd = "/other", .when = 30 });
    try insertHistoryRecord(history.db, .{ .cmd = "echo git status", .cwd = "/other", .when = 40 });

    const first = (try history.searchEntry(std.testing.allocator, "git sta", "/repo", "", .{}, null)).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("git status", first.text);
    try std.testing.expectEqual(@as(i64, 10), first.when);

    const second = (try history.searchEntry(std.testing.allocator, "git sta", "/repo", "", .{}, first.id)).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo git status", second.text);
    try std.testing.expectEqual(@as(i64, 40), second.when);
}

test "history search and autosuggest dedupe whitespace variants" {
    const path = "rush-history-whitespace-dedupe-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try insertHistoryRecord(history.db, .{
        .cmd = "zig build  run-lua-bar-example",
        .cwd = "/repo",
        .when = 10,
    });
    try insertHistoryRecord(history.db, .{
        .cmd = "zig build run-lua-bar-example ",
        .cwd = "/repo",
        .when = 20,
    });

    const first = (try history.searchEntry(std.testing.allocator, "zig build run", "/repo", "", .{}, null)).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zig build run-lua-bar-example ", first.text);
    const missing = try history.searchEntry(std.testing.allocator, "zig build run", "/repo", "", .{}, first.id);
    try std.testing.expect(missing == null);

    const suggestion = (try history.suggestEntry(std.testing.allocator, "zig build", "/repo", "", "")).?;
    defer suggestion.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zig build run-lua-bar-example ", suggestion.text);

    const entries = try history.fcEntries(std.testing.allocator);
    defer {
        for (entries) |entry| std.testing.allocator.free(entry.command);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
}

test "history load migrates whitespace dedupe keys for old sqlite databases" {
    const path = "rush-history-command-key-migration-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    var db: ?*sqlite.sqlite3 = null;
    try sqliteCheck(sqlite.sqlite3_open_v2(
        path_z.ptr,
        &db,
        sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_NOMUTEX,
        null,
    ), db);
    const handle = db.?;
    errdefer _ = sqlite.sqlite3_close(handle);
    try sqliteExec(handle,
        \\create table history (
        \\  id integer primary key,
        \\  command text not null,
        \\  cwd text not null,
        \\  status integer not null,
        \\  exit_signal integer,
        \\  started_at integer not null,
        \\  duration_ms integer,
        \\  hostname text not null default '',
        \\  session_id text not null default ''
        \\);
        \\insert into history(command, cwd, status, started_at) values
        \\  ('zig build  run-lua-bar-example', '/repo', 0, 10),
        \\  ('zig build run-lua-bar-example ', '/repo', 0, 20);
    );
    try sqliteCheck(sqlite.sqlite3_close(handle), null);

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);

    const suggestion = (try history.suggestEntry(std.testing.allocator, "zig build", "/repo", "", "")).?;
    defer suggestion.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zig build run-lua-bar-example ", suggestion.text);
}

test "history search filters by cwd status and session" {
    const path = "rush-history-search-filter-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try insertHistoryRecord(history.db, .{
        .cmd = "git repo failed",
        .cwd = "/repo",
        .status = 1,
        .when = 10,
        .session_id = "session-a",
    });
    try insertHistoryRecord(history.db, .{
        .cmd = "git other ok",
        .cwd = "/other",
        .status = 0,
        .when = 20,
        .session_id = "session-a",
    });
    try insertHistoryRecord(history.db, .{
        .cmd = "git repo other-session",
        .cwd = "/repo",
        .status = 0,
        .when = 30,
        .session_id = "session-b",
    });
    try insertHistoryRecord(history.db, .{
        .cmd = "git repo ok",
        .cwd = "/repo",
        .status = 0,
        .when = 40,
        .session_id = "session-a",
    });

    const cwd_match = (try history.searchEntry(
        std.testing.allocator,
        "git",
        "/repo",
        "session-a",
        .{ .cwd = true },
        null,
    )).?;
    defer cwd_match.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("git repo ok", cwd_match.text);

    const successful_match = (try history.searchEntry(
        std.testing.allocator,
        "git repo failed",
        "/repo",
        "session-a",
        .{ .successful = true },
        null,
    ));
    try std.testing.expect(successful_match == null);

    const session_match = (try history.searchEntry(
        std.testing.allocator,
        "git repo other",
        "/repo",
        "session-a",
        .{ .session = true },
        null,
    ));
    try std.testing.expect(session_match == null);
}

test "history navigation walks recency across directories and dedupes commands" {
    const path = "rush-history-recency-navigation-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try insertHistoryRecord(history.db, .{ .cmd = "echo repo-a", .cwd = "/repo/a", .when = 10 });
    try insertHistoryRecord(history.db, .{ .cmd = "echo repo-b", .cwd = "/repo/b", .when = 20 });
    try insertHistoryRecord(history.db, .{ .cmd = "git status", .cwd = "/repo/a", .when = 30 });
    try insertHistoryRecord(history.db, .{ .cmd = "git status", .cwd = "/repo/b", .when = 40 });

    const newest = (try history.previousEntry(std.testing.allocator, "", null)).?;
    defer newest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("git status", newest.text);
    try std.testing.expectEqual(@as(i64, 40), newest.when);

    // The older duplicate "git status" is hidden; recency continues across cwds.
    const older = (try history.previousEntry(std.testing.allocator, "", newest.id)).?;
    defer older.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo repo-b", older.text);

    const oldest = (try history.previousEntry(std.testing.allocator, "", older.id)).?;
    defer oldest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo repo-a", oldest.text);

    const next = (try history.nextEntry(std.testing.allocator, "", oldest.id)).?;
    defer next.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo repo-b", next.text);

    const repo_b_suggestion = (try history.suggestEntry(std.testing.allocator, "echo", "/repo/b", "", "")).?;
    defer repo_b_suggestion.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo repo-b", repo_b_suggestion.text);
}

test "history directory jump ranks frecent matching directories" {
    const path = "rush-history-directory-jump-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try insertHistoryRecord(history.db, .{ .cmd = "old", .cwd = "/work/project-old", .when = 100 });
    try insertHistoryRecord(history.db, .{ .cmd = "one", .cwd = "/work/project-new", .when = 200 });
    try insertHistoryRecord(history.db, .{ .cmd = "two", .cwd = "/work/project-new", .when = 300 });
    try insertHistoryRecord(history.db, .{ .cmd = "other", .cwd = "/tmp/project", .when = 1_000 });

    const target = (try history.jumpDirectory(std.testing.allocator, &.{"proj"}, "", 1_000)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("/work/project-new", target);

    var directories = try history.rankDirectories(std.testing.allocator, &.{"proj"}, "", 1_000);
    defer directories.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), directories.entries.len);
    try std.testing.expectEqualStrings("/work/project-new", directories.entries[0].path);
}

test "history directory jump matches multiple terms in path order" {
    const path = "rush-history-directory-jump-terms-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try insertHistoryRecord(history.db, .{ .cmd = "one", .cwd = "/src/rush/website", .when = 100 });
    try insertHistoryRecord(history.db, .{ .cmd = "two", .cwd = "/src/website/rush", .when = 200 });

    const target = (try history.jumpDirectory(std.testing.allocator, &.{ "rush", "web" }, "", 200)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("/src/rush/website", target);

    try std.testing.expect(try history.jumpDirectory(std.testing.allocator, &.{"missing"}, "", 200) == null);
}

test "history directory jump mirrors zoxide keyword matching" {
    const path = "rush-history-directory-jump-zoxide-match-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try insertHistoryRecord(history.db, .{ .cmd = "one", .cwd = "/foo/bar", .when = 100 });
    try insertHistoryRecord(history.db, .{ .cmd = "two", .cwd = "/foo/baz", .when = 200 });
    try insertHistoryRecord(history.db, .{ .cmd = "three", .cwd = "/foo/baz", .when = 300 });

    const basename_match = (try history.jumpDirectory(std.testing.allocator, &.{"ba"}, "", 300)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(basename_match);
    try std.testing.expectEqualStrings("/foo/baz", basename_match);

    try std.testing.expect(try history.jumpDirectory(std.testing.allocator, &.{"fo"}, "", 300) == null);
    try std.testing.expect(try history.jumpDirectory(std.testing.allocator, &.{ "foo", "o", "bar" }, "", 300) == null);
    const excluded_current = (try history.jumpDirectory(std.testing.allocator, &.{"ba"}, "/foo/baz", 300)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(excluded_current);
    try std.testing.expectEqualStrings("/foo/bar", excluded_current);
}

test "history autosuggestion ranks cwd matches before global recency" {
    const path = "rush-history-cwd-suggestion-ranking-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try insertHistoryRecord(history.db, .{ .cmd = "ls repo", .cwd = "/repo", .when = 10 });
    try insertHistoryRecord(history.db, .{ .cmd = "ls other", .cwd = "/other", .when = 20 });

    const suggestion = (try history.suggestEntry(std.testing.allocator, "ls", "/repo", "", "")).?;
    defer suggestion.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ls repo", suggestion.text);
}

test "history autosuggestion follows menu order instead of command sequences" {
    const path = "rush-history-sequence-suggestion-ranking-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    history.current_cwd = "/repo";
    history.session_id = "session-a";
    try insertHistoryRecord(history.db, .{
        .cmd = "git status",
        .cwd = "/other",
        .when = 10,
        .session_id = "session-a",
    });
    try insertHistoryRecord(history.db, .{
        .cmd = "echo interleaved",
        .cwd = "/other",
        .when = 20,
        .session_id = "session-b",
    });
    try insertHistoryRecord(history.db, .{
        .cmd = "zig build test",
        .cwd = "/other",
        .when = 30,
        .session_id = "session-a",
    });
    try insertHistoryRecord(history.db, .{
        .cmd = "zig fmt .",
        .cwd = "/repo",
        .when = 40,
        .session_id = "session-a",
    });
    try insertHistoryRecord(history.db, .{
        .cmd = "git status",
        .cwd = "/repo",
        .when = 50,
        .session_id = "session-a",
    });

    var service = InteractiveHistoryService.init(&history);
    const suggestion = (try service.suggestEntry(std.testing.allocator, "zig")) orelse return error.TestExpectedEqual;
    defer suggestion.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zig fmt .", suggestion.text);
}

test "history autosuggestion does not rank other session sequences" {
    const path = "rush-history-other-session-suggestion-ranking-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    history.current_cwd = "/repo";
    history.session_id = "session-a";
    try insertHistoryRecord(history.db, .{
        .cmd = "git status",
        .cwd = "/other",
        .when = 10,
        .session_id = "session-b",
    });
    try insertHistoryRecord(history.db, .{
        .cmd = "zig build test",
        .cwd = "/other",
        .when = 20,
        .session_id = "session-b",
    });
    try insertHistoryRecord(history.db, .{
        .cmd = "zig fmt .",
        .cwd = "/repo",
        .when = 30,
        .session_id = "session-a",
    });
    try insertHistoryRecord(history.db, .{
        .cmd = "git status",
        .cwd = "/repo",
        .when = 40,
        .session_id = "session-a",
    });

    var service = InteractiveHistoryService.init(&history);
    const suggestion = (try service.suggestEntry(std.testing.allocator, "zig")) orelse return error.TestExpectedEqual;
    defer suggestion.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zig fmt .", suggestion.text);
}

test "interactive history writes and reads the current cwd" {
    const path = "rush-history-current-cwd-write-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    history.current_cwd = "/repo";
    history.session_id = "session-a";
    try history.addCommand(std.testing.io, "echo hello", 0, 10, 5);

    const entry = (try history.previousEntry(std.testing.allocator, "", null)).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo hello", entry.text);

    var service = InteractiveHistoryService.init(&history);
    const suggestion = (try service.suggestEntry(std.testing.allocator, "echo")) orelse return error.TestExpectedEqual;
    defer suggestion.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo hello", suggestion.text);
}

test "history skips commands with a leading space" {
    const path = "rush-history-ignorespace-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    history.current_cwd = "/repo";
    history.session_id = "session-a";
    try history.addCommand(std.testing.io, "echo visible", 0, 10, 5);
    try history.addCommand(std.testing.io, " export TOKEN=secret", 0, 20, 5);

    const newest = (try history.previousEntry(std.testing.allocator, "", null)).?;
    defer newest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo visible", newest.text);
    try std.testing.expect((try history.previousEntry(std.testing.allocator, "", newest.id)) == null);
    const searched = try history.searchEntry(std.testing.allocator, "TOKEN", "/repo", "session-a", .{}, null);
    try std.testing.expect(searched == null);
}

test "history search delete and clear manage sqlite entries" {
    const path = "rush-history-manage-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try insertHistoryRecord(history.db, .{ .cmd = "export TOKEN=abc", .when = 10 });
    try insertHistoryRecord(history.db, .{ .cmd = "ls -la", .when = 20 });
    try insertHistoryRecord(history.db, .{ .cmd = "echo TOKEN done", .when = 30 });

    const matches = try history.searchEntries(std.testing.allocator, "token");
    defer {
        for (matches) |entry| std.testing.allocator.free(entry.command);
        std.testing.allocator.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("export TOKEN=abc", matches[0].command);
    try std.testing.expectEqual(@as(i64, 1), matches[0].number);
    try std.testing.expectEqualStrings("echo TOKEN done", matches[1].command);

    try std.testing.expect(try history.deleteEntry(1));
    try std.testing.expect(!try history.deleteEntry(99));

    // The delete trigger keeps the FTS index in sync for reverse search.
    try std.testing.expect(try history.searchEntry(std.testing.allocator, "abc", "", "", .{}, null) == null);
    const remaining = try history.searchEntries(std.testing.allocator, "token");
    defer {
        for (remaining) |entry| std.testing.allocator.free(entry.command);
        std.testing.allocator.free(remaining);
    }
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expectEqualStrings("echo TOKEN done", remaining[0].command);

    try history.clearEntries();
    const cleared = try history.fcEntries(std.testing.allocator);
    defer std.testing.allocator.free(cleared);
    try std.testing.expectEqual(@as(usize, 0), cleared.len);
}

test "interactive autosuggestion falls back to global sqlite history" {
    const path = "rush-history-global-suggestion-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = try History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    history.current_cwd = "/repo";
    try insertHistoryRecord(history.db, .{ .cmd = "ls -la", .cwd = "/other", .when = 10 });

    var service = InteractiveHistoryService.init(&history);
    const suggestion = (try service.suggestEntry(std.testing.allocator, "l")) orelse return error.TestExpectedEqual;
    defer suggestion.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ls -la", suggestion.text);
}

test "line history walks session commands then history from session start" {
    const path = "rush-history-session-navigation-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history_a = try History.init(std.testing.allocator);
    defer history_a.deinit();
    try history_a.load(std.testing.io, path);
    history_a.current_cwd = "/repo";
    history_a.session_id = "session-a";
    var history_service_a = InteractiveHistoryService.init(&history_a);
    try insertHistoryRecord(history_a.db, .{
        .cmd = "echo a-one",
        .cwd = "/repo",
        .when = 10,
        .session_id = "session-a",
    });
    try insertHistoryRecord(history_a.db, .{
        .cmd = "echo b-one",
        .cwd = "/repo",
        .when = 20,
        .session_id = "session-b",
    });
    try insertHistoryRecord(history_a.db, .{
        .cmd = "git status",
        .cwd = "/repo",
        .when = 30,
        .session_id = "session-a",
    });
    try insertHistoryRecord(history_a.db, .{
        .cmd = "git diff",
        .cwd = "/repo",
        .when = 40,
        .session_id = "session-b",
    });
    try insertHistoryRecord(history_a.db, .{
        .cmd = "echo a-other",
        .cwd = "/other",
        .when = 50,
        .session_id = "session-a",
    });

    var history_b = try History.init(std.testing.allocator);
    defer history_b.deinit();
    try history_b.load(std.testing.io, path);
    history_b.current_cwd = "/repo";
    history_b.session_id = "session-b";
    var history_service_b = InteractiveHistoryService.init(&history_b);

    const history_view_a: line_editor.HistoryView = .{
        .context = &history_service_a,
        .previous = previousHistoryEntry,
        .next = nextHistoryEntry,
    };
    var session_a = try line_editor.LineSession.initWithOptions(
        std.testing.allocator,
        .{ .bytes = "$ " },
        history_view_a,
    );
    defer session_a.deinit();
    // Session A loaded an empty database, so it sees only its own commands:
    // concurrent session B rows do not interleave, and cwd never filters.
    try session_a.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session_a, history_view_a);
    try std.testing.expectEqualStrings("echo a-other", session_a.editor.buffer.text());
    try session_a.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session_a, history_view_a);
    try std.testing.expectEqualStrings("git status", session_a.editor.buffer.text());
    try session_a.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session_a, history_view_a);
    try std.testing.expectEqualStrings("echo a-one", session_a.editor.buffer.text());
    try session_a.handleKey(.{ .key = .down });
    try applyLineHistoryRequest(&session_a, history_view_a);
    try std.testing.expectEqualStrings("git status", session_a.editor.buffer.text());
    try session_a.handleKey(.{ .key = .down });
    try applyLineHistoryRequest(&session_a, history_view_a);
    try std.testing.expectEqualStrings("echo a-other", session_a.editor.buffer.text());
    try session_a.handleKey(.{ .key = .down });
    try applyLineHistoryRequest(&session_a, history_view_a);
    try std.testing.expectEqualStrings("", session_a.editor.buffer.text());

    const history_view_b: line_editor.HistoryView = .{
        .context = &history_service_b,
        .previous = previousHistoryEntry,
        .next = nextHistoryEntry,
    };
    var session_b = try line_editor.LineSession.initWithOptions(
        std.testing.allocator,
        .{ .bytes = "$ " },
        history_view_b,
    );
    defer session_b.deinit();
    // Session B loaded after every insert, so its snapshot covers all rows:
    // navigation walks pure recency across sessions and directories.
    try session_b.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session_b, history_view_b);
    try std.testing.expectEqualStrings("echo a-other", session_b.editor.buffer.text());
    try session_b.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session_b, history_view_b);
    try std.testing.expectEqualStrings("git diff", session_b.editor.buffer.text());
    try session_b.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session_b, history_view_b);
    try std.testing.expectEqualStrings("git status", session_b.editor.buffer.text());
    try session_b.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session_b, history_view_b);
    try std.testing.expectEqualStrings("echo b-one", session_b.editor.buffer.text());
    try session_b.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session_b, history_view_b);
    try std.testing.expectEqualStrings("echo a-one", session_b.editor.buffer.text());
    try session_b.handleKey(.{ .key = .down });
    try applyLineHistoryRequest(&session_b, history_view_b);
    try std.testing.expectEqualStrings("echo b-one", session_b.editor.buffer.text());
}

test "line history reaches persisted history in new sessions" {
    const path = "rush-history-session-fallback-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var stored_history = try History.init(std.testing.allocator);
    defer stored_history.deinit();
    try stored_history.load(std.testing.io, path);
    try insertHistoryRecord(stored_history.db, .{
        .cmd = "echo older",
        .cwd = "/repo",
        .when = 10,
        .session_id = "old-session",
    });
    try insertHistoryRecord(stored_history.db, .{
        .cmd = "git status",
        .cwd = "/repo",
        .when = 20,
        .session_id = "old-session",
    });
    try insertHistoryRecord(stored_history.db, .{
        .cmd = "echo elsewhere",
        .cwd = "/other",
        .when = 30,
        .session_id = "old-session",
    });

    var new_history = try History.init(std.testing.allocator);
    defer new_history.deinit();
    try new_history.load(std.testing.io, path);
    new_history.current_cwd = "/repo";
    new_history.session_id = "new-session";
    var history_service = InteractiveHistoryService.init(&new_history);
    const history_view: line_editor.HistoryView = .{
        .context = &history_service,
        .previous = previousHistoryEntry,
        .next = nextHistoryEntry,
    };
    var session = try line_editor.LineSession.initWithOptions(
        std.testing.allocator,
        .{ .bytes = "$ " },
        history_view,
    );
    defer session.deinit();

    try session.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session, history_view);
    try std.testing.expectEqualStrings("echo elsewhere", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session, history_view);
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session, history_view);
    try std.testing.expectEqualStrings("echo older", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try applyLineHistoryRequest(&session, history_view);
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
}

test "history path follows XDG state home then HOME fallback" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("XDG_STATE_HOME", "/state");
    try env.put("HOME", "/home/me");
    const xdg_path = (try defaultPath(std.testing.allocator, &env)).?;
    defer std.testing.allocator.free(xdg_path);
    try std.testing.expectEqualStrings("/state/rush/history.sqlite", xdg_path);

    try env.put("XDG_STATE_HOME", "");
    const home_path = (try defaultPath(std.testing.allocator, &env)).?;
    defer std.testing.allocator.free(home_path);
    try std.testing.expectEqualStrings("/home/me/.local/state/rush/history.sqlite", home_path);
}
