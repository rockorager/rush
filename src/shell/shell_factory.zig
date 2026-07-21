//! Owning shell instance parameterized by a concrete Host type.

const std = @import("std");

const ast = @import("ast.zig");
const builtin = @import("builtin.zig");
const eval = @import("eval.zig");
const history = @import("../history.zig");
const host_mod = @import("../host.zig");
const lexer = @import("lexer.zig");
const memory = @import("memory.zig");
const parser = @import("parser.zig");
const result = @import("result.zig");
const source = @import("source.zig");
const state = @import("state.zig");

pub const InitOptions = struct {
    state: state.Options = .{},
    env: []const [*:0]const u8 = &.{},
    arg_zero: []const u8 = "rush",
    positionals: []const []const u8 = &.{},
    initial_pwd: ?[]const u8 = null,
};

pub fn Shell(comptime Host: type) type {
    return ShellWithBuiltins(Host, builtin.default_registry);
}

pub fn ShellWithBuiltins(comptime Host: type, comptime builtin_registry: builtin.Registry) type {
    return struct {
        allocator: std.mem.Allocator,
        host: Host,
        env: []const [*:0]const u8,
        exec_envp_cache: ?[:null]const ?[*:0]const u8 = null,
        state: state.State,
        extensions: builtin_registry.ExtensionState,
        arenas: memory.Arenas,
        command_history: ?history.CommandHistory = null,
        function_autoload: ?*const fn (*Self, []const u8) anyerror!bool = null,
        autoloading_function: ?[]const u8 = null,
        directory_change_context: ?*anyopaque = null,
        directory_change_callback: ?*const fn (*anyopaque, []const u8, []const u8) void = null,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, host: Host, options: InitOptions) Self {
            var shell: Self = .{
                .allocator = allocator,
                .host = host,
                .env = options.env,
                .state = state.State.init(allocator, options.state),
                .extensions = builtin_registry.ExtensionState.init(allocator),
                .arenas = memory.Arenas.init(allocator),
            };
            shell.state.putVariable(.{ .name = "PS4", .value = "+ " }) catch unreachable;
            shell.state.putVariable(.{ .name = "IFS", .value = " \t\n" }) catch unreachable;
            if (options.initial_pwd) |pwd| {
                std.debug.assert(pwd.len != 0 and pwd[0] == '/');
                shell.state.putVariable(.{ .name = "PWD", .value = pwd, .exported = true }) catch unreachable;
            }
            if (comptime @hasDecl(Host, "wallTimeNs")) shell.state.resetStartTime(shell.host.wallTimeNs());
            shell.state.arg_zero = options.arg_zero;
            shell.state.positionals = options.positionals;
            return shell;
        }

        pub fn deinit(self: *Self) void {
            if (self.exec_envp_cache) |envp| self.allocator.free(envp);
            self.arenas.deinit();
            self.extensions.deinit();
            self.state.deinit();
            self.* = undefined;
        }

        pub fn execEnvp(self: *Self) ![:null]const ?[*:0]const u8 {
            if (self.exec_envp_cache) |envp| return envp;

            const envp = try self.allocator.allocSentinel(?[*:0]const u8, self.env.len, null);
            for (self.env, 0..) |entry, index| envp[index] = entry;
            self.exec_envp_cache = envp;
            return envp;
        }

        pub fn astAllocator(self: *Self) std.mem.Allocator {
            return self.arenas.ast.allocator();
        }

        pub fn scratchAllocator(self: *Self) std.mem.Allocator {
            return self.arenas.scratchAllocator();
        }

        pub fn lookupBuiltin(self: *Self, name: []const u8) ?builtin.Definition {
            const definition = builtin_registry.lookup(name) orelse return null;
            if (!builtin.availableInMode(definition, self.state.options.mode)) return null;
            return definition;
        }

        pub fn evalExtensionBuiltin(
            self: *Self,
            definition: builtin.Definition,
            args: []const []const u8,
        ) !result.EvalResult {
            return self.extensions.eval(self, definition, args);
        }

        pub fn setFunctionAutoload(self: *Self, autoload: *const fn (*Self, []const u8) anyerror!bool) void {
            self.function_autoload = autoload;
        }

        pub fn setCommandHistory(self: *Self, command_history: history.CommandHistory) void {
            self.command_history = command_history;
        }

        pub fn setDirectoryChangeCallback(
            self: *Self,
            context: *anyopaque,
            callback: *const fn (*anyopaque, []const u8, []const u8) void,
        ) void {
            self.directory_change_context = context;
            self.directory_change_callback = callback;
        }

        pub fn notifyDirectoryChange(self: *Self, old_pwd: []const u8, new_pwd: []const u8) void {
            if (std.mem.eql(u8, old_pwd, new_pwd)) return;
            const callback = self.directory_change_callback orelse return;
            const context = self.directory_change_context orelse return;
            if (self.state.shell_pid) |shell_pid| {
                if (comptime @hasDecl(Host, "currentProcessId")) {
                    if (self.host.currentProcessId() != shell_pid) return;
                }
            }
            callback(context, old_pwd, new_pwd);
        }

        pub fn tryAutoloadFunction(self: *Self, name: []const u8) !bool {
            std.debug.assert(name.len != 0);
            if (self.state.options.mode == .posix) return false;
            const autoload = self.function_autoload orelse return false;
            if (self.state.isFunctionAutoloadSuppressed(name)) return false;
            if (self.state.isFunctionAutoloadMissed(name)) return false;
            if (self.autoloading_function) |loading| if (std.mem.eql(u8, loading, name)) return false;

            const previous = self.autoloading_function;
            self.autoloading_function = name;
            defer self.autoloading_function = previous;
            return autoload(self, name);
        }

        pub fn resetForTopLevelCommand(self: *Self) void {
            self.arenas.resetForTopLevelCommand();
        }

        pub fn beginScratchScope(self: *Self) !memory.ScratchScope {
            return self.arenas.beginScratchScope();
        }

        pub fn evalSource(self: *Self, src: source.Source) !result.EvalResult {
            return self.evalSourceWithReset(src, true);
        }

        pub fn evalSourceNested(self: *Self, src: source.Source) !result.EvalResult {
            return self.evalSourceWithReset(src, false);
        }

        /// Evaluates the source one complete command at a time, so each
        /// command runs before later text is parsed. Commands that mutate
        /// alias state therefore affect the lexing of every following
        /// command, with no heuristics about which sources need it.
        fn evalSourceWithReset(self: *Self, src: source.Source, reset_chunks: bool) !result.EvalResult {
            src.validate();
            const previous_root_kind = self.state.root_source_kind;
            const set_root_source = previous_root_kind == null;
            if (set_root_source) {
                self.state.root_source_kind = src.kind;
            }
            defer if (set_root_source) {
                self.state.root_source_kind = previous_root_kind;
            };
            const previous_source_name = self.state.current_source_name;
            self.state.current_source_name = bashSourceName(src);
            defer self.state.current_source_name = previous_source_name;

            if (reset_chunks) self.resetForTopLevelCommand();
            if (src.text.len == 0) return .{};

            const ast_allocator = self.astAllocator();
            const tokens = try lexer.lex(ast_allocator, src);
            var incremental = parser.Incremental.init(ast_allocator, src, tokens, self.state);
            var boundaries_failed = false;

            var start: usize = 0;
            var last: result.EvalResult = .{};
            while (start < src.text.len) {
                var end: usize = undefined;
                var direct_program: ?ast.Program = null;
                if (boundaries_failed) {
                    end = src.text.len;
                } else if (incremental.next()) |maybe_program| {
                    const program = maybe_program orelse break;
                    direct_program = program;
                    end = incremental.nextOffset();
                } else |err| {
                    // Unexpanded text may only parse after alias expansion
                    // (an alias value can open a construct); retry the rest
                    // of the input through the alias-aware path.
                    if (!self.aliasesMayRewrite()) {
                        self.reportParseFailure(err, incremental.failure(), 0);
                        return err;
                    }
                    boundaries_failed = true;
                    end = src.text.len;
                }

                const evaluated = if (direct_program != null and !self.aliasesMayRewrite())
                    try self.evalParsedProgram(src.kind, direct_program.?)
                else
                    try self.evalAliasAwareCommand(src, &incremental, &boundaries_failed, start, &end);

                last = evaluated;
                if (last.flow != .normal) {
                    if ((self.state.options.interactive or
                        (self.state.options.mode == .bash and !self.state.options.errexit)) and
                        last.flow == .fatal)
                    {
                        last.flow = .normal;
                        self.state.last_status = last.status;
                    } else return last;
                }
                start = end;
            }
            return last;
        }

        /// Evaluates one command's original text through the alias-rewriting
        /// path, extending the chunk to the next command boundary when alias
        /// expansion leaves it incomplete (an alias value can open a
        /// construct that later lines close).
        fn evalAliasAwareCommand(
            self: *Self,
            src: source.Source,
            incremental: *parser.Incremental,
            boundaries_failed: *bool,
            start: usize,
            end: *usize,
        ) !result.EvalResult {
            while (true) {
                const require_complete = end.* < src.text.len;
                var failure: ?parser.Failure = null;
                const chunk = src.text[start..end.*];
                return self.evalSourceChunk(src, chunk, require_complete, &failure) catch |err| switch (err) {
                    error.ExpectedCommand,
                    error.ExpectedRedirectionTarget,
                    error.IncompleteHereDoc,
                    error.UnclosedCommandSubstitution,
                    error.UnclosedQuote,
                    error.UnexpectedToken,
                    => {
                        if (end.* >= src.text.len) {
                            self.reportParseFailure(err, failure, lineOffset(src.text, start));
                            return err;
                        }
                        end.* = nextBoundaryEnd(src, incremental, boundaries_failed);
                        continue;
                    },
                    else => return err,
                };
            }
        }

        fn evalSourceChunk(
            self: *Self,
            src: source.Source,
            text: []const u8,
            require_complete_here_docs: bool,
            failure: *?parser.Failure,
        ) !result.EvalResult {
            const chunk_src: source.Source = .{ .id = src.id, .kind = src.kind, .name = src.name, .text = text };

            const ast_allocator = self.astAllocator();
            const lexed = try lexer.lexWithAliasesSource(ast_allocator, chunk_src, self.state);
            const program = try parser.parseWithAliasesAndOptions(
                ast_allocator,
                lexed.source,
                lexed.tokens,
                self.state,
                .{ .require_complete_here_docs = require_complete_here_docs, .failure = failure },
            );
            program.validate();
            return self.evalParsedProgram(src.kind, program);
        }

        /// Advances Bash's command number only after an interactive command
        /// has parsed successfully and immediately before it begins executing.
        fn evalParsedProgram(
            self: *Self,
            source_kind: source.SourceKind,
            program: ast.Program,
        ) !result.EvalResult {
            if (source_kind == .interactive) self.state.prompt_command_number +|= 1;
            return eval.evalProgram(Host, self, program);
        }

        /// Writes a positioned syntax diagnostic in the same style as the
        /// evaluator's expansion diagnostics. The error still propagates to
        /// the caller, which decides whether the shell exits.
        fn reportParseFailure(self: *Self, err: anyerror, failure: ?parser.Failure, line_offset: usize) void {
            std.debug.assert(parser.isParseError(err));
            const stream_offset = line_offset + self.state.diagnostic_line_offset;
            const line = if (failure) |value| value.line + stream_offset else stream_offset + 1;
            const near = if (failure) |value| value.near else null;

            const message = message: {
                const allocator = self.astAllocator();
                break :message switch (err) {
                    error.UnclosedQuote => std.fmt.allocPrint(
                        allocator,
                        "{}: syntax error: unterminated quoted string\n",
                        .{line},
                    ),
                    error.UnclosedCommandSubstitution => std.fmt.allocPrint(
                        allocator,
                        "{}: syntax error: unterminated command substitution\n",
                        .{line},
                    ),
                    error.IncompleteHereDoc => std.fmt.allocPrint(
                        allocator,
                        "{}: syntax error: here-document missing terminating delimiter\n",
                        .{line},
                    ),
                    error.InvalidParameterExpansion => std.fmt.allocPrint(
                        allocator,
                        "{}: syntax error: bad substitution\n",
                        .{line},
                    ),
                    else => if (near) |text|
                        std.fmt.allocPrint(allocator, "{}: syntax error: unexpected '{s}'\n", .{ line, text })
                    else
                        std.fmt.allocPrint(allocator, "{}: syntax error: unexpected end of input\n", .{line}),
                } catch return;
            };
            // ziglint-ignore: Z026 best-effort diagnostic; the parse error still propagates
            self.host.writeAll(.stderr, message) catch {};
        }

        fn aliasesMayRewrite(self: *Self) bool {
            return self.state.aliases.count() != 0 and lexer.aliasesEnabled(self.state);
        }
    };
}

