//! Requests emitted by the deterministic editor session for shell/adapter services.

const std = @import("std");
const history = @import("history.zig");
const path = @import("path.zig");

pub const HistoryRequest = history.Request;
pub const HistoryResult = history.Result;

/// Owned request payload; ownership follows the containing `LineRequest`.
pub const ExternalEditorRequest = struct {
    text: []const u8,
    number: ?usize = null,

    pub fn deinit(self: ExternalEditorRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const Kind = enum {
    refresh_prompt,
    clear_screen,
    path_expansion,
    external_editor,
    vi_alias_lookup,
    history,
};

/// Request payloads are deeply owned and released by `deinit` unless moved.
pub const LineRequest = union(Kind) {
    refresh_prompt,
    clear_screen,
    path_expansion: path.Request,
    external_editor: ExternalEditorRequest,
    vi_alias_lookup: u21,
    history: HistoryRequest,

    pub fn deinit(self: LineRequest, allocator: std.mem.Allocator) void {
        switch (self) {
            .path_expansion => |request| request.deinit(allocator),
            .external_editor => |request| request.deinit(allocator),
            .history => |request| request.deinit(allocator),
            .refresh_prompt,
            .clear_screen,
            .vi_alias_lookup,
            => {},
        }
    }
};

/// Owns at most one request of each kind.
pub const Outbox = struct {
    items: [@typeInfo(Kind).@"enum".field_names.len]LineRequest = undefined,
    len: usize = 0,

    pub fn deinit(self: *Outbox, allocator: std.mem.Allocator) void {
        for (self.items[0..self.len]) |request| request.deinit(allocator);
        self.* = undefined;
    }

    /// Takes ownership of `request`, replacing and freeing the same kind.
    pub fn put(self: *Outbox, allocator: std.mem.Allocator, request: LineRequest) void {
        const kind = std.meta.activeTag(request);
        for (self.items[0..self.len]) |*existing| {
            if (std.meta.activeTag(existing.*) != kind) continue;
            existing.deinit(allocator);
            existing.* = request;
            return;
        }
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = request;
        self.len += 1;
    }

    /// Removes a request and transfers its payload ownership to the caller.
    pub fn take(self: *Outbox, kind: Kind) ?LineRequest {
        for (self.items[0..self.len], 0..) |request, index| {
            if (std.meta.activeTag(request) != kind) continue;
            const found = request;
            self.removeAt(index);
            return found;
        }
        return null;
    }

    /// Removes and deeply frees a request of `kind`, if present.
    pub fn clear(self: *Outbox, allocator: std.mem.Allocator, kind: Kind) void {
        const request = self.take(kind) orelse return;
        request.deinit(allocator);
    }

    pub fn contains(self: Outbox, kind: Kind) bool {
        for (self.items[0..self.len]) |request| {
            if (std.meta.activeTag(request) == kind) return true;
        }
        return false;
    }

    fn removeAt(self: *Outbox, index: usize) void {
        std.debug.assert(index < self.len);
        var cursor = index;
        while (cursor + 1 < self.len) : (cursor += 1) {
            self.items[cursor] = self.items[cursor + 1];
        }
        self.len -= 1;
    }
};
