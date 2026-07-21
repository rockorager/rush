//! Direct evaluator for the rewritten shell core.

const std = @import("std");
const zig_builtin = @import("builtin");

const ast = @import("ast.zig");
const ast_copy = @import("ast_copy.zig");
const builtin = @import("builtin.zig");
const editor_render = @import("../editor/render.zig");
const history_mod = @import("../history.zig");
const host_mod = @import("../host.zig");
const lexer = @import("lexer.zig");
const pattern_mod = @import("pattern.zig");
const parser = @import("parser.zig");
const prompt_mod = @import("prompt.zig");
const result = @import("result.zig");
const source_mod = @import("source.zig");
const state_mod = @import("state.zig");
const token_mod = @import("token.zig");

pub const EvalError = anyerror;
const CommandLookupMode = enum { none, terse, verbose };
const command_suggestion_limit = 2;
const command_suggestion_max_distance = 2;
const cd_suggestion_max_distance = 2;
const cd_suggestion_confirm_timeout_ms = 5 * 1000;
const job_control_signals = [_]u8{
    builtin.signalNumber("TSTP").?,
    builtin.signalNumber("TTIN").?,
    builtin.signalNumber("TTOU").?,
};

fn validateAst(value: anytype) void {
    if (zig_builtin.mode != .ReleaseFast and zig_builtin.mode != .ReleaseSmall) value.validate();
}

pub fn evalProgram(comptime Host: type, shell: anytype, program: ast.Program) EvalError!result.EvalResult {
    _ = Host;
    validateAst(program);
    return evalList(shell, program.body);
}

pub fn runExitTrap(shell: anytype, status: result.ExitStatus) EvalError!result.ExitStatus {
    const action = shell.state.exit_trap orelse return status;
    if (shell.state.running_exit_trap) return status;

    shell.state.running_exit_trap = true;
    defer shell.state.running_exit_trap = false;

    shell.state.last_status = status;
    const src: source_mod.Source = .{ .id = 0, .kind = .command_string, .name = "trap", .text = action };
    const evaluated = try shell.evalSourceNested(src);
    if (evaluated.flow == .exit) return evaluated.status;
    const pending = try runPendingTrapCheckpoint(shell);
    return if (pending.flow != .normal) pending.status else status;
}

fn runPendingTrapCheckpoint(shell: anytype) EvalError!result.EvalResult {
    if (shell.state.running_signal_trap) return .{};
    // Fast path for the common trap-free shell: nothing can be queued and
    // nothing is pending, so skip the polling walk.
    if (shell.state.signal_traps.count() == 0 and shell.state.pending_traps.items.len == 0) return .{};
    try queuePolledSignalTraps(shell);
    const name = shell.state.popPendingTrap() orelse return .{};
    const action = shell.state.getSignalTrap(name) orelse return .{};

    shell.state.running_signal_trap = true;
    defer shell.state.running_signal_trap = false;

    const saved_status = shell.state.last_status;
    const src: source_mod.Source = .{ .id = 0, .kind = .command_string, .name = "trap", .text = action };
    const evaluated = try shell.evalSourceNested(src);
    shell.state.last_status = saved_status;
    if (evaluated.flow != .normal) return evaluated;
    return .{ .status = saved_status };
}

fn queuePolledSignalTraps(shell: anytype) !void {
    var iterator = shell.state.signal_traps.iterator();
    while (iterator.next()) |entry| {
        const number = builtin.signalNumber(entry.key_ptr.*) orelse continue;
        if (shell.host.consumePendingSignal(number)) try shell.state.queueTrap(entry.key_ptr.*);
    }
}

fn evalList(shell: anytype, list: ast.List) EvalError!result.EvalResult {
    var status: result.ExitStatus = 0;
    for (list.entries) |entry| {
        const trap_result = try runPendingTrapCheckpoint(shell);
        if (trap_result.flow != .normal) return trap_result;
        shell.state.last_status_errexit_ignored = false;
        const evaluated = switch (entry.terminator orelse .sequence) {
            .sequence => try evalAndOr(shell, entry.and_or),
            .background => try evalBackgroundAndOr(shell, entry.and_or),
        };
        status = evaluated.status;
        shell.state.last_status = status;
        if (evaluated.flow != .normal) return evaluated;
        if (shouldApplyErrexit(shell, evaluated)) return .{ .status = status, .flow = .{ .exit = status } };
    }
    const trap_result = try runPendingTrapCheckpoint(shell);
    if (trap_result.flow != .normal) return trap_result;
    return .{ .status = status };
}

fn shouldApplyErrexit(shell: anytype, evaluated: result.EvalResult) bool {
    return shell.state.options.errexit and shell.state.errexit_ignore_depth == 0 and evaluated.flow == .normal and
        evaluated.status != 0 and !shell.state.last_status_errexit_ignored;
}

fn evalBackgroundAndOr(shell: anytype, and_or: ast.AndOr) EvalError!result.EvalResult {
    validateAst(and_or);
    if (and_or.pipelines.len == 1 and and_or.pipelines[0].pipeline.stages.len > 1) {
        return evalBackgroundPipeline(shell, and_or.pipelines[0].pipeline);
    }
    _ = shellProcessId(shell);
    _ = parentProcessId(shell);
    const background_subshell = backgroundSubshellInvocation(and_or);
    const pid = switch (try shell.host.forkProcess()) {
        .parent => |child_pid| child_pid,
        .child => {
            const scratch = shell.beginScratchScope() catch shell.host.exit(2);
            defer scratch.end();
            if (shell.state.options.monitor) setChildProcessGroup(shell, 0) catch shell.host.exit(2);
            resetJobControlSignalsForChild(shell);
            resetCaughtSignalTrapsForAsyncChild(shell);
            if (!shell.state.options.monitor) ignoreAsynchronousJobSignals(shell) catch shell.host.exit(2);
            if (background_subshell) |subshell| {
                // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                const evaluated = evalSubshellInCurrentProcess(shell, subshell.body.subshell, subshell.redirections) catch shell.host.exit(2);
                const status = runExitTrap(shell, evaluated.status) catch shell.host.exit(2);
                shell.host.exit(status);
            } else {
                if (!shell.state.options.xtrace and and_or.pipelines.len == 1) {
                    const pipeline = and_or.pipelines[0].pipeline;
                    if (!pipeline.negated and pipeline.stages.len == 1) {
                        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                        const request = dynamicExternalCommandRequest(shell, pipeline.stages[0], &.{}) catch shell.host.exit(2);
                        if (request) |spawn_request| shell.host.exec(spawn_request) catch shell.host.exit(127);
                    }
                }
                const evaluated = evalAndOr(shell, and_or) catch shell.host.exit(2);
                shell.host.exit(evaluated.status);
            }
        },
    };
    // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
    if (shell.state.options.monitor) setParentProcessGroup(shell, pid, pid) catch {};
    shell.state.last_background_pid = pid;
    try shell.state.addBackgroundPid(pid);
    const job_scratch = try shell.beginScratchScope();
    defer job_scratch.end();
    try shell.state.addBackgroundJob(pid, try backgroundAndOrCommandText(shell, and_or), shell.state.options.monitor);
    return .{ .status = 0 };
}

fn ignoreAsynchronousJobSignals(shell: anytype) !void {
    try shell.host.setSignalIgnored(2);
    try shell.host.setSignalIgnored(3);
}

fn resetCaughtSignalTrapsForAsyncChild(shell: anytype) void {
    var iterator = shell.state.signal_traps.iterator();
    while (iterator.next()) |entry| {
        const number = builtin.signalNumber(entry.key_ptr.*) orelse continue;
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        shell.host.setSignalDefault(number) catch {};
    }
    shell.state.running_signal_trap = false;
    shell.state.clearSignalTraps();
}

fn shellProcessId(shell: anytype) host_mod.Pid {
    if (shell.state.shell_pid) |pid| return pid;
    const pid = shell.host.currentProcessId();
    shell.state.shell_pid = pid;
    return pid;
}

fn parentProcessId(shell: anytype) host_mod.Pid {
    if (shell.state.parent_pid) |pid| return pid;
    const pid = shell.host.currentParentProcessId();
    shell.state.parent_pid = pid;
    return pid;
}

fn backgroundSubshellInvocation(and_or: ast.AndOr) ?ast.CompoundInvocation {
    if (and_or.pipelines.len != 1) return null;
    const pipeline = and_or.pipelines[0].pipeline;
    if (pipeline.negated or pipeline.stages.len != 1) return null;
    const command = pipeline.stages[0];
    if (command != .compound) return null;
    const compound = command.compound;
    if (compound.body != .subshell) return null;
    return compound;
}

fn evalBackgroundPipeline(shell: anytype, pipeline: ast.Pipeline) EvalError!result.EvalResult {
    validateAst(pipeline);
    std.debug.assert(pipeline.stages.len > 1);
    _ = shellProcessId(shell);
    _ = parentProcessId(shell);
    const pids = try spawnPipelineStages(shell, pipeline.stages, true, shell.state.options.monitor);
    defer shell.allocator.free(pids);
    for (pids) |pid| try shell.state.addBackgroundPid(pid);
    shell.state.last_background_pid = pids[pids.len - 1];
    const job_scratch = try shell.beginScratchScope();
    defer job_scratch.end();
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    try shell.state.addBackgroundJobPids(pids, pids[0], try pipelineCommandText(shell, pipeline), shell.state.options.monitor);
    return .{ .status = 0 };
}

fn backgroundAndOrCommandText(shell: anytype, and_or: ast.AndOr) ![]const u8 {
    if (and_or.pipelines.len != 1) return "background job";
    return pipelineCommandText(shell, and_or.pipelines[0].pipeline);
}

fn pipelineCommandText(shell: anytype, pipeline: ast.Pipeline) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    if (pipeline.negated) try output.appendSlice(allocator, "! ");
    for (pipeline.stages, 0..) |stage, stage_index| {
        if (stage_index != 0) try output.appendSlice(allocator, " | ");
        try output.appendSlice(allocator, try commandText(shell, stage));
    }
    return output.toOwnedSlice(allocator);
}

fn commandText(shell: anytype, command: ast.Command) ![]const u8 {
    return switch (command) {
        .simple => |simple| simpleCommandText(shell, simple),
        .function_definition => |definition| definition.name,
        .compound => "compound command",
    };
}

fn simpleCommandText(shell: anytype, command: ast.SimpleCommand) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    var needs_space = false;
    for (command.assignments) |assignment| {
        if (needs_space) try output.append(allocator, ' ');
        try output.appendSlice(allocator, assignment.name);
        try output.append(allocator, '=');
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        if (staticLiteralWord(assignment.value)) |value| try output.appendSlice(allocator, value) else try output.appendSlice(allocator, "...");
        needs_space = true;
    }
    for (command.words) |word| {
        if (needs_space) try output.append(allocator, ' ');
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        if (staticLiteralWord(word)) |value| try output.appendSlice(allocator, value) else try output.appendSlice(allocator, "...");
        needs_space = true;
    }
    return if (needs_space) output.toOwnedSlice(allocator) else "simple command";
}

fn evalAndOr(shell: anytype, and_or: ast.AndOr) EvalError!result.EvalResult {
    validateAst(and_or);
    var last: result.EvalResult = .{};
    for (and_or.pipelines, 0..) |pipeline, index| {
        if (index != 0) switch (pipeline.operator.?) {
            .and_if => if (last.status != 0) {
                shell.state.last_status_errexit_ignored = true;
                continue;
            },
            .or_if => if (last.status == 0) continue,
        };
        shell.state.last_status_errexit_ignored = false;
        const ignore_errexit = index + 1 < and_or.pipelines.len;
        if (ignore_errexit) shell.state.errexit_ignore_depth += 1;
        last = evalPipeline(shell, pipeline.pipeline) catch |err| {
            if (ignore_errexit) shell.state.errexit_ignore_depth -= 1;
            return err;
        };
        shell.state.last_status = last.status;
        if (ignore_errexit) shell.state.errexit_ignore_depth -= 1;
        if (last.flow != .normal) return last;
    }
    return last;
}

fn evalPipeline(shell: anytype, pipeline: ast.Pipeline) EvalError!result.EvalResult {
    validateAst(pipeline);
    var evaluated = if (pipeline.stages.len == 1) evaluated: {
        const command_result = try evalCommand(shell, pipeline.stages[0]);
        try shell.state.setLastPipelineStatuses(&.{command_result.status});
        break :evaluated command_result;
    } else try evalExternalPipeline(shell, pipeline);
    if (pipeline.negated and evaluated.flow == .normal) evaluated.status = if (evaluated.status == 0) 1 else 0;
    return evaluated;
}

fn evalExternalPipeline(shell: anytype, pipeline: ast.Pipeline) EvalError!result.EvalResult {
    const stages = pipeline.stages;
    std.debug.assert(stages.len > 1);
    const pipefail = shell.state.options.pipefail;
    const pids = try spawnPipelineStages(shell, stages, false, shell.state.options.monitor);
    defer shell.allocator.free(pids);
    const foreground_restore_group = giveTerminalToProcessGroup(shell, pids[0]) catch {
        const scratch = try shell.beginScratchScope();
        defer scratch.end();
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        _ = waitPids(shell, pids) catch {};
        return .{ .status = 1 };
    };
    defer if (foreground_restore_group) |process_group| restoreTerminalToProcessGroup(shell, process_group);
    const scratch = try shell.beginScratchScope();
    defer scratch.end();
    const statuses = try waitForegroundPids(shell, pids);
    try setPipelineStatusArray(shell, statuses);
    if (pipelineStopped(statuses)) {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try shell.state.addBackgroundJobPids(pids, pids[0], try pipelineCommandText(shell, pipeline), shell.state.options.monitor);
        _ = shell.state.setBackgroundJobStatusByPid(pids[0], .stopped);
        return .{ .status = stoppedPipelineStatus(statuses) };
    }
    return .{ .status = pipelineStatus(statuses, pipefail) };
}

fn setPipelineStatusArray(shell: anytype, statuses: []const host_mod.WaitStatus) !void {
    const values = try shell.scratchAllocator().alloc(result.ExitStatus, statuses.len);
    for (statuses, 0..) |status, index| values[index] = status.shellStatus();
    try shell.state.setLastPipelineStatuses(values);
}

fn pipelineStopped(statuses: []const host_mod.WaitStatus) bool {
    for (statuses) |status| switch (status) {
        .stopped => return true,
        else => {},
    };
    return false;
}

fn stoppedPipelineStatus(statuses: []const host_mod.WaitStatus) result.ExitStatus {
    for (statuses) |status| switch (status) {
        .stopped => return status.shellStatus(),
        else => {},
    };
    return 0;
}

fn giveTerminalToProcessGroup(shell: anytype, process_group: host_mod.Pid) !?host_mod.Pid {
    if (!shell.state.options.monitor) return null;
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (!@hasDecl(HostType, "terminalProcessGroup") or
        !@hasDecl(HostType, "setTerminalProcessGroup")) return null;
    const tty_fd = shell.state.controlling_tty orelse .stdin;
    const shell_process_group = shell.host.terminalProcessGroup(tty_fd) catch |err| switch (err) {
        error.NotATerminal => return null,
        else => return err,
    };
    shell.host.setTerminalProcessGroup(tty_fd, process_group) catch |err| switch (err) {
        error.NotATerminal => return null,
        else => return err,
    };
    return shell_process_group;
}

fn restoreTerminalToProcessGroup(shell: anytype, process_group: host_mod.Pid) void {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (!@hasDecl(HostType, "setTerminalProcessGroup")) return;
    // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
    shell.host.setTerminalProcessGroup(shell.state.controlling_tty orelse .stdin, process_group) catch {};
}

fn pipelineStatus(statuses: []const host_mod.WaitStatus, pipefail: bool) result.ExitStatus {
    if (!pipefail) return statuses[statuses.len - 1].shellStatus();
    var index = statuses.len;
    while (index != 0) {
        index -= 1;
        const status = statuses[index].shellStatus();
        if (status != 0) return status;
    }
    return 0;
}

fn spawnPipelineStages(
    shell: anytype,
    stages: []const ast.Command,
    direct_static_externals: bool,
    create_process_group: bool,
) EvalError![]const host_mod.Pid {
    std.debug.assert(stages.len > 1);
    const scratch = try shell.beginScratchScope();
    defer scratch.end();

    const allocator = shell.scratchAllocator();
    const pipes = try allocator.alloc(host_mod.Pipe, stages.len - 1);
    var open_pipes: usize = 0;
    errdefer closePipes(shell, pipes[0..open_pipes]);
    for (pipes) |*pipe_desc| {
        pipe_desc.* = try shell.host.pipe();
        open_pipes += 1;
    }

    const pids = try shell.allocator.alloc(host_mod.Pid, stages.len);
    errdefer shell.allocator.free(pids);
    var spawned: usize = 0;
    errdefer {
        closePipes(shell, pipes[0..open_pipes]);
        _ = waitPids(shell, pids[0..spawned]) catch {};
    }

    for (stages, 0..) |stage, index| {
        const suppress_child_xtrace = try traceStaticPipelineStage(shell, stage);
        const process_group: ?host_mod.Pid = if (!create_process_group) null else if (index == 0) 0 else pids[0];
        pids[index] = try forkPipelineStage(
            shell,
            stage,
            pipes,
            index,
            direct_static_externals,
            process_group,
            suppress_child_xtrace,
        );
        spawned += 1;
    }

    closePipes(shell, pipes);
    open_pipes = 0;
    return pids;
}

fn closePipes(shell: anytype, pipes: []const host_mod.Pipe) void {
    for (pipes) |pipe_desc| {
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        shell.host.close(pipe_desc.read) catch {};
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        shell.host.close(pipe_desc.write) catch {};
    }
}

fn waitPids(shell: anytype, pids: []const host_mod.Pid) ![]const host_mod.WaitStatus {
    const statuses = try shell.scratchAllocator().alloc(host_mod.WaitStatus, pids.len);
    for (pids, 0..) |pid, index| statuses[index] = try shell.host.wait(pid);
    return statuses;
}

fn waitForegroundPids(shell: anytype, pids: []const host_mod.Pid) ![]const host_mod.WaitStatus {
    const statuses = try shell.scratchAllocator().alloc(host_mod.WaitStatus, pids.len);
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    for (pids, 0..) |pid, index| {
        statuses[index] = if (@hasDecl(HostType, "waitJobEvent"))
            try shell.host.waitJobEvent(pid)
        else
            try shell.host.wait(pid);
        switch (statuses[index]) {
            .stopped => |signal| {
                for (statuses[index + 1 ..]) |*status| status.* = .{ .stopped = signal };
                break;
            },
            else => {},
        }
    }
    return statuses;
}

fn forkPipelineStage(
    shell: anytype,
    command: ast.Command,
    pipes: []const host_mod.Pipe,
    stage_index: usize,
    direct_static_external: bool,
    process_group: ?host_mod.Pid,
    suppress_child_xtrace: bool,
) !host_mod.Pid {
    const fd_actions = try pipelineFdActions(shell, pipes, stage_index);
    if (direct_static_external) {
        if (try staticExternalPipelineStageRequest(shell, command, fd_actions)) |request| {
            var grouped_request = request;
            grouped_request.process_group = process_group;
            const pid = (try shell.host.spawn(grouped_request)).pid;
            if (process_group) |pgid| try setParentProcessGroup(shell, pid, if (pgid == 0) pid else pgid);
            return pid;
        }
    }
    return switch (try shell.host.forkProcess()) {
        .parent => |pid| {
            if (process_group) |pgid| try setParentProcessGroup(shell, pid, if (pgid == 0) pid else pgid);
            return pid;
        },
        .child => {
            if (process_group) |pgid| setChildProcessGroup(shell, pgid) catch shell.host.exit(2);
            resetJobControlSignalsForChild(shell);
            applyPipelineChildFdActions(shell, fd_actions) catch shell.host.exit(127);
            if (!shell.state.options.xtrace) {
                const request = dynamicExternalCommandRequest(shell, command, &.{}) catch shell.host.exit(2);
                if (request) |spawn_request| shell.host.exec(spawn_request) catch shell.host.exit(127);
            }
            if (suppress_child_xtrace) shell.state.options.xtrace = false;
            const evaluated = evalCommand(shell, command) catch shell.host.exit(2);
            shell.host.exit(evaluated.status);
        },
    };
}

fn traceStaticPipelineStage(shell: anytype, command: ast.Command) EvalError!bool {
    if (!shell.state.options.xtrace) return false;
    const fields = try staticPipelineStageFields(shell, command) orelse return false;
    try traceSimpleCommand(shell, &.{}, fields);
    return true;
}

fn staticPipelineStageFields(shell: anytype, command: ast.Command) !?[]const []const u8 {
    if (command != .simple) return null;
    const simple = command.simple;
    if (simple.assignments.len != 0 or simple.redirections.len != 0 or simple.words.len == 0) return null;

    const fields = try shell.scratchAllocator().alloc([]const u8, simple.words.len);
    for (simple.words, 0..) |word, index| {
        if (wordExpandsLeadingTilde(shell, word)) return null;
        fields[index] = staticLiteralWord(word) orelse return null;
    }
    if (shell.state.getFunction(fields[0]) != null) return null;
    return fields;
}

fn resetJobControlSignalsForChild(shell: anytype) void {
    if (!shell.state.options.monitor) return;
    // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
    for (job_control_signals) |signal| shell.host.setSignalDefault(signal) catch {};
}

fn setParentProcessGroup(shell: anytype, pid: host_mod.Pid, process_group: host_mod.Pid) !void {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (!@hasDecl(HostType, "setProcessGroup")) return;
    shell.host.setProcessGroup(pid, process_group) catch |err| switch (err) {
        error.AccessDenied => return,
        else => return err,
    };
}

fn setChildProcessGroup(shell: anytype, process_group: host_mod.Pid) !void {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (!@hasDecl(HostType, "setProcessGroup")) return;
    try shell.host.setProcessGroup(0, process_group);
}

fn staticExternalPipelineStageRequest(
    shell: anytype,
    command: ast.Command,
    fd_actions: []const host_mod.SpawnFdAction,
) !?host_mod.SpawnRequest {
    if (command != .simple) return null;
    const simple = command.simple;
    if (simple.assignments.len != 0 or simple.redirections.len != 0 or simple.words.len == 0) return null;

    const fields = try shell.scratchAllocator().alloc([]const u8, simple.words.len);
    for (simple.words, 0..) |word, index| {
        if (wordExpandsLeadingTilde(shell, word)) return null;
        fields[index] = staticLiteralWord(word) orelse return null;
    }
    if (lookupBuiltin(shell, fields[0]) != null or shell.state.getFunction(fields[0]) != null) return null;
    return makeExternalSpawnRequest(shell, fields, &.{}, fd_actions) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
}

fn lookupBuiltin(shell: anytype, name: []const u8) ?builtin.Definition {
    const ShellType = switch (@typeInfo(@TypeOf(shell))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell),
    };
    if (@hasDecl(ShellType, "lookupBuiltin")) return shell.lookupBuiltin(name);
    return builtin.lookup(name);
}

fn staticLiteralWord(word: ast.Word) ?[]const u8 {
    return switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| staticLiteralParts(parts),
        .declaration_array_assignment => null,
    };
}

fn staticLiteralParts(parts: []const ast.WordPart) ?[]const u8 {
    if (parts.len != 1) return null;
    return switch (parts[0]) {
        .literal, .escaped, .single_quoted => |literal| literal,
        .double_quoted => |nested| staticLiteralParts(nested),
        else => null,
    };
}

fn applyPipelineChildFdActions(shell: anytype, actions: []const host_mod.SpawnFdAction) !void {
    for (actions) |action| switch (action) {
        .close => |fd| try shell.host.close(fd),
        .duplicate => |dup| try shell.host.duplicateTo(dup.from, dup.to),
    };
}

fn pipelineFdActions(
    shell: anytype,
    pipes: []const host_mod.Pipe,
    stage_index: usize,
) ![]const host_mod.SpawnFdAction {
    const allocator = shell.scratchAllocator();
    var actions: std.ArrayList(host_mod.SpawnFdAction) = .empty;

    if (stage_index != 0) try actions.append(allocator, .{ .duplicate = .{
        .from = pipes[stage_index - 1].read,
        .to = .stdin,
    } });
    if (stage_index < pipes.len) try actions.append(allocator, .{ .duplicate = .{
        .from = pipes[stage_index].write,
        .to = .stdout,
    } });
    for (pipes) |pipe_desc| {
        try actions.append(allocator, .{ .close = pipe_desc.read });
        try actions.append(allocator, .{ .close = pipe_desc.write });
    }

    return actions.toOwnedSlice(allocator);
}

fn evalCommand(shell: anytype, command: ast.Command) EvalError!result.EvalResult {
    reapProcessSubstitutions(shell);
    const process_substitution_start = shell.state.process_substitutions.items.len;
    defer {
        cleanupProcessSubstitutions(shell, process_substitution_start);
        reapProcessSubstitutions(shell);
    }

    return switch (command) {
        .simple => |simple| evalSimple(shell, simple),
        .compound => |compound| evalCompound(shell, compound),
        .function_definition => |definition| evalFunctionDefinition(shell, definition),
    };
}

fn cleanupProcessSubstitutions(shell: anytype, start: usize) void {
    const substitutions = shell.state.process_substitutions.items[start..];
    for (substitutions) |substitution| {
        // ziglint-ignore: Z026 best-effort cleanup; command status must not depend on async process substitution
        shell.host.close(substitution.fd) catch {};
    }
    for (substitutions) |substitution| {
        reapOrDeferProcessSubstitution(shell, substitution.pid);
    }
    shell.state.process_substitutions.shrinkRetainingCapacity(start);
}

fn reapOrDeferProcessSubstitution(shell: anytype, pid: host_mod.Pid) void {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (comptime @hasDecl(HostType, "waitNonBlocking")) {
        if ((shell.host.waitNonBlocking(pid) catch null) != null) return;
    }
    // ziglint-ignore: Z026 best-effort reap queue; dropping it is preferable to failing the command
    shell.state.reap_process_substitutions.append(shell.state.allocator, .{ .pid = pid }) catch {};
}

fn reapProcessSubstitutions(shell: anytype) void {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (comptime !@hasDecl(HostType, "waitNonBlocking")) return;

    var write_index: usize = 0;
    for (shell.state.reap_process_substitutions.items) |substitution| {
        if ((shell.host.waitNonBlocking(substitution.pid) catch null) == null) {
            shell.state.reap_process_substitutions.items[write_index] = substitution;
            write_index += 1;
        }
    }
    shell.state.reap_process_substitutions.shrinkRetainingCapacity(write_index);
}

fn closeInheritedProcessSubstitutionFds(shell: anytype) void {
    for (shell.state.process_substitutions.items) |substitution| {
        // ziglint-ignore: Z026 best-effort child cleanup before replacing/evaluating the child body
        shell.host.close(substitution.fd) catch {};
    }
    shell.state.process_substitutions.clearRetainingCapacity();
}

fn evalCompound(shell: anytype, command: ast.CompoundInvocation) EvalError!result.EvalResult {
    validateAst(command);
    if (command.body == .subshell) return evalSubshell(shell, command.body.subshell, command.redirections);

    const scratch = try shell.beginScratchScope();
    defer scratch.end();

    if (command.redirections.len == 0) return evalCompoundBody(shell, command.body);

    var redirections = applyRedirections(shell, command.redirections) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return redirectionFailure(shell, false),
    };
    defer redirections.restore(shell) catch {};

    return evalCompoundBody(shell, command.body);
}

fn evalCompoundBody(shell: anytype, command: ast.CompoundCommand) EvalError!result.EvalResult {
    return switch (command) {
        .brace_group => |body| evalList(shell, body),
        .if_command => |if_command| evalIf(shell, if_command),
        .loop => |loop| evalLoop(shell, loop),
        .for_command => |for_command| evalFor(shell, for_command),
        .c_for_command => |c_for_command| evalCFor(shell, c_for_command),
        .arithmetic_command => |arithmetic_command| evalArithmeticCommand(shell, arithmetic_command),
        .conditional_command => |conditional_command| evalConditionalCommand(shell, conditional_command),
        .case_command => |case_command| evalCase(shell, case_command),
        else => .{ .status = 2 },
    };
}

fn evalIf(shell: anytype, command: ast.IfCommand) EvalError!result.EvalResult {
    validateAst(command);
    for (command.branches) |branch| {
        shell.state.errexit_ignore_depth += 1;
        const condition = evalList(shell, branch.condition) catch |err| {
            shell.state.errexit_ignore_depth -= 1;
            return err;
        };
        shell.state.errexit_ignore_depth -= 1;
        if (condition.flow != .normal) return condition;
        if (condition.status == 0) return evalList(shell, branch.body);
    }
    if (command.else_body) |body| return evalList(shell, body);
    return .{};
}

fn evalLoop(shell: anytype, command: ast.LoopCommand) EvalError!result.EvalResult {
    validateAst(command);
    shell.state.loop_depth += 1;
    defer shell.state.loop_depth -= 1;

    var status: result.ExitStatus = 0;
    while (true) {
        shell.state.errexit_ignore_depth += 1;
        const condition = evalList(shell, command.condition) catch |err| {
            shell.state.errexit_ignore_depth -= 1;
            return err;
        };
        shell.state.errexit_ignore_depth -= 1;
        switch (condition.flow) {
            .normal => {},
            .continue_ => |count| if (count <= 1 or count > shell.state.loop_depth) continue else return .{
                .status = condition.status,
                .flow = .{ .continue_ = count - 1 },
            },
            .break_ => |count| if (count <= 1 or count > shell.state.loop_depth)
                return .{ .status = condition.status }
            else
                return .{
                    .status = condition.status,
                    .flow = .{ .break_ = count - 1 },
                },
            else => return condition,
        }
        const run_body = switch (command.kind) {
            .while_loop => condition.status == 0,
            .until_loop => condition.status != 0,
        };
        if (!run_body) return .{ .status = status };

        const evaluated = try evalList(shell, command.body);
        status = evaluated.status;
        switch (evaluated.flow) {
            .normal => {},
            .continue_ => |count| if (count <= 1 or count > shell.state.loop_depth) continue else return .{
                .status = status,
                .flow = .{ .continue_ = count - 1 },
            },
            .break_ => |count| if (count <= 1 or count > shell.state.loop_depth)
                return .{ .status = status }
            else
                return .{
                    .status = status,
                    .flow = .{ .break_ = count - 1 },
                },
            else => return evaluated,
        }
    }
}

fn evalSubshell(shell: anytype, body: ast.List, redirections: []const ast.Redirection) EvalError!result.EvalResult {
    _ = shellProcessId(shell);
    _ = parentProcessId(shell);
    const pid = switch (try shell.host.forkProcess()) {
        .child => {
            const scratch = shell.beginScratchScope() catch shell.host.exit(2);
            defer scratch.end();
            const evaluated = evalSubshellInCurrentProcess(shell, body, redirections) catch shell.host.exit(2);
            const status = runExitTrap(shell, evaluated.status) catch shell.host.exit(2);
            shell.host.exit(status);
        },
        .parent => |child_pid| child_pid,
    };
    const wait_status = try shell.host.wait(pid);
    return .{ .status = wait_status.shellStatus() };
}

fn evalSubshellInCurrentProcess(
    shell: anytype,
    body: ast.List,
    redirections: []const ast.Redirection,
) EvalError!result.EvalResult {
    shell.state.loop_depth = 0;
    shell.state.running_exit_trap = false;
    shell.state.forgetActiveExitTrap();
    const applied = applyRedirections(shell, redirections) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return redirectionFailure(shell, false),
    };
    _ = applied;
    return evalList(shell, body);
}

fn evalFor(shell: anytype, command: ast.ForCommand) EvalError!result.EvalResult {
    validateAst(command);
    shell.state.loop_depth += 1;
    defer shell.state.loop_depth -= 1;

    const scratch = try shell.beginScratchScope();
    defer scratch.end();

    if (!isAssignmentName(command.name)) {
        try shell.host.writeAll(
            .stderr,
            try std.fmt.allocPrint(shell.scratchAllocator(), "`{s}': not a valid identifier\n", .{command.name}),
        );
        return .{ .status = 1 };
    }

    const words = try snapshotFields(shell, try forCommandWords(shell, command.words));
    var status: result.ExitStatus = 0;
    for (words) |word| {
        shell.state.putVariable(.{
            .name = command.name,
            .value = word,
            .exported = assignmentExported(shell, command.name),
        }) catch |err| switch (err) {
            error.ReadonlyVariable => {
                try writeReadonlyDiagnostic(shell, command.name);
                return .{
                    .status = 1,
                    .flow = if (shell.state.options.mode == .posix) .{ .fatal = 1 } else .normal,
                };
            },
            else => return err,
        };
        const evaluated = try evalList(shell, command.body);
        status = evaluated.status;
        switch (evaluated.flow) {
            .normal => {},
            .continue_ => |count| if (count <= 1 or count > shell.state.loop_depth) continue else return .{
                .status = status,
                .flow = .{ .continue_ = count - 1 },
            },
            .break_ => |count| if (count <= 1 or count > shell.state.loop_depth)
                return .{ .status = status }
            else
                return .{
                    .status = status,
                    .flow = .{ .break_ = count - 1 },
                },
            else => return evaluated,
        }
    }
    return .{ .status = status };
}

fn evalCFor(shell: anytype, command: ast.CForCommand) EvalError!result.EvalResult {
    validateAst(command);
    shell.state.loop_depth += 1;
    defer shell.state.loop_depth -= 1;

    if (command.init) |init| {
        if (!try evalArithmeticForSideEffect(shell, init)) return .{ .status = 1 };
    }

    var status: result.ExitStatus = 0;
    while (true) {
        if (command.condition) |condition| {
            if (!try evalArithmeticForCommand(shell, condition)) return .{ .status = status };
        }

        const evaluated = try evalList(shell, command.body);
        status = evaluated.status;
        switch (evaluated.flow) {
            .normal => {},
            .continue_ => |count| if (count <= 1 or count > shell.state.loop_depth) {
                if (command.update) |update| {
                    if (!try evalArithmeticForSideEffect(shell, update)) return .{ .status = 1 };
                }
                continue;
            } else return .{
                .status = status,
                .flow = .{ .continue_ = count - 1 },
            },
            .break_ => |count| if (count <= 1 or count > shell.state.loop_depth)
                return .{ .status = status }
            else
                return .{
                    .status = status,
                    .flow = .{ .break_ = count - 1 },
                },
            else => return evaluated,
        }

        if (command.update) |update| {
            if (!try evalArithmeticForSideEffect(shell, update)) return .{ .status = 1 };
        }
    }
}

fn evalArithmeticCommand(shell: anytype, command: ast.ArithmeticCommand) EvalError!result.EvalResult {
    validateAst(command);
    const text = std.mem.trim(u8, command.expression, " \t\r\n");
    if (text.len == 0) return .{ .status = 1 };
    const value = evalArithmeticValue(shell, text) catch |err| switch (err) {
        error.InvalidArithmetic, error.FatalExpansionError => {
            try shell.host.writeAll(.stderr, "arithmetic expansion error\n");
            return .{ .status = 1 };
        },
        else => return err,
    };
    return .{ .status = if (value != 0) 0 else 1 };
}

fn evalConditionalCommand(shell: anytype, command: ast.ConditionalCommand) EvalError!result.EvalResult {
    validateAst(command);
    const scratch = try shell.beginScratchScope();
    defer scratch.end();

    const matched = try evalConditionalExpression(shell, command.expression);
    return .{ .status = if (matched) 0 else 1 };
}

fn evalConditionalExpression(shell: anytype, expression: ast.ConditionalExpression) EvalError!bool {
    return switch (expression) {
        .word => |word| (try expandWord(shell, word)).len != 0,
        .unary_not => |nested| !try evalConditionalExpression(shell, nested.*),
        .unary_test => |unary| evalConditionalUnaryTest(shell, unary),
        .binary => |binary| switch (binary.operator) {
            .and_if => if (try evalConditionalExpression(shell, binary.left.*))
                try evalConditionalExpression(shell, binary.right.*)
            else
                false,
            .or_if => if (try evalConditionalExpression(shell, binary.left.*))
                true
            else
                try evalConditionalExpression(shell, binary.right.*),
        },
        .comparison => |comparison| evalConditionalComparison(shell, comparison),
    };
}

fn evalConditionalUnaryTest(shell: anytype, test_expr: ast.ConditionalUnaryTest) EvalError!bool {
    const operand = try expandWord(shell, test_expr.operand);
    return switch (test_expr.operator) {
        .option_enabled => builtin.isSetOptionEnabled(shell, operand) orelse false,
        .string_empty => operand.len == 0,
        .string_nonempty => operand.len != 0,
        .variable_set => try conditionalParameterIsSet(shell, operand),
        else => (try evalFileUnaryTest(shell, conditionalUnaryTestOperatorText(test_expr.operator), operand)).?,
    };
}

fn conditionalParameterIsSet(shell: anytype, name: []const u8) EvalError!bool {
    if (isAssignmentName(name)) {
        if (shell.state.getVariable(name) != null) return true;
        const array = shell.state.getArray(name) orelse return false;
        return array.elementValue(0) != null;
    }
    if (shell.state.options.mode == .posix) return false;

    const parameter = parser.parseBracedParameterExpansion(
        shell.scratchAllocator(),
        name,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    } orelse return false;
    if (parameter.length or parameter.array_indices or parameter.op != null) {
        return false;
    }
    return switch (parameter.parameter) {
        .positional => |position| positionalValue(shell, position) != null,
        .array => |array_parameter| try conditionalArrayParameterIsSet(shell, array_parameter),
        else => false,
    };
}

fn conditionalArrayParameterIsSet(shell: anytype, parameter: ast.ArrayParameter) EvalError!bool {
    if (shell.state.getArray(parameter.name)) |array| {
        return switch (parameter.subscript) {
            .index => |word| array.elementValue(try expandArrayIndexForArray(shell, word, array)) != null,
            .all => array.elements.len != 0,
        };
    }

    if (shell.state.getVariable(parameter.name) == null) return false;
    return switch (parameter.subscript) {
        .index => |word| (try expandArrayIndexForName(shell, parameter.name, word)) == 0,
        .all => true,
    };
}

fn conditionalUnaryTestOperatorText(operator: ast.ConditionalUnaryTestOperator) []const u8 {
    return switch (operator) {
        .block_device => "-b",
        .character_device => "-c",
        .directory => "-d",
        .exists => "-e",
        .file => "-f",
        .setgid => "-g",
        .symlink => "-h",
        .named_pipe => "-p",
        .socket => "-S",
        .nonempty_file => "-s",
        .setuid => "-u",
        .terminal => "-t",
        .readable => "-r",
        .writable => "-w",
        .executable => "-x",
        .option_enabled, .string_empty, .string_nonempty, .variable_set => unreachable,
    };
}

fn evalConditionalComparison(shell: anytype, comparison: ast.ConditionalComparison) EvalError!bool {
    const left = try expandWord(shell, comparison.left);
    const right = switch (comparison.operator) {
        .equal, .not_equal => if (comparison.right.quoted)
            try expandWord(shell, comparison.right)
        else
            try expandPatternWord(shell, comparison.right),
        .less,
        .greater,
        .integer_equal,
        .integer_not_equal,
        .integer_greater,
        .integer_greater_equal,
        .integer_less,
        .integer_less_equal,
        => try expandWord(shell, comparison.right),
    };

    if (conditionalIntegerComparisonOperatorText(comparison.operator)) |operator| {
        return (evalIntegerComparison(shell, left, operator, right) catch |err| switch (err) {
            error.Integer => {
                try writeTestDiagnostic(shell, "[[", error.Integer);
                return false;
            },
            error.Syntax => return false,
        }).?;
    }

    const matched = switch (comparison.operator) {
        .equal => if (comparison.right.quoted) std.mem.eql(u8, left, right) else pattern_mod.matchesText(right, left),
        .not_equal => if (comparison.right.quoted)
            !std.mem.eql(u8, left, right)
        else
            !pattern_mod.matchesText(right, left),
        .less => std.mem.order(u8, left, right) == .lt,
        .greater => std.mem.order(u8, left, right) == .gt,
        .integer_equal,
        .integer_not_equal,
        .integer_greater,
        .integer_greater_equal,
        .integer_less,
        .integer_less_equal,
        => unreachable,
    };
    return matched;
}

