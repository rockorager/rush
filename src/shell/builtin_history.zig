//! Implements the `fc` and `history` builtin family.
//!
//! History mutation, editor handoff, and command re-execution operate through
//! the caller's concrete shell and Host so current-shell effects remain explicit.

const std = @import("std");

const host = @import("../host.zig");
const history_mod = @import("command_history.zig");
const result = @import("result.zig");

pub fn evalFc(shell: anytype, args: []const []const u8) !result.EvalResult {
    const command_history = shellCommandHistory(shell) orelse {
        try shell.host.writeAll(.stderr, "fc: history not active\n");
        return .{ .status = 1 };
    };

    const options = parseFcOptions(args) orelse return fcUsageError(shell);
    if (options.list and options.reexecute) return fcUsageError(shell);
    if (options.no_numbers and !options.list) return fcUsageError(shell);
    if (options.editor != null and (options.list or options.reexecute)) return fcUsageError(shell);

    const allocator = shell.scratchAllocator();
    const entries = command_history.list(command_history.context, allocator) catch return fcHistoryError(shell);
    defer freeFcEntries(allocator, entries);

    if (options.reexecute) return evalFcReexecute(shell, command_history, entries, args[options.operand_index..]);
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (options.list) return evalFcList(shell, entries, args[options.operand_index..], options.no_numbers, options.reverse);
    return evalFcEdit(shell, command_history, entries, args[options.operand_index..], options.editor, options.reverse);
}

const FcOptions = struct {
    list: bool = false,
    no_numbers: bool = false,
    reverse: bool = false,
    reexecute: bool = false,
    editor: ?[]const u8 = null,
    operand_index: usize = 1,
};

fn parseFcOptions(args: []const []const u8) ?FcOptions {
    var options: FcOptions = .{};
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    while (options.operand_index < args.len and isFcOptionArg(args[options.operand_index])) : (options.operand_index += 1) {
        const arg = args[options.operand_index];
        if (std.mem.eql(u8, arg, "--")) {
            options.operand_index += 1;
            break;
        }
        var option_index: usize = 1;
        while (option_index < arg.len) : (option_index += 1) switch (arg[option_index]) {
            'l' => options.list = true,
            'n' => options.no_numbers = true,
            'r' => options.reverse = true,
            's' => options.reexecute = true,
            'e' => {
                if (option_index + 1 < arg.len) {
                    options.editor = arg[option_index + 1 ..];
                    option_index = arg.len;
                    continue;
                }
                options.operand_index += 1;
                if (options.operand_index >= args.len) return null;
                options.editor = args[options.operand_index];
                option_index = arg.len;
                continue;
            },
            else => return null,
        };
    }
    return options;
}

fn isFcOptionArg(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-' and !std.ascii.isDigit(arg[1]);
}

fn shellCommandHistory(shell: anytype) ?*history_mod.CommandHistory {
    const ShellType = switch (@typeInfo(@TypeOf(shell))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell),
    };
    if (!@hasField(ShellType, "command_history")) return null;
    if (shell.command_history) |*command_history| return command_history;
    return null;
}

fn freeFcEntries(allocator: std.mem.Allocator, entries: []history_mod.HistoryEntry) void {
    for (entries) |entry| allocator.free(entry.command);
    allocator.free(entries);
}

fn evalFcList(
    shell: anytype,
    entries: []const history_mod.HistoryEntry,
    operands: []const []const u8,
    no_numbers: bool,
    reverse: bool,
) !result.EvalResult {
    if (entries.len == 0) return .{};
    if (operands.len > 2) return fcUsageError(shell);

    const last_entry_index = entries.len - 1;
    const first_index = if (operands.len >= 1)
        fcEntryIndex(entries, operands[0]) orelse return fcNoHistoryMatch(shell)
    else if (entries.len > 16)
        entries.len - 16
    else
        0;
    const last_index = if (operands.len >= 2)
        fcEntryIndex(entries, operands[1]) orelse return fcNoHistoryMatch(shell)
    else
        last_entry_index;

    const descending_range = first_index > last_index;
    const output_reverse = reverse != descending_range;
    const start = @min(first_index, last_index);
    const end = @max(first_index, last_index);

    if (output_reverse) {
        var index = end + 1;
        while (index > start) {
            index -= 1;
            try writeFcEntry(shell, entries[index], no_numbers);
        }
    } else {
        var index = start;
        while (index <= end) : (index += 1) try writeFcEntry(shell, entries[index], no_numbers);
    }
    return .{};
}

