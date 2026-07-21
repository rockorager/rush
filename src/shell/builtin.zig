//! Builtin command dispatch for the direct evaluator.

const std = @import("std");

const host = @import("../host.zig");
const history_mod = @import("../history.zig");
const builtin_history = @import("builtin_history.zig");
const output = @import("output.zig");
const printf = @import("printf.zig");
const result = @import("result.zig");
const state_mod = @import("state.zig");

pub const Kind = enum {
    special,
    regular,
};

pub const Origin = enum {
    core,
    extension,
};

pub const Id = enum {
    abbr,
    alias,
    bg,
    bracket,
    break_,
    cd,
    color,
    colon,
    dot,
    command,
    continue_,
    declare,
    echo,
    env,
    event,
    eval,
    exec,
    export_,
    exit,
    false_,
    fc,
    fg,
    getopts,
    hash,
    history,
    jobs,
    kill,
    local,
    prompt,
    prompt_duration,
    prompt_pwd,
    rush_complete,
    rush_env,
    printf,
    pwd,
    read,
    readonly,
    return_,
    set,
    shift,
    shopt,
    source,
    test_,
    times,
    trap,
    true_,
    typeset,
    type,
    ulimit,
    umask,
    unalias,
    unset,
    wait,
    z,
};

pub const Definition = struct {
    name: []const u8,
    id: Id,
    kind: Kind,
    origin: Origin = .core,

    pub fn validate(self: Definition) void {
        std.debug.assert(self.name.len != 0);
    }
};

const DefinitionMap = std.StaticStringMap(Definition);

pub const core_definitions: DefinitionMap = .initComptime(.{
    .{ "[", Definition{ .name = "[", .id = .bracket, .kind = .regular } },
    .{ "alias", Definition{ .name = "alias", .id = .alias, .kind = .regular } },
    .{ "bg", Definition{ .name = "bg", .id = .bg, .kind = .regular } },
    .{ "break", Definition{ .name = "break", .id = .break_, .kind = .special } },
    .{ "cd", Definition{ .name = "cd", .id = .cd, .kind = .regular } },
    .{ ":", Definition{ .name = ":", .id = .colon, .kind = .special } },
    .{ ".", Definition{ .name = ".", .id = .dot, .kind = .special } },
    .{ "command", Definition{ .name = "command", .id = .command, .kind = .regular } },
    .{ "continue", Definition{ .name = "continue", .id = .continue_, .kind = .special } },
    .{ "declare", Definition{ .name = "declare", .id = .declare, .kind = .regular } },
    .{ "echo", Definition{ .name = "echo", .id = .echo, .kind = .regular } },
    .{ "env", Definition{ .name = "env", .id = .env, .kind = .regular } },
    .{ "eval", Definition{ .name = "eval", .id = .eval, .kind = .special } },
    .{ "exec", Definition{ .name = "exec", .id = .exec, .kind = .special } },
    .{ "export", Definition{ .name = "export", .id = .export_, .kind = .special } },
    .{ "exit", Definition{ .name = "exit", .id = .exit, .kind = .special } },
    .{ "false", Definition{ .name = "false", .id = .false_, .kind = .regular } },
    .{ "fc", Definition{ .name = "fc", .id = .fc, .kind = .regular } },
    .{ "fg", Definition{ .name = "fg", .id = .fg, .kind = .regular } },
    .{ "getopts", Definition{ .name = "getopts", .id = .getopts, .kind = .regular } },
    .{ "hash", Definition{ .name = "hash", .id = .hash, .kind = .regular } },
    .{ "history", Definition{ .name = "history", .id = .history, .kind = .regular } },
    .{ "jobs", Definition{ .name = "jobs", .id = .jobs, .kind = .regular } },
    .{ "kill", Definition{ .name = "kill", .id = .kill, .kind = .regular } },
    .{ "local", Definition{ .name = "local", .id = .local, .kind = .regular } },
    .{ "printf", Definition{ .name = "printf", .id = .printf, .kind = .regular } },
    .{ "pwd", Definition{ .name = "pwd", .id = .pwd, .kind = .regular } },
    .{ "read", Definition{ .name = "read", .id = .read, .kind = .regular } },
    .{ "readonly", Definition{ .name = "readonly", .id = .readonly, .kind = .special } },
    .{ "return", Definition{ .name = "return", .id = .return_, .kind = .special } },
    .{ "set", Definition{ .name = "set", .id = .set, .kind = .special } },
    .{ "shift", Definition{ .name = "shift", .id = .shift, .kind = .special } },
    .{ "shopt", Definition{ .name = "shopt", .id = .shopt, .kind = .regular } },
    .{ "source", Definition{ .name = "source", .id = .source, .kind = .regular } },
    .{ "test", Definition{ .name = "test", .id = .test_, .kind = .regular } },
    .{ "times", Definition{ .name = "times", .id = .times, .kind = .special } },
    .{ "trap", Definition{ .name = "trap", .id = .trap, .kind = .special } },
    .{ "true", Definition{ .name = "true", .id = .true_, .kind = .regular } },
    .{ "typeset", Definition{ .name = "typeset", .id = .typeset, .kind = .regular } },
    .{ "type", Definition{ .name = "type", .id = .type, .kind = .regular } },
    .{ "ulimit", Definition{ .name = "ulimit", .id = .ulimit, .kind = .regular } },
    .{ "umask", Definition{ .name = "umask", .id = .umask, .kind = .regular } },
    .{ "unalias", Definition{ .name = "unalias", .id = .unalias, .kind = .regular } },
    .{ "unset", Definition{ .name = "unset", .id = .unset, .kind = .special } },
    .{ "wait", Definition{ .name = "wait", .id = .wait, .kind = .regular } },
    .{ "z", Definition{ .name = "z", .id = .z, .kind = .regular } },
});

pub const Registry = struct {
    extensions: []const Definition = &.{},
    ExtensionState: type = EmptyExtensionState,

    pub fn lookup(comptime self: Registry, name: []const u8) ?Definition {
        if (core_definitions.get(name)) |definition| {
            definition.validate();
            return definition;
        }
        inline for (self.extensions) |definition| {
            if (std.mem.eql(u8, definition.name, name)) {
                definition.validate();
                return definition;
            }
        }
        return null;
    }
};

pub const EmptyExtensionState = struct {
    pub fn init(_: std.mem.Allocator) EmptyExtensionState {
        return .{};
    }

    // ziglint-ignore: Z030 deinit intentionally leaves reusable/test-local state shape
    pub fn deinit(_: *EmptyExtensionState) void {}

    pub fn eval(
        _: *EmptyExtensionState,
        _: anytype,
        _: Definition,
        _: []const []const u8,
    ) !result.EvalResult {
        return .{ .status = 127 };
    }
};

pub const core_registry: Registry = .{};
pub const default_registry: Registry = core_registry;

pub fn extensionDefinition(comptime name: []const u8, comptime id: Id) Definition {
    return .{ .name = name, .id = id, .kind = .regular, .origin = .extension };
}

pub fn lookup(name: []const u8) ?Definition {
    return default_registry.lookup(name);
}

/// Rush-specific and bash-only builtins are hidden in POSIX mode.
pub fn availableInMode(definition: Definition, mode: state_mod.Mode) bool {
    if (mode != .posix) return true;
    return switch (definition.id) {
        .declare, .local, .source, .shopt, .typeset, .z, .history => false,
        else => true,
    };
}

pub fn eval(shell: anytype, definition: Definition, args: []const []const u8) !result.EvalResult {
    return (try tryEval(shell, definition, args)) orelse unreachable;
}

/// Evaluates builtins owned by this module and returns null for evaluator-owned builtins.
pub fn tryEval(shell: anytype, definition: Definition, args: []const []const u8) !?result.EvalResult {
    definition.validate();
    std.debug.assert(args.len != 0);
    if (definition.origin == .extension) return try evalExtension(shell, definition, args);
    const evaluated: result.EvalResult = switch (definition.id) {
        .colon, .true_ => .{},
        .alias => try evalAlias(shell, args),
        .bg => try evalBg(shell, args),
        .break_ => evalBreak(args),
        .bracket,
        .cd,
        .command,
        .declare,
        .dot,
        .eval,
        .exec,
        .export_,
        .pwd,
        .read,
        .source,
        .test_,
        .typeset,
        .type,
        .wait,
        => return null,
        .continue_ => evalContinue(args),
        .echo => try evalEcho(shell, args),
        .exit => evalExit(shell, args),
        .false_ => .{ .status = 1 },
        .fc => try builtin_history.evalFc(shell, args),
        .fg => try evalFg(shell, args),
        .getopts => try evalGetopts(shell, args),
        .hash => try evalHash(shell, args),
        .history => try builtin_history.evalHistory(shell, args),
        .jobs => try evalJobs(shell, args),
        .kill => try evalKill(shell, args),
        .local => try evalLocal(shell, args),
        .printf => try evalPrintf(shell, args),
        .readonly => try evalReadonly(shell, args),
        .return_ => evalReturn(shell, args),
        .set => try evalSet(shell, args),
        .shift => try evalShift(shell, args),
        .shopt => evalShopt(shell, args),
        .times => try evalTimes(shell, args),
        .trap => try evalTrap(shell, args),
        .ulimit => try evalUlimit(shell, args),
        .umask => try evalUmask(shell, args),
        .unalias => evalUnalias(shell, args),
        .unset => try evalUnset(shell, args),
        .abbr,
        .color,
        .env,
        .event,
        .prompt,
        .prompt_duration,
        .prompt_pwd,
        .rush_complete,
        .rush_env,
        .z,
        => return null,
    };
    return evaluated;
}

fn evalExtension(shell: anytype, definition: Definition, args: []const []const u8) !result.EvalResult {
    const ShellType = switch (@typeInfo(@TypeOf(shell))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell),
    };
    if (!@hasDecl(ShellType, "evalExtensionBuiltin")) return .{ .status = 127 };
    return shell.evalExtensionBuiltin(definition, args);
}

fn evalAlias(shell: anytype, args: []const []const u8) !result.EvalResult {
    var status: result.ExitStatus = 0;
    if (args.len == 1) {
        var iterator = shell.state.aliases.iterator();
        while (iterator.next()) |entry| try writeAlias(shell, entry.value_ptr.*);
        return .{};
    }

    for (args[1..]) |arg| {
        if (aliasAssignment(arg)) |assignment| {
            try shell.state.putAlias(.{ .name = assignment.name, .value = assignment.value });
        } else if (shell.state.getAlias(arg)) |alias| {
            try writeAlias(shell, alias);
        } else {
            try shell.host.writeAll(.stderr, "alias: use name=value to define an alias\n");
            status = 1;
        }
    }
    return .{ .status = status };
}

const AliasAssignment = struct {
    name: []const u8,
    value: []const u8,
};

fn aliasAssignment(arg: []const u8) ?AliasAssignment {
    const equal_index = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    const name = arg[0..equal_index];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return null;
    return .{ .name = name, .value = arg[equal_index + 1 ..] };
}

pub fn writeAlias(shell: anytype, alias: state_mod.Alias) !void {
    try shell.host.writeAll(.stdout, alias.name);
    try shell.host.writeAll(.stdout, "='");
    for (alias.value, 0..) |byte, index| {
        if (byte == '\'') {
            try shell.host.writeAll(.stdout, "'\\''");
        } else {
            try shell.host.writeAll(.stdout, alias.value[index..][0..1]);
        }
    }
    try shell.host.writeAll(.stdout, "'\n");
}