fn conditionalIntegerComparisonOperatorText(operator: ast.ConditionalComparisonOperator) ?[]const u8 {
    return switch (operator) {
        .integer_equal => "-eq",
        .integer_not_equal => "-ne",
        .integer_greater => "-gt",
        .integer_greater_equal => "-ge",
        .integer_less => "-lt",
        .integer_less_equal => "-le",
        .equal, .not_equal, .less, .greater => null,
    };
}

fn evalArithmeticForCommand(shell: anytype, text: []const u8) EvalError!bool {
    const value = evalArithmeticValue(shell, text) catch |err| switch (err) {
        error.InvalidArithmetic, error.FatalExpansionError => {
            try shell.host.writeAll(.stderr, "arithmetic expansion error\n");
            return false;
        },
        else => return err,
    };
    return value != 0;
}

fn evalArithmeticForSideEffect(shell: anytype, text: []const u8) EvalError!bool {
    _ = evalArithmeticValue(shell, text) catch |err| switch (err) {
        error.InvalidArithmetic, error.FatalExpansionError => {
            try shell.host.writeAll(.stderr, "arithmetic expansion error\n");
            return false;
        },
        else => return err,
    };
    return true;
}

fn forCommandWords(shell: anytype, words: ast.ForWords) ![]const []const u8 {
    return switch (words) {
        .positional_parameters => shell.state.positionals,
        .words => |word_list| expandForWordFields(shell, word_list),
    };
}

fn snapshotFields(shell: anytype, fields: []const []const u8) ![]const []const u8 {
    const allocator = shell.scratchAllocator();
    const snapshot = try allocator.alloc([]const u8, fields.len);
    for (fields, 0..) |field, index| snapshot[index] = try allocator.dupe(u8, field);
    return snapshot;
}

fn expandForWordFields(shell: anytype, words: []const ast.Word) ![]const []const u8 {
    if (words.len == 0) return &.{};
    const allocator = shell.scratchAllocator();
    var fields: std.ArrayList([]const u8) = .empty;
    for (words) |word| {
        if (try appendUnquotedAtFields(shell, &fields, word) or
            try appendUnquotedStarFields(shell, &fields, word) or
            try appendUnquotedArrayIndexFields(shell, &fields, word) or
            try appendEmbeddedUnquotedPositionalFields(shell, &fields, word) or
            try appendSpecialQuotedFields(shell, &fields, word))
        {
            continue;
        } else if (!wordHasDynamicExpansion(word)) {
            try appendStaticWordField(shell, &fields, word);
        } else {
            if (wordContainsQuotes(word)) {
                if (wordDynamicExpansionsAreQuoted(word)) {
                    try appendPathnameExpandedPattern(
                        shell,
                        &fields,
                        try expandQuotedDynamicWordPathnamePattern(shell, word, null),
                    );
                } else {
                    const expanded = try expandWordTracking(shell, word, null);
                    try fields.append(allocator, expanded);
                }
            } else {
                const expanded = try expandWordTracking(shell, word, null);
                if (wordHasFieldSplittingExpansion(word)) {
                    try appendSplitFields(shell, &fields, expanded, !wordExpandsLeadingTilde(shell, word));
                } else {
                    try appendPathnameExpandedField(shell, &fields, expanded);
                }
            }
        }
    }
    return fields.toOwnedSlice(allocator);
}

fn appendSpecialQuotedFields(shell: anytype, fields: *std.ArrayList([]const u8), word: ast.Word) !bool {
    if (try appendEmbeddedQuotedAtFields(shell, fields, word)) return true;
    if (try appendEmbeddedQuotedArrayAtFields(shell, fields, word)) return true;
    if (wordIsQuotedAt(word)) {
        try fields.appendSlice(shell.scratchAllocator(), shell.state.positionals);
        return true;
    }
    if (try appendParameterOperatorAtFields(shell, fields, word)) return true;
    if (try appendParameterOperatorStarField(shell, fields, word)) return true;
    const parameter = singleDoubleQuotedParameter(word) orelse return false;
    if (parameter.parameter != .special or parameter.parameter.special != .at or parameter.op == null) return false;

    switch (parameter.op.?) {
        .default_value => {
            if (shell.state.positionals.len == 0) return false;
            try fields.appendSlice(shell.scratchAllocator(), shell.state.positionals);
            return true;
        },
        .alternate_value => {
            if (shell.state.positionals.len == 0 or parameter.word == null or !wordIsAtParameter(parameter.word.?)) {
                return false;
            }
            try fields.appendSlice(shell.scratchAllocator(), shell.state.positionals);
            return true;
        },
        else => return false,
    }
}

fn appendParameterOperatorAtFields(shell: anytype, fields: *std.ArrayList([]const u8), word: ast.Word) !bool {
    const parameter = singleParameterWord(word) orelse return false;
    if (parameter.op == null or parameter.word == null) return false;
    const at_parts = atExpansionParts(parameter.word.?) orelse return false;

    const is_set = isParameterSet(parameter, try parameterCurrentValue(shell, parameter.parameter));
    const selected = switch (parameter.op.?) {
        .default_value => !is_set,
        .alternate_value => is_set,
        else => false,
    };
    if (!selected) return false;

    try appendQuotedAtPartsFields(shell, fields, at_parts);
    return true;
}

fn appendParameterOperatorStarField(shell: anytype, fields: *std.ArrayList([]const u8), word: ast.Word) !bool {
    const parameter = singleParameterWord(word) orelse return false;
    if (parameter.op == null or parameter.word == null) return false;
    const parameter_is_quoted = singleDoubleQuotedParameter(word) != null;
    const word_is_quoted_star = wordIsQuotedStar(parameter.word.?);
    const word_is_unquoted_star = wordIsUnquotedStar(parameter.word.?);
    if (!word_is_quoted_star and !word_is_unquoted_star) return false;

    const is_set = isParameterSet(parameter, try parameterCurrentValue(shell, parameter.parameter));
    const selected = switch (parameter.op.?) {
        .default_value => !is_set,
        .alternate_value => is_set,
        else => false,
    };
    if (!selected) return false;

    if (parameter_is_quoted or word_is_quoted_star) {
        try fields.append(shell.scratchAllocator(), try joinPositionals(shell, ifsFirstCharacter(shell)));
    } else {
        try appendUnquotedPositionalFields(shell, fields);
    }
    return true;
}

fn appendEmbeddedQuotedAtFields(shell: anytype, fields: *std.ArrayList([]const u8), word: ast.Word) !bool {
    const quoted = switch (word.data) {
        .literal => return false,
        .parts => |parts| if (parts.len == 1) switch (parts[0]) {
            .double_quoted => |nested| nested,
            else => return false,
        } else return false,
        .declaration_array_assignment => return false,
    };
    if (!wordPartsContainAtParameter(quoted)) return false;

    try appendQuotedAtPartsFields(shell, fields, quoted);
    return true;
}

fn appendEmbeddedQuotedArrayAtFields(shell: anytype, fields: *std.ArrayList([]const u8), word: ast.Word) !bool {
    const quoted = switch (word.data) {
        .literal => return false,
        .parts => |parts| if (parts.len == 1) switch (parts[0]) {
            .double_quoted => |nested| nested,
            else => return false,
        } else return false,
        .declaration_array_assignment => return false,
    };
    if (!wordPartsContainArrayAtParameter(quoted)) return false;

    try appendQuotedArrayAtPartsFields(shell, fields, quoted);
    return true;
}

fn appendQuotedAtPartsFields(shell: anytype, fields: *std.ArrayList([]const u8), quoted: []const ast.WordPart) !void {
    const positionals = shell.state.positionals;
    const allocator = shell.scratchAllocator();
    const start_len = fields.items.len;
    var expanded_positionals = false;
    try fields.append(allocator, "");
    var segment_start: usize = 0;
    for (quoted, 0..) |part, index| {
        if (!wordPartIsAtParameter(part)) continue;
        try appendTextToLastField(shell, fields, try expandWordParts(shell, quoted[segment_start..index], null));
        if (positionals.len != 0) {
            expanded_positionals = true;
            try appendTextToLastField(shell, fields, positionals[0]);
            if (positionals.len > 1) try fields.appendSlice(allocator, positionals[1..]);
        }
        segment_start = index + 1;
    }
    try appendTextToLastField(shell, fields, try expandWordParts(shell, quoted[segment_start..], null));
    if (!expanded_positionals and fields.items.len == start_len + 1 and fields.items[start_len].len == 0) {
        _ = fields.pop();
    }
}

fn appendQuotedArrayAtPartsFields(
    shell: anytype,
    fields: *std.ArrayList([]const u8),
    quoted: []const ast.WordPart,
) !void {
    const allocator = shell.scratchAllocator();
    const start_len = fields.items.len;
    var expanded_array = false;
    try fields.append(allocator, "");
    var segment_start: usize = 0;
    for (quoted, 0..) |part, index| {
        const expansion = wordPartArrayAtExpansion(part) orelse continue;
        try appendTextToLastField(shell, fields, try expandWordParts(shell, quoted[segment_start..index], null));
        if (try arrayExpansionElements(shell, expansion.parameter)) |elements| if (elements.len != 0) {
            expanded_array = true;
            if (expansion.indices) {
                try appendTextToLastField(
                    shell,
                    fields,
                    try std.fmt.allocPrint(allocator, "{}", .{elements[0].index}),
                );
                for (elements[1..]) |element| {
                    try fields.append(allocator, try std.fmt.allocPrint(allocator, "{}", .{element.index}));
                }
            } else {
                try appendTextToLastField(shell, fields, elements[0].value);
                for (elements[1..]) |element| try fields.append(allocator, element.value);
            }
        };
        segment_start = index + 1;
    }
    try appendTextToLastField(shell, fields, try expandWordParts(shell, quoted[segment_start..], null));
    if (!expanded_array and fields.items.len == start_len + 1 and fields.items[start_len].len == 0) {
        _ = fields.pop();
    }
}

fn appendTextToLastField(shell: anytype, fields: *std.ArrayList([]const u8), text: []const u8) !void {
    if (text.len == 0) return;
    const last = &fields.items[fields.items.len - 1];
    last.* = try std.fmt.allocPrint(shell.scratchAllocator(), "{s}{s}", .{ last.*, text });
}

fn wordPartsContainAtParameter(parts: []const ast.WordPart) bool {
    for (parts) |part| if (wordPartIsAtParameter(part)) return true;
    return false;
}

fn wordPartsContainArrayAtParameter(parts: []const ast.WordPart) bool {
    for (parts) |part| if (wordPartArrayAtExpansion(part) != null) return true;
    return false;
}

const ArrayAtExpansion = struct {
    parameter: ast.ParameterExpansion,
    indices: bool,
};

fn wordPartArrayAtExpansion(part: ast.WordPart) ?ArrayAtExpansion {
    return switch (part) {
        .parameter => |parameter| {
            if (parameter.length or parameter.parameter != .array) return null;
            if (parameter.op != null and parameter.op.? != .substring) return null;
            const array = parameter.parameter.array;
            return switch (array.subscript) {
                .all => |special| if (special == .at) .{
                    .parameter = parameter,
                    .indices = parameter.array_indices,
                } else null,
                else => null,
            };
        },
        else => null,
    };
}

fn wordPartIsAtParameter(part: ast.WordPart) bool {
    return switch (part) {
        .parameter => |parameter| {
            return !parameter.length and parameter.op == null and parameter.parameter == .special and
                parameter.parameter.special == .at;
        },
        else => false,
    };
}

fn singleDoubleQuotedParameter(word: ast.Word) ?ast.ParameterExpansion {
    return switch (word.data) {
        .literal => null,
        .parts => |parts| if (parts.len == 1) switch (parts[0]) {
            .double_quoted => |quoted| if (quoted.len == 1) switch (quoted[0]) {
                .parameter => |parameter| parameter,
                else => null,
            } else null,
            else => null,
        } else null,
        .declaration_array_assignment => null,
    };
}

fn singleParameterWord(word: ast.Word) ?ast.ParameterExpansion {
    return switch (word.data) {
        .literal => null,
        .parts => |parts| if (parts.len == 1) switch (parts[0]) {
            .parameter => |parameter| parameter,
            .double_quoted => |quoted| if (quoted.len == 1) switch (quoted[0]) {
                .parameter => |parameter| parameter,
                else => null,
            } else null,
            else => null,
        } else null,
        .declaration_array_assignment => null,
    };
}

fn singleUnquotedParameter(word: ast.Word) ?ast.ParameterExpansion {
    return switch (word.data) {
        .literal => null,
        .parts => |parts| if (parts.len == 1) switch (parts[0]) {
            .parameter => |parameter| parameter,
            else => null,
        } else null,
        .declaration_array_assignment => null,
    };
}

fn appendUnquotedAtFields(shell: anytype, fields: *std.ArrayList([]const u8), word: ast.Word) !bool {
    if (!wordIsUnquotedAt(word)) return false;
    try appendUnquotedPositionalFields(shell, fields);
    return true;
}

fn appendUnquotedStarFields(shell: anytype, fields: *std.ArrayList([]const u8), word: ast.Word) !bool {
    if (!wordIsUnquotedStar(word)) return false;
    try appendUnquotedPositionalFields(shell, fields);
    return true;
}

fn appendUnquotedArrayIndexFields(shell: anytype, fields: *std.ArrayList([]const u8), word: ast.Word) !bool {
    const parameter = singleUnquotedParameter(word) orelse return false;
    if (!parameter.array_indices or parameter.parameter != .array) return false;
    const array_parameter = parameter.parameter.array;
    switch (array_parameter.subscript) {
        .all => {},
        .index => return false,
    }
    const array = shell.state.getArray(array_parameter.name) orelse return true;
    for (array.elements) |element| {
        try fields.append(shell.scratchAllocator(), try std.fmt.allocPrint(
            shell.scratchAllocator(),
            "{}",
            .{element.index},
        ));
    }
    return true;
}

fn appendEmbeddedUnquotedPositionalFields(shell: anytype, fields: *std.ArrayList([]const u8), word: ast.Word) !bool {
    const parts = switch (word.data) {
        .literal => return false,
        .parts => |parts| parts,
        .declaration_array_assignment => return false,
    };
    if (parts.len < 2) return false;

    var has_positional = false;
    for (parts) |part| switch (part) {
        .literal => {},
        .parameter => |parameter| {
            if (!isUnquotedPositionalListParameter(parameter)) return false;
            has_positional = true;
        },
        else => return false,
    };
    if (!has_positional) return false;

    const allocator = shell.scratchAllocator();
    var logical_fields: std.ArrayList([]const u8) = .empty;
    try logical_fields.append(allocator, "");
    for (parts) |part| switch (part) {
        .literal => |literal| try appendTextToLastField(shell, &logical_fields, literal),
        .parameter => {
            const positionals = shell.state.positionals;
            if (positionals.len == 0) continue;
            try appendTextToLastField(shell, &logical_fields, positionals[0]);
            if (positionals.len > 1) try logical_fields.appendSlice(allocator, positionals[1..]);
        },
        else => unreachable,
    };

    for (logical_fields.items) |field| try appendSplitFields(shell, fields, field, true);
    return true;
}

fn isUnquotedPositionalListParameter(parameter: ast.ParameterExpansion) bool {
    return parameter.op == null and parameter.parameter == .special and switch (parameter.parameter.special) {
        .at, .star => true,
        else => false,
    };
}

fn appendUnquotedPositionalFields(shell: anytype, fields: *std.ArrayList([]const u8)) !void {
    const preserve_empty = ifsHasNonWhitespaceDelimiter(parameterValue(shell, "IFS") orelse " \t\n");
    for (shell.state.positionals) |positional| {
        if (positional.len == 0 and preserve_empty) {
            try fields.append(shell.scratchAllocator(), "");
        } else {
            try appendSplitFields(shell, fields, positional, true);
        }
    }
}

fn wordIsUnquotedAt(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| parts.len == 1 and switch (parts[0]) {
            .parameter => |parameter| !parameter.length and parameter.op == null and parameter.parameter == .special and
                parameter.parameter.special == .at,
            else => false,
        },
        .declaration_array_assignment => false,
    };
}

fn wordIsUnquotedStar(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| parts.len == 1 and switch (parts[0]) {
            .parameter => |parameter| !parameter.length and parameter.op == null and parameter.parameter == .special and
                parameter.parameter.special == .star,
            else => false,
        },
        .declaration_array_assignment => false,
    };
}

fn wordIsQuotedAt(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| parts.len == 1 and switch (parts[0]) {
            .double_quoted => |quoted| quoted.len == 1 and switch (quoted[0]) {
                // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                .parameter => |parameter| !parameter.length and parameter.op == null and parameter.parameter == .special and
                    parameter.parameter.special == .at,
                else => false,
            },
            else => false,
        },
        .declaration_array_assignment => false,
    };
}

fn wordIsQuotedStar(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| parts.len == 1 and switch (parts[0]) {
            .double_quoted => |quoted| quoted.len == 1 and switch (quoted[0]) {
                // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                .parameter => |parameter| !parameter.length and parameter.op == null and parameter.parameter == .special and
                    parameter.parameter.special == .star,
                else => false,
            },
            else => false,
        },
        .declaration_array_assignment => false,
    };
}

fn wordIsAtParameter(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| parts.len == 1 and switch (parts[0]) {
            .parameter => |parameter| !parameter.length and parameter.op == null and parameter.parameter == .special and
                parameter.parameter.special == .at,
            .double_quoted => |quoted| quoted.len == 1 and switch (quoted[0]) {
                // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                .parameter => |parameter| !parameter.length and parameter.op == null and parameter.parameter == .special and
                    parameter.parameter.special == .at,
                else => false,
            },
            else => false,
        },
        .declaration_array_assignment => false,
    };
}

fn atExpansionParts(word: ast.Word) ?[]const ast.WordPart {
    return switch (word.data) {
        .literal => null,
        .parts => |parts| if (wordPartsContainAtParameter(parts))
            parts
        else if (parts.len == 1) switch (parts[0]) {
            .double_quoted => |quoted| if (wordPartsContainAtParameter(quoted)) quoted else null,
            else => null,
        } else null,
        .declaration_array_assignment => null,
    };
}

fn evalCase(shell: anytype, command: ast.CaseCommand) EvalError!result.EvalResult {
    validateAst(command);
    const scratch = try shell.beginScratchScope();
    defer scratch.end();

    const word = try expandWord(shell, command.word);
    var execute_next = false;
    for (command.arms) |arm| {
        const matches = execute_next or try caseArmMatches(shell, arm, word);
        if (!matches) continue;

        const evaluated = try evalList(shell, arm.body);
        if (evaluated.flow != .normal) return evaluated;
        switch (arm.fallthrough) {
            .none => return evaluated,
            .execute_next => execute_next = true,
            .test_next => execute_next = false,
        }
    }
    return .{ .status = 0 };
}

fn caseArmMatches(shell: anytype, arm: ast.CaseArm, word: []const u8) EvalError!bool {
    for (arm.patterns) |pattern_word| {
        const pattern = try expandPatternWord(shell, pattern_word);
        if (pattern_mod.matchesText(pattern, word)) return true;
    }
    return false;
}

fn evalFunctionDefinition(shell: anytype, definition: ast.FunctionDefinition) EvalError!result.EvalResult {
    validateAst(definition);
    const copied = try ast_copy.copyFunction(
        shell.state.definitionAllocator(),
        definition,
        shell.state.current_source_name,
    );
    validateAst(copied.definition);
    const function: state_mod.Function = .{
        .name = copied.name,
        .source_name = copied.source_name,
        .source_text = copied.name,
        .definition = copied.definition,
    };
    try shell.state.putPersistentFunction(function);
    return .{};
}

fn evalSimple(shell: anytype, command: ast.SimpleCommand) EvalError!result.EvalResult {
    validateAst(command);
    const scratch = try shell.beginScratchScope();
    defer scratch.end();

    return evalSimpleScoped(shell, command) catch |err| switch (err) {
        error.AssignmentError => .{ .status = 1, .flow = .{ .fatal = 1 } },
        error.ExpansionError => .{ .status = 1, .flow = .{ .fatal = 1 } },
        error.FatalExpansionError => {
            const status = bashFatalExpansionStatus(shell);
            try shell.host.writeAll(.stderr, "expansion error\n");
            return .{ .status = status, .flow = .{ .exit = status } };
        },
        error.InvalidArithmetic => {
            try shell.host.writeAll(.stderr, "arithmetic expansion error\n");
            return .{ .status = 1, .flow = .{ .fatal = 1 } };
        },
        error.BadFd, error.BrokenPipe, error.InputOutput, error.WouldBlock => .{ .status = 1 },
        else => return err,
    };
}

fn bashFatalExpansionStatus(shell: anytype) result.ExitStatus {
    if (shell.state.options.interactive) return 1;
    if (shell.state.root_source_kind == .command_string) return 127;
    return 1;
}

fn redirectionFailure(shell: anytype, fatal: bool) result.EvalResult {
    // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
    shell.host.writeAll(.stderr, "redirection failed\n") catch {};
    return .{ .status = 1, .flow = if (fatal) .{ .fatal = 1 } else .normal };
}

fn writeReadonlyDiagnostic(shell: anytype, name: []const u8) !void {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    try shell.host.writeAll(.stderr, try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: readonly variable\n", .{name}));
}

fn evalSimpleScoped(shell: anytype, command: ast.SimpleCommand) EvalError!result.EvalResult {
    if (command.words.len == 0 and command.assignments.len != 0) {
        const expanded_assignments = try expandAndApplyAssignments(shell, command.assignments);
        const has_redirections = command.redirections.len != 0;
        var redirections: AppliedRedirections = if (has_redirections)
            applyRedirections(shell, command.redirections) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return redirectionFailure(shell, false),
            }
        else
            .{ .frames = &.{}, .here_doc_writers = &.{} };
        defer if (has_redirections) redirections.restore(shell) catch {};

        try traceSimpleCommand(shell, expanded_assignments, &.{});
        const status = assignmentExpansionStatus(expanded_assignments);
        return .{ .status = status };
    }

    const has_redirections = command.redirections.len != 0;
    var redirections: AppliedRedirections = if (has_redirections)
        applyRedirections(shell, command.redirections) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return redirectionFailure(shell, simpleRedirectionFailureIsFatal(shell, command)),
        }
    else
        .{ .frames = &.{}, .here_doc_writers = &.{} };
    var restore_redirections = true;
    defer if (restore_redirections and has_redirections) redirections.restore(shell) catch {};

    if (command.words.len == 0) {
        return .{};
    }

    if (try staticDeclarationBuiltinName(shell, command.words[0])) |id| {
        if (id == .declare or id == .export_ or id == .readonly or id == .typeset or id == .local) {
            try applyAssignments(shell, command.assignments);
            return evalDeclarationBuiltin(shell, id, command.words[1..]);
        }
    }

    var expansion_status: ?result.ExitStatus = null;
    const fields = try expandWordFields(shell, command.words, &expansion_status);
    if (fields.len == 0) {
        const status = try applyAssignmentsWithStatus(shell, command.assignments);
        return .{ .status = expansion_status orelse status };
    }
    try traceSimpleCommand(shell, &.{}, fields);
    const name = fields[0];
    const builtin_definition = lookupBuiltin(shell, name);
    if (builtin_definition) |definition| {
        if (definition.kind == .special) {
            const saved_assignments = if (shell.state.options.mode == .bash)
                try saveAssignmentVariables(shell, command.assignments)
            else
                &[_]SavedVariable{};
            var restore_assignments = shell.state.options.mode == .bash;
            defer if (restore_assignments) restoreVariables(shell, saved_assignments);
            errdefer if (restore_assignments) {
                restoreVariables(shell, saved_assignments);
                restore_assignments = false;
            };
            if (shell.state.options.mode == .bash) {
                try applyAssignmentsIgnoringReadonly(shell, command.assignments);
            } else {
                try applyAssignments(shell, command.assignments);
            }
            if (definition.id == .declare or definition.id == .export_ or
                definition.id == .readonly or definition.id == .typeset or definition.id == .local)
            {
                return evalDeclarationBuiltin(shell, definition.id, command.words[1..]);
            }
            if (definition.id == .dot) return evalDotBuiltin(shell, fields);
            if (definition.id == .eval) return evalEvalBuiltin(shell, fields);
            if (definition.id == .exec) {
                restore_redirections = false;
                if (has_redirections) try redirections.commit(shell);
                if (fields.len == 1) return .{};
                return evalExecBuiltin(shell, fields, command.assignments);
            }
            if ((definition.id == .break_ or definition.id == .continue_) and shell.state.loop_depth == 0) {
                return .{ .status = 2 };
            }
            const args = switch (definition.id) {
                .break_, .continue_, .exit, .return_, .set, .shift, .trap, .unset => fields,
                else => &[_][]const u8{name},
            };
            return fatalSpecialBuiltinError(definition, try builtin.eval(shell, definition, args));
        }
    }
    if (name.len == 0) return .{ .status = 127 };
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (shell.state.getFunction(name)) |function| return evalFunction(shell, function, command.assignments, fields[1..]);
    if (try shell.tryAutoloadFunction(name)) {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        if (shell.state.getFunction(name)) |function| return evalFunction(shell, function, command.assignments, fields[1..]);
    }
    if (builtin_definition) |definition| {
        if (definition.id == .declare or definition.id == .typeset) {
            return evalDeclarationBuiltin(shell, definition.id, command.words[1..]);
        }
        if (definition.id == .cd) return evalCdBuiltin(shell, fields);
        if (definition.id == .z) return evalZBuiltin(shell, fields);
        if (definition.id == .command) {
            return evalCommandBuiltin(shell, fields, command.assignments, &redirections, &restore_redirections);
        }
        if (definition.id == .source) return evalDotBuiltin(shell, fields);
        if (definition.id == .env) return evalEnvBuiltin(shell, fields, command.assignments);
        if (definition.id == .pwd) return evalPwdBuiltin(shell, fields);
        if (definition.id == .read) return evalReadBuiltin(shell, fields, command.assignments);
        if (definition.id == .test_ or definition.id == .bracket) {
            return evalTestBuiltin(shell, fields, command.assignments);
        }
        if (definition.id == .type) return evalTypeBuiltin(shell, fields);
        if (definition.id == .wait) return evalWaitBuiltin(shell, fields);
        return (try builtin.tryEval(shell, definition, fields)) orelse unreachable;
    }
    return evalExternal(shell, fields, command.assignments);
}

const ExpandedAssignment = struct {
    name: []const u8,
    value: []const u8,
    status: ?result.ExitStatus = null,
};

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn traceSimpleCommand(shell: anytype, assignments: []const ExpandedAssignment, fields: []const []const u8) EvalError!void {
    if (!shell.state.options.xtrace) return;
    if (assignments.len == 0 and fields.len == 0) return;

    const prefix = try expandXtracePrefix(shell);
    try shell.host.writeAll(.stderr, prefix);
    var needs_space = false;
    for (assignments) |assignment| {
        if (needs_space) try shell.host.writeAll(.stderr, " ");
        try shell.host.writeAll(.stderr, assignment.name);
        try shell.host.writeAll(.stderr, "=");
        try shell.host.writeAll(.stderr, assignment.value);
        needs_space = true;
    }
    for (fields) |field| {
        if (needs_space) try shell.host.writeAll(.stderr, " ");
        try shell.host.writeAll(.stderr, field);
        needs_space = true;
    }
    try shell.host.writeAll(.stderr, "\n");
}

fn expandXtracePrefix(shell: anytype) EvalError![]const u8 {
    const raw = if (shell.state.getVariable("PS4")) |variable| variable.value else "";
    if (raw.len == 0) return "";

    const saved_xtrace = shell.state.options.xtrace;
    const saved_status = shell.state.last_status;
    shell.state.options.xtrace = false;
    defer {
        shell.state.options.xtrace = saved_xtrace;
        shell.state.last_status = saved_status;
    }

    var output: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    var index: usize = 0;
    while (index < raw.len) {
        if (index + 1 < raw.len and raw[index] == '$' and raw[index + 1] == '(') {
            if (commandSubstitutionEnd(raw, index + 2)) |end| {
                const substitution: ast.CommandSubstitution = .{ .source_text = raw[index + 2 .. end] };
                try output.appendSlice(allocator, try expandCommandSubstitution(shell, substitution, null));
                index = end + 1;
                continue;
            }
        }
        try output.append(allocator, raw[index]);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn commandSubstitutionEnd(text: []const u8, start: usize) ?usize {
    var index = start;
    var depth: usize = 1;
    var single_quoted = false;
    var double_quoted = false;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '\\') {
            if (index + 1 < text.len) index += 1;
            continue;
        }
        if (!double_quoted and byte == '\'') {
            single_quoted = !single_quoted;
            continue;
        }
        if (!single_quoted and byte == '"') {
            double_quoted = !double_quoted;
            continue;
        }
        if (single_quoted) continue;
        if (index + 1 < text.len and byte == '$' and text[index + 1] == '(') {
            depth += 1;
            index += 1;
            continue;
        }
        if (byte == ')') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn simpleRedirectionFailureIsFatal(shell: anytype, command: ast.SimpleCommand) bool {
    if (command.words.len == 0) return false;
    const name = staticLiteralWord(command.words[0]) orelse return false;
    const definition = lookupBuiltin(shell, name) orelse return false;
    return definition.kind == .special;
}

fn fatalSpecialBuiltinError(definition: builtin.Definition, evaluated: result.EvalResult) result.EvalResult {
    if (definition.kind == .special and evaluated.flow == .normal and evaluated.status == 2) {
        return .{ .status = evaluated.status, .flow = .{ .fatal = evaluated.status } };
    }
    return evaluated;
}

fn suppressFatalFlow(evaluated: result.EvalResult) result.EvalResult {
    return if (evaluated.flow == .fatal)
        .{ .status = evaluated.status }
    else
        evaluated;
}

fn evalCdBuiltin(shell: anytype, args: []const []const u8) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    var physical = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "-L")) {
            physical = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-P")) {
            physical = true;
            continue;
        }
        break;
    }
    if (args.len - index > 1) return .{ .status = 2 };

    var print_new_dir = false;
    const target = if (index >= args.len) target: {
        break :target parameterValue(shell, "HOME") orelse return .{ .status = 1 };
    } else if (std.mem.eql(u8, args[index], "-")) target: {
        print_new_dir = true;
        break :target parameterValue(shell, "OLDPWD") orelse return .{ .status = 1 };
    } else target: {
        break :target try cdPathTarget(shell, args[index], &print_new_dir) orelse args[index];
    };

    return changeDirectoryBuiltin(shell, "cd", target, physical, print_new_dir, true);
}

fn evalZBuiltin(shell: anytype, args: []const []const u8) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    const index: usize = 1;
    if (args.len == 3 and std.mem.eql(u8, args[1], "--")) {
        return changeDirectoryBuiltin(shell, "z", args[2], false, false, false);
    }
    if (index >= args.len) {
        const home = parameterValue(shell, "HOME") orelse return .{ .status = 1 };
        return changeDirectoryBuiltin(shell, "z", home, false, false, false);
    }
    if (args.len == 2 and std.mem.eql(u8, args[index], "-")) {
        const old_pwd = parameterValue(shell, "OLDPWD") orelse {
            try shell.host.writeAll(.stderr, "zoxide: $OLDPWD is not set\n");
            return .{ .status = 1 };
        };
        return changeDirectoryBuiltin(shell, "z", old_pwd, false, false, false);
    }
    if (args.len == 2) {
        const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
            .pointer => |pointer| pointer.child,
            else => @TypeOf(shell.host),
        };
        if (comptime @hasDecl(HostType, "listDir")) {
            if (try pathIsDirectory(shell, args[index], .other)) {
                return changeDirectoryBuiltin(shell, "z", args[index], false, false, false);
            }
        }
    }

    if (comptime !@hasField(@TypeOf(shell.*), "command_history")) return .{ .status = 1 };
    const command_history = shell.command_history orelse {
        try shell.host.writeAll(.stderr, "z: no history available\n");
        return .{ .status = 1 };
    };
    const jump = command_history.jump orelse {
        try shell.host.writeAll(.stderr, "z: no directory history available\n");
        return .{ .status = 1 };
    };

    const allocator = shell.scratchAllocator();
    const current_dir = try currentLogicalDir(shell);
    const now = std.Io.Clock.real.now(command_history.io).toSeconds();
    const target = try jump(command_history.context, allocator, args[index..], current_dir, now) orelse {
        try writeZNoMatchDiagnostic(shell, args[index..]);
        return .{ .status = 1 };
    };
    defer allocator.free(target);
    return changeDirectoryBuiltin(shell, "z", target, false, false, false);
}

fn changeDirectoryBuiltin(
    shell: anytype,
    builtin_name: []const u8,
    initial_target: []const u8,
    physical: bool,
    print_new_dir: bool,
    allow_suggestion: bool,
) EvalError!result.EvalResult {
    const allocator = shell.scratchAllocator();
    const old_pwd = try currentLogicalDir(shell);
    var target = initial_target;
    shell.host.changeDir(target) catch |err| {
        target = if (allow_suggestion)
            try cdSuggestionRecoveryTarget(shell, builtin_name, target, err) orelse return .{ .status = 1 }
        else {
            try writeCdFailureDiagnostic(shell, builtin_name, target, err, null, .line);
            return .{ .status = 1 };
        };
        shell.host.changeDir(target) catch |recovery_err| {
            try writeCdFailureDiagnostic(shell, builtin_name, target, recovery_err, null, .line);
            return .{ .status = 1 };
        };
    };
    const new_pwd = if (physical) try shell.host.currentDir(allocator) else try logicalPath(allocator, old_pwd, target);
    shell.state.putVariable(.{ .name = "OLDPWD", .value = old_pwd, .exported = exportedFlag(shell, "OLDPWD") }) catch {
        return .{ .status = 1 };
    };
    shell.state.putVariable(.{ .name = "PWD", .value = new_pwd, .exported = exportedFlag(shell, "PWD") }) catch {
        return .{ .status = 1 };
    };
    if (comptime @hasDecl(@TypeOf(shell.*), "notifyDirectoryChange")) shell.notifyDirectoryChange(old_pwd, new_pwd);

    if (print_new_dir) try shell.host.writeAll(.stdout, try std.fmt.allocPrint(allocator, "{s}\n", .{new_pwd}));
    return .{};
}

fn writeZNoMatchDiagnostic(shell: anytype, terms: []const []const u8) !void {
    try shell.host.writeAll(.stderr, "z: no match for:");
    for (terms) |term| {
        try shell.host.writeAll(.stderr, " ");
        try shell.host.writeAll(.stderr, term);
    }
    try shell.host.writeAll(.stderr, "\n");
}

fn cdSuggestionRecoveryTarget(
    shell: anytype,
    builtin_name: []const u8,
    target: []const u8,
    err: anyerror,
) !?[]const u8 {
    const suggestion = if (err == error.FileNotFound and shell.state.options.interactive)
        try collectCdSuggestion(shell, target)
    else
        null;
    const mode: CdSuggestionDiagnosticMode = if (suggestion != null and cdCanReadInteractiveKey(shell))
        .confirm
    else
        .line;
    try writeCdFailureDiagnostic(shell, builtin_name, target, err, suggestion, mode);
    if (suggestion == null or mode != .confirm) return null;

    const accepted = if (readCdConfirmationKey(shell)) |key|
        key == 'y' or key == 'Y'
    else
        false;
    try shell.host.writeAll(.stderr, "\n");
    if (accepted) return suggestion;
    try writeCdFailureDiagnostic(shell, builtin_name, target, err, null, .line);
    return null;
}

const CdSuggestionDiagnosticMode = enum { line, confirm };

fn writeCdFailureDiagnostic(
    shell: anytype,
    builtin_name: []const u8,
    target: []const u8,
    err: anyerror,
    suggestion: ?[]const u8,
    mode: CdSuggestionDiagnosticMode,
) !void {
    const allocator = shell.scratchAllocator();
    const reason = cdFailureReason(err);

    var message: std.ArrayList(u8) = .empty;
    if (mode == .line) {
        try message.appendSlice(allocator, builtin_name);
        try message.appendSlice(allocator, ": ");
        try message.appendSlice(allocator, target);
        try message.appendSlice(allocator, ": ");
        try message.appendSlice(allocator, reason);
    }
    if (suggestion) |path| {
        if (mode == .line) try message.appendSlice(allocator, "; ");
        try message.appendSlice(allocator, "did you mean: ");
        const style = cdSuggestionDirectoryStyle(shell);
        try editor_render.appendUiStyleStart(allocator, &message, style);
        try message.appendSlice(allocator, path);
        try editor_render.appendUiStyleEnd(allocator, &message, style);
        try message.append(allocator, '?');
    }
    switch (mode) {
        .line => try message.append(allocator, '\n'),
        .confirm => try message.appendSlice(allocator, " [y,N] "),
    }
    try shell.host.writeAll(.stderr, message.items);
}

fn cdCanReadInteractiveKey(shell: anytype) bool {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    return comptime @hasDecl(HostType, "readInteractiveKey");
}

fn readCdConfirmationKey(shell: anytype) ?u8 {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (comptime !@hasDecl(HostType, "readInteractiveKey")) return null;
    return shell.host.readInteractiveKey(cd_suggestion_confirm_timeout_ms);
}

fn cdSuggestionDirectoryStyle(shell: anytype) editor_render.UiStyle {
    var style = (editor_render.UiTheme{}).directory;
    if (shell.state.getVariable("rush_style_directory")) |variable| {
        style = editor_render.parseUiStyle(variable.value) orelse style;
    }
    style.bold = true;
    return style;
}

fn cdFailureReason(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such directory",
        error.NotDir => "not a directory",
        error.AccessDenied => "permission denied",
        error.NameTooLong => "name too long",
        else => "cannot change directory",
    };
}

fn evalPwdBuiltin(shell: anytype, args: []const []const u8) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    var physical = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-P")) {
            physical = true;
        } else if (std.mem.eql(u8, arg, "-L")) {
            physical = false;
        } else {
            return .{ .status = 2 };
        }
    }

    const cwd = if (physical) try shell.host.currentDir(shell.scratchAllocator()) else try currentLogicalDir(shell);
    try shell.host.writeAll(.stdout, try std.fmt.allocPrint(shell.scratchAllocator(), "{s}\n", .{cwd}));
    return .{};
}