fn evalFcReexecute(
    shell: anytype,
    command_history: *history_mod.CommandHistory,
    entries: []const history_mod.HistoryEntry,
    operands: []const []const u8,
) !result.EvalResult {
    const ShellType = switch (@typeInfo(@TypeOf(shell))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell),
    };
    if (!@hasDecl(ShellType, "evalSourceNested")) {
        try shell.host.writeAll(.stderr, "fc: re-execution unavailable\n");
        return .{ .status = 2 };
    }
    if (entries.len == 0) return fcNoHistoryMatch(shell);

    var replacement: ?FcReplacement = null;
    var selector: ?[]const u8 = null;
    if (operands.len >= 1) {
        if (fcReplacement(operands[0])) |parsed| {
            replacement = parsed;
            if (operands.len >= 2) selector = operands[1];
            if (operands.len > 2) return fcUsageError(shell);
        } else {
            selector = operands[0];
            if (operands.len > 1) return fcUsageError(shell);
        }
    }

    const entry_index = if (selector) |operand|
        fcEntryIndex(entries, operand) orelse return fcNoHistoryMatch(shell)
    else
        entries.len - 1;
    const command = try fcReexecuteCommand(shell.scratchAllocator(), entries[entry_index].command, replacement);
    defer if (command.owned) shell.scratchAllocator().free(command.text);

    return evalFcCommand(shell, command_history, command.text);
}

fn evalFcEdit(
    shell: anytype,
    command_history: *history_mod.CommandHistory,
    entries: []const history_mod.HistoryEntry,
    operands: []const []const u8,
    editor: ?[]const u8,
    reverse: bool,
) !result.EvalResult {
    if (entries.len == 0) return fcNoHistoryMatch(shell);
    if (operands.len > 2) return fcUsageError(shell);
    if (comptime !fcEditorAvailable(@TypeOf(shell.host))) {
        try shell.host.writeAll(.stderr, "fc: editor unavailable\n");
        return .{ .status = 2 };
    }

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const selected = fcSelectedCommands(shell.scratchAllocator(), entries, operands, reverse, .edit) catch |err| switch (err) {
        error.NoHistoryMatch => return fcNoHistoryMatch(shell),
        else => return err,
    };
    defer shell.scratchAllocator().free(selected);

    const temp_path = createFcTempFile(shell, selected) catch return fcHistoryError(shell);
    defer deleteFcTempFile(shell, temp_path);
    defer shell.scratchAllocator().free(temp_path);

    const editor_name = fcEditorName(shell, editor);
    const editor_status = runFcEditor(shell, editor_name, temp_path) catch return fcEditorError(shell);
    if (editor_status != 0) return .{ .status = editor_status };

    const edited = readFcTempFile(shell, temp_path) catch return fcHistoryError(shell);
    defer shell.scratchAllocator().free(edited);
    return evalFcCommand(shell, command_history, edited);
}

const FcRangeMode = enum { list, edit };

fn fcSelectedCommands(
    allocator: std.mem.Allocator,
    entries: []const history_mod.HistoryEntry,
    operands: []const []const u8,
    reverse: bool,
    mode: FcRangeMode,
) ![]const u8 {
    const range = fcRange(entries, operands, mode) orelse return error.NoHistoryMatch;
    const descending_range = range.first > range.last;
    const output_reverse = reverse != descending_range;
    const start = @min(range.first, range.last);
    const end = @max(range.first, range.last);

    var text: std.ArrayList(u8) = .empty;
    if (output_reverse) {
        var index = end + 1;
        while (index > start) {
            index -= 1;
            try text.appendSlice(allocator, entries[index].command);
            try text.append(allocator, '\n');
        }
    } else {
        var index = start;
        while (index <= end) : (index += 1) {
            try text.appendSlice(allocator, entries[index].command);
            try text.append(allocator, '\n');
        }
    }
    return text.toOwnedSlice(allocator);
}

