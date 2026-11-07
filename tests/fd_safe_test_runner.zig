//! Unit test runner that does not use Zig's `--listen=-` stdio protocol.
//!
//! Rush has tests that intentionally replace or validate fd 0/1/2 behavior.
//! Zig's default build-runner protocol uses fd 0/1 for test control messages,
//! which makes those tests look like hangs or corrupts the protocol. This runner
//! always runs in terminal mode.

const builtin = @import("builtin");
const std = @import("std");

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;
var is_fuzz_test: bool = false;

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();
    if (builtin.fuzz) @panic("fuzz tests require Zig's server runner");

    const args = init.args.toSlice(std.heap.page_allocator) catch |err| {
        std.debug.panic("unable to parse command line args: {t}", .{err});
    };
    defer std.heap.page_allocator.free(args);

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--listen=-")) {
            continue;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            std.testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch {
                std.debug.panic("unable to parse --seed argument: {s}", .{arg});
            };
        } else if (std.mem.startsWith(u8, arg, "--cache-dir=")) {
            continue;
        } else if (std.mem.eql(u8, arg, "--cache-dir")) {
            if (index + 1 < args.len) index += 1;
        } else {
            std.debug.panic("unrecognized command line argument: {s}", .{arg});
        }
    }

    runTests(init);
}

fn runTests(init: std.process.Init.Minimal) void {
    const test_fns = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leak_count: usize = 0;
    var fuzz_count: usize = 0;

    for (test_fns, 0..) |test_fn, test_index| {
        // Match Zig's default test runner configuration.
        std.testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        std.testing.log_level = .warn;
        std.testing.environ = init.environ;
        log_err_count = 0;
        is_fuzz_test = false;

        std.debug.print("{d}/{d} {s}...", .{ test_index + 1, test_fns.len, test_fn.name });
        const result = test_fn.func();
        std.testing.io_instance.deinit();
        const leaked = std.testing.allocator_instance.deinit();

        if (leaked != 0) leak_count += leaked;
        fuzz_count += @intFromBool(is_fuzz_test);

        if (result) |_| {
            if (leaked == 0 and log_err_count == 0) {
                ok_count += 1;
                std.debug.print("OK\n", .{});
            } else {
                fail_count += 1;
                std.debug.print("FAIL", .{});
                if (leaked != 0) std.debug.print(" ({d} leaks)", .{leaked});
                if (log_err_count != 0) std.debug.print(" ({d} logged errors)", .{log_err_count});
                std.debug.print("\n", .{});
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                std.debug.print("SKIP\n", .{});
            },
            else => {
                fail_count += 1;
                std.debug.print("FAIL ({t})\n", .{err});
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }

    std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count });
    if (leak_count != 0) std.debug.print("{d} leaked allocations.\n", .{leak_count});
    if (fuzz_count != 0) std.debug.print("{d} fuzz tests found.\n", .{fuzz_count});
    if (fail_count != 0 or leak_count != 0) std.process.exit(1);
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@backingInt(message_level) <= @backingInt(std.log.Level.err)) log_err_count +|= 1;
    if (@backingInt(message_level) <= @backingInt(std.testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
