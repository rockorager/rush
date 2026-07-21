//! Minimal ZON-driven shell conformance harness.

const std = @import("std");

const Mode = enum {
    posix,
    bash,
};

const Suite = struct {
    name: []const u8,
    mode: Mode = .posix,
    cases: []const Case,
};

const Case = struct {
    name: []const u8,
    shell_args: []const []const u8 = &.{},
    script: []const u8,
    stdin: ?[]const u8 = null,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    stderr_match: BytesExpectation = .exact,
    status: u8 = 0,
    status_match: StatusExpectation = .exact,
    skip: ?[]const u8 = null,
    skip_rush: ?[]const u8 = null,
};

const BytesExpectation = enum {
    exact,
    any,
    nonempty,
};

const StatusExpectation = enum {
    exact,
    nonzero,
};

const Config = struct {
    rush_path: ?[]const u8,
    shell: ?[]const u8,
    shell_args: []const []const u8,
    mode: Mode,
    interactive: bool,
    files: []const []const u8,
    print_diff: bool,
    color_diff: bool,
    case_filter: ?[]const u8,
    environ_map: ?*const std.process.Environ.Map = null,
};

const DiscoveredFiles = struct {
    files: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *DiscoveredFiles, allocator: std.mem.Allocator) void {
        for (self.files.items) |file| allocator.free(file);
        self.files.deinit(allocator);
        self.* = undefined;
    }
};

const TempRoot = struct {
    path: []const u8,
    dir: std.Io.Dir,
    environ_map: std.process.Environ.Map,

    fn deinit(self: *TempRoot, allocator: std.mem.Allocator, io: std.Io) void {
        self.environ_map.deinit();
        self.dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, self.path) catch |err| {
            std.debug.print("conformance: failed to remove temporary directory {s}: {s}\n", .{
                self.path,
                @errorName(err),
            });
        };
        allocator.free(self.path);
        self.* = undefined;
    }
};

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    status: u8,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

const RunStats = struct {
    failed: usize = 0,
    skipped: usize = 0,

    fn add(self: *RunStats, other: RunStats) void {
        self.failed += other.failed;
        self.skipped += other.skipped;
    }
};

const CaseResult = enum {
    passed,
    failed,
    skipped,
};