fn evalDotBuiltin(shell: anytype, args: []const []const u8) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    if (args.len == 1) return .{ .status = 2 };

    const path = try resolveDotPath(shell, args[1]) orelse {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try shell.host.writeAll(.stderr, try std.fmt.allocPrint(shell.scratchAllocator(), ".: {s}: not found\n", .{args[1]}));
        return .{ .status = 2, .flow = .{ .fatal = 2 } };
    };
    const script = readDotScript(shell, path) catch {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try shell.host.writeAll(.stderr, try std.fmt.allocPrint(shell.scratchAllocator(), ".: {s}: cannot open\n", .{path}));
        return .{ .status = 1, .flow = .{ .fatal = 1 } };
    };
    defer shell.allocator.free(script);

    const saved_positionals = try savePositionals(shell);
    defer freeSavedPositionals(shell, saved_positionals);
    var restored_positionals = false;
    errdefer if (!restored_positionals) restorePositionals(shell, saved_positionals) catch {};

    const keep_positional_changes = args.len > 2 and shell.state.options.mode == .bash;
    if (args.len > 2) try shell.state.setPositionals(args[2..]);

    const src: source_mod.Source = .{
        .id = 0,
        .kind = .sourced_file,
        .name = path,
        .text = script,
    };
    const evaluated = shell.evalSourceNested(src) catch |err| switch (err) {
        error.ExpectedCommand,
        error.ExpectedRedirectionTarget,
        error.InvalidParameterExpansion,
        error.UnclosedCommandSubstitution,
        error.UnclosedQuote,
        error.UnexpectedToken,
        => {
            try shell.host.writeAll(.stderr, ".: syntax error\n");
            return .{ .status = 2, .flow = .{ .fatal = 2 } };
        },
        else => return err,
    };
    if (!keep_positional_changes) try restorePositionals(shell, saved_positionals);
    restored_positionals = true;
    if (evaluated.flow == .return_) return .{ .status = evaluated.status };
    return evaluated;
}

fn readDotScript(shell: anytype, path: []const u8) ![]const u8 {
    const allocator = shell.allocator;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = try shell.host.openZ(path_z, .{ .access = .read_only });
    defer shell.host.close(fd) catch {};

    var output: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_len = try shell.host.read(fd, &buffer);
        if (read_len == 0) break;
        try output.appendSlice(allocator, buffer[0..read_len]);
    }
    return output.toOwnedSlice(allocator);
}

fn resolveDotPath(shell: anytype, operand: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, operand, '/') != null) return operand;

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const path = if (shell.state.getVariable("PATH")) |variable| variable.value else envPath(shell.env) orelse defaultUtilityPath();
    const allocator = shell.scratchAllocator();
    var candidate_buffer: std.ArrayList(u8) = .empty;
    var iterator = std.mem.splitScalar(u8, path, ':');
    while (iterator.next()) |directory| {
        candidate_buffer.clearRetainingCapacity();
        const prefix = if (directory.len == 0) "." else directory;
        try candidate_buffer.appendSlice(allocator, prefix);
        if (!std.mem.endsWith(u8, prefix, "/")) try candidate_buffer.append(allocator, '/');
        try candidate_buffer.appendSlice(allocator, operand);
        try candidate_buffer.append(allocator, 0);
        const candidate = candidate_buffer.items[0 .. candidate_buffer.items.len - 1 :0];
        if (shell.host.fileAccessZ(candidate, .read)) return candidate;
    }
    return null;
}

fn savePositionals(shell: anytype) ![]const []const u8 {
    const allocator = shell.allocator;
    const saved = try allocator.alloc([]const u8, shell.state.positionals.len);
    errdefer allocator.free(saved);
    var copied: usize = 0;
    errdefer for (saved[0..copied]) |positional| allocator.free(positional);
    for (shell.state.positionals, 0..) |positional, index| {
        saved[index] = try allocator.dupe(u8, positional);
        copied += 1;
    }
    return saved;
}

fn restorePositionals(shell: anytype, saved: []const []const u8) !void {
    try shell.state.setPositionals(saved);
}

fn freeSavedPositionals(shell: anytype, saved: []const []const u8) void {
    for (saved) |positional| shell.allocator.free(positional);
    shell.allocator.free(saved);
}

fn evalCommandBuiltin(
    shell: anytype,
    args: []const []const u8,
    assignments: []const ast.Assignment,
    redirections: *AppliedRedirections,
    restore_redirections: *bool,
) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    var use_default_path = false;
    var lookup_mode: CommandLookupMode = .none;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            'p' => use_default_path = true,
            'v' => lookup_mode = .terse,
            'V' => lookup_mode = .verbose,
            else => return .{ .status = 2 },
        };
    }
    if (index >= args.len) return .{};

    const saved = try saveAssignmentVariables(shell, assignments);
    var restored_assignments = false;
    errdefer if (!restored_assignments) restoreVariables(shell, saved);
    try applyAssignments(shell, assignments);

    const search_path: ?[]const u8 = if (use_default_path) defaultUtilityPath() else null;
    if (lookup_mode != .none) {
        const evaluated = try evalCommandLookup(shell, args[index..], lookup_mode, search_path);
        restoreVariables(shell, saved);
        restored_assignments = true;
        return evaluated;
    }

    const name = args[index];
    if (lookupBuiltin(shell, name)) |definition| {
        if ((definition.id == .break_ or definition.id == .continue_) and shell.state.loop_depth == 0) {
            restoreVariables(shell, saved);
            restored_assignments = true;
            return .{};
        }
        switch (definition.id) {
            .cd => {
                const evaluated = try evalCdBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .z => {
                const evaluated = try evalZBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .dot => {
                const evaluated = try evalDotBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return suppressFatalFlow(evaluated);
            },
            .source => {
                const evaluated = try evalDotBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .env => {
                const evaluated = try evalEnvBuiltin(shell, args[index..], assignments);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .eval => {
                const evaluated = try evalEvalBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return suppressFatalFlow(evaluated);
            },
            .exec => {
                restore_redirections.* = false;
                try redirections.commit(shell);
                if (index + 1 == args.len) return .{};
                return evalExecBuiltin(shell, args[index..], assignments);
            },
            .declare, .export_, .readonly, .typeset => {
                // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                const evaluated = try evalDeclarationBuiltin(shell, definition.id, commandFieldsAsWords(shell, args[index + 1 ..]) catch return error.OutOfMemory);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return suppressFatalFlow(evaluated);
            },
            .pwd => {
                const evaluated = try evalPwdBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .read => {
                const evaluated = try evalReadBuiltin(shell, args[index..], &.{});
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .test_, .bracket => {
                const evaluated = try evalTestBuiltin(shell, args[index..], assignments);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .type => {
                const evaluated = try evalTypeBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .wait => {
                const evaluated = try evalWaitBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .command => {
                // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                const evaluated = try evalCommandBuiltin(shell, args[index..], &.{}, redirections, restore_redirections);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            else => {
                const evaluated = (try builtin.tryEval(shell, definition, args[index..])) orelse unreachable;
                restoreVariables(shell, saved);
                restored_assignments = true;
                return suppressFatalFlow(evaluated);
            },
        }
    }
    const evaluated = try evalExternalWithSearchPath(shell, args[index..], assignments, search_path);
    restoreVariables(shell, saved);
    restored_assignments = true;
    return evaluated;
}

fn evalTestBuiltin(
    shell: anytype,
    args: []const []const u8,
    assignments: []const ast.Assignment,
) EvalError!result.EvalResult {
    _ = assignments;
    std.debug.assert(args.len != 0);
    const operands = testOperands(args) catch |err| {
        try writeTestDiagnostic(shell, args[0], err);
        return .{ .status = 2 };
    };
    const matches = evalTestOperands(shell, operands) catch |err| {
        switch (err) {
            error.Syntax => {
                try writeTestDiagnostic(shell, args[0], error.Syntax);
                return .{ .status = 2 };
            },
            error.Integer => {
                try writeTestDiagnostic(shell, args[0], error.Integer);
                return .{ .status = 2 };
            },
            else => return err,
        }
    };
    return .{ .status = if (matches) 0 else 1 };
}

const TestEvalError = error{
    Syntax,
    Integer,
};

fn testOperands(args: []const []const u8) TestEvalError![]const []const u8 {
    if (std.mem.eql(u8, args[0], "[")) {
        if (args.len < 2 or !std.mem.eql(u8, args[args.len - 1], "]")) return error.Syntax;
        return args[1 .. args.len - 1];
    }
    std.debug.assert(std.mem.eql(u8, args[0], "test"));
    return args[1..];
}

fn evalTestOperands(shell: anytype, args: []const []const u8) EvalError!bool {
    return switch (args.len) {
        0 => false,
        1 => args[0].len != 0,
        2 => evalTwoArgumentTest(shell, args[0], args[1]),
        3 => evalThreeArgumentTest(shell, args[0], args[1], args[2]),
        4 => if (std.mem.eql(u8, args[0], "!"))
            !try evalThreeArgumentTest(shell, args[1], args[2], args[3])
        else
            error.Syntax,
        else => error.Syntax,
    };
}

fn evalTwoArgumentTest(shell: anytype, operator: []const u8, operand: []const u8) EvalError!bool {
    if (std.mem.eql(u8, operator, "!")) return operand.len == 0;
    if (std.mem.eql(u8, operator, "-n")) return operand.len != 0;
    if (std.mem.eql(u8, operator, "-z")) return operand.len == 0;
    return (try evalFileUnaryTest(shell, operator, operand)) orelse error.Syntax;
}

fn evalThreeArgumentTest(shell: anytype, left: []const u8, operator: []const u8, right: []const u8) EvalError!bool {
    if (std.mem.eql(u8, operator, "=")) return std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, operator, "!=")) return !std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, operator, ">")) return std.mem.order(u8, left, right) == .gt;
    if (std.mem.eql(u8, operator, "<")) return std.mem.order(u8, left, right) == .lt;
    if (std.mem.eql(u8, left, "!")) {
        return !try evalTwoArgumentTest(shell, operator, right);
    }

    if (try evalFileBinaryTest(shell, left, operator, right)) |matches| return matches;
    if (try evalIntegerComparison(shell, left, operator, right)) |matches| return matches;
    return error.Syntax;
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn evalIntegerComparison(shell: anytype, left: []const u8, operator: []const u8, right: []const u8) TestEvalError!?bool {
    if (!isIntegerComparisonOperator(operator)) return null;
    const lhs_text = testIntegerOperand(shell, left);
    const rhs_text = testIntegerOperand(shell, right);
    const lhs = std.fmt.parseInt(i64, lhs_text, 10) catch return error.Integer;
    const rhs = std.fmt.parseInt(i64, rhs_text, 10) catch return error.Integer;
    if (std.mem.eql(u8, operator, "-eq")) return lhs == rhs;
    if (std.mem.eql(u8, operator, "-ne")) return lhs != rhs;
    if (std.mem.eql(u8, operator, "-gt")) return lhs > rhs;
    if (std.mem.eql(u8, operator, "-ge")) return lhs >= rhs;
    if (std.mem.eql(u8, operator, "-lt")) return lhs < rhs;
    if (std.mem.eql(u8, operator, "-le")) return lhs <= rhs;
    unreachable;
}

fn testIntegerOperand(shell: anytype, operand: []const u8) []const u8 {
    if (shell.state.options.mode == .posix) return operand;
    return std.mem.trim(u8, operand, " \t\n\r");
}

fn isIntegerComparisonOperator(operator: []const u8) bool {
    return std.mem.eql(u8, operator, "-eq") or
        std.mem.eql(u8, operator, "-ne") or
        std.mem.eql(u8, operator, "-gt") or
        std.mem.eql(u8, operator, "-ge") or
        std.mem.eql(u8, operator, "-lt") or
        std.mem.eql(u8, operator, "-le");
}

fn evalFileUnaryTest(shell: anytype, operator: []const u8, operand: []const u8) EvalError!?bool {
    if (std.mem.eql(u8, operator, "-t")) return evalTerminalTest(shell, operand);
    if (std.mem.eql(u8, operator, "-r")) return try fileAccess(shell, operand, .read);
    if (std.mem.eql(u8, operator, "-w")) return try fileAccess(shell, operand, .write);
    if (std.mem.eql(u8, operator, "-x")) return try fileAccess(shell, operand, .execute);

    const follow_symlinks = !std.mem.eql(u8, operator, "-h") and !std.mem.eql(u8, operator, "-L");
    const status = try fileStatus(shell, operand, follow_symlinks);
    if (std.mem.eql(u8, operator, "-b")) return if (status) |st| st.kind == .block_device else false;
    if (std.mem.eql(u8, operator, "-c")) return if (status) |st| st.kind == .character_device else false;
    if (std.mem.eql(u8, operator, "-d")) return if (status) |st| st.kind == .directory else false;
    if (std.mem.eql(u8, operator, "-e")) return status != null;
    if (std.mem.eql(u8, operator, "-f")) return if (status) |st| st.kind == .file else false;
    if (std.mem.eql(u8, operator, "-g")) return if (status) |st| st.mode & 0o2000 != 0 else false;
    if (std.mem.eql(u8, operator, "-h")) return if (status) |st| st.kind == .symlink else false;
    if (std.mem.eql(u8, operator, "-L")) return if (status) |st| st.kind == .symlink else false;
    if (std.mem.eql(u8, operator, "-p")) return if (status) |st| st.kind == .named_pipe else false;
    if (std.mem.eql(u8, operator, "-S")) return if (status) |st| st.kind == .socket else false;
    if (std.mem.eql(u8, operator, "-s")) return if (status) |st| st.size > 0 else false;
    if (std.mem.eql(u8, operator, "-u")) return if (status) |st| st.mode & 0o4000 != 0 else false;
    return null;
}

fn evalFileBinaryTest(shell: anytype, left: []const u8, operator: []const u8, right: []const u8) EvalError!?bool {
    if (std.mem.eql(u8, operator, "-ef")) {
        const lhs = try fileStatus(shell, left, true) orelse return false;
        const rhs = try fileStatus(shell, right, true) orelse return false;
        return lhs.sameFile(rhs);
    }
    if (std.mem.eql(u8, operator, "-nt")) {
        const lhs = try fileStatus(shell, left, true) orelse return false;
        const rhs = try fileStatus(shell, right, true) orelse return true;
        return lhs.newerThan(rhs);
    }
    if (std.mem.eql(u8, operator, "-ot")) {
        const lhs = try fileStatus(shell, left, true);
        const rhs = try fileStatus(shell, right, true) orelse return false;
        return if (lhs) |status| status.olderThan(rhs) else true;
    }
    return null;
}

fn evalTerminalTest(shell: anytype, operand: []const u8) bool {
    const fd = std.fmt.parseInt(i32, operand, 10) catch return false;
    return shell.host.isTerminalFd(@enumFromInt(fd));
}

fn fileStatus(shell: anytype, path: []const u8, follow_symlinks: bool) !?host_mod.FileStatus {
    if (path.len == 0) return null;
    const path_z = try shell.scratchAllocator().dupeZ(u8, path);
    return shell.host.fileTestStatusZ(path_z, follow_symlinks);
}

fn fileAccess(shell: anytype, path: []const u8, access: host_mod.FileAccess) !bool {
    if (path.len == 0) return false;
    const path_z = try shell.scratchAllocator().dupeZ(u8, path);
    return shell.host.fileAccessZ(path_z, access);
}

fn writeTestDiagnostic(shell: anytype, name: []const u8, err: TestEvalError) !void {
    const message = switch (err) {
        error.Syntax => "invalid expression",
        error.Integer => "integer expression expected",
    };
    try shell.host.writeAll(.stderr, name);
    try shell.host.writeAll(.stderr, ": ");
    try shell.host.writeAll(.stderr, message);
    try shell.host.writeAll(.stderr, "\n");
}

fn evalCommandLookup(
    shell: anytype,
    names: []const []const u8,
    mode: CommandLookupMode,
    search_path: ?[]const u8,
) !result.EvalResult {
    var status: result.ExitStatus = 0;
    for (names) |name| {
        if (try commandLookupText(shell, name, mode, search_path)) |text| {
            try shell.host.writeAll(.stdout, text);
            try shell.host.writeAll(.stdout, "\n");
        } else {
            status = 1;
        }
    }
    return .{ .status = status };
}

fn commandLookupText(shell: anytype, name: []const u8, mode: CommandLookupMode, search_path: ?[]const u8) !?[]const u8 {
    const allocator = shell.scratchAllocator();
    if (shell.state.getAlias(name)) |alias| {
        return if (mode == .verbose)
            try std.fmt.allocPrint(allocator, "{s} is an alias for {s}", .{ name, alias.value })
        else
            try std.fmt.allocPrint(allocator, "alias {s}='{s}'", .{ name, alias.value });
    }
    if (shell.state.getFunction(name) != null) {
        return if (mode == .verbose) try std.fmt.allocPrint(allocator, "{s} is a shell function", .{name}) else name;
    }
    if (isCommandLookupReservedWord(name)) {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        return if (mode == .verbose) try std.fmt.allocPrint(allocator, "{s} is a shell reserved word", .{name}) else name;
    }
    if (lookupBuiltin(shell, name) != null) {
        return if (mode == .verbose) try std.fmt.allocPrint(allocator, "{s} is a shell builtin", .{name}) else name;
    }
    if (try findCommandPath(shell, name, search_path)) |path| {
        return if (mode == .verbose) try std.fmt.allocPrint(allocator, "{s} is {s}", .{ name, path }) else path;
    }
    return null;
}

const command_lookup_operator_reserved_words = std.StaticStringMap(void).initComptime(.{
    .{ "!", {} },
    .{ "{", {} },
    .{ "}", {} },
});

fn isCommandLookupReservedWord(name: []const u8) bool {
    return token_mod.lookupReservedWord(name) != null or command_lookup_operator_reserved_words.has(name);
}

fn commandFieldsAsWords(shell: anytype, fields: []const []const u8) ![]const ast.Word {
    const words = try shell.scratchAllocator().alloc(ast.Word, fields.len);
    for (fields, 0..) |field, index| words[index] = .{ .data = .{ .literal = field } };
    return words;
}

fn evalTypeBuiltin(shell: anytype, args: []const []const u8) !result.EvalResult {
    std.debug.assert(args.len != 0);
    const parsed = parseTypeOptions(args) orelse return .{ .status = 2 };
    if (parsed.index >= args.len) return .{ .status = 2 };

    var status: result.ExitStatus = 0;
    for (args[parsed.index..]) |name| {
        const found = try typeLookup(shell, name, parsed.options);
        if (!found) status = 1;
    }
    return .{ .status = status };
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn evalEnvBuiltin(shell: anytype, args: []const []const u8, assignments: []const ast.Assignment) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    var index: usize = 1;
    if (index < args.len and std.mem.eql(u8, args[index], "--")) index += 1;

    const first_env_operand = index;
    while (index < args.len and envOperandAssignment(args[index]) != null) index += 1;
    const env_operands = args[first_env_operand..index];

    if (index < args.len and args[index].len != 0 and args[index][0] == '-') return .{ .status = 2 };

    const env_entries = try makeEnvBuiltinEntries(shell, assignments, env_operands);
    const envp = try makeEnvpFromEntries(shell, env_entries);
    if (index >= args.len) {
        for (envp) |maybe_entry| {
            const entry = std.mem.span(maybe_entry.?);
            try shell.host.writeAll(.stdout, entry);
            try shell.host.writeAll(.stdout, "\n");
        }
        return .{};
    }

    const fields = args[index..];
    if (fields[0].len == 0) return .{ .status = 127 };
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const search_path = envEntriesPath(env_entries) orelse if (shell.state.getVariable("PATH")) |variable| variable.value else envPath(shell.env) orelse defaultUtilityPath();
    const command_path = try findCommandPath(shell, fields[0], search_path) orelse {
        try writeCommandNotFoundDiagnostic(shell, fields[0], search_path);
        return .{ .status = 127 };
    };
    const argv = try makeExecArgv(shell, fields);
    const command_text = std.mem.span(argv[0].?);
    const command = argv[0].?[0..command_text.len :0];
    const path = if (std.mem.indexOfScalar(u8, command, '/') != null)
        command
    else
        try shell.scratchAllocator().dupeZ(u8, command_path);
    const request: host_mod.SpawnRequest = .{
        .path = path,
        .argv = argv,
        .fallback_argv = try makeShellFallbackArgv(shell, path, fields[1..]),
        .envp = envp,
        .default_signals = if (shell.state.options.monitor) &job_control_signals else &.{},
    };
    const waited = try shell.host.spawnAndWait(request);
    return .{ .status = waited.shellStatus() };
}

fn makeEnvBuiltinEntries(
    shell: anytype,
    assignments: []const ast.Assignment,
    env_operands: []const []const u8,
) ![]const AssignmentEnvEntry {
    const allocator = shell.scratchAllocator();
    const exported_count = countExportedVariables(shell);
    const entries = try allocator.alloc(AssignmentEnvEntry, exported_count + assignments.len + env_operands.len);
    var entry_count: usize = 0;
    var variable_iterator = shell.state.bindings.iterator();
    while (variable_iterator.next()) |entry| {
        const variable = entry.value_ptr.variable() orelse continue;
        if (!variable.exported) continue;
        entries[entry_count] = .{ .name = variable.name, .value = variable.value };
        entry_count += 1;
    }
    for (assignments) |assignment| {
        const value = try expandEnvBuiltinAssignmentValue(shell, entries[0..entry_count], assignment);
        try validateAssignment(shell, assignment.name, value);
        entries[entry_count] = .{
            .name = assignment.name,
            .value = value,
        };
        entry_count += 1;
    }
    for (env_operands) |operand| {
        const env_assignment = envOperandAssignment(operand).?;
        entries[entry_count] = env_assignment;
        entry_count += 1;
    }
    std.debug.assert(entry_count == entries.len);
    return entries;
}

fn expandEnvBuiltinAssignmentValue(
    shell: anytype,
    entries: []const AssignmentEnvEntry,
    assignment: ast.Assignment,
) ![]const u8 {
    const value = try expandAssignmentWordTracking(shell, assignment.value, null);
    if (!assignment.append) return value;
    const existing = envEntryValue(entries, assignment.name) orelse
        if (shell.state.getVariable(assignment.name)) |variable| variable.value else "";
    return std.mem.concat(shell.scratchAllocator(), u8, &.{ existing, value });
}

fn envOperandAssignment(operand: []const u8) ?AssignmentEnvEntry {
    const equals = std.mem.indexOfScalar(u8, operand, '=') orelse return null;
    return .{ .name = operand[0..equals], .value = operand[equals + 1 ..] };
}

fn envEntryValue(entries: []const AssignmentEnvEntry, name: []const u8) ?[]const u8 {
    var index = entries.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, entries[index].name, name)) return entries[index].value;
    }
    return null;
}

fn envEntriesPath(entries: []const AssignmentEnvEntry) ?[]const u8 {
    var index = entries.len;
    while (index != 0) {
        index -= 1;
        if (std.mem.eql(u8, entries[index].name, "PATH")) return entries[index].value;
    }
    return null;
}

const TypeOptions = struct {
    all: bool = false,
    no_functions: bool = false,
    path_only: bool = false,
    force_path: bool = false,
    kind_only: bool = false,
};

const ParsedTypeOptions = struct {
    options: TypeOptions,
    index: usize,
};

fn parseTypeOptions(args: []const []const u8) ?ParsedTypeOptions {
    var options: TypeOptions = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            'a' => options.all = true,
            'f' => options.no_functions = true,
            'p' => options.path_only = true,
            'P' => options.force_path = true,
            't' => options.kind_only = true,
            else => return null,
        };
    }
    return .{ .options = options, .index = index };
}

fn typeLookup(shell: anytype, name: []const u8, options: TypeOptions) !bool {
    var found = false;
    const skip_shell_constructs = options.path_only or options.force_path;

    if (!skip_shell_constructs) {
        if (shell.state.getAlias(name)) |alias| {
            try writeTypeAlias(shell, name, alias.value, options.kind_only);
            found = true;
            if (!options.all) return true;
        }
        if (!options.no_functions and shell.state.getFunction(name) != null) {
            try writeTypeMatch(shell, name, "function", "shell function", options.kind_only);
            found = true;
            if (!options.all) return true;
        }
        if (isCommandLookupReservedWord(name)) {
            try writeTypeMatch(shell, name, "keyword", "shell reserved word", options.kind_only);
            found = true;
            if (!options.all) return true;
        }
        if (lookupBuiltin(shell, name) != null) {
            try writeTypeMatch(shell, name, "builtin", "shell builtin", options.kind_only);
            found = true;
            if (!options.all) return true;
        }
    }

    if (try findCommandPath(shell, name, null)) |path| {
        if (options.kind_only) {
            try shell.host.writeAll(.stdout, "file\n");
        } else if (options.path_only or options.force_path) {
            try shell.host.writeAll(.stdout, path);
            try shell.host.writeAll(.stdout, "\n");
        } else {
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            try shell.host.writeAll(.stdout, try std.fmt.allocPrint(shell.scratchAllocator(), "{s} is {s}\n", .{ name, path }));
        }
        found = true;
    }
    return found;
}

fn writeTypeAlias(shell: anytype, name: []const u8, value: []const u8, kind_only: bool) !void {
    if (kind_only) {
        try shell.host.writeAll(.stdout, "alias\n");
        return;
    }
    try shell.host.writeAll(
        .stdout,
        try std.fmt.allocPrint(shell.scratchAllocator(), "{s} is aliased to `{s}'\n", .{ name, value }),
    );
}

fn writeTypeMatch(shell: anytype, name: []const u8, kind: []const u8, verbose_kind: []const u8, kind_only: bool) !void {
    if (kind_only) {
        try shell.host.writeAll(.stdout, kind);
        try shell.host.writeAll(.stdout, "\n");
        return;
    }
    try shell.host.writeAll(
        .stdout,
        try std.fmt.allocPrint(shell.scratchAllocator(), "{s} is a {s}\n", .{ name, verbose_kind }),
    );
}

fn evalWaitBuiltin(shell: anytype, args: []const []const u8) !result.EvalResult {
    std.debug.assert(args.len != 0);
    if (args.len == 1) {
        var status: result.ExitStatus = 0;
        for (shell.state.background_pids.items) |pid| {
            const waited = shell.host.waitInterruptible(pid) catch continue;
            status = waited.shellStatus();
            if (status > 128) break;
        }
        shell.state.clearBackgroundPids();
        return .{ .status = status };
    }

    var status: result.ExitStatus = 0;
    for (args[1..]) |arg| {
        if (waitOperandJob(shell, arg)) |job| {
            status = try waitBackgroundJob(shell, job);
            continue;
        }
        const pid = waitOperandPid(shell, arg) orelse {
            try shell.host.writeAll(.stderr, "wait: invalid pid\n");
            status = 1;
            continue;
        };
        if (!shell.state.removeBackgroundPid(pid)) {
            try shell.host.writeAll(.stderr, "wait: unknown pid\n");
            status = 127;
            continue;
        }
        const waited = shell.host.waitInterruptible(pid) catch {
            status = 127;
            continue;
        };
        status = waited.shellStatus();
    }
    return .{ .status = status };
}

fn waitBackgroundJob(shell: anytype, job: state_mod.BackgroundJob) !result.ExitStatus {
    const pids = try shell.scratchAllocator().dupe(host_mod.Pid, job.pids.items);
    defer shell.scratchAllocator().free(pids);
    var status: result.ExitStatus = 0;
    for (pids) |pid| {
        const waited = waitBackgroundJobPid(shell, pid) catch {
            status = 127;
            continue;
        };
        status = waited.shellStatus();
        switch (waited) {
            .stopped => {
                _ = shell.state.setBackgroundJobStatusByPid(pid, .stopped);
                return status;
            },
            else => {},
        }
        if (!shell.state.removeBackgroundPid(pid)) status = 127;
    }
    return status;
}

fn waitBackgroundJobPid(shell: anytype, pid: host_mod.Pid) !host_mod.WaitStatus {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (@hasDecl(HostType, "waitJobEventInterruptible")) return shell.host.waitJobEventInterruptible(pid);
    return shell.host.waitInterruptible(pid);
}

fn waitOperandJob(shell: anytype, arg: []const u8) ?state_mod.BackgroundJob {
    return shell.state.resolveJobSpec(arg);
}

fn waitOperandPid(shell: anytype, arg: []const u8) ?host_mod.Pid {
    _ = shell;
    return parseWaitPid(arg);
}

fn parseWaitPid(arg: []const u8) ?host_mod.Pid {
    if (arg.len == 0) return null;
    if (arg[0] == '%') return null;
    return std.fmt.parseInt(host_mod.Pid, arg, 10) catch null;
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn evalReadBuiltin(shell: anytype, args: []const []const u8, assignments: []const ast.Assignment) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    var options: ReadOptions = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (arg.len < 2 or arg[0] != '-') break;
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        var option_index: usize = 1;
        while (option_index < arg.len) : (option_index += 1) switch (arg[option_index]) {
            'a' => {
                if (shell.state.options.mode == .posix) return .{ .status = 2 };
                options.array_name = if (option_index + 1 < arg.len) name: {
                    defer option_index = arg.len;
                    break :name arg[option_index + 1 ..];
                } else name: {
                    index += 1;
                    if (index >= args.len) return .{ .status = 2 };
                    break :name args[index];
                };
                break;
            },
            'r' => options.raw = true,
            'd' => {
                if (option_index + 1 < arg.len) {
                    options.delimiter = arg[option_index + 1];
                    option_index = arg.len;
                } else {
                    index += 1;
                    if (index >= args.len or args[index].len == 0) return .{ .status = 2 };
                    options.delimiter = args[index][0];
                }
                break;
            },
            'n', 'N' => |option| {
                if (shell.state.options.mode == .posix) return .{ .status = 2 };
                const exact = option == 'N';
                const count_text = if (option_index + 1 < arg.len) count: {
                    defer option_index = arg.len;
                    break :count arg[option_index + 1 ..];
                } else count: {
                    index += 1;
                    if (index >= args.len) return .{ .status = 2 };
                    break :count args[index];
                };
                options.count = parseReadCount(count_text) orelse return .{ .status = 2 };
                options.exact_count = exact;
                break;
            },
            'p' => {
                if (shell.state.options.mode == .posix) return .{ .status = 2 };
                options.prompt = if (option_index + 1 < arg.len) prompt: {
                    defer option_index = arg.len;
                    break :prompt arg[option_index + 1 ..];
                } else prompt: {
                    index += 1;
                    if (index >= args.len) return .{ .status = 2 };
                    break :prompt args[index];
                };
                break;
            },
            's' => {
                if (shell.state.options.mode == .posix) return .{ .status = 2 };
                options.silent = true;
            },
            't' => {
                if (shell.state.options.mode == .posix) return .{ .status = 2 };
                const timeout_text = if (option_index + 1 < arg.len) timeout: {
                    defer option_index = arg.len;
                    break :timeout arg[option_index + 1 ..];
                } else timeout: {
                    index += 1;
                    if (index >= args.len) return .{ .status = 2 };
                    break :timeout args[index];
                };
                options.timeout_ms = parseReadTimeout(timeout_text) orelse return .{ .status = 2 };
                break;
            },
            else => return .{ .status = 2 },
        };
    }

    const names = if (index < args.len) args[index..] else &[_][]const u8{"REPLY"};
    if (options.array_name) |name| {
        if (!isAssignmentName(name)) return .{ .status = 2 };
    } else {
        for (names) |name| if (!isAssignmentName(name)) return .{ .status = 2 };
    }

    if (options.prompt) |prompt| {
        if (shell.host.isTerminalFd(.stdin)) try shell.host.writeAll(.stderr, prompt);
    }

    const saved_terminal_mode = if (options.silent) shell.host.disableTerminalEcho(.stdin) else null;
    defer if (saved_terminal_mode) |mode| shell.host.restoreTerminalMode(.stdin, mode);

    const line_result = try readBuiltinLine(shell, options);
    const saved = try saveAssignmentVariables(shell, assignments);
    var restored_assignments = false;
    errdefer if (!restored_assignments) restoreVariables(shell, saved);
    try applyAssignments(shell, assignments);
    const ifs = parameterValue(shell, "IFS") orelse " \t\n";
    if (options.array_name) |name| {
        const values = if (options.exact_count)
            try readExactFieldValues(shell, line_result.line, 1)
        else
            try readArrayFieldValues(shell, line_result.line, ifs);
        restoreVariables(shell, saved);
        restored_assignments = true;
        try shell.state.putArray(name, values);
        if (line_result.timed_out) return .{ .status = 142 };
        return .{ .status = if (line_result.found_delimiter) 0 else 1 };
    }
    const values = if (options.exact_count)
        try readExactFieldValues(shell, line_result.line, names.len)
    else
        try readFieldValues(shell, line_result.line, names.len, ifs);
    restoreVariables(shell, saved);
    restored_assignments = true;

    for (names, 0..) |name, name_index| {
        try shell.state.putVariable(.{ .name = name, .value = values[name_index] });
    }
    if (line_result.timed_out) return .{ .status = 142 };
    return .{ .status = if (line_result.found_delimiter) 0 else 1 };
}

const ReadOptions = struct {
    raw: bool = false,
    delimiter: u8 = '\n',
    count: ?usize = null,
    exact_count: bool = false,
    prompt: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    silent: bool = false,
    array_name: ?[]const u8 = null,
};

fn parseReadCount(text: []const u8) ?usize {
    if (text.len == 0) return null;
    return std.fmt.parseUnsigned(usize, text, 10) catch null;
}

fn parseReadTimeout(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var index: usize = 0;
    var seconds: u64 = 0;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {
        seconds = std.math.mul(u64, seconds, 10) catch return null;
        seconds = std.math.add(u64, seconds, text[index] - '0') catch return null;
    }

    var millis: u64 = std.math.mul(u64, seconds, 1000) catch return null;
    if (index < text.len) {
        if (text[index] != '.') return null;
        index += 1;
        var scale: u64 = 100;
        var saw_fraction = false;
        var saw_nonzero_fraction = false;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {
            saw_fraction = true;
            if (text[index] != '0') saw_nonzero_fraction = true;
            if (scale != 0) {
                millis = std.math.add(u64, millis, @as(u64, text[index] - '0') * scale) catch return null;
                scale /= 10;
            }
        }
        if (!saw_fraction) return null;
        if (millis == 0 and saw_nonzero_fraction) millis = 1;
    }
    if (index != text.len) return null;
    return millis;
}

const ReadLineResult = struct {
    line: []const u8,
    found_delimiter: bool,
    timed_out: bool = false,
};

const read_escape_marker: u8 = 0;

fn readBuiltinLine(shell: anytype, options: ReadOptions) !ReadLineResult {
    var line: std.ArrayList(u8) = .empty;
    if (options.count == 0) {
        return .{ .line = try line.toOwnedSlice(shell.scratchAllocator()), .found_delimiter = true };
    }
    if (options.timeout_ms == 0) return .{
        .line = try line.toOwnedSlice(shell.scratchAllocator()),
        .found_delimiter = shell.host.readReady(.stdin, 0),
    };

    var characters_read: usize = 0;
    while (true) {
        const first = (try readBuiltinByte(shell, options.timeout_ms)) orelse return .{
            .line = try line.toOwnedSlice(shell.scratchAllocator()),
            .found_delimiter = false,
        };
        if (first == .timeout) return .{
            .line = try line.toOwnedSlice(shell.scratchAllocator()),
            .found_delimiter = false,
            .timed_out = true,
        };
        const byte = first.byte;
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        if (!options.exact_count and byte == options.delimiter) {
            return .{ .line = try line.toOwnedSlice(shell.scratchAllocator()), .found_delimiter = true };
        }
        if (!options.raw and byte == '\\') {
            const escaped = (try readBuiltinByte(shell, options.timeout_ms)) orelse {
                try line.append(shell.scratchAllocator(), '\\');
                return .{ .line = try line.toOwnedSlice(shell.scratchAllocator()), .found_delimiter = false };
            };
            if (escaped == .timeout) return .{
                .line = try line.toOwnedSlice(shell.scratchAllocator()),
                .found_delimiter = false,
                .timed_out = true,
            };
            if (!options.exact_count and escaped.byte == options.delimiter and options.delimiter == '\n') continue;
            try line.append(shell.scratchAllocator(), read_escape_marker);
            try appendReadCharacter(shell, &line, escaped.byte, options.timeout_ms);
        } else {
            try appendReadCharacter(shell, &line, byte, options.timeout_ms);
        }
        if (options.count) |count| {
            characters_read += 1;
            if (characters_read >= count) return .{
                .line = try line.toOwnedSlice(shell.scratchAllocator()),
                .found_delimiter = true,
            };
        }
    }
}

const ReadByteResult = union(enum) {
    byte: u8,
    timeout,
};

fn readBuiltinByte(shell: anytype, timeout_ms: ?u64) !?ReadByteResult {
    var byte: [1]u8 = undefined;
    if (timeout_ms) |ms| {
        return switch (try shell.host.readWithTimeout(.stdin, &byte, ms)) {
            .read => |read_len| if (read_len == 0) null else .{ .byte = byte[0] },
            .timeout => .timeout,
        };
    }

    const read_len = try shell.host.read(.stdin, &byte);
    return if (read_len == 0) null else .{ .byte = byte[0] };
}

fn appendReadCharacter(shell: anytype, line: *std.ArrayList(u8), first: u8, timeout_ms: ?u64) !void {
    const allocator = shell.scratchAllocator();
    try line.append(allocator, first);
    const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    if (sequence_len <= 1) return;
    var remaining = sequence_len - 1;
    while (remaining != 0) : (remaining -= 1) {
        const next = (try readBuiltinByte(shell, timeout_ms)) orelse return;
        switch (next) {
            .byte => |byte| try line.append(allocator, byte),
            .timeout => return,
        }
    }
}

fn readExactFieldValues(shell: anytype, line: []const u8, count: usize) ![]const []const u8 {
    std.debug.assert(count != 0);
    const values = try shell.scratchAllocator().alloc([]const u8, count);
    @memset(values, "");
    values[0] = try cleanReadField(shell, line);
    return values;
}

fn readFieldValues(shell: anytype, line: []const u8, count: usize, ifs: []const u8) ![]const []const u8 {
    std.debug.assert(count != 0);
    const values = try shell.scratchAllocator().alloc([]const u8, count);
    @memset(values, "");
    if (ifs.len == 0) {
        values[0] = try cleanReadField(shell, line);
        return values;
    }
    if (count == 1) {
        const start = skipIfsWhitespace(line, 0, ifs);
        values[0] = try cleanReadField(shell, line[start..trimTrailingIfsWhitespace(line, start, line.len, ifs)]);
        return values;
    }

    var pos: usize = 0;
    var value_index: usize = 0;
    while (value_index + 1 < count) : (value_index += 1) {
        pos = skipIfsWhitespace(line, pos, ifs);
        const start = pos;
        while (pos < line.len and ifsMatchAt(line, pos, ifs) == null) pos += utf8CharLen(line, pos);
        values[value_index] = try cleanReadField(shell, line[start..pos]);
        pos = consumeReadDelimiter(line, pos, ifs);
    }

    pos = skipIfsWhitespace(line, pos, ifs);
    const last_start = pos;
    var end = trimTrailingIfsWhitespace(line, last_start, line.len, ifs);
    const starts_with_nonwhitespace_delimiter = if (ifsMatchAt(line, last_start, ifs)) |match|
        !match.whitespace
    else
        false;
    if (!starts_with_nonwhitespace_delimiter) end = trimOneTrailingIfsNonWhitespace(line, last_start, end, ifs);
    values[value_index] = try cleanReadField(shell, line[last_start..end]);
    return values;
}

fn readArrayFieldValues(shell: anytype, line: []const u8, ifs: []const u8) ![]const []const u8 {
    const allocator = shell.scratchAllocator();
    if (ifs.len == 0) return allocator.dupe([]const u8, &.{try cleanReadField(shell, line)});

    var values: std.ArrayList([]const u8) = .empty;
    var pos = skipIfsWhitespace(line, 0, ifs);
    while (pos < line.len) {
        const start = pos;
        while (pos < line.len and ifsMatchAt(line, pos, ifs) == null) pos += utf8CharLen(line, pos);
        const end = if (pos == line.len) trimTrailingIfsWhitespace(line, start, line.len, ifs) else pos;
        try values.append(allocator, try cleanReadField(shell, line[start..end]));
        pos = consumeReadDelimiter(line, pos, ifs);
    }
    return values.toOwnedSlice(allocator);
}