const FcRange = struct { first: usize, last: usize };

fn fcRange(entries: []const history_mod.HistoryEntry, operands: []const []const u8, mode: FcRangeMode) ?FcRange {
    if (entries.len == 0 or operands.len > 2) return null;

    const last_entry_index = entries.len - 1;
    const first_index = if (operands.len >= 1)
        fcEntryIndex(entries, operands[0]) orelse return null
    else switch (mode) {
        .list => if (entries.len > 16) entries.len - 16 else 0,
        .edit => last_entry_index,
    };
    const last_index = if (operands.len >= 2)
        fcEntryIndex(entries, operands[1]) orelse return null
    else switch (mode) {
        .list => last_entry_index,
        .edit => first_index,
    };
    return .{ .first = first_index, .last = last_index };
}

fn evalFcCommand(shell: anytype, command_history: *history_mod.CommandHistory, command: []const u8) !result.EvalResult {
    const ShellType = switch (@typeInfo(@TypeOf(shell))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell),
    };
    if (!@hasDecl(ShellType, "evalSourceNested")) {
        try shell.host.writeAll(.stderr, "fc: re-execution unavailable\n");
        return .{ .status = 2 };
    }

    if (command_history.suppress_next_append) |suppress| suppress(command_history.context);

    const started_at = std.Io.Clock.real.now(command_history.io).toSeconds();
    const evaluated = try shell.evalSourceNested(.{
        .id = 0,
        .kind = .interactive,
        .name = "fc",
        .text = command,
    });
    const duration_ms = @max(std.Io.Clock.real.now(command_history.io).toSeconds() - started_at, 0) * 1000;
    if (command_history.append) |append| {
        // ziglint-ignore: Z024 Z026 preserve existing readable expression shape; lint-only cleanup; intentional best-effort cleanup; preserve behavior
        append(command_history.context, command_history.io, command, evaluated.status, started_at, duration_ms) catch {};
    }
    return evaluated;
}

fn fcEditorAvailable(comptime HostValueType: type) bool {
    const HostType = switch (@typeInfo(HostValueType)) {
        .pointer => |pointer| pointer.child,
        else => HostValueType,
    };
    return @hasDecl(HostType, "openZ") and
        @hasDecl(HostType, "close") and
        @hasDecl(HostType, "read") and
        @hasDecl(HostType, "deleteFileZ") and
        @hasDecl(HostType, "spawn") and
        @hasDecl(HostType, "wait") and
        @hasDecl(HostType, "isExecutableZ");
}

fn fcEditorName(shell: anytype, editor: ?[]const u8) []const u8 {
    if (editor) |name| if (name.len != 0) return name;
    if (shell.state.getVariable("FCEDIT")) |variable| if (variable.value.len != 0) return variable.value;
    if (shellEnvValue(shell, "FCEDIT")) |value| if (value.len != 0) return value;
    return "ed";
}

fn shellEnvValue(shell: anytype, name: []const u8) ?[]const u8 {
    const ShellType = switch (@typeInfo(@TypeOf(shell))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell),
    };
    if (!@hasField(ShellType, "env")) return null;
    const variable = shell.state.lookupVariable(shell.env, name) orelse return null;
    return variable.value;
}

