//! Interactive event hook dispatch for Rush extensions.

const std = @import("std");

const editor = @import("../editor.zig");
const file_util = @import("../file_util.zig");
const host = @import("../host.zig");
const shell = @import("../shell.zig");

pub fn Dispatcher(comptime ShellType: type) type {
    return struct {
        sh: *ShellType,

        const Self = @This();

        pub fn runEvent(
            self: *Self,
            allocator: std.mem.Allocator,
            io: std.Io,
            event_name: []const u8,
            args: []const []const u8,
        ) !DispatchResult {
            var output: std.ArrayList(u8) = .empty;
            errdefer output.deinit(allocator);

            const visible_status = self.sh.state.last_status;
            const calls = try self.hookCalls(allocator, event_name, null);
            defer freeHookCalls(allocator, calls);

            for (calls) |call| {
                self.sh.state.last_status = visible_status;
                const evaluated = try self.runHook(allocator, io, event_name, call, args, &output);
                self.sh.state.last_status = visible_status;
                switch (evaluated.flow) {
                    .exit, .fatal => return .{
                        .output = try output.toOwnedSlice(allocator),
                        .exit_status = evaluated.status,
                        .ran_count = calls.len,
                    },
                    else => {},
                }
            }
            self.sh.state.last_status = visible_status;
            return .{ .output = try output.toOwnedSlice(allocator), .ran_count = calls.len };
        }

        pub fn runDueTimers(
            self: *Self,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !DispatchResult {
            var output: std.ArrayList(u8) = .empty;
            errdefer output.deinit(allocator);

            const now_ms = monotonicMillis(io);
            const visible_status = self.sh.state.last_status;
            const calls = try self.hookCalls(allocator, "timer.tick", now_ms);
            defer freeHookCalls(allocator, calls);

            for (calls) |call| {
                self.sh.state.last_status = visible_status;
                const evaluated = try self.runHook(allocator, io, "timer.tick", call, &.{call.name}, &output);
                self.sh.state.last_status = visible_status;
                switch (evaluated.flow) {
                    .exit, .fatal => return .{
                        .output = try output.toOwnedSlice(allocator),
                        .exit_status = evaluated.status,
                        .ran_count = calls.len,
                    },
                    else => {},
                }
            }
            self.sh.state.last_status = visible_status;
            return .{ .output = try output.toOwnedSlice(allocator), .ran_count = calls.len };
        }

        pub fn nextTimerDelayMs(self: *Self, io: std.Io) ?u64 {
            var next_delay: ?u64 = null;
            const now_ms = monotonicMillis(io);
            var iterator = self.sh.extensions.event_handlers.iterator();
            while (iterator.next()) |entry| {
                if (!std.mem.eql(u8, entry.value_ptr.event, "timer.tick")) continue;
                const every_ms = entry.value_ptr.every_ms orelse continue;
                const next_tick_ms = entry.value_ptr.next_tick_ms orelse now_ms +| every_ms;
                entry.value_ptr.next_tick_ms = next_tick_ms;
                const delay = if (next_tick_ms <= now_ms) 0 else next_tick_ms - now_ms;
                if (next_delay == null or delay < next_delay.?) next_delay = delay;
            }
            return next_delay;
        }

        fn hookCalls(
            self: *Self,
            allocator: std.mem.Allocator,
            event_name: []const u8,
            now_ms: ?u64,
        ) ![]HookCall {
            var calls: std.ArrayList(HookCall) = .empty;
            errdefer {
                for (calls.items) |*call| call.deinit(allocator);
                calls.deinit(allocator);
            }

            var iterator = self.sh.extensions.event_handlers.iterator();
            while (iterator.next()) |entry| {
                const handler = entry.value_ptr;
                if (!std.mem.eql(u8, handler.event, event_name)) continue;
                if (now_ms) |now| {
                    const every_ms = handler.every_ms orelse continue;
                    const next_tick_ms = handler.next_tick_ms orelse now +| every_ms;
                    handler.next_tick_ms = next_tick_ms;
                    if (next_tick_ms > now) continue;
                    handler.next_tick_ms = now +| every_ms;
                }

                const owned_name = try allocator.dupe(u8, handler.name);
                errdefer allocator.free(owned_name);
                const owned_action = try allocator.dupe(u8, handler.action);
                errdefer allocator.free(owned_action);
                try calls.append(allocator, .{
                    .name = owned_name,
                    .action = owned_action,
                    .priority = handler.priority,
                });
            }
            std.mem.sort(HookCall, calls.items, {}, lessThanHookCall);
            return calls.toOwnedSlice(allocator);
        }

        fn runHook(
            self: *Self,
            allocator: std.mem.Allocator,
            io: std.Io,
            event_name: []const u8,
            call: HookCall,
            args: []const []const u8,
            output: *std.ArrayList(u8),
        ) !shell.result.EvalResult {
            var capture = try file_util.AnonymousFile.init(allocator, io, &self.sh.host, "rush-event");
            defer capture.deinit(&self.sh.host);

            const command = try eventCommand(allocator, event_name, call, args, capture.fd);
            defer allocator.free(command);

            const src: shell.source.Source = .{
                .id = 0,
                .kind = .command_string,
                .name = "event",
                .text = command,
            };
            const evaluated = self.sh.evalSourceNested(src) catch |err| switch (err) {
                error.ExpectedCommand,
                error.ExpectedRedirectionTarget,
                error.InvalidParameterExpansion,
                error.UnclosedCommandSubstitution,
                error.UnclosedQuote,
                error.UnexpectedToken,
                => @as(shell.result.EvalResult, .{ .status = 2 }),
                else => return err,
            };
            try capture.readAll(allocator, &self.sh.host, output);
            return evaluated;
        }
    };
}

pub const DispatchResult = struct {
    output: []const u8,
    exit_status: ?shell.result.ExitStatus = null,
    ran_count: usize = 0,

    pub fn deinit(self: *DispatchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        self.* = undefined;
    }

    pub fn hookResult(self: DispatchResult) editor.driver.HookResult {
        return .{
            .output = self.output,
            .refresh_prompt = self.ran_count != 0 or self.output.len != 0,
            .stop = self.exit_status != null,
        };
    }
};

const HookCall = struct {
    name: []const u8,
    action: []const u8,
    priority: i32,

    fn deinit(self: *HookCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.action);
        self.* = undefined;
    }
};

