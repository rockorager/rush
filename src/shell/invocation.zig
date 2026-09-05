//! Classifies process arguments into interactive, command-string, and script
//! startup modes while applying shell mode and option flags. Parsed string and
//! positional slices borrow the original argument vector.

const std = @import("std");

const builtin = @import("builtin.zig");
const state = @import("state.zig");

pub const ParseError = error{
    MissingCommandString,
    UnsupportedOption,
    UnexpectedOperand,
};

pub const Invocation = union(enum) {
    help,
    version,
    interactive: Interactive,
    command_string: CommandString,
    script_file: ScriptFile,
};

pub const Interactive = struct {
    mode: state.Mode = .bash,
    options: state.Options = .{},
    arg_zero: []const u8,
    positionals: []const []const u8 = &.{},
    login: bool = false,
    /// True only when -i was given explicitly. Otherwise both standard input
    /// and standard error must be terminals to run interactively.
    forced_interactive: bool = false,
};

pub const CommandString = struct {
    mode: state.Mode = .bash,
    options: state.Options = .{},
    script: []const u8,
    arg_zero: []const u8,
    positionals: []const []const u8 = &.{},
};

pub const ScriptFile = struct {
    mode: state.Mode = .bash,
    options: state.Options = .{},
    path: []const u8,
    positionals: []const []const u8 = &.{},
};

pub fn parse(args: []const []const u8) ParseError!Invocation {
    std.debug.assert(args.len != 0);

    const base = std.fs.path.basename(args[0]);
    const name = if (base.len > 0 and base[0] == '-') base[1..] else base;
    var mode: state.Mode = if (std.mem.eql(u8, name, "sh")) .posix else .bash;
    var options: state.Options = .{};
    var login = isLoginArgZero(args[0]);
    var forced_interactive = false;
    var command_string = false;
    var standard_input = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "--version")) return .version;
        if (std.mem.eql(u8, arg, "--login")) {
            login = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--posix")) {
            mode = .posix;
            continue;
        }
        if (std.mem.eql(u8, arg, "--") or std.mem.eql(u8, arg, "-")) {
            index += 1;
            break;
        }
        if (arg.len > 1 and (arg[0] == '-' or arg[0] == '+')) {
            const enabled = arg[0] == '-';
            for (arg[1..]) |option| switch (option) {
                'c' => {
                    if (!enabled) return error.UnsupportedOption;
                    command_string = true;
                },
                's' => {
                    if (!enabled) return error.UnsupportedOption;
                    standard_input = true;
                },
                'i' => {
                    if (!enabled) return error.UnsupportedOption;
                    options.interactive = true;
                    options.history = true;
                    forced_interactive = true;
                },
                'l' => login = enabled,
                'o' => {
                    index += 1;
                    if (index >= args.len) return error.UnsupportedOption;
                    if (!builtin.setNamedOption(&options, args[index], enabled)) return error.UnsupportedOption;
                },
                else => if (!builtin.setShortOption(&options, option, enabled)) return error.UnsupportedOption,
            };
            continue;
        }
        break;
    }

    options.mode = mode;
    if (command_string) {
        if (index >= args.len) return error.MissingCommandString;
        const operands = args[index + 1 ..];
        return .{ .command_string = .{
            .mode = mode,
            .options = options,
            .script = args[index],
            .arg_zero = if (operands.len == 0) args[0] else operands[0],
            .positionals = if (operands.len <= 1) &.{} else operands[1..],
        } };
    }
    if (!standard_input and index < args.len) {
        return .{ .script_file = .{
            .mode = mode,
            .options = options,
            .path = args[index],
            .positionals = args[index + 1 ..],
        } };
    }

    options.interactive = true;
    options.history = true;
    return .{ .interactive = .{
        .mode = mode,
        .options = options,
        .arg_zero = args[0],
        .positionals = args[index..],
        .login = login,
        .forced_interactive = forced_interactive,
    } };
}

fn isLoginArgZero(arg_zero: []const u8) bool {
    const base = std.fs.path.basename(arg_zero);
    return base.len > 1 and base[0] == '-';
}

