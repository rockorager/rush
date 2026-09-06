//! Freestanding host effects for WebAssembly embedders.
//!
//! Captures stdout/stderr in memory. Process, pipe, and filesystem calls
//! fail as ordinary host errors: there is no POSIX process model in
//! wasm32-freestanding. `cd`/`pwd` keep a virtual working directory so
//! language-only scripts can still mutate PWD.

const WasmHost = @This();

const std = @import("std");

const host = @import("../host.zig");

const empty_output: [1]u8 = .{0};

const Descriptor = enum {
    stdin,
    stdout,
    stderr,
};

allocator: std.mem.Allocator,
stdout: std.ArrayList(u8) = .empty,
stderr: std.ArrayList(u8) = .empty,
descriptors: std.AutoHashMapUnmanaged(i32, Descriptor) = .empty,
cwd: []u8,
umask: u32 = 0o022,

pub const WriteError = error{
    BadFd,
    WouldBlock,
    InputOutput,
    BrokenPipe,
    SystemResources,
    Unexpected,
};

pub const ReadError = host.ReadError;
pub const OpenError = error{
    AccessDenied,
    FileNotFound,
    PathAlreadyExists,
    NotDir,
    IsDir,
    NameTooLong,
    SystemResources,
    Unexpected,
};
pub const CloseError = host.CloseError;
pub const DeleteFileError = host.DeleteFileError;
pub const DuplicateError = host.DuplicateError;
pub const FdFlagError = host.FdFlagError;
pub const PipeError = host.PipeError;
pub const ForkError = host.ForkError;
pub const SpawnError = error{
    SystemResources,
    Unexpected,
};
pub const WaitError = error{
    Unexpected,
};
pub const KillError = host.KillError;
pub const ProcessGroupError = host.ProcessGroupError;
pub const TerminalProcessGroupError = host.TerminalProcessGroupError;
pub const SignalDispositionError = host.SignalDispositionError;
pub const ResourceLimitError = host.ResourceLimitError;
pub const FileStatusError = host.FileStatusError;
pub const ListDirError = host.ListDirError || std.mem.Allocator.Error;
pub const ChangeDirError = host.ChangeDirError;
pub const CurrentDirError = host.CurrentDirError || std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator) !WasmHost {
    var wasm_host: WasmHost = .{
        .allocator = allocator,
        .cwd = try allocator.dupe(u8, "/"),
    };
    errdefer allocator.free(wasm_host.cwd);
    errdefer wasm_host.descriptors.deinit(allocator);
    try wasm_host.descriptors.put(allocator, host.Fd.stdin.raw(), .stdin);
    try wasm_host.descriptors.put(allocator, host.Fd.stdout.raw(), .stdout);
    try wasm_host.descriptors.put(allocator, host.Fd.stderr.raw(), .stderr);
    return wasm_host;
}

pub fn deinit(self: *WasmHost) void {
    self.stdout.deinit(self.allocator);
    self.stderr.deinit(self.allocator);
    self.descriptors.deinit(self.allocator);
    self.allocator.free(self.cwd);
    self.* = undefined;
}

pub fn clearOutput(self: *WasmHost) void {
    self.stdout.clearRetainingCapacity();
    self.stderr.clearRetainingCapacity();
}

pub fn stdoutSlice(self: *const WasmHost) []const u8 {
    return self.stdout.items;
}

pub fn stderrSlice(self: *const WasmHost) []const u8 {
    return self.stderr.items;
}

pub fn stdoutPtr(self: *const WasmHost) [*]const u8 {
    return outputPtr(self.stdout.items);
}

pub fn stderrPtr(self: *const WasmHost) [*]const u8 {
    return outputPtr(self.stderr.items);
}

fn outputPtr(bytes: []const u8) [*]const u8 {
    if (bytes.len == 0) return @as([*]const u8, @ptrCast(&empty_output));
    return bytes.ptr;
}

pub fn wallTimeNs(_: *const WasmHost) i128 {
    return 0;
}