fn createFcTempFile(shell: anytype, contents: []const u8) ![]const u8 {
    const allocator = shell.scratchAllocator();
    const pid = fcTempPid(shell);
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        const path = try std.fmt.allocPrint(allocator, "/tmp/rush-fc-{}-{}", .{ pid, attempt });
        errdefer allocator.free(path);
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const fd = shell.host.openZ(path_z, .{
            .access = .read_write,
            .create = true,
            .exclusive = true,
            .truncate = true,
            .mode = 0o600,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        var close = true;
        errdefer if (close) shell.host.close(fd) catch {};
        try shell.host.writeAll(fd, contents);
        try shell.host.close(fd);
        close = false;
        return path;
    }
    return error.PathAlreadyExists;
}

fn fcTempPid(shell: anytype) host.Pid {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (!@hasDecl(HostType, "currentProcessId")) return 0;
    return shell.host.currentProcessId();
}

fn deleteFcTempFile(shell: anytype, path: []const u8) void {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (!@hasDecl(HostType, "deleteFileZ")) return;
    const path_z = shell.scratchAllocator().dupeZ(u8, path) catch return;
    defer shell.scratchAllocator().free(path_z);
    // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
    shell.host.deleteFileZ(path_z) catch {};
}

fn readFcTempFile(shell: anytype, path: []const u8) ![]const u8 {
    const allocator = shell.scratchAllocator();
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = try shell.host.openZ(path_z, .{ .access = .read_only });
    defer shell.host.close(fd) catch {};

    var bytes: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_len = try shell.host.read(fd, &buffer);
        if (read_len == 0) break;
        try bytes.appendSlice(allocator, buffer[0..read_len]);
    }
    return bytes.toOwnedSlice(allocator);
}

fn runFcEditor(shell: anytype, editor: []const u8, path: []const u8) !result.ExitStatus {
    const allocator = shell.scratchAllocator();
    const editor_path_z = (try fcResolveEditorPathZ(shell, editor)) orelse return error.FileNotFound;
    defer allocator.free(editor_path_z);
    const editor_arg_z = try allocator.dupeZ(u8, editor);
    defer allocator.free(editor_arg_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const argv = try allocator.allocSentinel(?[*:0]const u8, 2, null);
    defer allocator.free(argv);
    argv[0] = editor_arg_z.ptr;
    argv[1] = path_z.ptr;

    const envp = try fcEditorEnvp(shell);
    defer allocator.free(envp);
    const spawned = try shell.host.spawn(.{
        .path = editor_path_z,
        .argv = argv,
        .envp = envp,
    });
    return (try shell.host.wait(spawned.pid)).shellStatus();
}

fn fcEditorEnvp(shell: anytype) ![:null]const ?[*:0]const u8 {
    const ShellType = switch (@typeInfo(@TypeOf(shell))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell),
    };
    const allocator = shell.scratchAllocator();
    if (@hasField(ShellType, "env")) {
        const envp = try allocator.allocSentinel(?[*:0]const u8, shell.env.len, null);
        for (shell.env, 0..) |entry, index| envp[index] = entry;
        return envp;
    }
    return allocator.allocSentinel(?[*:0]const u8, 0, null);
}

fn fcResolveEditorPathZ(shell: anytype, editor: []const u8) !?[:0]u8 {
    const allocator = shell.scratchAllocator();
    if (std.mem.indexOfScalar(u8, editor, '/') != null) {
        const editor_z = try allocator.dupeZ(u8, editor);
        errdefer allocator.free(editor_z);
        if (shell.host.isExecutableZ(editor_z)) return editor_z;
        allocator.free(editor_z);
        return null;
    }

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const path = if (shell.state.getVariable("PATH")) |variable| variable.value else shellEnvValue(shell, "PATH") orelse defaultUtilityPath();
    var iterator = std.mem.splitScalar(u8, path, ':');
    while (iterator.next()) |directory| {
        const prefix = if (directory.len == 0) "." else directory;
        const candidate_text = if (std.mem.endsWith(u8, prefix, "/"))
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, editor })
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, editor });
        defer allocator.free(candidate_text);
        const candidate = try allocator.dupeZ(u8, candidate_text);
        errdefer allocator.free(candidate);
        if (shell.host.isExecutableZ(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn fcEntryIndex(entries: []const history_mod.HistoryEntry, selector: []const u8) ?usize {
    if (selector.len == 0) return null;
    if (selector[0] == '-') {
        const offset = std.fmt.parseInt(usize, selector[1..], 10) catch return null;
        if (offset == 0 or offset > entries.len) return null;
        return entries.len - offset;
    }
    if (std.ascii.isDigit(selector[0]) or selector[0] == '+') {
        const number_text = if (selector[0] == '+') selector[1..] else selector;
        const number = std.fmt.parseInt(i64, number_text, 10) catch return null;
        for (entries, 0..) |entry, index| if (entry.number == number) return index;
        return null;
    }

    var index = entries.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.startsWith(u8, entries[index].command, selector)) return index;
    }
    return null;
}