test "invocation parses bare interactive shell" {
    const args = [_][]const u8{"rush"};
    const invocation = try parse(&args);
    const interactive = switch (invocation) {
        .interactive => |interactive| interactive,
        .help, .version, .command_string, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(state.Mode.bash, interactive.mode);
    try std.testing.expect(interactive.options.interactive);
    try std.testing.expect(interactive.options.history);
    try std.testing.expect(!interactive.forced_interactive);
    try std.testing.expect(!interactive.login);
    try std.testing.expectEqualStrings("rush", interactive.arg_zero);
}

test "invocation records explicit -i as forced interactive" {
    const args = [_][]const u8{ "rush", "-i" };
    const invocation = try parse(&args);
    const interactive = switch (invocation) {
        .interactive => |interactive| interactive,
        .help, .version, .command_string, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expect(interactive.options.interactive);
    try std.testing.expect(interactive.forced_interactive);
}

test "invocation parses explicit login shell" {
    const args = [_][]const u8{ "rush", "--login" };
    const invocation = try parse(&args);
    const interactive = switch (invocation) {
        .interactive => |interactive| interactive,
        .help, .version, .command_string, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expect(interactive.login);
    try std.testing.expect(interactive.options.interactive);
}

test "invocation parses short login flag" {
    const args = [_][]const u8{ "rush", "-l" };
    const invocation = try parse(&args);
    const interactive = switch (invocation) {
        .interactive => |interactive| interactive,
        .help, .version, .command_string, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expect(interactive.login);
    try std.testing.expect(interactive.options.interactive);
}

test "invocation parses bundled short login flag" {
    const args = [_][]const u8{ "rush", "-il" };
    const invocation = try parse(&args);
    const interactive = switch (invocation) {
        .interactive => |interactive| interactive,
        .help, .version, .command_string, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expect(interactive.login);
    try std.testing.expect(interactive.forced_interactive);
}

test "invocation parses login shell arg zero" {
    const args = [_][]const u8{"/bin/-rush"};
    const invocation = try parse(&args);
    const interactive = switch (invocation) {
        .interactive => |interactive| interactive,
        .help, .version, .command_string, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expect(interactive.login);
    try std.testing.expect(interactive.options.interactive);
}

test "invocation parses POSIX interactive shell" {
    const args = [_][]const u8{ "rush", "--posix" };
    const invocation = try parse(&args);
    const interactive = switch (invocation) {
        .interactive => |interactive| interactive,
        .help, .version, .command_string, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(state.Mode.posix, interactive.mode);
    try std.testing.expectEqual(state.Mode.posix, interactive.options.mode);
    try std.testing.expect(interactive.options.interactive);
}

test "invocation parses POSIX command string" {
    const args = [_][]const u8{ "rush", "--posix", "-c", ":", "name", "a" };
    const invocation = try parse(&args);
    const command = switch (invocation) {
        .command_string => |command| command,
        .help, .version, .interactive, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(state.Mode.posix, command.mode);
    try std.testing.expectEqual(state.Mode.posix, command.options.mode);
    try std.testing.expectEqualStrings(":", command.script);
    try std.testing.expectEqualStrings("name", command.arg_zero);
    try std.testing.expectEqual(@as(usize, 1), command.positionals.len);
    try std.testing.expectEqualStrings("a", command.positionals[0]);
}

test "invocation parses xtrace option" {
    const args = [_][]const u8{ "rush", "--posix", "-x", "-c", ":" };
    const invocation = try parse(&args);
    const command = switch (invocation) {
        .command_string => |command| command,
        .help, .version, .interactive, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expect(command.options.xtrace);
    try std.testing.expectEqual(state.Mode.posix, command.options.mode);
}

test "invocation parses command string in bundled short options" {
    const args = [_][]const u8{ "rush", "-ucx", ":", "name", "arg" };
    const invocation = try parse(&args);
    const command = switch (invocation) {
        .command_string => |command| command,
        .help, .version, .interactive, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expect(command.options.nounset);
    try std.testing.expect(command.options.xtrace);
    try std.testing.expectEqualStrings(":", command.script);
    try std.testing.expectEqualStrings("name", command.arg_zero);
    try std.testing.expectEqualSlices([]const u8, &.{"arg"}, command.positionals);
}

test "invocation parses nounset option" {
    const args = [_][]const u8{ "rush", "--posix", "-u", "-c", ":" };
    const invocation = try parse(&args);
    const command = switch (invocation) {
        .command_string => |command| command,
        .help, .version, .interactive, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expect(command.options.nounset);
    try std.testing.expectEqual(state.Mode.posix, command.options.mode);
}

test "invocation parses POSIX script file" {
    const args = [_][]const u8{ "rush", "--posix", "script.sh", "a", "b" };
    const invocation = try parse(&args);
    const script = switch (invocation) {
        .script_file => |script| script,
        .command_string, .help, .version, .interactive => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(state.Mode.posix, script.mode);
    try std.testing.expectEqual(state.Mode.posix, script.options.mode);
    try std.testing.expectEqualStrings("script.sh", script.path);
    try std.testing.expectEqual(@as(usize, 2), script.positionals.len);
    try std.testing.expectEqualStrings("a", script.positionals[0]);
    try std.testing.expectEqualStrings("b", script.positionals[1]);
}

test "invocation parses script file after option terminator" {
    const args = [_][]const u8{ "rush", "--posix", "--", "-script", "a" };
    const invocation = try parse(&args);
    const script = switch (invocation) {
        .script_file => |script| script,
        .command_string, .help, .version, .interactive => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(state.Mode.posix, script.options.mode);
    try std.testing.expectEqualStrings("-script", script.path);
    try std.testing.expectEqual(@as(usize, 1), script.positionals.len);
    try std.testing.expectEqualStrings("a", script.positionals[0]);
}

test "invocation parses interactive option" {
    const args = [_][]const u8{ "rush", "--posix", "-i", "-c", ":" };
    const invocation = try parse(&args);
    const command = switch (invocation) {
        .command_string => |command| command,
        .help, .version, .interactive, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expect(command.options.interactive);
    try std.testing.expect(command.options.history);
    try std.testing.expectEqual(state.Mode.posix, command.options.mode);
}

test "invocation parses version" {
    const args = [_][]const u8{ "rush", "--version" };
    switch (try parse(&args)) {
        .version => {},
        else => return error.TestExpectedEqual,
    }
}

test "invocation name sh selects POSIX mode for every input form" {
    for ([_][]const u8{ "sh", "/bin/sh", "-sh", "/bin/-sh" }) |name| {
        const stdin_invocation = (try parse(&.{name})).interactive;
        try std.testing.expectEqual(state.Mode.posix, stdin_invocation.options.mode);
        try std.testing.expectEqualStrings(name, stdin_invocation.arg_zero);
        const command = (try parse(&.{ name, "-c", ":" })).command_string;
        try std.testing.expectEqual(state.Mode.posix, command.options.mode);
        const script = (try parse(&.{ name, "script" })).script_file;
        try std.testing.expectEqual(state.Mode.posix, script.options.mode);
    }
    try std.testing.expectEqual(state.Mode.bash, (try parse(&.{"rush"})).interactive.options.mode);
}

test "invocation shares set flags and accepts options after c" {
    const command = (try parse(&.{ "sh", "-c", "-abCefhmnuvx", "+abCfhmuvx", ":" })).command_string;
    try std.testing.expect(command.options.errexit);
    try std.testing.expect(command.options.noexec);
    try std.testing.expect(!command.options.allexport);
    try std.testing.expect(!command.options.notify);
    try std.testing.expect(!command.options.noclobber);
    try std.testing.expect(!command.options.noglob);
    try std.testing.expect(!command.options.hashall);
    try std.testing.expect(!command.options.monitor);
    try std.testing.expect(!command.options.nounset);
    try std.testing.expect(!command.options.verbose);
    try std.testing.expect(!command.options.xtrace);
}

test "invocation shares named options and editing exclusions" {
    const command = (try parse(&.{ "sh", "-eo", "pipefail", "+o", "errexit", "-o", "vi", "-c", ":" }))
        .command_string;
    try std.testing.expect(command.options.pipefail);
    try std.testing.expect(!command.options.errexit);
    try std.testing.expect(command.options.vi);
    try std.testing.expect(!command.options.emacs);
    try std.testing.expectError(error.UnsupportedOption, parse(&.{ "sh", "-o" }));
    try std.testing.expectError(error.UnsupportedOption, parse(&.{ "sh", "-o", "unknown" }));
    try std.testing.expectError(error.UnsupportedOption, parse(&.{ "sh", "-z" }));
    try std.testing.expectError(error.MissingCommandString, parse(&.{ "sh", "-ec" }));
}

test "invocation stdin operands and option terminators preserve arguments" {
    const input = (try parse(&.{ "sh", "-s", "--", "-first", "second" })).interactive;
    try std.testing.expectEqualStrings("sh", input.arg_zero);
    try std.testing.expectEqualSlices([]const u8, &.{ "-first", "second" }, input.positionals);
    for ([_][]const u8{ "-", "--" }) |terminator| {
        try std.testing.expectEqual(@as(usize, 0), (try parse(&.{ "sh", terminator })).interactive.positionals.len);
        const file = (try parse(&.{ "sh", terminator, "-file", "arg" })).script_file;
        try std.testing.expectEqualStrings("-file", file.path);
        const command = (try parse(&.{ "sh", "-c", terminator, "-text", "name", "arg" })).command_string;
        try std.testing.expectEqualStrings("-text", command.script);
        try std.testing.expectEqualStrings("name", command.arg_zero);
        try std.testing.expectEqualSlices([]const u8, &.{"arg"}, command.positionals);
    }
}