fn bashSourceName(src: source.Source) []const u8 {
    return switch (src.kind) {
        .command_string => "environment",
        else => src.name,
    };
}

/// Number of lines before `offset`, for translating chunk-relative parse
/// failure lines into source lines.
fn lineOffset(text: []const u8, offset: usize) usize {
    std.debug.assert(offset <= text.len);
    return std.mem.count(u8, text[0..offset], "\n");
}

fn nextBoundaryEnd(
    src: source.Source,
    incremental: *parser.Incremental,
    boundaries_failed: *bool,
) usize {
    if (boundaries_failed.*) return src.text.len;
    const maybe_program = incremental.next() catch {
        boundaries_failed.* = true;
        return src.text.len;
    };
    if (maybe_program == null) return src.text.len;
    return incremental.nextOffset();
}

test "Shell caches exec environment pointer array" {
    const TestHost = struct {};
    const env = [_][*:0]const u8{ "A=1", "B=2" };

    var shell = Shell(TestHost).init(std.testing.allocator, .{}, .{ .env = &env });
    defer shell.deinit();

    const first = try shell.execEnvp();
    const second = try shell.execEnvp();

    try std.testing.expectEqual(first.ptr, second.ptr);
    try std.testing.expectEqualStrings("A=1", std.mem.span(first[0].?));
    try std.testing.expectEqualStrings("B=2", std.mem.span(first[1].?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), first[2]);
}