const Progress = struct {
    root_node: std.Progress.Node,
    completed_cases: usize = 0,

    fn init(io: std.Io, case_count: usize) Progress {
        return .{ .root_node = std.Progress.start(io, .{
            .root_name = "Conformance",
            .initial_delay_ns = .fromMilliseconds(0),
            .estimated_total_items = case_count,
        }) };
    }

    fn deinit(self: Progress) void {
        self.root_node.end();
    }

    fn startFile(self: Progress, path: []const u8, suite_name: []const u8, case_count: usize) std.Progress.Node {
        const name = if (suite_name.len == 0) std.fs.path.stem(path) else suite_name;
        return self.root_node.start(name, case_count);
    }

    fn finishFile(self: Progress, file_node: std.Progress.Node) void {
        file_node.end();
        self.root_node.setCompletedItems(self.completed_cases);
    }

    fn startCase(_: Progress, file_node: std.Progress.Node, case_name: []const u8) std.Progress.Node {
        return file_node.start(case_name, 0);
    }

    fn completeCase(self: *Progress) void {
        self.completed_cases += 1;
        self.root_node.setCompletedItems(self.completed_cases);
    }
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const parsed_config = (try parseArgs(allocator, args)) orelse {
        try writeUsage(init.io);
        return 2;
    };
    defer allocator.free(parsed_config.shell_args);
    const rush_path = if (parsed_config.rush_path) |path| try resolvePath(allocator, init.io, path) else null;
    defer if (rush_path) |path| allocator.free(path);
    const shell = if (parsed_config.shell) |path| try resolveCommandPath(allocator, init.io, path) else null;
    defer if (shell) |path| allocator.free(path);
    var discovered_files: DiscoveredFiles = .{};
    defer discovered_files.deinit(allocator);
    const files = if (parsed_config.files.len == 0) files: {
        try discoverSuiteFiles(allocator, init.io, parsed_config, &discovered_files);
        break :files discovered_files.files.items;
    } else parsed_config.files;
    const config: Config = .{
        .rush_path = rush_path,
        .shell = shell,
        .shell_args = parsed_config.shell_args,
        .mode = parsed_config.mode,
        .interactive = parsed_config.interactive,
        .files = files,
        .print_diff = parsed_config.print_diff or parsed_config.case_filter != null,
        .color_diff = std.Io.File.stderr().isTty(init.io) catch false,
        .case_filter = parsed_config.case_filter,
        .environ_map = init.environ_map,
    };
    if (config.files.len == 0) {
        std.debug.print("conformance: no suite files found\n", .{});
        return 2;
    }

    var stats: RunStats = .{};
    const case_count = try countCases(allocator, init.io, config);
    if (case_count == 0) {
        if (config.case_filter) |case_filter| {
            std.debug.print("conformance: no case names matched '{s}'\n", .{case_filter});
        } else {
            std.debug.print("conformance: no cases found\n", .{});
        }
        return 2;
    }
    const target_name = try targetNameAlloc(allocator, config);
    defer allocator.free(target_name);
    var progress = Progress.init(init.io, case_count);
    errdefer progress.deinit();
    for (config.files) |path| {
        stats.add(try runSuiteFile(allocator, init.io, config, path, &progress));
    }
    progress.deinit();

    if (stats.failed != 0) {
        std.debug.print(
            "conformance: failed {d}/{d} case(s), skipped {d} from {d} file(s) against {s}\n",
            .{ stats.failed, case_count, stats.skipped, config.files.len, target_name },
        );
        return 1;
    }
    const passed = case_count - stats.skipped;
    if (stats.skipped == 0) {
        std.debug.print(
            "conformance: passed {d} case(s) from {d} file(s) against {s}\n",
            .{ passed, config.files.len, target_name },
        );
    } else {
        std.debug.print(
            "conformance: passed {d} case(s), skipped {d} from {d} file(s) against {s}\n",
            .{ passed, stats.skipped, config.files.len, target_name },
        );
    }
    return 0;
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !?Config {
    if (args.len < 4) return null;
    var rush_path: ?[]const u8 = null;
    var shell: ?[]const u8 = null;
    var shell_args: std.ArrayList([]const u8) = .empty;
    defer shell_args.deinit(allocator);
    var mode: ?Mode = null;
    var interactive = false;
    var print_diff = false;
    var case_filter: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--rush")) {
            index += 1;
            if (index >= args.len) return null;
            rush_path = args[index];
        } else if (std.mem.eql(u8, arg, "--shell")) {
            index += 1;
            if (index >= args.len) return null;
            shell = args[index];
        } else if (std.mem.eql(u8, arg, "--shell-arg")) {
            index += 1;
            if (index >= args.len) return null;
            try shell_args.append(allocator, args[index]);
        } else if (std.mem.eql(u8, arg, "--mode")) {
            index += 1;
            if (index >= args.len) return null;
            mode = parseMode(args[index]) orelse return null;
        } else if (std.mem.eql(u8, arg, "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "--diff")) {
            print_diff = true;
        } else if (std.mem.eql(u8, arg, "--case")) {
            index += 1;
            if (index >= args.len) return null;
            case_filter = args[index];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return null;
        } else {
            break;
        }
        index += 1;
    }
    if ((rush_path == null) == (shell == null)) return null;
    const parsed_mode = mode orelse return null;
    return .{
        .rush_path = rush_path,
        .shell = shell,
        .shell_args = try shell_args.toOwnedSlice(allocator),
        .mode = parsed_mode,
        .interactive = interactive,
        .files = args[index..],
        .print_diff = print_diff,
        .color_diff = false,
        .case_filter = case_filter,
    };
}

fn parseMode(text: []const u8) ?Mode {
    if (std.mem.eql(u8, text, "posix")) return .posix;
    if (std.mem.eql(u8, text, "bash")) return .bash;
    return null;
}

fn resolvePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    if (std.Io.Dir.path.isAbsolute(path)) return allocator.dupeZ(u8, path);
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
}

fn resolveCommandPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, path, '/') == null) return allocator.dupeZ(u8, path);
    return resolvePath(allocator, io, path);
}

fn discoverSuiteFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    discovered_files: *DiscoveredFiles,
) !void {
    const dir_path = suiteDir(config.mode, config.interactive);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        errdefer allocator.free(file_path);
        try discovered_files.files.append(allocator, file_path);
    }

    std.mem.sort([]const u8, discovered_files.files.items, {}, stringLessThan);
}

