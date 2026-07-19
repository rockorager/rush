//! Interactive Rush session orchestration.

const std = @import("std");

const completion = @import("completion.zig");
const editor = @import("editor.zig");
const extensions = @import("extensions.zig");
const function_autoload = @import("function_autoload.zig");
const history = @import("history.zig");
const host = @import("host.zig");
const interactive_event = @import("interactive/event.zig");
const interactive_style = @import("interactive/style.zig");
const startup = @import("interactive/startup.zig");
const shell = @import("shell.zig");

const RushShell = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry);

pub const Options = struct {
    state_options: shell.state.Options,
    arg_zero: []const u8,
    positionals: []const []const u8 = &.{},
    login: bool = false,
    forced_interactive: bool = false,
};

pub fn run(
    allocator: std.mem.Allocator,
    real_host: host.RealHost,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    io: std.Io,
    env: []const [*:0]const u8,
    options: Options,
) !u8 {
    var host_probe = real_host;
    const stdin_terminal = host_probe.isTerminalFd(.stdin);
    // POSIX: without -i, a shell whose standard input is not a terminal is
    // not interactive; it reads commands from standard input like a script.
    const interactive = options.forced_interactive or stdin_terminal;
    var state_options = options.state_options;
    if (!interactive) state_options.interactive = false;

    const initial_pwd = try real_host.currentDir(allocator);
    var sh = RushShell.init(allocator, real_host, .{
        .state = state_options,
        .env = env,
        .arg_zero = options.arg_zero,
        .positionals = options.positionals,
        .initial_pwd = initial_pwd,
    });
    defer sh.deinit();
    sh.setFunctionAutoload(autoloadRushFunction);

    var source_id: shell.source.SourceId = 1;
    if (try startup.source(&sh, &source_id, options.login, stdin_terminal)) |status| return status;

    if (!interactive) return runStdinScript(allocator, &sh, &source_id);

    var command_history = try history.History.init(allocator);
    defer command_history.deinit();
    if (try startup.historyPath(allocator, env)) |path| {
        defer allocator.free(path);
        command_history.load(io, path) catch |err| {
            const message = try std.fmt.allocPrint(
                sh.scratchAllocator(),
                "rush: persistent history unavailable ({s}); using memory\n",
                .{@errorName(err)},
            );
            try sh.host.writeAll(.stderr, message);
        };
    }
    command_history.session_id = history.sessionId(allocator, io) catch "";
    var history_service = history.InteractiveHistoryService.init(&command_history);
    sh.setCommandHistory(history_service.commandHistory(io));

    if (!stdin_terminal) {
        return runPromptedStdin(allocator, &sh, &source_id);
    }

    var session: InteractiveSession = .{
        .allocator = allocator,
        .io = io,
        .sh = &sh,
        .source_id = &source_id,
        .command_history = &command_history,
        .history_service = &history_service,
        .events = .{ .sh = &sh },
        .last_command_status = sh.state.last_status,
    };
    return session.runTerminal();
}

fn enableJobControl(sh: *RushShell, tty_fd: host.Fd) ?host.Pid {
    const original_process_group = sh.host.currentProcessGroup();
    const original_terminal_group = sh.host.terminalProcessGroup(tty_fd) catch return null;

    const shell_pid = sh.host.currentProcessId();
    sh.state.shell_pid = shell_pid;
    sh.state.controlling_tty = null;
    ignoreInteractiveJobControlSignals(sh);
    // Login shells are usually already process-group leaders (and often session
    // leaders). setpgid fails with EPERM for session leaders, so only create a
    // new group when we are not already the intended leader.
    if (original_process_group != shell_pid) {
        sh.host.setProcessGroup(0, shell_pid) catch {
            sh.state.options.monitor = false;
            return null;
        };
    }
    sh.host.setTerminalProcessGroup(tty_fd, shell_pid) catch {
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        if (original_process_group != shell_pid) sh.host.setProcessGroup(0, original_process_group) catch {};
        sh.state.options.monitor = false;
        return null;
    };
    const foreground_group = sh.host.terminalProcessGroup(tty_fd) catch {
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        sh.host.setTerminalProcessGroup(tty_fd, original_terminal_group) catch {};
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        if (original_process_group != shell_pid) sh.host.setProcessGroup(0, original_process_group) catch {};
        sh.state.options.monitor = false;
        return null;
    };
    if (foreground_group != shell_pid) {
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        sh.host.setTerminalProcessGroup(tty_fd, original_terminal_group) catch {};
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        if (original_process_group != shell_pid) sh.host.setProcessGroup(0, original_process_group) catch {};
        sh.state.options.monitor = false;
        return null;
    }
    // Use the same tty for later give/restore so fg does not hand off via a
    // redirected stdin while the interactive session owns /dev/tty.
    sh.state.controlling_tty = tty_fd;
    sh.state.options.monitor = true;
    return original_terminal_group;
}

fn ignoreInteractiveJobControlSignals(sh: *RushShell) void {
    inline for (.{ "TSTP", "TTIN", "TTOU" }) |name| {
        if (shell.builtin.signalNumber(name)) |signal| {
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            sh.host.setSignalIgnored(signal) catch {};
        }
    }
}

fn deinitTerminalAfterRestore(session: anytype, terminal: anytype) void {
    session.restoreTerminalProcessGroup();
    terminal.deinit();
}

const InteractiveSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sh: *RushShell,
    source_id: *shell.source.SourceId,
    command_history: *history.History,
    history_service: *history.InteractiveHistoryService,
    events: interactive_event.Dispatcher(RushShell),
    terminal: ?*editor.driver.TerminalSession = null,
    dispatching_directory_change: bool = false,
    restore_terminal_pgrp: ?host.Pid = null,
    last_command_status: shell.result.ExitStatus = 0,
    last_command_duration_ms: ?i64 = null,
    pending_event_exit_status: ?u8 = null,
    command_cache: PathCommandCache = .{},
    history_cwd: []const u8 = "",

    fn runTerminal(self: *InteractiveSession) !u8 {
        var terminal = editor.driver.TerminalSession.init(self.allocator, self.io) catch {
            try self.sh.host.writeAll(.stderr, "rush: cannot initialize terminal\n");
            return 2;
        };
        defer self.clearHistoryCurrentDirectory();
        defer self.command_cache.deinit(self.allocator);
        defer deinitTerminalAfterRestore(self, &terminal);
        self.terminal = &terminal;
        defer self.terminal = null;
        self.sh.setDirectoryChangeCallback(self, onDirectoryChange);
        self.restore_terminal_pgrp = enableJobControl(self.sh, @enumFromInt(terminal.ttyFd()));
        self.sh.extensions.configurePromptAsync(self.io, terminal.promptRedrawWakeFd(), .{
            .context = self,
            .register = registerPromptAsyncFd,
            .unregister = unregisterPromptAsyncFd,
        });
        if (try self.dispatchStartupEvents()) |status| return self.exit(status);

        while (true) {
            const line_result = self.readLine(&terminal) catch |err| switch (err) {
                error.EditorFailure => return 2,
                else => return err,
            };
            switch (line_result) {
                .submitted => |line| {
                    defer self.allocator.free(line);
                    if (try self.evaluateSubmittedLine(&terminal, line)) |status| return status;
                },
                .canceled => continue,
                .interrupted => if (self.pending_event_exit_status) |status| return self.exit(status) else continue,
                .eof => {
                    try terminal.leaveEditorMode();
                    return self.exitWithLastStatus();
                },
            }
        }
    }

    fn restoreTerminalProcessGroup(self: *InteractiveSession) void {
        if (self.restore_terminal_pgrp) |process_group| {
            const tty_fd = self.sh.state.controlling_tty orelse .stdin;
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            self.sh.host.setTerminalProcessGroup(tty_fd, process_group) catch {};
        }
    }

    const ReadLineError = error{EditorFailure} || error{OutOfMemory};

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    fn readLine(self: *InteractiveSession, terminal: *editor.driver.TerminalSession) ReadLineError!editor.driver.ReadLineResult {
        const job_output = self.reapBackgroundJobsAndDispatch(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try self.allocator.dupe(u8, ""),
        };
        defer self.allocator.free(job_output);
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        if (job_output.len != 0) self.sh.host.writeAll(.stderr, job_output) catch {};

        // Collect prompt async refreshes that completed while a foreground
        // command was running so the first render shows fresh output.
        self.sh.extensions.pumpPromptAsync();

        const prompt_text = self.renderPrompt() catch try prompt(self.allocator, self.sh);
        defer self.allocator.free(prompt_text);
        const right_prompt_text = try self.renderRightPrompt() orelse "";
        defer if (right_prompt_text.len != 0) self.allocator.free(right_prompt_text);
        _ = self.dispatchPromptAsyncLifecycleEvents(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };

        try self.refreshHistoryCurrentDirectory();
        // ziglint-ignore: Z026 best-effort terminal metadata; the next directory change or prompt reports it again
        self.reportTerminalLocation(terminal) catch {};
        try self.command_cache.refresh(self.allocator, self.sh);

        return terminal.readLine(.{
            .prompt = prompt_text,
            .right_prompt = right_prompt_text,
            // Read shell option state each prompt so `set -o vi` / `set -o emacs`
            // take effect on the next line without restarting the session.
            .editing_mode = if (self.sh.state.options.vi) .vi else .emacs,
            .history = self.history_service.lineEditorView(self.io),
            .prompt_async_context = self,
            .pump_prompt_async = pumpPromptAsync,
            .completion_context = self.sh,
            .complete = completion.complete,
            .expand_abbreviation = expandRushAbbreviation,
            .theme = interactive_style.themeForEnvironment(self.sh.state, self.sh.env),
            .style_context = self.sh,
            .refresh_style = interactive_style.refreshStyle,
            .refresh_color_report = interactive_style.refreshColorReport,
            .diagnostic_context = self,
            .diagnose = diagnoseInteractiveInput,
            .hook_context = self,
            .run_hooks = runInteractiveHooks,
            .next_hook_interval_ms = nextInteractiveHookIntervalMs,
            .prompt_context = self,
            .refresh_prompt = refreshInteractivePrompt,
            .refresh_right_prompt = refreshInteractiveRightPrompt,
            .refresh_transient_prompt = refreshInteractiveTransientPrompt,
        }) catch |err| {
            var message_buffer: [128]u8 = undefined;
            const message = std.fmt.bufPrint(
                &message_buffer,
                "rush: editor error: {s}\n",
                .{@errorName(err)},
            ) catch "rush: editor error\n";
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            self.sh.host.writeAll(.stderr, message) catch {};
            return error.EditorFailure;
        };
    }

    fn refreshHistoryCurrentDirectory(self: *InteractiveSession) !void {
        const current_cwd = self.sh.host.currentDir(self.allocator) catch try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(current_cwd);
        const previous_cwd = self.history_cwd;
        self.history_cwd = current_cwd;
        self.command_history.current_cwd = current_cwd;
        if (previous_cwd.len != 0) self.allocator.free(previous_cwd);
    }

    fn clearHistoryCurrentDirectory(self: *InteractiveSession) void {
        if (self.history_cwd.len != 0) self.allocator.free(self.history_cwd);
        self.history_cwd = "";
        self.command_history.current_cwd = "";
    }

    fn reportTerminalLocation(self: *InteractiveSession, terminal: *editor.driver.TerminalSession) !void {
        const cwd = try self.currentDirectoryForReporting();
        defer self.allocator.free(cwd);
        try terminal.reportCurrentDirectory(cwd, self.command_history.hostname);
        try self.reportWindowTitle(terminal, cwd);
    }

    fn reportWindowTitle(self: *InteractiveSession, terminal: *editor.driver.TerminalSession, cwd: []const u8) !void {
        const title = try extensions.rush.formatPromptPwdForShell(self.allocator, self.sh, cwd, .{ .dir_length = 1 });
        defer self.allocator.free(title);
        try terminal.reportWindowTitle(title);
    }

    fn currentDirectoryForReporting(self: *InteractiveSession) ![]const u8 {
        if (self.sh.state.getVariable("PWD")) |variable| {
            if (variable.value.len != 0 and variable.value[0] == '/') return self.allocator.dupe(u8, variable.value);
        }
        return self.sh.host.currentDir(self.allocator);
    }

    fn renderPrompt(self: *InteractiveSession) ![]const u8 {
        const prompt_status = self.last_command_status;
        defer self.sh.state.last_status = prompt_status;

        var prepared = try self.events.runEvent(self.allocator, self.io, "prompt.prepare", &.{});
        defer prepared.deinit(self.allocator);
        if (prepared.exit_status) |status| {
            self.pending_event_exit_status = status;
            return prompt(self.allocator, self.sh);
        }
        return extensions.rush.renderPrompt(
            self.allocator,
            self.sh,
            prompt_status,
            self.last_command_duration_ms,
        );
    }

    fn renderTransientPrompt(self: *InteractiveSession) !?[]const u8 {
        const prompt_status = self.last_command_status;
        defer self.sh.state.last_status = prompt_status;

        return extensions.rush.renderTransientPrompt(
            self.allocator,
            self.sh,
            prompt_status,
            self.last_command_duration_ms,
        );
    }

    fn renderRightPrompt(self: *InteractiveSession) !?[]const u8 {
        const prompt_status = self.last_command_status;
        defer self.sh.state.last_status = prompt_status;

        return extensions.rush.renderRightPrompt(
            self.allocator,
            self.sh,
            prompt_status,
            self.last_command_duration_ms,
        );
    }

    fn dispatchPromptAsyncLifecycleEvents(self: *InteractiveSession, allocator: std.mem.Allocator) !bool {
        const events = self.sh.extensions.takePromptAsyncLifecycleEvents();
        for (0..events.start_count) |_| {
            var dispatched = try self.events.runEvent(allocator, self.io, "prompt.async.start", &.{ "prompt", "1" });
            defer dispatched.deinit(allocator);
            if (dispatched.exit_status) |status| pendingEventExit(self, status);
            if (dispatched.output.len != 0) try self.sh.host.writeAll(.stderr, dispatched.output);
        }
        for (0..events.end_count) |_| {
            var dispatched = try self.events.runEvent(allocator, self.io, "prompt.async.end", &.{ "prompt", "0" });
            defer dispatched.deinit(allocator);
            if (dispatched.exit_status) |status| pendingEventExit(self, status);
            if (dispatched.output.len != 0) try self.sh.host.writeAll(.stderr, dispatched.output);
        }
        return events.start_count != 0 or events.end_count != 0;
    }

    fn evaluateSubmittedLine(
        self: *InteractiveSession,
        terminal: *editor.driver.TerminalSession,
        line: []const u8,
    ) !?u8 {
        self.sh.state.last_status = self.last_command_status;
        try terminal.leaveEditorMode();

        const src: shell.source.Source = .{
            .id = self.source_id.*,
            .kind = .interactive,
            .name = "interactive",
            .text = line,
        };
        self.source_id.* +%= 1;

        const background_jobs_before = self.sh.state.background_jobs.items.len;
        const started_at = unixTimestamp(self.io);
        // Commit before evaluation so a terminal or process exit cannot lose
        // the command that was already submitted.
        const history_handle = self.history_service.startCommand(self.io, line, started_at) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // History remains best effort when persistent storage fails; a
            // broken history database must not prevent command execution.
            else => null,
        };
        const evaluated = self.sh.evalSource(src) catch |err| {
            self.sh.state.last_status = 2;
            self.last_command_status = 2;
            const duration_ms = @max(unixTimestamp(self.io) - started_at, 0) * 1000;
            self.last_command_duration_ms = duration_ms;
            // Consume suppression even when an earlier command ran before a
            // later parse/evaluation failure, so it cannot leak to the next line.
            // ziglint-ignore: Z026 intentional best-effort history update; the pre-execution row remains on failure
            self.history_service.completeCommand(history_handle, 2, duration_ms) catch {};
            // Parse errors already produced a positioned syntax diagnostic.
            if (!shell.parser.isParseError(err)) try self.sh.host.writeAll(.stderr, "rush: shell error\n");
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            terminal.finishSemanticCommand(2) catch {};
            try terminal.enterEditorMode();
            return null;
        };
        const duration_ms = @max(unixTimestamp(self.io) - started_at, 0) * 1000;
        self.last_command_duration_ms = duration_ms;
        // ziglint-ignore: Z026 intentional best-effort history update; the pre-execution row remains on failure
        self.history_service.completeCommand(history_handle, evaluated.status, duration_ms) catch {};
        self.last_command_status = evaluated.status;
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        terminal.finishSemanticCommand(evaluated.status) catch {};
        const job_event_output = try self.dispatchJobLifecycleEvents(
            self.allocator,
            background_jobs_before,
            self.sh.state.background_jobs.items.len,
        );
        defer self.allocator.free(job_event_output);
        if (job_event_output.len != 0) try self.sh.host.writeAll(.stderr, job_event_output);

        switch (evaluated.flow) {
            .exit => |status| return self.exit(status),
            else => {
                try terminal.enterEditorMode();
                return null;
            },
        }
    }

    fn reapBackgroundJobsAndDispatch(self: *InteractiveSession, allocator: std.mem.Allocator) ![]const u8 {
        const HostType = switch (@typeInfo(@TypeOf(self.sh.host))) {
            .pointer => |pointer| pointer.child,
            else => @TypeOf(self.sh.host),
        };
        if (!@hasDecl(HostType, "waitNonBlocking")) return allocator.dupe(u8, "");

        const background_jobs_before = self.sh.state.background_jobs.items.len;
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        var index: usize = 0;
        while (index < self.sh.state.background_jobs.items.len) {
            const job = &self.sh.state.background_jobs.items[index];
            var pid_index: usize = 0;
            while (pid_index < job.pids.items.len) {
                const pid = job.pids.items[pid_index];
                const waited = self.sh.host.waitNonBlocking(pid) catch {
                    pid_index += 1;
                    continue;
                };
                const status = waited orelse {
                    pid_index += 1;
                    continue;
                };
                const job_complete = job.pids.items.len == 1;
                if (job_complete and self.sh.state.options.notify) {
                    try appendBackgroundJobNotification(allocator, &output, job.*, status);
                }
                switch (status) {
                    .stopped => {
                        _ = self.sh.state.setBackgroundJobStatusByPid(pid, .stopped);
                        break;
                    },
                    else => {},
                }
                _ = self.sh.state.removeBackgroundPid(pid);
                if (job_complete) break;
            }
            if (index < self.sh.state.background_jobs.items.len and
                self.sh.state.background_jobs.items[index].pids.items.len != 0)
            {
                index += 1;
            }
        }

        const job_event_output = try self.dispatchJobLifecycleEvents(
            allocator,
            background_jobs_before,
            self.sh.state.background_jobs.items.len,
        );
        defer allocator.free(job_event_output);
        try output.appendSlice(allocator, job_event_output);
        return output.toOwnedSlice(allocator);
    }

    fn dispatchJobLifecycleEvents(
        self: *InteractiveSession,
        allocator: std.mem.Allocator,
        previous_count: usize,
        current_count: usize,
    ) ![]const u8 {
        if (previous_count == current_count) return allocator.dupe(u8, "");

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        const event_name = if (current_count > previous_count) "job.start" else "job.end";
        var count_buffer: [32]u8 = undefined;
        const active_count = try std.fmt.bufPrint(&count_buffer, "{d}", .{current_count});
        var dispatched = try self.events.runEvent(allocator, self.io, event_name, &.{ "job", active_count });
        defer dispatched.deinit(allocator);
        if (dispatched.exit_status) |status| pendingEventExit(self, status);
        try output.appendSlice(allocator, dispatched.output);
        return output.toOwnedSlice(allocator);
    }

    /// Fire events describing state established before the first prompt, so
    /// hooks registered during startup observe the initial directory instead
    /// of waiting for the first `cd`.
    fn dispatchStartupEvents(self: *InteractiveSession) !?u8 {
        const initial_pwd = self.currentDirectoryForReporting() catch return null;
        defer self.allocator.free(initial_pwd);

        // Suppress recursive dispatch if a startup hook itself changes
        // directory, matching onDirectoryChange.
        self.dispatching_directory_change = true;
        defer self.dispatching_directory_change = false;

        var dispatched = try self.events.runEvent(
            self.allocator,
            self.io,
            "directory.change",
            &.{ "", initial_pwd },
        );
        defer dispatched.deinit(self.allocator);
        if (dispatched.output.len != 0) {
            // ziglint-ignore: Z026 event output is best effort during startup dispatch
            self.sh.host.writeAll(.stderr, dispatched.output) catch {};
        }
        return dispatched.exit_status;
    }

    fn exitWithLastStatus(self: *InteractiveSession) u8 {
        return self.exit(self.last_command_status);
    }

    fn exit(self: *InteractiveSession, status: u8) u8 {
        return shell.eval.runExitTrap(self.sh, status) catch {
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            self.sh.host.writeAll(.stderr, "rush: shell error\n") catch {};
            return 2;
        };
    }
};

