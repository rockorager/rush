//! Rush-specific shell extensions.

const std = @import("std");

const completion_path = @import("../completion_path.zig");
const completion = @import("../editor/completion.zig");
const editor_render = @import("../editor/render.zig");
const host = @import("../host.zig");
const shell = @import("../shell.zig");

const builtin = shell.builtin;
const result = shell.result;
const real_host: host.RealHost = .{};

pub const definitions = [_]builtin.Definition{
    builtin.extensionDefinition("abbr", .abbr),
    builtin.extensionDefinition("color", .color),
    builtin.extensionDefinition("event", .event),
    builtin.extensionDefinition("prompt", .prompt),
    builtin.extensionDefinition("prompt_duration", .prompt_duration),
    builtin.extensionDefinition("prompt_pwd", .prompt_pwd),
    builtin.extensionDefinition("rush_complete", .rush_complete),
    builtin.extensionDefinition("rush_env", .rush_env),
};

pub const registry: builtin.Registry = .{
    .extensions = &definitions,
    .ExtensionState = State,
};

pub const EventHandler = struct {
    event: []const u8,
    name: []const u8,
    action: []const u8,
    priority: i32 = 0,
    every_ms: ?u64 = null,
    next_tick_ms: ?u64 = null,
};

pub const CompletionParsedOption = struct {
    spelling: []const u8,
    name: []const u8,
    key: []const u8,
    value: ?[]const u8 = null,
};

pub const CompletionParsedOperand = struct {
    value: []const u8,
    index: usize,
};

pub const CompletionContext = struct {
    allocator: std.mem.Allocator,
    prefix: []const u8,
    replace_start: usize,
    replace_end: usize,
    argument_index: usize,
    options_terminated: bool,
    value_position: []const u8,
    parsed_options: []const CompletionParsedOption,
    operands: []const CompletionParsedOperand,
    candidates: std.ArrayList(completion.Candidate) = .empty,
    next_source_order: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        prefix: []const u8,
        replace_start: usize,
        replace_end: usize,
        argument_index: usize,
        options_terminated: bool,
        value_position: []const u8,
        parsed_options: []const CompletionParsedOption,
        operands: []const CompletionParsedOperand,
    ) CompletionContext {
        return .{
            .allocator = allocator,
            .prefix = prefix,
            .replace_start = replace_start,
            .replace_end = replace_end,
            .argument_index = argument_index,
            .options_terminated = options_terminated,
            .value_position = value_position,
            .parsed_options = parsed_options,
            .operands = operands,
        };
    }

    pub fn deinit(self: *CompletionContext) void {
        if (self.candidates.items.len != 0) {
            const candidates = self.candidates.toOwnedSlice(self.allocator) catch unreachable;
            completion.freeCandidates(self.allocator, candidates);
        } else self.candidates.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn takeCandidates(self: *CompletionContext) ![]completion.Candidate {
        const candidates = try self.candidates.toOwnedSlice(self.allocator);
        self.candidates = .empty;
        return candidates;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    abbreviations: std.StringHashMapUnmanaged([]const u8) = .empty,
    event_handlers: std.StringHashMapUnmanaged(EventHandler) = .empty,
    prompt_async_entries: std.ArrayListUnmanaged(*PromptAsyncEntry) = .empty,
    prompt_async_io: ?std.Io = null,
    prompt_async_redraw_fd: ?host.Fd = null,
    prompt_async_registry: ?PromptAsyncFdRegistry = null,
    prompt_async_active_count: usize = 0,
    prompt_async_pending_start_events: usize = 0,
    prompt_async_pending_end_events: usize = 0,
    prompt_async_render_started: bool = false,
    prompt_buffer: std.ArrayListUnmanaged(u8) = .empty,
    building_prompt: bool = false,
    // Set when a terminal color/scheme report changes a rush_color_* value;
    // the DA1 batch terminator reruns rush_style only while this is set.
    style_dirty: bool = true,
    previous_duration_ms: ?i64 = null,
    completion_context: ?*CompletionContext = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        var abbreviation_iterator = self.abbreviations.iterator();
        while (abbreviation_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.abbreviations.deinit(self.allocator);
        var event_iterator = self.event_handlers.iterator();
        while (event_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.event);
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.action);
        }
        self.event_handlers.deinit(self.allocator);
        for (self.prompt_async_entries.items) |entry| entry.deinit(self.allocator);
        self.prompt_async_entries.deinit(self.allocator);
        self.prompt_buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn eval(
        self: *State,
        sh: anytype,
        definition: builtin.Definition,
        args: []const []const u8,
    ) !result.EvalResult {
        return switch (definition.id) {
            .abbr => evalAbbr(self, sh, args),
            .color => evalColor(sh, args),
            .event => evalEvent(self, sh, args),
            .prompt => evalPrompt(self, sh, args),
            .prompt_duration => evalPromptDuration(self, sh, args),
            .prompt_pwd => evalPromptPwd(sh, args),
            .rush_complete => evalRushComplete(self, sh, args),
            .rush_env => evalRushEnv(sh, args),
            else => .{ .status = 127 },
        };
    }

    pub fn putAbbreviation(self: *State, name: []const u8, replacement: []const u8) !void {
        std.debug.assert(name.len != 0);
        const owned_replacement = try self.allocator.dupe(u8, replacement);
        errdefer self.allocator.free(owned_replacement);

        if (self.abbreviations.getPtr(name)) |existing| {
            self.allocator.free(existing.*);
            existing.* = owned_replacement;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.abbreviations.put(self.allocator, owned_name, owned_replacement);
    }

    pub fn getAbbreviation(self: State, name: []const u8) ?[]const u8 {
        if (name.len == 0) return null;
        return self.abbreviations.get(name);
    }

    pub fn removeAbbreviation(self: *State, name: []const u8) bool {
        if (name.len == 0) return false;
        if (self.abbreviations.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
            return true;
        }
        return false;
    }

    pub fn putEventHandler(
        self: *State,
        event: []const u8,
        name: []const u8,
        action: []const u8,
        priority: i32,
        every_ms: ?u64,
    ) !void {
        std.debug.assert(event.len != 0);
        std.debug.assert(name.len != 0);
        std.debug.assert(action.len != 0);

        const key = try eventKey(self.allocator, event, name);
        errdefer self.allocator.free(key);
        const owned_event = try self.allocator.dupe(u8, event);
        errdefer self.allocator.free(owned_event);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_action = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(owned_action);

        if (self.event_handlers.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.event);
            self.allocator.free(entry.value.name);
            self.allocator.free(entry.value.action);
        }
        try self.event_handlers.put(self.allocator, key, .{
            .event = owned_event,
            .name = owned_name,
            .action = owned_action,
            .priority = priority,
            .every_ms = every_ms,
        });
    }

    fn removeEventHandler(self: *State, event: []const u8, name: []const u8) !bool {
        if (event.len == 0 or name.len == 0) return false;
        const key = try eventKey(self.allocator, event, name);
        defer self.allocator.free(key);
        if (self.event_handlers.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.event);
            self.allocator.free(entry.value.name);
            self.allocator.free(entry.value.action);
            return true;
        }
        return false;
    }

    pub fn clearPrompt(self: *State) void {
        self.prompt_buffer.clearRetainingCapacity();
        self.prompt_async_render_started = false;
    }

    fn appendPrompt(self: *State, bytes: []const u8) !void {
        try self.prompt_buffer.appendSlice(self.allocator, bytes);
    }

    pub fn configurePromptAsync(
        self: *State,
        io: std.Io,
        redraw_fd: std.posix.fd_t,
        fd_registry: PromptAsyncFdRegistry,
    ) void {
        self.prompt_async_io = io;
        self.prompt_async_redraw_fd = @enumFromInt(redraw_fd);
        self.prompt_async_registry = fd_registry;
    }

    pub fn promptAsyncPending(self: *State) bool {
        return self.prompt_async_render_started or self.prompt_async_active_count != 0;
    }

    pub fn takePromptAsyncLifecycleEvents(self: *State) PromptAsyncLifecycleEvents {
        const events: PromptAsyncLifecycleEvents = .{
            .start_count = self.prompt_async_pending_start_events,
            .end_count = self.prompt_async_pending_end_events,
        };
        self.prompt_async_pending_start_events = 0;
        self.prompt_async_pending_end_events = 0;
        return events;
    }

    /// Drains prompt async command pipes on the main thread.
    ///
    /// Called from the editor event loop when a pipe becomes readable and
    /// before each prompt render. Runs entirely on the main thread so no
    /// reader thread can hold allocator or extension locks while the shell
    /// forks children that keep running the evaluator.
    pub fn pumpPromptAsync(self: *State) void {
        for (self.prompt_async_entries.items) |entry| self.pumpPromptAsyncEntry(entry);
    }

    fn pumpPromptAsyncEntry(self: *State, entry: *PromptAsyncEntry) void {
        if (entry.read_fd) |read_fd| {
            var buffer: [4096]u8 = undefined;
            while (true) {
                const read_len = real_host.read(read_fd, &buffer) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => break,
                };
                if (read_len == 0) break;
                entry.output.appendSlice(self.allocator, buffer[0..read_len]) catch break;
            }
            self.finishPromptAsyncEntry(entry);
        }
        reapPromptAsyncChild(entry);
    }

    fn finishPromptAsyncEntry(self: *State, entry: *PromptAsyncEntry) void {
        std.debug.assert(entry.refreshing);
        const read_fd = entry.read_fd.?;
        if (self.prompt_async_registry) |fd_registry| fd_registry.unregister(fd_registry.context, read_fd.raw());
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        real_host.close(read_fd) catch {};
        entry.read_fd = null;

        if (entry.output.toOwnedSlice(self.allocator) catch null) |stdout| {
            self.allocator.free(entry.stdout);
            entry.stdout = stdout;
            entry.updated_ms = if (self.prompt_async_io) |io| monotonicMillis(io) else 0;
        } else entry.output.clearAndFree(self.allocator);
        entry.refreshing = false;
        std.debug.assert(self.prompt_async_active_count != 0);
        self.prompt_async_active_count -= 1;
        if (self.prompt_async_active_count == 0) self.prompt_async_pending_end_events += 1;

        // ziglint-ignore: Z026 best-effort wakeup; the next input event can redraw
        if (self.prompt_async_redraw_fd) |fd| real_host.writeAll(fd, "p") catch {};
    }
};