fn evalUnalias(shell: anytype, args: []const []const u8) result.EvalResult {
    var all = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            'a' => all = true,
            else => return .{ .status = 2 },
        };
    }

    if (all) {
        shell.state.clearAliases();
        return .{};
    }
    if (index >= args.len) return .{ .status = 2 };

    var status: result.ExitStatus = 0;
    for (args[index..]) |name| {
        if (!shell.state.removeAlias(name)) status = 1;
    }
    return .{ .status = status };
}

const ShoptOption = enum {
    expand_aliases,
    promptvars,
};

const shopt_option_names = std.StaticStringMap(ShoptOption).initComptime(.{
    .{ "expand_aliases", .expand_aliases },
    .{ "promptvars", .promptvars },
});

const shopt_option_order = [_]ShoptOption{
    .expand_aliases,
    .promptvars,
};

fn shoptOptionName(option: ShoptOption) []const u8 {
    return switch (option) {
        .expand_aliases => "expand_aliases",
        .promptvars => "promptvars",
    };
}

fn shoptOptionEnabled(shell: anytype, option: ShoptOption) bool {
    return switch (option) {
        .expand_aliases => shell.state.options.expand_aliases,
        .promptvars => shell.state.options.promptvars,
    };
}

fn setShoptOption(shell: anytype, option: ShoptOption, enabled: bool) void {
    switch (option) {
        .expand_aliases => shell.state.options.expand_aliases = enabled,
        .promptvars => shell.state.options.promptvars = enabled,
    }
}

fn evalShopt(shell: anytype, args: []const []const u8) result.EvalResult {
    var print_reusable = false;
    var query = false;
    var set_value: ?bool = null;
    var set_and_unset = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            'p' => print_reusable = true,
            'q' => query = true,
            's' => {
                if (set_value == false) set_and_unset = true;
                set_value = true;
            },
            'u' => {
                if (set_value == true) set_and_unset = true;
                set_value = false;
            },
            else => return .{ .status = 2 },
        };
    }

    if (set_and_unset) {
        shell.host.writeAll(.stderr, "shopt: cannot set and unset shell options simultaneously\n") catch {
            return .{ .status = 1 };
        };
        return .{ .status = 1 };
    }

    if (index >= args.len) return printShopt(shell, print_reusable, null, query, set_value);

    if (set_value == null) return printShopt(shell, print_reusable, args[index..], query, null);

    var status: result.ExitStatus = 0;
    for (args[index..]) |name| {
        const option = shopt_option_names.get(name) orelse {
            status = 1;
            if (!writeInvalidShoptOption(shell, name)) return .{ .status = 1 };
            continue;
        };
        setShoptOption(shell, option, set_value.?);
    }
    return .{ .status = status };
}

fn printShopt(
    shell: anytype,
    reusable: bool,
    names: ?[]const []const u8,
    query: bool,
    enabled_filter: ?bool,
) result.EvalResult {
    var status: result.ExitStatus = 0;
    if (names) |operands| {
        for (operands) |name| {
            const option = shopt_option_names.get(name) orelse {
                status = 1;
                if (!writeInvalidShoptOption(shell, name)) return .{ .status = 1 };
                continue;
            };
            if (!shoptOptionEnabled(shell, option)) status = 1;
            if (!query and !writeShoptOption(shell, option, reusable)) return .{ .status = 1 };
        }
    } else if (!query) {
        for (shopt_option_order) |option| {
            if (enabled_filter) |enabled| if (shoptOptionEnabled(shell, option) != enabled) continue;
            if (!writeShoptOption(shell, option, reusable)) return .{ .status = 1 };
        }
    }
    return .{ .status = status };
}

fn writeInvalidShoptOption(shell: anytype, name: []const u8) bool {
    shell.host.writeAll(.stderr, "shopt: ") catch return false;
    shell.host.writeAll(.stderr, name) catch return false;
    shell.host.writeAll(.stderr, ": invalid shell option name\n") catch return false;
    return true;
}

fn writeShoptOption(shell: anytype, option: ShoptOption, reusable: bool) bool {
    const name = shoptOptionName(option);
    const enabled = shoptOptionEnabled(shell, option);
    var buffer: [64]u8 = undefined;
    const text = if (reusable)
        std.fmt.bufPrint(&buffer, "shopt -{s} {s}\n", .{ if (enabled) "s" else "u", name }) catch unreachable
    else
        std.fmt.bufPrint(&buffer, "{s}\t{s}\n", .{ name, if (enabled) "on" else "off" }) catch unreachable;
    shell.host.writeAll(.stdout, text) catch return false;
    return true;
}

fn evalHash(shell: anytype, args: []const []const u8) !result.EvalResult {
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            'r' => shell.state.clearCommandHashes(),
            else => return .{ .status = 2 },
        };
    }

    if (index < args.len) {
        var status: result.ExitStatus = 0;
        for (args[index..]) |utility| {
            if (try findHashPath(shell, utility)) |path| {
                try shell.state.putCommandHash(.{ .name = utility, .path = path });
            } else {
                status = 1;
                try shell.host.writeAll(.stderr, "hash: ");
                try shell.host.writeAll(.stderr, utility);
                try shell.host.writeAll(.stderr, ": not found\n");
            }
        }
        return .{ .status = status };
    }

    var iterator = shell.state.command_hashes.iterator();
    while (iterator.next()) |entry| {
        try shell.host.writeAll(.stdout, entry.value_ptr.path);
        try shell.host.writeAll(.stdout, "\n");
    }
    return .{};
}

fn findHashPath(shell: anytype, utility: []const u8) !?[]const u8 {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (!@hasDecl(HostType, "isExecutableZ")) return null;

    const allocator = shell.scratchAllocator();
    if (std.mem.indexOfScalar(u8, utility, '/') != null) {
        const utility_z = try allocator.dupeZ(u8, utility);
        return if (shell.host.isExecutableZ(utility_z)) utility else null;
    }

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const path = if (shell.state.getVariable("PATH")) |variable| variable.value else shellEnvValue(shell, "PATH") orelse defaultUtilityPath();
    var candidate_buffer: std.ArrayList(u8) = .empty;
    var iterator = std.mem.splitScalar(u8, path, ':');
    while (iterator.next()) |directory| {
        candidate_buffer.clearRetainingCapacity();
        const prefix = if (directory.len == 0) "." else directory;
        try candidate_buffer.appendSlice(allocator, prefix);
        if (!std.mem.endsWith(u8, prefix, "/")) try candidate_buffer.append(allocator, '/');
        try candidate_buffer.appendSlice(allocator, utility);
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
    for (env) |entry_z| {
        const entry = std.mem.span(entry_z);
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) {
            return entry[name.len + 1 ..];
        }
    }
    return null;
}

fn shellEnvValue(shell: anytype, name: []const u8) ?[]const u8 {
    const ShellType = switch (@typeInfo(@TypeOf(shell))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell),
    };
    if (!@hasField(ShellType, "env")) return null;
    return envValue(shell.env, name);
}

fn evalGetopts(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len < 3) return .{ .status = 2 };
    const optstring = args[1];
    const name = args[2];
    if (!isAssignmentName(name)) return .{ .status = 2 };

    const operands = if (args.len > 3) args[3..] else shell.state.positionals;
    var optind = getoptsOptind(shell);
    if (optind == 0) optind = 1;
    const operand_index = optind - 1;
    if (operand_index >= operands.len) {
        try putGetoptsOptind(shell, optind);
        shell.state.getopts_char_index = 1;
        return .{ .status = 1 };
    }

    const operand = operands[operand_index];
    if (shell.state.getopts_char_index == 1) {
        if (!isGetoptsOptionOperand(operand)) return .{ .status = 1 };
        if (std.mem.eql(u8, operand, "--")) {
            try putGetoptsOptind(shell, optind + 1);
            return .{ .status = 1 };
        }
    }

    if (shell.state.getopts_char_index >= operand.len) {
        shell.state.getopts_char_index = 1;
        try putGetoptsOptind(shell, optind + 1);
        return .{ .status = 1 };
    }

    const option = operand[shell.state.getopts_char_index];
    // ziglint-ignore: Z011 deprecated API left unchanged to avoid semantic drift in lint-only pass
    const option_index = std.mem.indexOfScalar(u8, optstring, option);
    if (option_index == null or option == ':') {
        try shell.state.putVariable(.{ .name = name, .value = "?" });
        shell.state.removeVariable("OPTARG");
        try advanceGetopts(shell, optind, operand);
        return .{};
    }

    try shell.state.putVariable(.{ .name = name, .value = operand[shell.state.getopts_char_index..][0..1] });
    if (option_index.? + 1 < optstring.len and optstring[option_index.? + 1] == ':') {
        if (shell.state.getopts_char_index + 1 < operand.len) {
            try shell.state.putVariable(.{ .name = "OPTARG", .value = operand[shell.state.getopts_char_index + 1 ..] });
            shell.state.getopts_char_index = 1;
            try putGetoptsOptind(shell, optind + 1);
        } else if (operand_index + 1 < operands.len) {
            try shell.state.putVariable(.{ .name = "OPTARG", .value = operands[operand_index + 1] });
            shell.state.getopts_char_index = 1;
            try putGetoptsOptind(shell, optind + 2);
        } else {
            const option_text = operand[shell.state.getopts_char_index..][0..1];
            if (std.mem.startsWith(u8, optstring, ":")) {
                try shell.state.putVariable(.{ .name = name, .value = ":" });
                try shell.state.putVariable(.{ .name = "OPTARG", .value = option_text });
            } else {
                try shell.state.putVariable(.{ .name = name, .value = "?" });
                shell.state.removeVariable("OPTARG");
            }
            shell.state.getopts_char_index = 1;
            try putGetoptsOptind(shell, optind + 1);
        }
    } else {
        shell.state.removeVariable("OPTARG");
        try advanceGetopts(shell, optind, operand);
    }
    return .{};
}

fn getoptsOptind(shell: anytype) usize {
    const value = if (shell.state.getVariable("OPTIND")) |variable| variable.value else "1";
    return std.fmt.parseInt(usize, value, 10) catch 1;
}

fn putGetoptsOptind(shell: anytype, optind: usize) !void {
    const value = try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{optind});
    try shell.state.putVariable(.{ .name = "OPTIND", .value = value });
}

fn advanceGetopts(shell: anytype, optind: usize, operand: []const u8) !void {
    shell.state.getopts_char_index += 1;
    if (shell.state.getopts_char_index >= operand.len) {
        shell.state.getopts_char_index = 1;
        try putGetoptsOptind(shell, optind + 1);
    } else {
        try putGetoptsOptind(shell, optind);
    }
}

fn isGetoptsOptionOperand(operand: []const u8) bool {
    return operand.len >= 2 and operand[0] == '-' and !std.mem.eql(u8, operand, "-");
}

fn evalKill(shell: anytype, args: []const []const u8) !result.EvalResult {
    var kill_signal: KillSignal = .{ .name = "TERM", .number = signalNumber("TERM").? };
    var index: usize = 1;
    if (index < args.len and std.mem.eql(u8, args[index], "-l")) return evalKillList(shell, args[index + 1 ..]);
    if (index < args.len and std.mem.eql(u8, args[index], "-s")) {
        index += 1;
        if (index >= args.len) return .{ .status = 2 };
        kill_signal = parseKillSignal(args[index]) orelse return .{ .status = 2 };
        index += 1;
    } else if (index < args.len and args[index].len > 1 and args[index][0] == '-') {
        kill_signal = parseKillSignal(args[index][1..]) orelse return .{ .status = 2 };
        index += 1;
    }
    if (index >= args.len) return .{ .status = 2 };

    var status: result.ExitStatus = 0;
    while (index < args.len) : (index += 1) {
        if (killOperandJob(shell, args[index])) |job| {
            const target = if (job.job_control) -job.process_group else job.pid;
            shell.host.sendSignal(target, kill_signal.number) catch {
                status = 1;
                continue;
            };
            continue;
        }
        const pid = killOperandPid(shell, args[index]) orelse {
            status = 1;
            continue;
        };
        if (kill_signal.name) |signal_name| {
            if (pid == shell.host.currentProcessId() and shell.state.getSignalTrap(signal_name) != null) {
                try shell.state.queueTrap(signal_name);
                continue;
            }
        }
        shell.host.sendSignal(pid, kill_signal.number) catch {
            status = 1;
            continue;
        };
    }
    return .{ .status = status };
}

