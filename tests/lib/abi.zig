//! Links the installed C ABI (`librush`) and checks eval plus output capture.

const std = @import("std");
const build_options = @import("build_options");
const c = @cImport({
    if (build_options.static_linkage) @cDefine("RUSH_STATIC", "1");
    @cInclude("rush.h");
});

test "version is non-empty" {
    try std.testing.expect(c.rush_version()[0] != 0);
}

test "eval captures stdout" {
    const instance = c.rush_create() orelse return error.CreateFailed;
    defer c.rush_destroy(instance);

    const src = "echo hello";
    try std.testing.expectEqual(@as(u8, 0), c.rush_eval(instance, src.ptr, src.len));
    try std.testing.expectEqualStrings(
        "hello\n",
        captured(c.rush_stdout_ptr(instance), c.rush_stdout_len(instance)),
    );
}

test "standard descriptor redirections route and close output" {
    const instance = c.rush_create() orelse return error.CreateFailed;
    defer c.rush_destroy(instance);

    const src = "echo error >&2; echo hidden >&-; echo visible";
    try std.testing.expectEqual(@as(u8, 0), c.rush_eval(instance, src.ptr, src.len));
    try std.testing.expectEqualStrings(
        "visible\n",
        captured(c.rush_stdout_ptr(instance), c.rush_stdout_len(instance)),
    );
    try std.testing.expectEqualStrings(
        "error\necho: write failed\n",
        captured(c.rush_stderr_ptr(instance), c.rush_stderr_len(instance)),
    );
}

test "unavailable pipeline reports a shell error" {
    const instance = c.rush_create() orelse return error.CreateFailed;
    defer c.rush_destroy(instance);

    const src = "echo a | echo b";
    try std.testing.expectEqual(@as(u8, 2), c.rush_eval(instance, src.ptr, src.len));
    try std.testing.expectEqualStrings(
        "rush: shell error\n",
        captured(c.rush_stderr_ptr(instance), c.rush_stderr_len(instance)),
    );
}

test "exec of an unavailable external command returns 127" {
    const instance = c.rush_create() orelse return error.CreateFailed;
    defer c.rush_destroy(instance);

    const src = "exec definitely-not-an-embedded-builtin";
    try std.testing.expectEqual(@as(u8, 127), c.rush_eval(instance, src.ptr, src.len));
    try std.testing.expectEqualStrings(
        "exec: definitely-not-an-embedded-builtin: not found\n",
        captured(c.rush_stderr_ptr(instance), c.rush_stderr_len(instance)),
    );
}

test "finished session retains an EXIT trap failure status" {
    const instance = c.rush_create() orelse return error.CreateFailed;
    defer c.rush_destroy(instance);

    const exit_src = "trap 'echo a | echo b' EXIT; exit 7";
    try std.testing.expectEqual(@as(u8, 2), c.rush_eval(instance, exit_src.ptr, exit_src.len));

    const ignored_src = "echo still";
    try std.testing.expectEqual(@as(u8, 2), c.rush_eval(instance, ignored_src.ptr, ignored_src.len));
    try std.testing.expectEqualStrings(
        "",
        captured(c.rush_stdout_ptr(instance), c.rush_stdout_len(instance)),
    );
    try std.testing.expectEqualStrings(
        "",
        captured(c.rush_stderr_ptr(instance), c.rush_stderr_len(instance)),
    );
}

test "nullable cleanup and allocation edge cases" {
    c.rush_destroy(null);
    c.rush_wasm_free_u8_array(null, 0);
    try std.testing.expectEqual(null, c.rush_wasm_alloc_u8_array(0));

    const bytes = c.rush_wasm_alloc_u8_array(16) orelse return error.AllocFailed;
    c.rush_wasm_free_u8_array(bytes, 16);
}

fn captured(ptr: [*c]const u8, len: usize) []const u8 {
    return ptr[0..len];
}