fn writeFcEntry(shell: anytype, entry: history_mod.HistoryEntry, no_numbers: bool) !void {
    var lines = std.mem.splitScalar(u8, entry.command, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (first and !no_numbers) {
            try shell.host.writeAll(.stdout, try std.fmt.allocPrint(shell.scratchAllocator(), "{}\t", .{entry.number}));
        } else {
            try shell.host.writeAll(.stdout, "\t");
        }
        try shell.host.writeAll(.stdout, line);
        try shell.host.writeAll(.stdout, "\n");
        first = false;
    }
}

const FcReplacement = struct {
    old: []const u8,
    new: []const u8,
};

const FcCommand = struct {
    text: []const u8,
    owned: bool = false,
};

fn fcReplacement(operand: []const u8) ?FcReplacement {
    const equals = std.mem.indexOfScalar(u8, operand, '=') orelse return null;
    return .{ .old = operand[0..equals], .new = operand[equals + 1 ..] };
}

fn fcReexecuteCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    replacement: ?FcReplacement,
) !FcCommand {
    const parsed = replacement orelse return .{ .text = command };
    if (parsed.old.len == 0) return .{ .text = command };
    const match = std.mem.indexOf(u8, command, parsed.old) orelse return .{ .text = command };

    var command_output: std.ArrayList(u8) = .empty;
    try command_output.appendSlice(allocator, command[0..match]);
    try command_output.appendSlice(allocator, parsed.new);
    try command_output.appendSlice(allocator, command[match + parsed.old.len ..]);
    return .{ .text = try command_output.toOwnedSlice(allocator), .owned = true };
}

const default_history_list_count = 16;

pub fn evalHistory(shell: anytype, args: []const []const u8) !result.EvalResult {
    const command_history = shellCommandHistory(shell) orelse {
        try shell.host.writeAll(.stderr, "history: history not active\n");
        return .{ .status = 1 };
    };
    // Never record history invocations: recording them would make every
    // search match its own command line and leave "history clear" behind
    // as the sole entry after a clear.
    if (command_history.suppress_next_append) |suppress| suppress(command_history.context);
    if (args.len <= 1) return evalHistoryList(shell, command_history, null);
    const subcommand = args[1];
    if (historyListCount(subcommand)) |count| {
        if (args.len > 2) return historyUsageError(shell);
        return evalHistoryList(shell, command_history, count);
    }
    if (std.mem.eql(u8, subcommand, "list")) {
        if (args.len > 3) return historyUsageError(shell);
        const count = if (args.len == 3)
            historyListCount(args[2]) orelse return historyUsageError(shell)
        else
            null;
        return evalHistoryList(shell, command_history, count);
    }
    if (std.mem.eql(u8, subcommand, "search")) return evalHistorySearch(shell, command_history, args[2..]);
    if (std.mem.eql(u8, subcommand, "delete")) return evalHistoryDelete(shell, command_history, args[2..]);
    if (std.mem.eql(u8, subcommand, "clear")) {
        if (args.len > 2) return historyUsageError(shell);
        const clear = command_history.clear orelse return historyUnavailable(shell);
        clear(command_history.context) catch return historyError(shell);
        return .{};
    }
    return historyUsageError(shell);
}