fn killOperandPid(shell: anytype, arg: []const u8) ?host.Pid {
    _ = shell;
    if (arg.len >= 1 and arg[0] == '%') return null;
    return std.fmt.parseInt(host.Pid, arg, 10) catch null;
}

fn killOperandJob(shell: anytype, arg: []const u8) ?state_mod.BackgroundJob {
    return jobOperand(shell, arg);
}

fn evalJobs(shell: anytype, args: []const []const u8) !result.EvalResult {
    var format: JobFormat = .default;
    var first_operand: usize = 1;
    while (first_operand < args.len) : (first_operand += 1) {
        const arg = args[first_operand];
        if (std.mem.eql(u8, arg, "-l")) {
            if (format != .default) return .{ .status = 2 };
            format = .long;
        } else if (std.mem.eql(u8, arg, "-p")) {
            if (format != .default) return .{ .status = 2 };
            format = .pid;
        } else break;
    }

    if (first_operand == args.len) {
        for (shell.state.background_jobs.items) |job| try writeJob(shell, job, format);
        return .{};
    }

    var status: result.ExitStatus = 0;
    for (args[first_operand..]) |arg| {
        const job = jobOperand(shell, arg) orelse {
            try shell.host.writeAll(.stderr, "jobs: no such job\n");
            status = 1;
            continue;
        };
        try writeJob(shell, job, format);
    }
    return .{ .status = status };
}

const JobFormat = enum { default, long, pid };

fn writeJob(shell: anytype, job: state_mod.BackgroundJob, format: JobFormat) !void {
    const status_text = jobStatusText(job.status);
    const marker = shell.state.backgroundJobMarker(job.id);
    const text = switch (format) {
        .default => try std.fmt.allocPrint(
            shell.scratchAllocator(),
            "[{}] {c} {s} {s}\n",
            .{ job.id, marker, status_text, job.command },
        ),
        .long => try std.fmt.allocPrint(
            shell.scratchAllocator(),
            "[{}] {c} {} {s} {s}\n",
            .{ job.id, marker, job.pid, status_text, job.command },
        ),
        .pid => try std.fmt.allocPrint(
            shell.scratchAllocator(),
            "{}\n",
            .{if (job.job_control) job.process_group else job.pid},
        ),
    };
    defer shell.scratchAllocator().free(text);
    try shell.host.writeAll(.stdout, text);
}

fn jobStatusText(status: state_mod.JobStatus) []const u8 {
    return switch (status) {
        .running => "Running",
        .stopped => "Stopped",
    };
}

fn jobOperand(shell: anytype, arg: []const u8) ?state_mod.BackgroundJob {
    return shell.state.resolveJobSpec(arg);
}

fn jobOperandOrCurrent(shell: anytype, arg: ?[]const u8) ?state_mod.BackgroundJob {
    if (arg) |job_spec| {
        return jobOperand(shell, job_spec);
    }
    return shell.state.currentBackgroundJob();
}

fn writeNoSuchJob(shell: anytype, builtin_name: []const u8) !void {
    try shell.host.writeAll(
        .stderr,
        try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: no such job\n", .{builtin_name}),
    );
}

fn writeNoCurrentJob(shell: anytype, builtin_name: []const u8) !void {
    try shell.host.writeAll(
        .stderr,
        try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: no current job\n", .{builtin_name}),
    );
}

fn resumeBackgroundJob(shell: anytype, job: state_mod.BackgroundJob) !result.EvalResult {
    sendContinueToJob(shell, job) catch return .{ .status = 1 };
    _ = shell.state.setBackgroundJobStatus(job.id, .running);
    const text = try std.fmt.allocPrint(shell.scratchAllocator(), "[{}] {s}\n", .{ job.id, job.command });
    defer shell.scratchAllocator().free(text);
    try shell.host.writeAll(.stdout, text);
    return .{};
}

fn foregroundJob(shell: anytype, job: state_mod.BackgroundJob) !result.EvalResult {
    const text = try std.fmt.allocPrint(shell.scratchAllocator(), "{s}\n", .{job.command});
    defer shell.scratchAllocator().free(text);
    try shell.host.writeAll(.stdout, text);
    const foreground_restore_group = giveTerminalToJob(shell, job.process_group) catch return .{ .status = 1 };
    defer if (foreground_restore_group) |process_group| restoreTerminalToShell(shell, process_group);
    sendContinueToJob(shell, job) catch return .{ .status = 1 };
    _ = shell.state.setBackgroundJobStatus(job.id, .running);
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (!@hasDecl(HostType, "waitInterruptible")) return .{ .status = 1 };
    const pids = try shell.scratchAllocator().dupe(host.Pid, job.pids.items);
    defer shell.scratchAllocator().free(pids);
    var status: result.ExitStatus = 0;
    for (pids) |pid| {
        const waited = waitForegroundJobPid(shell, pid) catch return .{ .status = 127 };
        status = waited.shellStatus();
        switch (waited) {
            .stopped => {
                _ = shell.state.setBackgroundJobStatusByPid(pid, .stopped);
                return .{ .status = status };
            },
            else => {},
        }
        _ = shell.state.removeBackgroundPid(pid);
    }
    return .{ .status = status };
}

fn waitForegroundJobPid(shell: anytype, pid: host.Pid) !host.WaitStatus {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (@hasDecl(HostType, "waitJobEventInterruptible")) return shell.host.waitJobEventInterruptible(pid);
    return shell.host.waitInterruptible(pid);
}

fn giveTerminalToJob(shell: anytype, process_group: host.Pid) !?host.Pid {
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

fn restoreTerminalToShell(shell: anytype, process_group: host.Pid) void {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (!@hasDecl(HostType, "setTerminalProcessGroup")) return;
    // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
    shell.host.setTerminalProcessGroup(shell.state.controlling_tty orelse .stdin, process_group) catch {};
}

fn sendContinueToJob(shell: anytype, job: state_mod.BackgroundJob) !void {
    const cont = signalNumber("CONT") orelse return error.InvalidSignal;
    if (shell.state.options.monitor) {
        try shell.host.sendSignal(-job.process_group, cont);
        return;
    }
    var failed = false;
    for (job.pids.items) |pid| {
        shell.host.sendSignal(pid, cont) catch {
            failed = true;
        };
    }
    if (failed) return error.SignalFailed;
}

fn evalBg(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (!shell.state.options.monitor) {
        try shell.host.writeAll(.stderr, "bg: job control disabled\n");
        return .{ .status = 1 };
    }
    if (args.len == 1) {
        const job = shell.state.currentBackgroundJob() orelse {
            try writeNoCurrentJob(shell, "bg");
            return .{ .status = 1 };
        };
        return resumeBackgroundJob(shell, job);
    }

    var status: result.ExitStatus = 0;
    for (args[1..]) |arg| {
        const job = jobOperandOrCurrent(shell, arg) orelse {
            try writeNoSuchJob(shell, "bg");
            status = 1;
            continue;
        };
        const evaluated = try resumeBackgroundJob(shell, job);
        if (evaluated.status != 0) status = evaluated.status;
    }
    return .{ .status = status };
}

fn evalFg(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len > 2) return .{ .status = 2 };
    if (!shell.state.options.monitor) {
        try shell.host.writeAll(.stderr, "fg: job control disabled\n");
        return .{ .status = 1 };
    }
    const job = jobOperandOrCurrent(shell, if (args.len == 2) args[1] else null) orelse {
        if (args.len == 2) {
            try writeNoSuchJob(shell, "fg");
        } else {
            try writeNoCurrentJob(shell, "fg");
        }
        return .{ .status = 1 };
    };
    return foregroundJob(shell, job);
}

fn evalKillList(shell: anytype, operands: []const []const u8) !result.EvalResult {
    if (operands.len == 0) {
        for (trap_signal_names, 0..) |name, index| {
            if (index != 0) try shell.host.writeAll(.stdout, " ");
            try shell.host.writeAll(.stdout, name);
        }
        try shell.host.writeAll(.stdout, "\n");
        return .{};
    }
    if (operands.len != 1) return .{ .status = 2 };
    const raw_number = std.fmt.parseInt(u8, operands[0], 10) catch return .{ .status = 2 };
    const number = if (raw_number > 128) raw_number - 128 else raw_number;
    const name = signalNameFromNumber(number) orelse return .{ .status = 2 };
    try shell.host.writeAll(.stdout, name);
    try shell.host.writeAll(.stdout, "\n");
    return .{};
}

const UlimitResource = struct {
    option: u8,
    kind: host.ResourceLimitKind,
    units: u64,
    label: []const u8,
};

const ulimit_resources = [_]UlimitResource{
    .{ .option = 'c', .kind = .core, .units = 512, .label = "core file size" },
    .{ .option = 'd', .kind = .data, .units = 1024, .label = "data seg size" },
    .{ .option = 'f', .kind = .file_size, .units = 512, .label = "file size" },
    .{ .option = 'n', .kind = .open_files, .units = 1, .label = "open files" },
    .{ .option = 's', .kind = .stack, .units = 1024, .label = "stack size" },
    .{ .option = 't', .kind = .cpu_time, .units = 1, .label = "cpu time" },
    .{ .option = 'v', .kind = .address_space, .units = 1024, .label = "address space" },
};

const UlimitSelection = enum {
    soft,
    hard,
    both,
};

fn evalUlimit(shell: anytype, args: []const []const u8) !result.EvalResult {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (!@hasDecl(HostType, "getResourceLimit") or !@hasDecl(HostType, "setResourceLimit")) {
        try shell.host.writeAll(.stderr, "ulimit: resource limits unavailable\n");
        return .{ .status = 2 };
    }

    var selection: UlimitSelection = .soft;
    var resource: ?UlimitResource = null;
    var all = false;
    var index: usize = 1;
    while (index < args.len and isUlimitOption(args[index])) : (index += 1) {
        const arg = args[index];
        for (arg[1..]) |option| switch (option) {
            'H' => selection = .hard,
            'S' => selection = .soft,
            'a' => all = true,
            else => resource = ulimitResource(option) orelse return ulimitUsageError(shell),
        };
    }

    if (all and index < args.len) return ulimitUsageError(shell);
    if (all) return printAllResourceLimits(shell, selection);

    const selected_resource = resource orelse ulimitResource('f').?;
    if (index == args.len) return printResourceLimit(shell, selected_resource, selection, false);
    if (index + 1 != args.len) return ulimitUsageError(shell);

    const native_value = parseUlimitValue(args[index], selected_resource.units) catch return ulimitUsageError(shell);
    const current = shell.host.getResourceLimit(selected_resource.kind) catch return ulimitResourceError(shell);
    const new_limit: host.ResourceLimit = switch (selection) {
        .soft => .{ .soft = native_value, .hard = current.hard },
        .hard => .{ .soft = current.soft, .hard = native_value },
        .both => unreachable,
    };

    const set_both = !sawHardOrSoft(args[1..index]);
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const effective_limit: host.ResourceLimit = if (set_both) .{ .soft = native_value, .hard = native_value } else new_limit;
    shell.host.setResourceLimit(selected_resource.kind, effective_limit) catch return ulimitResourceError(shell);
    return .{};
}

