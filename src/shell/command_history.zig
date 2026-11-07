//! Command-history callback interface used by the evaluator and builtins.
//!
//! Persistent SQLite storage lives in `src/history.zig`. This module only
//! defines the callback shape so the shell core does not analyze sqlite or
//! the interactive editor.

const std = @import("std");

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
/// owned result. Each uses the allocator passed to that callback. Times are
/// supplied by the shell from its Host: Unix seconds and durations in
/// milliseconds.
pub const CommandHistory = struct {
    context: *anyopaque,
    list: *const fn (*anyopaque, std.mem.Allocator) anyerror![]HistoryEntry,
    append: ?*const fn (*anyopaque, []const u8, ExitStatus, i64, i64) anyerror!void = null,
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