fn registerPromptAsyncFd(context: *anyopaque, fd: std.posix.fd_t) anyerror!void {
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    const terminal = session.terminal orelse return error.Unexpected;
    try terminal.addPromptAsyncFd(fd);
}

fn unregisterPromptAsyncFd(context: *anyopaque, fd: std.posix.fd_t) void {
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    const terminal = session.terminal orelse return;
    terminal.removePromptAsyncFd(fd);
}

fn pumpPromptAsync(context: *anyopaque) void {
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    session.sh.extensions.pumpPromptAsync();
}

fn onDirectoryChange(context: *anyopaque, old_pwd: []const u8, new_pwd: []const u8) void {
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    const terminal = session.terminal orelse return;

    // ziglint-ignore: Z026 best-effort terminal metadata; the next prompt reports it again
    terminal.reportCurrentDirectory(new_pwd, session.command_history.hostname) catch {};
    // ziglint-ignore: Z026 best-effort terminal metadata; the next prompt reports it again
    session.reportWindowTitle(terminal, new_pwd) catch {};

    if (session.dispatching_directory_change) return;
    session.dispatching_directory_change = true;
    defer session.dispatching_directory_change = false;

    var dispatched = session.events.runEvent(
        session.allocator,
        session.io,
        "directory.change",
        &.{ old_pwd, new_pwd },
    ) catch |err| {
        var message_buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "rush: directory.change event failed: {s}\n",
            .{@errorName(err)},
        ) catch "rush: directory.change event failed\n";
        // ziglint-ignore: Z026 event diagnostics are best effort during callback dispatch
        session.sh.host.writeAll(.stderr, message) catch {};
        return;
    };
    defer dispatched.deinit(session.allocator);
    if (dispatched.exit_status) |status| pendingEventExit(session, status);
    if (dispatched.output.len != 0) {
        // ziglint-ignore: Z026 event output is best effort during callback dispatch
        session.sh.host.writeAll(.stderr, dispatched.output) catch {};
    }
}

// ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
fn runInteractiveHooks(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) !editor.driver.HookResult {
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    const job_output = try session.reapBackgroundJobsAndDispatch(allocator);
    defer allocator.free(job_output);
    try output.appendSlice(allocator, job_output);

    const prompt_async_event_ran = try session.dispatchPromptAsyncLifecycleEvents(allocator);
    var dispatched = try session.events.runDueTimers(allocator, io);
    defer dispatched.deinit(allocator);
    if (dispatched.exit_status) |status| pendingEventExit(session, status);
    try output.appendSlice(allocator, dispatched.output);
    return .{
        .output = try output.toOwnedSlice(allocator),
        .refresh_prompt = prompt_async_event_ran or dispatched.ran_count != 0 or dispatched.output.len != 0,
        .stop = dispatched.exit_status != null,
    };
}

// ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
fn nextInteractiveHookIntervalMs(context: *anyopaque, io: std.Io) !?u64 {
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    return session.events.nextTimerDelayMs(io);
}

// ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
fn refreshInteractivePrompt(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    _ = io;
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    _ = try session.dispatchPromptAsyncLifecycleEvents(allocator);
    return session.renderPrompt() catch try prompt(allocator, session.sh);
}

// ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
fn refreshInteractiveRightPrompt(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    _ = allocator;
    _ = io;
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    return try session.renderRightPrompt();
}

// ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
fn refreshInteractiveTransientPrompt(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    _ = allocator;
    _ = io;
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    return try session.renderTransientPrompt();
}

fn diagnoseInteractiveInput(
    context: *anyopaque,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    allocator: std.mem.Allocator,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    io: std.Io,
    text: []const u8,
) !?editor.render.DiagnosticRender {
    _ = io;
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    return analyzeInteractiveInput(allocator, session.sh, &session.command_cache, text);
}

fn analyzeInteractiveInput(
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
    tokens: []const shell.Token,
) !void {
    var tracker: shell.token.CommandPositionTracker = .{};
    for (tokens) |tok| {
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
    return sh.host.existsZ(command_z);
}

/// Caches exact external-command lookups instead of eagerly enumerating PATH,
/// which can block the first prompt when PATH contains slow mounted filesystems.
const PathCommandCache = struct {
    path_key: []const u8 = "",
    cwd_key: []const u8 = "",
    commands: std.StringHashMapUnmanaged(bool) = .empty,

    // ziglint-ignore: Z030 deinit intentionally leaves reusable/test-local state shape
    fn deinit(self: *PathCommandCache, allocator: std.mem.Allocator) void {
        allocator.free(self.path_key);
        allocator.free(self.cwd_key);
        var iterator = self.commands.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        self.commands.deinit(allocator);
        self.* = .{};
    }

    fn refresh(self: *PathCommandCache, allocator: std.mem.Allocator, sh: anytype) !void {
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

fn pendingEventExit(session: *InteractiveSession, status: u8) void {
    session.pending_event_exit_status = status;
}

fn appendBackgroundJobNotification(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    job: shell.state.BackgroundJob,
    status: host.WaitStatus,
) !void {
    const label = switch (status) {
        .exited => |code| if (code == 0) "Done" else "Exit",
        .signaled => "Terminated",
        .stopped => "Stopped",
        .continued => "Continued",
    };
    switch (status) {
        .exited => |code| if (code == 0) {
            try appendPrint(allocator, output, "[{d}] {s} {s}\n", .{ job.id, label, job.command });
        } else {
            try appendPrint(allocator, output, "[{d}] {s} {d} {s}\n", .{ job.id, label, code, job.command });
        },
        .signaled => |signal| try appendPrint(
            allocator,
            output,
            "[{d}] {s} {d} {s}\n",
            .{ job.id, label, signal, job.command },
        ),
        .stopped => |signal| try appendPrint(
            allocator,
            output,
            "[{d}] {s} {d} {s}\n",
            .{ job.id, label, signal, job.command },
        ),
        .continued => try appendPrint(allocator, output, "[{d}] {s} {s}\n", .{ job.id, label, job.command }),
    }
}

fn appendPrint(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const bytes = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(bytes);
    try output.appendSlice(allocator, bytes);
}

fn autoloadRushFunction(sh: *RushShell, name: []const u8) !bool {
    return function_autoload.autoload(sh, name);
}

/// Runs a non-interactive shell reading commands from standard input.
///
/// Lines accumulate until they form complete commands, so multi-line
/// constructs and here-documents work across lines while commands still
/// execute as soon as they are complete, sharing standard input with the
/// commands they run (POSIX sh -s semantics). Per POSIX 2.8.1 the shell
/// exits on a syntax error or fatal shell error.
fn runStdinScript(
    allocator: std.mem.Allocator,
    sh: *RushShell,
    source_id: *shell.source.SourceId,
) !u8 {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    // Diagnostics number lines from the start of the stream even though
    // each complete command evaluates as its own source.
    var consumed_lines: usize = 0;
    defer sh.state.diagnostic_line_offset = 0;

    while (true) {
        const line = try readStdinLineWithNewline(allocator, sh) orelse break;
        defer allocator.free(line);
        try pending.appendSlice(allocator, line);
        if (endsWithLineContinuation(pending.items)) continue;
        if (!stdinCommandsComplete(sh, pending.items)) continue;
        sh.state.diagnostic_line_offset = consumed_lines;
        consumed_lines += std.mem.count(u8, pending.items, "\n");
        if (try evalStdinPending(sh, source_id, &pending)) |status| return status;
    }
    if (pending.items.len != 0) {
        sh.state.diagnostic_line_offset = consumed_lines;
        if (try evalStdinPending(sh, source_id, &pending)) |status| return status;
    }
    return shell.eval.runExitTrap(sh, sh.state.last_status) catch {
        try sh.host.writeAll(.stderr, "rush: shell error\n");
        return 2;
    };
}

/// Evaluates the pending buffer; returns an exit status when the shell
/// must stop reading standard input.
fn evalStdinPending(
    sh: *RushShell,
    source_id: *shell.source.SourceId,
    pending: *std.ArrayList(u8),
) !?u8 {
    const src: shell.source.Source = .{
        .id = source_id.*,
        .kind = .standard_input,
        .name = "stdin",
        .text = pending.items,
    };
    source_id.* +%= 1;

    const evaluated = sh.evalSource(src) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // Parse errors already produced a positioned syntax diagnostic.
            if (!shell.parser.isParseError(err)) try sh.host.writeAll(.stderr, "rush: shell error\n");
            return 2;
        },
    };
    pending.clearRetainingCapacity();
    switch (evaluated.flow) {
        .exit, .fatal => return shell.eval.runExitTrap(sh, evaluated.status) catch {
            try sh.host.writeAll(.stderr, "rush: shell error\n");
            return 2;
        },
        else => return null,
    }
}

/// Checks whether the accumulated text parses as complete commands, so
/// evaluation never runs a prefix of a construct that later lines finish.
/// Alias values that open compound commands cannot be detected here; such
/// constructs must not span physical lines when piped into the shell.
fn stdinCommandsComplete(sh: *RushShell, text: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(sh.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: shell.source.Source = .{ .id = 0, .kind = .standard_input, .name = "stdin", .text = text };
    const tokens = shell.lexer.lex(allocator, src) catch return true;
    var incremental = shell.parser.Incremental.initWithOptions(allocator, src, tokens, sh.state, .{
        .require_complete_here_docs = true,
    });
    while (true) {
        const maybe_program = incremental.next() catch |err| return switch (err) {
            error.IncompleteHereDoc,
            error.UnclosedQuote,
            error.UnclosedCommandSubstitution,
            => false,
            error.ExpectedCommand,
            error.ExpectedRedirectionTarget,
            error.UnexpectedToken,
            => !incremental.atEndOfInput(),
            error.InvalidParameterExpansion, error.OutOfMemory => true,
        };
        if (maybe_program == null) return true;
    }
}

/// True when the text ends with an unquoted <backslash><newline>, which the
/// lexer removes as line continuation; the next line must be read first.
fn endsWithLineContinuation(text: []const u8) bool {
    if (text.len < 2 or text[text.len - 1] != '\n') return false;
    var backslashes: usize = 0;
    var index = text.len - 1;
    while (index > 0 and text[index - 1] == '\\') : (index -= 1) backslashes += 1;
    return backslashes % 2 == 1;
}

test "line continuation detection counts trailing backslashes" {
    try std.testing.expect(endsWithLineContinuation("echo a\\\n"));
    try std.testing.expect(!endsWithLineContinuation("echo a\\\\\n"));
    try std.testing.expect(endsWithLineContinuation("echo a\\\\\\\n"));
    try std.testing.expect(!endsWithLineContinuation("echo a\n"));
    try std.testing.expect(!endsWithLineContinuation("echo a"));
    try std.testing.expect(!endsWithLineContinuation("\n"));
}

fn readStdinLineWithNewline(allocator: std.mem.Allocator, sh: *RushShell) !?[]const u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        const read_len = try sh.host.read(.stdin, &byte);
        if (read_len == 0) {
            if (line.items.len == 0) return null;
            return try line.toOwnedSlice(allocator);
        }
        try line.append(allocator, byte[0]);
        if (byte[0] == '\n') return try line.toOwnedSlice(allocator);
    }
}