test "Shell initializes IFS from the shell default instead of the environment" {
    const TestHost = struct {};
    const env = [_][*:0]const u8{"IFS=abc"};

    var shell = Shell(TestHost).init(std.testing.allocator, .{}, .{ .env = &env });
    defer shell.deinit();

    try std.testing.expectEqualStrings(" \t\n", shell.state.getVariable("IFS").?.value);
}

test "Shell initializes exported PWD instead of preserving a stale environment value" {
    const TestHost = struct {};
    const env = [_][*:0]const u8{"PWD=/home/tim"};

    var shell = Shell(TestHost).init(std.testing.allocator, .{}, .{
        .env = &env,
        .initial_pwd = "/home/tim/repos",
    });
    defer shell.deinit();

    const pwd = shell.state.getVariable("PWD").?;
    try std.testing.expectEqualStrings("/home/tim/repos", pwd.value);
    try std.testing.expect(pwd.exported);
}

test "Shell counts parsed interactive commands at the evaluation boundary" {
    const TestHost = struct {
        fn writeAll(_: @This(), _: host_mod.Fd, _: []const u8) !void {}
    };
    var shell = Shell(TestHost).init(std.testing.allocator, .{}, .{});
    defer shell.deinit();

    const malformed_src: source.Source = .{
        .id = 1,
        .kind = .interactive,
        .name = "interactive",
        .text = ")",
    };
    try std.testing.expectError(error.ExpectedCommand, shell.evalSource(malformed_src));
    try std.testing.expectEqual(@as(u64, 1), shell.state.prompt_command_number);

    const interactive_src: source.Source = .{
        .id = 2,
        .kind = .interactive,
        .name = "interactive",
        .text = "value=1",
    };
    _ = try shell.evalSource(interactive_src);
    try std.testing.expectEqual(@as(u64, 2), shell.state.prompt_command_number);

    const nested_src: source.Source = .{
        .id = 3,
        .kind = .command_string,
        .name = "nested",
        .text = "value=2",
    };
    _ = try shell.evalSourceNested(nested_src);
    try std.testing.expectEqual(@as(u64, 2), shell.state.prompt_command_number);
}