/// Event-loop fd registration callbacks supplied by the interactive session.
///
/// Keeps the shell extension decoupled from the editor driver while letting
/// prompt async pipes wake the main-thread event loop.
pub const PromptAsyncFdRegistry = struct {
    context: *anyopaque,
    register: *const fn (*anyopaque, std.posix.fd_t) anyerror!void,
    unregister: *const fn (*anyopaque, std.posix.fd_t) void,
};

fn reapPromptAsyncChild(entry: *PromptAsyncEntry) void {
    std.debug.assert(entry.read_fd == null or entry.pid != null);
    const pid = entry.pid orelse return;
    if (entry.read_fd != null) return;
    const status = real_host.waitNonBlocking(pid) catch {
        entry.pid = null;
        return;
    };
    if (status != null) entry.pid = null;
}

pub const PromptAsyncLifecycleEvents = struct {
    start_count: usize = 0,
    end_count: usize = 0,
};

const PromptAsyncEntry = struct {
    state: *State,
    key: []const u8,
    cwd: []const u8,
    stdout: []const u8,
    output: std.ArrayListUnmanaged(u8) = .empty,
    updated_ms: u64 = 0,
    refreshing: bool = false,
    pid: ?host.Pid = null,
    read_fd: ?host.Fd = null,

    // ziglint-ignore: Z030 deinit intentionally leaves reusable/test-local state shape
    fn deinit(self: *PromptAsyncEntry, allocator: std.mem.Allocator) void {
        if (self.read_fd) |read_fd| {
            // The event loop is already gone by the time extension state
            // deinitializes; closing the pipe is enough. The child is
            // reparented and reaped by init after the shell exits.
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            real_host.close(read_fd) catch {};
        }
        if (self.pid) |pid| {
            // ziglint-ignore: Z026 best-effort reap; init adopts still-running children
            _ = real_host.waitNonBlocking(pid) catch {};
        }
        self.output.deinit(allocator);
        allocator.free(self.key);
        allocator.free(self.cwd);
        allocator.free(self.stdout);
        allocator.destroy(self);
    }
};

fn evalAbbr(state: *State, sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len == 1) return listAbbreviations(state, sh);
    if (std.mem.eql(u8, args[1], "--list")) {
        if (args.len != 2) return .{ .status = 2 };
        return listAbbreviations(state, sh);
    }
    if (std.mem.eql(u8, args[1], "--erase") or
        std.mem.eql(u8, args[1], "erase") or
        std.mem.eql(u8, args[1], "remove"))
    {
        if (args.len < 3) return .{ .status = 2 };
        var status: result.ExitStatus = 0;
        for (args[2..]) |name| {
            if (!state.removeAbbreviation(name)) status = 1;
        }
        return .{ .status = status };
    }
    if (args.len != 3 or !isAbbreviationName(args[1])) return .{ .status = 2 };
    try state.putAbbreviation(args[1], args[2]);
    return .{};
}

fn listAbbreviations(state: *State, sh: anytype) !result.EvalResult {
    var iterator = state.abbreviations.iterator();
    while (iterator.next()) |entry| {
        try sh.host.writeAll(.stdout, "abbr ");
        try sh.host.writeAll(.stdout, entry.key_ptr.*);
        try sh.host.writeAll(.stdout, " ");
        try writeShellSingleQuoted(sh, entry.value_ptr.*);
        try sh.host.writeAll(.stdout, "\n");
    }
    return .{};
}

fn isAbbreviationName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn writeShellSingleQuoted(sh: anytype, value: []const u8) !void {
    try sh.host.writeAll(.stdout, "'");
    for (value, 0..) |byte, index| {
        if (byte == '\'') {
            try sh.host.writeAll(.stdout, "'\\''");
        } else {
            try sh.host.writeAll(.stdout, value[index..][0..1]);
        }
    }
    try sh.host.writeAll(.stdout, "'");
}

fn evalEvent(state: *State, sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len == 1) return listEvents(state, sh, &.{});
    if (std.mem.eql(u8, args[1], "list")) return listEvents(state, sh, args[2..]);
    if (std.mem.eql(u8, args[1], "add")) return eventAdd(state, args[2..]);
    if (std.mem.eql(u8, args[1], "remove")) return eventRemove(state, args[2..]);
    return .{ .status = 2 };
}

fn eventAdd(state: *State, args: []const []const u8) !result.EvalResult {
    if (args.len < 3) return .{ .status = 2 };
    if (!isEventName(args[0]) or !isRegistrationName(args[1]) or !isFunctionName(args[2])) return .{ .status = 2 };

    var priority: i32 = 0;
    var every_ms: ?u64 = null;
    var index: usize = 3;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--every")) {
            index += 1;
            if (index >= args.len) return .{ .status = 2 };
            every_ms = std.fmt.parseInt(u64, args[index], 10) catch return .{ .status = 2 };
            if (every_ms.? == 0) return .{ .status = 2 };
        } else if (std.mem.eql(u8, args[index], "--priority")) {
            index += 1;
            if (index >= args.len) return .{ .status = 2 };
            priority = std.fmt.parseInt(i32, args[index], 10) catch return .{ .status = 2 };
        } else return .{ .status = 2 };
        index += 1;
    }
    if (std.mem.eql(u8, args[0], "timer.tick")) {
        if (every_ms == null) return .{ .status = 2 };
    } else if (every_ms != null) return .{ .status = 2 };
    try state.putEventHandler(args[0], args[1], args[2], priority, every_ms);
    return .{};
}

fn eventRemove(state: *State, args: []const []const u8) !result.EvalResult {
    if (args.len != 2) return .{ .status = 2 };
    if (!isEventName(args[0]) or !isRegistrationName(args[1])) return .{ .status = 2 };
    _ = try state.removeEventHandler(args[0], args[1]);
    return .{};
}

