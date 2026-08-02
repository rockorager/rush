//! CLI invocation dispatch for the Rush executable.

const std = @import("std");

const build_config = @import("build_config");
const extensions = @import("extensions.zig");
const file_util = @import("file_util.zig");
const function_autoload = @import("function_autoload.zig");
const host = @import("host.zig");
const interactive = @import("interactive.zig");
const shell = @import("shell.zig");

const RushShell = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry);

const usage =
    \\usage: rush [-l | --login] [--posix] [-i] [-u] [-x]
    \\       rush [--posix] [-i] [-u] [-x] -c SCRIPT [NAME [ARGS...]]
    \\       rush [--posix] [-i] [-u] [-x] [--] SCRIPT [ARGS...]
    \\       rush --help
    \\       rush --version
    \\
;

const EvalSourceOptions = struct {
    state_options: shell.state.Options,
    arg_zero: []const u8,
    positionals: []const []const u8,
};

pub fn run(
    root_allocator: std.mem.Allocator,
    process_allocator: std.mem.Allocator,
    init: std.process.Init.Minimal,
) !u8 {
    var real_host: host.RealHost = .{};

    const args = try init.args.toSlice(process_allocator);
    const invocation = shell.invocation.parse(args) catch {
        try real_host.writeAll(.stderr, usage);
        return 2;
    };

    switch (invocation) {
        .help => {
            try real_host.writeAll(.stdout, usage);
            return 0;
        },
        .version => {
            try real_host.writeAll(.stdout, "rush " ++ build_config.version ++ "\n");
            return 0;
        },
        .interactive => |interactive_invocation| {
            var threaded_io: std.Io.Threaded = .init(root_allocator, .{
                .argv0 = .init(init.args),
                .environ = init.environ,
            });
            defer threaded_io.deinit();
            return interactive.run(process_allocator, real_host, threaded_io.io(), init.environ.block.view().slice, .{
                .state_options = interactive_invocation.options,
                .arg_zero = interactive_invocation.arg_zero,
                .positionals = &.{},
                .login = interactive_invocation.login,
                .forced_interactive = interactive_invocation.forced_interactive,
            });
        },
        .command_string => |command| {
            const src: shell.source.Source = .{
                .id = 1,
                .kind = .command_string,
                .name = command.arg_zero,
                .text = command.script,
            };
            return evalSource(process_allocator, real_host, init.environ.block.view().slice, .{
                .state_options = command.options,
                .arg_zero = command.arg_zero,
                .positionals = command.positionals,
            }, src);
        },
        .script_file => |script| {
            const text = file_util.readFileAlloc(process_allocator, &real_host, script.path) catch {
                try real_host.writeAll(.stderr, "rush: cannot read script file\n");
                return 2;
            };
            const src: shell.source.Source = .{
                .id = 1,
                .kind = .script_file,
                .name = script.path,
                .text = text,
            };
            return evalSource(process_allocator, real_host, init.environ.block.view().slice, .{
                .state_options = script.options,
                .arg_zero = script.path,
                .positionals = script.positionals,
            }, src);
        },
    }
}

fn evalSource(
    allocator: std.mem.Allocator,
    real_host: host.RealHost,
    env: []const [*:0]const u8,
    options: EvalSourceOptions,
    src: shell.source.Source,
) !u8 {
    const initial_pwd = try real_host.currentDir(allocator);
    var sh = RushShell.init(allocator, real_host, .{
        .state = options.state_options,
        .env = env,
        .arg_zero = options.arg_zero,
        .positionals = options.positionals,
        .initial_pwd = initial_pwd,
    });
    defer sh.deinit();
    sh.setFunctionAutoload(autoloadRushFunction);

    const evaluated = sh.evalSource(src) catch |err| {
        // Parse errors already produced a positioned syntax diagnostic.
        if (!shell.parser.isParseError(err)) try sh.host.writeAll(.stderr, "rush: shell error\n");
        return 2;
    };
    return shell.eval.runExitTrap(&sh, evaluated.status) catch |err| {
        if (!shell.parser.isParseError(err)) try sh.host.writeAll(.stderr, "rush: shell error\n");
        return 2;
    };
}

fn autoloadRushFunction(sh: *RushShell, name: []const u8) !bool {
    return function_autoload.autoload(sh, name);
}

test {
    std.testing.refAllDecls(@This());
}