fn runPromptedStdin(
    allocator: std.mem.Allocator,
    sh: *RushShell,
    source_id: *shell.source.SourceId,
) !u8 {
    while (true) {
        const prompt_text = try promptedStdinPrompt(allocator, sh);
        defer allocator.free(prompt_text);
        try sh.host.writeAll(.stderr, prompt_text);

        const line = try readInteractiveStdinLine(allocator, sh) orelse {
            return shell.eval.runExitTrap(sh, sh.state.last_status) catch {
                try sh.host.writeAll(.stderr, "rush: shell error\n");
                return 2;
            };
        };
        defer allocator.free(line);

        const src: shell.source.Source = .{
            .id = source_id.*,
            .kind = .interactive,
            .name = "interactive",
            .text = line,
        };
        source_id.* +%= 1;

        const evaluated = sh.evalSource(src) catch |err| {
            sh.state.last_status = 2;
            // Parse errors already produced a positioned syntax diagnostic.
            if (!shell.parser.isParseError(err)) try sh.host.writeAll(.stderr, "rush: shell error\n");
            continue;
        };
        switch (evaluated.flow) {
            .exit => |status| return shell.eval.runExitTrap(sh, status) catch {
                try sh.host.writeAll(.stderr, "rush: shell error\n");
                return 2;
            },
            else => {},
        }
    }
}

