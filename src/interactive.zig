//! Interactive Rush session orchestration.

const std = @import("std");

const completion = @import("completion.zig");
const editor = @import("editor.zig");
const extensions = @import("extensions.zig");
const function_autoload = @import("function_autoload.zig");
const history = @import("history.zig");
const host = @import("host.zig");
const interactive_event = @import("interactive/event.zig");
const input_analysis = @import("interactive/input_analysis.zig");
const interactive_style = @import("interactive/style.zig");
const startup = @import("interactive/startup.zig");
const shell = @import("shell.zig");

const RushShell = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry);

const BashPromptCommands = union(enum) {
    scalar: []const u8,
    array: []const shell.state.ArrayElement,
};

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
    state_options.interactive = interactive;
    if (interactive) state_options.history = true;

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
    sh.state.prompt_history_number = history_service.nextCommandNumber() catch 1;

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
    if (!stdin_terminal) {
        session.bash_prompt_mode = .parameter;
        return session.runPromptedStdin();
    }
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
    command_cache: input_analysis.PathCommandCache = .{},
    history_cwd: []const u8 = "",
    // Keep PS1 stable for one editor cycle. Async redraws must not rerun
    // command substitutions while the user is editing the same line.
    bash_prompt_cache: ?[]const u8 = null,
    bash_prompt_active: ?bool = null,
    bash_prompt_mode: shell.prompt.DecodeMode = .editor,

    fn runTerminal(self: *InteractiveSession) !u8 {
        var terminal = editor.driver.TerminalSession.init(self.allocator, self.io) catch {
            try self.sh.host.writeAll(.stderr, "rush: cannot initialize terminal\n");
            return 2;
        };
        defer self.clearHistoryCurrentDirectory();
        defer self.clearBashPromptCache();
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

    fn runPromptedStdin(self: *InteractiveSession) !u8 {
        defer self.clearBashPromptCache();

        while (true) {
            self.clearBashPromptCache();
            if (try self.runBashPromptCommand()) |status| return self.exit(status);

            const prompt_text = self.renderPrompt() catch try promptedStdinPrompt(self.allocator, self.sh);
            defer self.allocator.free(prompt_text);
            try self.sh.host.writeAll(.stderr, prompt_text);

            const line = try readInteractiveStdinLine(self.allocator, self.sh) orelse return self.exitWithLastStatus();
            defer self.allocator.free(line);

            const src: shell.source.Source = .{
                .id = self.source_id.*,
                .kind = .interactive,
                .name = "interactive",
                .text = line,
            };
            self.source_id.* +%= 1;

            const started_at = unixTimestamp(self.io);
            const history_handle = self.startHistoryCommand(line, started_at) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            const evaluated = self.sh.evalSource(src) catch |err| {
                self.last_command_status = 2;
                self.sh.state.last_status = 2;
                // ziglint-ignore: Z026 history updates remain best effort when evaluation fails
                self.history_service.completeCommand(history_handle, 2, 0) catch {};
                if (!shell.parser.isParseError(err)) try self.sh.host.writeAll(.stderr, "rush: shell error\n");
                continue;
            };
            const duration_ms = @max(unixTimestamp(self.io) - started_at, 0) * 1000;
            // ziglint-ignore: Z026 history updates remain best effort after command completion
            self.history_service.completeCommand(history_handle, evaluated.status, duration_ms) catch {};
            self.last_command_status = evaluated.status;
            switch (evaluated.flow) {
                .exit => |status| return self.exit(status),
                else => {},
            }
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

        self.clearBashPromptCache();
        if (try self.runBashPromptCommand()) |status| {
            self.pending_event_exit_status = status;
            return .interrupted;
        }

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

        if (self.usesBashPrompt()) {
            self.sh.state.last_status = prompt_status;
            return self.renderBashPrompt();
        }
        self.sh.state.last_status = prompt_status;

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

    fn usesBashPrompt(self: *InteractiveSession) bool {
        if (self.bash_prompt_active) |active| return active;
        const active = self.selectsBashPrompt(self.bashPromptCommands() != null);
        self.bash_prompt_active = active;
        return active;
    }

    /// PROMPT_COMMAND selects Bash compatibility first. Otherwise Rush's
    /// native prompt function takes precedence over an explicit PS1.
    fn selectsBashPrompt(self: InteractiveSession, has_prompt_command: bool) bool {
        if (has_prompt_command) return true;
        if (self.sh.state.getFunction("rush_prompt") != null) return false;
        return self.sh.state.getVariable("PS1") != null or startup.envValue(self.sh.env, "PS1") != null;
    }

    fn bashPromptCommands(self: InteractiveSession) ?BashPromptCommands {
        if (self.sh.state.getVariable("PROMPT_COMMAND")) |variable| return .{ .scalar = variable.value };
        if (self.sh.state.getArray("PROMPT_COMMAND")) |array| return .{ .array = array.elements };
        const value = startup.envValue(self.sh.env, "PROMPT_COMMAND") orelse return null;
        return .{ .scalar = value };
    }

    fn clearBashPromptCache(self: *InteractiveSession) void {
        if (self.bash_prompt_cache) |cached| self.allocator.free(cached);
        self.bash_prompt_cache = null;
        self.bash_prompt_active = null;
    }

    fn renderBashPrompt(self: *InteractiveSession) ![]const u8 {
        if (self.bash_prompt_cache) |cached| return self.allocator.dupe(u8, cached);

        const scratch = try self.sh.beginScratchScope();
        defer scratch.end();
        const value = if (self.sh.state.getVariable("PS1")) |variable|
            variable.value
        else
            startup.envValue(self.sh.env, "PS1") orelse "rush> ";
        const expanded = try shell.eval.expandPromptValue(self.sh, value, .{}, self.bash_prompt_mode);
        const cached = try self.allocator.dupe(u8, expanded);
        errdefer self.allocator.free(cached);
        const rendered = try self.allocator.dupe(u8, cached);
        self.bash_prompt_cache = cached;
        return rendered;
    }

    fn runBashPromptCommand(self: *InteractiveSession) !?u8 {
        const prompt_commands = self.bashPromptCommands();
        const active = self.selectsBashPrompt(prompt_commands != null);
        self.bash_prompt_active = active;
        if (!active) return null;

        self.sh.state.last_status = self.last_command_status;
        const commands = prompt_commands orelse return null;
        const exit_status = switch (commands) {
            .scalar => |value| run: {
                const command = try self.allocator.dupe(u8, value);
                defer self.allocator.free(command);
                break :run try self.runBashPromptCommandText(command);
            },
            .array => |elements| run: {
                // A hook may replace or unset PROMPT_COMMAND. Keep this prompt
                // cycle's ordered elements alive across evaluator resets.
                const command_snapshot = try snapshotPromptCommands(self.allocator, elements);
                defer freePromptCommands(self.allocator, command_snapshot);
                for (command_snapshot) |command| {
                    if (try self.runBashPromptCommandText(command)) |status| break :run status;
                }
                break :run null;
            },
        };
        return exit_status;
    }

    fn runBashPromptCommandText(self: *InteractiveSession, command: []const u8) !?u8 {
        if (command.len == 0) return null;
        const src: shell.source.Source = .{
            .id = 0,
            .kind = .command_string,
            .name = "PROMPT_COMMAND",
            .text = command,
        };
        const evaluated = self.sh.evalSourceNested(src) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (!shell.parser.isParseError(err)) {
                    // ziglint-ignore: Z026 preserve the original prompt-command failure when diagnostics cannot write
                    self.sh.host.writeAll(.stderr, "rush: PROMPT_COMMAND error\n") catch {};
                }
                self.sh.state.last_status = 2;
                return null;
            },
        };
        return if (evaluated.flow == .exit) evaluated.status else null;
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
        const history_handle = self.startHistoryCommand(line, started_at) catch |err| switch (err) {
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

    fn startHistoryCommand(
        self: *InteractiveSession,
        line: []const u8,
        started_at: i64,
    ) !?history.History.CommandHandle {
        if (!self.sh.state.options.history) return null;
        const handle = try self.history_service.startCommand(self.io, line, started_at);
        if (handle) |number| self.sh.state.prompt_history_number = number +| 1;
        return handle;
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

fn snapshotPromptCommands(
    allocator: std.mem.Allocator,
    elements: []const shell.state.ArrayElement,
) ![][]const u8 {
    const commands = try allocator.alloc([]const u8, elements.len);
    errdefer allocator.free(commands);
    var initialized: usize = 0;
    errdefer for (commands[0..initialized]) |command| allocator.free(command);
    for (elements, 0..) |element, index| {
        commands[index] = try allocator.dupe(u8, element.value);
        initialized += 1;
    }
    return commands;
}

fn freePromptCommands(allocator: std.mem.Allocator, commands: [][]const u8) void {
    for (commands) |command| allocator.free(command);
    allocator.free(commands);
}

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
    return input_analysis.analyze(allocator, session.sh, &session.command_cache, text);
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

test "PROMPT_COMMAND selects and prepares the Bash PS1 prompt" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text =
        \\prepare_prompt() { PS1="bash:$?"; }
        \\rush_prompt() { prompt text native; }
        \\PROMPT_COMMAND=(prepare_prompt)
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
        .last_command_status = 7,
    };
    defer session.clearBashPromptCache();

    try std.testing.expectEqual(@as(?u8, null), try session.runBashPromptCommand());
    const rendered = try session.renderPrompt();
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("bash:7", rendered);
}

test "Bash prompt expansion uses the preceding command status after PROMPT_COMMAND" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text =
        \\PROMPT_COMMAND=false
        \\PS1='$?'
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
        .last_command_status = 7,
    };
    defer session.clearBashPromptCache();

    try std.testing.expectEqual(@as(?u8, null), try session.runBashPromptCommand());
    sh.state.last_status = 42;
    const rendered = try session.renderPrompt();
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("7", rendered);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 7), sh.state.last_status);
}