fn cleanReadField(shell: anytype, field: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, field, read_escape_marker) == null) return field;
    var output: std.ArrayList(u8) = .empty;
    for (field) |byte| {
        if (byte != read_escape_marker) try output.append(shell.scratchAllocator(), byte);
    }
    return output.toOwnedSlice(shell.scratchAllocator());
}

const IfsMatch = struct {
    len: usize,
    whitespace: bool,
};

fn ifsMatchAt(line: []const u8, pos: usize, ifs: []const u8) ?IfsMatch {
    if (pos >= line.len) return null;
    if (line[pos] == read_escape_marker or (pos != 0 and line[pos - 1] == read_escape_marker)) return null;
    const line_len = utf8CharLen(line, pos);
    var ifs_pos: usize = 0;
    while (ifs_pos < ifs.len) {
        const ifs_len = utf8CharLen(ifs, ifs_pos);
        if (line_len == ifs_len and std.mem.eql(u8, line[pos..][0..line_len], ifs[ifs_pos..][0..ifs_len])) {
            return .{ .len = line_len, .whitespace = ifs_len == 1 and isIfsWhitespace(ifs[ifs_pos]) };
        }
        ifs_pos += ifs_len;
    }
    return null;
}

fn skipIfsWhitespace(line: []const u8, pos: usize, ifs: []const u8) usize {
    var cursor = pos;
    while (ifsMatchAt(line, cursor, ifs)) |match| {
        if (!match.whitespace) break;
        cursor += match.len;
    }
    return cursor;
}

fn consumeReadDelimiter(line: []const u8, pos: usize, ifs: []const u8) usize {
    const match = ifsMatchAt(line, pos, ifs) orelse return pos;
    var cursor = pos + match.len;
    cursor = skipIfsWhitespace(line, cursor, ifs);
    if (match.whitespace) {
        if (ifsMatchAt(line, cursor, ifs)) |next| {
            if (!next.whitespace) cursor = skipIfsWhitespace(line, cursor + next.len, ifs);
        }
    }
    return cursor;
}

fn trimTrailingIfsWhitespace(line: []const u8, start: usize, end: usize, ifs: []const u8) usize {
    var cursor = end;
    while (cursor > start) {
        const prev = previousUtf8Start(line, start, cursor);
        const match = ifsMatchAt(line, prev, ifs) orelse break;
        if (!match.whitespace or prev + match.len != cursor) break;
        cursor = prev;
    }
    return cursor;
}

fn trimOneTrailingIfsNonWhitespace(line: []const u8, start: usize, end: usize, ifs: []const u8) usize {
    if (end <= start) return end;
    const prev = previousUtf8Start(line, start, end);
    const match = ifsMatchAt(line, prev, ifs) orelse return end;
    return if (!match.whitespace and prev + match.len == end) prev else end;
}

fn previousUtf8Start(line: []const u8, start: usize, end: usize) usize {
    var cursor = end - 1;
    while (cursor > start and (line[cursor] & 0xc0) == 0x80) cursor -= 1;
    return cursor;
}

fn utf8CharLen(bytes: []const u8, index: usize) usize {
    const byte = bytes[index];
    if (byte < 0x80) return 1;
    if ((byte & 0xe0) == 0xc0 and index + 1 < bytes.len) return 2;
    if ((byte & 0xf0) == 0xe0 and index + 2 < bytes.len) return 3;
    if ((byte & 0xf8) == 0xf0 and index + 3 < bytes.len) return 4;
    return 1;
}

fn isIfsWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
}

fn currentLogicalDir(shell: anytype) ![]const u8 {
    return parameterValue(shell, "PWD") orelse try shell.host.currentDir(shell.scratchAllocator());
}

fn exportedFlag(shell: anytype, name: []const u8) bool {
    return if (shell.state.getVariable(name)) |variable| variable.exported else envValue(shell.env, name) != null;
}

fn cdPathTarget(shell: anytype, operand: []const u8, print_new_dir: *bool) !?[]const u8 {
    if (operand.len == 0 or operand[0] == '/' or startsWithDotPathComponent(operand)) return null;
    const cdpath = parameterValue(shell, "CDPATH") orelse return null;
    var iterator = std.mem.splitScalar(u8, cdpath, ':');
    while (iterator.next()) |prefix| {
        const candidate = if (prefix.len == 0)
            operand
        else
            try std.fmt.allocPrint(shell.scratchAllocator(), "{s}/{s}", .{ prefix, operand });
        if (try pathIsDirectory(shell, candidate, .other)) {
            print_new_dir.* = prefix.len != 0;
            return candidate;
        }
    }
    return null;
}

fn collectCdSuggestion(shell: anytype, target: []const u8) !?[]const u8 {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (comptime !@hasDecl(HostType, "listDir")) return null;

    const allocator = shell.scratchAllocator();
    const trimmed = trimTrailingPathSeparators(target);
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "/")) return null;
    if (containsCdSuggestionMeta(trimmed)) return null;

    const wanted = std.fs.path.basename(trimmed);
    if (wanted.len == 0) return null;
    const parent = std.fs.path.dirname(trimmed) orelse ".";
    var entries = shell.host.listDir(allocator, parent) catch return null;
    defer entries.deinit();

    var distance: EditDistance = .{};
    defer distance.deinit(allocator);

    var best_name: ?[]const u8 = null;
    var best_distance: usize = cd_suggestion_max_distance + 1;
    for (entries.entries) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.' and wanted[0] != '.') continue;
        const candidate = try joinPathComponent(allocator, parent, entry.name);
        if (!try pathIsDirectory(shell, candidate, entry.kind)) continue;
        const entry_distance = try distance.atMost(
            allocator,
            wanted,
            entry.name,
            cd_suggestion_max_distance,
        ) orelse continue;
        if (best_name == null or cdSuggestionBefore(entry.name, entry_distance, best_name.?, best_distance)) {
            best_name = entry.name;
            best_distance = entry_distance;
        }
    }

    const name = best_name orelse return null;
    const suggestion: []const u8 = if (std.mem.eql(u8, parent, "."))
        try allocator.dupe(u8, name)
    else
        try joinPathComponent(allocator, parent, name);
    return suggestion;
}

fn trimTrailingPathSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn containsCdSuggestionMeta(path: []const u8) bool {
    for (path) |byte| switch (byte) {
        '*', '?', '[' => return true,
        else => {},
    };
    return false;
}

fn cdSuggestionBefore(candidate: []const u8, candidate_distance: usize, best: []const u8, best_distance: usize) bool {
    if (candidate_distance != best_distance) return candidate_distance < best_distance;
    if (candidate.len != best.len) return candidate.len < best.len;
    return std.mem.lessThan(u8, candidate, best);
}

fn startsWithDotPathComponent(path: []const u8) bool {
    return std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..") or
        std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../");
}

fn logicalPath(allocator: std.mem.Allocator, old_pwd: []const u8, target: []const u8) ![]const u8 {
    var combined: []const u8 = target;
    if (target.len == 0 or target[0] != '/') {
        combined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ old_pwd, target });
    }
    return normalizeAbsolutePath(allocator, combined);
}

fn normalizeAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // ziglint-ignore: Z016 compound assert documents a single invariant; preserve readability
    std.debug.assert(path.len != 0 and path[0] == '/');
    var components: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, path, '/');
    while (iterator.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (components.items.len != 0) components.items.len -= 1;
            continue;
        }
        try components.append(allocator, component);
    }
    if (components.items.len == 0) return allocator.dupe(u8, "/");

    var total_len: usize = 0;
    for (components.items) |component| total_len += component.len + 1;
    const normalized = try allocator.alloc(u8, total_len);
    var cursor: usize = 0;
    for (components.items) |component| {
        normalized[cursor] = '/';
        cursor += 1;
        @memcpy(normalized[cursor..][0..component.len], component);
        cursor += component.len;
    }
    return normalized;
}

fn staticDeclarationBuiltinName(shell: anytype, word: ast.Word) !?builtin.Id {
    if (wordHasDynamicExpansion(word)) return null;
    // Plain literal words expand to themselves unless a tilde prefix applies,
    // so skip the expansion machinery on the per-command hot path.
    const name = switch (word.data) {
        .literal => |literal| if (word.quoted or tildePrefixLen(literal) == null)
            literal
        else
            try expandWordTracking(shell, word, null),
        .parts => try expandWordTracking(shell, word, null),
        .declaration_array_assignment => return null,
    };
    if (shell.state.options.mode == .bash) {
        if (std.mem.eql(u8, name, "declare")) return .declare;
        if (std.mem.eql(u8, name, "typeset")) return .typeset;
        if (std.mem.eql(u8, name, "local")) return .local;
    }
    if (std.mem.eql(u8, name, "export")) return .export_;
    if (std.mem.eql(u8, name, "readonly")) return .readonly;
    return null;
}

const DeclarationOptions = struct {
    exported: bool = false,
    readonly: bool = false,
    integer: bool = false,
    array: bool = false,
    print: bool = false,
    global: bool = false,
    first_operand: usize = 0,
};

const DeclarationAssignment = struct {
    name: []const u8,
    value: ast.Word,
};

fn evalDeclarationBuiltin(shell: anytype, id: builtin.Id, words: []const ast.Word) EvalError!result.EvalResult {
    std.debug.assert(id == .declare or id == .export_ or id == .readonly or id == .typeset or id == .local);
    if (id == .local and !shell.state.hasLocalFrame()) {
        try shell.host.writeAll(.stderr, "local: can only be used in a function\n");
        return .{ .status = 1 };
    }
    const options = parseDeclarationOptions(shell, id, words) catch |err| switch (err) {
        error.DeclarationUsage => return .{ .status = 2 },
        else => return err,
    };
    const operands = words[options.first_operand..];
    if (id == .local and operands.len == 0) return .{};
    if (options.print) return evalDeclarationPrint(shell, id, operands);
    if (operands.len == 0) return evalDeclarationList(shell, id);

    if (id == .declare or id == .typeset or id == .local or
        (shell.state.options.mode == .bash and (options.array or operandsContainDeclarationArrayAssignment(operands))))
    {
        return evalDeclareOperands(shell, id, options, operands);
    }

    var status: result.ExitStatus = 0;
    for (operands) |word| {
        if (try declarationAssignment(shell, word)) |assignment| {
            const expanded_value = try expandAssignmentWordTracking(shell, assignment.value, null);
            const value = try assignmentValueForStorage(shell, assignment.name, expanded_value);
            const existing = shell.state.getVariable(assignment.name);
            shell.state.putVariable(.{
                .name = assignment.name,
                .value = value,
                .exported = id == .export_ or (existing != null and existing.?.exported),
                .readonly = id == .readonly or (existing != null and existing.?.readonly),
                .integer = existing != null and existing.?.integer,
            }) catch |err| switch (err) {
                error.ReadonlyVariable => {
                    try writeReadonlyDiagnostic(shell, assignment.name);
                    status = 1;
                },
                else => return err,
            };
            continue;
        }

        const names = try expandWordFields(shell, &.{word}, null);
        for (names) |name| {
            if (literalDeclarationAssignment(name)) |assignment| {
                const expanded_value = switch (assignment.value.data) {
                    .literal => |literal| literal,
                    .parts => unreachable,
                    .declaration_array_assignment => unreachable,
                };
                const value = try assignmentValueForStorage(shell, assignment.name, expanded_value);
                const existing = shell.state.getVariable(assignment.name);
                shell.state.putVariable(.{
                    .name = assignment.name,
                    .value = value,
                    .exported = id == .export_ or (existing != null and existing.?.exported),
                    .readonly = id == .readonly or (existing != null and existing.?.readonly),
                    .integer = existing != null and existing.?.integer,
                }) catch |err| switch (err) {
                    error.ReadonlyVariable => {
                        try writeReadonlyDiagnostic(shell, assignment.name);
                        status = 1;
                    },
                    else => return err,
                };
                continue;
            }
            if (!isAssignmentName(name)) {
                try writeInvalidIdentifierDiagnostic(shell, id, name);
                status = if (shell.state.options.mode == .bash) 1 else 2;
                continue;
            }
            const existing = shell.state.getVariable(name);
            if (existing) |variable| {
                shell.state.putVariable(.{
                    .name = name,
                    .value = variable.value,
                    .exported = id == .export_ or variable.exported,
                    .readonly = id == .readonly or variable.readonly,
                    .integer = variable.integer,
                }) catch |err| switch (err) {
                    error.ReadonlyVariable => {
                        try writeReadonlyDiagnostic(shell, name);
                        status = 1;
                    },
                    else => return err,
                };
            } else {
                try shell.state.putVariableAttributes(.{
                    .name = name,
                    .exported = id == .export_,
                    .readonly = id == .readonly,
                });
            }
        }
    }
    const fatal = status != 0 and shell.state.options.mode == .posix;
    return .{ .status = status, .flow = if (fatal) .{ .fatal = status } else .normal };
}

fn operandsContainDeclarationArrayAssignment(operands: []const ast.Word) bool {
    for (operands) |word| if (word.data == .declaration_array_assignment) return true;
    return false;
}

fn parseDeclarationOptions(shell: anytype, id: builtin.Id, words: []const ast.Word) !DeclarationOptions {
    var options: DeclarationOptions = switch (id) {
        .export_ => .{ .exported = true },
        .readonly => .{ .readonly = true },
        .declare, .typeset, .local => .{},
        else => unreachable,
    };
    while (options.first_operand < words.len) : (options.first_operand += 1) {
        const literal = staticLiteralWord(words[options.first_operand]) orelse break;
        if (std.mem.eql(u8, literal, "--")) {
            options.first_operand += 1;
            break;
        }
        if (literal.len < 2 or literal[0] != '-') break;
        for (literal[1..]) |option| switch (option) {
            'a' => {
                const can_declare_array = id == .declare or id == .typeset or id == .local;
                const can_mark_array = shell.state.options.mode == .bash and (id == .export_ or id == .readonly);
                if (!can_declare_array and !can_mark_array) return declarationUsageError(shell, id);
                options.array = true;
            },
            'p' => {
                if (id == .local) return declarationUsageError(shell, id);
                options.print = true;
            },
            'r' => options.readonly = true,
            'x' => options.exported = true,
            'i' => {
                if (id != .declare and id != .typeset and id != .local) return declarationUsageError(shell, id);
                options.integer = true;
            },
            'g' => {
                if (id != .declare and id != .typeset) return declarationUsageError(shell, id);
                options.global = true;
            },
            else => return declarationUsageError(shell, id),
        };
    }
    return options;
}

fn declarationUsageError(shell: anytype, id: builtin.Id) !DeclarationOptions {
    try shell.host.writeAll(
        .stderr,
        try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: invalid option\n", .{declarationName(id)}),
    );
    return error.DeclarationUsage;
}

fn evalDeclareOperands(
    shell: anytype,
    id: builtin.Id,
    options: DeclarationOptions,
    operands: []const ast.Word,
) EvalError!result.EvalResult {
    var status: result.ExitStatus = 0;
    for (operands) |word| {
        if (word.data == .declaration_array_assignment) {
            try applyDeclaredArrayAssignment(shell, word.data.declaration_array_assignment, options, &status);
            continue;
        }
        if (try declarationAssignment(shell, word)) |assignment| {
            const value = try expandAssignmentWordTracking(shell, assignment.value, null);
            try applyDeclaredVariable(shell, assignment.name, value, options, &status);
            continue;
        }

        const names = try expandWordFields(shell, &.{word}, null);
        for (names) |name| {
            if (literalDeclarationAssignment(name)) |assignment| {
                const value = switch (assignment.value.data) {
                    .literal => |literal| literal,
                    .parts => unreachable,
                    .declaration_array_assignment => unreachable,
                };
                try applyDeclaredVariable(shell, assignment.name, value, options, &status);
                continue;
            }
            if (!isAssignmentName(name)) {
                try writeInvalidIdentifierDiagnostic(shell, id, name);
                status = 1;
                continue;
            }
            try applyDeclaredName(shell, id, name, options, &status);
        }
    }
    return .{ .status = status };
}

fn applyDeclaredArrayAssignment(
    shell: anytype,
    assignment: ast.DeclarationArrayAssignment,
    options: DeclarationOptions,
    status: *result.ExitStatus,
) !void {
    if (assignment.append) {
        try prepareDeclaredArrayAppend(shell, assignment.name, options, status);
        if (status.* != 0) return;
    }
    const append_start = if (assignment.append) compoundArrayAppendStart(shell, assignment.name) else 0;
    const expanded = try expandArrayAssignmentElements(shell, assignment.values, append_start, null);
    const stored = try arrayElementValuesForStorage(shell, assignment.name, expanded, options.integer);
    try applyDeclaredArrayElements(shell, assignment.name, stored, assignment.append, options, status);
}

fn declareUsesLocalScope(shell: anytype, options: DeclarationOptions) bool {
    return shell.state.hasLocalFrame() and !options.global;
}

fn applyDeclaredVariable(
    shell: anytype,
    name: []const u8,
    value: []const u8,
    options: DeclarationOptions,
    status: *result.ExitStatus,
) !void {
    if (options.array) {
        try applyDeclaredArrayVariable(shell, name, value, options, status);
        return;
    }
    const declared_value = try integerDeclarationValue(shell, name, value, options.integer);
    if (applyDynamicVariableAssignment(shell, name, declared_value)) return;
    const existing = shell.state.getVariable(name);
    if (declareUsesLocalScope(shell, options)) {
        shell.state.declareLocalWithAttributes(.{
            .name = name,
            .value = declared_value,
            .exported = options.exported or (existing != null and existing.?.exported),
            .readonly = options.readonly or (existing != null and existing.?.readonly),
            .integer = options.integer or (existing != null and existing.?.integer),
        }) catch |err| switch (err) {
            error.ReadonlyVariable => {
                try writeReadonlyDiagnostic(shell, name);
                status.* = 1;
            },
            else => return err,
        };
        return;
    }
    shell.state.putVariable(.{
        .name = name,
        .value = declared_value,
        .exported = options.exported or (existing != null and existing.?.exported),
        .readonly = options.readonly or (existing != null and existing.?.readonly),
        .integer = options.integer or (existing != null and existing.?.integer),
    }) catch |err| switch (err) {
        error.ReadonlyVariable => {
            try writeReadonlyDiagnostic(shell, name);
            status.* = 1;
        },
        else => return err,
    };
}

fn applyDeclaredName(
    shell: anytype,
    id: builtin.Id,
    name: []const u8,
    options: DeclarationOptions,
    status: *result.ExitStatus,
) !void {
    if (options.array) {
        if (id == .declare or id == .typeset or id == .local) {
            try applyDeclaredArrayName(shell, name, options, status);
        } else if (options.exported or options.readonly or options.integer) {
            try shell.state.putVariableAttributes(.{
                .name = name,
                .exported = options.exported,
                .readonly = options.readonly,
                .integer = options.integer,
            });
        }
        return;
    }
    const existing = shell.state.getVariable(name);
    if (declareUsesLocalScope(shell, options)) {
        shell.state.declareLocalWithAttributes(.{
            .name = name,
            .exported = options.exported,
            .readonly = options.readonly,
            .integer = options.integer,
        }) catch |err| switch (err) {
            error.ReadonlyVariable => {
                try writeReadonlyDiagnostic(shell, name);
                status.* = 1;
            },
            else => return err,
        };
        return;
    }
    if (existing) |variable| {
        shell.state.putVariable(.{
            .name = name,
            .value = variable.value,
            .exported = options.exported or variable.exported,
            .readonly = options.readonly or variable.readonly,
            .integer = options.integer or variable.integer,
        }) catch |err| switch (err) {
            error.ReadonlyVariable => {
                try writeReadonlyDiagnostic(shell, name);
                status.* = 1;
            },
            else => return err,
        };
    } else if (options.exported or options.readonly or options.integer) {
        try shell.state.putVariableAttributes(.{
            .name = name,
            .exported = options.exported,
            .readonly = options.readonly,
            .integer = options.integer,
        });
    }
}

fn integerDeclarationValue(shell: anytype, name: []const u8, value: []const u8, force_integer: bool) ![]const u8 {
    const integer = force_integer or if (shell.state.getVariable(name)) |variable|
        variable.integer
    else if (shell.state.getArray(name)) |array|
        array.integer
    else if (shell.state.getVariableAttributes(name)) |attributes|
        attributes.integer
    else
        false;
    if (!integer) return value;
    return integerAssignmentValue(shell, value);
}

fn applyDeclaredArrayVariable(
    shell: anytype,
    name: []const u8,
    value: []const u8,
    options: DeclarationOptions,
    status: *result.ExitStatus,
) !void {
    try applyDeclaredArrayValues(shell, name, &.{value}, options, status);
}

fn prepareDeclaredArrayAppend(
    shell: anytype,
    name: []const u8,
    options: DeclarationOptions,
    status: *result.ExitStatus,
) !void {
    if (!declareUsesLocalScope(shell, options)) return;
    if (shell.state.hasSavedLocalBinding(name) and shell.state.getArray(name) != null) return;
    shell.state.declareLocalArray(name, &.{}) catch |err| switch (err) {
        error.ReadonlyVariable => {
            try writeReadonlyDiagnostic(shell, name);
            status.* = 1;
        },
        else => return err,
    };
}

fn applyDeclaredArrayValues(
    shell: anytype,
    name: []const u8,
    values: []const []const u8,
    options: DeclarationOptions,
    status: *result.ExitStatus,
) !void {
    const uses_local_scope = declareUsesLocalScope(shell, options);
    const attributes = declarationArrayAttributes(options);
    const applied = if (uses_local_scope)
        shell.state.declareLocalArrayWithAttributes(name, values, attributes)
    else
        shell.state.putArrayWithAttributes(name, values, attributes);
    applied catch |err| switch (err) {
        error.ReadonlyVariable => {
            try writeReadonlyDiagnostic(shell, name);
            status.* = 1;
        },
        else => return err,
    };
}

fn applyDeclaredArrayElements(
    shell: anytype,
    name: []const u8,
    elements: []const state_mod.ArrayElement,
    append: bool,
    options: DeclarationOptions,
    status: *result.ExitStatus,
) !void {
    const uses_local_scope = declareUsesLocalScope(shell, options);
    const attributes = declarationArrayAttributes(options);
    const applied = if (append)
        shell.state.appendArrayElements(name, elements)
    else if (uses_local_scope)
        applyLocalArrayElements(shell, name, elements, attributes)
    else
        shell.state.putArrayElementsWithAttributes(name, elements, attributes);
    var applied_ok = true;
    applied catch |err| switch (err) {
        error.ReadonlyVariable => {
            try writeReadonlyDiagnostic(shell, name);
            status.* = 1;
            applied_ok = false;
        },
        else => return err,
    };
    if (applied_ok and append and (options.exported or options.readonly or options.integer)) {
        try shell.state.putVariableAttributes(.{
            .name = name,
            .exported = options.exported,
            .readonly = options.readonly,
            .integer = options.integer,
        });
    }
}

fn declarationArrayAttributes(options: DeclarationOptions) state_mod.ArrayAttributes {
    return .{
        .exported = options.exported,
        .readonly = options.readonly,
        .integer = options.integer,
    };
}

fn applyLocalArrayElements(
    shell: anytype,
    name: []const u8,
    elements: []const state_mod.ArrayElement,
    attributes: state_mod.ArrayAttributes,
) !void {
    try shell.state.declareLocalArrayWithAttributes(name, &.{}, .{
        .exported = attributes.exported,
        .integer = attributes.integer,
    });
    try shell.state.putArrayElements(name, elements);
    if (attributes.readonly) {
        try shell.state.putVariableAttributes(.{ .name = name, .readonly = true });
    }
}

fn applyDeclaredArrayName(
    shell: anytype,
    name: []const u8,
    options: DeclarationOptions,
    status: *result.ExitStatus,
) !void {
    if (shell.state.getArray(name) != null) {
        if (options.exported or options.readonly or options.integer) {
            try shell.state.putVariableAttributes(.{
                .name = name,
                .exported = options.exported,
                .readonly = options.readonly,
                .integer = options.integer,
            });
        }
        return;
    }
    if (shell.state.getVariable(name)) |variable| {
        try applyDeclaredArrayVariable(shell, name, variable.value, options, status);
        return;
    }
    try applyDeclaredArrayValues(shell, name, &.{}, options, status);
}

fn writeInvalidIdentifierDiagnostic(shell: anytype, id: builtin.Id, name: []const u8) !void {
    try shell.host.writeAll(
        .stderr,
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: `{s}': not a valid identifier\n", .{ declarationName(id), name }),
    );
}

fn declarationName(id: builtin.Id) []const u8 {
    return switch (id) {
        .declare, .typeset => "declare",
        .export_ => "export",
        .readonly => "readonly",
        else => unreachable,
    };
}

fn evalDeclarationList(shell: anytype, id: builtin.Id) !result.EvalResult {
    var attributes_iterator = shell.state.bindings.iterator();
    while (attributes_iterator.next()) |entry| {
        const attributes = entry.value_ptr.attributes() orelse continue;
        const include = switch (id) {
            .declare, .typeset => true,
            .export_ => attributes.exported,
            .readonly => attributes.readonly,
            else => unreachable,
        };
        if (!include) continue;
        try writeDeclarationEntry(
            shell,
            id,
            attributes.name,
            null,
            attributes.exported,
            attributes.readonly,
            attributes.integer,
        );
    }

    var iterator = shell.state.bindings.iterator();
    while (iterator.next()) |entry| {
        const variable = entry.value_ptr.variable() orelse continue;
        const include = switch (id) {
            .declare, .typeset => true,
            .export_ => variable.exported,
            .readonly => variable.readonly,
            else => unreachable,
        };
        if (!include) continue;
        try writeDeclarationEntry(
            shell,
            id,
            variable.name,
            variable.value,
            variable.exported,
            variable.readonly,
            variable.integer,
        );
    }
    if (id == .declare or id == .typeset) {
        var array_iterator = shell.state.bindings.iterator();
        while (array_iterator.next()) |entry| {
            const array = entry.value_ptr.array() orelse continue;
            try writeArrayDeclarationEntry(shell, id, array);
        }
    }
    return .{};
}

fn evalDeclarationPrint(shell: anytype, id: builtin.Id, operands: []const ast.Word) EvalError!result.EvalResult {
    if (operands.len == 0) return evalDeclarationList(shell, id);
    var status: result.ExitStatus = 0;
    for (operands) |word| {
        const names = try expandWordFields(shell, &.{word}, null);
        for (names) |name| {
            if (!isAssignmentName(name)) {
                try writeInvalidIdentifierDiagnostic(shell, id, name);
                status = 1;
                continue;
            }
            if (shell.state.getVariable(name)) |variable| {
                try writeDeclarationEntry(
                    shell,
                    id,
                    variable.name,
                    variable.value,
                    variable.exported,
                    variable.readonly,
                    variable.integer,
                );
            } else if (shell.state.getArray(name)) |array| {
                if (id == .declare or id == .typeset) {
                    try writeArrayDeclarationEntry(shell, id, array);
                } else {
                    try shell.host.writeAll(
                        .stderr,
                        try std.fmt.allocPrint(
                            shell.scratchAllocator(),
                            "{s}: {s}: not found\n",
                            .{ declarationName(id), name },
                        ),
                    );
                    status = 1;
                }
            } else if (shell.state.getVariableAttributes(name)) |attributes| {
                try writeDeclarationEntry(
                    shell,
                    id,
                    attributes.name,
                    null,
                    attributes.exported,
                    attributes.readonly,
                    attributes.integer,
                );
            } else {
                try shell.host.writeAll(
                    .stderr,
                    try std.fmt.allocPrint(
                        shell.scratchAllocator(),
                        "{s}: {s}: not found\n",
                        .{ declarationName(id), name },
                    ),
                );
                status = 1;
            }
        }
    }
    return .{ .status = status };
}

fn writeDeclarationEntry(
    shell: anytype,
    id: builtin.Id,
    name: []const u8,
    value: ?[]const u8,
    exported: bool,
    readonly: bool,
    integer: bool,
) !void {
    if (id == .declare or id == .typeset) {
        try shell.host.writeAll(.stdout, "declare ");
        if (readonly or exported or integer) {
            try shell.host.writeAll(.stdout, "-");
            if (readonly) try shell.host.writeAll(.stdout, "r");
            if (integer) try shell.host.writeAll(.stdout, "i");
            if (exported) try shell.host.writeAll(.stdout, "x");
            try shell.host.writeAll(.stdout, " ");
        } else {
            try shell.host.writeAll(.stdout, "-- ");
        }
        try shell.host.writeAll(.stdout, name);
        if (value) |text| {
            const quoted = try doubleQuoteShell(shell.scratchAllocator(), text);
            try shell.host.writeAll(.stdout, "=");
            try shell.host.writeAll(.stdout, quoted);
        }
        try shell.host.writeAll(.stdout, "\n");
        return;
    }

    if (value) |text| {
        const quoted = try singleQuoteShell(shell.scratchAllocator(), text);
        try shell.host.writeAll(.stdout, declarationPrefix(id));
        try shell.host.writeAll(.stdout, name);
        try shell.host.writeAll(.stdout, "=");
        try shell.host.writeAll(.stdout, quoted);
        try shell.host.writeAll(.stdout, "\n");
    } else {
        try shell.host.writeAll(.stdout, declarationPrefix(id));
        try shell.host.writeAll(.stdout, name);
        try shell.host.writeAll(.stdout, "\n");
    }
}

fn writeArrayDeclarationEntry(shell: anytype, id: builtin.Id, array: state_mod.ArrayVariable) !void {
    std.debug.assert(id == .declare or id == .typeset);
    try shell.host.writeAll(.stdout, "declare -a");
    if (array.readonly) try shell.host.writeAll(.stdout, "r");
    if (array.integer) try shell.host.writeAll(.stdout, "i");
    if (array.exported) try shell.host.writeAll(.stdout, "x");
    try shell.host.writeAll(.stdout, " ");
    try shell.host.writeAll(.stdout, array.name);
    if (array.elements.len != 0) {
        try shell.host.writeAll(.stdout, "=(");
        for (array.elements, 0..) |element, index| {
            if (index != 0) try shell.host.writeAll(.stdout, " ");
            try shell.host.writeAll(.stdout, "[");
            try shell.host.writeAll(.stdout, try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{element.index}));
            try shell.host.writeAll(.stdout, "]=");
            try shell.host.writeAll(.stdout, try doubleQuoteShell(shell.scratchAllocator(), element.value));
        }
        try shell.host.writeAll(.stdout, ")");
    }
    try shell.host.writeAll(.stdout, "\n");
}

fn declarationPrefix(id: builtin.Id) []const u8 {
    return switch (id) {
        .export_ => "export ",
        .readonly => "readonly ",
        else => unreachable,
    };
}

fn doubleQuoteShell(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    try output.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '"', '\\', '$', '`' => {
                try output.append(allocator, '\\');
                try output.append(allocator, byte);
            },
            else => try output.append(allocator, byte),
        }
    }
    try output.append(allocator, '"');
    return output.toOwnedSlice(allocator);
}

fn singleQuoteShell(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    try output.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try output.appendSlice(allocator, "'\\''");
        } else {
            try output.append(allocator, byte);
        }
    }
    try output.append(allocator, '\'');
    return output.toOwnedSlice(allocator);
}

fn declarationAssignment(shell: anytype, word: ast.Word) !?DeclarationAssignment {
    return switch (word.data) {
        .literal => |literal| literalDeclarationAssignment(literal),
        .parts => |parts| partsDeclarationAssignment(shell, parts),
        .declaration_array_assignment => null,
    };
}

fn literalDeclarationAssignment(literal: []const u8) ?DeclarationAssignment {
    const equal_index = std.mem.indexOfScalar(u8, literal, '=') orelse return null;
    const name = literal[0..equal_index];
    if (!isAssignmentName(name)) return null;
    return .{ .name = name, .value = .{ .data = .{ .literal = literal[equal_index + 1 ..] } } };
}

fn partsDeclarationAssignment(shell: anytype, parts: []const ast.WordPart) !?DeclarationAssignment {
    if (parts.len == 0) return null;
    const first_literal = switch (parts[0]) {
        .literal => |literal| literal,
        else => return null,
    };
    const equal_index = std.mem.indexOfScalar(u8, first_literal, '=') orelse return null;
    const name = first_literal[0..equal_index];
    if (!isAssignmentName(name)) return null;

    const allocator = shell.scratchAllocator();
    var value_parts: std.ArrayList(ast.WordPart) = .empty;
    const suffix = first_literal[equal_index + 1 ..];
    if (suffix.len != 0) try value_parts.append(allocator, .{ .literal = suffix });
    try value_parts.appendSlice(allocator, parts[1..]);
    return .{ .name = name, .value = .{ .data = .{ .parts = try value_parts.toOwnedSlice(allocator) } } };
}

fn isAssignmentName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

fn evalEvalBuiltin(shell: anytype, args: []const []const u8) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    if (args.len == 1) return .{};

    const allocator = shell.scratchAllocator();
    var total_len: usize = args.len - 2;
    for (args[1..]) |arg| total_len = std.math.add(usize, total_len, arg.len) catch return error.OutOfMemory;

    const script = try allocator.alloc(u8, total_len);
    var cursor: usize = 0;
    for (args[1..], 0..) |arg, index| {
        if (index != 0) {
            script[cursor] = ' ';
            cursor += 1;
        }
        @memcpy(script[cursor..][0..arg.len], arg);
        cursor += arg.len;
    }

    const src: source_mod.Source = .{ .id = 0, .kind = .command_string, .name = "eval", .text = script };
    return shell.evalSourceNested(src) catch |err| switch (err) {
        error.ExpectedCommand,
        error.ExpectedRedirectionTarget,
        error.InvalidParameterExpansion,
        error.UnclosedCommandSubstitution,
        error.UnclosedQuote,
        error.UnexpectedToken,
        => {
            try shell.host.writeAll(.stderr, "eval: syntax error\n");
            return .{ .status = 2, .flow = .{ .fatal = 2 } };
        },
        else => return err,
    };
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn evalExecBuiltin(shell: anytype, args: []const []const u8, assignments: []const ast.Assignment) EvalError!result.EvalResult {
    std.debug.assert(args.len > 1);
    const request = try makeExternalSpawnRequest(shell, args[1..], assignments, &.{});
    try shell.host.exec(request);
    return .{ .status = 127 };
}

const SavedVariable = struct {
    name: []const u8,
    variable: ?state_mod.Variable,
};

fn evalFunction(
    shell: anytype,
    function: state_mod.Function,
    assignments: []const ast.Assignment,
    args: []const []const u8,
) EvalError!result.EvalResult {
    validateAst(function);
    try shell.state.pushFunctionCall(function);
    defer shell.state.popFunctionCall();
    const previous_source_name = shell.state.current_source_name;
    shell.state.current_source_name = function.source_name;
    defer shell.state.current_source_name = previous_source_name;

    const saved = try saveAssignmentVariables(shell, assignments);
    defer restoreVariables(shell, saved);

    const saved_positionals = try savePositionals(shell);
    defer freeSavedPositionals(shell, saved_positionals);
    var restored_positionals = false;
    errdefer if (!restored_positionals) restorePositionals(shell, saved_positionals) catch {};

    try applyExportedAssignments(shell, assignments);
    try pushFunctionLocalFrame(shell, assignments);
    var local_frame_popped = false;
    // ziglint-ignore: Z026 best-effort restore; the enclosing error already aborts the function call
    defer if (!local_frame_popped) shell.state.popLocalFrame() catch {};
    try shell.state.setPositionals(args);
    const saved_loop_depth = shell.state.loop_depth;
    shell.state.loop_depth = 0;
    errdefer shell.state.loop_depth = saved_loop_depth;
    const evaluated = try evalCommand(shell, .{ .compound = .{
        .body = function.definition.body,
        .redirections = function.definition.redirections,
    } });
    shell.state.loop_depth = saved_loop_depth;
    try restorePositionals(shell, saved_positionals);
    restored_positionals = true;
    local_frame_popped = true;
    try shell.state.popLocalFrame();
    if (evaluated.flow == .return_) return .{ .status = evaluated.status };
    if (evaluated.flow == .break_ or evaluated.flow == .continue_) return .{ .status = 2 };
    if (evaluated.flow == .fatal and shell.state.options.mode == .bash and !shell.state.options.errexit) {
        return .{ .status = evaluated.status };
    }
    return evaluated;
}

fn pushFunctionLocalFrame(shell: anytype, assignments: []const ast.Assignment) !void {
    const names = try shell.scratchAllocator().alloc([]const u8, assignments.len);
    for (assignments, 0..) |assignment, index| names[index] = assignment.name;
    try shell.state.pushLocalFrame(names);
}

fn saveAssignmentVariables(shell: anytype, assignments: []const ast.Assignment) ![]const SavedVariable {
    const saved = try shell.scratchAllocator().alloc(SavedVariable, assignments.len);
    for (assignments, 0..) |assignment, index| {
        const variable = if (shell.state.getVariable(assignment.name)) |existing| state_mod.Variable{
            .name = try shell.scratchAllocator().dupe(u8, existing.name),
            .value = try shell.scratchAllocator().dupe(u8, existing.value),
            .exported = existing.exported,
            .readonly = existing.readonly,
        } else null;
        saved[index] = .{
            .name = assignment.name,
            .variable = variable,
        };
    }
    return saved;
}

fn restoreVariables(shell: anytype, saved: []const SavedVariable) void {
    var index = saved.len;
    while (index != 0) {
        index -= 1;
        const entry = saved[index];
        if (entry.variable) |variable| {
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            shell.state.putVariable(variable) catch {};
        } else {
            shell.state.removeVariable(entry.name);
        }
    }
}

fn applyExportedAssignments(shell: anytype, assignments: []const ast.Assignment) !void {
    var status: ?result.ExitStatus = null;
    for (assignments) |assignment| {
        const value = try expandAssignmentValue(shell, assignment, &status);
        try shell.state.putVariable(.{ .name = assignment.name, .value = value, .exported = true });
    }
}

const AppliedRedirections = struct {
    frames: []const RedirectionFrame,
    here_doc_writers: []const host_mod.Pid,

    fn commit(self: AppliedRedirections, shell: anytype) !void {
        for (self.frames) |frame| {
            if (frame.saved) |saved| try shell.host.close(saved);
        }
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        for (self.here_doc_writers) |pid| _ = shell.host.wait(pid) catch {};
    }

    fn restore(self: AppliedRedirections, shell: anytype) !void {
        var index = self.frames.len;
        while (index != 0) {
            index -= 1;
            const frame = self.frames[index];
            if (frame.saved) |saved| {
                try shell.host.duplicateTo(saved, frame.target);
                try shell.host.close(saved);
            } else {
                shell.host.close(frame.target) catch |err| switch (err) {
                    error.Unexpected => {},
                    else => return err,
                };
            }
        }
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        for (self.here_doc_writers) |pid| _ = shell.host.wait(pid) catch {};
    }
};

const RedirectionFrame = struct {
    target: host_mod.Fd,
    saved: ?host_mod.Fd,
};

fn applyRedirections(shell: anytype, redirections: []const ast.Redirection) !AppliedRedirections {
    var frames: std.ArrayList(RedirectionFrame) = .empty;
    var here_doc_writers: std.ArrayList(host_mod.Pid) = .empty;
    errdefer restoreFrames(shell, frames.items) catch {};

    for (redirections) |redirection| {
        try applyRedirection(shell, redirection, &frames, &here_doc_writers);
    }

    return .{
        .frames = try frames.toOwnedSlice(shell.scratchAllocator()),
        .here_doc_writers = try here_doc_writers.toOwnedSlice(shell.scratchAllocator()),
    };
}