fn isUlimitOption(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

fn sawHardOrSoft(args: []const []const u8) bool {
    for (args) |arg| {
        if (!isUlimitOption(arg)) return false;
        for (arg[1..]) |option| if (option == 'H' or option == 'S') return true;
    }
    return false;
}

fn ulimitResource(option: u8) ?UlimitResource {
    for (ulimit_resources) |resource| if (resource.option == option) return resource;
    return null;
}

const ParseUlimitValueError = error{Invalid};

fn parseUlimitValue(text: []const u8, units: u64) ParseUlimitValueError!?u64 {
    if (std.mem.eql(u8, text, "unlimited")) return null;
    const value = std.fmt.parseInt(u64, text, 10) catch return error.Invalid;
    return std.math.mul(u64, value, units) catch error.Invalid;
}

fn printAllResourceLimits(shell: anytype, selection: UlimitSelection) !result.EvalResult {
    for (ulimit_resources) |resource| {
        const limit = shell.host.getResourceLimit(resource.kind) catch return ulimitResourceError(shell);
        try shell.host.writeAll(.stdout, resource.label);
        try shell.host.writeAll(.stdout, " ");
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try shell.host.writeAll(.stdout, try std.fmt.allocPrint(shell.scratchAllocator(), "(-{c}) ", .{resource.option}));
        try writeUlimitValue(shell, selectedLimitValue(limit, selection), resource.units);
    }
    return .{};
}

fn printResourceLimit(
    shell: anytype,
    resource: UlimitResource,
    selection: UlimitSelection,
    _: bool,
) !result.EvalResult {
    const limit = shell.host.getResourceLimit(resource.kind) catch return ulimitResourceError(shell);
    try writeUlimitValue(shell, selectedLimitValue(limit, selection), resource.units);
    return .{};
}

fn selectedLimitValue(limit: host.ResourceLimit, selection: UlimitSelection) ?u64 {
    return switch (selection) {
        .soft => limit.soft,
        .hard => limit.hard,
        .both => unreachable,
    };
}

fn writeUlimitValue(shell: anytype, value: ?u64, units: u64) !void {
    if (value) |native_value| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try shell.host.writeAll(.stdout, try std.fmt.allocPrint(shell.scratchAllocator(), "{}\n", .{native_value / units}));
    } else {
        try shell.host.writeAll(.stdout, "unlimited\n");
    }
}

fn ulimitUsageError(shell: anytype) !result.EvalResult {
    try shell.host.writeAll(.stderr, "ulimit: invalid option or operand\n");
    return .{ .status = 2 };
}

fn ulimitResourceError(shell: anytype) !result.EvalResult {
    try shell.host.writeAll(.stderr, "ulimit: resource limit error\n");
    return .{ .status = 1 };
}

fn evalUmask(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len > 2) return .{ .status = 2 };
    const current = currentUmask(shell);
    if (args.len == 1) {
        try shell.host.writeAll(.stdout, try std.fmt.allocPrint(shell.scratchAllocator(), "{o:0>4}\n", .{current}));
        return .{};
    }
    if (std.mem.eql(u8, args[1], "-S")) {
        try shell.host.writeAll(.stdout, try symbolicUmask(shell, current));
        return .{};
    }

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const new_mask = parseOctalUmask(args[1]) orelse parseSymbolicUmask(current, args[1]) orelse return .{ .status = 2 };
    _ = shell.host.setFileCreationMask(new_mask);
    return .{};
}

fn currentUmask(shell: anytype) u32 {
    const current = shell.host.setFileCreationMask(0);
    _ = shell.host.setFileCreationMask(current);
    return current & 0o777;
}

fn parseOctalUmask(text: []const u8) ?u32 {
    if (text.len == 0) return null;
    var value: u32 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '7') return null;
        value = value * 8 + byte - '0';
        if (value > 0o777) return null;
    }
    return value;
}

fn symbolicUmask(shell: anytype, mask: u32) ![]const u8 {
    const allowed = (~mask) & 0o777;
    return std.fmt.allocPrint(
        shell.scratchAllocator(),
        "u={s}{s}{s},g={s}{s}{s},o={s}{s}{s}\n",
        .{
            if ((allowed & 0o400) != 0) "r" else "",
            if ((allowed & 0o200) != 0) "w" else "",
            if ((allowed & 0o100) != 0) "x" else "",
            if ((allowed & 0o040) != 0) "r" else "",
            if ((allowed & 0o020) != 0) "w" else "",
            if ((allowed & 0o010) != 0) "x" else "",
            if ((allowed & 0o004) != 0) "r" else "",
            if ((allowed & 0o002) != 0) "w" else "",
            if ((allowed & 0o001) != 0) "x" else "",
        },
    );
}

fn parseSymbolicUmask(current: u32, text: []const u8) ?u32 {
    var mask = current & 0o777;
    var iterator = std.mem.splitScalar(u8, text, ',');
    while (iterator.next()) |clause| {
        if (clause.len == 0) return null;
        mask = applyUmaskClause(mask, clause) orelse return null;
    }
    return mask;
}

fn applyUmaskClause(current: u32, clause: []const u8) ?u32 {
    var index: usize = 0;
    var who_mask: u32 = 0;
    while (index < clause.len) : (index += 1) switch (clause[index]) {
        'u' => who_mask |= 0o700,
        'g' => who_mask |= 0o070,
        'o' => who_mask |= 0o007,
        'a' => who_mask |= 0o777,
        '+', '-', '=' => break,
        else => return null,
    };
    if (who_mask == 0) who_mask = 0o777;
    if (index >= clause.len) return null;
    const op = clause[index];
    index += 1;

    var permissions: u32 = 0;
    while (index < clause.len) : (index += 1) switch (clause[index]) {
        'r' => permissions |= permissionsForWho(who_mask, 0o444),
        'w' => permissions |= permissionsForWho(who_mask, 0o222),
        'x' => permissions |= permissionsForWho(who_mask, 0o111),
        else => return null,
    };

    const updated: u32 = switch (op) {
        '+' => current & ~permissions,
        '-' => current | permissions,
        '=' => (current & ~who_mask) | (who_mask & ~permissions),
        else => unreachable,
    };
    return updated & 0o777;
}

fn permissionsForWho(who_mask: u32, permissions: u32) u32 {
    return who_mask & permissions;
}

fn evalExit(shell: anytype, args: []const []const u8) result.EvalResult {
    const status = if (args.len > 1) parseExitStatus(args[1]) else shell.state.last_status;
    return .{ .status = status, .flow = .{ .exit = status } };
}

fn evalReturn(shell: anytype, args: []const []const u8) result.EvalResult {
    if (args.len > 2) return .{ .status = 2 };
    const status = if (args.len > 1) parseExitStatus(args[1]) else shell.state.last_status;
    return .{ .status = status, .flow = .{ .return_ = status } };
}

fn parseExitStatus(text: []const u8) result.ExitStatus {
    const value = std.fmt.parseInt(u64, text, 10) catch return 2;
    return @truncate(value);
}

fn evalShift(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len > 2) return .{ .status = 2 };
    const count = if (args.len == 1) 1 else std.fmt.parseInt(usize, args[1], 10) catch return .{ .status = 2 };
    if (count > shell.state.positionals.len) return .{ .status = 1 };
    try shell.state.setPositionals(shell.state.positionals[count..]);
    return .{};
}

fn evalTimes(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len != 1) return .{ .status = 2 };
    shell.host.writeAll(.stdout, "0m0.000s 0m0.000s\n0m0.000s 0m0.000s\n") catch {
        try shell.host.writeAll(.stderr, "times: write failed\n");
        return .{ .status = 1 };
    };
    return .{};
}

fn evalEcho(shell: anytype, args: []const []const u8) !result.EvalResult {
    var newline = true;
    var escapes = false;
    var first_operand: usize = 1;

    while (first_operand < args.len) : (first_operand += 1) {
        const option = parseEchoOption(args[first_operand]) orelse break;
        if (option.suppress_newline) newline = false;
        if (option.escapes) |enabled| escapes = enabled;
    }

    for (args[first_operand..], 0..) |arg, index| {
        if (index != 0) shell.host.writeAll(.stdout, " ") catch return echoWriteFailed(shell);
        if (escapes) {
            const complete = writeEchoEscaped(shell, arg) catch return echoWriteFailed(shell);
            if (!complete) return .{};
        } else {
            shell.host.writeAll(.stdout, arg) catch return echoWriteFailed(shell);
        }
    }
    if (newline) shell.host.writeAll(.stdout, "\n") catch return echoWriteFailed(shell);
    return .{};
}

const EchoOption = struct {
    suppress_newline: bool = false,
    escapes: ?bool = null,
};

fn parseEchoOption(arg: []const u8) ?EchoOption {
    if (arg.len < 2 or arg[0] != '-') return null;

    var option: EchoOption = .{};
    for (arg[1..]) |byte| {
        switch (byte) {
            'n' => option.suppress_newline = true,
            'e' => option.escapes = true,
            'E' => option.escapes = false,
            else => return null,
        }
    }
    return option;
}

fn writeEchoEscaped(shell: anytype, text: []const u8) !bool {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '\\') {
            try shell.host.writeAll(.stdout, text[index .. index + 1]);
            index += 1;
            continue;
        }

        index += 1;
        if (index >= text.len) {
            try shell.host.writeAll(.stdout, "\\");
            return true;
        }
        if (!try writeEchoEscape(shell, text, &index)) return false;
    }
    return true;
}

fn writeEchoEscape(shell: anytype, text: []const u8, index: *usize) !bool {
    switch (text[index.*]) {
        'a' => try shell.host.writeAll(.stdout, "\x07"),
        'b' => try shell.host.writeAll(.stdout, "\x08"),
        'c' => {
            index.* += 1;
            return false;
        },
        'e', 'E' => try shell.host.writeAll(.stdout, "\x1b"),
        'f' => try shell.host.writeAll(.stdout, "\x0c"),
        'n' => try shell.host.writeAll(.stdout, "\n"),
        'r' => try shell.host.writeAll(.stdout, "\r"),
        't' => try shell.host.writeAll(.stdout, "\t"),
        'v' => try shell.host.writeAll(.stdout, "\x0b"),
        '\\' => try shell.host.writeAll(.stdout, "\\"),
        '0' => try writeEchoOctalEscape(shell, text, index),
        'x' => try writeEchoHexByteEscape(shell, text, index),
        'u' => try writeEchoUnicodeEscape(shell, text, index, 4),
        'U' => try writeEchoUnicodeEscape(shell, text, index, 8),
        else => {
            try shell.host.writeAll(.stdout, "\\");
            try shell.host.writeAll(.stdout, text[index.* .. index.* + 1]);
            index.* += 1;
            return true;
        },
    }
    index.* += 1;
    return true;
}

fn writeEchoOctalEscape(shell: anytype, text: []const u8, index: *usize) !void {
    var value: u16 = 0;
    var count: usize = 0;
    var cursor = index.* + 1;
    while (cursor < text.len and count < 3 and text[cursor] >= '0' and text[cursor] <= '7') : (count += 1) {
        value = value * 8 + (text[cursor] - '0');
        cursor += 1;
    }
    try writeEchoByte(shell, @intCast(value & 0xff));
    index.* = cursor - 1;
}