fn readInteractiveStdinLine(allocator: std.mem.Allocator, sh: *RushShell) !?[]const u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        const read_len = try sh.host.read(.stdin, &byte);
        if (read_len == 0) {
            if (line.items.len == 0) return null;
            return try line.toOwnedSlice(allocator);
        }
        if (byte[0] == '\n') return try line.toOwnedSlice(allocator);
        try line.append(allocator, byte[0]);
    }
}

fn prompt(allocator: std.mem.Allocator, sh: *RushShell) ![]const u8 {
    if (sh.state.getVariable("PS1")) |variable| return allocator.dupe(u8, variable.value);
    if (startup.envValue(sh.env, "PS1")) |value| return allocator.dupe(u8, value);
    return allocator.dupe(u8, "rush> ");
}

fn promptedStdinPrompt(allocator: std.mem.Allocator, sh: *RushShell) ![]const u8 {
    if (sh.state.getVariable("PS1")) |variable| return allocator.dupe(u8, variable.value);
    if (startup.envValue(sh.env, "PS1")) |value| return allocator.dupe(u8, value);
    return allocator.dupe(u8, "$ ");
}

fn expandRushAbbreviation(
    context: *anyopaque,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    allocator: std.mem.Allocator,
    source: []const u8,
    cursor: usize,
    append_space: bool,
) !?editor.completion.Edit {
    const sh: *RushShell = @ptrCast(@alignCast(context));
    return extensions.rush.expandAbbreviation(&sh.extensions, allocator, source, cursor, append_space);
}

fn unixTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

test "interactive history cwd remains valid after prompt read" {
    const path = "rush-interactive-history-cwd-lifetime-test.sqlite";
    const cleanup = struct {
        fn deleteIfFound(file_path: []const u8) !void {
            std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };
        }
    };

    try cleanup.deleteIfFound(path);
    try cleanup.deleteIfFound(path ++ "-wal");
    try cleanup.deleteIfFound(path ++ "-shm");
    defer cleanup.deleteIfFound(path) catch |err| std.debug.panic("failed to delete test db: {}", .{err});
    defer cleanup.deleteIfFound(path ++ "-wal") catch |err| std.debug.panic("failed to delete test db wal: {}", .{err});
    defer cleanup.deleteIfFound(path ++ "-shm") catch |err| std.debug.panic("failed to delete test db shm: {}", .{err});

    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    var command_history = try history.History.init(std.testing.allocator);
    defer command_history.deinit();
    try command_history.load(std.testing.io, path);
    command_history.session_id = "test-session";
    var history_service = history.InteractiveHistoryService.init(&command_history);
    var source_id: shell.source.SourceId = 1;
    var session: InteractiveSession = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .sh = &sh,
        .source_id = &source_id,
        .command_history = &command_history,
        .history_service = &history_service,
        .events = .{ .sh = &sh },
    };
    defer session.clearHistoryCurrentDirectory();

    try session.refreshHistoryCurrentDirectory();
    try history_service.addCommand(std.testing.io, "echo previous", 0, 10, 1);

    const view = history_service.lineEditorView(std.testing.io);
    const entry = (try view.previous.?(
        view.context.?,
        std.testing.allocator,
        "",
        null,
    )) orelse return error.TestExpectedEqual;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo previous", entry.text);
}