fn listEvents(state: *State, sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len > 2) return .{ .status = 2 };
    var json = false;
    var filter: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (json) return .{ .status = 2 };
            json = true;
            continue;
        }
        if (filter != null or !isEventName(arg)) return .{ .status = 2 };
        filter = arg;
    }

    var handlers: std.ArrayList(EventHandler) = .empty;
    defer handlers.deinit(sh.scratchAllocator());
    var iterator = state.event_handlers.iterator();
    while (iterator.next()) |entry| {
        const handler = entry.value_ptr.*;
        if (filter) |event_name| if (!std.mem.eql(u8, handler.event, event_name)) continue;
        try handlers.append(sh.scratchAllocator(), handler);
    }
    std.mem.sort(EventHandler, handlers.items, {}, lessThanEventHandler);
    if (json) return listEventsJson(sh, handlers.items);
    try listEventsText(sh, handlers.items);
    return .{};
}

fn lessThanEventHandler(_: void, left: EventHandler, right: EventHandler) bool {
    const event_order = std.mem.order(u8, left.event, right.event);
    if (event_order != .eq) return event_order == .lt;
    if (left.priority != right.priority) return left.priority < right.priority;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn listEventsText(sh: anytype, handlers: []const EventHandler) !void {
    var current_event: ?[]const u8 = null;
    for (handlers) |handler| {
        if (current_event == null or !std.mem.eql(u8, current_event.?, handler.event)) {
            current_event = handler.event;
            try sh.host.writeAll(.stdout, handler.event);
            try sh.host.writeAll(.stdout, "\n");
        }
        try sh.host.writeAll(.stdout, "  ");
        try sh.host.writeAll(.stdout, handler.name);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try sh.host.writeAll(.stdout, try std.fmt.allocPrint(sh.scratchAllocator(), " priority={d}", .{handler.priority}));
        if (handler.every_ms) |every_ms| {
            try sh.host.writeAll(.stdout, try std.fmt.allocPrint(sh.scratchAllocator(), " every={d}ms", .{every_ms}));
        }
        try sh.host.writeAll(.stdout, " ");
        try sh.host.writeAll(.stdout, handler.action);
        try sh.host.writeAll(.stdout, "\n");
    }
}

fn listEventsJson(sh: anytype, handlers: []const EventHandler) !result.EvalResult {
    try sh.host.writeAll(.stdout, "[\n");
    for (handlers, 0..) |handler, index| {
        if (index != 0) try sh.host.writeAll(.stdout, ",\n");
        try sh.host.writeAll(.stdout, "{\"event\":");
        try writeJsonString(sh, handler.event);
        try sh.host.writeAll(.stdout, ",\"name\":");
        try writeJsonString(sh, handler.name);
        try sh.host.writeAll(.stdout, ",\"function\":");
        try writeJsonString(sh, handler.action);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try sh.host.writeAll(.stdout, try std.fmt.allocPrint(sh.scratchAllocator(), ",\"priority\":{d}", .{handler.priority}));
        if (handler.every_ms) |every_ms| {
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            try sh.host.writeAll(.stdout, try std.fmt.allocPrint(sh.scratchAllocator(), ",\"every_ms\":{d}", .{every_ms}));
        }
        try sh.host.writeAll(.stdout, "}");
    }
    try sh.host.writeAll(.stdout, "\n]\n");
    return .{};
}

fn writeJsonString(sh: anytype, value: []const u8) !void {
    try sh.host.writeAll(.stdout, "\"");
    for (value) |byte| switch (byte) {
        '"' => try sh.host.writeAll(.stdout, "\\\""),
        '\\' => try sh.host.writeAll(.stdout, "\\\\"),
        '\n' => try sh.host.writeAll(.stdout, "\\n"),
        '\r' => try sh.host.writeAll(.stdout, "\\r"),
        '\t' => try sh.host.writeAll(.stdout, "\\t"),
        else => if (byte < 0x20)
            try sh.host.writeAll(
                .stdout,
                try std.fmt.allocPrint(sh.scratchAllocator(), "\\u{x:0>4}", .{byte}),
            )
        else
            try sh.host.writeAll(.stdout, try std.fmt.allocPrint(sh.scratchAllocator(), "{c}", .{byte})),
    };
    try sh.host.writeAll(.stdout, "\"");
}

fn isEventName(name: []const u8) bool {
    return std.mem.eql(u8, name, "directory.change") or
        std.mem.eql(u8, name, "prompt.prepare") or
        std.mem.eql(u8, name, "prompt.async.start") or
        std.mem.eql(u8, name, "prompt.async.end") or
        std.mem.eql(u8, name, "job.start") or
        std.mem.eql(u8, name, "job.end") or
        std.mem.eql(u8, name, "timer.tick");
}

fn isRegistrationName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.') continue;
        return false;
    }
    return true;
}

fn isFunctionName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

fn evalPrompt(state: *State, sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len < 2) return .{ .status = 2 };
    if (std.mem.eql(u8, args[1], "async-pending")) return .{ .status = if (state.promptAsyncPending()) 0 else 1 };
    if (!state.building_prompt) return .{};
    if (std.mem.eql(u8, args[1], "text")) {
        if (args.len < 3) return .{ .status = 2 };
        try appendPromptText(state, args[2..]);
        return .{};
    }
    if (std.mem.eql(u8, args[1], "newline")) {
        if (args.len != 2) return .{ .status = 2 };
        try state.appendPrompt("\n");
        return .{};
    }
    if (std.mem.eql(u8, args[1], "segment")) {
        var style: editor_render.UiStyle = .{};
        var index: usize = 2;
        while (index < args.len) {
            if (!(parsePromptStyleOption(args, &index, &style) catch return .{ .status = 2 })) break;
        }
        if (index >= args.len) return .{ .status = 2 };
        try appendStyledPromptText(state, style, args[index..]);
        return .{};
    }
    if (std.mem.eql(u8, args[1], "async")) {
        const parsed = (try parsePromptAsyncSegment(args)) orelse return .{ .status = 2 };
        const cached_stdout = try promptAsyncCachedOutput(state, parsed.async, sh);
        const display_stdout = std.mem.trimEnd(u8, cached_stdout, "\n");
        if (display_stdout.len != 0) {
            if (parsed.prefix) |prefix| try state.appendPrompt(prefix);
            try appendStyledPromptText(state, parsed.style, &.{display_stdout});
        }
        return .{};
    }
    return .{ .status = 2 };
}

fn parsePromptStyleOption(args: []const []const u8, index: *usize, style: *editor_render.UiStyle) !bool {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--fg")) {
        index.* += 1;
        if (index.* >= args.len) return error.InvalidPromptStyle;
        style.fg = editor_render.parseUiColor(args[index.*]) orelse return error.InvalidPromptStyle;
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--bg")) {
        index.* += 1;
        if (index.* >= args.len) return error.InvalidPromptStyle;
        style.bg = editor_render.parseUiColor(args[index.*]) orelse return error.InvalidPromptStyle;
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--bold")) {
        style.bold = true;
    } else if (std.mem.eql(u8, arg, "--dim")) {
        style.dim = true;
    } else if (std.mem.eql(u8, arg, "--italic")) {
        style.italic = true;
    } else if (std.mem.eql(u8, arg, "--underline")) {
        style.ul = .single;
    } else if (std.mem.eql(u8, arg, "--reverse")) {
        style.reverse = true;
    } else if (std.mem.eql(u8, arg, "--strikethrough")) {
        style.strike = true;
    } else return false;
    index.* += 1;
    return true;
}

fn appendPromptText(state: *State, args: []const []const u8) !void {
    for (args, 0..) |arg, index| {
        if (index != 0) try state.appendPrompt(" ");
        try state.appendPrompt(arg);
    }
}

fn appendStyledPromptText(state: *State, style: editor_render.UiStyle, args: []const []const u8) !void {
    var styled: std.ArrayList(u8) = .empty;
    defer styled.deinit(state.allocator);
    try editor_render.appendUiStyleStart(state.allocator, &styled, style);
    for (args, 0..) |arg, index| {
        if (index != 0) try styled.append(state.allocator, ' ');
        try styled.appendSlice(state.allocator, arg);
    }
    try editor_render.appendUiStyleEnd(state.allocator, &styled, style);
    try state.appendPrompt(styled.items);
}