fn writeEchoHexByteEscape(shell: anytype, text: []const u8, index: *usize) !void {
    const start = index.*;
    var value: u8 = 0;
    var count: usize = 0;
    var cursor = start + 1;
    while (cursor < text.len and count < 2) : (count += 1) {
        const digit = std.fmt.charToDigit(text[cursor], 16) catch break;
        value = value * 16 + digit;
        cursor += 1;
    }
    if (count == 0) {
        try shell.host.writeAll(.stdout, "\\x");
        index.* = start + 1;
    } else {
        try writeEchoByte(shell, value);
        index.* = cursor - 1;
    }
}

fn writeEchoUnicodeEscape(shell: anytype, text: []const u8, index: *usize, max_digits: usize) !void {
    std.debug.assert(max_digits == 4 or max_digits == 8);

    const start = index.*;
    var value: u32 = 0;
    var count: usize = 0;
    var cursor = start + 1;
    while (cursor < text.len and count < max_digits) : (count += 1) {
        const digit = std.fmt.charToDigit(text[cursor], 16) catch break;
        value = value * 16 + digit;
        cursor += 1;
    }
    if (count == 0) {
        try shell.host.writeAll(.stdout, text[start - 1 .. start + 1]);
        index.* = start + 1;
    } else {
        try writeEchoUtf8(shell, value);
        index.* = cursor - 1;
    }
}

fn writeEchoUtf8(shell: anytype, value: u32) !void {
    if (value <= 0x7f) return writeEchoByte(shell, @intCast(value));

    var buffer: [6]u8 = undefined;
    const len: usize = if (value <= 0x7ff) len: {
        buffer[0] = 0xc0 | @as(u8, @intCast(value >> 6));
        buffer[1] = 0x80 | @as(u8, @intCast(value & 0x3f));
        break :len 2;
    } else if (value <= 0xffff) len: {
        buffer[0] = 0xe0 | @as(u8, @intCast(value >> 12));
        buffer[1] = 0x80 | @as(u8, @intCast((value >> 6) & 0x3f));
        buffer[2] = 0x80 | @as(u8, @intCast(value & 0x3f));
        break :len 3;
    } else if (value <= 0x1fffff) len: {
        buffer[0] = 0xf0 | @as(u8, @intCast(value >> 18));
        buffer[1] = 0x80 | @as(u8, @intCast((value >> 12) & 0x3f));
        buffer[2] = 0x80 | @as(u8, @intCast((value >> 6) & 0x3f));
        buffer[3] = 0x80 | @as(u8, @intCast(value & 0x3f));
        break :len 4;
    } else if (value <= 0x3ffffff) len: {
        buffer[0] = 0xf8 | @as(u8, @intCast(value >> 24));
        buffer[1] = 0x80 | @as(u8, @intCast((value >> 18) & 0x3f));
        buffer[2] = 0x80 | @as(u8, @intCast((value >> 12) & 0x3f));
        buffer[3] = 0x80 | @as(u8, @intCast((value >> 6) & 0x3f));
        buffer[4] = 0x80 | @as(u8, @intCast(value & 0x3f));
        break :len 5;
    } else if (value <= 0x7fffffff) len: {
        buffer[0] = 0xfc | @as(u8, @intCast(value >> 30));
        buffer[1] = 0x80 | @as(u8, @intCast((value >> 24) & 0x3f));
        buffer[2] = 0x80 | @as(u8, @intCast((value >> 18) & 0x3f));
        buffer[3] = 0x80 | @as(u8, @intCast((value >> 12) & 0x3f));
        buffer[4] = 0x80 | @as(u8, @intCast((value >> 6) & 0x3f));
        buffer[5] = 0x80 | @as(u8, @intCast(value & 0x3f));
        break :len 6;
    } else return;
    try shell.host.writeAll(.stdout, buffer[0..len]);
}

fn writeEchoByte(shell: anytype, byte: u8) !void {
    const buffer = [1]u8{byte};
    try shell.host.writeAll(.stdout, &buffer);
}

fn echoWriteFailed(shell: anytype) result.EvalResult {
    // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
    shell.host.writeAll(.stderr, "echo: write failed\n") catch {};
    return .{ .status = 1 };
}

fn evalBreak(args: []const []const u8) result.EvalResult {
    const count = parseLoopControlCount(args) orelse return .{ .status = 2 };
    return .{ .flow = .{ .break_ = count } };
}

fn evalContinue(args: []const []const u8) result.EvalResult {
    const count = parseLoopControlCount(args) orelse return .{ .status = 2 };
    return .{ .flow = .{ .continue_ = count } };
}

fn parseLoopControlCount(args: []const []const u8) ?usize {
    if (args.len > 2) return null;
    if (args.len == 1) return 1;
    const count = std.fmt.parseInt(usize, args[1], 10) catch return null;
    return if (count == 0) null else count;
}

fn evalPrintf(shell: anytype, args: []const []const u8) !result.EvalResult {
    const HostWriter = output.HostWriter(@TypeOf(shell.host));
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = HostWriter.init(&shell.host, .stdout, &stdout_buffer);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = HostWriter.init(&shell.host, .stderr, &stderr_buffer);

    const status = printf.evaluate(
        shell.scratchAllocator(),
        args,
        &stdout.interface,
        &stderr.interface,
    ) catch |err| switch (err) {
        error.WriteFailed => return .{ .status = 1 },
        else => return err,
    };
    stdout.interface.flush() catch return .{ .status = 1 };
    stderr.interface.flush() catch return .{ .status = 1 };
    return .{ .status = status };
}

fn evalLocal(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (!shell.state.hasLocalFrame()) {
        try shell.host.writeAll(.stderr, "local: can only be used in a function\n");
        return .{ .status = 1 };
    }

    var exported = false;
    var readonly = false;
    var first_operand: usize = 1;
    while (first_operand < args.len) : (first_operand += 1) {
        const arg = args[first_operand];
        if (std.mem.eql(u8, arg, "--")) {
            first_operand += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            'r' => readonly = true,
            'x' => exported = true,
            else => return .{ .status = 2 },
        };
    }

    var status: result.ExitStatus = 0;
    for (args[first_operand..]) |arg| {
        // ziglint-ignore: Z011 deprecated API left unchanged to avoid semantic drift in lint-only pass
        const equal_index = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (equal_index) |index| arg[0..index] else arg;
        if (!isAssignmentName(name)) {
            try shell.host.writeAll(
                .stderr,
                try std.fmt.allocPrint(shell.scratchAllocator(), "local: `{s}': not a valid identifier\n", .{arg}),
            );
            status = 1;
            continue;
        }
        const value = if (equal_index) |index| arg[index + 1 ..] else null;
        shell.state.declareLocalWithAttributes(.{
            .name = name,
            .value = value,
            .exported = exported,
            .readonly = readonly,
        }) catch |err| switch (err) {
            error.ReadonlyVariable => {
                try shell.host.writeAll(
                    .stderr,
                    try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: readonly variable\n", .{name}),
                );
                status = 1;
            },
            else => return err,
        };
    }
    return .{ .status = status };
}

fn evalReadonly(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len == 1) return .{};
    for (args[1..]) |arg| {
        // ziglint-ignore: Z011 deprecated API left unchanged to avoid semantic drift in lint-only pass
        const equal_index = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (equal_index) |index| arg[0..index] else arg;
        if (!isAssignmentName(name)) return .{ .status = 2 };
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        const value = if (equal_index) |index| arg[index + 1 ..] else if (shell.state.getVariable(name)) |variable| variable.value else "";
        try shell.state.putVariable(.{ .name = name, .value = value, .readonly = true });
    }
    return .{};
}

fn evalSet(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len == 1) return listSetVariables(shell);
    if (std.mem.eql(u8, args[1], "--")) {
        try shell.state.setPositionals(args[2..]);
        return .{};
    }
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            try shell.state.setPositionals(args[index + 1 ..]);
            return .{};
        }
        if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) {
            try shell.state.setPositionals(args[index..]);
            return .{};
        }
        const enabled = arg[0] == '-';
        if (std.mem.eql(u8, arg[1..], "o")) {
            index += 1;
            if (index >= args.len) return listSetOptions(shell, enabled);
            if (!setNamedOption(shell, args[index], enabled)) return setUsageError(shell);
            continue;
        }
        for (arg[1..]) |option| switch (option) {
            'a' => shell.state.options.allexport = enabled,
            'b' => shell.state.options.notify = enabled,
            'C' => shell.state.options.noclobber = enabled,
            'e' => shell.state.options.errexit = enabled,
            'f' => shell.state.options.noglob = enabled,
            'h' => shell.state.options.hashall = enabled,
            'm' => shell.state.options.monitor = enabled,
            'n' => shell.state.options.noexec = enabled,
            'o' => {
                index += 1;
                if (index >= args.len) return listSetOptions(shell, enabled);
                if (!setNamedOption(shell, args[index], enabled)) return setUsageError(shell);
            },
            'u' => shell.state.options.nounset = enabled,
            'v' => shell.state.options.verbose = enabled,
            'x' => shell.state.options.xtrace = enabled,
            else => return setUsageError(shell),
        };
    }
    return .{};
}

fn listSetVariables(shell: anytype) !result.EvalResult {
    const allocator = shell.scratchAllocator();
    var variables: std.ArrayList(state_mod.Variable) = .empty;
    var iterator = shell.state.bindings.iterator();
    while (iterator.next()) |entry| {
        const variable = entry.value_ptr.variable() orelse continue;
        try variables.append(allocator, variable);
    }

    std.mem.sort(state_mod.Variable, variables.items, {}, variableLessThan);
    for (variables.items) |variable| {
        try shell.host.writeAll(.stdout, try std.fmt.allocPrint(
            allocator,
            "{s}={s}\n",
            .{ variable.name, variable.value },
        ));
    }
    return .{};
}

fn variableLessThan(_: void, lhs: state_mod.Variable, rhs: state_mod.Variable) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

const SetOption = enum {
    allexport,
    emacs,
    errexit,
    hashall,
    history,
    monitor,
    noclobber,
    noexec,
    noglob,
    notify,
    nounset,
    pipefail,
    vi,
    verbose,
    xtrace,
};

const set_option_names = std.StaticStringMap(SetOption).initComptime(.{
    .{ "allexport", .allexport },
    .{ "emacs", .emacs },
    .{ "errexit", .errexit },
    .{ "hashall", .hashall },
    .{ "history", .history },
    .{ "monitor", .monitor },
    .{ "noclobber", .noclobber },
    .{ "noexec", .noexec },
    .{ "noglob", .noglob },
    .{ "notify", .notify },
    .{ "nounset", .nounset },
    .{ "pipefail", .pipefail },
    .{ "vi", .vi },
    .{ "verbose", .verbose },
    .{ "xtrace", .xtrace },
});

const set_option_order = [_]SetOption{
    .allexport,
    .emacs,
    .errexit,
    .hashall,
    .history,
    .monitor,
    .noclobber,
    .noexec,
    .noglob,
    .notify,
    .nounset,
    .pipefail,
    .vi,
    .verbose,
    .xtrace,
};

fn setOptionName(option: SetOption) []const u8 {
    return switch (option) {
        .allexport => "allexport",
        .emacs => "emacs",
        .errexit => "errexit",
        .hashall => "hashall",
        .history => "history",
        .monitor => "monitor",
        .noclobber => "noclobber",
        .noexec => "noexec",
        .noglob => "noglob",
        .notify => "notify",
        .nounset => "nounset",
        .pipefail => "pipefail",
        .vi => "vi",
        .verbose => "verbose",
        .xtrace => "xtrace",
    };
}