test "interactive startup dispatch fires directory.change with empty old directory" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text = "on_startup_dir(){ startup_old=\"[$1]\"; startup_new=$2; }",
    };
    const defined = try sh.evalSource(src);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 0), defined.status);
    try sh.extensions.putEventHandler("directory.change", "startup", "on_startup_dir", 0, null);

    var command_history = try history.History.init(std.testing.allocator);
    defer command_history.deinit();
    var history_service = history.InteractiveHistoryService.init(&command_history);
    var source_id: shell.source.SourceId = 2;
    var session: InteractiveSession = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .sh = &sh,
        .source_id = &source_id,
        .command_history = &command_history,
        .history_service = &history_service,
        .events = .{ .sh = &sh },
    };

    const status = try session.dispatchStartupEvents();
    try std.testing.expectEqual(@as(?u8, null), status);

    const old_arg = sh.state.getVariable("startup_old") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("[]", old_arg.value);
    const new_arg = sh.state.getVariable("startup_new") orelse return error.TestExpectedEqual;
    try std.testing.expect(new_arg.value.len != 0);
    try std.testing.expect(new_arg.value[0] == '/');
}

test "interactive prompt render uses last command status when shell status drifted" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text =
        \\rush_prompt(){
        \\  if test "$?" = 0; then
        \\    prompt text OK
        \\  else
        \\    prompt text BAD
        \\  fi
        \\}
        ,
    };
    const defined = try sh.evalSource(src);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 0), defined.status);

    var command_history = try history.History.init(std.testing.allocator);
    defer command_history.deinit();
    var history_service = history.InteractiveHistoryService.init(&command_history);
    var source_id: shell.source.SourceId = 2;
    var session: InteractiveSession = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .sh = &sh,
        .source_id = &source_id,
        .command_history = &command_history,
        .history_service = &history_service,
        .events = .{ .sh = &sh },
        .last_command_status = 1,
    };

    sh.state.last_status = 0;
    const rendered = try session.renderPrompt();
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("BAD", rendered);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 1), sh.state.last_status);
}

test "interactive transient prompt uses prompt helpers and last command status" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text =
        \\rush_prompt_transient(){
        \\  if test "$?" = 0; then
        \\    prompt text OK
        \\  else
        \\    prompt text BAD
        \\  fi
        \\}
        ,
    };
    const defined = try sh.evalSource(src);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 0), defined.status);

    var command_history = try history.History.init(std.testing.allocator);
    defer command_history.deinit();
    var history_service = history.InteractiveHistoryService.init(&command_history);
    var source_id: shell.source.SourceId = 2;
    var session: InteractiveSession = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .sh = &sh,
        .source_id = &source_id,
        .command_history = &command_history,
        .history_service = &history_service,
        .events = .{ .sh = &sh },
        .last_command_status = 1,
    };

    sh.state.last_status = 0;
    const rendered = (try session.renderTransientPrompt()) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("BAD", rendered);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 1), sh.state.last_status);
}

test "interactive right prompt uses prompt helpers and last command status" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text =
        \\rush_prompt_right(){
        \\  if test "$?" = 0; then
        \\    prompt text OK-RIGHT
        \\  else
        \\    prompt text BAD-RIGHT
        \\  fi
        \\}
        ,
    };
    const defined = try sh.evalSource(src);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 0), defined.status);

    var command_history = try history.History.init(std.testing.allocator);
    defer command_history.deinit();
    var history_service = history.InteractiveHistoryService.init(&command_history);
    var source_id: shell.source.SourceId = 2;
    var session: InteractiveSession = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .sh = &sh,
        .source_id = &source_id,
        .command_history = &command_history,
        .history_service = &history_service,
        .events = .{ .sh = &sh },
        .last_command_status = 1,
    };

    sh.state.last_status = 0;
    const rendered = (try session.renderRightPrompt()) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("BAD-RIGHT", rendered);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 1), sh.state.last_status);
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
    const analyzed = (try analyzeInteractiveInput(std.testing.allocator, &sh, &command_cache, text)).?;
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

test "interactive input analysis styles assignment operator and expanded value separately" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    var command_cache: PathCommandCache = .{};
    defer command_cache.deinit(std.testing.allocator);

    const text = "FOO=$HOME/foo";
    const analyzed = (try analyzeInteractiveInput(std.testing.allocator, &sh, &command_cache, text)).?;
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
    const analyzed = (try analyzeInteractiveInput(std.testing.allocator, &sh, &command_cache, text)).?;
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
    const analyzed = (try analyzeInteractiveInput(std.testing.allocator, &sh, &command_cache, text)).?;
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
    const analyzed = (try analyzeInteractiveInput(std.testing.allocator, &sh, &command_cache, text)).?;
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

test "interactive terminal teardown restores process group before closing tty" {
    const Event = enum { restore, deinit };
    const FakeSession = struct {
        tty_closed: bool = false,
        events: std.ArrayList(Event) = .empty,

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        fn restoreTerminalProcessGroup(self: *@This()) void {
            std.testing.expect(!self.tty_closed) catch unreachable;
            self.events.append(std.testing.allocator, .restore) catch unreachable;
        }
    };
    const FakeTerminal = struct {
        session: *FakeSession,

        // ziglint-ignore: Z020 Z030 test-local helper uses @This(); avoid non-semantic refactor
        fn deinit(self: *@This()) void {
            self.session.tty_closed = true;
            self.session.events.append(std.testing.allocator, .deinit) catch unreachable;
        }
    };

    var session: FakeSession = .{};
    defer session.events.deinit(std.testing.allocator);
    var terminal: FakeTerminal = .{ .session = &session };

    deinitTerminalAfterRestore(&session, &terminal);

    try std.testing.expect(session.tty_closed);
    try std.testing.expectEqualSlices(Event, &.{ .restore, .deinit }, session.events.items);
}

test {
    std.testing.refAllDecls(@This());
}