fn promptAsyncCachedOutput(state: *State, parsed: PromptAsyncOptions, sh: anytype) ![]const u8 {
    const io = state.prompt_async_io orelse return "";
    const entry = try promptAsyncEntry(state, sh, parsed.key);

    const cached_stdout = try sh.scratchAllocator().dupe(u8, entry.stdout);
    const should_refresh = !entry.refreshing and
        (entry.updated_ms == 0 or monotonicMillis(io) >= entry.updated_ms +| parsed.ttl_ms);
    if (should_refresh) {
        entry.refreshing = true;
        if (state.prompt_async_active_count == 0) state.prompt_async_pending_start_events += 1;
        state.prompt_async_active_count += 1;
        state.prompt_async_render_started = true;
    }

    if (should_refresh) {
        const HostType = switch (@typeInfo(@TypeOf(sh.host))) {
            .pointer => |pointer| pointer.child,
            else => @TypeOf(sh.host),
        };
        if (@hasDecl(HostType, "forkProcess")) {
            startPromptAsyncRefresh(sh, entry, parsed.command) catch |err| {
                promptAsyncRefreshFailed(&sh.extensions, entry);
                if (err == error.OutOfMemory) return error.OutOfMemory;
            };
        } else promptAsyncRefreshFailed(&sh.extensions, entry);
    }
    return cached_stdout;
}

const PromptAsyncOptions = struct {
    key: []const u8,
    ttl_ms: u64,
    command: []const []const u8,
};

const PromptAsyncSegmentOptions = struct {
    async: PromptAsyncOptions,
    style: editor_render.UiStyle = .{},
    prefix: ?[]const u8 = null,
};

fn parsePromptAsyncSegment(args: []const []const u8) !?PromptAsyncSegmentOptions {
    if (args.len < 7) return null;
    var parsed: PromptAsyncSegmentOptions = .{
        .async = .{ .key = args[2], .ttl_ms = 0, .command = &.{} },
    };
    var index: usize = 3;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--")) {
            index += 1;
            if (index >= args.len) return null;
            parsed.async.command = args[index..];
            return parsed;
        }
        if (std.mem.eql(u8, args[index], "--ttl")) {
            index += 1;
            if (index >= args.len) return null;
            parsed.async.ttl_ms = std.fmt.parseInt(u64, args[index], 10) catch return null;
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, args[index], "--prefix")) {
            index += 1;
            if (index >= args.len) return null;
            parsed.prefix = args[index];
            index += 1;
            continue;
        }
        if ((parsePromptStyleOption(args, &index, &parsed.style) catch return null)) continue;
        return null;
    }
    return null;
}

test "prompt async segment parser accepts style and prefix" {
    const parsed = (try parsePromptAsyncSegment(&.{
        "prompt",
        "async",
        "git",
        "--ttl",
        "2000",
        "--prefix",
        " ",
        "--fg",
        "yellow",
        "--",
        "rush_prompt_git",
    })).?;
    try std.testing.expectEqualStrings("git", parsed.async.key);
    try std.testing.expectEqual(@as(u64, 2000), parsed.async.ttl_ms);
    try std.testing.expectEqualStrings(" ", parsed.prefix.?);
    try std.testing.expectEqual(editor_render.parseUiColor("yellow").?, parsed.style.fg.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.async.command.len);
    try std.testing.expectEqualStrings("rush_prompt_git", parsed.async.command[0]);
}

test "prompt async lifecycle events are drained once" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    state.prompt_async_active_count = 1;
    state.prompt_async_pending_start_events = 1;
    state.prompt_async_pending_end_events = 2;

    try std.testing.expect(state.promptAsyncPending());
    try std.testing.expectEqual(
        // ziglint-ignore: Z010 explicit type retained for readability/type inference
        PromptAsyncLifecycleEvents{ .start_count = 1, .end_count = 2 },
        state.takePromptAsyncLifecycleEvents(),
    );
    // ziglint-ignore: Z010 explicit type retained for readability/type inference
    try std.testing.expectEqual(PromptAsyncLifecycleEvents{}, state.takePromptAsyncLifecycleEvents());
}

test "prompt async pump collects pipe output and completes the entry" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();

    const entry = try std.testing.allocator.create(PromptAsyncEntry);
    entry.* = .{
        .state = &state,
        .key = try std.testing.allocator.dupe(u8, "git"),
        .cwd = try std.testing.allocator.dupe(u8, "/"),
        .stdout = try std.testing.allocator.dupe(u8, "stale"),
        .refreshing = true,
    };
    try state.prompt_async_entries.append(std.testing.allocator, entry);
    state.prompt_async_active_count = 1;

    const pipe_desc = try real_host.pipe();
    entry.read_fd = pipe_desc.read;
    try real_host.writeAll(pipe_desc.write, "main\n");
    try real_host.close(pipe_desc.write);

    state.pumpPromptAsync();

    try std.testing.expectEqualStrings("main\n", entry.stdout);
    try std.testing.expect(!entry.refreshing);
    try std.testing.expectEqual(@as(?host.Fd, null), entry.read_fd);
    try std.testing.expectEqual(@as(usize, 0), state.prompt_async_active_count);
    try std.testing.expectEqual(@as(usize, 1), state.takePromptAsyncLifecycleEvents().end_count);
}

fn promptAsyncEntry(state: *State, sh: anytype, key: []const u8) !*PromptAsyncEntry {
    const cwd = try promptDirectory(sh);
    for (state.prompt_async_entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, key) and std.mem.eql(u8, entry.cwd, cwd)) return entry;
    }
    const entry = try state.allocator.create(PromptAsyncEntry);
    errdefer state.allocator.destroy(entry);
    entry.* = .{
        .state = state,
        .key = try state.allocator.dupe(u8, key),
        .cwd = try state.allocator.dupe(u8, cwd),
        .stdout = try state.allocator.dupe(u8, ""),
    };
    errdefer state.allocator.free(entry.key);
    errdefer state.allocator.free(entry.cwd);
    errdefer state.allocator.free(entry.stdout);
    try state.prompt_async_entries.append(state.allocator, entry);
    return entry;
}

fn startPromptAsyncRefresh(sh: anytype, entry: *PromptAsyncEntry, command_args: []const []const u8) !void {
    std.debug.assert(entry.read_fd == null);
    const state = entry.state;
    const fd_registry = state.prompt_async_registry orelse return error.PromptAsyncUnavailable;
    // Best-effort reap of a previous child that outlived its pipe; a
    // still-running one is abandoned to init rather than blocking the prompt.
    reapPromptAsyncChild(entry);
    entry.pid = null;
    const command = try shellCommand(sh.scratchAllocator(), command_args);
    const pipe_desc = try sh.host.pipe();
    var read_open = true;
    var write_open = true;
    errdefer {
        if (read_open) sh.host.close(pipe_desc.read) catch {};
        if (write_open) sh.host.close(pipe_desc.write) catch {};
    }
    switch (try sh.host.forkProcess()) {
        .child => {
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            sh.host.close(pipe_desc.read) catch {};
            read_open = false;
            sh.host.duplicateTo(pipe_desc.write, .stdout) catch sh.host.exit(127);
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            sh.host.close(pipe_desc.write) catch {};
            write_open = false;
            sh.state.options.monitor = false;
            sh.state.shell_pid = null;
            // The child must never start nested refreshes: its inherited
            // registry would mutate the parent's event loop (the epoll/kqueue
            // fd is shared across fork).
            sh.extensions.prompt_async_io = null;
            sh.extensions.prompt_async_redraw_fd = null;
            sh.extensions.prompt_async_registry = null;
            if (sh.host.openZ("/dev/null", .{ .access = .write_only })) |null_fd| {
                // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
                sh.host.duplicateTo(null_fd, .stderr) catch {};
                // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
                sh.host.close(null_fd) catch {};
            } else |_| {}
            const src: shell.source.Source = .{
                .id = 0,
                .kind = .command_string,
                .name = "prompt async",
                .text = command,
            };
            const evaluated = sh.evalSourceNested(src) catch sh.host.exit(2);
            sh.host.exit(evaluated.status);
        },
        .parent => |pid| {
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            sh.host.close(pipe_desc.write) catch {};
            write_open = false;
            fd_registry.register(fd_registry.context, pipe_desc.read.raw()) catch |err| {
                // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
                sh.host.close(pipe_desc.read) catch {};
                read_open = false;
                // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
                _ = sh.host.wait(pid) catch {};
                return err;
            };
            entry.pid = pid;
            entry.read_fd = pipe_desc.read;
            read_open = false;
        },
    }
}