pub fn writeAll(self: *WasmHost, fd: host.Fd, bytes: []const u8) WriteError!void {
    switch (self.descriptors.get(fd.raw()) orelse return error.BadFd) {
        .stdout => self.stdout.appendSlice(self.allocator, bytes) catch return error.SystemResources,
        .stderr => self.stderr.appendSlice(self.allocator, bytes) catch return error.SystemResources,
        .stdin => return error.BadFd,
    }
}

pub fn write(self: *WasmHost, fd: host.Fd, bytes: []const u8) WriteError!usize {
    try self.writeAll(fd, bytes);
    return bytes.len;
}

pub fn read(self: *const WasmHost, fd: host.Fd, buffer: []u8) ReadError!usize {
    _ = buffer;
    return switch (self.descriptors.get(fd.raw()) orelse return error.Unexpected) {
        .stdin => 0,
        .stdout, .stderr => error.Unexpected,
    };
}

pub fn readWithTimeout(self: *const WasmHost, fd: host.Fd, buffer: []u8, _: u64) ReadError!host.TimedReadResult {
    return .{ .read = try self.read(fd, buffer) };
}

pub fn readReady(_: *const WasmHost, _: host.Fd, _: u64) bool {
    return false;
}

pub fn openZ(_: *const WasmHost, path: [:0]const u8, _: host.OpenOptions) OpenError!host.Fd {
    std.debug.assert(path.len != 0);
    return error.FileNotFound;
}

pub fn close(self: *WasmHost, fd: host.Fd) CloseError!void {
    if (!self.descriptors.remove(fd.raw())) return error.Unexpected;
}

pub fn deleteFileZ(_: *const WasmHost, path: [:0]const u8) DeleteFileError!void {
    std.debug.assert(path.len != 0);
    return error.FileNotFound;
}

pub fn duplicate(self: *WasmHost, fd: host.Fd) DuplicateError!host.Fd {
    return self.duplicateAtLeast(fd, 0);
}

pub fn duplicateAtLeast(self: *WasmHost, fd: host.Fd, min_fd: u31) DuplicateError!host.Fd {
    const descriptor = self.descriptors.get(fd.raw()) orelse return error.BadFd;
    const duplicate_fd = self.availableFd(min_fd) orelse return error.SystemResources;
    self.descriptors.put(self.allocator, duplicate_fd.raw(), descriptor) catch return error.SystemResources;
    return duplicate_fd;
}

pub fn duplicateTo(self: *WasmHost, from: host.Fd, to: host.Fd) DuplicateError!void {
    const descriptor = self.descriptors.get(from.raw()) orelse return error.BadFd;
    if (from == to) return;
    self.descriptors.put(self.allocator, to.raw(), descriptor) catch return error.SystemResources;
}

pub fn setCloseOnExec(self: *const WasmHost, fd: host.Fd, _: bool) FdFlagError!void {
    if (!self.descriptors.contains(fd.raw())) return error.BadFd;
}

fn availableFd(self: *const WasmHost, min_fd: u31) ?host.Fd {
    var raw_fd: i32 = @intCast(min_fd);
    while (self.descriptors.contains(raw_fd)) {
        if (raw_fd == std.math.maxInt(i32)) return null;
        raw_fd += 1;
    }
    return @enumFromInt(raw_fd);
}

pub fn pipe(_: *const WasmHost) PipeError!host.Pipe {
    return error.SystemResources;
}

pub fn forkProcess(_: *const WasmHost, _: host.ForkOptions) ForkError!host.ForkResult {
    return error.SystemResources;
}

pub fn exit(_: *const WasmHost, _: u8) noreturn {
    @trap();
}

pub fn currentProcessId(_: *const WasmHost) host.Pid {
    return 1;
}

pub fn currentProcessGroup(_: *const WasmHost) host.Pid {
    return 1;
}

pub fn currentParentProcessId(_: *const WasmHost) host.Pid {
    return 0;
}

pub fn sendSignal(_: *const WasmHost, _: host.Pid, _: u8) KillError!void {
    return error.NoSuchProcess;
}