fn suiteDir(mode: Mode, interactive: bool) []const u8 {
    if (interactive) {
        return switch (mode) {
            .posix => "tests/interactive/posix",
            .bash => "tests/interactive/bash",
        };
    }
    return switch (mode) {
        .posix => "tests/posix",
        .bash => "tests/bash",
    };
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn countCases(allocator: std.mem.Allocator, io: std.Io, config: Config) !usize {
    var case_count: usize = 0;
    for (config.files) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        defer allocator.free(source);
        const source_z = try allocator.dupeZ(u8, source);
        defer allocator.free(source_z);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const suite = try std.zon.parse.fromSliceAlloc(Suite, arena.allocator(), source_z, null, .{});
        std.debug.assert(suite.mode == config.mode);
        case_count += countMatchingCases(config, suite);
    }
    return case_count;
}

fn countMatchingCases(config: Config, suite: Suite) usize {
    var case_count: usize = 0;
    for (suite.cases) |case| {
        if (caseMatches(config, case.name)) case_count += 1;
    }
    return case_count;
}

fn caseMatches(config: Config, case_name: []const u8) bool {
    const case_filter = config.case_filter orelse return true;
    return std.mem.indexOf(u8, case_name, case_filter) != null;
}

fn runSuiteFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    path: []const u8,
    progress: *Progress,
) !RunStats {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(source);
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const suite = try std.zon.parse.fromSliceAlloc(Suite, arena.allocator(), source_z, null, .{});
    std.debug.assert(suite.mode == config.mode);
    const matching_cases = countMatchingCases(config, suite);
    if (matching_cases == 0) return .{};

    const file_node = progress.startFile(path, suite.name, matching_cases);
    defer progress.finishFile(file_node);

    var temp_root = try createTempRoot(allocator, io, config.environ_map.?);
    defer temp_root.deinit(allocator, io);

    var stats: RunStats = .{};
    for (suite.cases, 0..) |case, case_index| {
        if (!caseMatches(config, case.name)) continue;
        switch (try runCase(
            allocator,
            io,
            config,
            path,
            file_node,
            suite.name,
            &temp_root,
            case,
            case_index,
            progress,
        )) {
            .passed => {},
            .failed => stats.failed += 1,
            .skipped => stats.skipped += 1,
        }
    }
    return stats;
}

fn createTempRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_environ_map: *const std.process.Environ.Map,
) !TempRoot {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ".zig-cache");

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        const random = std.mem.readInt(u64, &random_bytes, .little);
        const path = try std.fmt.allocPrint(
            allocator,
            ".zig-cache/rush-conformance-{x}",
            .{random},
        );
        errdefer allocator.free(path);

        cwd.createDir(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        // ziglint-ignore: Z026 best-effort cleanup after failed temporary-environment setup
        errdefer cwd.deleteTree(io, path) catch {};

        var environ_map = try parent_environ_map.clone(allocator);
        errdefer environ_map.deinit();
        try environ_map.put("HOME", ".");
        try environ_map.put("XDG_CONFIG_HOME", ".");
        try environ_map.put("XDG_STATE_HOME", ".");
        try environ_map.put("HISTFILE", ".bash_history");
        _ = environ_map.swapRemove("BASH_ENV");
        _ = environ_map.swapRemove("ENV");
        _ = environ_map.swapRemove("PROMPT_COMMAND");
        _ = environ_map.swapRemove("PS1");

        return .{
            .path = path,
            .dir = try cwd.openDir(io, path, .{}),
            .environ_map = environ_map,
        };
    }

    return error.TemporaryNameCollision;
}

fn runCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    path: []const u8,
    file_node: std.Progress.Node,
    suite_name: []const u8,
    temp_root: *TempRoot,
    case: Case,
    case_index: usize,
    progress: *Progress,
) !CaseResult {
    const case_node = progress.startCase(file_node, case.name);
    defer case_node.end();
    if (caseSkipReason(case, config)) |reason| {
        if (config.print_diff) printSkipHeader(path, suite_name, case.name, reason);
        progress.completeCase();
        return .skipped;
    }

    const target = try runTarget(allocator, io, temp_root, case_index, config, case);
    defer target.deinit(allocator);
    const target_name = try targetNameAlloc(allocator, config);
    defer allocator.free(target_name);
    const failed = try reportMismatch(
        allocator,
        path,
        suite_name,
        case,
        target_name,
        target,
        config.print_diff,
        config.color_diff,
    );
    progress.completeCase();

    return if (failed) .failed else .passed;
}

fn caseSkipReason(case: Case, config: Config) ?[]const u8 {
    if (case.skip) |reason| return reason;
    if (config.rush_path != null) {
        if (case.skip_rush) |reason| return reason;
    }
    return null;
}