fn historyListCount(operand: []const u8) ?usize {
    return std.fmt.parseUnsigned(usize, operand, 10) catch null;
}

fn evalHistoryList(
    shell: anytype,
    command_history: *history_mod.CommandHistory,
    count: ?usize,
) !result.EvalResult {
    const allocator = shell.scratchAllocator();
    const entries = command_history.list(command_history.context, allocator) catch return historyError(shell);
    defer freeFcEntries(allocator, entries);
    const limit = count orelse default_history_list_count;
    const start = entries.len -| limit;
    for (entries[start..]) |entry| try writeFcEntry(shell, entry, false);
    return .{};
}

fn evalHistorySearch(
    shell: anytype,
    command_history: *history_mod.CommandHistory,
    operands: []const []const u8,
) !result.EvalResult {
    if (operands.len == 0) return historyUsageError(shell);
    const search = command_history.search orelse return historyUnavailable(shell);
    const allocator = shell.scratchAllocator();
    const query = try std.mem.join(allocator, " ", operands);
    defer allocator.free(query);
    const entries = search(command_history.context, allocator, query) catch return historyError(shell);
    defer freeFcEntries(allocator, entries);
    for (entries) |entry| try writeFcEntry(shell, entry, false);
    return .{};
}

fn evalHistoryDelete(
    shell: anytype,
    command_history: *history_mod.CommandHistory,
    operands: []const []const u8,
) !result.EvalResult {
    if (operands.len == 0) return historyUsageError(shell);
    const delete_id = command_history.delete_id orelse return historyUnavailable(shell);
    var failed = false;
    var index: usize = 0;
    while (index < operands.len) : (index += 1) {
        const operand = operands[index];
        var value: []const u8 = undefined;
        if (std.mem.eql(u8, operand, "--id")) {
            index += 1;
            if (index >= operands.len) return historyUsageError(shell);
            value = operands[index];
        } else if (std.mem.startsWith(u8, operand, "--id=")) {
            value = operand["--id=".len..];
        } else {
            return historyUsageError(shell);
        }
        const id = std.fmt.parseInt(i64, value, 10) catch return historyUsageError(shell);
        const deleted = delete_id(command_history.context, id) catch return historyError(shell);
        if (!deleted) {
            const message = try std.fmt.allocPrint(
                shell.scratchAllocator(),
                "history: no entry with id {d}\n",
                .{id},
            );
            defer shell.scratchAllocator().free(message);
            try shell.host.writeAll(.stderr, message);
            failed = true;
        }
    }
    return .{ .status = @intFromBool(failed) };
}

fn historyUsageError(shell: anytype) !result.EvalResult {
    try shell.host.writeAll(
        .stderr,
        "history: usage: history [n] | list [n] | search text ... | delete --id n ... | clear\n",
    );
    return .{ .status = 2 };
}

fn historyUnavailable(shell: anytype) !result.EvalResult {
    try shell.host.writeAll(.stderr, "history: operation unavailable\n");
    return .{ .status = 1 };
}

fn historyError(shell: anytype) !result.EvalResult {
    try shell.host.writeAll(.stderr, "history: history error\n");
    return .{ .status = 1 };
}

fn fcUsageError(shell: anytype) !result.EvalResult {
    try shell.host.writeAll(.stderr, "fc: invalid option or operand\n");
    return .{ .status = 2 };
}

fn fcNoHistoryMatch(shell: anytype) !result.EvalResult {
    try shell.host.writeAll(.stderr, "fc: no command found\n");
    return .{ .status = 1 };
}

fn fcHistoryError(shell: anytype) !result.EvalResult {
    try shell.host.writeAll(.stderr, "fc: history error\n");
    return .{ .status = 1 };
}

fn fcEditorError(shell: anytype) !result.EvalResult {
    try shell.host.writeAll(.stderr, "fc: editor error\n");
    return .{ .status = 1 };
}

fn defaultUtilityPath() []const u8 {
    return "/bin:/usr/bin";
}