pub fn setProcessGroup(_: *const WasmHost, _: host.Pid, _: host.Pid) ProcessGroupError!void {
    return error.NoSuchProcess;
}

pub fn terminalProcessGroup(_: *const WasmHost, _: host.Fd) TerminalProcessGroupError!host.Pid {
    return error.NotATerminal;
}

pub fn setTerminalProcessGroup(_: *const WasmHost, _: host.Fd, _: host.Pid) TerminalProcessGroupError!void {
    return error.NotATerminal;
}

pub fn setSignalIgnored(_: *const WasmHost, _: u8) SignalDispositionError!void {}

pub fn setSignalDefault(_: *const WasmHost, _: u8) SignalDispositionError!void {}

pub fn installSignalTrap(_: *const WasmHost, _: u8) SignalDispositionError!void {}

pub fn consumePendingSignal(_: *const WasmHost, _: u8) bool {
    return false;
}

pub fn getResourceLimit(_: *const WasmHost, _: host.ResourceLimitKind) ResourceLimitError!host.ResourceLimit {
    return error.Unexpected;
}

pub fn setResourceLimit(_: *const WasmHost, _: host.ResourceLimitKind, _: host.ResourceLimit) ResourceLimitError!void {
    return error.Unexpected;
}

pub fn isExecutableZ(_: *const WasmHost, path: [:0]const u8) bool {
    std.debug.assert(path.len != 0);
    return false;
}

pub fn existsZ(_: *const WasmHost, path: [:0]const u8) bool {
    std.debug.assert(path.len != 0);
    return false;
}

pub fn fileStatusZ(_: *const WasmHost, path: [:0]const u8) FileStatusError!host.FileStatus {
    std.debug.assert(path.len != 0);
    return error.FileNotFound;
}

pub fn fileTestStatusZ(_: *const WasmHost, path: [:0]const u8, _: bool) ?host.FileStatus {
    std.debug.assert(path.len != 0);
    return null;
}

pub fn fileAccessZ(_: *const WasmHost, path: [:0]const u8, _: host.FileAccess) bool {
    std.debug.assert(path.len != 0);
    return false;
}

pub fn isTerminalFd(_: *const WasmHost, _: host.Fd) bool {
    return false;
}

pub const TerminalMode = void;

pub fn disableTerminalEcho(_: *const WasmHost, _: host.Fd) ?TerminalMode {
    return null;
}

pub fn restoreTerminalMode(_: *const WasmHost, _: host.Fd, _: TerminalMode) void {}

// ziglint-ignore: Z015 existing public API error set exposure; preserve API
pub fn listDir(_: *const WasmHost, _: std.mem.Allocator, path: []const u8) ListDirError!host.ListDirResult {
    std.debug.assert(path.len != 0);
    return error.FileNotFound;
}

pub fn changeDir(self: *WasmHost, path: []const u8) ChangeDirError!void {
    std.debug.assert(path.len != 0);
    const resolved = resolvePath(self.allocator, self.cwd, path) catch return error.Unexpected;
    self.allocator.free(self.cwd);
    self.cwd = resolved;
}

// ziglint-ignore: Z015 existing public API error set exposure; preserve API
pub fn currentDir(self: *const WasmHost, allocator: std.mem.Allocator) CurrentDirError![]const u8 {
    return allocator.dupe(u8, self.cwd) catch error.Unexpected;
}

pub fn setFileCreationMask(self: *WasmHost, mask: u32) u32 {
    const previous = self.umask;
    self.umask = mask;
    return previous;
}

pub fn spawnAndWait(_: *const WasmHost, request: host.SpawnRequest) SpawnError!host.WaitStatus {
    request.validate();
    return .{ .exited = 127 };
}

pub fn spawn(_: *const WasmHost, request: host.SpawnRequest) SpawnError!host.SpawnResult {
    request.validate();
    return error.SystemResources;
}

pub fn exec(_: *const WasmHost, request: host.SpawnRequest) SpawnError!void {
    request.validate();
}