fn targetNameAlloc(allocator: std.mem.Allocator, config: Config) ![]u8 {
    var name: std.Io.Writer.Allocating = .init(allocator);
    errdefer name.deinit();

    if (config.shell) |shell| {
        try name.writer.writeAll(shell);
        for (config.shell_args) |arg| {
            try name.writer.print(" {s}", .{arg});
        }
        if (config.interactive) try name.writer.writeAll(" -i");
    } else {
        try name.writer.writeAll("rush");
        if (config.mode == .posix) try name.writer.writeAll(" --posix");
        if (config.interactive) try name.writer.writeAll(" -i");
    }

    return name.toOwnedSlice();
}

fn runTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_root: *TempRoot,
    case_index: usize,
    config: Config,
    case: Case,
) !RunResult {
    if (config.shell) |shell| {
        var sub_path_buffer: [64]u8 = undefined;
        const sub_path = try std.fmt.bufPrint(&sub_path_buffer, "case-{d}-shell", .{case_index});
        return runGenericShell(allocator, io, temp_root, sub_path, shell, config.shell_args, config.interactive, case);
    }
    return runRush(allocator, io, temp_root, case_index, config, case);
}

fn runRush(
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_root: *TempRoot,
    case_index: usize,
    config: Config,
    case: Case,
) !RunResult {
    var sub_path_buffer: [64]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&sub_path_buffer, "case-{d}-rush", .{case_index});
    var cwd = try temp_root.dir.createDirPathOpen(io, sub_path, .{});
    defer cwd.close(io);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, config.rush_path.?);
    if (config.mode == .posix) try argv.append(allocator, "--posix");
    if (config.interactive) try argv.append(allocator, "-i");
    try argv.appendSlice(allocator, case.shell_args);
    if (case.stdin == null) {
        try argv.append(allocator, "-c");
        try argv.append(allocator, case.script);
    }
    return runCommand(allocator, io, cwd, argv.items, case.stdin, &temp_root.environ_map);
}

fn runGenericShell(
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_root: *TempRoot,
    sub_path: []const u8,
    shell: []const u8,
    shell_args: []const []const u8,
    interactive: bool,
    case: Case,
) !RunResult {
    var cwd = try temp_root.dir.createDirPathOpen(io, sub_path, .{});
    defer cwd.close(io);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, shell);
    try argv.appendSlice(allocator, shell_args);
    if (interactive) try argv.append(allocator, "-i");
    try argv.appendSlice(allocator, case.shell_args);
    if (case.stdin == null) {
        try argv.append(allocator, "-c");
        try argv.append(allocator, case.script);
    }
    var result = try runCommand(allocator, io, cwd, argv.items, case.stdin, &temp_root.environ_map);
    if (interactive) result = try filterInteractiveShellStderr(allocator, result);
    return result;
}

fn runCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    argv: []const []const u8,
    stdin: ?[]const u8,
    environ_map: *const std.process.Environ.Map,
) !RunResult {
    var wrapper_argv: std.ArrayList([]const u8) = .empty;
    defer wrapper_argv.deinit(allocator);
    if (stdin) |input| {
        try wrapper_argv.appendSlice(allocator, &.{
            "/bin/sh",
            "-c",
            \\input=$1; shift; printf '%s' "$input" | "$@"
            ,
            "rush-conformance",
            input,
        });
        try wrapper_argv.appendSlice(allocator, argv);
    }

    const command_argv = if (stdin == null) argv else wrapper_argv.items;
    const result = try std.process.run(allocator, io, .{
        .argv = command_argv,
        .cwd = .{ .dir = cwd },
        .environ_map = environ_map,
    });
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .status = statusFromTerm(result.term),
    };
}

fn filterInteractiveShellStderr(allocator: std.mem.Allocator, result: RunResult) !RunResult {
    var filtered: std.ArrayList(u8) = .empty;
    errdefer filtered.deinit(allocator);

    var start: usize = 0;
    while (start < result.stderr.len) {
        const end = if (std.mem.findScalarPos(u8, result.stderr, start, '\n')) |newline|
            newline + 1
        else
            result.stderr.len;
        const line = result.stderr[start..end];
        if (!interactiveShellWarningLine(line)) try filtered.appendSlice(allocator, line);
        start = end;
    }

    allocator.free(result.stderr);
    return .{
        .stdout = result.stdout,
        .stderr = try filtered.toOwnedSlice(allocator),
        .status = result.status,
    };
}