test "Shell parameter-only expansion preserves non-parameter substitutions" {
    var shell = Shell(host_mod.RealHost).init(std.testing.allocator, .{}, .{});
    defer shell.deinit();
    try shell.state.putVariable(.{ .name = "USER", .value = "rush-user" });

    const scratch = try shell.beginScratchScope();
    defer scratch.end();
    const expanded = try eval.expandParametersScalar(
        &shell,
        "'$USER':${MISSING:-$USER}:$(printf '$USER'):`printf '$USER'`:$((1 + $USER)):$'$USER'",
    );

    try std.testing.expectEqualStrings(
        "'rush-user':rush-user:$(printf '$USER'):`printf '$USER'`:$((1 + $USER)):$'$USER'",
        expanded,
    );
}

test "ShellWithBuiltins uses the supplied compile-time builtin registry" {
    const TestHost = struct {};

    var shell = ShellWithBuiltins(TestHost, builtin.core_registry).init(std.testing.allocator, .{}, .{});
    defer shell.deinit();

    try std.testing.expect(shell.lookupBuiltin("printf") != null);
    try std.testing.expect(shell.lookupBuiltin("history") != null);
    try std.testing.expectEqual(@as(?builtin.Definition, null), shell.lookupBuiltin("abbr"));

    shell.state.options.mode = .posix;
    try std.testing.expect(shell.lookupBuiltin("printf") != null);
    try std.testing.expectEqual(@as(?builtin.Definition, null), shell.lookupBuiltin("history"));
}