fn promptAsyncRefreshFailed(state: *State, entry: *PromptAsyncEntry) void {
    entry.refreshing = false;
    std.debug.assert(state.prompt_async_active_count != 0);
    state.prompt_async_active_count -= 1;
    if (state.prompt_async_active_count == 0) state.prompt_async_pending_end_events += 1;
}

fn monotonicMillis(io: std.Io) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds());
}

fn evalPromptPwd(sh: anytype, args: []const []const u8) !result.EvalResult {
    const options = parsePromptPwdOptions(args) orelse return .{ .status = 2 };
    const HostType = switch (@typeInfo(@TypeOf(sh.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(sh.host),
    };
    if (!@hasDecl(HostType, "currentDir")) return .{ .status = 1 };
    const cwd = try promptDirectory(sh);
    const display = try formatPromptPwdForShell(sh.scratchAllocator(), sh, cwd, options);
    try sh.host.writeAll(.stdout, display);
    try sh.host.writeAll(.stdout, "\n");
    return .{};
}

pub fn formatPromptPwdForShell(
    allocator: std.mem.Allocator,
    sh: anytype,
    cwd: []const u8,
    options: PromptPwdOptions,
) ![]const u8 {
    return formatPromptPwd(allocator, cwd, shellValue(sh, "HOME"), options);
}

fn promptDirectory(sh: anytype) ![]const u8 {
    if (sh.state.getVariable("PWD")) |variable| return variable.value;
    return sh.host.currentDir(sh.scratchAllocator()) catch |err| {
        return shellEnvValue(sh, "PWD") orelse return err;
    };
}

pub const PromptPwdOptions = struct {
    dir_length: ?usize = null,
    full_length_dirs: usize = 1,
};

fn parsePromptPwdOptions(args: []const []const u8) ?PromptPwdOptions {
    var options: PromptPwdOptions = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--dir-length")) {
            index += 1;
            if (index >= args.len) return null;
            options.dir_length = std.fmt.parseInt(usize, args[index], 10) catch return null;
            continue;
        }
        if (std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--full-length-dirs")) {
            index += 1;
            if (index >= args.len) return null;
            options.full_length_dirs = std.fmt.parseInt(usize, args[index], 10) catch return null;
            continue;
        }
        return null;
    }
    return options;
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn formatPromptPwd(allocator: std.mem.Allocator, cwd: []const u8, maybe_home: ?[]const u8, options: PromptPwdOptions) ![]const u8 {
    const display = try abbreviateHomePath(allocator, cwd, maybe_home);
    const dir_length = options.dir_length orelse return display;
    if (dir_length == 0) return display;
    defer allocator.free(display);
    return abbreviatePromptPath(allocator, display, dir_length, options.full_length_dirs);
}

fn abbreviateHomePath(
    allocator: std.mem.Allocator,
    path: []const u8,
    maybe_home: ?[]const u8,
) ![]const u8 {
    if (maybe_home) |home| {
        var normalized_home = home;
        while (normalized_home.len > 1 and normalized_home[normalized_home.len - 1] == '/') {
            normalized_home = normalized_home[0 .. normalized_home.len - 1];
        }
        if (normalized_home.len != 0 and std.mem.eql(u8, path, normalized_home)) {
            return allocator.dupe(u8, "~");
        }
        if (normalized_home.len != 0 and std.mem.startsWith(u8, path, normalized_home) and
            (normalized_home.len == 1 or
                (path.len > normalized_home.len and path[normalized_home.len] == '/')))
        {
            const suffix = if (normalized_home.len == 1) path else path[normalized_home.len..];
            return std.mem.concat(allocator, u8, &.{ "~", suffix });
        }
    }
    return allocator.dupe(u8, path);
}

test "home path abbreviation preserves directory boundaries" {
    const descendant = try abbreviateHomePath(std.testing.allocator, "/home/tim/project", "/home/tim/");
    defer std.testing.allocator.free(descendant);
    try std.testing.expectEqualStrings("~/project", descendant);

    const sibling = try abbreviateHomePath(std.testing.allocator, "/home/timothy/project", "/home/tim");
    defer std.testing.allocator.free(sibling);
    try std.testing.expectEqualStrings("/home/timothy/project", sibling);
}

fn abbreviatePromptPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    dir_length: usize,
    full_length_dirs: usize,
) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var cursor: usize = 0;
    const prefix: []const u8 = if (std.mem.startsWith(u8, path, "~/")) prefix: {
        cursor = 2;
        break :prefix "~/";
    } else if (std.mem.eql(u8, path, "~")) {
        return allocator.dupe(u8, path);
    } else if (std.mem.startsWith(u8, path, "/")) prefix: {
        cursor = 1;
        break :prefix "/";
    } else "";

    while (cursor <= path.len) {
        const rest = path[cursor..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        if (slash != 0) try parts.append(allocator, rest[0..slash]);
        if (slash == rest.len) break;
        cursor += slash + 1;
    }
    if (parts.items.len <= full_length_dirs) return allocator.dupe(u8, path);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, prefix);
    for (parts.items, 0..) |part, index| {
        if (index != 0) try out.append(allocator, '/');
        if (index + full_length_dirs >= parts.items.len) {
            try out.appendSlice(allocator, part);
        } else {
            try out.appendSlice(allocator, part[0..@min(dir_length, part.len)]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn evalColor(sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len == 4 and std.mem.eql(u8, args[1], "dim")) {
        const color = parseRgb(args[2]) orelse return .{ .status = 2 };
        const percent = std.fmt.parseInt(u8, args[3], 10) catch return .{ .status = 2 };
        if (percent > 100) return .{ .status = 2 };
        try writeRgb(sh, blendRgb(color, .{ 0, 0, 0 }, percent));
        return .{};
    }
    if (args.len == 5 and std.mem.eql(u8, args[1], "blend")) {
        const lhs = parseRgb(args[2]) orelse return .{ .status = 2 };
        const rhs = parseRgb(args[3]) orelse return .{ .status = 2 };
        const percent = std.fmt.parseInt(u8, args[4], 10) catch return .{ .status = 2 };
        if (percent > 100) return .{ .status = 2 };
        try writeRgb(sh, blendRgb(lhs, rhs, percent));
        return .{};
    }
    return .{ .status = 2 };
}

fn evalPromptDuration(state: *State, sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len != 1) return .{ .status = 2 };
    const duration_ms = state.previous_duration_ms orelse return .{ .status = 1 };
    try sh.host.writeAll(.stdout, try std.fmt.allocPrint(sh.scratchAllocator(), "{d}ms\n", .{duration_ms}));
    return .{};
}

fn evalRushEnv(sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len != 2) return .{ .status = 2 };
    const input = try readStdinAlloc(sh);
    defer sh.scratchAllocator().free(input);

    if (std.mem.eql(u8, args[1], "import-json")) return importJsonEnv(sh, input);
    if (std.mem.eql(u8, args[1], "import-sh")) return importShEnv(sh, input);
    return .{ .status = 2 };
}

fn readStdinAlloc(sh: anytype) ![]const u8 {
    var input: std.ArrayList(u8) = .empty;
    errdefer input.deinit(sh.scratchAllocator());
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_len = try sh.host.read(.stdin, &buffer);
        if (read_len == 0) break;
        try input.appendSlice(sh.scratchAllocator(), buffer[0..read_len]);
    }
    return input.toOwnedSlice(sh.scratchAllocator());
}

