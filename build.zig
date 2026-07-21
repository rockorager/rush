const std = @import("std");
const ziglint = @import("ziglint");

const compile_check_targets = [_][]const u8{
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "x86_64-macos",
    "aarch64-macos",
    "x86_64-freebsd",
    "x86_64-openbsd",
    "x86_64-netbsd",
};

const rush_stack_size = 128 * 1024 * 1024;
const default_config_path = "share/rush/config.rush";
const release_version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = versionString(b);
    const uucode = sharedUucodeModule(b, target, optimize);
    const vaxis = sharedVaxisModule(b, target, optimize, uucode);
    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    }).module("zeit");
    const use_system_sqlite = b.systemIntegrationOption("sqlite3", .{ .default = false });
    const register_as_login_shell = b.option(
        bool,
        "register-shell",
        "Register the installed executable in /etc/shells (default: true)",
    ) orelse true;

    // System config dir, GNU sysconfdir convention: defaults to <prefix>/etc
    // so non-root installs stay self-contained; packagers pass -Dsysconfdir=/etc.
    const sysconfdir = b.option(
        []const u8,
        "sysconfdir",
        "Directory for system-wide configuration (default: <prefix>/etc)",
    ) orelse
        b.getInstallPath(.prefix, "etc");
    const datadir = b.option(
        []const u8,
        "datadir",
        "Directory for read-only data files (default: <prefix>/share)",
    ) orelse
        b.getInstallPath(.prefix, "share");
    const build_config = b.addOptions();
    build_config.addOption([]const u8, "sysconfdir", sysconfdir);
    build_config.addOption([]const u8, "datadir", datadir);
    build_config.addOption([]const u8, "version", version);

    const exe_module = createRushRootModule(
        b,
        target,
        optimize,
        vaxis,
        uucode,
        zeit,
        build_config,
        use_system_sqlite,
        .{ .link_libc = true },
    );
    const exe = b.addExecutable(.{
        .name = "rush",
        .root_module = exe_module,
        .version = std.SemanticVersion.parse(version) catch unreachable,
    });
    exe.stack_size = rush_stack_size;

    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);
    const register_shell = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\shell=$1
        \\shells=/etc/shells
        \\
        \\if [ -f "$shells" ] && grep -Fxq "$shell" "$shells"; then
        \\  exit 0
        \\fi
        \\
        \\if { [ -f "$shells" ] && [ -w "$shells" ]; } || { [ ! -e "$shells" ] && [ -w /etc ]; }; then
        \\  printf '%s\n' "$shell" >>"$shells"
        \\  printf 'registered %s in %s\n' "$shell" "$shells" >&2
        \\else
        \\  printf 'note: %s is not listed in %s\n' "$shell" "$shells" >&2
        \\  printf 'note: rerun install with permission to allow chsh/login-shell use\n' >&2
        \\fi
        ,
        "sh",
        b.getInstallPath(.bin, "rush"),
    });
    register_shell.setName("register rush in /etc/shells");
    register_shell.step.dependOn(&install_exe.step);
    if (register_as_login_shell) b.getInstallStep().dependOn(&register_shell.step);
    b.installDirectory(.{
        .source_dir = b.path("share/rush/completions"),
        .install_dir = .{ .custom = "share/rush/completions" },
        .install_subdir = "",
        .include_extensions = &.{ ".rush", ".json" },
        .exclude_extensions = &.{},
        .blank_extensions = &.{},
    });
    b.installDirectory(.{
        .source_dir = b.path("share/rush/functions"),
        .install_dir = .{ .custom = "share/rush/functions" },
        .install_subdir = "",
        .include_extensions = &.{".rush"},
        .exclude_extensions = &.{},
        .blank_extensions = &.{},
    });
    b.installFile("share/vim/vimfiles/ftdetect/rush.vim", "share/vim/vimfiles/ftdetect/rush.vim");
    b.installFile("share/nvim/site/ftdetect/rush.lua", "share/nvim/site/ftdetect/rush.lua");
    b.installFile("share/man/man1/rush.1", "share/man/man1/rush.1");
    b.installFile("share/man/man5/rush.5", "share/man/man5/rush.5");
    b.installFile(default_config_path, default_config_path);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const test_no_run = b.option(
        bool,
        "test-no-run",
        "Compile unit tests without running the test binary",
    ) orelse false;
    const test_module = createRushRootModule(
        b,
        target,
        optimize,
        vaxis,
        uucode,
        zeit,
        build_config,
        use_system_sqlite,
        .{},
    );
    const exe_tests = b.addTest(.{
        .root_module = test_module,
        .test_runner = .{
            .path = b.path("tests/fd_safe_test_runner.zig"),
            .mode = .simple,
        },
    });
    if (test_no_run) {
        test_step.dependOn(&exe_tests.step);
    } else {
        test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    }

    const conformance_step = b.step("conformance", "Run shell conformance tests");
    addConformanceTests(b, target, optimize, exe, conformance_step);

    const differential_step = b.step("differential", "Run generated differential shell integration tests");
    addDifferentialTests(b, target, optimize, exe, differential_step);

    const compile_check_step = b.step("compile-check", "Compile-check Linux/macOS/BSD targets");
    addCompileChecks(b, compile_check_step, optimize, build_config, use_system_sqlite);

    const ziglint_dep = b.dependency("ziglint", .{ .optimize = .ReleaseFast });
    const lint_step = b.step("lint", "Run ziglint");
    lint_step.dependOn(ziglint.addLint(b, ziglint_dep, &.{
        b.path("build.zig"),
        b.path("fuzz"),
        b.path("src"),
        b.path("tests"),
    }));
}