test "Shell directory change callback reports only current-shell changes" {
    const TestHost = struct {
        pub const Self = @This();

        pid: i32,

        pub fn currentProcessId(self: Self) i32 {
            return self.pid;
        }
    };
    const CallbackState = struct {
        const Self = @This();

        count: usize = 0,
        old_pwd: []const u8 = "",
        new_pwd: []const u8 = "",

        fn callback(context: *anyopaque, old_pwd: []const u8, new_pwd: []const u8) void {
            const callback_state: *Self = @ptrCast(@alignCast(context));
            callback_state.count += 1;
            callback_state.old_pwd = old_pwd;
            callback_state.new_pwd = new_pwd;
        }
    };

    var callback_state: CallbackState = .{};
    var sh = Shell(TestHost).init(std.testing.allocator, .{ .pid = 42 }, .{});
    defer sh.deinit();
    sh.setDirectoryChangeCallback(&callback_state, CallbackState.callback);

    sh.notifyDirectoryChange("/old", "/new");
    try std.testing.expectEqual(@as(usize, 1), callback_state.count);
    try std.testing.expectEqualStrings("/old", callback_state.old_pwd);
    try std.testing.expectEqualStrings("/new", callback_state.new_pwd);

    sh.notifyDirectoryChange("/new", "/new");
    try std.testing.expectEqual(@as(usize, 1), callback_state.count);

    sh.state.shell_pid = 7;
    sh.notifyDirectoryChange("/new", "/other");
    try std.testing.expectEqual(@as(usize, 1), callback_state.count);
}