fn importJsonEnv(sh: anytype, input: []const u8) !result.EvalResult {
    var parsed = std.json.parseFromSlice(std.json.Value, sh.scratchAllocator(), input, .{
        .duplicate_field_behavior = .use_last,
    }) catch return .{ .status = 1 };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return .{ .status = 1 },
    };
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!isShellVariableName(entry.key_ptr.*)) return .{ .status = 1 };
        switch (entry.value_ptr.*) {
            .string => |value| if (!try putExportedEnv(sh, entry.key_ptr.*, value)) return .{ .status = 1 },
            .null => if (!removeEnv(sh, entry.key_ptr.*)) return .{ .status = 1 },
            else => return .{ .status = 1 },
        }
    }
    return .{};
}

fn evalRushComplete(state: *State, sh: anytype, args: []const []const u8) !result.EvalResult {
    const context = state.completion_context orelse {
        try sh.host.writeAll(.stderr, "rush_complete: only available during completion providers\n");
        return .{ .status = 2 };
    };
    if (args.len < 2) return .{ .status = 2 };
    if (std.mem.eql(u8, args[1], "candidate")) return rushCompleteCandidate(context, args);
    if (std.mem.eql(u8, args[1], "files")) return rushCompletePaths(context, sh, args, false);
    if (std.mem.eql(u8, args[1], "directories")) return rushCompletePaths(context, sh, args, true);
    if (std.mem.eql(u8, args[1], "aliases")) return rushCompleteNames(context, sh.state.aliases, .plain, "alias");
    if (std.mem.eql(u8, args[1], "variables")) return rushCompleteVariables(context, sh);
    if (std.mem.eql(u8, args[1], "functions")) return rushCompleteFunctions(context, sh);
    if (std.mem.eql(u8, args[1], "jobs")) return rushCompleteJobs(context, sh);
    if (std.mem.eql(u8, args[1], "history-directories")) return rushCompleteHistoryDirectories(context, sh, args);
    if (std.mem.eql(u8, args[1], "option-present")) return rushCompleteOptionPresent(context, args);
    if (std.mem.eql(u8, args[1], "option-values")) return rushCompleteOptionValues(context, sh, args);
    if (std.mem.eql(u8, args[1], "operand")) return rushCompleteOperand(context, sh, args);
    return .{ .status = 2 };
}

fn rushCompleteCandidate(context: *CompletionContext, args: []const []const u8) !result.EvalResult {
    if (args.len < 3) return .{ .status = 2 };
    var candidate: completion.Candidate = .{
        .value = try context.allocator.dupe(u8, args[2]),
        .replace_start = context.replace_start,
        .replace_end = context.replace_end,
        .source_order = context.next_source_order,
    };
    errdefer freeCompletionCandidateFields(context.allocator, candidate);

    var index: usize = 3;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--kind")) {
            index += 1;
            if (index >= args.len) return .{ .status = 2 };
            candidate.kind = parseCompletionKind(args[index]) orelse return .{ .status = 2 };
        } else if (std.mem.eql(u8, arg, "--description")) {
            index += 1;
            if (index >= args.len) return .{ .status = 2 };
            candidate.description = try context.allocator.dupe(u8, args[index]);
        } else if (std.mem.eql(u8, arg, "--display")) {
            index += 1;
            if (index >= args.len) return .{ .status = 2 };
            candidate.display = try context.allocator.dupe(u8, args[index]);
        } else if (std.mem.eql(u8, arg, "--insert")) {
            index += 1;
            if (index >= args.len) return .{ .status = 2 };
            candidate.insert = try context.allocator.dupe(u8, args[index]);
        } else if (std.mem.eql(u8, arg, "--tag")) {
            index += 1;
            if (index >= args.len) return .{ .status = 2 };
            candidate.tag = try context.allocator.dupe(u8, args[index]);
        } else if (std.mem.eql(u8, arg, "--suffix")) {
            index += 1;
            if (index >= args.len) return .{ .status = 2 };
            candidate.suffix = try context.allocator.dupe(u8, args[index]);
        } else if (std.mem.eql(u8, arg, "--priority")) {
            index += 1;
            if (index >= args.len) return .{ .status = 2 };
            candidate.priority = std.fmt.parseInt(i8, args[index], 10) catch return .{ .status = 2 };
        } else if (std.mem.eql(u8, arg, "--no-space")) {
            candidate.append_space = false;
        } else return .{ .status = 2 };
    }
    try context.candidates.append(context.allocator, candidate);
    context.next_source_order += 1;
    return .{};
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn rushCompletePaths(context: *CompletionContext, sh: anytype, args: []const []const u8, directories_only: bool) !result.EvalResult {
    for (args[2..]) |arg| if (!std.mem.eql(u8, arg, "--append-slash")) return .{ .status = 2 };
    try appendPathCompletionCandidates(context, sh, directories_only);
    return .{};
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn rushCompleteNames(context: *CompletionContext, map: anytype, kind: completion.Kind, description: []const u8) !result.EvalResult {
    var iterator = map.iterator();
    while (iterator.next()) |entry| try appendCompletionCandidate(context, entry.key_ptr.*, kind, description, 0);
    return .{};
}

fn rushCompleteVariables(context: *CompletionContext, sh: anytype) !result.EvalResult {
    var iterator = sh.state.bindings.iterator();
    while (iterator.next()) |entry| {
        const variable = entry.value_ptr.variable() orelse continue;
        try appendCompletionCandidate(context, variable.name, .variable, "variable", 0);
    }
    return .{};
}

fn rushCompleteFunctions(context: *CompletionContext, sh: anytype) !result.EvalResult {
    var iterator = sh.state.functions.iterator();
    while (iterator.next()) |entry| {
        if (!sh.state.isFunctionAutoloadSuppressed(entry.key_ptr.*)) {
            try appendCompletionCandidate(context, entry.key_ptr.*, .function, "function", 0);
        }
    }
    return .{};
}

fn rushCompleteJobs(context: *CompletionContext, sh: anytype) !result.EvalResult {
    for (sh.state.background_jobs.items) |job| {
        const value = try std.fmt.allocPrint(context.allocator, "%{d}", .{job.id});
        defer context.allocator.free(value);
        try appendCompletionCandidate(context, value, .plain, "job", 0);
    }
    return .{};
}

fn rushCompleteHistoryDirectories(
    context: *CompletionContext,
    sh: anytype,
    args: []const []const u8,
) !result.EvalResult {
    if (args.len != 2) return .{ .status = 2 };
    if (comptime !@hasField(@TypeOf(sh.*), "command_history")) return .{};
    const command_history = sh.command_history orelse return .{};
    const list_directories = command_history.directories orelse return .{};

    var terms: std.ArrayList([]const u8) = .empty;
    defer terms.deinit(context.allocator);
    for (context.operands) |operand| try terms.append(context.allocator, operand.value);
    if (context.prefix.len != 0) try terms.append(context.allocator, context.prefix);

    const exclude = shellValue(sh, "PWD") orelse "";
    const now = std.Io.Clock.real.now(command_history.io).toSeconds();
    var directories = list_directories(
        command_history.context,
        context.allocator,
        terms.items,
        exclude,
        now,
    ) catch return .{};
    defer directories.deinit(context.allocator);

    for (directories.entries) |entry| {
        if (entry.path.len == 0 or entry.path[0] != '/') continue;
        const name = std.fs.path.basename(entry.path);
        if (name.len == 0) continue;
        const value = if (context.prefix.len == 0)
            name
        else suffix: {
            const start = std.ascii.findIgnoreCase(name, context.prefix) orelse continue;
            break :suffix name[start..];
        };
        const description = try abbreviateHomePath(context.allocator, entry.path, shellValue(sh, "HOME"));
        defer context.allocator.free(description);
        try appendCompletionCandidate(context, value, .directory, description, 0);
        const candidate = &context.candidates.items[context.candidates.items.len - 1];
        candidate.append_space = true;
        if (!std.mem.eql(u8, value, name)) candidate.display = try context.allocator.dupe(u8, name);
    }
    return .{};
}

fn rushCompleteOptionPresent(context: *CompletionContext, args: []const []const u8) result.EvalResult {
    const selector = parseCompletionOptionSelector(args) orelse return .{ .status = 2 };
    for (context.parsed_options) |option| {
        if (completionOptionMatchesSelector(option, selector)) return .{};
    }
    return .{ .status = 1 };
}

fn rushCompleteOptionValues(context: *CompletionContext, sh: anytype, args: []const []const u8) !result.EvalResult {
    const selector = parseCompletionOptionSelector(args) orelse return .{ .status = 2 };
    for (context.parsed_options) |option| {
        if (!completionOptionMatchesSelector(option, selector)) continue;
        if (option.value) |value| {
            try sh.host.writeAll(.stdout, value);
            try sh.host.writeAll(.stdout, "\n");
        }
    }
    return .{};
}

fn rushCompleteOperand(context: *CompletionContext, sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len != 3) return .{ .status = 2 };
    const wanted = std.fmt.parseInt(usize, args[2], 10) catch return .{ .status = 2 };
    for (context.operands) |operand| {
        if (operand.index != wanted) continue;
        try sh.host.writeAll(.stdout, operand.value);
        try sh.host.writeAll(.stdout, "\n");
        return .{};
    }
    return .{ .status = 1 };
}

