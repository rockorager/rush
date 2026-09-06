//! CLI invocation dispatch for the Rush executable.

const std = @import("std");

const build_config = @import("build_config");
const extensions = @import("extensions.zig");
const file_util = @import("file_util.zig");
const function_autoload = @import("function_autoload.zig");
const host = @import("host.zig");
const interactive = @import("interactive.zig");
const shell = @import("shell.zig");
const startup = @import("interactive/startup.zig");

const RushShell = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry);

const usage =
    \\usage: rush [--posix] [-l | --login] [OPTIONS] [--] [SCRIPT [ARGS...]]
    \\       rush [--posix] [OPTIONS] -c SCRIPT [NAME [ARGS...]]
    \\       rush [--posix] [OPTIONS] -s [--] [ARGS...]
    \\       rush --help
    \\       rush --version
    \\Options: -i, -/+abCefhmnuvx, -o NAME, +o NAME
    \\Invoking as sh selects POSIX mode.
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

    // Only invocation data belongs in the process arena; shell state must be reclaimable.
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
            var pipe_action: std.posix.Sigaction = undefined;
            std.posix.sigaction(.PIPE, null, &pipe_action);
            var threaded_io: std.Io.Threaded = .init(root_allocator, .{
                .argv0 = .init(init.args),
                .environ = init.environ,
                // RealHost's atomic signal wait requires delivery on the shell
                // thread. Async I/O runs inline; worker threads are not enabled.
                .async_limit = .nothing,
                .concurrent_limit = .nothing,
            });
            defer threaded_io.deinit();
            // Threaded installs a no-op SIGPIPE handler. Shell signal semantics
            // must instead start from the disposition inherited across exec.
            std.posix.sigaction(.PIPE, &pipe_action, null);
            return interactive.run(root_allocator, real_host, threaded_io.io(), init.environ.block.view().slice, .{
                .state_options = interactive_invocation.options,
                .arg_zero = interactive_invocation.arg_zero,
                .positionals = interactive_invocation.positionals,
                .login = interactive_invocation.login,
                .interactive_override = interactive_invocation.interactive_override,
            });
        },
        .command_string => |command| {
            const src: shell.source.Source = .{
                .id = 1,
                .kind = .command_string,
                .name = command.arg_zero,
                .text = command.script,
            };
            return evalSource(root_allocator, real_host, init.environ.block.view().slice, .{
                .state_options = command.options,
                .arg_zero = command.arg_zero,
                .positionals = command.positionals,
            }, src);
        },
        .script_file => |script| {
            // Reclaim intermediate read buffers instead of retaining their
            // growth in the process arena for the entire script execution.
            const text = file_util.readFileAlloc(root_allocator, &real_host, script.path) catch {
                try real_host.writeAll(.stderr, "rush: cannot read script file\n");
                return 2;
            };
            defer root_allocator.free(text);
            const src: shell.source.Source = .{
                .id = 1,
                .kind = .script_file,
                .name = script.path,
                .text = text,
            };
            return evalSource(root_allocator, real_host, init.environ.block.view().slice, .{
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
    const initial_pwd = try real_host.startupPwd(allocator, environmentValue(env, "PWD"));
    defer if (initial_pwd) |pwd| allocator.free(pwd);
    var sh = RushShell.init(allocator, real_host, .{
        .state = options.state_options,
        .env = env,
        .arg_zero = options.arg_zero,
        .positionals = options.positionals,
        .initial_pwd = initial_pwd,
        .initial_pwd_unavailable = initial_pwd == null,
    });
    defer sh.deinit();
    try shell.builtin.initializeSignals(&sh);
    sh.setFunctionAutoload(autoloadRushFunction);

    if (options.state_options.interactive) {
        var source_id = src.id +% 1;
        if (try startup.source(&sh, &source_id, false)) |status| return status;
    }

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

fn environmentValue(env: []const [*:0]const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len != 0);
    for (env) |entry_ptr| {
        const entry = std.mem.span(entry_ptr);
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) {
            return entry[name.len + 1 ..];
        }
    }
    return null;
}

fn autoloadRushFunction(sh: *RushShell, name: []const u8) !bool {
    return function_autoload.autoload(sh, name);
}

test "command evaluation does not allocate shell state from the process arena" {
    // Invocation data may live until exit, but replacing a variable must not
    // consume that arena's capacity on every iteration.
    var process_buffer: [64 * 1024]u8 = undefined;
    var process_allocator = std.heap.FixedBufferAllocator.init(&process_buffer);
    const script =
        \\i=0
        \\while [ "$i" -lt 1000 ]; do
        \\    value=$1
        \\    i=$((i+1))
        \\done
        \\[ "$i" -eq 1000 ] && [ "${#value}" -eq 1024 ]
    ;
    const status = try run(std.testing.allocator, process_allocator.allocator(), .{
        .args = .{ .vector = &.{ "rush", "--posix", "-c", script, "rush", "x" ** 1024 } },
        .environ = .empty,
    });
    try std.testing.expectEqual(@as(u8, 0), status);
}

test "script input does not consume the process arena" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.testing.io, .{
        .sub_path = "script",
        .data = "#" ++ "x" ** (128 * 1024) ++ "\nf() { : \"${x:-ok}\"; }; trap f EXIT\n",
    });
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ ".zig-cache", "tmp", &dir.sub_path, "script" });
    defer std.testing.allocator.free(path);
    var process_buffer: [4096]u8 = undefined;
    var process_allocator = std.heap.FixedBufferAllocator.init(&process_buffer);
    const status = try run(std.testing.allocator, process_allocator.allocator(), .{
        .args = .{ .vector = &.{ "rush", "--posix", path } },
        .environ = .empty,
    });
    try std.testing.expectEqual(@as(u8, 0), status);
}

test {
    std.testing.refAllDecls(@This());
}