test "environment PROMPT_COMMAND selects and prepares the Bash prompt" {
    const env = [_][:0]const u8{
        "PS1=initial:$?",
        "PROMPT_COMMAND=PS1=environment:$?",
    };
    const env_ptrs = [_][*:0]const u8{ env[0].ptr, env[1].ptr };
    var sh = RushShell.init(std.testing.allocator, .{}, .{ .env = &env_ptrs });
    defer sh.deinit();

    var command_history = try history.History.init(std.testing.allocator);
    defer command_history.deinit();
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
        .last_command_status = 7,
    };
    defer session.clearBashPromptCache();

    try std.testing.expectEqual(@as(?u8, null), try session.runBashPromptCommand());
    const rendered = try session.renderPrompt();
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("environment:7", rendered);
    try std.testing.expectEqual(@as(shell.result.ExitStatus, 7), sh.state.last_status);
}

test "explicit PS1 selects Bash prompt expansion without PROMPT_COMMAND" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text =
        \\HOME=/Users/tester
        \\PWD=/Users/tester/project
        \\PS1='\w'
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
    };
    defer session.clearBashPromptCache();

    const rendered = try session.renderPrompt();
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("~/project", rendered);
}

test "environment PS1 selects Bash prompt when no native prompt function exists" {
    const env = [_][:0]const u8{"PS1=environment> "};
    const env_ptrs = [_][*:0]const u8{env[0].ptr};
    var sh = RushShell.init(std.testing.allocator, .{}, .{ .env = &env_ptrs });
    defer sh.deinit();

    var command_history = try history.History.init(std.testing.allocator);
    defer command_history.deinit();
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
    defer session.clearBashPromptCache();

    const rendered = try session.renderPrompt();
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("environment> ", rendered);
}