fn setOptionEnabled(shell: anytype, option: SetOption) bool {
    return switch (option) {
        .allexport => shell.state.options.allexport,
        .emacs => shell.state.options.emacs,
        .errexit => shell.state.options.errexit,
        .hashall => shell.state.options.hashall,
        .history => shell.state.options.history,
        .monitor => shell.state.options.monitor,
        .noclobber => shell.state.options.noclobber,
        .noexec => shell.state.options.noexec,
        .noglob => shell.state.options.noglob,
        .notify => shell.state.options.notify,
        .nounset => shell.state.options.nounset,
        .pipefail => shell.state.options.pipefail,
        .vi => shell.state.options.vi,
        .verbose => shell.state.options.verbose,
        .xtrace => shell.state.options.xtrace,
    };
}

pub fn isSetOptionEnabled(shell: anytype, name: []const u8) ?bool {
    const option = set_option_names.get(name) orelse return null;
    return setOptionEnabled(shell, option);
}

fn listSetOptions(shell: anytype, table: bool) !result.EvalResult {
    for (set_option_order) |option| {
        const name = setOptionName(option);
        const enabled = setOptionEnabled(shell, option);
        const text = if (table)
            try std.fmt.allocPrint(
                shell.scratchAllocator(),
                "{s}\t{s}\n",
                .{ name, if (enabled) "on" else "off" },
            )
        else
            try std.fmt.allocPrint(
                shell.scratchAllocator(),
                "set {s}o {s}\n",
                .{ if (enabled) "-" else "+", name },
            );
        defer shell.scratchAllocator().free(text);
        try shell.host.writeAll(.stdout, text);
    }
    return .{};
}

fn setNamedOption(shell: anytype, name: []const u8, enabled: bool) bool {
    const option = set_option_names.get(name) orelse return false;
    switch (option) {
        .allexport => shell.state.options.allexport = enabled,
        .emacs => {
            // Emacs-style editing is Rush's default interactive mode. Enabling
            // it clears vi; disabling it only clears the explicit option bit
            // and does not enable vi.
            shell.state.options.emacs = enabled;
            if (enabled) shell.state.options.vi = false;
        },
        .errexit => shell.state.options.errexit = enabled,
        .hashall => shell.state.options.hashall = enabled,
        .history => shell.state.options.history = enabled,
        .monitor => shell.state.options.monitor = enabled,
        .noclobber => shell.state.options.noclobber = enabled,
        .noexec => shell.state.options.noexec = enabled,
        .noglob => shell.state.options.noglob = enabled,
        .notify => shell.state.options.notify = enabled,
        .nounset => shell.state.options.nounset = enabled,
        .pipefail => shell.state.options.pipefail = enabled,
        .vi => {
            // POSIX vi editing mode. Enabling it turns off emacs; disabling it
            // restores Rush's default emacs-style editing option.
            shell.state.options.vi = enabled;
            shell.state.options.emacs = !enabled;
        },
        .verbose => shell.state.options.verbose = enabled,
        .xtrace => shell.state.options.xtrace = enabled,
    }
    return true;
}

fn setUsageError(shell: anytype) !result.EvalResult {
    try shell.host.writeAll(.stderr, "set: invalid option\n");
    return .{ .status = 2 };
}

fn evalUnset(shell: anytype, args: []const []const u8) !result.EvalResult {
    var functions = false;
    var variables = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            'f' => functions = true,
            'v' => variables = true,
            else => return .{ .status = 2 },
        };
    }
    if (functions and variables) return .{ .status = 2 };
    const unset_functions = functions and !variables;
    var status: result.ExitStatus = 0;
    for (args[index..]) |name_arg| {
        const array_target = if (!unset_functions and shell.state.options.mode == .bash)
            parseUnsetArrayTarget(name_arg)
        else
            null;
        const name = if (array_target) |target| target.name else name_arg;
        if (!isAssignmentName(name) and !unset_functions) {
            status = 2;
            continue;
        }
        if (unset_functions) {
            if (std.mem.indexOfScalar(u8, name, '/') == null) {
                shell.state.removeFunction(name);
                try shell.state.suppressFunctionAutoload(name);
            }
        } else if (array_target) |target| {
            status = try unsetArrayTarget(shell, target, status);
        } else if (shell.state.getVariable(name)) |variable| {
            if (variable.readonly) {
                // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                try shell.host.writeAll(.stderr, try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: readonly variable\n", .{name}));
                status = 1;
            } else {
                shell.state.removeVariable(name);
            }
        } else if (shell.state.getVariableAttributes(name)) |attributes| {
            if (attributes.readonly) {
                // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
                try shell.host.writeAll(.stderr, try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: readonly variable\n", .{name}));
                status = 1;
            } else {
                shell.state.removeVariableAttributes(name);
            }
        } else if (shell.state.getArray(name) != null) {
            shell.state.removeArray(name);
        }
    }
    return .{ .status = status, .flow = if (status == 1) .{ .fatal = status } else .normal };
}

const UnsetArrayTarget = struct {
    name: []const u8,
    subscript: []const u8,
};

fn parseUnsetArrayTarget(arg: []const u8) ?UnsetArrayTarget {
    if (arg.len < 4 or arg[arg.len - 1] != ']') return null;
    const open_index = std.mem.indexOfScalar(u8, arg, '[') orelse return null;
    if (open_index == 0) return null;
    const name = arg[0..open_index];
    if (!isAssignmentName(name)) return null;
    return .{ .name = name, .subscript = arg[open_index + 1 .. arg.len - 1] };
}

fn unsetArrayTarget(shell: anytype, target: UnsetArrayTarget, current_status: result.ExitStatus) !result.ExitStatus {
    if (std.mem.eql(u8, target.subscript, "@") or std.mem.eql(u8, target.subscript, "*")) {
        try shell.state.putArray(target.name, &.{});
        return current_status;
    }
    const array = shell.state.getArray(target.name) orelse return current_status;
    const index = unsetArrayIndex(target.subscript, array) catch |err| switch (err) {
        error.BadArraySubscript => {
            try shell.host.writeAll(.stderr, try std.fmt.allocPrint(
                shell.scratchAllocator(),
                "unset: [{s}]: bad array subscript\n",
                .{target.subscript},
            ));
            return 1;
        },
    };
    try shell.state.removeArrayElement(target.name, index);
    return current_status;
}

const UnsetArrayIndexError = error{BadArraySubscript};

fn unsetArrayIndex(subscript: []const u8, array: state_mod.ArrayVariable) UnsetArrayIndexError!usize {
    const value = std.fmt.parseInt(i64, subscript, 10) catch 0;
    if (value >= 0) return @intCast(value);
    if (array.elements.len == 0) return error.BadArraySubscript;
    const max_index = array.elements[array.elements.len - 1].index;
    const magnitude: u64 = if (value == std.math.minInt(i64))
        @as(u64, 1) << 63
    else
        @intCast(-value);
    if (magnitude > max_index + 1) return error.BadArraySubscript;
    return max_index + 1 - @as(usize, @intCast(magnitude));
}

fn evalTrap(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len == 1) {
        try listAllTraps(shell);
        return .{};
    }

    var index: usize = 1;
    if (std.mem.eql(u8, args[index], "--")) {
        index += 1;
        if (index >= args.len) return .{ .status = 2 };
    }
    if (std.mem.eql(u8, args[index], "-p")) {
        index += 1;
        if (index >= args.len) {
            try listAllTraps(shell);
            return .{};
        }
        var status: result.ExitStatus = 0;
        while (index < args.len) : (index += 1) {
            const signal = parseTrapSignal(args[index]) orelse {
                status = 1;
                continue;
            };
            try listTrap(shell, signal);
        }
        return .{ .status = status };
    }

    const reset = std.mem.eql(u8, args[index], "-");
    const action = args[index];
    index += 1;
    if (index >= args.len) return .{ .status = 2 };

    var status: result.ExitStatus = 0;
    while (index < args.len) : (index += 1) {
        const signal = parseTrapSignal(args[index]) orelse {
            status = 1;
            continue;
        };
        switch (signal) {
            .exit => if (reset) shell.state.clearExitTrap() else try shell.state.setExitTrap(action),
            .other => |name| if (reset) {
                shell.state.clearSignalTrap(name);
                // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
                if (signalNumber(name)) |number| shell.host.setSignalDefault(number) catch {};
            } else {
                try shell.state.setSignalTrap(name, action);
                if (signalNumber(name)) |number| {
                    if (action.len == 0) {
                        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
                        shell.host.setSignalIgnored(number) catch {};
                    } else {
                        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
                        shell.host.installSignalTrap(number) catch {};
                    }
                }
            },
        }
    }
    return .{ .status = status };
}

fn listAllTraps(shell: anytype) !void {
    try listTrap(shell, .exit);
    for (trap_signal_names) |signal| try listTrap(shell, .{ .other = signal });
}

fn listTrap(shell: anytype, signal: TrapSignal) !void {
    switch (signal) {
        .exit => if (shell.state.exit_trap_listing) |action| {
            try shell.host.writeAll(.stdout, try std.fmt.allocPrint(
                shell.scratchAllocator(),
                "trap -- '{s}' EXIT\n",
                .{action},
            ));
        },
        .other => |name| if (shell.state.getSignalTrap(name)) |action| {
            try shell.host.writeAll(.stdout, try std.fmt.allocPrint(
                shell.scratchAllocator(),
                "trap -- '{s}' {s}\n",
                .{ action, name },
            ));
        },
    }
}

const TrapSignal = union(enum) { exit, other: []const u8 };

const KillSignal = struct {
    name: ?[]const u8,
    number: u8,
};

const trap_signal_names = [_][]const u8{
    "HUP",  "INT",  "QUIT", "ILL",  "TRAP",   "ABRT", "FPE",   "KILL", "BUS",  "SEGV",
    "PIPE", "ALRM", "TERM", "USR1", "USR2",   "CHLD", "CONT",  "STOP", "TSTP", "TTIN",
    "TTOU", "URG",  "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "POLL", "SYS",
};

fn parseTrapSignal(signal: []const u8) ?TrapSignal {
    if (std.mem.eql(u8, signal, "0") or std.ascii.eqlIgnoreCase(signal, "EXIT")) return .exit;
    if (signalName(signal)) |name| return .{ .other = name };
    const number = std.fmt.parseInt(u8, signal, 10) catch return null;
    return if (signalNameFromNumber(number)) |name| .{ .other = name } else null;
}

fn parseKillSignal(signal: []const u8) ?KillSignal {
    if (std.mem.eql(u8, signal, "0")) return .{ .name = null, .number = 0 };
    if (signalName(signal)) |name| return .{ .name = name, .number = signalNumber(name) orelse return null };
    const number = std.fmt.parseInt(u8, signal, 10) catch return null;
    if (number == 0) return .{ .name = null, .number = 0 };
    return .{ .name = signalNameFromNumber(number), .number = number };
}

fn signalName(signal: []const u8) ?[]const u8 {
    const name_without_prefix = if (signal.len >= 3 and std.ascii.eqlIgnoreCase(signal[0..3], "SIG"))
        signal[3..]
    else
        signal;
    for (trap_signal_names) |name| if (std.ascii.eqlIgnoreCase(name_without_prefix, name)) return name;
    return null;
}

pub fn signalNumber(signal: []const u8) ?u8 {
    inline for (trap_signal_names) |name| {
        if (std.mem.eql(u8, signal, name) and @hasField(std.c.SIG, name)) {
            return @intCast(@intFromEnum(@field(std.c.SIG, name)));
        }
    }
    return null;
}

fn signalNameFromNumber(number: u8) ?[]const u8 {
    for (trap_signal_names) |name| if (signalNumber(name) == number) return name;
    return null;
}

fn isAssignmentName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