fn lessThanHookCall(_: void, left: HookCall, right: HookCall) bool {
    if (left.priority != right.priority) return left.priority < right.priority;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn freeHookCalls(allocator: std.mem.Allocator, calls: []HookCall) void {
    for (calls) |*call| call.deinit(allocator);
    allocator.free(calls);
}

fn eventCommand(
    allocator: std.mem.Allocator,
    event_name: []const u8,
    call: HookCall,
    args: []const []const u8,
    capture_fd: host.Fd,
) ![]const u8 {
    var command: std.ArrayList(u8) = .empty;
    errdefer command.deinit(allocator);

    try command.appendSlice(allocator, "RUSH_EVENT=");
    try appendShellSingleQuoted(allocator, &command, event_name);
    try command.appendSlice(allocator, " RUSH_EVENT_HOOK=");
    try appendShellSingleQuoted(allocator, &command, call.name);
    try command.append(allocator, ' ');
    try command.appendSlice(allocator, call.action);
    for (args) |arg| {
        try command.append(allocator, ' ');
        try appendShellSingleQuoted(allocator, &command, arg);
    }
    try command.print(allocator, " >&{d} 2>&1", .{capture_fd.raw()});
    return command.toOwnedSlice(allocator);
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

fn monotonicMillis(io: std.Io) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds());
}

test "event commands quote context and capture redirections" {
    const command = try eventCommand(
        std.testing.allocator,
        "timer.tick",
        .{ .name = "tick'one", .action = "on_tick", .priority = 0 },
        &.{"arg value"},
        @enumFromInt(9),
    );
    defer std.testing.allocator.free(command);

    try std.testing.expectEqualStrings(
        "RUSH_EVENT='timer.tick' RUSH_EVENT_HOOK='tick'\\''one' on_tick 'arg value' >&9 2>&1",
        command,
    );
}

test "timer delay initializes and advances hook deadlines" {
    const extensions = @import("../extensions.zig");
    const TestHost = struct {
        pub fn writeAll(_: *@This(), _: host.Fd, _: []const u8) !void {}
    };
    const TestShell = shell.ShellWithBuiltins(TestHost, extensions.rush.registry);

    var sh = TestShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    try sh.extensions.putEventHandler("timer.tick", "clock", "on_tick", 0, 50);
    var dispatcher: Dispatcher(TestShell) = .{ .sh = &sh };

    const delay = dispatcher.nextTimerDelayMs(std.testing.io) orelse return error.ExpectedDelay;
    try std.testing.expect(delay <= 50);
}

test "event dispatch captures output while preserving visible status" {
    const extensions = @import("../extensions.zig");
    const TestShell = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry);

    var sh = TestShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    sh.state.last_status = 7;

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text = "on_prepare(){ PREPARED=\"$?:$RUSH_EVENT:$RUSH_EVENT_HOOK:$1\"; echo hook-output; }",
    };
    const defined = try sh.evalSource(src);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 0), defined.status);
    sh.state.last_status = 7;

    try sh.extensions.putEventHandler("prompt.prepare", "prep", "on_prepare", 0, null);
    var dispatcher: Dispatcher(TestShell) = .{ .sh = &sh };

    var dispatched = try dispatcher.runEvent(std.testing.allocator, std.testing.io, "prompt.prepare", &.{"arg"});
    defer dispatched.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hook-output\n", dispatched.output);
    try std.testing.expectEqual(@as(?shell.result.ExitStatus, null), dispatched.exit_status);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 7), sh.state.last_status);
    try std.testing.expectEqualStrings("7:prompt.prepare:prep:arg", sh.state.getVariable("PREPARED").?.value);
    try std.testing.expectEqual(@as(?shell.state.Variable, null), sh.state.getVariable("RUSH_EVENT"));
    try std.testing.expectEqual(@as(?shell.state.Variable, null), sh.state.getVariable("RUSH_EVENT_HOOK"));
}

test "event hook result refreshes only when work ran" {
    const extensions = @import("../extensions.zig");
    const TestShell = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry);

    var sh = TestShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    var dispatcher: Dispatcher(TestShell) = .{ .sh = &sh };

    var idle = try dispatcher.runEvent(std.testing.allocator, std.testing.io, "prompt.prepare", &.{});
    defer idle.deinit(std.testing.allocator);
    try std.testing.expect(!idle.hookResult().refresh_prompt);

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text = "on_prepare(){ PROMPT_PREPARED=1; }",
    };
    const defined = try sh.evalSource(src);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 0), defined.status);

    try sh.extensions.putEventHandler("prompt.prepare", "prep", "on_prepare", 0, null);
    var ran = try dispatcher.runEvent(std.testing.allocator, std.testing.io, "prompt.prepare", &.{});
    defer ran.deinit(std.testing.allocator);
    try std.testing.expect(ran.hookResult().refresh_prompt);
}