test "native prompt function takes precedence over PS1 without PROMPT_COMMAND" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text =
        \\PS1='bash> '
        \\rush_prompt() { prompt text NATIVE; }
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
    };

    const rendered = try session.renderPrompt();
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("NATIVE", rendered);
}

test "Bash primary prompt preserves Rush right and transient hooks" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text =
        \\PS1='bash> '
        \\rush_prompt_right() { prompt text RIGHT; }
        \\rush_prompt_transient() { prompt text TRANSIENT; }
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
    };

    const right = (try session.renderRightPrompt()) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(right);
    const transient = (try session.renderTransientPrompt()) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(transient);
    try std.testing.expectEqualStrings("RIGHT", right);
    try std.testing.expectEqualStrings("TRANSIENT", transient);
}

test "history shell option controls interactive command recording" {
    var sh = RushShell.init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    var command_history = try history.History.init(std.testing.allocator);
    defer command_history.deinit();
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

    try std.testing.expectEqual(
        @as(?history.History.CommandHandle, null),
        try session.startHistoryCommand("hidden", 1),
    );
    try std.testing.expect((try command_history.latestCommand(std.testing.allocator, "")) == null);

    sh.state.options.history = true;
    const handle = (try session.startHistoryCommand("shown", 2)) orelse return error.TestExpectedEqual;
    try history_service.completeCommand(handle, 0, 1);
    const latest = (try command_history.latestCommand(std.testing.allocator, "")) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(latest);
    try std.testing.expectEqualStrings("shown", latest);
    try std.testing.expectEqual(handle + 1, sh.state.prompt_history_number);
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