pub fn wait(_: *const WasmHost, _: host.Pid) WaitError!host.WaitStatus {
    return error.Unexpected;
}

pub fn waitNonBlocking(_: *const WasmHost, _: host.Pid) WaitError!?host.WaitStatus {
    return error.Unexpected;
}

pub fn waitJobEvent(_: *const WasmHost, _: host.Pid) WaitError!host.WaitStatus {
    return error.Unexpected;
}

pub fn waitJobEventInterruptible(_: *const WasmHost, _: host.Pid) WaitError!host.InterruptibleWait {
    return error.Unexpected;
}

pub fn waitInterruptible(_: *const WasmHost, _: host.Pid) WaitError!host.InterruptibleWait {
    return error.Unexpected;
}

fn resolvePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) error{OutOfMemory}![]u8 {
    if (path.len != 0 and path[0] == '/') return normalizeAbs(allocator, path);
    if (std.mem.eql(u8, cwd, "/")) return normalizeAbs(allocator, path);

    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    try joined.appendSlice(allocator, cwd);
    if (joined.items.len == 0 or joined.items[joined.items.len - 1] != '/') {
        try joined.append(allocator, '/');
    }
    try joined.appendSlice(allocator, path);
    const owned = try joined.toOwnedSlice(allocator);
    defer allocator.free(owned);
    return normalizeAbs(allocator, owned);
}

fn normalizeAbs(allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len != 0) _ = parts.pop();
            continue;
        }
        try parts.append(allocator, part);
    }

    if (parts.items.len == 0) return allocator.dupe(u8, "/");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (parts.items) |part| {
        try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }
    return out.toOwnedSlice(allocator);
}

test "WasmHost evaluates scripts through the shell core" {
    const shell_mod = @import("../shell.zig");

    {
        const host_value = try WasmHost.init(std.testing.allocator);
        var sh = shell_mod.Shell(WasmHost).init(std.testing.allocator, host_value, .{
            .initial_pwd = "/",
        });
        defer sh.deinit();
        defer sh.host.deinit();
        const src: shell_mod.source.Source = .{
            .id = 1,
            .kind = .command_string,
            .name = "wasm",
            .text = "echo hello",
        };
        const evaluated = try sh.evalSource(src);
        try std.testing.expectEqual(@as(u8, 0), evaluated.status);
        try std.testing.expectEqualStrings("hello\n", sh.host.stdoutSlice());
    }

    {
        const host_value = try WasmHost.init(std.testing.allocator);
        var sh = shell_mod.Shell(WasmHost).init(std.testing.allocator, host_value, .{
            .initial_pwd = "/",
        });
        defer sh.deinit();
        defer sh.host.deinit();
        const src: shell_mod.source.Source = .{
            .id = 1,
            .kind = .command_string,
            .name = "wasm",
            .text = "ls",
        };
        const evaluated = try sh.evalSource(src);
        try std.testing.expectEqual(@as(u8, 127), evaluated.status);
    }
}

test "WasmHost virtual cwd tracks cd" {
    var wasm_host = try WasmHost.init(std.testing.allocator);
    defer wasm_host.deinit();
    try wasm_host.changeDir("tmp");
    try std.testing.expectEqualStrings("/tmp", wasm_host.cwd);
    try wasm_host.changeDir("..");
    try std.testing.expectEqualStrings("/", wasm_host.cwd);
}

test "WasmHost duplicates, routes, and closes descriptors" {
    var wasm_host = try WasmHost.init(std.testing.allocator);
    defer wasm_host.deinit();

    const saved_stdout = try wasm_host.duplicateAtLeast(.stdout, 10);
    try wasm_host.duplicateTo(.stderr, .stdout);
    try wasm_host.writeAll(.stdout, "error\n");
    try std.testing.expectEqualStrings("error\n", wasm_host.stderrSlice());

    try wasm_host.duplicateTo(saved_stdout, .stdout);
    try wasm_host.close(saved_stdout);
    try wasm_host.close(.stdout);
    try std.testing.expectError(error.BadFd, wasm_host.writeAll(.stdout, "hidden\n"));
}