const CompletionOptionSelector = union(enum) {
    long: []const u8,
    short: []const u8,
};

fn parseCompletionOptionSelector(args: []const []const u8) ?CompletionOptionSelector {
    if (args.len != 4) return null;
    if (std.mem.eql(u8, args[2], "--long")) return .{ .long = args[3] };
    if (std.mem.eql(u8, args[2], "--short")) return .{ .short = args[3] };
    return null;
}

fn completionOptionMatchesSelector(option: CompletionParsedOption, selector: CompletionOptionSelector) bool {
    return switch (selector) {
        .long => |name| std.mem.eql(u8, option.name, name) or
            (option.spelling.len == name.len + 2 and std.mem.eql(u8, option.spelling[0..2], "--") and
                std.mem.eql(u8, option.spelling[2..], name)),
        .short => |name| std.mem.eql(u8, option.name, name) or
            (option.spelling.len == name.len + 1 and option.spelling[0] == '-' and
                std.mem.eql(u8, option.spelling[1..], name)),
    };
}

fn appendPathCompletionCandidates(context: *CompletionContext, sh: anytype, directories_only: bool) !void {
    // ziglint-ignore: Z011 deprecated API left unchanged to avoid semantic drift in lint-only pass
    const slash = std.mem.lastIndexOfScalar(u8, context.prefix, '/');
    const dir_prefix = if (slash) |index| context.prefix[0 .. index + 1] else "";
    const entry_prefix = if (slash) |index| context.prefix[index + 1 ..] else context.prefix;
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const unexpanded_dir_path = if (dir_prefix.len == 0) "." else if (std.mem.eql(u8, dir_prefix, "/")) "/" else std.mem.trimEnd(u8, dir_prefix, "/");
    const dir_path = try completion_path.expandLeadingTilde(
        context.allocator,
        unexpanded_dir_path,
        shellValue(sh, "HOME"),
    );
    defer context.allocator.free(dir_path);
    var entries = sh.host.listDir(context.allocator, dir_path) catch return;
    defer entries.deinit();
    const include_hidden = std.mem.startsWith(u8, entry_prefix, ".");
    for (entries.entries) |entry| {
        if (entry.name.len == 0 or std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (!include_hidden and entry.name[0] == '.') continue;
        const is_directory = entry.kind == .directory;
        if (directories_only and !is_directory) continue;
        const value = if (is_directory)
            try std.fmt.allocPrint(context.allocator, "{s}{s}/", .{ dir_prefix, entry.name })
        else
            try std.fmt.allocPrint(context.allocator, "{s}{s}", .{ dir_prefix, entry.name });
        defer context.allocator.free(value);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try appendCompletionCandidate(context, value, if (is_directory) .directory else .file, if (is_directory) "directory" else "file", 0);
    }
}

test "rush_complete path provider leaves case-insensitive filtering to the matcher" {
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
            const entries = try allocator.alloc(host.DirectoryEntry, 1);
            errdefer allocator.free(entries);
            entries[0] = .{ .name = try allocator.dupe(u8, "AGENTS.md"), .kind = .file };
            return .{ .allocator = allocator, .entries = entries };
        }
    };
    const TestShell = struct {
        host: TestHost,
        state: TestState,
        env: []const [*:0]const u8 = &.{},
    };

    var context: CompletionContext = .init(
        std.testing.allocator,
        "agents",
        0,
        "agents".len,
        0,
        false,
        "item",
        &.{},
        &.{},
    );
    defer context.deinit();
    var sh: TestShell = .{ .host = .{}, .state = .{} };

    try appendPathCompletionCandidates(&context, &sh, false);
    const candidates = try context.takeCandidates();
    defer completion.freeCandidates(std.testing.allocator, candidates);

    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("AGENTS.md", candidates[0].value);
    try std.testing.expectEqual(completion.MatchRank.prefix, completion.candidateMatchRank(
        candidates[0],
        context.prefix,
        .prefixOnly(),
    ).?);
}

fn appendCompletionCandidate(
    context: *CompletionContext,
    value: []const u8,
    kind: completion.Kind,
    description: ?[]const u8,
    priority: i8,
) !void {
    const owned_value = try context.allocator.dupe(u8, value);
    errdefer context.allocator.free(owned_value);
    const owned_description = if (description) |text| try context.allocator.dupe(u8, text) else null;
    errdefer if (owned_description) |text| context.allocator.free(text);
    try context.candidates.append(context.allocator, .{
        .value = owned_value,
        .description = owned_description,
        .kind = kind,
        .priority = priority,
        .replace_start = context.replace_start,
        .replace_end = context.replace_end,
        .append_space = kind != .directory,
        .source_order = context.next_source_order,
    });
    context.next_source_order += 1;
}

fn parseCompletionKind(value: []const u8) ?completion.Kind {
    inline for (std.meta.fields(completion.Kind)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn freeCompletionCandidateFields(allocator: std.mem.Allocator, candidate: completion.Candidate) void {
    const owned = allocator.alloc(completion.Candidate, 1) catch unreachable;
    owned[0] = candidate;
    completion.freeCandidates(allocator, owned);
}

fn importShEnv(sh: anytype, input: []const u8) !result.EvalResult {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "export ")) {
            const assignment = std.mem.trim(u8, line[7..], " \t");
            const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse return .{ .status = 1 };
            const name = assignment[0..equals];
            if (!isShellVariableName(name)) return .{ .status = 1 };
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            const value = parseShellEnvValue(sh.scratchAllocator(), assignment[equals + 1 ..]) catch return .{ .status = 1 };
            defer sh.scratchAllocator().free(value);
            if (!try putExportedEnv(sh, name, value)) return .{ .status = 1 };
            continue;
        }
        if (std.mem.startsWith(u8, line, "unset ")) {
            const name = std.mem.trim(u8, line[6..], " \t");
            if (!isShellVariableName(name)) return .{ .status = 1 };
            if (!removeEnv(sh, name)) return .{ .status = 1 };
            continue;
        }
        return .{ .status = 1 };
    }
    return .{};
}

fn putExportedEnv(sh: anytype, name: []const u8, value: []const u8) !bool {
    sh.state.putVariable(.{ .name = name, .value = value, .exported = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => return false,
    };
    return true;
}

fn removeEnv(sh: anytype, name: []const u8) bool {
    if (sh.state.getVariable(name)) |variable| {
        if (variable.readonly) return false;
        sh.state.removeVariable(name);
        return true;
    }
    if (sh.state.getVariableAttributes(name)) |attributes| {
        if (attributes.readonly) return false;
        sh.state.removeVariableAttributes(name);
    }
    return true;
}

fn parseShellEnvValue(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') {
        if (std.mem.indexOfScalar(u8, value[1 .. value.len - 1], '\'') != null) return error.InvalidEnvScript;
        return allocator.dupe(u8, value[1 .. value.len - 1]);
    }
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var index: usize = 1;
        while (index < value.len - 1) : (index += 1) {
            if (value[index] == '\\') {
                index += 1;
                if (index >= value.len - 1) return error.InvalidEnvScript;
            }
            try out.append(allocator, value[index]);
        }
        return out.toOwnedSlice(allocator);
    }
    if (std.mem.indexOfAny(u8, value, " \t'\"`;$|&<>()") != null) return error.InvalidEnvScript;
    return allocator.dupe(u8, value);
}