const RushRootModuleOptions = struct {
    link_libc: bool = false,
};

fn addCompileChecks(
    b: *std.Build,
    compile_check_step: *std.Build.Step,
    optimize: std.builtin.OptimizeMode,
    build_config: *std.Build.Step.Options,
    use_system_sqlite: bool,
) void {
    for (compile_check_targets) |target_name| {
        const target_query = std.Target.Query.parse(.{ .arch_os_abi = target_name }) catch |err|
            std.debug.panic("invalid compile-check target '{s}': {s}", .{ target_name, @errorName(err) });
        const check_target = b.resolveTargetQuery(target_query);
        const check_uucode = sharedUucodeModule(b, check_target, optimize);
        const check_vaxis = sharedVaxisModule(b, check_target, optimize, check_uucode);
        const check_zeit = b.dependency("zeit", .{
            .target = check_target,
            .optimize = optimize,
        }).module("zeit");
        const check_module = createRushRootModule(
            b,
            check_target,
            optimize,
            check_vaxis,
            check_uucode,
            check_zeit,
            build_config,
            use_system_sqlite,
            .{ .link_libc = true },
        );
        const check = b.addExecutable(.{
            .name = b.fmt("rush-{s}", .{target_name}),
            .root_module = check_module,
        });
        check.stack_size = rush_stack_size;
        compile_check_step.dependOn(&check.step);
    }
}