fn applyRedirection(
    shell: anytype,
    redirection: ast.Redirection,
    frames: *std.ArrayList(RedirectionFrame),
    here_doc_writers: *std.ArrayList(host_mod.Pid),
) !void {
    validateAst(redirection);
    const target = redirectionFd(redirection);
    if (redirection.op == .duplicate_input or redirection.op == .duplicate_output) {
        try applyDuplicateRedirection(shell, redirection, target, frames);
        return;
    }
    if (redirection.op == .output_and_error or redirection.op == .append_and_error) {
        try applyOutputAndErrorRedirection(shell, redirection, frames);
        return;
    }

    const saved = saveFd(shell, target) catch |err| switch (err) {
        error.BadFd => null,
        else => return err,
    };
    try frames.append(shell.scratchAllocator(), .{ .target = target, .saved = saved });

    switch (redirection.op) {
        .input, .output, .append, .read_write, .clobber => {
            const path = try shell.scratchAllocator().dupeZ(u8, try expandWord(shell, redirection.target));
            const opened = try openRedirectionPath(shell, path, redirection.op);
            if (opened != target) {
                defer shell.host.close(opened) catch {};
                try shell.host.duplicateTo(opened, target);
            } else {
                try shell.host.setCloseOnExec(target, false);
            }
        },
        .duplicate_input, .duplicate_output => unreachable,
        .output_and_error, .append_and_error => unreachable,
        .here_doc, .here_doc_strip_tabs => {
            const pid = try applyHereDocRedirection(shell, target, redirection.here_doc.?);
            try here_doc_writers.append(shell.scratchAllocator(), pid);
        },
        .here_string => {
            const expanded = try expandWord(shell, redirection.target);
            const body = try std.fmt.allocPrint(shell.scratchAllocator(), "{s}\n", .{expanded});
            const pid = try applyPipeInputRedirection(shell, target, body);
            try here_doc_writers.append(shell.scratchAllocator(), pid);
        },
    }
}

fn applyOutputAndErrorRedirection(
    shell: anytype,
    redirection: ast.Redirection,
    frames: *std.ArrayList(RedirectionFrame),
) !void {
    const stdout_saved = saveFd(shell, .stdout) catch |err| switch (err) {
        error.BadFd => null,
        else => return err,
    };
    try frames.append(shell.scratchAllocator(), .{ .target = .stdout, .saved = stdout_saved });

    const stderr_saved = saveFd(shell, .stderr) catch |err| switch (err) {
        error.BadFd => null,
        else => return err,
    };
    try frames.append(shell.scratchAllocator(), .{ .target = .stderr, .saved = stderr_saved });

    const path = try shell.scratchAllocator().dupeZ(u8, try expandWord(shell, redirection.target));
    const file_op: ast.RedirectionOperator = switch (redirection.op) {
        .output_and_error => .output,
        .append_and_error => .append,
        else => unreachable,
    };
    const opened = try openRedirectionPath(shell, path, file_op);
    if (opened != .stdout) {
        defer shell.host.close(opened) catch {};
        try shell.host.duplicateTo(opened, .stdout);
    } else {
        try shell.host.setCloseOnExec(.stdout, false);
    }
    try shell.host.duplicateTo(.stdout, .stderr);
}

fn applyDuplicateRedirection(
    shell: anytype,
    redirection: ast.Redirection,
    target: host_mod.Fd,
    frames: *std.ArrayList(RedirectionFrame),
) !void {
    const source_text = try expandWord(shell, redirection.target);
    if (std.mem.eql(u8, source_text, "-")) {
        const saved = saveFd(shell, target) catch |err| switch (err) {
            error.BadFd => null,
            else => return err,
        };
        try frames.append(shell.scratchAllocator(), .{ .target = target, .saved = saved });
        shell.host.close(target) catch |err| switch (err) {
            error.Unexpected => {},
            else => return err,
        };
        return;
    }

    const source = try parseFd(source_text);
    if (source == target) return;
    const probe = try shell.host.duplicate(source);
    try shell.host.close(probe);

    const saved = saveFd(shell, target) catch |err| switch (err) {
        error.BadFd => null,
        else => return err,
    };
    try frames.append(shell.scratchAllocator(), .{ .target = target, .saved = saved });
    try shell.host.duplicateTo(source, target);
}

fn applyHereDocRedirection(shell: anytype, target: host_mod.Fd, here_doc: ast.HereDoc) !host_mod.Pid {
    const body = if (here_doc.delimiter_quoted) here_doc.body else try expandHereDocParts(shell, here_doc.parts);
    return applyPipeInputRedirection(shell, target, body);
}

/// Expands a parsed here-document body. Expansion follows the normal word
/// part rules except that a bare $@ joins the positional parameters with
/// the first IFS character like $* does, matching dash; field splitting
/// never applies inside a here-document.
fn expandHereDocParts(shell: anytype, parts: []const ast.WordPart) EvalError![]const u8 {
    const allocator = shell.scratchAllocator();
    var output: std.ArrayList(u8) = .empty;
    for (parts) |part| {
        const bytes = if (hereDocAtParameter(part))
            try joinPositionals(shell, ifsFirstCharacter(shell))
        else
            try expandWordPart(shell, part, null);
        try output.appendSlice(allocator, bytes);
    }
    return output.toOwnedSlice(allocator);
}

fn hereDocAtParameter(part: ast.WordPart) bool {
    const parameter = switch (part) {
        .parameter => |parameter| parameter,
        else => return false,
    };
    if (parameter.op != null or parameter.length or parameter.array_indices) return false;
    return switch (parameter.parameter) {
        .special => |special| special == .at,
        else => false,
    };
}

fn applyPipeInputRedirection(shell: anytype, target: host_mod.Fd, body: []const u8) !host_mod.Pid {
    const pipe_desc = try shell.host.pipe();
    errdefer {
        shell.host.close(pipe_desc.read) catch {};
        shell.host.close(pipe_desc.write) catch {};
    }

    const pid = switch (try shell.host.forkProcess()) {
        .child => {
            shell.host.close(pipe_desc.read) catch shell.host.exit(127);
            shell.host.writeAll(pipe_desc.write, body) catch shell.host.exit(1);
            shell.host.close(pipe_desc.write) catch shell.host.exit(1);
            shell.host.exit(0);
        },
        .parent => |child_pid| child_pid,
    };

    try shell.host.close(pipe_desc.write);
    if (pipe_desc.read != target) {
        defer shell.host.close(pipe_desc.read) catch {};
        try shell.host.duplicateTo(pipe_desc.read, target);
    } else {
        try shell.host.setCloseOnExec(target, false);
    }
    return pid;
}

fn restoreFrames(shell: anytype, frames: []const RedirectionFrame) !void {
    try (AppliedRedirections{ .frames = frames, .here_doc_writers = &.{} }).restore(shell);
}

fn saveFd(shell: anytype, fd: host_mod.Fd) !host_mod.Fd {
    return shell.host.duplicateAtLeast(fd, 10);
}

fn redirectionFd(redirection: ast.Redirection) host_mod.Fd {
    return if (redirection.fd) |fd| parseKnownFd(fd) else switch (redirection.op) {
        .input, .duplicate_input, .read_write, .here_doc, .here_doc_strip_tabs, .here_string => .stdin,
        .output, .append, .output_and_error, .append_and_error, .duplicate_output, .clobber => .stdout,
    };
}

fn openOptions(operator: ast.RedirectionOperator) host_mod.OpenOptions {
    return switch (operator) {
        .input => .{ .access = .read_only },
        .output, .clobber => .{ .access = .write_only, .create = true, .truncate = true },
        .append => .{ .access = .write_only, .create = true, .append = true },
        .read_write => .{ .access = .read_write, .create = true },
        else => unreachable,
    };
}

fn openRedirectionPath(shell: anytype, path: [:0]const u8, operator: ast.RedirectionOperator) !host_mod.Fd {
    if (operator != .output or !shell.state.options.noclobber) return shell.host.openZ(path, openOptions(operator));

    const opened = shell.host.openZ(path, .{
        .access = .write_only,
        .create = true,
        .exclusive = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if ((try shell.host.fileStatusZ(path)).kind == .file) return error.PathAlreadyExists;
            return shell.host.openZ(path, .{ .access = .write_only });
        },
        else => return err,
    };
    return opened;
}

fn parseFd(text: []const u8) !host_mod.Fd {
    const raw = std.fmt.parseInt(u31, text, 10) catch return error.UnsupportedRedirection;
    return parseKnownFd(raw);
}

fn parseKnownFd(raw: u31) host_mod.Fd {
    return @enumFromInt(@as(i32, @intCast(raw)));
}

fn applyAssignments(shell: anytype, assignments: []const ast.Assignment) !void {
    _ = try applyAssignmentsWithStatus(shell, assignments);
}

fn validateAssignment(shell: anytype, name: []const u8, value: []const u8) !void {
    if (shell.state.getVariableAttributes(name)) |attributes| {
        if (attributes.readonly) {
            try writeReadonlyDiagnostic(shell, name);
            return error.AssignmentError;
        }
    }
    if (shell.state.getVariable(name)) |variable| {
        if (variable.readonly and !std.mem.eql(u8, variable.value, value)) {
            try writeReadonlyDiagnostic(shell, name);
            return error.AssignmentError;
        }
    }
}

fn applyAssignmentsIgnoringReadonly(shell: anytype, assignments: []const ast.Assignment) !void {
    for (assignments) |assignment| {
        var status: ?result.ExitStatus = null;
        _ = applyAssignment(shell, assignment, &status) catch |err| switch (err) {
            error.AssignmentError => {},
            else => return err,
        };
    }
}

fn applyAssignmentsWithStatus(shell: anytype, assignments: []const ast.Assignment) !result.ExitStatus {
    var status: ?result.ExitStatus = null;
    for (assignments) |assignment| {
        _ = try applyAssignment(shell, assignment, &status);
    }
    return status orelse 0;
}

fn expandAndApplyAssignments(shell: anytype, assignments: []const ast.Assignment) ![]const ExpandedAssignment {
    if (assignments.len == 0) return &.{};
    const expanded = try shell.scratchAllocator().alloc(ExpandedAssignment, assignments.len);
    for (assignments, 0..) |assignment, index| {
        var status: ?result.ExitStatus = null;
        const value = try applyAssignment(shell, assignment, &status);
        expanded[index] = .{ .name = assignment.name, .value = value, .status = status };
    }
    return expanded;
}

fn applyAssignment(
    shell: anytype,
    assignment: ast.Assignment,
    substitution_status: ?*?result.ExitStatus,
) ![]const u8 {
    if (assignment.array_values) |values| {
        const append_start = if (assignment.append) compoundArrayAppendStart(shell, assignment.name) else 0;
        const expanded = try expandArrayAssignmentElements(shell, values, append_start, substitution_status);
        const stored = try arrayElementValuesForStorage(shell, assignment.name, expanded, false);
        const applied = if (assignment.append)
            shell.state.appendArrayElements(assignment.name, stored)
        else
            shell.state.putArrayElements(assignment.name, stored);
        applied catch |err| switch (err) {
            error.ReadonlyVariable => {
                try writeReadonlyDiagnostic(shell, assignment.name);
                return error.AssignmentError;
            },
            else => return err,
        };
        return joinArrayElementValues(shell, stored, " ");
    }

    const expanded_value = try expandAssignmentValue(shell, assignment, substitution_status);
    const value = try assignmentValueForStorage(shell, assignment.name, expanded_value);
    if (assignment.index) |index_word| {
        const index = try expandArrayIndexForName(shell, assignment.name, index_word);
        shell.state.putArrayElement(assignment.name, index, value) catch |err| switch (err) {
            error.ReadonlyVariable => {
                try writeReadonlyDiagnostic(shell, assignment.name);
                return error.AssignmentError;
            },
            else => return err,
        };
        return value;
    }

    if (applyDynamicVariableAssignment(shell, assignment.name, value)) return value;
    shell.state.putVariable(.{
        .name = assignment.name,
        .value = value,
        .exported = assignmentExported(shell, assignment.name),
    }) catch |err| switch (err) {
        error.ReadonlyVariable => {
            try writeReadonlyDiagnostic(shell, assignment.name);
            return error.AssignmentError;
        },
        else => return err,
    };
    return value;
}

fn assignmentValueForStorage(shell: anytype, name: []const u8, value: []const u8) ![]const u8 {
    const integer = if (shell.state.getVariable(name)) |variable|
        variable.integer
    else if (shell.state.getArray(name)) |array|
        array.integer
    else if (shell.state.getVariableAttributes(name)) |attributes|
        attributes.integer
    else
        false;
    if (!integer) return value;
    return integerAssignmentValue(shell, value);
}

fn arrayElementValuesForStorage(
    shell: anytype,
    name: []const u8,
    elements: []const state_mod.ArrayElement,
    force_integer: bool,
) ![]const state_mod.ArrayElement {
    const integer = force_integer or if (shell.state.getArray(name)) |array|
        array.integer
    else if (shell.state.getVariable(name)) |variable|
        variable.integer
    else if (shell.state.getVariableAttributes(name)) |attributes|
        attributes.integer
    else
        false;
    if (!integer) return elements;

    const stored = try shell.scratchAllocator().alloc(state_mod.ArrayElement, elements.len);
    for (elements, 0..) |element, index| {
        stored[index] = .{
            .index = element.index,
            .value = try integerAssignmentValue(shell, element.value),
        };
    }
    return stored;
}

fn integerAssignmentValue(shell: anytype, value: []const u8) ![]const u8 {
    const arithmetic_value = try evalArithmeticValue(shell, value);
    return std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{arithmetic_value});
}

fn expandArrayAssignmentElements(
    shell: anytype,
    values: []const ast.ArrayAssignmentElement,
    first_index: usize,
    substitution_status: ?*?result.ExitStatus,
) ![]const state_mod.ArrayElement {
    const expanded = try shell.scratchAllocator().alloc(state_mod.ArrayElement, values.len);
    var next_index = first_index;
    for (values, 0..) |element, expanded_index| {
        const index = if (element.index) |index_word| index: {
            const explicit = try expandArrayIndex(shell, index_word);
            next_index = std.math.add(usize, explicit, 1) catch return error.InvalidArithmetic;
            break :index explicit;
        } else index: {
            const implicit = next_index;
            next_index = std.math.add(usize, next_index, 1) catch return error.InvalidArithmetic;
            break :index implicit;
        };
        expanded[expanded_index] = .{
            .index = index,
            .value = try expandAssignmentWordTracking(shell, element.value, substitution_status),
        };
    }
    return expanded;
}

fn compoundArrayAppendStart(shell: anytype, name: []const u8) usize {
    if (shell.state.getArray(name)) |array| {
        if (array.elements.len != 0) return array.elements[array.elements.len - 1].index + 1;
        return 0;
    }
    if (shell.state.getVariable(name) != null) return 1;
    return 0;
}

fn joinArrayElementValues(
    shell: anytype,
    elements: []const state_mod.ArrayElement,
    separator: []const u8,
) ![]const u8 {
    if (elements.len == 0) return "";
    const values = try shell.scratchAllocator().alloc([]const u8, elements.len);
    for (elements, 0..) |element, index| values[index] = element.value;
    return joinValues(shell, values, separator);
}

fn applyDynamicVariableAssignment(shell: anytype, name: []const u8, value: []const u8) bool {
    if (shell.state.options.mode != .bash) return false;
    if (std.mem.eql(u8, name, "RANDOM")) {
        shell.state.setRandomSeed(value);
        return true;
    }
    if (std.mem.eql(u8, name, "SECONDS")) {
        shell.state.resetSeconds(value, currentWallTimeNs(shell));
        return true;
    }
    if (std.mem.eql(u8, name, "EPOCHSECONDS") or std.mem.eql(u8, name, "EPOCHREALTIME")) {
        shell.state.removeVariable(name);
        return true;
    }
    return false;
}

fn expandAssignmentValue(
    shell: anytype,
    assignment: ast.Assignment,
    substitution_status: ?*?result.ExitStatus,
) ![]const u8 {
    const value = try expandAssignmentWordTracking(shell, assignment.value, substitution_status);
    if (!assignment.append) return value;
    const existing = if (assignment.index) |index_word| existing: {
        const index = try expandArrayIndexForName(shell, assignment.name, index_word);
        const array = shell.state.getArray(assignment.name) orelse {
            if (index == 0) if (shell.state.getVariable(assignment.name)) |variable| break :existing variable.value;
            break :existing "";
        };
        break :existing array.elementValue(index) orelse "";
    } else if (shell.state.getVariable(assignment.name)) |variable| variable.value else "";
    return std.mem.concat(shell.scratchAllocator(), u8, &.{ existing, value });
}

fn expandArrayIndexForName(shell: anytype, name: []const u8, word: ast.Word) !usize {
    const value = try expandArrayIndexValue(shell, word);
    if (value >= 0) return @intCast(value);
    return resolveNegativeArrayIndex(value, shell.state.getArray(name), shell.state.getVariable(name) != null);
}

fn expandArrayIndexForArray(shell: anytype, word: ast.Word, array: state_mod.ArrayVariable) !usize {
    const value = try expandArrayIndexValue(shell, word);
    if (value >= 0) return @intCast(value);
    return resolveNegativeArrayIndex(value, array, false);
}

fn resolveNegativeArrayIndex(value: i64, maybe_array: ?state_mod.ArrayVariable, scalar_is_set: bool) !usize {
    std.debug.assert(value < 0);
    const max_index = if (maybe_array) |array| max: {
        if (array.elements.len == 0) return error.InvalidArithmetic;
        break :max array.elements[array.elements.len - 1].index;
    } else if (scalar_is_set)
        0
    else
        return error.InvalidArithmetic;
    const magnitude: u64 = if (value == std.math.minInt(i64))
        @as(u64, 1) << 63
    else
        @intCast(-value);
    if (magnitude > max_index + 1) return error.InvalidArithmetic;
    return max_index + 1 - @as(usize, @intCast(magnitude));
}

fn expandArrayIndex(shell: anytype, word: ast.Word) !usize {
    const value = try expandArrayIndexValue(shell, word);
    if (value < 0) return error.InvalidArithmetic;
    return @intCast(value);
}

fn expandArrayIndexValue(shell: anytype, word: ast.Word) !i64 {
    const text = try expandWord(shell, word);
    return parseArithmeticValue(shell, text);
}

fn assignmentExported(shell: anytype, name: []const u8) bool {
    return shell.state.options.allexport or if (shell.state.getVariable(name)) |variable| variable.exported else false;
}

fn assignmentExpansionStatus(assignments: []const ExpandedAssignment) result.ExitStatus {
    var status: ?result.ExitStatus = null;
    for (assignments) |assignment| {
        if (assignment.status) |value| status = value;
    }
    return status orelse 0;
}

fn expandWords(shell: anytype, words: []const ast.Word) ![]const []const u8 {
    std.debug.assert(words.len != 0);
    const allocator = shell.scratchAllocator();
    const expanded = try allocator.alloc([]const u8, words.len);
    for (words, 0..) |word, index| expanded[index] = try expandWord(shell, word);
    return expanded;
}

fn expandWordFields(
    shell: anytype,
    words: []const ast.Word,
    substitution_status: ?*?result.ExitStatus,
) EvalError![]const []const u8 {
    std.debug.assert(words.len != 0);
    const allocator = shell.scratchAllocator();
    var fields: std.ArrayList([]const u8) = .empty;

    for (words) |word| {
        if (try braceExpandWord(shell, word)) |brace_expanded| {
            for (brace_expanded) |expanded_word| {
                try appendExpandedWordFields(shell, &fields, expanded_word, substitution_status);
            }
        } else {
            try appendExpandedWordFields(shell, &fields, word, substitution_status);
        }
    }

    return fields.toOwnedSlice(allocator);
}

fn appendExpandedWordFields(
    shell: anytype,
    fields: *std.ArrayList([]const u8),
    word: ast.Word,
    substitution_status: ?*?result.ExitStatus,
) EvalError!void {
    const allocator = shell.scratchAllocator();

    // Fast path for plain literal words: every special-case check below only
    // matches words built from parts, and a literal has no dynamic expansion.
    if (word.data == .literal) {
        try appendStaticWordField(shell, fields, word);
        return;
    }

    if (try appendUnquotedAtFields(shell, fields, word) or
        try appendUnquotedStarFields(shell, fields, word) or
        try appendUnquotedArrayIndexFields(shell, fields, word) or
        try appendEmbeddedUnquotedPositionalFields(shell, fields, word) or
        try appendSpecialQuotedFields(shell, fields, word))
    {
        return;
    } else if (!wordHasDynamicExpansion(word)) {
        try appendStaticWordField(shell, fields, word);
    } else {
        if (wordContainsQuotes(word)) {
            if (wordDynamicExpansionsAreQuoted(word)) {
                try appendPathnameExpandedPattern(
                    shell,
                    fields,
                    try expandQuotedDynamicWordPathnamePattern(shell, word, substitution_status),
                );
            } else {
                const expanded = try expandWordTracking(shell, word, substitution_status);
                const ifs = parameterValue(shell, "IFS") orelse " \t\n";
                if (ifs.len == 0) {
                    try appendPathnameExpandedField(shell, fields, expanded);
                } else {
                    try fields.append(allocator, expanded);
                }
            }
        } else {
            const expanded = try expandWordTracking(shell, word, substitution_status);
            if (wordHasFieldSplittingExpansion(word)) {
                try appendSplitFields(shell, fields, expanded, !wordExpandsLeadingTilde(shell, word));
            } else {
                try appendPathnameExpandedField(shell, fields, expanded);
            }
        }
    }
}

const BraceAtom = union(enum) {
    byte: u8,
    part: ast.WordPart,
};

const BraceExpansion = union(enum) {
    alternatives: []const []const BraceAtom,
    sequence: []const []const u8,
};

const BraceMatch = struct {
    start: usize,
    end: usize,
    expansion: BraceExpansion,
};

/// Returns null when brace expansion does not apply, leaving the word as-is.
fn braceExpandWord(shell: anytype, word: ast.Word) !?[]const ast.Word {
    // A brace match can only start at a literal `{` byte: braceAtomsFromWord
    // produces byte atoms only from literal text and from simple parameter
    // expansions rendered as `$name`, which never contain braces. Skip the
    // per-byte atomize/reparse round trip for the common brace-free word.
    if (shell.state.options.mode == .posix or !wordLiteralsContainBrace(word)) return null;

    const atoms = try braceAtomsFromWord(shell, word);
    var expanded: std.ArrayList(ast.Word) = .empty;
    try appendBraceExpandedWords(shell, &expanded, atoms, word.span, word.quoted);
    return try expanded.toOwnedSlice(shell.scratchAllocator());
}

fn wordLiteralsContainBrace(word: ast.Word) bool {
    return switch (word.data) {
        .literal => |literal| std.mem.indexOfScalar(u8, literal, '{') != null,
        .parts => |parts| for (parts) |part| switch (part) {
            .literal => |literal| if (std.mem.indexOfScalar(u8, literal, '{') != null) break true,
            else => {},
        } else false,
        .declaration_array_assignment => false,
    };
}

fn braceAtomsFromWord(shell: anytype, word: ast.Word) ![]const BraceAtom {
    var atoms: std.ArrayList(BraceAtom) = .empty;
    switch (word.data) {
        .literal => |literal| try appendBraceTextAtoms(shell, &atoms, literal),
        .parts => |parts| for (parts) |part| switch (part) {
            .literal => |literal| try appendBraceTextAtoms(shell, &atoms, literal),
            .parameter => |parameter| if (!try appendBraceParameterAtoms(shell, &atoms, parameter)) {
                try atoms.append(shell.scratchAllocator(), .{ .part = part });
            },
            else => try atoms.append(shell.scratchAllocator(), .{ .part = part }),
        },
        .declaration_array_assignment => unreachable,
    }
    return atoms.toOwnedSlice(shell.scratchAllocator());
}

fn appendBraceTextAtoms(shell: anytype, atoms: *std.ArrayList(BraceAtom), text: []const u8) !void {
    for (text) |byte| try atoms.append(shell.scratchAllocator(), .{ .byte = byte });
}

fn appendBraceParameterAtoms(
    shell: anytype,
    atoms: *std.ArrayList(BraceAtom),
    parameter: ast.ParameterExpansion,
) !bool {
    const text = try unbracedParameterExpansionText(shell, parameter) orelse return false;
    try appendBraceTextAtoms(shell, atoms, text);
    return true;
}

fn unbracedParameterExpansionText(shell: anytype, expansion: ast.ParameterExpansion) !?[]const u8 {
    if (expansion.length or expansion.array_indices or expansion.colon or
        expansion.op != null or expansion.word != null)
    {
        return null;
    }

    const expected_len: usize = switch (expansion.parameter) {
        .variable => |name| 1 + name.len,
        .array => return null,
        .positional, .special => 2,
    };
    if (expansion.span.len() != expected_len) return null;

    return switch (expansion.parameter) {
        .variable => |name| try std.fmt.allocPrint(shell.scratchAllocator(), "${s}", .{name}),
        .array => null,
        .positional => |index| if (index < 10)
            try std.fmt.allocPrint(shell.scratchAllocator(), "${}", .{index})
        else
            null,
        .special => |special| try std.fmt.allocPrint(
            shell.scratchAllocator(),
            "${c}",
            .{specialParameterByte(special)},
        ),
    };
}

fn specialParameterByte(parameter: ast.SpecialParameter) u8 {
    return switch (parameter) {
        .at => '@',
        .star => '*',
        .hash => '#',
        .question => '?',
        .hyphen => '-',
        .dollar => '$',
        .bang => '!',
    };
}

fn appendBraceExpandedWords(
    shell: anytype,
    words: *std.ArrayList(ast.Word),
    atoms: []const BraceAtom,
    span: source_mod.Span,
    quoted: bool,
) !void {
    const match = try firstBraceMatch(shell, atoms) orelse {
        // Bash removes unquoted words that brace expansion leaves fully
        // empty, e.g. `{,x}` yields only `x`. Empty atom lists can only
        // arise from a splice: the parser never produces an empty unquoted
        // word, and braceExpandWord only atomizes words containing `{`.
        if (atoms.len == 0 and !quoted) return;
        try words.append(shell.scratchAllocator(), try wordFromBraceAtoms(shell, atoms, span, quoted));
        return;
    };

    switch (match.expansion) {
        .alternatives => |alternatives| {
            for (alternatives) |alternative| {
                const expanded = try spliceBraceAtoms(
                    shell,
                    atoms[0..match.start],
                    alternative,
                    atoms[match.end + 1 ..],
                );
                try appendBraceExpandedWords(shell, words, expanded, span, quoted);
            }
        },
        .sequence => |items| {
            for (items) |item| {
                const item_atoms = try textBraceAtoms(shell, item);
                const expanded = try spliceBraceAtoms(
                    shell,
                    atoms[0..match.start],
                    item_atoms,
                    atoms[match.end + 1 ..],
                );
                try appendBraceExpandedWords(shell, words, expanded, span, quoted);
            }
        },
    }
}

fn firstBraceMatch(shell: anytype, atoms: []const BraceAtom) !?BraceMatch {
    var index: usize = 0;
    while (index < atoms.len) : (index += 1) {
        if (!braceAtomByteEquals(atoms[index], '{')) continue;
        const end = matchingBraceEnd(atoms, index) orelse continue;
        const content = atoms[index + 1 .. end];
        if (try braceSequence(shell, content)) |sequence| {
            return .{ .start = index, .end = end, .expansion = .{ .sequence = sequence } };
        }
        if (try braceAlternatives(shell, content)) |alternatives| {
            return .{ .start = index, .end = end, .expansion = .{ .alternatives = alternatives } };
        }
    }
    return null;
}

fn matchingBraceEnd(atoms: []const BraceAtom, start: usize) ?usize {
    std.debug.assert(braceAtomByteEquals(atoms[start], '{'));
    var depth: usize = 0;
    for (atoms[start..], start..) |atom, index| {
        if (braceAtomByteEquals(atom, '{')) {
            depth += 1;
        } else if (braceAtomByteEquals(atom, '}')) {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn braceAlternatives(shell: anytype, content: []const BraceAtom) !?[]const []const BraceAtom {
    var alternatives: std.ArrayList([]const BraceAtom) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    var found_comma = false;

    for (content, 0..) |atom, index| {
        if (braceAtomByteEquals(atom, '{')) {
            depth += 1;
        } else if (braceAtomByteEquals(atom, '}')) {
            if (depth == 0) return null;
            depth -= 1;
        } else if (depth == 0 and braceAtomByteEquals(atom, ',')) {
            found_comma = true;
            try alternatives.append(shell.scratchAllocator(), content[start..index]);
            start = index + 1;
        }
    }
    if (!found_comma) return null;
    try alternatives.append(shell.scratchAllocator(), content[start..]);
    return try alternatives.toOwnedSlice(shell.scratchAllocator());
}

fn braceSequence(shell: anytype, content: []const BraceAtom) !?[]const []const u8 {
    const text = try braceAtomText(shell, content) orelse return null;
    var parts: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var index: usize = 0;
    while (index + 1 < text.len) : (index += 1) {
        if (text[index] == '.' and text[index + 1] == '.') {
            try parts.append(shell.scratchAllocator(), text[start..index]);
            index += 1;
            start = index + 1;
        }
    }
    if (parts.items.len == 0) return null;
    try parts.append(shell.scratchAllocator(), text[start..]);
    if (parts.items.len == 2 or parts.items.len == 3) {
        if (try numericBraceSequence(shell, parts.items)) |sequence| return sequence;
        if (try alphabeticBraceSequence(shell, parts.items)) |sequence| return sequence;
    }
    return null;
}

const NumericBraceBound = struct {
    value: i64,
    width: usize,
    padded: bool,
};

fn numericBraceSequence(shell: anytype, parts: []const []const u8) !?[]const []const u8 {
    const start = parseNumericBraceBound(parts[0]) orelse return null;
    const end = parseNumericBraceBound(parts[1]) orelse return null;
    const raw_step = if (parts.len == 3) std.fmt.parseInt(i64, parts[2], 10) catch return null else 1;
    const step_magnitude: i128 = if (raw_step == 0) 1 else @intCast(@abs(raw_step));
    const step = if (start.value <= end.value) step_magnitude else -step_magnitude;
    const width = @max(start.width, end.width);
    const padded = start.padded or end.padded;

    var items: std.ArrayList([]const u8) = .empty;
    var value = start.value;
    while (true) {
        const text = if (padded)
            try paddedNumericBraceValue(shell, value, width)
        else
            try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{value});
        try items.append(shell.scratchAllocator(), text);

        const next: i128 = @as(i128, value) + step;
        if (step > 0) {
            if (next > end.value) break;
        } else if (next < end.value) break;
        value = @intCast(next);
    }
    return try items.toOwnedSlice(shell.scratchAllocator());
}

fn paddedNumericBraceValue(shell: anytype, value: i64, width: usize) ![]const u8 {
    const raw = try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{value});
    const sign_len: usize = if (raw[0] == '-') 1 else 0;
    if (raw.len - sign_len >= width) return raw;

    const zero_count = width - (raw.len - sign_len);
    const padded = try shell.scratchAllocator().alloc(u8, sign_len + zero_count + raw.len - sign_len);
    if (sign_len != 0) padded[0] = raw[0];
    @memset(padded[sign_len..][0..zero_count], '0');
    @memcpy(padded[sign_len + zero_count ..], raw[sign_len..]);
    return padded;
}

fn parseNumericBraceBound(text: []const u8) ?NumericBraceBound {
    if (text.len == 0) return null;
    var digit_start: usize = 0;
    if (text[0] == '-' or text[0] == '+') digit_start = 1;
    if (digit_start == text.len) return null;
    for (text[digit_start..]) |byte| if (!std.ascii.isDigit(byte)) return null;
    const digits = text[digit_start..];
    return .{
        .value = std.fmt.parseInt(i64, text, 10) catch return null,
        .width = digits.len,
        .padded = digits.len > 1 and digits[0] == '0',
    };
}

fn alphabeticBraceSequence(shell: anytype, parts: []const []const u8) !?[]const []const u8 {
    if (parts[0].len != 1 or parts[1].len != 1) return null;
    if (!std.ascii.isAlphabetic(parts[0][0]) or !std.ascii.isAlphabetic(parts[1][0])) return null;
    const raw_step = if (parts.len == 3) std.fmt.parseInt(i64, parts[2], 10) catch return null else 1;
    const start: i64 = parts[0][0];
    const end: i64 = parts[1][0];
    const step_magnitude: i128 = if (raw_step == 0) 1 else @intCast(@abs(raw_step));
    const step = if (start <= end) step_magnitude else -step_magnitude;

    var items: std.ArrayList([]const u8) = .empty;
    var value = start;
    while (true) {
        const text = try shell.scratchAllocator().alloc(u8, 1);
        text[0] = @intCast(value);
        try items.append(shell.scratchAllocator(), text);

        const next: i128 = @as(i128, value) + step;
        if (step > 0) {
            if (next > end) break;
        } else if (next < end) break;
        value = @intCast(next);
    }
    return try items.toOwnedSlice(shell.scratchAllocator());
}

fn braceAtomText(shell: anytype, atoms: []const BraceAtom) !?[]const u8 {
    for (atoms) |atom| if (atom != .byte) return null;
    return try braceAtomsText(shell, atoms);
}

fn braceAtomByteEquals(atom: BraceAtom, byte: u8) bool {
    return atom == .byte and atom.byte == byte;
}

fn textBraceAtoms(shell: anytype, text: []const u8) ![]const BraceAtom {
    const atoms = try shell.scratchAllocator().alloc(BraceAtom, text.len);
    for (text, 0..) |byte, index| atoms[index] = .{ .byte = byte };
    return atoms;
}

fn spliceBraceAtoms(
    shell: anytype,
    prefix: []const BraceAtom,
    middle: []const BraceAtom,
    suffix: []const BraceAtom,
) ![]const BraceAtom {
    const atoms = try shell.scratchAllocator().alloc(BraceAtom, prefix.len + middle.len + suffix.len);
    @memcpy(atoms[0..prefix.len], prefix);
    @memcpy(atoms[prefix.len..][0..middle.len], middle);
    @memcpy(atoms[prefix.len + middle.len ..], suffix);
    return atoms;
}

fn wordFromBraceAtoms(shell: anytype, atoms: []const BraceAtom, span: source_mod.Span, quoted: bool) !ast.Word {
    var has_part = false;
    for (atoms) |atom| if (atom == .part) {
        has_part = true;
        break;
    };
    if (!has_part) {
        var word = try parser.parseWordExpansionText(shell.scratchAllocator(), try braceAtomsText(shell, atoms), span);
        word.quoted = quoted;
        return word;
    }

    var parts: std.ArrayList(ast.WordPart) = .empty;
    var text: std.ArrayList(u8) = .empty;
    for (atoms) |atom| switch (atom) {
        .byte => |byte| try text.append(shell.scratchAllocator(), byte),
        .part => |part| {
            if (text.items.len != 0) {
                try parts.append(shell.scratchAllocator(), .{
                    .literal = try text.toOwnedSlice(shell.scratchAllocator()),
                });
                text = .empty;
            }
            try parts.append(shell.scratchAllocator(), part);
        },
    };
    if (text.items.len != 0) {
        try parts.append(shell.scratchAllocator(), .{ .literal = try text.toOwnedSlice(shell.scratchAllocator()) });
    }
    return .{ .data = .{ .parts = try parts.toOwnedSlice(shell.scratchAllocator()) }, .span = span, .quoted = quoted };
}

fn braceAtomsText(shell: anytype, atoms: []const BraceAtom) ![]const u8 {
    const text = try shell.scratchAllocator().alloc(u8, atoms.len);
    for (atoms, 0..) |atom, index| text[index] = atom.byte;
    return text;
}

fn appendStaticWordField(shell: anytype, fields: *std.ArrayList([]const u8), word: ast.Word) !void {
    const expanded = try expandWordTracking(shell, word, null);
    if (wordExpandsLeadingTilde(shell, word)) {
        try fields.append(shell.scratchAllocator(), expanded);
    } else if (word.quoted) {
        try appendPathnameExpandedPattern(shell, fields, try staticWordPathnamePattern(shell, word));
    } else {
        try appendPathnameExpandedField(shell, fields, expanded);
    }
}

fn wordHasDynamicExpansion(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| partsHaveDynamicExpansion(parts),
        .declaration_array_assignment => false,
    };
}

fn partsHaveDynamicExpansion(parts: []const ast.WordPart) bool {
    for (parts) |part| switch (part) {
        .parameter, .command_substitution, .process_substitution, .arithmetic => return true,
        .double_quoted => |nested| if (partsHaveDynamicExpansion(nested)) return true,
        else => {},
    };
    return false;
}

fn wordHasFieldSplittingExpansion(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| partsHaveFieldSplittingExpansion(parts),
        .declaration_array_assignment => false,
    };
}

fn partsHaveFieldSplittingExpansion(parts: []const ast.WordPart) bool {
    for (parts) |part| switch (part) {
        .parameter, .command_substitution, .arithmetic => return true,
        .double_quoted => {},
        else => {},
    };
    return false;
}

fn wordDynamicExpansionsAreQuoted(word: ast.Word) bool {
    return switch (word.data) {
        .literal => true,
        .parts => |parts| partsDynamicExpansionsAreQuoted(parts, false),
        .declaration_array_assignment => false,
    };
}

fn partsDynamicExpansionsAreQuoted(parts: []const ast.WordPart, quoted: bool) bool {
    for (parts) |part| switch (part) {
        .parameter, .command_substitution, .process_substitution, .arithmetic => if (!quoted) return false,
        .double_quoted => |nested| if (!partsDynamicExpansionsAreQuoted(nested, true)) return false,
        else => {},
    };
    return true;
}

fn staticWordPathnamePattern(shell: anytype, word: ast.Word) !PathnamePattern {
    const allocator = shell.scratchAllocator();
    var text: std.ArrayList(u8) = .empty;
    var special: std.ArrayList(bool) = .empty;
    switch (word.data) {
        .literal => |literal| try appendPathnamePatternBytes(allocator, &text, &special, literal, true),
        .parts => |parts| try appendStaticWordPathnameParts(allocator, &text, &special, parts, false),
        .declaration_array_assignment => unreachable,
    }
    return .{ .text = try text.toOwnedSlice(allocator), .special = try special.toOwnedSlice(allocator) };
}

fn appendStaticWordPathnameParts(
    allocator: std.mem.Allocator,
    text: *std.ArrayList(u8),
    special: *std.ArrayList(bool),
    parts: []const ast.WordPart,
    quoted: bool,
) !void {
    for (parts) |part| switch (part) {
        .literal => |bytes| try appendPathnamePatternBytes(allocator, text, special, bytes, !quoted),
        .escaped, .single_quoted => |bytes| try appendPathnamePatternBytes(allocator, text, special, bytes, false),
        .double_quoted => |nested| try appendStaticWordPathnameParts(allocator, text, special, nested, true),
        .parameter, .command_substitution, .process_substitution, .arithmetic => unreachable,
    };
}

fn expandQuotedDynamicWordPathnamePattern(
    shell: anytype,
    word: ast.Word,
    substitution_status: ?*?result.ExitStatus,
) EvalError!PathnamePattern {
    const allocator = shell.scratchAllocator();
    var text: std.ArrayList(u8) = .empty;
    var special: std.ArrayList(bool) = .empty;
    switch (word.data) {
        .literal => |literal| try appendPathnamePatternBytes(allocator, &text, &special, literal, true),
        .parts => |parts| try appendExpandedWordPathnameParts(
            shell,
            &text,
            &special,
            parts,
            false,
            substitution_status,
        ),
        .declaration_array_assignment => unreachable,
    }
    return .{ .text = try text.toOwnedSlice(allocator), .special = try special.toOwnedSlice(allocator) };
}