test "builtin lookup identifies null true and false utilities" {
    try std.testing.expectEqual(Id.bracket, lookup("[").?.id);
    try std.testing.expectEqual(@as(?Definition, null), lookup("abbr"));
    try std.testing.expectEqual(Id.alias, lookup("alias").?.id);
    try std.testing.expectEqual(Id.break_, lookup("break").?.id);
    try std.testing.expectEqual(Id.cd, lookup("cd").?.id);
    try std.testing.expectEqual(Id.colon, lookup(":").?.id);
    try std.testing.expectEqual(Id.dot, lookup(".").?.id);
    try std.testing.expectEqual(Id.command, lookup("command").?.id);
    try std.testing.expectEqual(Id.continue_, lookup("continue").?.id);
    try std.testing.expectEqual(Id.declare, lookup("declare").?.id);
    try std.testing.expectEqual(Id.eval, lookup("eval").?.id);
    try std.testing.expectEqual(Id.exec, lookup("exec").?.id);
    try std.testing.expectEqual(Id.export_, lookup("export").?.id);
    try std.testing.expectEqual(Id.exit, lookup("exit").?.id);
    try std.testing.expectEqual(Id.fc, lookup("fc").?.id);
    try std.testing.expectEqual(Id.getopts, lookup("getopts").?.id);
    try std.testing.expectEqual(Id.kill, lookup("kill").?.id);
    try std.testing.expectEqual(Id.true_, lookup("true").?.id);
    try std.testing.expectEqual(Id.false_, lookup("false").?.id);
    try std.testing.expectEqual(Id.printf, lookup("printf").?.id);
    try std.testing.expectEqual(Id.pwd, lookup("pwd").?.id);
    try std.testing.expectEqual(Id.read, lookup("read").?.id);
    try std.testing.expectEqual(Id.readonly, lookup("readonly").?.id);
    try std.testing.expectEqual(Id.trap, lookup("trap").?.id);
    try std.testing.expectEqual(Id.typeset, lookup("typeset").?.id);
    try std.testing.expectEqual(Id.type, lookup("type").?.id);
    try std.testing.expectEqual(Id.test_, lookup("test").?.id);
    try std.testing.expectEqual(Id.times, lookup("times").?.id);
    try std.testing.expectEqual(Id.umask, lookup("umask").?.id);
    try std.testing.expectEqual(Id.unalias, lookup("unalias").?.id);
    try std.testing.expectEqual(Id.unset, lookup("unset").?.id);
    try std.testing.expectEqual(Id.wait, lookup("wait").?.id);
    try std.testing.expectEqual(Id.z, lookup("z").?.id);
    try std.testing.expectEqual(@as(?Definition, null), lookup("missing"));
}

test "fc lists and re-executes attached command history" {
    const TestHost = struct {
        stdout: std.ArrayList(u8) = .empty,
        stderr: std.ArrayList(u8) = .empty,
        file: std.ArrayList(u8) = .empty,
        read_offset: usize = 0,
        deleted: bool = false,

        // ziglint-ignore: Z020 Z030 test helper/reusable deinit; preserve behavior
        fn deinit(self: *@This()) void {
            self.stdout.deinit(std.testing.allocator);
            self.stderr.deinit(std.testing.allocator);
            self.file.deinit(std.testing.allocator);
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn writeAll(self: *@This(), fd: host.Fd, bytes: []const u8) !void {
            switch (fd) {
                .stdout => try self.stdout.appendSlice(std.testing.allocator, bytes),
                .stderr => try self.stderr.appendSlice(std.testing.allocator, bytes),
                else => try self.file.appendSlice(std.testing.allocator, bytes),
            }
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn read(self: *@This(), _: host.Fd, buffer: []u8) !usize {
            if (self.read_offset >= self.file.items.len) return 0;
            const len = @min(buffer.len, self.file.items.len - self.read_offset);
            @memcpy(buffer[0..len], self.file.items[self.read_offset..][0..len]);
            self.read_offset += len;
            return len;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn openZ(self: *@This(), _: [:0]const u8, options: host.OpenOptions) !host.Fd {
            if (options.create) {
                self.file.clearRetainingCapacity();
            }
            self.read_offset = 0;
            return @enumFromInt(100);
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn close(_: *@This(), _: host.Fd) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn deleteFileZ(self: *@This(), _: [:0]const u8) !void {
            self.deleted = true;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn isExecutableZ(_: *@This(), path: [:0]const u8) bool {
            return std.mem.endsWith(u8, path, "fake-ed");
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn spawn(self: *@This(), request: host.SpawnRequest) !host.SpawnResult {
            try std.testing.expectEqualStrings("/bin/fake-ed", request.path);
            try std.testing.expectEqualStrings("fake-ed", std.mem.span(request.argv[0].?));
            try std.testing.expect(std.mem.startsWith(u8, std.mem.span(request.argv[1].?), "/tmp/rush-fc-1-"));
            try std.testing.expectEqualStrings("echo two\n", self.file.items);
            self.file.clearRetainingCapacity();
            try self.file.appendSlice(std.testing.allocator, "echo edited\n");
            return .{ .pid = 123 };
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn wait(_: *@This(), _: host.Pid) !host.WaitStatus {
            return .{ .exited = 0 };
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
    };
    const TestContext = struct {
        entries: []const history_mod.HistoryEntry,
        appended: std.ArrayList(u8) = .empty,
        suppress_next_append: bool = false,

        // ziglint-ignore: Z020 Z030 test helper/reusable deinit; preserve behavior
        fn deinit(self: *@This()) void {
            self.appended.deinit(std.testing.allocator);
        }

        // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
        fn list(context: *anyopaque, allocator: std.mem.Allocator) ![]history_mod.HistoryEntry {
            // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
            const self: *@This() = @ptrCast(@alignCast(context));
            const entries = try allocator.alloc(history_mod.HistoryEntry, self.entries.len);
            for (self.entries, 0..) |entry, index| {
                entries[index] = .{ .number = entry.number, .command = try allocator.dupe(u8, entry.command) };
            }
            return entries;
        }

        fn append(
            context: *anyopaque,
            // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
            _: std.Io,
            line: []const u8,
            _: u8,
            _: i64,
            _: i64,
        ) !void {
            // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
            const self: *@This() = @ptrCast(@alignCast(context));
            try self.appended.appendSlice(std.testing.allocator, line);
        }

        fn suppress(context: *anyopaque) void {
            // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
            const self: *@This() = @ptrCast(@alignCast(context));
            self.suppress_next_append = true;
        }
    };
    const TestShell = struct {
        host: TestHost = .{},
        state: state_mod.State,
        command_history: ?history_mod.CommandHistory = null,

        // ziglint-ignore: Z020 Z030 test helper/reusable deinit; preserve behavior
        fn deinit(self: *@This()) void {
            self.host.deinit();
            self.state.deinit();
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn scratchAllocator(_: *@This()) std.mem.Allocator {
            return std.testing.allocator;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn evalSourceNested(self: *@This(), src: anytype) !result.EvalResult {
            try self.host.writeAll(.stdout, "RUN:");
            try self.host.writeAll(.stdout, src.text);
            try self.host.writeAll(.stdout, "\n");
            return .{};
        }
    };

    const entries = [_]history_mod.HistoryEntry{
        .{ .number = 1, .command = "printf one" },
        .{ .number = 2, .command = "echo two" },
        .{ .number = 3, .command = "echo three" },
    };
    var context: TestContext = .{ .entries = &entries };
    defer context.deinit();

    var shell: TestShell = .{ .state = state_mod.State.init(std.testing.allocator, .{}) };
    defer shell.deinit();
    shell.command_history = .{
        .context = &context,
        .io = std.testing.io,
        .list = TestContext.list,
        .append = TestContext.append,
        .suppress_next_append = TestContext.suppress,
    };

    const fc_definition = lookup("fc").?;
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, fc_definition, &.{ "fc", "-ln", "2", "3" })).status,
    );
    try std.testing.expectEqualStrings("\techo two\n\techo three\n", shell.host.stdout.items);

    shell.host.stdout.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, fc_definition, &.{ "fc", "-s", "two=deux", "2" })).status,
    );
    try std.testing.expectEqualStrings("RUN:echo deux\n", shell.host.stdout.items);
    try std.testing.expectEqualStrings("echo deux", context.appended.items);
    try std.testing.expect(context.suppress_next_append);

    shell.host.stdout.clearRetainingCapacity();
    context.appended.clearRetainingCapacity();
    context.suppress_next_append = false;
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, fc_definition, &.{ "fc", "-e", "fake-ed", "2" })).status,
    );
    try std.testing.expectEqualStrings("RUN:echo edited\n\n", shell.host.stdout.items);
    try std.testing.expectEqualStrings("echo edited\n", context.appended.items);
    try std.testing.expect(context.suppress_next_append);
    try std.testing.expect(shell.host.deleted);
}

test "history builtin lists searches deletes and clears attached history" {
    const TestHost = struct {
        stdout: std.ArrayList(u8) = .empty,
        stderr: std.ArrayList(u8) = .empty,

        // ziglint-ignore: Z020 Z030 test helper/reusable deinit; preserve behavior
        fn deinit(self: *@This()) void {
            self.stdout.deinit(std.testing.allocator);
            self.stderr.deinit(std.testing.allocator);
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn writeAll(self: *@This(), fd: host.Fd, bytes: []const u8) !void {
            switch (fd) {
                .stdout => try self.stdout.appendSlice(std.testing.allocator, bytes),
                else => try self.stderr.appendSlice(std.testing.allocator, bytes),
            }
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
    };
    const TestContext = struct {
        entries: []const history_mod.HistoryEntry,
        deleted: std.ArrayList(i64) = .empty,
        cleared: bool = false,
        suppress_next_append: bool = false,

        // ziglint-ignore: Z020 Z030 test helper/reusable deinit; preserve behavior
        fn deinit(self: *@This()) void {
            self.deleted.deinit(std.testing.allocator);
        }

        fn suppress(context: *anyopaque) void {
            // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
            const self: *@This() = @ptrCast(@alignCast(context));
            self.suppress_next_append = true;
        }

        // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
        fn list(context: *anyopaque, allocator: std.mem.Allocator) ![]history_mod.HistoryEntry {
            // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
            const self: *@This() = @ptrCast(@alignCast(context));
            const entries = try allocator.alloc(history_mod.HistoryEntry, self.entries.len);
            for (self.entries, 0..) |entry, index| {
                entries[index] = .{ .number = entry.number, .command = try allocator.dupe(u8, entry.command) };
            }
            return entries;
        }

        // ziglint-ignore: Z023 parameter order follows CommandHistory.search callback shape
        fn search(context: *anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]history_mod.HistoryEntry {
            // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
            const self: *@This() = @ptrCast(@alignCast(context));
            var matches: std.ArrayList(history_mod.HistoryEntry) = .empty;
            errdefer {
                for (matches.items) |entry| allocator.free(entry.command);
                matches.deinit(allocator);
            }
            for (self.entries) |entry| {
                if (std.mem.indexOf(u8, entry.command, text) == null) continue;
                try matches.append(allocator, .{
                    .number = entry.number,
                    .command = try allocator.dupe(u8, entry.command),
                });
            }
            return matches.toOwnedSlice(allocator);
        }

        fn delete(context: *anyopaque, id: i64) !bool {
            // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
            const self: *@This() = @ptrCast(@alignCast(context));
            for (self.entries) |entry| {
                if (entry.number != id) continue;
                try self.deleted.append(std.testing.allocator, id);
                return true;
            }
            return false;
        }

        fn clear(context: *anyopaque) !void {
            // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
            const self: *@This() = @ptrCast(@alignCast(context));
            self.cleared = true;
        }
    };
    const TestShell = struct {
        host: TestHost = .{},
        state: state_mod.State,
        command_history: ?history_mod.CommandHistory = null,
        // Production scratch allocators are arenas; writeFcEntry relies on that.
        scratch: std.heap.ArenaAllocator,

        // ziglint-ignore: Z020 Z030 test helper/reusable deinit; preserve behavior
        fn deinit(self: *@This()) void {
            self.host.deinit();
            self.state.deinit();
            self.scratch.deinit();
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn scratchAllocator(self: *@This()) std.mem.Allocator {
            return self.scratch.allocator();
        }
    };

    const entries = [_]history_mod.HistoryEntry{
        .{ .number = 11, .command = "printf one" },
        .{ .number = 12, .command = "echo two" },
        .{ .number = 13, .command = "echo three" },
    };
    var context: TestContext = .{ .entries = &entries };
    defer context.deinit();

    var shell: TestShell = .{
        .state = state_mod.State.init(std.testing.allocator, .{}),
        .scratch = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer shell.deinit();
    shell.command_history = .{
        .context = &context,
        .io = std.testing.io,
        .list = TestContext.list,
        .search = TestContext.search,
        .delete_id = TestContext.delete,
        .clear = TestContext.clear,
        .suppress_next_append = TestContext.suppress,
    };

    const history_definition = lookup("history").?;
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, history_definition, &.{"history"})).status,
    );
    try std.testing.expectEqualStrings("11\tprintf one\n12\techo two\n13\techo three\n", shell.host.stdout.items);
    // history invocations must not record themselves.
    try std.testing.expect(context.suppress_next_append);

    shell.host.stdout.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, history_definition, &.{ "history", "2" })).status,
    );
    try std.testing.expectEqualStrings("12\techo two\n13\techo three\n", shell.host.stdout.items);

    shell.host.stdout.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, history_definition, &.{ "history", "search", "echo" })).status,
    );
    try std.testing.expectEqualStrings("12\techo two\n13\techo three\n", shell.host.stdout.items);

    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, history_definition, &.{ "history", "delete", "--id", "12", "--id=13" })).status,
    );
    try std.testing.expectEqualSlices(i64, &.{ 12, 13 }, context.deleted.items);

    try std.testing.expectEqual(
        @as(result.ExitStatus, 1),
        (try eval(&shell, history_definition, &.{ "history", "delete", "--id", "99" })).status,
    );
    try std.testing.expectEqualStrings("history: no entry with id 99\n", shell.host.stderr.items);

    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, history_definition, &.{ "history", "clear" })).status,
    );
    try std.testing.expect(context.cleared);

    shell.host.stderr.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(result.ExitStatus, 2),
        (try eval(&shell, history_definition, &.{ "history", "bogus" })).status,
    );
    try std.testing.expect(std.mem.startsWith(u8, shell.host.stderr.items, "history: usage:"));
}