fn interactiveShellWarningLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "cannot set terminal process group") != null or
        std.mem.indexOf(u8, line, "no job control in this shell") != null or
        std.mem.indexOf(u8, line, "can't access tty; job control turned off") != null;
}

fn statusFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |status| status,
        .signal => |signal| signalStatus(@intFromEnum(signal)),
        .stopped => |signal| signalStatus(@intFromEnum(signal)),
        .unknown => 255,
    };
}

fn signalStatus(signal: u32) u8 {
    const value: u32 = 128 + signal;
    return if (value <= std.math.maxInt(u8)) @intCast(value) else std.math.maxInt(u8);
}

fn reportMismatch(
    allocator: std.mem.Allocator,
    path: []const u8,
    suite_name: []const u8,
    case: Case,
    shell_name: []const u8,
    actual: RunResult,
    print_diff: bool,
    color_diff: bool,
) !bool {
    const stdout_failed = !std.mem.eql(u8, actual.stdout, case.stdout);
    const stderr_failed = !bytesMatch(actual.stderr, case.stderr, case.stderr_match);
    const status_failed = !statusMatches(actual.status, case.status, case.status_match);

    if (!stdout_failed and !stderr_failed and !status_failed) return false;

    if (!print_diff) {
        printFailureHeader(path, suite_name, case.name);
        return true;
    }

    printFailureHeader(path, suite_name, case.name);
    std.debug.print("  target: {s}\n", .{shell_name});
    if (stdout_failed) {
        try printExactBytesMismatch(allocator, "stdout", case.stdout, actual.stdout, color_diff);
    }
    if (stderr_failed) {
        try printBytesExpectationMismatch(
            allocator,
            "stderr",
            case.stderr,
            case.stderr_match,
            actual.stderr,
            color_diff,
        );
    }
    if (status_failed) {
        switch (case.status_match) {
            .exact => std.debug.print(
                "  status mismatch: expected {d}, got {d}\n",
                .{ case.status, actual.status },
            ),
            .nonzero => std.debug.print(
                "  status mismatch: expected nonzero, got {d}\n",
                .{actual.status},
            ),
        }
    }
    return true;
}

fn bytesMatch(actual: []const u8, expected: []const u8, expectation: BytesExpectation) bool {
    return switch (expectation) {
        .exact => std.mem.eql(u8, actual, expected),
        .any => true,
        .nonempty => actual.len != 0,
    };
}

fn statusMatches(actual: u8, expected: u8, expectation: StatusExpectation) bool {
    return switch (expectation) {
        .exact => actual == expected,
        .nonzero => actual != 0,
    };
}

fn printFailureHeader(
    path: []const u8,
    suite_name: []const u8,
    case_name: []const u8,
) void {
    std.debug.print("FAIL {s} › {s} › {s}\n", .{ path, suite_name, case_name });
}

fn printSkipHeader(
    path: []const u8,
    suite_name: []const u8,
    case_name: []const u8,
    reason: []const u8,
) void {
    std.debug.print("SKIP {s} › {s} › {s}: {s}\n", .{ path, suite_name, case_name, reason });
}

fn printBytesExpectationMismatch(
    allocator: std.mem.Allocator,
    stream: []const u8,
    expected: []const u8,
    expectation: BytesExpectation,
    actual: []const u8,
    color_diff: bool,
) !void {
    switch (expectation) {
        .exact => try printExactBytesMismatch(allocator, stream, expected, actual, color_diff),
        .any => {},
        .nonempty => std.debug.print(
            "  {s} mismatch: expected nonempty, got {d} byte(s)\n",
            .{ stream, actual.len },
        ),
    }
}

const DiffLine = struct {
    text: []const u8,
};

fn printExactBytesMismatch(
    allocator: std.mem.Allocator,
    stream: []const u8,
    expected: []const u8,
    actual: []const u8,
    color_diff: bool,
) !void {
    std.debug.print(
        "  {s} mismatch (- expected, + actual):\n  --- expected {s} ({d} byte(s))\n  +++ actual {s} ({d} byte(s))\n",
        .{ stream, stream, expected.len, stream, actual.len },
    );
    try printUnifiedDiff(allocator, expected, actual, color_diff);
}