fn appendExpandedWordPathnameParts(
    shell: anytype,
    text: *std.ArrayList(u8),
    special: *std.ArrayList(bool),
    parts: []const ast.WordPart,
    quoted: bool,
    substitution_status: ?*?result.ExitStatus,
) EvalError!void {
    const allocator = shell.scratchAllocator();
    for (parts) |part| switch (part) {
        .literal => |bytes| try appendPathnamePatternBytes(allocator, text, special, bytes, !quoted),
        .escaped, .single_quoted => |bytes| try appendPathnamePatternBytes(allocator, text, special, bytes, false),
        .double_quoted => |nested| try appendExpandedWordPathnameParts(
            shell,
            text,
            special,
            nested,
            true,
            substitution_status,
        ),
        .parameter, .command_substitution, .process_substitution, .arithmetic => {
            std.debug.assert(quoted);
            const bytes = try expandWordPart(shell, part, substitution_status);
            try appendPathnamePatternBytes(allocator, text, special, bytes, false);
        },
    };
}

fn appendPathnamePatternBytes(
    allocator: std.mem.Allocator,
    text: *std.ArrayList(u8),
    special: *std.ArrayList(bool),
    bytes: []const u8,
    are_special: bool,
) !void {
    try text.appendSlice(allocator, bytes);
    try special.appendNTimes(allocator, are_special, bytes.len);
}

fn appendSplitFields(
    shell: anytype,
    fields: *std.ArrayList([]const u8),
    text: []const u8,
    pathname_expansion: bool,
) !void {
    const ifs = parameterValue(shell, "IFS") orelse " \t\n";
    if (ifs.len == 0) {
        if (text.len != 0) try appendMaybePathnameExpandedField(shell, fields, text, pathname_expansion);
        return;
    }

    var index: usize = 0;
    while (ifsDelimiter(ifs, text, index)) |delimiter| {
        if (!delimiter.whitespace) break;
        index += delimiter.len;
    }

    var field_start = index;
    while (index < text.len) {
        if (ifsDelimiter(ifs, text, index)) |delimiter| {
            if (delimiter.whitespace) {
                if (field_start < index) try appendMaybePathnameExpandedField(
                    shell,
                    fields,
                    text[field_start..index],
                    pathname_expansion,
                );
                index += delimiter.len;
                while (ifsDelimiter(ifs, text, index)) |next| {
                    if (!next.whitespace) break;
                    index += next.len;
                }
                if (ifsDelimiter(ifs, text, index)) |next| {
                    if (!next.whitespace) {
                        index += next.len;
                        while (ifsDelimiter(ifs, text, index)) |after| {
                            if (!after.whitespace) break;
                            index += after.len;
                        }
                    }
                }
                field_start = index;
                continue;
            }

            try appendMaybePathnameExpandedField(shell, fields, text[field_start..index], pathname_expansion);
            index += delimiter.len;
            while (ifsDelimiter(ifs, text, index)) |next| {
                if (!next.whitespace) break;
                index += next.len;
            }
            field_start = index;
            continue;
        }

        index += utf8SequenceLength(text[index..]);
    }
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (field_start < text.len) try appendMaybePathnameExpandedField(shell, fields, text[field_start..], pathname_expansion);
}

fn appendMaybePathnameExpandedField(
    shell: anytype,
    fields: *std.ArrayList([]const u8),
    field: []const u8,
    pathname_expansion: bool,
) !void {
    if (!pathname_expansion) {
        try fields.append(shell.scratchAllocator(), field);
        return;
    }
    try appendPathnameExpandedField(shell, fields, field);
}

const PathnamePattern = pattern_mod.Pattern;

fn appendPathnameExpandedField(shell: anytype, fields: *std.ArrayList([]const u8), field: []const u8) !void {
    try appendPathnameExpandedPattern(shell, fields, .{ .text = field });
}

fn appendPathnameExpandedPattern(shell: anytype, fields: *std.ArrayList([]const u8), pattern: PathnamePattern) !void {
    if (shell.state.options.noglob or !pattern_mod.containsMeta(pattern)) {
        try fields.append(shell.scratchAllocator(), pattern.text);
        return;
    }
    if (try appendFinalPathnameExpansion(shell, fields, pattern)) return;

    var matches: std.ArrayList([]const u8) = .empty;
    const allocator = shell.scratchAllocator();
    try expandPathnamePattern(shell, allocator, &matches, "", pattern);

    if (matches.items.len == 0) {
        try fields.append(allocator, pattern.text);
        return;
    }
    std.mem.sort([]const u8, matches.items, {}, stringLessThan);
    try fields.appendSlice(allocator, matches.items);
}

const FinalPathnamePattern = struct {
    prefix: []const u8,
    component: PathnamePattern,
};

fn appendFinalPathnameExpansion(shell: anytype, fields: *std.ArrayList([]const u8), pattern: PathnamePattern) !bool {
    const final = finalPathnamePattern(pattern) orelse return false;
    const allocator = shell.scratchAllocator();
    const directory_path = if (final.prefix.len == 0) "." else final.prefix;
    const directory = shell.host.listDir(allocator, directory_path) catch {
        try fields.append(allocator, pattern.text);
        return true;
    };

    var names: std.ArrayList([]const u8) = .empty;
    try appendMatchingEntryNames(allocator, &names, final.component, directory.entries);
    if (names.items.len == 0) {
        try fields.append(allocator, pattern.text);
        return true;
    }

    std.mem.sort([]const u8, names.items, {}, stringLessThan);
    try fields.ensureUnusedCapacity(allocator, names.items.len);
    for (names.items) |name| {
        const field = if (final.prefix.len == 0) name else try joinPathComponent(allocator, final.prefix, name);
        fields.appendAssumeCapacity(field);
    }
    return true;
}

fn finalPathnamePattern(pattern: PathnamePattern) ?FinalPathnamePattern {
    // ziglint-ignore: Z011 deprecated API left unchanged to avoid semantic drift in lint-only pass
    const slash_index = std.mem.lastIndexOfScalar(u8, pattern.text, '/');
    if (slash_index) |index| {
        if (index == pattern.text.len - 1) return null;
        const prefix_end = if (index == 0) 1 else index;
        const prefix = pattern.slice(0, prefix_end);
        if (pattern_mod.containsMeta(prefix)) return null;
        const component = pattern.slice(index + 1, pattern.text.len);
        return .{ .prefix = prefix.text, .component = component };
    }
    return .{ .prefix = "", .component = pattern };
}

fn expandPathnamePattern(
    shell: anytype,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    allocator: std.mem.Allocator,
    matches: *std.ArrayList([]const u8),
    prefix: []const u8,
    remaining: PathnamePattern,
) error{OutOfMemory}!void {
    // ziglint-ignore: Z011 deprecated API left unchanged to avoid semantic drift in lint-only pass
    const slash_index = std.mem.indexOfScalar(u8, remaining.text, '/');
    const component = if (slash_index) |index| remaining.slice(0, index) else remaining;
    const rest = if (slash_index) |index|
        remaining.slice(index + 1, remaining.text.len)
    else
        PathnamePattern{ .text = "" };
    const trailing_slash = slash_index != null and rest.text.len == 0;
    if (component.text.len == 0) {
        if (prefix.len == 0 and slash_index == 0 and rest.text.len != 0) {
            try expandPathnamePattern(shell, allocator, matches, "/", rest);
        } else if (slash_index != null and rest.text.len != 0) {
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            try expandPathnamePattern(shell, allocator, matches, try std.fmt.allocPrint(allocator, "{s}/", .{prefix}), rest);
        }
        return;
    }

    if (!pattern_mod.containsMeta(component)) {
        const candidate = try joinPathComponent(allocator, prefix, component.text);
        if (trailing_slash) {
            if (try pathIsDirectory(shell, candidate, .other)) {
                try matches.append(allocator, try std.fmt.allocPrint(allocator, "{s}/", .{candidate}));
            }
        } else if (rest.text.len == 0) {
            try matches.append(allocator, candidate);
        } else {
            try expandPathnamePattern(shell, allocator, matches, candidate, rest);
        }
        return;
    }

    const directory_path = if (prefix.len == 0) "." else prefix;
    const directory = shell.host.listDir(allocator, directory_path) catch return;
    var saw_dot = false;
    var saw_dotdot = false;
    for (directory.entries) |entry| {
        if (std.mem.eql(u8, entry.name, ".")) saw_dot = true;
        if (std.mem.eql(u8, entry.name, "..")) saw_dotdot = true;
        if (entry.name[0] == '.' and component.text[0] != '.') continue;
        if (!pattern_mod.matches(component, entry.name)) continue;

        const candidate = try joinPathComponent(allocator, prefix, entry.name);
        if (trailing_slash) {
            if (try pathIsDirectory(shell, candidate, entry.kind)) {
                try matches.append(allocator, try std.fmt.allocPrint(allocator, "{s}/", .{candidate}));
            }
        } else if (rest.text.len == 0) {
            try matches.append(allocator, candidate);
        } else {
            try expandPathnamePattern(shell, allocator, matches, candidate, rest);
        }
    }
    if (component.text[0] == '.') {
        if (!saw_dot) {
            try appendSyntheticDotPathnameMatch(
                shell,
                allocator,
                matches,
                prefix,
                component,
                rest,
                trailing_slash,
                ".",
            );
        }
        if (!saw_dotdot) {
            try appendSyntheticDotPathnameMatch(
                shell,
                allocator,
                matches,
                prefix,
                component,
                rest,
                trailing_slash,
                "..",
            );
        }
    }
}

fn appendMatchingEntryNames(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    component: PathnamePattern,
    entries: []const host_mod.DirectoryEntry,
) error{OutOfMemory}!void {
    var saw_dot = false;
    var saw_dotdot = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, ".")) saw_dot = true;
        if (std.mem.eql(u8, entry.name, "..")) saw_dotdot = true;
        if (entry.name[0] == '.' and component.text[0] != '.') continue;
        if (!pattern_mod.matches(component, entry.name)) continue;
        try names.append(allocator, entry.name);
    }
    if (component.text[0] == '.') {
        if (!saw_dot and pattern_mod.matches(component, ".")) try names.append(allocator, ".");
        if (!saw_dotdot and pattern_mod.matches(component, "..")) try names.append(allocator, "..");
    }
}

fn appendSyntheticDotPathnameMatch(
    shell: anytype,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    allocator: std.mem.Allocator,
    matches: *std.ArrayList([]const u8),
    prefix: []const u8,
    component: PathnamePattern,
    rest: PathnamePattern,
    trailing_slash: bool,
    entry_name: []const u8,
) error{OutOfMemory}!void {
    if (!pattern_mod.matches(component, entry_name)) return;
    const candidate = try joinPathComponent(allocator, prefix, entry_name);
    if (trailing_slash) {
        try matches.append(allocator, try std.fmt.allocPrint(allocator, "{s}/", .{candidate}));
    } else if (rest.text.len == 0) {
        try matches.append(allocator, candidate);
    } else {
        try expandPathnamePattern(shell, allocator, matches, candidate, rest);
    }
}

fn joinPathComponent(allocator: std.mem.Allocator, prefix: []const u8, component: []const u8) ![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, component);
    const needs_separator = !std.mem.eql(u8, prefix, "/");
    const len = prefix.len + @intFromBool(needs_separator) + component.len;
    const path = try allocator.alloc(u8, len);
    @memcpy(path[0..prefix.len], prefix);
    var index = prefix.len;
    if (needs_separator) {
        path[index] = '/';
        index += 1;
    }
    @memcpy(path[index..][0..component.len], component);
    return path;
}

fn pathIsDirectory(shell: anytype, path: []const u8, kind: host_mod.FileKind) !bool {
    if (kind == .directory) return true;
    if (kind == .file) return false;
    const allocator = shell.scratchAllocator();
    const directory = shell.host.listDir(allocator, path) catch return false;
    _ = directory;
    return true;
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn isDefaultIfsWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
}

const IfsDelimiter = struct {
    len: usize,
    whitespace: bool,
};

fn ifsDelimiter(ifs: []const u8, text: []const u8, index: usize) ?IfsDelimiter {
    if (index >= text.len) return null;
    var ifs_index: usize = 0;
    while (ifs_index < ifs.len) {
        const len = utf8SequenceLength(ifs[ifs_index..]);
        if (index + len <= text.len and std.mem.eql(u8, text[index..][0..len], ifs[ifs_index..][0..len])) {
            return .{ .len = len, .whitespace = len == 1 and isDefaultIfsWhitespace(ifs[ifs_index]) };
        }
        ifs_index += len;
    }
    return null;
}

fn ifsHasNonWhitespaceDelimiter(ifs: []const u8) bool {
    var index: usize = 0;
    while (index < ifs.len) {
        const len = utf8SequenceLength(ifs[index..]);
        if (len != 1 or !isDefaultIfsWhitespace(ifs[index])) return true;
        index += len;
    }
    return false;
}

fn utf8SequenceLength(text: []const u8) usize {
    if (text.len == 0) return 0;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
    return @min(len, text.len);
}

fn wordContainsQuotes(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| partsContainQuotes(parts),
        .declaration_array_assignment => false,
    };
}

fn partsContainQuotes(parts: []const ast.WordPart) bool {
    for (parts) |part| switch (part) {
        .escaped, .single_quoted, .double_quoted => return true,
        else => {},
    };
    return false;
}

fn expandWord(shell: anytype, word: ast.Word) ![]const u8 {
    return expandWordTracking(shell, word, null);
}

pub fn expandParametersScalar(shell: anytype, text: []const u8) ![]const u8 {
    const allocator = shell.scratchAllocator();
    const expansions = try parser.parseParameterExpansionText(allocator, text);
    if (expansions.len == 0) return text;

    var output: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (expansions) |expansion| {
        std.debug.assert(expansion.span.start >= cursor);
        std.debug.assert(expansion.span.end <= text.len);
        try output.appendSlice(allocator, text[cursor..expansion.span.start]);
        try output.appendSlice(allocator, try expandParameter(shell, expansion));
        cursor = expansion.span.end;
    }
    try output.appendSlice(allocator, text[cursor..]);
    return output.toOwnedSlice(allocator);
}

fn expandWordTracking(shell: anytype, word: ast.Word, substitution_status: ?*?result.ExitStatus) ![]const u8 {
    const expanded = switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| try expandWordParts(shell, parts, substitution_status),
        .declaration_array_assignment => unreachable,
    };
    return expandLeadingTilde(shell, word, expanded);
}

fn expandAssignmentWordTracking(shell: anytype, word: ast.Word, substitution_status: ?*?result.ExitStatus) ![]const u8 {
    if (word.quoted) return expandWordTracking(shell, word, substitution_status);
    return switch (word.data) {
        .literal => |literal| expandAssignmentLiteralTildes(shell, literal),
        .parts => expandWordTracking(shell, word, substitution_status),
        .declaration_array_assignment => unreachable,
    };
}

fn expandAssignmentLiteralTildes(shell: anytype, literal: []const u8) ![]const u8 {
    const home = homeValue(shell) orelse return literal;
    var output: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    var index: usize = 0;
    while (index < literal.len) {
        if ((index == 0 or literal[index - 1] == ':') and assignmentTildePrefixLen(literal[index..]) != null) {
            try output.appendSlice(allocator, home);
            index += 1;
        } else {
            try output.append(allocator, literal[index]);
            index += 1;
        }
    }
    return output.toOwnedSlice(allocator);
}

fn expandLeadingTilde(shell: anytype, word: ast.Word, expanded: []const u8) ![]const u8 {
    if (word.quoted) return expanded;
    const literal = switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| if (parts.len != 0) switch (parts[0]) {
            .literal => |literal| literal,
            else => return expanded,
        } else return expanded,
        .declaration_array_assignment => return expanded,
    };
    const prefix_len = tildePrefixLen(literal) orelse return expanded;
    const home = homeValue(shell) orelse return expanded;
    return std.fmt.allocPrint(shell.scratchAllocator(), "{s}{s}", .{ home, expanded[prefix_len..] });
}

fn wordExpandsLeadingTilde(shell: anytype, word: ast.Word) bool {
    if (word.quoted) return false;
    const literal = switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| if (parts.len != 0) switch (parts[0]) {
            .literal => |literal| literal,
            else => return false,
        } else return false,
        .declaration_array_assignment => return false,
    };
    return tildePrefixLen(literal) != null and homeValue(shell) != null;
}

fn tildePrefixLen(literal: []const u8) ?usize {
    if (literal.len == 0 or literal[0] != '~') return null;
    if (literal.len == 1 or literal[1] == '/') return 1;
    return null;
}

fn assignmentTildePrefixLen(literal: []const u8) ?usize {
    if (literal.len == 0 or literal[0] != '~') return null;
    if (literal.len == 1 or literal[1] == '/' or literal[1] == ':') return 1;
    return null;
}

fn homeValue(shell: anytype) ?[]const u8 {
    if (parameterValue(shell, "HOME")) |home| return home;
    return envValue(shell.env, "HOME");
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn expandWordParts(shell: anytype, parts: []const ast.WordPart, substitution_status: ?*?result.ExitStatus) EvalError![]const u8 {
    if (parts.len == 0) return "";
    if (parts.len == 1) return expandWordPart(shell, parts[0], substitution_status);

    const allocator = shell.scratchAllocator();
    var stack_expanded: [8][]const u8 = undefined;
    const expanded = if (parts.len <= stack_expanded.len)
        stack_expanded[0..parts.len]
    else
        try allocator.alloc([]const u8, parts.len);

    var total_len: usize = 0;
    for (parts, 0..) |part, index| {
        const bytes = try expandWordPart(shell, part, substitution_status);
        expanded[index] = bytes;
        total_len = std.math.add(usize, total_len, bytes.len) catch return error.OutOfMemory;
    }
    if (total_len == 0) return "";

    const output = try allocator.alloc(u8, total_len);
    var cursor: usize = 0;
    for (expanded) |bytes| {
        @memcpy(output[cursor..][0..bytes.len], bytes);
        cursor += bytes.len;
    }
    return output;
}

fn expandWordPart(shell: anytype, part: ast.WordPart, substitution_status: ?*?result.ExitStatus) EvalError![]const u8 {
    return switch (part) {
        .literal, .escaped, .single_quoted => |bytes| bytes,
        .arithmetic => |text| expandArithmetic(shell, text),
        .double_quoted => |parts| expandWordParts(shell, parts, substitution_status),
        .parameter => |parameter| expandParameter(shell, parameter),
        .command_substitution => |substitution| expandCommandSubstitution(shell, substitution, substitution_status),
        .process_substitution => |substitution| expandProcessSubstitution(shell, substitution),
    };
}

fn expandArithmetic(shell: anytype, text: []const u8) ![]const u8 {
    const value = try parseArithmeticValue(shell, text);
    return std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{value});
}

fn evalArithmeticValue(shell: anytype, text: []const u8) !i64 {
    const scratch = try shell.beginScratchScope();
    defer scratch.end();
    return parseArithmeticValue(shell, text);
}

fn parseArithmeticValue(shell: anytype, text: []const u8) !i64 {
    const expanded = try expandArithmeticText(shell, text);
    var parser_state: ArithmeticParser(@TypeOf(shell)) = .{ .shell = shell, .text = expanded };
    return parser_state.parse();
}

fn expandProcessSubstitution(shell: anytype, substitution: ast.ProcessSubstitution) EvalError![]const u8 {
    validateAst(substitution);
    const program = if (substitution.parsed) |program| program.* else program: {
        const src: source_mod.Source = .{
            .id = 0,
            .kind = .command_string,
            .name = if (substitution.kind == .input) "<()" else ">()",
            .text = substitution.source_text,
        };
        const ast_allocator = shell.astAllocator();
        const tokens = try lexer.lexWithAliases(ast_allocator, src, shell.state);
        break :program try parser.parseWithAliases(ast_allocator, src, tokens, shell.state);
    };

    const pipe_desc = try shell.host.pipe();
    errdefer {
        shell.host.close(pipe_desc.read) catch {};
        shell.host.close(pipe_desc.write) catch {};
    }

    const parent_original = if (substitution.kind == .input) pipe_desc.read else pipe_desc.write;
    const parent_fd = try shell.host.duplicateAtLeast(parent_original, 10);
    errdefer shell.host.close(parent_fd) catch {};
    try shell.host.setCloseOnExec(parent_fd, false);

    var spawned_pid: ?host_mod.Pid = null;
    errdefer if (spawned_pid) |spawned| reapOrDeferProcessSubstitution(shell, spawned);

    const pid = switch (try shell.host.forkProcess()) {
        .child => {
            closeInheritedProcessSubstitutionFds(shell);
            shell.host.close(parent_fd) catch shell.host.exit(127);
            switch (substitution.kind) {
                .input => {
                    shell.host.close(pipe_desc.read) catch shell.host.exit(127);
                    shell.host.duplicateTo(pipe_desc.write, .stdout) catch shell.host.exit(127);
                    shell.host.close(pipe_desc.write) catch shell.host.exit(127);
                },
                .output => {
                    shell.host.close(pipe_desc.write) catch shell.host.exit(127);
                    shell.host.duplicateTo(pipe_desc.read, .stdin) catch shell.host.exit(127);
                    shell.host.close(pipe_desc.read) catch shell.host.exit(127);
                },
            }
            shell.state.loop_depth = 0;
            shell.state.running_exit_trap = false;
            shell.state.diagnostic_line_offset += substitution.line_offset;
            shell.state.forgetActiveExitTrap();
            shell.state.exit_trap_listing = null;
            if (shell.state.options.mode == .bash) shell.state.options.errexit = false;
            const evaluated = evalProgram(@TypeOf(shell.host), shell, program) catch shell.host.exit(2);
            const status = runExitTrap(shell, evaluated.status) catch shell.host.exit(2);
            shell.host.exit(status);
        },
        .parent => |child_pid| child_pid,
    };
    spawned_pid = pid;

    try shell.host.close(parent_original);
    switch (substitution.kind) {
        .input => try shell.host.close(pipe_desc.write),
        .output => try shell.host.close(pipe_desc.read),
    }
    try shell.state.process_substitutions.append(shell.state.allocator, .{ .fd = parent_fd, .pid = pid });
    spawned_pid = null;
    return std.fmt.allocPrint(shell.scratchAllocator(), "/dev/fd/{}", .{parent_fd.raw()});
}

fn expandArithmeticText(shell: anytype, text: []const u8) ![]const u8 {
    // Expansion only rewrites `$` forms and strips quotes; text without them
    // expands to itself, so skip the byte-by-byte copy.
    if (std.mem.indexOfAny(u8, text, "$'\"") == null) return text;

    var output: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    var index: usize = 0;
    while (index < text.len) {
        switch (text[index]) {
            '\'', '"' => |quote| {
                index += 1;
                while (index < text.len and text[index] != quote) : (index += 1) {
                    try output.append(allocator, text[index]);
                }
                if (index >= text.len) return error.InvalidArithmetic;
                index += 1;
            },
            '$' => {
                if (index + 1 >= text.len) {
                    try output.append(allocator, '$');
                    index += 1;
                    continue;
                }
                if (text[index + 1] == '(' and (index + 2 >= text.len or text[index + 2] != '(')) {
                    const substitution_end = try scanArithmeticCommandSubstitution(text, index + 1);
                    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                    const substitution: ast.CommandSubstitution = .{ .source_text = text[index + 2 .. substitution_end] };
                    try output.appendSlice(allocator, try expandCommandSubstitution(shell, substitution, null));
                    index = substitution_end + 1;
                    continue;
                }
                const expanded = try expandArithmeticParameter(shell, text, &index);
                try output.appendSlice(allocator, expanded);
            },
            else => {
                try output.append(allocator, text[index]);
                index += 1;
            },
        }
    }
    return output.toOwnedSlice(allocator);
}

fn expandArithmeticParameter(shell: anytype, text: []const u8, index: *usize) ![]const u8 {
    // ziglint-ignore: Z016 compound assert documents a single invariant; preserve readability
    std.debug.assert(index.* < text.len and text[index.*] == '$');
    const parameter_start = index.* + 1;
    if (parameter_start >= text.len) {
        index.* += 1;
        return "$";
    }
    if (std.ascii.isDigit(text[parameter_start])) {
        index.* = parameter_start + 1;
        return positionalValue(shell, text[parameter_start] - '0') orelse "";
    }
    if (arithmeticSpecialParameter(text[parameter_start])) |special| {
        index.* = parameter_start + 1;
        return expandParameter(shell, .{ .parameter = .{ .special = special } });
    }
    if (text[parameter_start] == '{') return expandArithmeticBracedParameter(shell, text, index);
    if (!isArithmeticNameStart(text[parameter_start])) {
        index.* += 1;
        return "$";
    }
    var parameter_end = parameter_start + 1;
    while (parameter_end < text.len and isArithmeticNameContinue(text[parameter_end])) parameter_end += 1;
    index.* = parameter_end;
    return parameterValue(shell, text[parameter_start..parameter_end]) orelse {
        if (shell.state.options.nounset) return if (shell.state.options.mode == .bash)
            error.FatalExpansionError
        else
            error.InvalidArithmetic;
        return "";
    };
}

fn expandArithmeticBracedParameter(shell: anytype, text: []const u8, index: *usize) ![]const u8 {
    const content_start = index.* + 2;
    const content_end = scanArithmeticBracedParameterEnd(text, content_start) orelse return error.InvalidArithmetic;
    const content = text[content_start..content_end];
    const parameter = parseArithmeticBracedParameter(content) orelse parameter: {
        if (shell.state.options.mode == .posix) return error.InvalidArithmetic;
        // Bash permits its full parameter grammar here, including indexed
        // array lengths such as `${#values[@]}`.
        const parsed = parser.parseBracedParameterExpansion(
            shell.scratchAllocator(),
            content,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidArithmetic,
        };
        break :parameter parsed orelse return error.InvalidArithmetic;
    };

    index.* = content_end + 1;
    return expandParameter(shell, parameter);
}

fn scanArithmeticBracedParameterEnd(text: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var index = start;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\'' or text[index] == '"') {
            const quote = text[index];
            index += 1;
            while (index < text.len and text[index] != quote) : (index += 1) {}
            if (index >= text.len) return null;
            continue;
        }
        if (text[index] == '$' and index + 1 < text.len and text[index + 1] == '{') {
            depth += 1;
            index += 1;
            continue;
        }
        if (text[index] == '}') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

const ArithmeticParameterPrefix = struct {
    parameter: ast.Parameter,
    end: usize,
};

fn parseArithmeticBracedParameter(content: []const u8) ?ast.ParameterExpansion {
    if (content.len >= 2 and content[0] == '#') {
        const length_prefix = parseArithmeticParameterPrefix(content[1..]) orelse return null;
        if (length_prefix.end != content.len - 1) return null;
        return .{
            .parameter = length_prefix.parameter,
            .length = true,
        };
    }

    const prefix = parseArithmeticParameterPrefix(content) orelse return null;
    const rest = content[prefix.end..];
    if (rest.len == 0) return .{ .parameter = prefix.parameter };

    const colon = rest.len >= 2 and rest[0] == ':' and arithmeticParameterOperator(rest[1]) != null;
    const operator_byte = if (colon) rest[1] else rest[0];
    const operator = arithmeticParameterOperator(operator_byte) orelse return null;
    const word_text = if (colon) rest[2..] else rest[1..];
    return .{
        .parameter = prefix.parameter,
        .colon = colon,
        .op = operator,
        .word = .{ .data = .{ .literal = word_text } },
    };
}

fn parseArithmeticParameterPrefix(content: []const u8) ?ArithmeticParameterPrefix {
    if (content.len == 0) return null;
    if (arithmeticSpecialParameter(content[0])) |special| return .{ .parameter = .{ .special = special }, .end = 1 };
    if (std.ascii.isDigit(content[0])) {
        var end: usize = 1;
        while (end < content.len and std.ascii.isDigit(content[end])) end += 1;
        return .{
            .parameter = .{ .positional = std.fmt.parseInt(u32, content[0..end], 10) catch return null },
            .end = end,
        };
    }
    if (!isArithmeticNameStart(content[0])) return null;
    var end: usize = 1;
    while (end < content.len and isArithmeticNameContinue(content[end])) end += 1;
    return .{ .parameter = .{ .variable = content[0..end] }, .end = end };
}

fn arithmeticParameterOperator(byte: u8) ?ast.ParameterOperator {
    return switch (byte) {
        '-' => .default_value,
        '=' => .assign_default,
        '?' => .error_if_unset,
        '+' => .alternate_value,
        else => null,
    };
}

fn arithmeticSpecialParameter(byte: u8) ?ast.SpecialParameter {
    return switch (byte) {
        '@' => .at,
        '*' => .star,
        '#' => .hash,
        '?' => .question,
        '-' => .hyphen,
        '$' => .dollar,
        '!' => .bang,
        else => null,
    };
}

fn scanArithmeticCommandSubstitution(text: []const u8, open_index: usize) !usize {
    // ziglint-ignore: Z016 compound assert documents a single invariant; preserve readability
    std.debug.assert(open_index < text.len and text[open_index] == '(');
    var index = open_index + 1;
    var depth: usize = 1;
    while (index < text.len) {
        switch (text[index]) {
            '\'', '"' => |quote| {
                index += 1;
                while (index < text.len and text[index] != quote) index += 1;
                if (index >= text.len) return error.InvalidArithmetic;
                index += 1;
            },
            '\\' => index += if (index + 1 < text.len) 2 else 1,
            '(' => {
                depth += 1;
                index += 1;
            },
            ')' => {
                depth -= 1;
                if (depth == 0) return index;
                index += 1;
            },
            else => index += 1,
        }
    }
    return error.InvalidArithmetic;
}

const ArithmeticError = error{ InvalidArithmetic, FatalExpansionError, OutOfMemory };

fn ArithmeticParser(comptime ShellType: type) type {
    return struct {
        shell: ShellType,
        text: []const u8,
        index: usize = 0,
        evaluating: bool = true,
        recursion_depth: usize = 0,

        const Self = @This();

        fn parse(self: *Self) ArithmeticError!i64 {
            const value = try self.parseAssignment();
            self.skipWhitespace();
            if (self.index != self.text.len) return error.InvalidArithmetic;
            return value;
        }

        fn parseAssignment(self: *Self) ArithmeticError!i64 {
            self.skipWhitespace();
            const rewind = self.index;
            if (self.parseName()) |name| {
                self.skipWhitespace();
                if (self.parseAssignmentOperator()) |operator| {
                    const rhs = try self.parseAssignment();
                    const value = try self.applyAssignmentOperator(name, operator, rhs);
                    try self.assignVariable(name, value);
                    return value;
                }
            }
            self.index = rewind;
            return self.parseConditional();
        }

        const AssignmentOperator = enum {
            assign,
            add,
            subtract,
            multiply,
            divide,
            remainder,
            shift_left,
            shift_right,
            bit_and,
            bit_xor,
            bit_or,
        };

        fn parseAssignmentOperator(self: *Self) ?AssignmentOperator {
            switch (self.peek()) {
                '<' => return if (self.eatString("<<=")) .shift_left else null,
                '>' => return if (self.eatString(">>=")) .shift_right else null,
                '+' => return if (self.eatString("+=")) .add else null,
                '-' => return if (self.eatString("-=")) .subtract else null,
                '*' => return if (self.eatString("*=")) .multiply else null,
                '/' => return if (self.eatString("/=")) .divide else null,
                '%' => return if (self.eatString("%=")) .remainder else null,
                '&' => return if (self.eatString("&=")) .bit_and else null,
                '^' => return if (self.eatString("^=")) .bit_xor else null,
                '|' => return if (self.eatString("|=")) .bit_or else null,
                '=' => {
                    if (self.peekOffset(1) == '=') return null;
                    self.index += 1;
                    return .assign;
                },
                else => return null,
            }
        }

        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        fn applyAssignmentOperator(self: *Self, name: []const u8, operator: AssignmentOperator, rhs: i64) ArithmeticError!i64 {
            if (operator == .assign) return rhs;
            const lhs = try self.variableValue(name);
            return switch (operator) {
                .assign => unreachable,
                .add => lhs + rhs,
                .subtract => lhs - rhs,
                .multiply => lhs * rhs,
                .divide => if (rhs == 0) error.InvalidArithmetic else @divTrunc(lhs, rhs),
                .remainder => if (rhs == 0) error.InvalidArithmetic else @rem(lhs, rhs),
                .shift_left => shiftLeft(lhs, rhs),
                .shift_right => shiftRight(lhs, rhs),
                .bit_and => lhs & rhs,
                .bit_xor => lhs ^ rhs,
                .bit_or => lhs | rhs,
            };
        }

        fn parseConditional(self: *Self) ArithmeticError!i64 {
            const condition = try self.parseLogicalOr();
            self.skipWhitespace();
            if (!self.eat('?')) return condition;

            const outer_evaluating = self.evaluating;
            self.evaluating = outer_evaluating and condition != 0;
            const true_value = try self.parseAssignment();
            self.skipWhitespace();
            if (!self.eat(':')) return error.InvalidArithmetic;
            self.evaluating = outer_evaluating and condition == 0;
            const false_value = try self.parseAssignment();
            self.evaluating = outer_evaluating;
            return if (condition != 0) true_value else false_value;
        }

        fn parseLogicalOr(self: *Self) ArithmeticError!i64 {
            var value = try self.parseLogicalAnd();
            var saw_operator = false;
            while (true) {
                self.skipWhitespace();
                if (!self.eatString("||")) return if (saw_operator) if (value != 0) 1 else 0 else value;
                saw_operator = true;
                const outer_evaluating = self.evaluating;
                self.evaluating = outer_evaluating and value == 0;
                const rhs = try self.parseLogicalAnd();
                self.evaluating = outer_evaluating;
                value = if (value != 0 or rhs != 0) 1 else 0;
            }
        }

        fn parseLogicalAnd(self: *Self) ArithmeticError!i64 {
            var value = try self.parseBitOr();
            var saw_operator = false;
            while (true) {
                self.skipWhitespace();
                if (!self.eatString("&&")) return if (saw_operator) if (value != 0) 1 else 0 else value;
                saw_operator = true;
                const outer_evaluating = self.evaluating;
                self.evaluating = outer_evaluating and value != 0;
                const rhs = try self.parseBitOr();
                self.evaluating = outer_evaluating;
                value = if (value != 0 and rhs != 0) 1 else 0;
            }
        }

        fn parseBitOr(self: *Self) ArithmeticError!i64 {
            var value = try self.parseBitXor();
            while (true) {
                self.skipWhitespace();
                if (self.eatSingle('|')) {
                    value |= try self.parseBitXor();
                } else {
                    return value;
                }
            }
        }

        fn parseBitXor(self: *Self) ArithmeticError!i64 {
            var value = try self.parseBitAnd();
            while (true) {
                self.skipWhitespace();
                if (self.eat('^')) {
                    value ^= try self.parseBitAnd();
                } else {
                    return value;
                }
            }
        }

        fn parseBitAnd(self: *Self) ArithmeticError!i64 {
            var value = try self.parseRelational();
            while (true) {
                self.skipWhitespace();
                if (self.eatSingle('&')) {
                    value &= try self.parseRelational();
                } else {
                    return value;
                }
            }
        }

        fn parseRelational(self: *Self) ArithmeticError!i64 {
            var value = try self.parseShift();
            while (true) {
                self.skipWhitespace();
                if (self.eatString("==")) {
                    value = if (value == try self.parseShift()) 1 else 0;
                } else if (self.eatString("!=")) {
                    value = if (value != try self.parseShift()) 1 else 0;
                } else if (self.eatString(">=")) {
                    value = if (value >= try self.parseShift()) 1 else 0;
                } else if (self.eatString("<=")) {
                    value = if (value <= try self.parseShift()) 1 else 0;
                } else if (self.eat('>')) {
                    value = if (value > try self.parseShift()) 1 else 0;
                } else if (self.eat('<')) {
                    value = if (value < try self.parseShift()) 1 else 0;
                } else {
                    return value;
                }
            }
        }

        fn parseShift(self: *Self) ArithmeticError!i64 {
            var value = try self.parseAdd();
            while (true) {
                self.skipWhitespace();
                if (self.eatString("<<")) {
                    value = shiftLeft(value, try self.parseAdd());
                } else if (self.eatString(">>")) {
                    value = shiftRight(value, try self.parseAdd());
                } else {
                    return value;
                }
            }
        }

        fn parseAdd(self: *Self) ArithmeticError!i64 {
            var value = try self.parseMul();
            while (true) {
                self.skipWhitespace();
                if (self.eat('+')) {
                    value += try self.parseMul();
                } else if (self.eat('-')) {
                    value -= try self.parseMul();
                } else {
                    return value;
                }
            }
        }

        fn parseMul(self: *Self) ArithmeticError!i64 {
            var value = try self.parseUnary();
            while (true) {
                self.skipWhitespace();
                if (self.eat('*')) {
                    value *= try self.parseUnary();
                } else if (self.eat('/')) {
                    const rhs = try self.parseUnary();
                    if (!self.evaluating) return 0;
                    if (rhs == 0) return error.InvalidArithmetic;
                    value = @divTrunc(value, rhs);
                } else if (self.eat('%')) {
                    const rhs = try self.parseUnary();
                    if (!self.evaluating) return 0;
                    if (rhs == 0) return error.InvalidArithmetic;
                    value = @rem(value, rhs);
                } else {
                    return value;
                }
            }
        }

        fn parseUnary(self: *Self) ArithmeticError!i64 {
            self.skipWhitespace();
            if (self.shell.state.options.mode == .bash and self.eatString("++")) return self.parsePrefixUpdate(1);
            if (self.shell.state.options.mode == .bash and self.eatString("--")) return self.parsePrefixUpdate(-1);
            if (self.eat('+')) return self.parseUnary();
            if (self.eat('-')) return -(try self.parseUnary());
            if (self.eat('!')) return if (try self.parseUnary() == 0) 1 else 0;
            if (self.eat('~')) return ~(try self.parseUnary());
            return self.parsePrimary();
        }

        fn parsePrefixUpdate(self: *Self, delta: i64) ArithmeticError!i64 {
            self.skipWhitespace();
            const name = self.parseName() orelse return error.InvalidArithmetic;
            const value = try self.variableValue(name) + delta;
            try self.assignVariable(name, value);
            return value;
        }

        fn parsePrimary(self: *Self) ArithmeticError!i64 {
            self.skipWhitespace();
            if (self.eat('(')) {
                const value = try self.parseAssignment();
                self.skipWhitespace();
                if (!self.eat(')')) return error.InvalidArithmetic;
                return value;
            }
            if (self.peek() == '$') {
                self.index += 1;
                const name = self.parseName() orelse return error.InvalidArithmetic;
                return self.variableValue(name);
            }
            if (isArithmeticNameStart(self.peek())) {
                const name = self.parseName().?;
                return self.variableValue(name);
            }
            return self.parseNumber();
        }

        fn parseNumber(self: *Self) ArithmeticError!i64 {
            self.skipWhitespace();
            const start = self.index;
            while (self.index < self.text.len and std.ascii.isAlphanumeric(self.text[self.index])) self.index += 1;
            if (start == self.index) return error.InvalidArithmetic;
            const token = self.text[start..self.index];
            if (std.mem.startsWith(u8, token, "0x") or std.mem.startsWith(u8, token, "0X")) {
                return std.fmt.parseInt(i64, token[2..], 16) catch error.InvalidArithmetic;
            }
            if (token.len > 1 and token[0] == '0') {
                return std.fmt.parseInt(i64, token[1..], 8) catch error.InvalidArithmetic;
            }
            return std.fmt.parseInt(i64, token, 10) catch error.InvalidArithmetic;
        }

        fn parseName(self: *Self) ?[]const u8 {
            if (!isArithmeticNameStart(self.peek())) return null;
            const start = self.index;
            self.index += 1;
            while (isArithmeticNameContinue(self.peek())) self.index += 1;
            return self.text[start..self.index];
        }

        fn variableValue(self: *Self, name: []const u8) ArithmeticError!i64 {
            if (!self.evaluating) return 0;
            const value = parameterValue(self.shell, name) orelse {
                if (self.shell.state.options.nounset) return if (self.shell.state.options.mode == .bash)
                    error.FatalExpansionError
                else
                    error.InvalidArithmetic;
                return 0;
            };
            const trimmed = std.mem.trim(u8, value, " \t\n");
            if (trimmed.len == 0) return 0;
            if (self.shell.state.options.mode == .bash) {
                // Plain decimal values evaluate to themselves; skip the
                // recursive parse that bash-mode expression values require.
                if (plainDecimalArithmeticValue(trimmed)) |plain| return plain;
                if (self.recursion_depth >= 64) return error.InvalidArithmetic;
                var parser_state: ArithmeticParser(ShellType) = .{
                    .shell = self.shell,
                    .text = trimmed,
                    .recursion_depth = self.recursion_depth + 1,
                };
                return parser_state.parse();
            }
            return std.fmt.parseInt(i64, trimmed, 10) catch error.InvalidArithmetic;
        }

        fn assignVariable(self: *Self, name: []const u8, value: i64) ArithmeticError!void {
            if (!self.evaluating) return;
            const text = try std.fmt.allocPrint(self.shell.scratchAllocator(), "{}", .{value});
            self.shell.state.putVariable(.{ .name = name, .value = text }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ReadonlyVariable => return error.InvalidArithmetic,
            };
        }

        fn skipWhitespace(self: *Self) void {
            while (self.index < self.text.len and std.ascii.isWhitespace(self.text[self.index])) self.index += 1;
        }

        fn eat(self: *Self, byte: u8) bool {
            if (self.peek() != byte) return false;
            self.index += 1;
            return true;
        }

        fn eatSingle(self: *Self, byte: u8) bool {
            if (self.peek() != byte or self.peekOffset(1) == byte) return false;
            self.index += 1;
            return true;
        }

        fn eatString(self: *Self, bytes: []const u8) bool {
            if (!std.mem.startsWith(u8, self.text[self.index..], bytes)) return false;
            self.index += bytes.len;
            return true;
        }

        fn peek(self: Self) u8 {
            if (self.index >= self.text.len) return 0;
            return self.text[self.index];
        }

        fn peekOffset(self: Self, offset: usize) u8 {
            const target = self.index + offset;
            if (target >= self.text.len) return 0;
            return self.text[target];
        }
    };
}