fn addConformanceTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    rush: *std.Build.Step.Compile,
    conformance_step: *std.Build.Step,
) void {
    const harness = b.addExecutable(.{
        .name = "rush-conformance-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/harness.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    if (b.args) |args| {
        if (usesCustomConformanceRunner(args)) {
            const run_posix = b.addRunArtifact(harness);
            run_posix.addArgs(args);
            conformance_step.dependOn(&run_posix.step);

            if (!conformanceArgsSelectInteractive(args) and
                !conformanceArgsHaveSuiteFiles(args))
            {
                const run_interactive = b.addRunArtifact(harness);
                run_interactive.addArgs(args);
                run_interactive.addArg("--interactive");
                conformance_step.dependOn(&run_interactive.step);
            }
        } else {
            const run_posix = b.addRunArtifact(harness);
            run_posix.addArg("--rush");
            run_posix.addArtifactArg(rush);
            run_posix.addArg("--mode");
            run_posix.addArg("posix");
            run_posix.addArgs(args);
            conformance_step.dependOn(&run_posix.step);

            if (!conformanceArgsSelectInteractive(args) and !conformanceArgsHaveSuiteFiles(args)) {
                const run_interactive = b.addRunArtifact(harness);
                run_interactive.addArg("--rush");
                run_interactive.addArtifactArg(rush);
                run_interactive.addArg("--mode");
                run_interactive.addArg("posix");
                run_interactive.addArgs(args);
                run_interactive.addArg("--interactive");
                conformance_step.dependOn(&run_interactive.step);
            }
        }
    } else {
        const run_posix = b.addRunArtifact(harness);
        run_posix.addArg("--rush");
        run_posix.addArtifactArg(rush);
        run_posix.addArg("--mode");
        run_posix.addArg("posix");
        conformance_step.dependOn(&run_posix.step);

        const run_interactive = b.addRunArtifact(harness);
        run_interactive.addArg("--rush");
        run_interactive.addArtifactArg(rush);
        run_interactive.addArg("--mode");
        run_interactive.addArg("posix");
        run_interactive.addArg("--interactive");
        conformance_step.dependOn(&run_interactive.step);

        const run_bash = b.addRunArtifact(harness);
        run_bash.addArg("--rush");
        run_bash.addArtifactArg(rush);
        run_bash.addArg("--mode");
        run_bash.addArg("bash");
        conformance_step.dependOn(&run_bash.step);

        const run_bash_interactive = b.addRunArtifact(harness);
        run_bash_interactive.addArg("--rush");
        run_bash_interactive.addArtifactArg(rush);
        run_bash_interactive.addArg("--mode");
        run_bash_interactive.addArg("bash");
        run_bash_interactive.addArg("--interactive");
        conformance_step.dependOn(&run_bash_interactive.step);
    }
}

fn usesCustomConformanceRunner(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--rush") or std.mem.eql(u8, arg, "--shell")) return true;
    }
    return false;
}

fn conformanceArgsSelectInteractive(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--interactive")) return true;
    }
    return false;
}

fn conformanceArgsHaveSuiteFiles(args: []const []const u8) bool {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--rush") or
            std.mem.eql(u8, arg, "--shell") or
            std.mem.eql(u8, arg, "--shell-arg") or
            std.mem.eql(u8, arg, "--mode") or
            std.mem.eql(u8, arg, "--case"))
        {
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--diff") or std.mem.eql(u8, arg, "--interactive")) continue;
        if (std.mem.startsWith(u8, arg, "--")) continue;
        return true;
    }
    return false;
}

fn addDifferentialTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    rush: *std.Build.Step.Compile,
    differential_step: *std.Build.Step,
) void {
    const harness = b.addExecutable(.{
        .name = "rush-differential-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz/differential.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run = b.addRunArtifact(harness);
    run.addArg("--rush");
    run.addArtifactArg(rush);
    if (b.args) |args| run.addArgs(args);
    differential_step.dependOn(&run.step);
}

fn createRushRootModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vaxis: *std.Build.Module,
    uucode: *std.Build.Module,
    zeit: *std.Build.Module,
    build_config: *std.Build.Step.Options,
    use_system_sqlite: bool,
    options: RushRootModuleOptions,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = options.link_libc,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis },
            .{ .name = "uucode", .module = uucode },
            .{ .name = "zeit", .module = zeit },
        },
    });
    module.addOptions("build_config", build_config);
    module.addAnonymousImport("default_config", .{ .root_source_file = generatedDefaultConfig(b) });
    linkSqlite(b, module, use_system_sqlite);
    return module;
}

fn generatedDefaultConfig(b: *std.Build) std.Build.LazyPath {
    return b.path(default_config_path);
}

fn sharedVaxisModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    uucode: *std.Build.Module,
) *std.Build.Module {
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
        .external_uucode = true,
    }).module("vaxis");
    vaxis.addImport("uucode", uucode);
    return vaxis;
}