test "builtin eval returns utility status" {
    const TestHost = struct {
        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn writeAll(_: *@This(), _: host.Fd, _: []const u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
    };
    const TestShell = struct {
        host: TestHost = .{},
        state: state_mod.State,

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn scratchAllocator(_: *@This()) std.mem.Allocator {
            return std.testing.allocator;
        }
    };

    var shell: TestShell = .{ .state = state_mod.State.init(std.testing.allocator, .{}) };
    defer shell.state.deinit();
    const true_definition = lookup("true").?;
    const false_definition = lookup("false").?;

    try std.testing.expectEqual(@as(result.ExitStatus, 0), (try eval(&shell, true_definition, &.{"true"})).status);
    try std.testing.expectEqual(@as(result.ExitStatus, 1), (try eval(&shell, false_definition, &.{"false"})).status);
}

test "set -o notify toggles notify option" {
    const TestHost = struct {
        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn writeAll(_: *@This(), _: host.Fd, _: []const u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
    };
    const TestShell = struct {
        host: TestHost = .{},
        state: state_mod.State,

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn scratchAllocator(_: *@This()) std.mem.Allocator {
            return std.testing.allocator;
        }
    };

    var shell: TestShell = .{ .state = state_mod.State.init(std.testing.allocator, .{}) };
    defer shell.state.deinit();
    const set_definition = lookup("set").?;

    try std.testing.expect(!shell.state.options.notify);
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, set_definition, &.{ "set", "-o", "notify" })).status,
    );
    try std.testing.expect(shell.state.options.notify);
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, set_definition, &.{ "set", "+o", "notify" })).status,
    );
    try std.testing.expect(!shell.state.options.notify);
}

test "set -o monitor toggles and lists the monitor option" {
    const TestHost = struct {
        stdout: std.ArrayList(u8) = .empty,

        // ziglint-ignore: Z020 Z030 test helper/reusable deinit; preserve behavior
        fn deinit(self: *@This()) void {
            self.stdout.deinit(std.testing.allocator);
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn writeAll(self: *@This(), fd: host.Fd, bytes: []const u8) !void {
            switch (fd) {
                .stdout => try self.stdout.appendSlice(std.testing.allocator, bytes),
                else => {},
            }
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
    };
    const TestShell = struct {
        host: TestHost = .{},
        state: state_mod.State,

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn scratchAllocator(_: *@This()) std.mem.Allocator {
            return std.testing.allocator;
        }
    };

    var shell: TestShell = .{ .state = state_mod.State.init(std.testing.allocator, .{}) };
    defer shell.state.deinit();
    defer shell.host.deinit();
    const set_definition = lookup("set").?;

    try std.testing.expect(!shell.state.options.monitor);
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, set_definition, &.{ "set", "-o", "monitor" })).status,
    );
    try std.testing.expect(shell.state.options.monitor);
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, set_definition, &.{ "set", "-o" })).status,
    );
    try std.testing.expect(std.mem.indexOf(u8, shell.host.stdout.items, "monitor\ton\n") != null);

    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, set_definition, &.{ "set", "+o", "monitor" })).status,
    );
    try std.testing.expect(!shell.state.options.monitor);
    shell.host.stdout.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, set_definition, &.{ "set", "-o" })).status,
    );
    try std.testing.expect(std.mem.indexOf(u8, shell.host.stdout.items, "monitor\toff\n") != null);
}

test "set -o vi and emacs are mutually exclusive editing options" {
    const TestHost = struct {
        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn writeAll(_: *@This(), _: host.Fd, _: []const u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
    };
    const TestShell = struct {
        host: TestHost = .{},
        state: state_mod.State,

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn scratchAllocator(_: *@This()) std.mem.Allocator {
            return std.testing.allocator;
        }
    };

    var shell: TestShell = .{ .state = state_mod.State.init(std.testing.allocator, .{}) };
    defer shell.state.deinit();
    const set_definition = lookup("set").?;

    try std.testing.expect(shell.state.options.emacs);
    try std.testing.expect(!shell.state.options.vi);

    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, set_definition, &.{ "set", "-o", "vi" })).status,
    );
    try std.testing.expect(shell.state.options.vi);
    try std.testing.expect(!shell.state.options.emacs);

    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, set_definition, &.{ "set", "+o", "vi" })).status,
    );
    try std.testing.expect(!shell.state.options.vi);
    try std.testing.expect(shell.state.options.emacs);

    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, set_definition, &.{ "set", "-o", "vi" })).status,
    );
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, set_definition, &.{ "set", "-o", "emacs" })).status,
    );
    try std.testing.expect(shell.state.options.emacs);
    try std.testing.expect(!shell.state.options.vi);

    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, set_definition, &.{ "set", "+o", "emacs" })).status,
    );
    try std.testing.expect(!shell.state.options.emacs);
    try std.testing.expect(!shell.state.options.vi);
}

test "jobs builtin filters jobs and prints pids" {
    const TestHost = struct {
        stdout: std.ArrayList(u8) = .empty,
        stderr: std.ArrayList(u8) = .empty,

        // ziglint-ignore: Z020 Z030 test helper/reusable deinit; preserve behavior
        fn deinit(self: *@This()) void {
            self.stdout.deinit(std.testing.allocator);
            self.stderr.deinit(std.testing.allocator);
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn writeAll(self: *@This(), fd: host.Fd, bytes: []const u8) !void {
            switch (fd) {
                .stdout => try self.stdout.appendSlice(std.testing.allocator, bytes),
                .stderr => try self.stderr.appendSlice(std.testing.allocator, bytes),
                else => unreachable,
            }
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
    };
    const TestShell = struct {
        host: TestHost = .{},
        state: state_mod.State,

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn scratchAllocator(_: *@This()) std.mem.Allocator {
            return std.testing.allocator;
        }
    };

    var shell: TestShell = .{ .state = state_mod.State.init(std.testing.allocator, .{}) };
    defer shell.state.deinit();
    defer shell.host.deinit();
    try shell.state.addBackgroundPid(111);
    try shell.state.addBackgroundJob(111, "sleep 1", true);
    try shell.state.addBackgroundPid(222);
    try shell.state.addBackgroundJob(222, "sleep 2", true);

    const jobs_definition = lookup("jobs").?;
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, jobs_definition, &.{ "jobs", "-p", "%2" })).status,
    );
    try std.testing.expectEqualStrings("222\n", shell.host.stdout.items);

    shell.host.stdout.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(result.ExitStatus, 1),
        (try eval(&shell, jobs_definition, &.{ "jobs", "%3" })).status,
    );
    try std.testing.expectEqualStrings("", shell.host.stdout.items);
    try std.testing.expectEqualStrings("jobs: no such job\n", shell.host.stderr.items);
}

test "exit builtin returns requested exit flow" {
    const TestHost = struct {
        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn writeAll(_: *@This(), _: host.Fd, _: []const u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
    };
    const TestShell = struct {
        host: TestHost = .{},
        state: state_mod.State,

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn scratchAllocator(_: *@This()) std.mem.Allocator {
            return std.testing.allocator;
        }
    };

    var shell: TestShell = .{ .state = state_mod.State.init(std.testing.allocator, .{}) };
    defer shell.state.deinit();
    const evaluated = try eval(&shell, lookup("exit").?, &.{ "exit", "7" });

    try std.testing.expectEqual(@as(result.ExitStatus, 7), evaluated.status);
    // ziglint-ignore: Z010 explicit type retained for readability/type inference
    try std.testing.expectEqual(result.ControlFlow{ .exit = 7 }, evaluated.flow);
}

test "printf writes formatted output once" {
    const TestHost = struct {
        stdout: std.ArrayList(u8) = .empty,
        stderr: std.ArrayList(u8) = .empty,

        // ziglint-ignore: Z020 Z030 test helper/reusable deinit; preserve behavior
        fn deinit(self: *@This()) void {
            self.stdout.deinit(std.testing.allocator);
            self.stderr.deinit(std.testing.allocator);
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn writeAll(self: *@This(), fd: host.Fd, bytes: []const u8) !void {
            switch (fd) {
                .stdout => try self.stdout.appendSlice(std.testing.allocator, bytes),
                .stderr => try self.stderr.appendSlice(std.testing.allocator, bytes),
                else => unreachable,
            }
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
    };
    const TestShell = struct {
        host: TestHost = .{},
        state: state_mod.State,

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn scratchAllocator(_: *@This()) std.mem.Allocator {
            return std.testing.allocator;
        }
    };

    var shell: TestShell = .{ .state = state_mod.State.init(std.testing.allocator, .{}) };
    defer shell.state.deinit();
    defer shell.host.deinit();

    const printf_definition = lookup("printf").?;
    const evaluated = try eval(&shell, printf_definition, &.{ "printf", "%s\\n", "hello" });

    try std.testing.expectEqual(@as(result.ExitStatus, 0), evaluated.status);
    try std.testing.expectEqualStrings("hello\n", shell.host.stdout.items);
    try std.testing.expectEqualStrings("", shell.host.stderr.items);
}