/// Parses text that the full arithmetic parser would evaluate to the same
/// plain decimal value, or null when full parsing is required. Leading-zero
/// (octal) and overflowing magnitudes must take the full parser path.
fn plainDecimalArithmeticValue(text: []const u8) ?i64 {
    const negate = text[0] == '-';
    const digits = if (negate or text[0] == '+') text[1..] else text;
    if (digits.len == 0) return null;
    if (digits[0] == '0' and digits.len > 1) return null;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return null;
    const magnitude = std.fmt.parseInt(i64, digits, 10) catch return null;
    return if (negate) -magnitude else magnitude;
}

fn isArithmeticNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isArithmeticNameContinue(byte: u8) bool {
    return isArithmeticNameStart(byte) or std.ascii.isDigit(byte);
}

fn shiftLeft(value: i64, amount: i64) i64 {
    if (amount < 0 or amount >= 63) return 0;
    return value << @as(u6, @intCast(amount));
}

fn shiftRight(value: i64, amount: i64) i64 {
    if (amount < 0 or amount >= 63) return 0;
    return value >> @as(u6, @intCast(amount));
}

fn expandCommandSubstitution(
    shell: anytype,
    substitution: ast.CommandSubstitution,
    substitution_status: ?*?result.ExitStatus,
) EvalError![]const u8 {
    validateAst(substitution);
    const program = if (substitution.parsed) |program| program.* else program: {
        const src: source_mod.Source = .{
            .id = 0,
            .kind = .command_string,
            .name = "$()",
            .text = substitution.source_text,
        };
        const ast_allocator = shell.astAllocator();
        const tokens = try lexer.lexWithAliases(ast_allocator, src, shell.state);
        break :program try parser.parseWithAliases(ast_allocator, src, tokens, shell.state);
    };
    const capture = try evalCommandSubstitutionInChild(shell, substitution, program);
    const status = capture.status;
    if (substitution_status) |tracked| tracked.* = status;
    shell.state.last_status = status;
    return capture.output;
}

const CommandSubstitutionCapture = struct {
    output: []const u8,
    status: result.ExitStatus,
};

fn evalCommandSubstitutionInChild(
    shell: anytype,
    substitution: ast.CommandSubstitution,
    program: ast.Program,
) !CommandSubstitutionCapture {
    _ = shellProcessId(shell);
    _ = parentProcessId(shell);

    const pipe_desc = try shell.host.pipe();
    errdefer {
        shell.host.close(pipe_desc.read) catch {};
        shell.host.close(pipe_desc.write) catch {};
    }

    const pid = switch (try shell.host.forkProcess()) {
        .child => {
            shell.host.close(pipe_desc.read) catch shell.host.exit(127);
            shell.host.duplicateTo(pipe_desc.write, .stdout) catch shell.host.exit(127);
            shell.host.close(pipe_desc.write) catch shell.host.exit(127);
            closeInheritedProcessSubstitutionFds(shell);
            shell.state.loop_depth = 0;
            shell.state.running_exit_trap = false;
            shell.state.diagnostic_line_offset += substitution.line_offset;
            shell.state.forgetActiveExitTrap();
            shell.state.exit_trap_listing = null;
            if (shell.state.options.mode == .bash) shell.state.options.errexit = false;
            const evaluated = if (shell.state.options.xtrace) evaluated: {
                break :evaluated evalProgram(@TypeOf(shell.host), shell, program) catch shell.host.exit(2);
            } else evaluated: {
                // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                const external_request = commandSubstitutionExternalProgramRequest(shell, program) catch shell.host.exit(2);
                if (external_request) |request| {
                    shell.host.exec(request) catch shell.host.exit(127);
                }
                break :evaluated evalProgram(@TypeOf(shell.host), shell, program) catch shell.host.exit(2);
            };
            const status = runExitTrap(shell, evaluated.status) catch shell.host.exit(2);
            shell.host.exit(status);
        },
        .parent => |child_pid| child_pid,
    };

    try shell.host.close(pipe_desc.write);
    const output = readCommandSubstitutionOutput(shell, pipe_desc.read) catch |err| {
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        shell.host.close(pipe_desc.read) catch {};
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        _ = shell.host.wait(pid) catch {};
        return err;
    };
    try shell.host.close(pipe_desc.read);
    const wait_status = try shell.host.wait(pid);
    return .{ .output = output, .status = wait_status.shellStatus() };
}

fn commandSubstitutionExternalProgramRequest(shell: anytype, program: ast.Program) !?host_mod.SpawnRequest {
    if (try staticExternalProgramRequest(shell, program)) |request| return request;
    return dynamicExternalProgramRequest(shell, program);
}

fn dynamicExternalProgramRequest(shell: anytype, program: ast.Program) !?host_mod.SpawnRequest {
    if (program.body.entries.len != 1) return null;
    const entry = program.body.entries[0];
    if (entry.terminator == .background) return null;
    if (entry.and_or.pipelines.len != 1) return null;
    const pipeline = entry.and_or.pipelines[0].pipeline;
    if (pipeline.negated or pipeline.stages.len != 1) return null;
    return dynamicExternalCommandRequest(shell, pipeline.stages[0], &.{});
}

fn dynamicExternalCommandRequest(
    shell: anytype,
    command: ast.Command,
    fd_actions: []const host_mod.SpawnFdAction,
) !?host_mod.SpawnRequest {
    if (command != .simple) return null;
    const simple = command.simple;
    if (simple.assignments.len != 0 or simple.redirections.len != 0 or simple.words.len == 0) return null;
    for (simple.words) |word| if (!wordIsSafeForSpeculativeExpansion(word)) return null;

    var expansion_status: ?result.ExitStatus = null;
    const fields = try expandWordFields(shell, simple.words, &expansion_status);
    if (expansion_status != null or fields.len == 0) return null;
    if (lookupBuiltin(shell, fields[0]) != null or shell.state.getFunction(fields[0]) != null) return null;
    return makeExternalSpawnRequest(shell, fields, &.{}, fd_actions) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
}

fn wordIsSafeForSpeculativeExpansion(word: ast.Word) bool {
    return switch (word.data) {
        .literal => true,
        .parts => |parts| partsAreSafeForSpeculativeExpansion(parts),
        .declaration_array_assignment => false,
    };
}

fn partsAreSafeForSpeculativeExpansion(parts: []const ast.WordPart) bool {
    for (parts) |part| switch (part) {
        .literal, .escaped, .single_quoted => {},
        .double_quoted => |nested| if (!partsAreSafeForSpeculativeExpansion(nested)) return false,
        .parameter => |parameter| if (parameter.op != null) return false,
        .command_substitution, .process_substitution, .arithmetic => return false,
    };
    return true;
}

fn staticExternalProgramRequest(shell: anytype, program: ast.Program) !?host_mod.SpawnRequest {
    if (program.body.entries.len != 1) return null;
    const entry = program.body.entries[0];
    if (entry.terminator == .background) return null;
    if (entry.and_or.pipelines.len != 1) return null;
    const pipeline = entry.and_or.pipelines[0].pipeline;
    if (pipeline.negated or pipeline.stages.len != 1) return null;
    return staticExternalPipelineStageRequest(shell, pipeline.stages[0], &.{});
}

fn readCommandSubstitutionOutput(shell: anytype, fd: host_mod.Fd) ![]const u8 {
    const allocator = shell.scratchAllocator();
    var output: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_len = try shell.host.read(fd, &buffer);
        if (read_len == 0) break;
        for (buffer[0..read_len]) |byte| {
            if (byte != 0) try output.append(allocator, byte);
        }
    }
    while (output.items.len != 0 and output.items[output.items.len - 1] == '\n') {
        output.items.len -= 1;
    }
    if (output.items.len == 0) return "";
    return output.toOwnedSlice(allocator);
}

fn expandParameter(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    validateAst(parameter);
    if (parameter.length) return expandParameterLength(shell, parameter);
    if (parameter.array_indices) return (try arrayIndicesParameterValue(shell, parameter.parameter.array)) orelse "";

    if (parameter.op) |operator| {
        return switch (operator) {
            .default_value => expandParameterDefault(shell, parameter),
            .assign_default => expandParameterAssignDefault(shell, parameter),
            .alternate_value => expandParameterAlternate(shell, parameter),
            .error_if_unset => expandParameterErrorIfUnset(shell, parameter),
            .remove_small_prefix,
            .remove_large_prefix,
            .remove_small_suffix,
            .remove_large_suffix,
            => expandParameterPatternRemoval(shell, parameter, operator),
            .substring => expandParameterSubstring(shell, parameter),
            .substitute_first,
            .substitute_all,
            .substitute_prefix,
            .substitute_suffix,
            => expandParameterSubstitution(shell, parameter, operator),
            .transform_prompt => expandParameterPrompt(shell, parameter),
        };
    }

    return switch (parameter.parameter) {
        .variable => |name| parameterExpansionValue(shell, name, parameter.span) orelse {
            if (shell.state.options.nounset) {
                try writeExpansionDiagnostic(shell, parameter, "parameter", "parameter not set");
                return if (shell.state.options.mode == .bash) error.FatalExpansionError else error.ExpansionError;
            }
            return "";
        },
        .array => parameterCurrentValue(shell, parameter.parameter) catch |err| switch (err) {
            error.InvalidArithmetic => return error.ExpansionError,
            else => return err,
        } orelse {
            if (shell.state.options.nounset) {
                try writeExpansionDiagnostic(shell, parameter, "parameter", "parameter not set");
                return if (shell.state.options.mode == .bash) error.FatalExpansionError else error.ExpansionError;
            }
            return "";
        },
        .special => |special| switch (special) {
            .hash => try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{shell.state.positionals.len}),
            .question => try formatExitStatus(shell, shell.state.last_status),
            .hyphen => try optionFlags(shell),
            .dollar => try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{shellProcessId(shell)}),
            .bang => if (shell.state.last_background_pid) |pid|
                try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{pid})
            else
                "",
            .star => try joinPositionals(shell, ifsFirstCharacter(shell)),
            .at => try joinPositionals(shell, " "),
        },
        .positional => |position| positionalValue(shell, position) orelse {
            if (shell.state.options.nounset) {
                // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                try writeExpansionDiagnostic(shell, parameter, parameterDiagnosticName(parameter.parameter), "parameter not set");
                return if (shell.state.options.mode == .bash) error.FatalExpansionError else error.ExpansionError;
            }
            return "";
        },
    };
}

fn expandParameterPrompt(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    const value = (try parameterCurrentValue(shell, parameter.parameter)) orelse {
        if (shell.state.options.nounset and parameterSubjectToNounset(parameter.parameter)) {
            try writeExpansionDiagnostic(
                shell,
                parameter,
                parameterDiagnosticName(parameter.parameter),
                "parameter not set",
            );
            return error.FatalExpansionError;
        }
        return "";
    };
    return expandPromptValue(shell, value, parameter.span);
}

/// Expands a Bash prompt value, including prompt escapes and the optional
/// second expansion controlled by `shopt -s promptvars`.
pub fn expandPromptValue(shell: anytype, value: []const u8, span: source_mod.Span) EvalError![]const u8 {
    const decoded = try prompt_mod.decode(shell, value);
    if (!shell.state.options.promptvars) return decoded;
    if (std.mem.indexOfAny(u8, decoded, "$\\`") == null) return decoded;

    const word = try parser.parseDoubleQuotedExpansionText(shell.scratchAllocator(), decoded, span);
    return expandWord(shell, word);
}

fn positionalValue(shell: anytype, position: u32) ?[]const u8 {
    if (position == 0) return shell.state.arg_zero;
    const index: usize = position - 1;
    if (index >= shell.state.positionals.len) return null;
    return shell.state.positionals[index];
}

fn optionFlags(shell: anytype) ![]const u8 {
    var flags: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    if (shell.state.options.allexport) try flags.append(allocator, 'a');
    if (shell.state.options.notify) try flags.append(allocator, 'b');
    if (shell.state.options.noclobber) try flags.append(allocator, 'C');
    if (shell.state.options.errexit) try flags.append(allocator, 'e');
    if (shell.state.options.noglob) try flags.append(allocator, 'f');
    if (shell.state.options.hashall) try flags.append(allocator, 'h');
    if (shell.state.options.monitor) try flags.append(allocator, 'm');
    if (shell.state.options.noexec) try flags.append(allocator, 'n');
    if (shell.state.options.nounset) try flags.append(allocator, 'u');
    if (shell.state.options.verbose) try flags.append(allocator, 'v');
    if (shell.state.options.xtrace) try flags.append(allocator, 'x');
    return flags.toOwnedSlice(allocator);
}

fn ifsFirstCharacter(shell: anytype) []const u8 {
    const ifs = parameterValue(shell, "IFS") orelse " \t\n";
    if (ifs.len == 0) return "";
    const len = std.unicode.utf8ByteSequenceLength(ifs[0]) catch 1;
    return ifs[0..@min(len, ifs.len)];
}

fn joinPositionals(shell: anytype, separator: []const u8) ![]const u8 {
    const positionals = shell.state.positionals;
    if (positionals.len == 0) return "";
    return joinValues(shell, positionals, separator);
}

fn joinValues(shell: anytype, values: []const []const u8, separator: []const u8) ![]const u8 {
    if (values.len == 0) return "";
    var total_len = std.math.mul(usize, values.len - 1, separator.len) catch return error.OutOfMemory;
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    for (values) |value| total_len = std.math.add(usize, total_len, value.len) catch return error.OutOfMemory;

    const output = try shell.scratchAllocator().alloc(u8, total_len);
    var cursor: usize = 0;
    for (values, 0..) |value, index| {
        if (index != 0) {
            @memcpy(output[cursor..][0..separator.len], separator);
            cursor += separator.len;
        }
        @memcpy(output[cursor..][0..value.len], value);
        cursor += value.len;
    }
    return output;
}

fn joinArrayElements(shell: anytype, elements: []const state_mod.ArrayElement, separator: []const u8) ![]const u8 {
    if (elements.len == 0) return "";
    var total_len = std.math.mul(usize, elements.len - 1, separator.len) catch return error.OutOfMemory;
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    for (elements) |element| total_len = std.math.add(usize, total_len, element.value.len) catch return error.OutOfMemory;

    const output = try shell.scratchAllocator().alloc(u8, total_len);
    var cursor: usize = 0;
    for (elements, 0..) |element, element_index| {
        if (element_index != 0) {
            @memcpy(output[cursor..][0..separator.len], separator);
            cursor += separator.len;
        }
        @memcpy(output[cursor..][0..element.value.len], element.value);
        cursor += element.value.len;
    }
    return output;
}

fn expandParameterLength(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    if (shell.state.options.mode == .bash) switch (parameter.parameter) {
        .special => |special| switch (special) {
            .at, .star => return std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{shell.state.positionals.len}),
            else => {},
        },
        .array => |array| switch (array.subscript) {
            .all => return expandArrayElementCount(shell, parameter, array),
            .index => {},
        },
        else => {},
    };
    const value = (try parameterCurrentValue(shell, parameter.parameter)) orelse {
        if (shell.state.options.nounset and parameterSubjectToNounset(parameter.parameter)) {
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            try writeExpansionDiagnostic(shell, parameter, parameterDiagnosticName(parameter.parameter), "parameter not set");
            return if (shell.state.options.mode == .bash) error.FatalExpansionError else error.ExpansionError;
        }
        return "0";
    };
    const length = std.unicode.utf8CountCodepoints(value) catch value.len;
    return std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{length});
}

fn expandArrayElementCount(
    shell: anytype,
    expansion: ast.ParameterExpansion,
    parameter: ast.ArrayParameter,
) EvalError![]const u8 {
    const count = arrayElementCount(shell, parameter) orelse {
        if (shell.state.options.nounset) {
            try writeExpansionDiagnostic(
                shell,
                expansion,
                parameterDiagnosticName(expansion.parameter),
                "parameter not set",
            );
            return error.FatalExpansionError;
        }
        return "0";
    };
    return std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{count});
}

fn arrayElementCount(shell: anytype, parameter: ast.ArrayParameter) ?usize {
    if (shell.state.options.mode == .bash and std.mem.eql(u8, parameter.name, "PIPESTATUS")) {
        return shell.state.last_pipeline_statuses.len;
    }
    if (shell.state.options.mode == .bash and std.mem.eql(u8, parameter.name, "FUNCNAME")) {
        return shell.state.function_call_stack.items.len;
    }
    if (shell.state.options.mode == .bash and std.mem.eql(u8, parameter.name, "BASH_SOURCE")) {
        return shell.state.function_call_stack.items.len;
    }
    const array = shell.state.getArray(parameter.name) orelse return null;
    return array.elements.len;
}

fn parameterSubjectToNounset(parameter: ast.Parameter) bool {
    return switch (parameter) {
        .variable, .array, .positional => true,
        .special => false,
    };
}

fn expandParameterDefault(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    const value = try parameterCurrentValue(shell, parameter.parameter);
    if (isParameterSet(parameter, value)) return value.?;
    return expandWord(shell, parameter.word.?);
}

fn expandParameterAssignDefault(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    const name = switch (parameter.parameter) {
        .variable => |variable_name| variable_name,
        else => return "",
    };
    const value = parameterValue(shell, name);
    if (isParameterSet(parameter, value)) return value.?;

    const default = try expandWord(shell, parameter.word.?);
    shell.state.putVariable(.{ .name = name, .value = default }) catch |err| switch (err) {
        error.ReadonlyVariable => {
            try writeReadonlyDiagnostic(shell, name);
            return error.ExpansionError;
        },
        else => return err,
    };
    return default;
}

fn expandParameterAlternate(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    const value = try parameterCurrentValue(shell, parameter.parameter);
    if (!isParameterSet(parameter, value)) return "";
    return expandWord(shell, parameter.word.?);
}

fn expandParameterErrorIfUnset(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    const value = try parameterCurrentValue(shell, parameter.parameter);
    if (isParameterSet(parameter, value)) return value.?;

    const message = try expandWord(shell, parameter.word.?);
    try writeExpansionDiagnostic(shell, parameter, parameterDiagnosticName(parameter.parameter), message);
    return if (shell.state.options.mode == .bash) error.FatalExpansionError else error.ExpansionError;
}

fn parameterDiagnosticName(parameter: ast.Parameter) []const u8 {
    return switch (parameter) {
        .variable => |name| name,
        .array => |array| array.name,
        .positional => "positional parameter",
        .special => "special parameter",
    };
}

fn parameterCurrentValue(shell: anytype, parameter: ast.Parameter) !?[]const u8 {
    return switch (parameter) {
        .variable => |name| parameterValue(shell, name),
        .array => |array| arrayParameterValue(shell, array),
        .positional => |position| positionalValue(shell, position),
        .special => |special| switch (special) {
            .at => if (shell.state.positionals.len == 0) null else try joinPositionals(shell, " "),
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            .star => if (shell.state.positionals.len == 0) null else try joinPositionals(shell, ifsFirstCharacter(shell)),
            .hash => try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{shell.state.positionals.len}),
            .question => try formatExitStatus(shell, shell.state.last_status),
            .hyphen => try optionFlags(shell),
            .dollar => try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{shellProcessId(shell)}),
            .bang => if (shell.state.last_background_pid) |pid|
                try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{pid})
            else
                null,
        },
    };
}

fn arrayParameterValue(shell: anytype, parameter: ast.ArrayParameter) !?[]const u8 {
    if (shell.state.options.mode == .bash and std.mem.eql(u8, parameter.name, "PIPESTATUS")) {
        return pipelineStatusParameterValue(shell, parameter.subscript);
    }
    if (shell.state.options.mode == .bash and std.mem.eql(u8, parameter.name, "FUNCNAME")) {
        return functionStackParameterValue(shell, parameter.subscript, .name);
    }
    if (shell.state.options.mode == .bash and std.mem.eql(u8, parameter.name, "BASH_SOURCE")) {
        return functionStackParameterValue(shell, parameter.subscript, .source_name);
    }
    const array = shell.state.getArray(parameter.name) orelse return null;
    return switch (parameter.subscript) {
        .index => |word| value: {
            const index = try expandArrayIndexForArray(shell, word, array);
            break :value array.elementValue(index);
        },
        .all => |special| if (array.elements.len == 0) null else switch (special) {
            .at => try joinArrayElements(shell, array.elements, " "),
            .star => try joinArrayElements(shell, array.elements, ifsFirstCharacter(shell)),
            else => unreachable,
        },
    };
}

fn arrayExpansionElements(shell: anytype, expansion: ast.ParameterExpansion) EvalError!?[]const state_mod.ArrayElement {
    std.debug.assert(expansion.parameter == .array);
    const array_parameter = expansion.parameter.array;
    const array = shell.state.getArray(array_parameter.name) orelse return null;
    const elements = switch (array_parameter.subscript) {
        .all => array.elements,
        .index => return null,
    };
    if (expansion.op == null) return elements;
    std.debug.assert(expansion.op.? == .substring);
    const offset = try parameterArithmeticValue(shell, expansion.word.?);
    const maybe_length = if (expansion.second_word) |word| try parameterArithmeticValue(shell, word) else null;
    return arraySubstringElements(elements, offset, maybe_length) catch |err| switch (err) {
        error.NegativeArraySubstringLength => return error.ExpansionError,
    };
}

const ArraySubstringError = error{NegativeArraySubstringLength};

fn arraySubstringElements(
    elements: []const state_mod.ArrayElement,
    offset: i64,
    maybe_length: ?i64,
) ArraySubstringError![]const state_mod.ArrayElement {
    if (elements.len == 0) return elements;
    if (maybe_length) |length| if (length < 0) return error.NegativeArraySubstringLength;

    const max_index_plus_one = elements[elements.len - 1].index + 1;
    const start_index = normalizeSubstringIndex(offset, max_index_plus_one);
    var start_position: usize = 0;
    while (start_position < elements.len and elements[start_position].index < start_index) : (start_position += 1) {}

    const length = maybe_length orelse return elements[start_position..];
    const selected_len = @min(elements.len - start_position, @as(usize, @intCast(length)));
    return elements[start_position .. start_position + selected_len];
}

fn arrayIndicesParameterValue(shell: anytype, parameter: ast.ArrayParameter) !?[]const u8 {
    return switch (parameter.subscript) {
        .all => |special| if (shell.state.getArray(parameter.name)) |array| {
            if (array.elements.len == 0) return null;
            const separator = if (special == .star) ifsFirstCharacter(shell) else " ";
            return try joinArrayElementIndices(shell, array.elements, separator);
        } else null,
        .index => null,
    };
}

fn joinArrayElementIndices(
    shell: anytype,
    elements: []const state_mod.ArrayElement,
    separator: []const u8,
) ![]const u8 {
    std.debug.assert(elements.len != 0);
    var output: std.Io.Writer.Allocating = .init(shell.scratchAllocator());
    defer output.deinit();
    for (elements, 0..) |element, index| {
        if (index != 0) try output.writer.writeAll(separator);
        try output.writer.print("{}", .{element.index});
    }
    return output.toOwnedSlice();
}

const FunctionStackField = enum {
    name,
    source_name,
};

fn functionStackParameterValue(
    shell: anytype,
    subscript: ast.ArraySubscript,
    field: FunctionStackField,
) !?[]const u8 {
    const stack = shell.state.function_call_stack.items;
    if (stack.len == 0) return null;
    return switch (subscript) {
        .index => |word| value: {
            const index = try expandArrayIndex(shell, word);
            if (index >= stack.len) break :value null;
            const frame = stack[stack.len - 1 - index];
            break :value functionStackFieldValue(frame, field);
        },
        .all => |special| switch (special) {
            .at => try joinFunctionStack(shell, field, " "),
            .star => try joinFunctionStack(shell, field, ifsFirstCharacter(shell)),
            else => unreachable,
        },
    };
}

fn joinFunctionStack(shell: anytype, field: FunctionStackField, separator: []const u8) ![]const u8 {
    const stack = shell.state.function_call_stack.items;
    if (stack.len == 0) return "";
    var output: std.Io.Writer.Allocating = .init(shell.scratchAllocator());
    defer output.deinit();
    var index = stack.len;
    while (index != 0) {
        index -= 1;
        if (index != stack.len - 1) try output.writer.writeAll(separator);
        try output.writer.writeAll(functionStackFieldValue(stack[index], field));
    }
    return output.toOwnedSlice();
}

fn functionStackFieldValue(frame: state_mod.FunctionCallFrame, field: FunctionStackField) []const u8 {
    return switch (field) {
        .name => frame.name,
        .source_name => frame.source_name,
    };
}

fn pipelineStatusParameterValue(shell: anytype, subscript: ast.ArraySubscript) !?[]const u8 {
    const statuses = shell.state.last_pipeline_statuses;
    if (statuses.len == 0) return null;
    return switch (subscript) {
        .index => |word| value: {
            const index = try expandArrayIndex(shell, word);
            if (index >= statuses.len) break :value null;
            break :value try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{statuses[index]});
        },
        .all => |special| switch (special) {
            .at => try joinPipelineStatuses(shell, " "),
            .star => try joinPipelineStatuses(shell, ifsFirstCharacter(shell)),
            else => unreachable,
        },
    };
}

fn joinPipelineStatuses(shell: anytype, separator: []const u8) ![]const u8 {
    const statuses = shell.state.last_pipeline_statuses;
    if (statuses.len == 0) return "";
    var output: std.Io.Writer.Allocating = .init(shell.scratchAllocator());
    defer output.deinit();
    for (statuses, 0..) |status, index| {
        if (index != 0) try output.writer.writeAll(separator);
        try output.writer.print("{}", .{status});
    }
    return output.toOwnedSlice();
}

fn parameterExpansionValue(shell: anytype, name: []const u8, span: source_mod.Span) ?[]const u8 {
    if (std.mem.eql(u8, name, "LINENO")) return std.fmt.allocPrint(
        shell.scratchAllocator(),
        "{}",
        .{span.start_line + shell.state.diagnostic_line_offset},
    ) catch null;
    return parameterValue(shell, name);
}

fn expandParameterPatternRemoval(
    shell: anytype,
    parameter: ast.ParameterExpansion,
    operator: ast.ParameterOperator,
) EvalError![]const u8 {
    const value = (try parameterCurrentValue(shell, parameter.parameter)) orelse "";
    const pattern = try expandPatternWord(shell, parameter.word.?);
    return switch (operator) {
        .remove_small_prefix => pattern_mod.removePrefix(value, pattern, .small),
        .remove_large_prefix => pattern_mod.removePrefix(value, pattern, .large),
        .remove_small_suffix => pattern_mod.removeSuffix(value, pattern, .small),
        .remove_large_suffix => pattern_mod.removeSuffix(value, pattern, .large),
        else => unreachable,
    };
}

fn expandParameterSubstring(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    if (parameter.parameter == .array) {
        const elements = (try arrayExpansionElements(shell, parameter)) orelse return "";
        const array = parameter.parameter.array;
        const separator = switch (array.subscript) {
            .all => |special| if (special == .star) ifsFirstCharacter(shell) else " ",
            .index => unreachable,
        };
        return joinArrayElements(shell, elements, separator);
    }
    const value = (try parameterCurrentValue(shell, parameter.parameter)) orelse "";
    const offset = try parameterArithmeticValue(shell, parameter.word.?);
    const maybe_length = if (parameter.second_word) |word| try parameterArithmeticValue(shell, word) else null;
    return substringValue(value, offset, maybe_length);
}

fn parameterArithmeticValue(shell: anytype, word: ast.Word) EvalError!i64 {
    const text = try expandWord(shell, word);
    return evalArithmeticValue(shell, text) catch |err| switch (err) {
        error.InvalidArithmetic, error.FatalExpansionError => return error.ExpansionError,
        else => return err,
    };
}

fn substringValue(value: []const u8, offset: i64, maybe_length: ?i64) []const u8 {
    const count = utf8CodepointCount(value);
    const start_index = substringIndex(value, normalizeSubstringIndex(offset, count));
    const end_count = if (maybe_length) |length| if (length < 0)
        normalizeSubstringIndex(length, count)
    else
        @min(count, normalizeSubstringIndex(offset, count) + @as(usize, @intCast(length))) else count;
    const end_index = substringIndex(value, @max(normalizeSubstringIndex(offset, count), end_count));
    return value[start_index..end_index];
}

fn normalizeSubstringIndex(value: i64, count: usize) usize {
    if (value >= 0) return @min(count, @as(usize, @intCast(value)));
    const magnitude: u64 = if (value == std.math.minInt(i64))
        @as(u64, 1) << 63
    else
        @intCast(-value);
    if (magnitude >= count) return 0;
    return count - @as(usize, @intCast(magnitude));
}

fn substringIndex(value: []const u8, codepoint_count: usize) usize {
    var byte_index: usize = 0;
    var index: usize = 0;
    while (byte_index < value.len and index < codepoint_count) : (index += 1) {
        byte_index += utf8SequenceLength(value[byte_index..]);
    }
    return byte_index;
}

fn utf8CodepointCount(value: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < value.len) : (count += 1) index += utf8SequenceLength(value[index..]);
    return count;
}

fn expandParameterSubstitution(
    shell: anytype,
    parameter: ast.ParameterExpansion,
    operator: ast.ParameterOperator,
) EvalError![]const u8 {
    const value = (try parameterCurrentValue(shell, parameter.parameter)) orelse "";
    const pattern = try expandPatternWord(shell, parameter.word.?);
    if (pattern.len == 0) return value;
    const replacement = try expandWord(shell, parameter.second_word.?);
    return switch (operator) {
        .substitute_first => substituteFirst(shell, value, pattern, replacement),
        .substitute_all => substituteAll(shell, value, pattern, replacement),
        .substitute_prefix => substitutePrefix(shell, value, pattern, replacement),
        .substitute_suffix => substituteSuffix(shell, value, pattern, replacement),
        else => unreachable,
    };
}

fn expandPatternWord(shell: anytype, word: ast.Word) ![]const u8 {
    const pattern = switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| try expandPatternParts(shell, parts),
        .declaration_array_assignment => unreachable,
    };
    return expandLeadingTilde(shell, word, pattern);
}

fn expandPatternParts(shell: anytype, parts: []const ast.WordPart) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    for (parts) |part| switch (part) {
        .literal => |bytes| try output.appendSlice(allocator, bytes),
        .escaped => |bytes| try appendPatternLiteral(allocator, &output, bytes),
        .single_quoted => |bytes| try appendPatternLiteral(allocator, &output, bytes),
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        .double_quoted => |nested| try appendPatternLiteral(allocator, &output, try expandWordParts(shell, nested, null)),
        .parameter, .command_substitution, .process_substitution, .arithmetic => {
            try output.appendSlice(allocator, try expandWordPart(shell, part, null));
        },
    };
    return output.toOwnedSlice(allocator);
}

fn appendPatternLiteral(allocator: std.mem.Allocator, output: *std.ArrayList(u8), bytes: []const u8) !void {
    for (bytes) |byte| {
        if (byte == '*' or byte == '?' or byte == '[' or byte == ']' or byte == '\\' or
            byte == '-' or byte == '!' or byte == '^')
        {
            try output.append(allocator, '\\');
        }
        try output.append(allocator, byte);
    }
}

fn substituteFirst(shell: anytype, value: []const u8, pattern: []const u8, replacement: []const u8) ![]const u8 {
    const matched = pattern_mod.firstMatch(value, pattern) orelse return value;
    return spliceSubstitution(shell, value, matched, replacement);
}

fn substituteAll(shell: anytype, value: []const u8, pattern: []const u8, replacement: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    var cursor: usize = 0;
    while (cursor <= value.len) {
        const matched = pattern_mod.firstMatchFrom(value, pattern, cursor) orelse break;
        try output.appendSlice(allocator, value[cursor..matched.start]);
        try output.appendSlice(allocator, replacement);
        cursor = matched.end;
        if (matched.start == matched.end) {
            if (cursor >= value.len) break;
            const next = pattern_mod.nextCut(value, cursor);
            try output.appendSlice(allocator, value[cursor..next]);
            cursor = next;
        }
    }
    if (output.items.len == 0) return value;
    try output.appendSlice(allocator, value[cursor..]);
    return output.toOwnedSlice(allocator);
}

fn substitutePrefix(shell: anytype, value: []const u8, pattern: []const u8, replacement: []const u8) ![]const u8 {
    const matched = pattern_mod.prefixMatch(value, pattern) orelse return value;
    return spliceSubstitution(shell, value, matched, replacement);
}

fn substituteSuffix(shell: anytype, value: []const u8, pattern: []const u8, replacement: []const u8) ![]const u8 {
    const matched = pattern_mod.suffixMatch(value, pattern) orelse return value;
    return spliceSubstitution(shell, value, matched, replacement);
}

fn spliceSubstitution(
    shell: anytype,
    value: []const u8,
    matched: pattern_mod.Match,
    replacement: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        shell.scratchAllocator(),
        "{s}{s}{s}",
        .{ value[0..matched.start], replacement, value[matched.end..] },
    );
}

fn isParameterSet(parameter: ast.ParameterExpansion, value: ?[]const u8) bool {
    return value != null and (!parameter.colon or value.?.len != 0);
}

fn writeExpansionDiagnostic(
    shell: anytype,
    parameter: ast.ParameterExpansion,
    name: []const u8,
    message: []const u8,
) !void {
    const diagnostic = try std.fmt.allocPrint(
        shell.scratchAllocator(),
        "{}: expansion error: {s}: {s}\n",
        .{ parameter.span.start_line + shell.state.diagnostic_line_offset, name, message },
    );
    try shell.host.writeAll(.stderr, diagnostic);
}

fn parameterValue(shell: anytype, name: []const u8) ?[]const u8 {
    if (dynamicParameterValue(shell, name)) |value| return value;
    if (shell.state.getVariable(name)) |variable| return variable.value;
    if (std.mem.eql(u8, name, "PPID")) return std.fmt.allocPrint(
        shell.scratchAllocator(),
        "{}",
        .{parentProcessId(shell)},
    ) catch null;
    if (std.mem.eql(u8, name, "PWD")) {
        if (comptime @hasDecl(@TypeOf(shell.host), "currentDir")) {
            return shell.host.currentDir(shell.scratchAllocator()) catch envValue(shell.env, name);
        }
    }
    return envValue(shell.env, name);
}

fn dynamicParameterValue(shell: anytype, name: []const u8) ?[]const u8 {
    if (shell.state.options.mode != .bash) return null;
    if (std.mem.eql(u8, name, "RANDOM")) return std.fmt.allocPrint(
        shell.scratchAllocator(),
        "{}",
        .{shell.state.nextRandom()},
    ) catch null;
    if (std.mem.eql(u8, name, "SECONDS")) return std.fmt.allocPrint(
        shell.scratchAllocator(),
        "{}",
        .{shell.state.secondsValue(currentWallTimeNs(shell))},
    ) catch null;
    if (std.mem.eql(u8, name, "EPOCHSECONDS")) return std.fmt.allocPrint(
        shell.scratchAllocator(),
        "{}",
        .{@divFloor(currentWallTimeNs(shell), std.time.ns_per_s)},
    ) catch null;
    if (std.mem.eql(u8, name, "EPOCHREALTIME")) {
        const now_ns = currentWallTimeNs(shell);
        return std.fmt.allocPrint(
            shell.scratchAllocator(),
            "{}.{d:0>6}",
            .{
                @divFloor(now_ns, std.time.ns_per_s),
                @as(u64, @intCast(@divFloor(@mod(now_ns, std.time.ns_per_s), std.time.ns_per_us))),
            },
        ) catch null;
    }
    return null;
}

fn currentWallTimeNs(shell: anytype) i128 {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (comptime @hasDecl(HostType, "wallTimeNs")) return shell.host.wallTimeNs();
    return shell.state.start_time_ns;
}