fn printUnifiedDiff(allocator: std.mem.Allocator, expected: []const u8, actual: []const u8, color_diff: bool) !void {
    const expected_lines = try splitDiffLines(allocator, expected);
    defer allocator.free(expected_lines);
    const actual_lines = try splitDiffLines(allocator, actual);
    defer allocator.free(actual_lines);

    const cell_count = (expected_lines.len + 1) * (actual_lines.len + 1);
    if (cell_count > 200_000) {
        printFullBytesFallback(expected, actual);
        return;
    }

    var lcs = try allocator.alloc(usize, cell_count);
    defer allocator.free(lcs);
    @memset(lcs, 0);

    const width = actual_lines.len + 1;
    var expected_index = expected_lines.len;
    while (expected_index > 0) {
        expected_index -= 1;
        var actual_index = actual_lines.len;
        while (actual_index > 0) {
            actual_index -= 1;
            const cell = expected_index * width + actual_index;
            if (std.mem.eql(u8, expected_lines[expected_index].text, actual_lines[actual_index].text)) {
                lcs[cell] = lcs[(expected_index + 1) * width + actual_index + 1] + 1;
            } else {
                lcs[cell] = @max(
                    lcs[(expected_index + 1) * width + actual_index],
                    lcs[expected_index * width + actual_index + 1],
                );
            }
        }
    }

    std.debug.print("  @@\n", .{});
    expected_index = 0;
    var actual_index: usize = 0;
    while (expected_index < expected_lines.len and actual_index < actual_lines.len) {
        if (std.mem.eql(u8, expected_lines[expected_index].text, actual_lines[actual_index].text)) {
            printDiffLine(' ', expected_lines[expected_index].text, color_diff);
            expected_index += 1;
            actual_index += 1;
        } else if (lcs[(expected_index + 1) * width + actual_index] >=
            lcs[expected_index * width + actual_index + 1])
        {
            printDiffLine('-', expected_lines[expected_index].text, color_diff);
            expected_index += 1;
        } else {
            printDiffLine('+', actual_lines[actual_index].text, color_diff);
            actual_index += 1;
        }
    }
    while (expected_index < expected_lines.len) : (expected_index += 1) {
        printDiffLine('-', expected_lines[expected_index].text, color_diff);
    }
    while (actual_index < actual_lines.len) : (actual_index += 1) {
        printDiffLine('+', actual_lines[actual_index].text, color_diff);
    }

    if (expected.len != 0 and !std.mem.endsWith(u8, expected, "\n")) {
        std.debug.print("  \\ expected has no trailing newline\n", .{});
    }
    if (actual.len != 0 and !std.mem.endsWith(u8, actual, "\n")) {
        std.debug.print("  \\ actual has no trailing newline\n", .{});
    }
}

fn splitDiffLines(allocator: std.mem.Allocator, bytes: []const u8) ![]DiffLine {
    var lines: std.ArrayList(DiffLine) = .empty;
    defer lines.deinit(allocator);

    var start: usize = 0;
    while (start < bytes.len) {
        const end = if (std.mem.findScalarPos(u8, bytes, start, '\n')) |newline| newline else bytes.len;
        try lines.append(allocator, .{ .text = bytes[start..end] });
        start = if (end < bytes.len) end + 1 else end;
    }

    return lines.toOwnedSlice(allocator);
}

fn printDiffLine(prefix: u8, line: []const u8, color_diff: bool) void {
    if (color_diff) {
        switch (prefix) {
            '-' => {
                std.debug.print("  \x1b[31m-{s}\x1b[0m\n", .{line});
                return;
            },
            '+' => {
                std.debug.print("  \x1b[32m+{s}\x1b[0m\n", .{line});
                return;
            },
            else => {},
        }
    }
    std.debug.print("  {c}{s}\n", .{ prefix, line });
}

fn printFullBytesFallback(expected: []const u8, actual: []const u8) void {
    std.debug.print(
        "  @@ output too large for line diff\n  expected:\n{s}\n  actual:\n{s}\n",
        .{ expected, actual },
    );
}

fn writeUsage(io: std.Io) !void {
    const usage =
        \\usage: conformance-harness (--rush PATH | --shell SHELL [--shell-arg ARG...])
        \\                           --mode MODE [--interactive] [--case TEXT] [--diff] [FILE...]
        \\modes: posix, bash
        \\--interactive: discover interactive suites and invoke the target with -i
        \\--case TEXT: run cases whose names contain TEXT; implies --diff
        \\--diff: print unified stdout/stderr diffs for failures
        \\
    ;
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.writeAll(usage);
    try writer.interface.flush();
}