fn sharedUucodeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{
            "east_asian_width",
            "grapheme_break",
            "general_category",
            "is_emoji_presentation",
        }),
    }).module("uucode");
}

fn linkSqlite(b: *std.Build, module: *std.Build.Module, use_system_sqlite: bool) void {
    if (use_system_sqlite) {
        module.linkSystemLibrary("sqlite3", .{
            .use_pkg_config = .yes,
            .preferred_link_mode = .dynamic,
            .search_strategy = .paths_first,
        });
        return;
    }

    const sqlite = b.dependency("sqlite", .{});
    // Built as a separate static library so `zig build fuzz --fuzz` does not
    // instrument the C code; clang's sancov emits callbacks (e.g.
    // __sanitizer_cov_trace_switch) that Zig's fuzzer runtime does not provide.
    const lib = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = module.resolved_target,
            .optimize = module.optimize,
            .link_libc = true,
            .fuzz = false,
        }),
    });
    lib.root_module.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
        },
    });
    module.linkLibrary(lib);
    module.addIncludePath(sqlite.path("."));
    module.link_libc = true;
}

fn versionString(b: *std.Build) []const u8 {
    const release = b.fmt("{f}", .{release_version});
    var code: u8 = undefined;
    const raw = b.runAllowFail(&.{
        "git",
        "-C",
        b.build_root.path orelse ".",
        "describe",
        "--tags",
        "--long",
        "--dirty",
        "--always",
        "--match",
        "v[0-9]*",
    }, &code, .ignore) catch return release;
    const description = std.mem.trim(u8, raw, " \r\n");
    if (description.len == 0) return release;

    const dirty = std.mem.endsWith(u8, description, "-dirty");
    const clean = if (dirty) description[0 .. description.len - "-dirty".len] else description;
    if (!std.mem.startsWith(u8, clean, "v")) {
        const count_raw = b.runAllowFail(&.{
            "git",
            "-C",
            b.build_root.path orelse ".",
            "rev-list",
            "--count",
            "HEAD",
        }, &code, .ignore) catch return release;
        const count = std.mem.trim(u8, count_raw, " \r\n");
        _ = std.fmt.parseInt(usize, count, 10) catch return release;
        return developmentVersion(b, release, count, clean, dirty);
    }

    const hash_sep = std.mem.lastIndexOfScalar(u8, clean, '-') orelse
        std.process.fatal("unexpected git describe output: {s}", .{description});
    const before_hash = clean[0..hash_sep];
    const distance_sep = std.mem.lastIndexOfScalar(u8, before_hash, '-') orelse
        std.process.fatal("unexpected git describe output: {s}", .{description});
    const tag = before_hash[0..distance_sep];
    const distance = before_hash[distance_sep + 1 ..];
    const hash = clean[hash_sep + 1 ..];
    if (hash.len < 2 or hash[0] != 'g')
        std.process.fatal("unexpected git describe output: {s}", .{description});

    const tagged_version = std.SemanticVersion.parse(tag[1..]) catch
        std.process.fatal("version tag is not semantic: {s}", .{tag});
    const commit_count = std.fmt.parseInt(usize, distance, 10) catch
        std.process.fatal("unexpected git describe output: {s}", .{description});
    if (commit_count == 0) {
        if (release_version.order(tagged_version) != .eq)
            std.process.fatal("release version {s} does not match tag {s}", .{ release, tag });
        if (!dirty) return release;
    } else if (release_version.order(tagged_version) != .gt) {
        std.process.fatal("release version {s} must be newer than tag {s}", .{ release, tag });
    }
    return developmentVersion(b, release, distance, hash[1..], dirty);
}

fn developmentVersion(
    b: *std.Build,
    release: []const u8,
    distance: []const u8,
    hash: []const u8,
    dirty: bool,
) []const u8 {
    return if (dirty)
        b.fmt("{s}-dev.{s}+g{s}.dirty", .{ release, distance, hash })
    else
        b.fmt("{s}-dev.{s}+g{s}", .{ release, distance, hash });
}