fn formatExitStatus(shell: anytype, status: result.ExitStatus) ![]const u8 {
    var buffer: [3]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{}", .{status});
    return shell.scratchAllocator().dupe(u8, text);
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn evalExternal(shell: anytype, fields: []const []const u8, assignments: []const ast.Assignment) EvalError!result.EvalResult {
    return evalExternalWithSearchPath(shell, fields, assignments, null);
}

fn evalExternalWithSearchPath(
    shell: anytype,
    fields: []const []const u8,
    assignments: []const ast.Assignment,
    search_path: ?[]const u8,
) EvalError!result.EvalResult {
    if (fields[0].len == 0) return .{ .status = 127 };
    const saved = try saveAssignmentVariables(shell, assignments);
    var restored_assignments = false;
    errdefer if (!restored_assignments) restoreVariables(shell, saved);
    try applyAssignments(shell, assignments);
    const command_path = switch (try searchExternalCommand(shell, fields[0], search_path)) {
        .executable => |path| path,
        .not_executable => {
            restoreVariables(shell, saved);
            restored_assignments = true;
            return .{ .status = 126 };
        },
        .not_found => {
            try writeCommandNotFoundDiagnostic(shell, fields[0], search_path);
            restoreVariables(shell, saved);
            restored_assignments = true;
            return .{ .status = 127 };
        },
    };
    try rememberCommandHash(shell, fields[0], command_path, search_path);
    const argv = try makeExecArgv(shell, fields);
    var request = try makeExternalSpawnRequestFromResolvedPath(
        shell,
        fields[1..],
        assignments,
        &.{},
        argv,
        command_path,
    );
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const status = if (@hasDecl(HostType, "spawn") and @hasDecl(HostType, "wait") and shell.state.options.monitor) status: {
        request.process_group = 0;
        const pid = (try shell.host.spawn(request)).pid;
        try setParentProcessGroup(shell, pid, pid);
        const foreground_restore_group = giveTerminalToProcessGroup(shell, pid) catch {
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            _ = shell.host.wait(pid) catch {};
            restoreVariables(shell, saved);
            restored_assignments = true;
            return .{ .status = 1 };
        };
        defer if (foreground_restore_group) |process_group| restoreTerminalToProcessGroup(shell, process_group);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        const waited = if (@hasDecl(HostType, "waitJobEvent")) try shell.host.waitJobEvent(pid) else try shell.host.wait(pid);
        switch (waited) {
            .stopped => {
                try shell.state.addBackgroundJob(pid, try externalCommandText(shell, fields), true);
                _ = shell.state.setBackgroundJobStatusByPid(pid, .stopped);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return .{ .status = waited.shellStatus() };
            },
            else => {},
        }
        break :status waited;
    } else try shell.host.spawnAndWait(request);
    restoreVariables(shell, saved);
    restored_assignments = true;
    return .{ .status = status.shellStatus() };
}

fn externalCommandText(shell: anytype, fields: []const []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    for (fields, 0..) |field, index| {
        if (index != 0) try output.append(allocator, ' ');
        try output.appendSlice(allocator, field);
    }
    return output.toOwnedSlice(allocator);
}

fn writeCommandNotFoundDiagnostic(shell: anytype, command: []const u8, search_path: ?[]const u8) !void {
    var suggestions: CommandSuggestions = .{};
    defer suggestions.deinit(shell.scratchAllocator());
    // Startup files commonly contain commands for another shell or an
    // optional tool. Do not walk and stat every executable in PATH before
    // the first prompt merely to improve their diagnostics.
    const interactive_startup = shell.state.options.interactive and
        shell.state.root_source_kind == .sourced_file;
    if (!interactive_startup) try collectCommandSuggestions(shell, command, search_path, &suggestions);
    if (suggestions.count == 0) {
        const message = try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: not found\n", .{command});
        try shell.host.writeAll(.stderr, message);
        return;
    }

    var message: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    const prefix = try std.fmt.allocPrint(allocator, "{s}: not found; did you mean: ", .{command});
    try message.appendSlice(allocator, prefix);
    for (suggestions.items[0..suggestions.count], 0..) |suggestion, index| {
        if (index != 0) try message.appendSlice(allocator, ", ");
        try message.appendSlice(allocator, suggestion.name);
    }
    try message.appendSlice(allocator, "?\n");
    try shell.host.writeAll(.stderr, message.items);
}

fn collectCommandSuggestions(
    shell: anytype,
    command: []const u8,
    search_path: ?[]const u8,
    suggestions: *CommandSuggestions,
) !void {
    if (std.mem.indexOfScalar(u8, command, '/') != null) return;

    var distance: EditDistance = .{};
    const allocator = shell.scratchAllocator();
    defer distance.deinit(allocator);

    const core_builtin_names = builtin.core_definitions.kvs.keys[0..builtin.core_definitions.kvs.len];
    for (core_builtin_names) |name| {
        if (lookupBuiltin(shell, name) == null) continue;
        try suggestions.consider(allocator, &distance, command, name);
    }

    var function_iterator = shell.state.functions.iterator();
    while (function_iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (shell.state.isFunctionAutoloadSuppressed(name)) continue;
        try suggestions.consider(allocator, &distance, command, name);
    }

    try collectAbbreviationSuggestions(allocator, shell, &distance, command, suggestions);
    try collectPathCommandSuggestions(allocator, shell, &distance, command, search_path, suggestions);
}

fn collectAbbreviationSuggestions(
    allocator: std.mem.Allocator,
    shell: anytype,
    distance: *EditDistance,
    command: []const u8,
    suggestions: *CommandSuggestions,
) !void {
    const ExtensionState = @TypeOf(shell.extensions);
    if (comptime !@hasField(ExtensionState, "abbreviations")) return;

    var iterator = shell.extensions.abbreviations.iterator();
    while (iterator.next()) |entry| try suggestions.consider(allocator, distance, command, entry.key_ptr.*);
}

fn collectPathCommandSuggestions(
    allocator: std.mem.Allocator,
    shell: anytype,
    distance: *EditDistance,
    command: []const u8,
    search_path: ?[]const u8,
    suggestions: *CommandSuggestions,
) !void {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (comptime !@hasDecl(HostType, "listDir") or !@hasDecl(HostType, "fileAccessZ")) return;

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const path = search_path orelse if (shell.state.getVariable("PATH")) |variable| variable.value else envPath(shell.env) orelse defaultUtilityPath();
    var candidate_buffer: std.ArrayList(u8) = .empty;
    defer candidate_buffer.deinit(allocator);
    var iterator = std.mem.splitScalar(u8, path, ':');
    while (iterator.next()) |raw_directory| {
        const directory = if (raw_directory.len == 0) "." else raw_directory;
        var entries = shell.host.listDir(allocator, directory) catch continue;
        defer entries.deinit();

        for (entries.entries) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (entry.kind == .directory) continue;
            if (suggestions.contains(entry.name)) continue;
            const candidate_distance = try distance.atMost(
                allocator,
                command,
                entry.name,
                command_suggestion_max_distance,
            ) orelse continue;
            candidate_buffer.clearRetainingCapacity();
            try candidate_buffer.appendSlice(allocator, directory);
            if (!std.mem.endsWith(u8, directory, "/")) try candidate_buffer.append(allocator, '/');
            try candidate_buffer.appendSlice(allocator, entry.name);
            try candidate_buffer.append(allocator, 0);
            const candidate = candidate_buffer.items[0 .. candidate_buffer.items.len - 1 :0];
            if (!shell.host.fileAccessZ(candidate, .execute)) continue;
            try suggestions.considerAtDistance(allocator, entry.name, candidate_distance);
        }
    }
}

const CommandSuggestion = struct {
    name: []const u8,
    distance: usize,
};

const CommandSuggestions = struct {
    items: [command_suggestion_limit]CommandSuggestion = undefined,
    count: usize = 0,

    fn deinit(self: *CommandSuggestions, allocator: std.mem.Allocator) void {
        for (self.items[0..self.count]) |item| allocator.free(item.name);
        self.* = undefined;
    }

    fn consider(
        self: *CommandSuggestions,
        allocator: std.mem.Allocator,
        distance: *EditDistance,
        command: []const u8,
        candidate: []const u8,
    ) !void {
        if (candidate.len == 0) return;
        if (self.contains(candidate)) return;
        const candidate_distance = try distance.atMost(
            allocator,
            command,
            candidate,
            command_suggestion_max_distance,
        ) orelse return;
        try self.considerAtDistance(allocator, candidate, candidate_distance);
    }

    fn considerAtDistance(
        self: *CommandSuggestions,
        allocator: std.mem.Allocator,
        candidate: []const u8,
        candidate_distance: usize,
    ) !void {
        std.debug.assert(candidate.len != 0);
        std.debug.assert(candidate_distance <= command_suggestion_max_distance);
        if (self.contains(candidate)) return;
        const suggestion: CommandSuggestion = .{
            .name = try allocator.dupe(u8, candidate),
            .distance = candidate_distance,
        };

        var insert_index: usize = 0;
        while (insert_index < self.count and
            suggestionAfter(self.items[insert_index], suggestion)) : (insert_index += 1)
        {}
        if (insert_index >= command_suggestion_limit) {
            allocator.free(suggestion.name);
            return;
        }

        if (self.count < command_suggestion_limit) {
            self.count += 1;
        } else {
            allocator.free(self.items[self.count - 1].name);
        }
        var index = self.count - 1;
        while (index > insert_index) : (index -= 1) self.items[index] = self.items[index - 1];
        self.items[insert_index] = suggestion;
    }

    fn contains(self: CommandSuggestions, name: []const u8) bool {
        for (self.items[0..self.count]) |item| if (std.mem.eql(u8, item.name, name)) return true;
        return false;
    }
};

fn suggestionAfter(existing: CommandSuggestion, candidate: CommandSuggestion) bool {
    if (existing.distance != candidate.distance) return existing.distance < candidate.distance;
    if (existing.name.len != candidate.name.len) return existing.name.len < candidate.name.len;
    return std.mem.lessThan(u8, existing.name, candidate.name);
}

const EditDistance = struct {
    previous: std.ArrayList(usize) = .empty,
    current: std.ArrayList(usize) = .empty,

    fn deinit(self: *EditDistance, allocator: std.mem.Allocator) void {
        self.previous.deinit(allocator);
        self.current.deinit(allocator);
        self.* = undefined;
    }

    fn atMost(self: *EditDistance, allocator: std.mem.Allocator, a: []const u8, b: []const u8, max: usize) !?usize {
        const length_delta = if (a.len > b.len) a.len - b.len else b.len - a.len;
        if (length_delta > max) return null;

        try self.previous.resize(allocator, b.len + 1);
        try self.current.resize(allocator, b.len + 1);
        for (self.previous.items, 0..) |*cell, index| cell.* = index;

        for (a, 0..) |a_byte, a_index| {
            self.current.items[0] = a_index + 1;
            var row_min = self.current.items[0];
            for (b, 0..) |b_byte, b_index| {
                const column = b_index + 1;
                const substitution_cost: usize = if (a_byte == b_byte) 0 else 1;
                const insertion = self.current.items[column - 1] + 1;
                const deletion = self.previous.items[column] + 1;
                const substitution = self.previous.items[column - 1] + substitution_cost;
                const value = @min(@min(insertion, deletion), substitution);
                self.current.items[column] = value;
                row_min = @min(row_min, value);
            }
            if (row_min > max) return null;
            std.mem.swap(std.ArrayList(usize), &self.previous, &self.current);
        }

        const final_distance = self.previous.items[b.len];
        return if (final_distance <= max) final_distance else null;
    }
};

const ExternalCommandSearchResult = union(enum) {
    executable: [:0]const u8,
    not_executable,
    not_found,
};

fn searchExternalCommand(
    shell: anytype,
    command: []const u8,
    search_path: ?[]const u8,
) !ExternalCommandSearchResult {
    std.debug.assert(command.len != 0);
    const allocator = shell.scratchAllocator();
    if (std.mem.indexOfScalar(u8, command, '/') != null) {
        const command_z = try allocator.dupeZ(u8, command);
        if (shell.host.isExecutableZ(command_z)) {
            if (try pathIsDirectory(shell, command, .other)) return .not_executable;
            return .{ .executable = command_z };
        }
        return if (shell.host.existsZ(command_z)) .not_executable else .not_found;
    }

    var found_not_executable = false;
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const path = search_path orelse if (shell.state.getVariable("PATH")) |variable| variable.value else envPath(shell.env) orelse defaultUtilityPath();
    var candidate_buffer: std.ArrayList(u8) = .empty;
    var iterator = std.mem.splitScalar(u8, path, ':');
    while (iterator.next()) |directory| {
        candidate_buffer.clearRetainingCapacity();
        const prefix = if (directory.len == 0) "." else directory;
        try candidate_buffer.appendSlice(allocator, prefix);
        if (!std.mem.endsWith(u8, prefix, "/")) try candidate_buffer.append(allocator, '/');
        try candidate_buffer.appendSlice(allocator, command);
        try candidate_buffer.append(allocator, 0);
        const candidate = candidate_buffer.items[0 .. candidate_buffer.items.len - 1 :0];
        if (shell.host.isExecutableZ(candidate)) {
            if (try pathIsDirectory(shell, candidate, .other)) {
                found_not_executable = true;
                continue;
            }
            return .{ .executable = candidate };
        }
        found_not_executable = found_not_executable or shell.host.existsZ(candidate);
    }
    return if (found_not_executable) .not_executable else .not_found;
}

fn rememberCommandHash(shell: anytype, command: []const u8, path: []const u8, search_path: ?[]const u8) !void {
    if (search_path != null) return;
    if (std.mem.indexOfScalar(u8, command, '/') != null) return;
    try shell.state.putCommandHash(.{ .name = command, .path = path });
}

fn makeExternalSpawnRequest(
    shell: anytype,
    fields: []const []const u8,
    assignments: []const ast.Assignment,
    fd_actions: []const host_mod.SpawnFdAction,
) !host_mod.SpawnRequest {
    return makeExternalSpawnRequestWithSearchPath(shell, fields, assignments, fd_actions, null);
}

fn makeExternalSpawnRequestWithSearchPath(
    shell: anytype,
    fields: []const []const u8,
    assignments: []const ast.Assignment,
    fd_actions: []const host_mod.SpawnFdAction,
    search_path: ?[]const u8,
) !host_mod.SpawnRequest {
    const argv = try makeExecArgv(shell, fields);
    const command_text = std.mem.span(argv[0].?);
    const command = argv[0].?[0..command_text.len :0];
    const path = try resolveCommandPathWithSearchPath(shell, command, search_path);
    return makeExternalSpawnRequestFromResolvedPath(shell, fields[1..], assignments, fd_actions, argv, path);
}

fn makeExternalSpawnRequestFromResolvedPath(
    shell: anytype,
    arguments: []const []const u8,
    assignments: []const ast.Assignment,
    fd_actions: []const host_mod.SpawnFdAction,
    argv: [:null]const ?[*:0]const u8,
    path: [:0]const u8,
) !host_mod.SpawnRequest {
    const envp = try makeExecEnvp(shell, assignments);
    return .{
        .path = path,
        .argv = argv,
        .fallback_argv = try makeShellFallbackArgv(shell, path, arguments),
        .envp = envp,
        .fd_actions = fd_actions,
        .default_signals = if (shell.state.options.monitor) &job_control_signals else &.{},
    };
}

fn makeShellFallbackArgv(
    shell: anytype,
    path: [:0]const u8,
    args: []const []const u8,
) ![:null]const ?[*:0]const u8 {
    const allocator = shell.scratchAllocator();
    const argv = try allocator.allocSentinel(?[*:0]const u8, args.len + 2, null);
    argv[0] = default_shell_path.ptr;
    argv[1] = path.ptr;
    for (args, 0..) |arg, index| argv[index + 2] = (try allocator.dupeZ(u8, arg)).ptr;
    return argv;
}

const default_shell_path: [:0]const u8 = "/bin/sh";

fn makeExecArgv(shell: anytype, fields: []const []const u8) ![:null]const ?[*:0]const u8 {
    std.debug.assert(fields.len != 0);
    const allocator = shell.scratchAllocator();
    const argv = try allocator.allocSentinel(?[*:0]const u8, fields.len, null);

    var total_len: usize = 0;
    for (fields) |bytes| {
        total_len = std.math.add(usize, total_len, bytes.len + 1) catch return error.OutOfMemory;
    }

    const arg_bytes = try allocator.alloc(u8, total_len);
    var cursor: usize = 0;
    for (fields, 0..) |bytes, index| {
        @memcpy(arg_bytes[cursor..][0..bytes.len], bytes);
        arg_bytes[cursor + bytes.len] = 0;
        argv[index] = arg_bytes[cursor .. cursor + bytes.len :0].ptr;
        cursor += bytes.len + 1;
    }

    return argv;
}

const AssignmentEnvEntry = struct {
    name: []const u8,
    value: []const u8,
};

fn makeExecEnvp(shell: anytype, assignments: []const ast.Assignment) ![:null]const ?[*:0]const u8 {
    const exported_count = countExportedVariables(shell);
    if (assignments.len == 0 and exported_count == 0) {
        if (comptime @hasDecl(@TypeOf(shell.*), "execEnvp")) return shell.execEnvp();

        const envp = try shell.scratchAllocator().allocSentinel(?[*:0]const u8, shell.env.len, null);
        for (shell.env, 0..) |entry, index| envp[index] = entry;
        return envp;
    }

    const allocator = shell.scratchAllocator();
    const assignment_entries = try allocator.alloc(AssignmentEnvEntry, exported_count + assignments.len);
    var entry_count: usize = 0;
    var variable_iterator = shell.state.bindings.iterator();
    while (variable_iterator.next()) |entry| {
        const variable = entry.value_ptr.variable() orelse continue;
        if (!variable.exported) continue;
        assignment_entries[entry_count] = .{ .name = variable.name, .value = variable.value };
        entry_count += 1;
    }
    for (assignments) |assignment| {
        assignment_entries[entry_count] = .{
            .name = assignment.name,
            .value = try execEnvAssignmentValue(shell, assignment),
        };
        entry_count += 1;
    }
    std.debug.assert(entry_count == assignment_entries.len);

    return makeEnvpFromEntries(shell, assignment_entries);
}

fn execEnvAssignmentValue(shell: anytype, assignment: ast.Assignment) ![]const u8 {
    if (assignment.append) {
        if (shell.state.getVariable(assignment.name)) |variable| return variable.value;
    }
    return expandAssignmentWordTracking(shell, assignment.value, null);
}

fn makeEnvpFromEntries(shell: anytype, assignment_entries: []const AssignmentEnvEntry) ![:null]const ?[*:0]const u8 {
    const allocator = shell.scratchAllocator();
    var env_len: usize = countBaseEnv(shell.env, assignment_entries);
    for (assignment_entries, 0..) |entry, index| {
        if (lastAssignmentIndex(assignment_entries, entry.name) == index) env_len += 1;
    }

    const envp = try allocator.allocSentinel(?[*:0]const u8, env_len, null);
    var env_index: usize = 0;
    for (shell.env) |entry| {
        const text = std.mem.span(entry);
        const name = envEntryName(text);
        if (containsAssignmentName(assignment_entries, name)) continue;
        envp[env_index] = entry;
        env_index += 1;
    }
    for (assignment_entries, 0..) |entry, index| {
        if (lastAssignmentIndex(assignment_entries, entry.name) != index) continue;
        envp[env_index] = (try makeEnvEntryZ(allocator, entry.name, entry.value)).ptr;
        env_index += 1;
    }
    std.debug.assert(env_index == env_len);
    return envp;
}

fn countExportedVariables(shell: anytype) usize {
    var count: usize = 0;
    var iterator = shell.state.bindings.valueIterator();
    while (iterator.next()) |binding| {
        const variable = binding.variable() orelse continue;
        if (variable.exported) count += 1;
    }
    return count;
}

fn makeEnvEntryZ(allocator: std.mem.Allocator, name: []const u8, value: []const u8) ![:0]const u8 {
    const entry = try allocator.allocSentinel(u8, name.len + 1 + value.len, 0);
    @memcpy(entry[0..name.len], name);
    entry[name.len] = '=';
    @memcpy(entry[name.len + 1 ..][0..value.len], value);
    return entry;
}

fn countBaseEnv(env: []const [*:0]const u8, assignments: []const AssignmentEnvEntry) usize {
    var count: usize = 0;
    for (env) |entry| {
        const name = envEntryName(std.mem.span(entry));
        if (!containsAssignmentName(assignments, name)) count += 1;
    }
    return count;
}

fn envEntryName(entry: []const u8) []const u8 {
    return entry[0 .. std.mem.indexOfScalar(u8, entry, '=') orelse entry.len];
}

fn containsAssignmentName(assignments: []const AssignmentEnvEntry, name: []const u8) bool {
    for (assignments) |assignment| {
        if (std.mem.eql(u8, assignment.name, name)) return true;
    }
    return false;
}

fn lastAssignmentIndex(assignments: []const AssignmentEnvEntry, name: []const u8) usize {
    var index = assignments.len;
    while (index != 0) {
        index -= 1;
        if (std.mem.eql(u8, assignments[index].name, name)) return index;
    }
    unreachable;
}

fn resolveCommandPath(shell: anytype, command: [:0]const u8) ![:0]const u8 {
    return resolveCommandPathWithSearchPath(shell, command, null);
}

fn resolveCommandPathWithSearchPath(shell: anytype, command: [:0]const u8, search_path: ?[]const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, command, '/') != null) return command;

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const path = search_path orelse if (shell.state.getVariable("PATH")) |variable| variable.value else envPath(shell.env) orelse defaultUtilityPath();
    const allocator = shell.scratchAllocator();
    var candidate_buffer: std.ArrayList(u8) = .empty;
    var iterator = std.mem.splitScalar(u8, path, ':');
    while (iterator.next()) |directory| {
        candidate_buffer.clearRetainingCapacity();
        const prefix = if (directory.len == 0) "." else directory;
        try candidate_buffer.appendSlice(allocator, prefix);
        if (!std.mem.endsWith(u8, prefix, "/")) try candidate_buffer.append(allocator, '/');
        try candidate_buffer.appendSlice(allocator, command);
        try candidate_buffer.append(allocator, 0);
        const candidate = candidate_buffer.items[0 .. candidate_buffer.items.len - 1 :0];
        if (shell.host.isExecutableZ(candidate)) return candidate;
    }

    return allocator.dupeZ(u8, command);
}

fn findCommandPath(shell: anytype, command: []const u8, search_path: ?[]const u8) !?[]const u8 {
    const allocator = shell.scratchAllocator();
    if (std.mem.indexOfScalar(u8, command, '/') != null) {
        const command_z = try allocator.dupeZ(u8, command);
        return if (shell.host.isExecutableZ(command_z)) command else null;
    }

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const path = search_path orelse if (shell.state.getVariable("PATH")) |variable| variable.value else envPath(shell.env) orelse defaultUtilityPath();
    var candidate_buffer: std.ArrayList(u8) = .empty;
    var iterator = std.mem.splitScalar(u8, path, ':');
    while (iterator.next()) |directory| {
        candidate_buffer.clearRetainingCapacity();
        const prefix = if (directory.len == 0) "." else directory;
        try candidate_buffer.appendSlice(allocator, prefix);
        if (!std.mem.endsWith(u8, prefix, "/")) try candidate_buffer.append(allocator, '/');
        try candidate_buffer.appendSlice(allocator, command);
        try candidate_buffer.append(allocator, 0);
        const candidate = candidate_buffer.items[0 .. candidate_buffer.items.len - 1 :0];
        if (shell.host.isExecutableZ(candidate)) return candidate;
    }
    return null;
}

fn defaultUtilityPath() []const u8 {
    return "/bin:/usr/bin";
}

fn envPath(env: []const [*:0]const u8) ?[]const u8 {
    return envValue(env, "PATH");
}

fn envValue(env: []const [*:0]const u8, name: []const u8) ?[]const u8 {
    for (env) |entry| {
        const text = std.mem.span(entry);
        const equals = std.mem.indexOfScalar(u8, text, '=') orelse continue;
        if (std.mem.eql(u8, text[0..equals], name)) return text[equals + 1 ..];
    }
    return null;
}

test "missing commands in interactive startup files do not scan PATH for suggestions" {
    const TestHost = struct {
        const Self = @This();

        stderr: std.ArrayList(u8) = .empty,
        list_dir_calls: usize = 0,

        fn writeAll(self: *Self, fd: host_mod.Fd, bytes: []const u8) !void {
            if (fd == .stderr) try self.stderr.appendSlice(std.testing.allocator, bytes);
        }

        fn listDir(self: *Self, _: std.mem.Allocator, _: []const u8) !host_mod.ListDirResult {
            self.list_dir_calls += 1;
            return error.FileNotFound;
        }

        fn fileAccessZ(_: *Self, _: [:0]const u8, _: host_mod.FileAccess) bool {
            return true;
        }
    };
    const TestShell = struct {
        const Self = @This();

        scratch: *std.heap.ArenaAllocator,
        host: *TestHost,
        env: []const [*:0]const u8 = &.{},
        state: state_mod.State,
        extensions: struct {} = .{},

        fn scratchAllocator(self: *Self) std.mem.Allocator {
            return self.scratch.allocator();
        }
    };

    var test_host: TestHost = .{};
    defer test_host.stderr.deinit(std.testing.allocator);
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var shell: TestShell = .{
        .scratch = &scratch,
        .host = &test_host,
        .state = .init(std.testing.allocator, .{ .interactive = true }),
    };
    defer shell.state.deinit();
    shell.state.root_source_kind = .sourced_file;

    try writeCommandNotFoundDiagnostic(&shell, "bindkey", "/commands");

    try std.testing.expectEqual(@as(usize, 0), test_host.list_dir_calls);
    try std.testing.expectEqualStrings("bindkey: not found\n", test_host.stderr.items);
}

test "bounded edit distance returns distances within cutoff" {
    var distance: EditDistance = .{};
    defer distance.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?usize, 0), try distance.atMost(std.testing.allocator, "printf", "printf", 2));
    try std.testing.expectEqual(@as(?usize, 1), try distance.atMost(std.testing.allocator, "prinf", "printf", 2));
    try std.testing.expectEqual(@as(?usize, 2), try distance.atMost(std.testing.allocator, "pritnf", "printf", 2));
    try std.testing.expectEqual(@as(?usize, null), try distance.atMost(std.testing.allocator, "abcdef", "printf", 2));
}

test "command suggestions keep the two nearest stable candidates" {
    var distance: EditDistance = .{};
    defer distance.deinit(std.testing.allocator);
    var suggestions: CommandSuggestions = .{};
    defer suggestions.deinit(std.testing.allocator);

    try suggestions.consider(std.testing.allocator, &distance, "gti", "gta");
    try suggestions.consider(std.testing.allocator, &distance, "gti", "git");
    try suggestions.consider(std.testing.allocator, &distance, "gti", "gt");
    try suggestions.consider(std.testing.allocator, &distance, "gti", "gtiiiii");

    try std.testing.expectEqual(@as(usize, 2), suggestions.count);
    try std.testing.expectEqualStrings("gt", suggestions.items[0].name);
    try std.testing.expectEqualStrings("gta", suggestions.items[1].name);
}

test "PATH command suggestions check executability only for close names" {
    const TestHost = struct {
        const Self = @This();

        file_access_calls: usize = 0,

        fn listDir(_: *Self, allocator: std.mem.Allocator, path: []const u8) !host_mod.ListDirResult {
            try std.testing.expectEqualStrings("/commands", path);
            const source = [_]host_mod.DirectoryEntry{
                .{ .name = "cat", .kind = .file },
                .{ .name = "git", .kind = .file },
                .{ .name = "gta", .kind = .file },
            };
            const entries = try allocator.alloc(host_mod.DirectoryEntry, source.len);
            var initialized: usize = 0;
            errdefer {
                for (entries[0..initialized]) |entry| allocator.free(entry.name);
                allocator.free(entries);
            }
            for (source, 0..) |entry, index| {
                entries[index] = .{
                    .name = try allocator.dupe(u8, entry.name),
                    .kind = entry.kind,
                };
                initialized += 1;
            }
            return .{ .allocator = allocator, .entries = entries };
        }

        fn fileAccessZ(self: *Self, path: [:0]const u8, access: host_mod.FileAccess) bool {
            std.debug.assert(access == .execute);
            self.file_access_calls += 1;
            return std.mem.endsWith(u8, path, "/git");
        }
    };
    const TestShell = struct {
        const Self = @This();

        scratch: *std.heap.ArenaAllocator,
        host: *TestHost,
        env: []const [*:0]const u8 = &.{},
        state: state_mod.State,

        fn scratchAllocator(self: *Self) std.mem.Allocator {
            return self.scratch.allocator();
        }
    };

    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var test_host: TestHost = .{};
    var shell: TestShell = .{
        .scratch = &scratch,
        .host = &test_host,
        .state = .init(std.testing.allocator, .{}),
    };
    defer shell.state.deinit();
    var distance: EditDistance = .{};
    defer distance.deinit(scratch.allocator());
    var suggestions: CommandSuggestions = .{};
    defer suggestions.deinit(scratch.allocator());

    try collectPathCommandSuggestions(
        scratch.allocator(),
        &shell,
        &distance,
        "gti",
        "/commands",
        &suggestions,
    );

    try std.testing.expectEqual(@as(usize, 2), test_host.file_access_calls);
    try std.testing.expectEqual(@as(usize, 1), suggestions.count);
    try std.testing.expectEqualStrings("git", suggestions.items[0].name);
}

test "external command search traverses PATH once" {
    const TestHost = struct {
        const Self = @This();

        executable_checks: usize = 0,
        existence_checks: usize = 0,
        directory_checks: usize = 0,

        fn isExecutableZ(self: *Self, path: [:0]const u8) bool {
            self.executable_checks += 1;
            return std.mem.eql(u8, path, "/two/cmd");
        }

        fn existsZ(self: *Self, path: [:0]const u8) bool {
            self.existence_checks += 1;
            return std.mem.eql(u8, path, "/one/cmd");
        }

        fn listDir(self: *Self, _: std.mem.Allocator, _: []const u8) !host_mod.ListDirResult {
            self.directory_checks += 1;
            return error.NotDir;
        }

        fn reset(self: *Self) void {
            self.executable_checks = 0;
            self.existence_checks = 0;
            self.directory_checks = 0;
        }
    };
    const TestShell = struct {
        const Self = @This();

        scratch: *std.heap.ArenaAllocator,
        host: *TestHost,
        env: []const [*:0]const u8 = &.{},
        state: state_mod.State,

        fn scratchAllocator(self: *Self) std.mem.Allocator {
            return self.scratch.allocator();
        }
    };

    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var test_host: TestHost = .{};
    var shell: TestShell = .{
        .scratch = &scratch,
        .host = &test_host,
        .state = .init(std.testing.allocator, .{}),
    };
    defer shell.state.deinit();

    const executable = try searchExternalCommand(&shell, "cmd", "/one:/two");
    switch (executable) {
        .executable => |path| try std.testing.expectEqualStrings("/two/cmd", path),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(@as(usize, 2), test_host.executable_checks);
    try std.testing.expectEqual(@as(usize, 1), test_host.existence_checks);
    try std.testing.expectEqual(@as(usize, 1), test_host.directory_checks);

    test_host.reset();
    const not_executable = try searchExternalCommand(&shell, "cmd", "/missing:/one");
    try std.testing.expect(not_executable == .not_executable);
    try std.testing.expectEqual(@as(usize, 2), test_host.executable_checks);
    try std.testing.expectEqual(@as(usize, 2), test_host.existence_checks);
    try std.testing.expectEqual(@as(usize, 0), test_host.directory_checks);

    test_host.reset();
    const not_found = try searchExternalCommand(&shell, "cmd", "/missing");
    try std.testing.expect(not_found == .not_found);
    try std.testing.expectEqual(@as(usize, 1), test_host.executable_checks);
    try std.testing.expectEqual(@as(usize, 1), test_host.existence_checks);
    try std.testing.expectEqual(@as(usize, 0), test_host.directory_checks);
}

test "cd suggestions choose nearest directory in target parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host: CdSuggestionTestHost = .{
        .parent = "repos",
        .entries = &.{
            .{ .name = "fish", .kind = .directory },
            .{ .name = "rush", .kind = .directory },
            .{ .name = "bash", .kind = .file },
        },
    };
    var sh: CdSuggestionTestShell = .{ .host = &host, .allocator = arena.allocator() };

    const suggestion = try collectCdSuggestion(&sh, "repos/ruxh") orelse return error.MissingSuggestion;

    try std.testing.expectEqualStrings("repos/rush", suggestion);
}

test "cd suggestions ignore weak matches and glob-like targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host: CdSuggestionTestHost = .{
        .parent = ".",
        .entries = &.{.{ .name = "rush", .kind = .directory }},
    };
    var sh: CdSuggestionTestShell = .{ .host = &host, .allocator = arena.allocator() };

    try std.testing.expect(try collectCdSuggestion(&sh, "very-different") == null);
    try std.testing.expect(try collectCdSuggestion(&sh, "ru*") == null);
}

test "cd suggestion diagnostic styles the suggested directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = state_mod.State.init(arena.allocator(), .{ .interactive = true });
    defer state.deinit();
    try state.putVariable(.{ .name = "rush_style_directory", .value = "fg=red" });
    var host: CdSuggestionTestHost = .{
        .parent = "repos",
        .entries = &.{.{ .name = "rush", .kind = .directory }},
    };
    defer host.stderr.deinit(std.testing.allocator);
    var sh: CdSuggestionDiagnosticTestShell = .{
        .host = &host,
        .state = &state,
        .allocator = arena.allocator(),
    };

    try writeCdFailureDiagnostic(&sh, "cd", "repos/ruxh", error.FileNotFound, "repos/rush", .line);

    try std.testing.expectEqualStrings(
        "cd: repos/ruxh: no such directory; did you mean: \x1b[1m\x1b[31mrepos/rush\x1b[22m\x1b[39m?\n",
        host.stderr.items,
    );
}

test "z builtin jumps through directory history" {
    const TestHost = struct {
        const Self = @This();

        cwd: []const u8 = "/old",
        stdout: std.ArrayList(u8) = .empty,
        stderr: std.ArrayList(u8) = .empty,

        fn deinit(self: *Self) void {
            self.stdout.deinit(std.testing.allocator);
            self.stderr.deinit(std.testing.allocator);
            self.* = undefined;
        }

        fn currentDir(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
            return allocator.dupe(u8, self.cwd);
        }

        fn changeDir(self: *Self, target: []const u8) !void {
            if (!std.mem.eql(u8, target, "/repo/project")) return error.FileNotFound;
            self.cwd = "/repo/project";
        }

        fn currentParentProcessId(_: *Self) host_mod.Pid {
            return 1;
        }

        fn writeAll(self: *Self, fd: host_mod.Fd, bytes: []const u8) !void {
            switch (fd) {
                .stdin => {},
                .stdout => try self.stdout.appendSlice(std.testing.allocator, bytes),
                .stderr => try self.stderr.appendSlice(std.testing.allocator, bytes),
                else => {},
            }
        }
    };
    const JumpContext = struct {
        const Self = @This();

        seen_terms: []const []const u8 = &.{},

        fn list(
            _: *anyopaque,
            // ziglint-ignore: Z023 parameter order follows CommandHistory.list callback shape
            allocator: std.mem.Allocator,
        ) ![]history_mod.HistoryEntry {
            return allocator.alloc(history_mod.HistoryEntry, 0);
        }

        fn jump(
            context: *anyopaque,
            // ziglint-ignore: Z023 parameter order follows CommandHistory.jump callback shape
            allocator: std.mem.Allocator,
            terms: []const []const u8,
            exclude: []const u8,
            now: i64,
        ) !?[]const u8 {
            _ = now;
            const self: *Self = @ptrCast(@alignCast(context));
            self.seen_terms = terms;
            try std.testing.expectEqualStrings("/old", exclude);
            const target = try allocator.dupe(u8, "/repo/project");
            return target;
        }
    };
    const TestShell = struct {
        const Self = @This();

        host: TestHost,
        state: state_mod.State,
        env: []const [*:0]const u8 = &.{},
        command_history: ?history_mod.CommandHistory = null,
        scratch: std.mem.Allocator,
        notified_old: []const u8 = "",
        notified_new: []const u8 = "",

        fn scratchAllocator(self: *Self) std.mem.Allocator {
            return self.scratch;
        }

        fn notifyDirectoryChange(self: *Self, old_pwd: []const u8, new_pwd: []const u8) void {
            self.notified_old = old_pwd;
            self.notified_new = new_pwd;
        }
    };

    var jump_context: JumpContext = .{};
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var shell: TestShell = .{
        .host = .{},
        .state = state_mod.State.init(std.testing.allocator, .{}),
        .scratch = scratch.allocator(),
    };
    defer shell.host.deinit();
    defer shell.state.deinit();
    shell.command_history = .{
        .context = &jump_context,
        .io = std.testing.io,
        .list = JumpContext.list,
        .jump = JumpContext.jump,
    };

    try std.testing.expectEqual(@as(result.ExitStatus, 0), (try evalZBuiltin(&shell, &.{ "z", "proj" })).status);
    try std.testing.expectEqualStrings("proj", jump_context.seen_terms[0]);
    try std.testing.expectEqualStrings("/repo/project", shell.host.cwd);
    try std.testing.expectEqualStrings("/old", shell.state.getVariable("OLDPWD").?.value);
    try std.testing.expectEqualStrings("/repo/project", shell.state.getVariable("PWD").?.value);
    try std.testing.expectEqualStrings("/old", shell.notified_old);
    try std.testing.expectEqualStrings("/repo/project", shell.notified_new);
}

test "cd suggestion prompt accepts y and times out to no" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = state_mod.State.init(arena.allocator(), .{ .interactive = true });
    defer state.deinit();
    var host: CdSuggestionTestHost = .{
        .parent = "repos",
        .entries = &.{.{ .name = "rush", .kind = .directory }},
        .interactive_key = 'y',
    };
    defer host.stderr.deinit(std.testing.allocator);
    var sh: CdSuggestionDiagnosticTestShell = .{
        .host = &host,
        .state = &state,
        .allocator = arena.allocator(),
    };

    const accepted = try cdSuggestionRecoveryTarget(&sh, "cd", "repos/ruxh", error.FileNotFound) orelse
        return error.MissingSuggestion;

    try std.testing.expectEqualStrings("repos/rush", accepted);
    try std.testing.expectEqual(@as(?u64, cd_suggestion_confirm_timeout_ms), host.interactive_key_timeout_ms);
    try std.testing.expectEqualStrings(
        "did you mean: \x1b[1m\x1b[34mrepos/rush\x1b[22m\x1b[39m? [y,N] \n",
        host.stderr.items,
    );

    host.stderr.clearRetainingCapacity();
    host.interactive_key = null;
    host.interactive_key_timeout_ms = null;

    try std.testing.expect(try cdSuggestionRecoveryTarget(&sh, "cd", "repos/ruxh", error.FileNotFound) == null);
    try std.testing.expectEqual(@as(?u64, cd_suggestion_confirm_timeout_ms), host.interactive_key_timeout_ms);
    try std.testing.expectEqualStrings(
        "did you mean: \x1b[1m\x1b[34mrepos/rush\x1b[22m\x1b[39m? [y,N] \n" ++
            "cd: repos/ruxh: no such directory\n",
        host.stderr.items,
    );
}

const CdSuggestionTestHost = struct {
    parent: []const u8,
    entries: []const host_mod.DirectoryEntry,
    stderr: std.ArrayList(u8) = .empty,
    interactive_key: ?u8 = null,
    interactive_key_timeout_ms: ?u64 = null,

    fn listDir(self: *CdSuggestionTestHost, allocator: std.mem.Allocator, path: []const u8) !host_mod.ListDirResult {
        if (!std.mem.eql(u8, path, self.parent)) return error.FileNotFound;
        const entries = try allocator.alloc(host_mod.DirectoryEntry, self.entries.len);
        errdefer allocator.free(entries);
        for (self.entries, 0..) |entry, index| {
            entries[index] = .{
                .name = try allocator.dupe(u8, entry.name),
                .kind = entry.kind,
            };
        }
        return .{ .allocator = allocator, .entries = entries };
    }

    fn writeAll(self: *CdSuggestionTestHost, fd: host_mod.Fd, bytes: []const u8) !void {
        if (fd != .stderr) return;
        try self.stderr.appendSlice(std.testing.allocator, bytes);
    }

    fn readInteractiveKey(self: *CdSuggestionTestHost, timeout_ms: u64) ?u8 {
        self.interactive_key_timeout_ms = timeout_ms;
        return self.interactive_key;
    }
};

const CdSuggestionTestShell = struct {
    host: *CdSuggestionTestHost,
    allocator: std.mem.Allocator,

    fn scratchAllocator(self: *CdSuggestionTestShell) std.mem.Allocator {
        return self.allocator;
    }
};

const CdSuggestionDiagnosticTestShell = struct {
    host: *CdSuggestionTestHost,
    state: *state_mod.State,
    allocator: std.mem.Allocator,

    fn scratchAllocator(self: *CdSuggestionDiagnosticTestShell) std.mem.Allocator {
        return self.allocator;
    }
};