fn isShellVariableName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn writeRgb(sh: anytype, rgb: [3]u8) !void {
    try sh.host.writeAll(.stdout, try std.fmt.allocPrint(
        sh.scratchAllocator(),
        "#{x:0>2}{x:0>2}{x:0>2}\n",
        .{ rgb[0], rgb[1], rgb[2] },
    ));
}

pub fn renderPrompt(
    allocator: std.mem.Allocator,
    sh: anytype,
    previous_status: result.ExitStatus,
    previous_duration_ms: ?i64,
) ![]const u8 {
    return (try renderPromptFunction(
        allocator,
        sh,
        "rush_prompt",
        previous_status,
        previous_duration_ms,
        .fallback_static,
    )) orelse unreachable;
}

pub fn renderTransientPrompt(
    allocator: std.mem.Allocator,
    sh: anytype,
    previous_status: result.ExitStatus,
    previous_duration_ms: ?i64,
) !?[]const u8 {
    return renderPromptFunction(
        allocator,
        sh,
        "rush_prompt_transient",
        previous_status,
        previous_duration_ms,
        .skip,
    );
}

pub fn renderRightPrompt(
    allocator: std.mem.Allocator,
    sh: anytype,
    previous_status: result.ExitStatus,
    previous_duration_ms: ?i64,
) !?[]const u8 {
    return renderPromptFunction(
        allocator,
        sh,
        "rush_prompt_right",
        previous_status,
        previous_duration_ms,
        .skip,
    );
}

const PromptFallback = enum { fallback_static, skip };

fn renderPromptFunction(
    allocator: std.mem.Allocator,
    sh: anytype,
    function_name: []const u8,
    previous_status: result.ExitStatus,
    previous_duration_ms: ?i64,
    fallback: PromptFallback,
) !?[]const u8 {
    if (sh.state.getFunction(function_name) == null) return switch (fallback) {
        .fallback_static => try staticPrompt(allocator, sh),
        .skip => null,
    };
    sh.extensions.clearPrompt();
    sh.extensions.building_prompt = true;
    sh.extensions.previous_duration_ms = previous_duration_ms;
    defer sh.extensions.building_prompt = false;
    defer sh.extensions.previous_duration_ms = null;

    const saved_status = sh.state.last_status;
    sh.state.last_status = previous_status;
    defer sh.state.last_status = saved_status;

    const src: shell.source.Source = .{ .id = 0, .kind = .command_string, .name = "prompt", .text = function_name };
    const evaluated = sh.evalSourceNested(src) catch return switch (fallback) {
        .fallback_static => try staticPrompt(allocator, sh),
        .skip => null,
    };
    if (evaluated.status != 0 or evaluated.flow != .normal or sh.extensions.prompt_buffer.items.len == 0) {
        return switch (fallback) {
            .fallback_static => try staticPrompt(allocator, sh),
            .skip => null,
        };
    }
    return try allocator.dupe(u8, sh.extensions.prompt_buffer.items);
}

fn staticPrompt(allocator: std.mem.Allocator, sh: anytype) ![]const u8 {
    if (sh.state.getVariable("PS1")) |variable| return allocator.dupe(u8, variable.value);
    return allocator.dupe(u8, "rush> ");
}

fn appendStyleStart(state: *State, fg: ?[]const u8, bg: ?[]const u8) !void {
    if (fg == null and bg == null) return;
    try state.appendPrompt("\x1b[");
    var needs_separator = false;
    if (fg) |color| {
        try appendColorCode(state, false, color);
        needs_separator = true;
    }
    if (bg) |color| {
        if (needs_separator) try state.appendPrompt(";");
        try appendColorCode(state, true, color);
    }
    try state.appendPrompt("m");
}

fn appendColorCode(state: *State, background: bool, color: []const u8) !void {
    if (parseRgb(color)) |rgb| {
        const prefix = if (background) "48" else "38";
        try appendPromptPrint(state, "{s};2;{d};{d};{d}", .{ prefix, rgb[0], rgb[1], rgb[2] });
        return;
    }
    const base: u8 = if (background) 40 else 30;
    const offset = namedAnsiColorOffset(color) orelse {
        try state.appendPrompt(if (background) "49" else "39");
        return;
    };
    try appendPromptPrint(state, "{d}", .{base + offset});
}

fn appendPromptPrint(state: *State, comptime fmt: []const u8, args: anytype) !void {
    const bytes = try std.fmt.allocPrint(state.allocator, fmt, args);
    defer state.allocator.free(bytes);
    try state.appendPrompt(bytes);
}

fn namedAnsiColorOffset(color: []const u8) ?u8 {
    if (std.mem.eql(u8, color, "black")) return 0;
    if (std.mem.eql(u8, color, "red")) return 1;
    if (std.mem.eql(u8, color, "green")) return 2;
    if (std.mem.eql(u8, color, "yellow")) return 3;
    if (std.mem.eql(u8, color, "blue")) return 4;
    if (std.mem.eql(u8, color, "magenta")) return 5;
    if (std.mem.eql(u8, color, "cyan")) return 6;
    if (std.mem.eql(u8, color, "white")) return 7;
    return null;
}

fn shellEnvValue(sh: anytype, name: []const u8) ?[]const u8 {
    for (sh.env) |entry_ptr| {
        const entry = std.mem.span(entry_ptr);
        if (entry.len <= name.len or entry[name.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

fn shellValue(sh: anytype, name: []const u8) ?[]const u8 {
    if (sh.state.getVariable(name)) |variable| return variable.value;
    return shellEnvValue(sh, name);
}

pub fn expandAbbreviation(
    state: *State,
    allocator: std.mem.Allocator,
    source: []const u8,
    cursor: usize,
    append_space: bool,
) !?completion.Edit {
    const end = @min(cursor, source.len);
    var start = end;
    while (start > 0 and isCommandNameByte(source[start - 1])) start -= 1;
    if (start == end) return null;
    if (start > 0 and !isCommandSeparator(source[start - 1])) return null;
    const name = source[start..end];
    const replacement = state.getAbbreviation(name) orelse return null;
    return .{
        .replace_start = start,
        .replace_end = end,
        .replacement = try allocator.dupe(u8, replacement),
        .append_space = append_space,
    };
}

fn isCommandNameByte(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', ';', '|', '&', '(', ')' => false,
        else => true,
    };
}

fn isCommandSeparator(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', ';', '|', '&', '(' => true,
        else => false,
    };
}

fn parseRgb(text: []const u8) ?[3]u8 {
    if (text.len != 7 or text[0] != '#') return null;
    return .{
        std.fmt.parseInt(u8, text[1..3], 16) catch return null,
        std.fmt.parseInt(u8, text[3..5], 16) catch return null,
        std.fmt.parseInt(u8, text[5..7], 16) catch return null,
    };
}

fn blendRgb(lhs: [3]u8, rhs: [3]u8, percent: u8) [3]u8 {
    var out: [3]u8 = undefined;
    for (&out, lhs, rhs) |*channel, a, b| {
        const left: i32 = a;
        const right: i32 = b;
        channel.* = @intCast(@divTrunc(left * (100 - percent) + right * percent, 100));
    }
    return out;
}

fn shellCommand(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (args, 0..) |arg, index| {
        if (index != 0) try out.append(allocator, ' ');
        try appendShellSingleQuoted(allocator, &out, arg);
    }
    return out.toOwnedSlice(allocator);
}

fn appendShellSingleQuoted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
}

fn eventKey(allocator: std.mem.Allocator, event: []const u8, name: []const u8) ![]const u8 {
    var key: std.ArrayList(u8) = .empty;
    errdefer key.deinit(allocator);
    try key.appendSlice(allocator, event);
    try key.append(allocator, 0);
    try key.appendSlice(allocator, name);
    return key.toOwnedSlice(allocator);
}

test "Rush extension registry exposes abbr as an extension" {
    const abbr = registry.lookup("abbr") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(builtin.Origin.extension, abbr.origin);
}

test "Rush extension registry does not expose legacy prompt_async command" {
    try std.testing.expectEqual(null, registry.lookup("prompt_async"));
}
