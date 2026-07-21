//! Real host effects implemented with platform syscalls.

const RealHost = @This();

const std = @import("std");
const builtin = @import("builtin");
const libc = @cImport({
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const host = @import("../host.zig");

const real_host: RealHost = .{};
const lookup_max_buffer_len = 1024 * 1024;
const local_time_max_buffer_len = 1024 * 1024;

extern "c" fn readdir(dir: *std.c.DIR) ?*std.c.dirent;
extern "c" fn getpgrp() c_int;
extern "c" fn tcgetpgrp(fd: c_int) c_int;
extern "c" fn tcsetpgrp(fd: c_int, pgrp: c_int) c_int;

var pending_signal_bits: std.atomic.Value(u64) = .init(0);

pub const ReadError = host.ReadError;

pub const TerminalMode = std.posix.termios;

pub const WriteError = error{
    BadFd,
    WouldBlock,
    InputOutput,
    BrokenPipe,
    SystemResources,
    Unexpected,
};

pub fn wallTimeNs(_: RealHost) i128 {
    return clockTimeNs(.REALTIME) orelse 0;
}

pub fn effectiveUserId(_: RealHost) std.c.uid_t {
    return std.c.geteuid();
}

pub fn effectiveUserName(_: RealHost, allocator: std.mem.Allocator) ![]const u8 {
    var password: std.c.passwd = undefined;
    var buffer_len: usize = 1024;
    while (buffer_len <= lookup_max_buffer_len) : (buffer_len *= 2) {
        const buffer = try allocator.alloc(u8, buffer_len);
        defer allocator.free(buffer);
        var entry: ?*std.c.passwd = null;
        const rc = std.c.getpwuid_r(std.c.geteuid(), &password, buffer.ptr, buffer.len, &entry);
        if (rc == 0) {
            const name = (entry orelse return error.Unexpected).name orelse return error.Unexpected;
            return allocator.dupe(u8, std.mem.span(name));
        }
        if (rc != @intFromEnum(std.c.E.RANGE)) return error.Unexpected;
    }
    return error.Unexpected;
}

pub fn hostname(_: RealHost, allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    return allocator.dupe(u8, try std.posix.gethostname(&buffer));
}

pub fn terminalName(_: RealHost, allocator: std.mem.Allocator, fd: host.Fd) ![]const u8 {
    var buffer_len: usize = 128;
    while (buffer_len <= lookup_max_buffer_len) : (buffer_len *= 2) {
        const buffer = try allocator.alloc(u8, buffer_len);
        defer allocator.free(buffer);
        const rc = libc.ttyname_r(fd.raw(), buffer.ptr, buffer.len);
        if (rc == 0) return allocator.dupe(u8, std.mem.sliceTo(buffer, 0));
        if (rc != @intFromEnum(std.c.E.RANGE)) return error.Unexpected;
    }
    return error.Unexpected;
}

pub fn formatLocalTime(_: RealHost, allocator: std.mem.Allocator, timestamp: i64, format: []const u8) ![]const u8 {
    const timestamp_c: libc.time_t = @intCast(timestamp);
    var local: libc.struct_tm = undefined;
    if (libc.localtime_r(&timestamp_c, &local) == null) return error.Unexpected;
    if (format.len == 0) return allocator.dupe(u8, "");

    const format_z = try allocator.dupeZ(u8, format);
    defer allocator.free(format_z);
    const minimum_len = std.math.add(usize, format.len, 1) catch return error.OutOfMemory;
    if (minimum_len > local_time_max_buffer_len) return error.Unexpected;

    var buffer_len = @max(@as(usize, 256), minimum_len);
    while (true) {
        const buffer = try allocator.alloc(u8, buffer_len);
        defer allocator.free(buffer);
        const written = libc.strftime(buffer.ptr, buffer.len, format_z.ptr, &local);
        if (written != 0) return allocator.dupe(u8, buffer[0..written]);

        // POSIX uses zero for both insufficient capacity and a legitimately
        // empty result. Retry to a bounded maximum before accepting empty.
        if (buffer_len == local_time_max_buffer_len) return allocator.dupe(u8, "");
        buffer_len = @min(buffer_len * 2, local_time_max_buffer_len);
    }
}

fn clockTimeNs(clock: std.c.clockid_t) ?i128 {
    var timespec: std.c.timespec = undefined;
    switch (builtin.os.tag) {
        .linux => switch (std.os.linux.errno(std.os.linux.clock_gettime(clock, &timespec))) {
            .SUCCESS => {},
            else => return null,
        },
        .macos, .freebsd, .openbsd, .netbsd => switch (std.c.errno(std.c.clock_gettime(clock, &timespec))) {
            .SUCCESS => {},
            else => return null,
        },
        else => return null,
    }
    return @as(i128, timespec.sec) * std.time.ns_per_s + timespec.nsec;
}

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

pub const FileStatusError = host.FileStatusError;

pub const ListDirError = host.ListDirError || std.mem.Allocator.Error;

pub const ChangeDirError = host.ChangeDirError;

pub const CurrentDirError = host.CurrentDirError || std.mem.Allocator.Error;

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

pub fn read(_: RealHost, fd: host.Fd, buffer: []u8) ReadError!usize {
    if (buffer.len == 0) return 0;
    return switch (builtin.os.tag) {
        .linux => linuxRead(fd, buffer),
        .macos, .freebsd, .openbsd, .netbsd => libcRead(fd, buffer),
        else => @compileError("unsupported host OS"),
    };
}

pub fn readWithTimeout(self: RealHost, fd: host.Fd, buffer: []u8, timeout_ms: u64) ReadError!host.TimedReadResult {
    if (buffer.len == 0) return .{ .read = 0 };
    if (!self.readReady(fd, timeout_ms)) return .timeout;
    return .{ .read = try self.read(fd, buffer) };
}

pub fn readReady(_: RealHost, fd: host.Fd, timeout_ms: u64) bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = @intCast(fd.raw()),
        .events = @intCast(std.c.POLL.IN),
        .revents = 0,
    }};
    const timeout: i32 = @intCast(@min(timeout_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
    const count = std.posix.poll(&fds, timeout) catch return false;
    if (count == 0) return false;
    return (fds[0].revents & @as(i16, @intCast(std.c.POLL.IN))) != 0;
}

pub fn readInteractiveKey(self: RealHost, timeout_ms: u64) ?u8 {
    const fd: host.Fd = .stdin;
    if (!self.isTerminalFd(fd)) return null;
    const raw_fd: std.posix.fd_t = @intCast(fd.raw());
    const saved = std.posix.tcgetattr(raw_fd) catch return null;
    var raw = saved;
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(raw_fd, .DRAIN, raw) catch return null;
    defer std.posix.tcsetattr(raw_fd, .DRAIN, saved) catch {};

    if (!self.readReady(fd, timeout_ms)) return null;

    var byte: [1]u8 = undefined;
    return if ((self.read(fd, &byte) catch return null) == 1) byte[0] else null;
}

pub fn disableTerminalEcho(self: RealHost, fd: host.Fd) ?TerminalMode {
    if (!self.isTerminalFd(fd)) return null;
    const raw_fd: std.posix.fd_t = @intCast(fd.raw());
    const saved = std.posix.tcgetattr(raw_fd) catch return null;
    var silent = saved;
    silent.lflag.ECHO = false;
    silent.lflag.ECHONL = false;
    std.posix.tcsetattr(raw_fd, .DRAIN, silent) catch return null;
    return saved;
}

pub fn restoreTerminalMode(_: RealHost, fd: host.Fd, mode: TerminalMode) void {
    const raw_fd: std.posix.fd_t = @intCast(fd.raw());
    // ziglint-ignore: Z026 best-effort terminal cleanup cannot report through this API
    std.posix.tcsetattr(raw_fd, .DRAIN, mode) catch {};
}

pub fn writeAll(self: RealHost, fd: host.Fd, bytes: []const u8) WriteError!void {
    var written: usize = 0;
    while (written < bytes.len) {
        written += try self.write(fd, bytes[written..]);
    }
}

pub fn write(_: RealHost, fd: host.Fd, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;
    return switch (builtin.os.tag) {
        .linux => linuxWrite(fd, bytes),
        .macos, .freebsd, .openbsd, .netbsd => libcWrite(fd, bytes),
        else => @compileError("unsupported host OS"),
    };
}

pub fn openZ(_: RealHost, path: [:0]const u8, options: host.OpenOptions) OpenError!host.Fd {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxOpenZ(path, options),
        .macos, .freebsd, .openbsd, .netbsd => libcOpenZ(path, options),
        else => @compileError("unsupported host OS"),
    };
}

pub fn close(_: RealHost, fd: host.Fd) CloseError!void {
    return switch (builtin.os.tag) {
        .linux => linuxClose(fd),
        .macos, .freebsd, .openbsd, .netbsd => libcClose(fd),
        else => @compileError("unsupported host OS"),
    };
}

pub fn deleteFileZ(_: RealHost, path: [:0]const u8) DeleteFileError!void {
    return switch (builtin.os.tag) {
        .linux => linuxDeleteFileZ(path),
        .macos, .freebsd, .openbsd, .netbsd => libcDeleteFileZ(path),
        else => @compileError("unsupported host OS"),
    };
}

pub fn duplicate(_: RealHost, fd: host.Fd) DuplicateError!host.Fd {
    return switch (builtin.os.tag) {
        .linux => linuxDuplicate(fd),
        .macos, .freebsd, .openbsd, .netbsd => libcDuplicate(fd),
        else => @compileError("unsupported host OS"),
    };
}

pub fn duplicateAtLeast(_: RealHost, fd: host.Fd, min_fd: u31) DuplicateError!host.Fd {
    return switch (builtin.os.tag) {
        .linux => linuxDuplicateAtLeast(fd, min_fd),
        .macos, .freebsd, .openbsd, .netbsd => libcDuplicateAtLeast(fd, min_fd),
        else => @compileError("unsupported host OS"),
    };
}

pub fn duplicateTo(_: RealHost, from: host.Fd, to: host.Fd) DuplicateError!void {
    return switch (builtin.os.tag) {
        .linux => linuxDuplicateTo(from, to),
        .macos, .freebsd, .openbsd, .netbsd => libcDuplicateTo(from, to),
        else => @compileError("unsupported host OS"),
    };
}

pub fn setCloseOnExec(_: RealHost, fd: host.Fd, enabled: bool) FdFlagError!void {
    return switch (builtin.os.tag) {
        .linux => linuxSetCloseOnExec(fd, enabled),
        .macos, .freebsd, .openbsd, .netbsd => libcSetCloseOnExec(fd, enabled),
        else => @compileError("unsupported host OS"),
    };
}

pub fn pipe(_: RealHost) PipeError!host.Pipe {
    return switch (builtin.os.tag) {
        .linux => linuxPipe(),
        .macos, .freebsd, .openbsd, .netbsd => libcPipe(),
        else => @compileError("unsupported host OS"),
    };
}

pub fn forkProcess(_: RealHost) ForkError!host.ForkResult {
    return switch (builtin.os.tag) {
        .linux => linuxForkProcess(),
        .macos, .freebsd, .openbsd, .netbsd => libcForkProcess(),
        else => @compileError("unsupported host OS"),
    };
}

pub fn exit(_: RealHost, status: u8) noreturn {
    switch (builtin.os.tag) {
        .linux => std.os.linux.exit(status),
        .macos, .freebsd, .openbsd, .netbsd => std.c._exit(status),
        else => @compileError("unsupported host OS"),
    }
}

pub fn currentProcessId(_: RealHost) host.Pid {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .macos, .freebsd, .openbsd, .netbsd => @intCast(std.c.getpid()),
        else => @compileError("unsupported host OS"),
    };
}

pub fn currentProcessGroup(_: RealHost) host.Pid {
    return @intCast(getpgrp());
}

pub fn currentParentProcessId(_: RealHost) host.Pid {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getppid()),
        .macos, .freebsd, .openbsd, .netbsd => @intCast(std.c.getppid()),
        else => @compileError("unsupported host OS"),
    };
}

pub fn sendSignal(_: RealHost, pid: host.Pid, signal: u8) KillError!void {
    return switch (builtin.os.tag) {
        .linux => linuxSendSignal(pid, signal),
        .macos, .freebsd, .openbsd, .netbsd => libcSendSignal(pid, signal),
        else => @compileError("unsupported host OS"),
    };
}

pub fn setProcessGroup(_: RealHost, pid: host.Pid, process_group: host.Pid) ProcessGroupError!void {
    return switch (builtin.os.tag) {
        .linux => linuxSetProcessGroup(pid, process_group),
        .macos, .freebsd, .openbsd, .netbsd => libcSetProcessGroup(pid, process_group),
        else => @compileError("unsupported host OS"),
    };
}

pub fn terminalProcessGroup(_: RealHost, fd: host.Fd) TerminalProcessGroupError!host.Pid {
    while (true) {
        const process_group = tcgetpgrp(fd.raw());
        if (process_group >= 0) return @intCast(process_group);
        switch (std.c.errno(process_group)) {
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            else => return error.Unexpected,
        }
    }
}

pub fn setTerminalProcessGroup(_: RealHost, fd: host.Fd, process_group: host.Pid) TerminalProcessGroupError!void {
    // Block SIGTTOU while claiming the terminal. Otherwise a shell that is not
    // currently the foreground process group can be stopped mid-handoff when
    // tcsetpgrp generates TTOU, leaving fg/bg and child jobs wedged.
    var blocked = std.posix.sigemptyset();
    std.posix.sigaddset(&blocked, .TTOU);
    var previous: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked, &previous);
    defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous, null);

    while (true) {
        const rc = tcsetpgrp(fd.raw(), @intCast(process_group));
        switch (std.c.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            .PERM => return error.NotAPgrpMember,
            else => return error.Unexpected,
        }
    }
}

pub fn setSignalIgnored(_: RealHost, signal: u8) SignalDispositionError!void {
    setSignalAction(signal, std.posix.SIG.IGN) catch return error.InvalidSignal;
}

pub fn setSignalDefault(self: RealHost, signal: u8) SignalDispositionError!void {
    setSignalAction(signal, std.posix.SIG.DFL) catch return error.InvalidSignal;
    _ = self.consumePendingSignal(signal);
}

pub fn installSignalTrap(_: RealHost, signal: u8) SignalDispositionError!void {
    setSignalAction(signal, trapSignalHandler) catch return error.InvalidSignal;
}

pub fn consumePendingSignal(_: RealHost, signal: u8) bool {
    if (signal >= 64) return false;
    const mask = @as(u64, 1) << @intCast(signal);
    return (pending_signal_bits.fetchAnd(~mask, .seq_cst) & mask) != 0;
}

pub fn getResourceLimit(_: RealHost, kind: host.ResourceLimitKind) ResourceLimitError!host.ResourceLimit {
    const limit = std.posix.getrlimit(resourceLimitKind(kind)) catch return error.Unexpected;
    return .{
        .soft = resourceLimitFromNative(limit.cur),
        .hard = resourceLimitFromNative(limit.max),
    };
}

pub fn setResourceLimit(_: RealHost, kind: host.ResourceLimitKind, limit: host.ResourceLimit) ResourceLimitError!void {
    const native: std.posix.rlimit = .{
        .cur = try resourceLimitToNative(limit.soft),
        .max = try resourceLimitToNative(limit.hard),
    };
    std.posix.setrlimit(resourceLimitKind(kind), native) catch |err| return switch (err) {
        error.PermissionDenied => error.PermissionDenied,
        error.LimitTooBig => error.LimitTooBig,
        error.Unexpected => error.Unexpected,
    };
}

fn setSignalAction(signal: u8, handler: ?std.posix.Sigaction.handler_fn) !void {
    if (signal == @intFromEnum(std.posix.SIG.KILL) or signal == @intFromEnum(std.posix.SIG.STOP)) {
        return error.InvalidSignal;
    }
    var action: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(@enumFromInt(signal), &action, null);
}

fn trapSignalHandler(signal: std.posix.SIG) callconv(.c) void {
    const number: u8 = @intCast(@intFromEnum(signal));
    if (number >= 64) return;
    const mask = @as(u64, 1) << @intCast(number);
    _ = pending_signal_bits.fetchOr(mask, .seq_cst);
}

fn peekPendingSignal() ?u8 {
    const bits = pending_signal_bits.load(.seq_cst);
    if (bits == 0) return null;
    return @intCast(@ctz(bits));
}

pub fn isExecutableZ(_: RealHost, path: [:0]const u8) bool {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxIsExecutableZ(path),
        .macos, .freebsd, .openbsd, .netbsd => libcIsExecutableZ(path),
        else => @compileError("unsupported host OS"),
    };
}

pub fn existsZ(_: RealHost, path: [:0]const u8) bool {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxExistsZ(path),
        .macos, .freebsd, .openbsd, .netbsd => libcExistsZ(path),
        else => @compileError("unsupported host OS"),
    };
}

pub fn fileStatusZ(_: RealHost, path: [:0]const u8) FileStatusError!host.FileStatus {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxFileStatusZ(path),
        .macos, .freebsd, .openbsd, .netbsd => libcFileStatusZ(path),
        else => @compileError("unsupported host OS"),
    };
}

pub fn fileTestStatusZ(_: RealHost, path: [:0]const u8, follow_symlinks: bool) ?host.FileStatus {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxFileTestStatusZ(path, follow_symlinks),
        .macos, .freebsd, .openbsd, .netbsd => libcFileTestStatusZ(path, follow_symlinks),
        else => @compileError("unsupported host OS"),
    };
}

pub fn fileAccessZ(_: RealHost, path: [:0]const u8, access: host.FileAccess) bool {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxFileAccessZ(path, access),
        .macos, .freebsd, .openbsd, .netbsd => libcFileAccessZ(path, access),
        else => @compileError("unsupported host OS"),
    };
}

pub fn isTerminalFd(_: RealHost, fd: host.Fd) bool {
    return std.c.isatty(@intCast(fd.raw())) == 1;
}

// ziglint-ignore: Z015 existing public API error set exposure; preserve API
pub fn listDir(_: RealHost, allocator: std.mem.Allocator, path: []const u8) ListDirError!host.ListDirResult {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxListDir(allocator, path),
        .macos, .freebsd, .openbsd, .netbsd => libcListDir(allocator, path),
        else => @compileError("unsupported host OS"),
    };
}

pub fn changeDir(_: RealHost, path: []const u8) ChangeDirError!void {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxChangeDir(path),
        .macos, .freebsd, .openbsd, .netbsd => libcChangeDir(path),
        else => @compileError("unsupported host OS"),
    };
}

// ziglint-ignore: Z015 existing public API error set exposure; preserve API
pub fn currentDir(_: RealHost, allocator: std.mem.Allocator) CurrentDirError![]const u8 {
    return switch (builtin.os.tag) {
        .linux => linuxCurrentDir(allocator),
        .macos, .freebsd, .openbsd, .netbsd => libcCurrentDir(allocator),
        else => @compileError("unsupported host OS"),
    };
}

pub fn setFileCreationMask(_: RealHost, mask: u32) u32 {
    return @intCast(std.c.umask(@intCast(mask)));
}

pub fn spawnAndWait(self: RealHost, request: host.SpawnRequest) SpawnError!host.WaitStatus {
    request.validate();
    const spawned = try self.spawn(request);
    return self.wait(spawned.pid) catch error.Unexpected;
}

pub fn spawn(_: RealHost, request: host.SpawnRequest) SpawnError!host.SpawnResult {
    request.validate();
    return switch (builtin.os.tag) {
        .linux => linuxSpawn(request),
        .macos, .freebsd, .openbsd, .netbsd => libcSpawn(request),
        else => @compileError("unsupported host OS"),
    };
}

pub fn exec(_: RealHost, request: host.SpawnRequest) SpawnError!void {
    request.validate();
    return switch (builtin.os.tag) {
        .linux => linuxExec(request),
        .macos, .freebsd, .openbsd, .netbsd => libcExec(request),
        else => @compileError("unsupported host OS"),
    };
}

pub fn wait(_: RealHost, pid: host.Pid) WaitError!host.WaitStatus {
    return switch (builtin.os.tag) {
        .linux => linuxWait(pid),
        .macos, .freebsd, .openbsd, .netbsd => libcWait(pid),
        else => @compileError("unsupported host OS"),
    };
}

pub fn waitNonBlocking(_: RealHost, pid: host.Pid) WaitError!?host.WaitStatus {
    return switch (builtin.os.tag) {
        .linux => linuxWaitNonBlocking(pid),
        .macos, .freebsd, .openbsd, .netbsd => libcWaitNonBlocking(pid),
        else => @compileError("unsupported host OS"),
    };
}

pub fn waitJobEvent(_: RealHost, pid: host.Pid) WaitError!host.WaitStatus {
    return switch (builtin.os.tag) {
        .linux => linuxWaitJobEvent(pid),
        .macos, .freebsd, .openbsd, .netbsd => libcWaitJobEvent(pid),
        else => @compileError("unsupported host OS"),
    };
}

pub fn waitJobEventInterruptible(_: RealHost, pid: host.Pid) WaitError!host.WaitStatus {
    return switch (builtin.os.tag) {
        .linux => linuxWaitJobEventInterruptible(pid),
        .macos, .freebsd, .openbsd, .netbsd => libcWaitJobEventInterruptible(pid),
        else => @compileError("unsupported host OS"),
    };
}

pub fn waitInterruptible(_: RealHost, pid: host.Pid) WaitError!host.WaitStatus {
    return switch (builtin.os.tag) {
        .linux => linuxWaitInterruptible(pid),
        .macos, .freebsd, .openbsd, .netbsd => libcWaitInterruptible(pid),
        else => @compileError("unsupported host OS"),
    };
}

fn linuxRead(fd: host.Fd, buffer: []u8) ReadError!usize {
    const linux = std.os.linux;
    while (true) {
        const rc = linux.read(fd.raw(), buffer.ptr, buffer.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .IO => return error.InputOutput,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .BADF, .FAULT, .INVAL, .ISDIR => return error.Unexpected,
            else => return error.Unexpected,
        }
    }
}

fn libcRead(fd: host.Fd, buffer: []u8) ReadError!usize {
    while (true) {
        const rc = std.c.read(@intCast(fd.raw()), buffer.ptr, buffer.len);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .IO => return error.InputOutput,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .BADF, .FAULT, .INVAL, .ISDIR => return error.Unexpected,
            else => return error.Unexpected,
        }
    }
}

fn linuxWrite(fd: host.Fd, bytes: []const u8) WriteError!usize {
    const linux = std.os.linux;
    while (true) {
        const rc = linux.write(fd.raw(), bytes.ptr, bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .IO => return error.InputOutput,
            .PIPE => return error.BrokenPipe,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .BADF => return error.BadFd,
            .DESTADDRREQ, .DQUOT, .FBIG, .INVAL, .NOSPC, .PERM => return error.Unexpected,
            else => return error.Unexpected,
        }
    }
}

fn libcWrite(fd: host.Fd, bytes: []const u8) WriteError!usize {
    while (true) {
        const rc = std.c.write(@intCast(fd.raw()), bytes.ptr, bytes.len);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .IO => return error.InputOutput,
            .PIPE => return error.BrokenPipe,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .BADF => return error.BadFd,
            .DESTADDRREQ, .DQUOT, .FBIG, .INVAL, .NOSPC, .PERM => return error.Unexpected,
            else => return error.Unexpected,
        }
    }
}

fn linuxOpenZ(path: [:0]const u8, options: host.OpenOptions) OpenError!host.Fd {
    const linux = std.os.linux;
    var flags = linuxOpenFlags(options);
    flags.CLOEXEC = true;
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, flags, @intCast(options.mode));
    switch (linux.errno(rc)) {
        .SUCCESS => return @enumFromInt(@as(i32, @intCast(rc))),
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .EXIST => return error.PathAlreadyExists,
        .NOTDIR => return error.NotDir,
        .ISDIR => return error.IsDir,
        .NAMETOOLONG => return error.NameTooLong,
        .NFILE, .MFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn libcOpenZ(path: [:0]const u8, options: host.OpenOptions) OpenError!host.Fd {
    var flags = libcOpenFlags(options);
    flags.CLOEXEC = true;
    const rc = std.c.open(path.ptr, flags, @as(std.c.mode_t, @intCast(options.mode)));
    switch (std.c.errno(rc)) {
        .SUCCESS => return @enumFromInt(@as(i32, @intCast(rc))),
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .EXIST => return error.PathAlreadyExists,
        .NOTDIR => return error.NotDir,
        .ISDIR => return error.IsDir,
        .NAMETOOLONG => return error.NameTooLong,
        .NFILE, .MFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn linuxClose(fd: host.Fd) CloseError!void {
    const linux = std.os.linux;
    const rc = linux.close(fd.raw());
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .INTR => return error.Interrupted,
        .IO => return error.InputOutput,
        .BADF => return error.Unexpected,
        else => return error.Unexpected,
    }
}

fn libcClose(fd: host.Fd) CloseError!void {
    const rc = std.c.close(@intCast(fd.raw()));
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
        .INTR => return error.Interrupted,
        .IO => return error.InputOutput,
        .BADF => return error.Unexpected,
        else => return error.Unexpected,
    }
}

fn linuxDeleteFileZ(path: [:0]const u8) DeleteFileError!void {
    const linux = std.os.linux;
    const rc = linux.unlinkat(linux.AT.FDCWD, path.ptr, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        .ISDIR => return error.Unexpected,
        else => return error.Unexpected,
    }
}

fn libcDeleteFileZ(path: [:0]const u8) DeleteFileError!void {
    const rc = std.c.unlink(path.ptr);
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        .ISDIR => return error.Unexpected,
        else => return error.Unexpected,
    }
}

fn linuxDuplicate(fd: host.Fd) DuplicateError!host.Fd {
    const linux = std.os.linux;
    const rc = linux.dup(fd.raw());
    switch (linux.errno(rc)) {
        .SUCCESS => return @enumFromInt(@as(i32, @intCast(rc))),
        .BADF => return error.BadFd,
        .INTR => return error.Interrupted,
        .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn libcDuplicate(fd: host.Fd) DuplicateError!host.Fd {
    const rc = std.c.dup(@intCast(fd.raw()));
    switch (std.c.errno(rc)) {
        .SUCCESS => return @enumFromInt(@as(i32, @intCast(rc))),
        .BADF => return error.BadFd,
        .INTR => return error.Interrupted,
        .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn linuxDuplicateAtLeast(fd: host.Fd, min_fd: u31) DuplicateError!host.Fd {
    const linux = std.os.linux;
    const rc = linux.fcntl(fd.raw(), linux.F.DUPFD_CLOEXEC, min_fd);
    switch (linux.errno(rc)) {
        .SUCCESS => return @enumFromInt(@as(i32, @intCast(rc))),
        .BADF => return error.BadFd,
        .INTR => return error.Interrupted,
        .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn libcDuplicateAtLeast(fd: host.Fd, min_fd: u31) DuplicateError!host.Fd {
    const command = if (comptime @hasDecl(std.c.F, "DUPFD_CLOEXEC")) std.c.F.DUPFD_CLOEXEC else std.c.F.DUPFD;
    const rc = std.c.fcntl(@intCast(fd.raw()), command, @as(c_int, @intCast(min_fd)));
    switch (std.c.errno(rc)) {
        .SUCCESS => {
            const duplicated: host.Fd = @enumFromInt(@as(i32, @intCast(rc)));
            if (comptime !@hasDecl(std.c.F, "DUPFD_CLOEXEC")) {
                libcSetCloseOnExec(duplicated, true) catch |err| {
                    // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
                    real_host.close(duplicated) catch {};
                    return switch (err) {
                        error.BadFd => error.BadFd,
                        error.Unexpected => error.Unexpected,
                    };
                };
            }
            return duplicated;
        },
        .BADF => return error.BadFd,
        .INTR => return error.Interrupted,
        .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn linuxDuplicateTo(from: host.Fd, to: host.Fd) DuplicateError!void {
    if (from == to) return;
    const linux = std.os.linux;
    const rc = linux.dup2(from.raw(), to.raw());
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .BADF => return error.BadFd,
        .INTR => return error.Interrupted,
        .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn libcDuplicateTo(from: host.Fd, to: host.Fd) DuplicateError!void {
    if (from == to) return;
    const rc = std.c.dup2(@intCast(from.raw()), @intCast(to.raw()));
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
        .BADF => return error.BadFd,
        .INTR => return error.Interrupted,
        .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn linuxPipe() PipeError!host.Pipe {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.pipe2(&fds, .{ .CLOEXEC = true });
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => return .{ .read = @enumFromInt(fds[0]), .write = @enumFromInt(fds[1]) },
        .MFILE, .NFILE, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn libcPipe() PipeError!host.Pipe {
    var fds: [2]std.c.fd_t = undefined;
    const rc = std.c.pipe(&fds);
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        .MFILE, .NFILE, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    errdefer real_host.close(@enumFromInt(fds[0])) catch {};
    errdefer real_host.close(@enumFromInt(fds[1])) catch {};
    try setCloseOnExecForPipe(@enumFromInt(fds[0]));
    try setCloseOnExecForPipe(@enumFromInt(fds[1]));
    return .{ .read = @enumFromInt(fds[0]), .write = @enumFromInt(fds[1]) };
}

fn setCloseOnExecForPipe(fd: host.Fd) PipeError!void {
    const rc = std.c.fcntl(@intCast(fd.raw()), std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
        else => return error.Unexpected,
    }
}

fn linuxSetCloseOnExec(fd: host.Fd, enabled: bool) FdFlagError!void {
    const linux = std.os.linux;
    const get_rc = linux.fcntl(fd.raw(), linux.F.GETFD, 0);
    const flags = switch (linux.errno(get_rc)) {
        .SUCCESS => get_rc,
        .BADF => return error.BadFd,
        else => return error.Unexpected,
    };
    const new_flags = if (enabled) flags | linux.FD_CLOEXEC else flags & ~@as(usize, linux.FD_CLOEXEC);
    const set_rc = linux.fcntl(fd.raw(), linux.F.SETFD, new_flags);
    switch (linux.errno(set_rc)) {
        .SUCCESS => return,
        .BADF => return error.BadFd,
        else => return error.Unexpected,
    }
}

fn libcSetCloseOnExec(fd: host.Fd, enabled: bool) FdFlagError!void {
    const get_rc = std.c.fcntl(@intCast(fd.raw()), std.c.F.GETFD, @as(c_int, 0));
    const flags: c_int = switch (std.c.errno(get_rc)) {
        .SUCCESS => get_rc,
        .BADF => return error.BadFd,
        else => return error.Unexpected,
    };
    const new_flags = if (enabled) flags | std.c.FD_CLOEXEC else flags & ~@as(c_int, std.c.FD_CLOEXEC);
    const set_rc = std.c.fcntl(@intCast(fd.raw()), std.c.F.SETFD, new_flags);
    switch (std.c.errno(set_rc)) {
        .SUCCESS => return,
        .BADF => return error.BadFd,
        else => return error.Unexpected,
    }
}

fn linuxForkProcess() ForkError!host.ForkResult {
    const rc = std.os.linux.fork();
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }

    const pid: i32 = @intCast(rc);
    return if (pid == 0) .child else .{ .parent = pid };
}

fn libcForkProcess() ForkError!host.ForkResult {
    const rc = std.c.fork();
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }

    const pid: i32 = @intCast(rc);
    return if (pid == 0) .child else .{ .parent = pid };
}

fn linuxIsExecutableZ(path: [:0]const u8) bool {
    const rc = std.os.linux.access(path.ptr, std.os.linux.X_OK);
    return std.os.linux.errno(rc) == .SUCCESS;
}

fn linuxExistsZ(path: [:0]const u8) bool {
    const rc = std.os.linux.access(path.ptr, std.os.linux.F_OK);
    return std.os.linux.errno(rc) == .SUCCESS;
}

fn linuxSendSignal(pid: host.Pid, signal: u8) KillError!void {
    const rc = std.os.linux.kill(pid, @enumFromInt(signal));
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => return,
        .PERM => return error.AccessDenied,
        .SRCH => return error.NoSuchProcess,
        .INVAL => return error.InvalidSignal,
        else => return error.Unexpected,
    }
}

fn linuxSetProcessGroup(pid: host.Pid, process_group: host.Pid) ProcessGroupError!void {
    const rc = std.os.linux.setpgid(pid, process_group);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .SRCH => return error.NoSuchProcess,
        else => return error.Unexpected,
    }
}

fn libcIsExecutableZ(path: [:0]const u8) bool {
    const rc = std.c.access(path.ptr, std.c.X_OK);
    return std.c.errno(rc) == .SUCCESS;
}

fn libcExistsZ(path: [:0]const u8) bool {
    const rc = std.c.access(path.ptr, std.c.F_OK);
    return std.c.errno(rc) == .SUCCESS;
}

fn libcSendSignal(pid: host.Pid, signal: u8) KillError!void {
    const rc = std.c.kill(@intCast(pid), @enumFromInt(signal));
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
        .PERM => return error.AccessDenied,
        .SRCH => return error.NoSuchProcess,
        .INVAL => return error.InvalidSignal,
        else => return error.Unexpected,
    }
}

fn libcSetProcessGroup(pid: host.Pid, process_group: host.Pid) ProcessGroupError!void {
    const rc = std.c.setpgid(@intCast(pid), @intCast(process_group));
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .SRCH => return error.NoSuchProcess,
        else => return error.Unexpected,
    }
}

fn linuxFileStatusZ(path: [:0]const u8) FileStatusError!host.FileStatus {
    const linux = std.os.linux;
    var status: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path.ptr, 0, file_status_mask, &status);
    switch (linux.errno(rc)) {
        .SUCCESS => return linuxStatusFromStatx(status),
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        .NFILE, .MFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn libcFileStatusZ(path: [:0]const u8) FileStatusError!host.FileStatus {
    var status: std.c.Stat = undefined;
    const rc = std.c.fstatat(std.c.AT.FDCWD, path.ptr, &status, 0);
    switch (std.c.errno(rc)) {
        .SUCCESS => return libcStatusFromStat(status),
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        .NFILE, .MFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
}

const file_status_mask: std.os.linux.STATX = .{
    .TYPE = true,
    .MODE = true,
    .MTIME = true,
    .INO = true,
    .SIZE = true,
};

fn linuxFileTestStatusZ(path: [:0]const u8, follow_symlinks: bool) ?host.FileStatus {
    const linux = std.os.linux;
    var flags: u32 = linux.AT.NO_AUTOMOUNT;
    if (!follow_symlinks) flags |= linux.AT.SYMLINK_NOFOLLOW;
    var statx = std.mem.zeroes(linux.Statx);
    const rc = linux.statx(linux.AT.FDCWD, path.ptr, flags, file_status_mask, &statx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return linuxStatusFromStatx(statx);
}

fn linuxStatusFromStatx(statx: std.os.linux.Statx) host.FileStatus {
    return .{
        .kind = linuxFileKindFromMode(statx.mode),
        .size = statx.size,
        .mode = statx.mode,
        .device = (@as(u64, statx.dev_major) << 32) | statx.dev_minor,
        .inode = statx.ino,
        .mtime_sec = statx.mtime.sec,
        .mtime_nsec = statx.mtime.nsec,
    };
}

fn libcFileTestStatusZ(path: [:0]const u8, follow_symlinks: bool) ?host.FileStatus {
    const flags: u32 = if (follow_symlinks) 0 else std.c.AT.SYMLINK_NOFOLLOW;
    const fstatat_sym = if (std.posix.lfs64_abi) std.c.fstatat64 else std.c.fstatat;
    var stat = std.mem.zeroes(std.posix.Stat);
    const rc = fstatat_sym(std.c.AT.FDCWD, path.ptr, &stat, flags);
    if (std.c.errno(rc) != .SUCCESS) return null;
    return libcStatusFromStat(stat);
}

fn libcStatusFromStat(stat: std.posix.Stat) host.FileStatus {
    const mtime = stat.mtime();
    return .{
        .kind = libcFileKindFromMode(stat.mode),
        .size = @intCast(@max(stat.size, 0)),
        .mode = @intCast(stat.mode),
        .device = statIdentifier(stat.dev),
        .inode = statIdentifier(stat.ino),
        .mtime_sec = @intCast(mtime.sec),
        .mtime_nsec = @intCast(mtime.nsec),
    };
}

fn statIdentifier(value: anytype) u64 {
    return std.math.cast(u64, value) orelse @as(u64, @bitCast(@as(i64, @intCast(value))));
}

fn linuxFileAccessZ(path: [:0]const u8, access: host.FileAccess) bool {
    const mode: u32 = switch (access) {
        .read => std.os.linux.R_OK,
        .write => std.os.linux.W_OK,
        .execute => std.os.linux.X_OK,
    };
    const rc = std.os.linux.access(path.ptr, mode);
    return std.os.linux.errno(rc) == .SUCCESS;
}

fn libcFileAccessZ(path: [:0]const u8, access: host.FileAccess) bool {
    const mode: c_uint = switch (access) {
        .read => std.c.R_OK,
        .write => std.c.W_OK,
        .execute => std.c.X_OK,
    };
    const rc = std.c.access(path.ptr, mode);
    return std.c.errno(rc) == .SUCCESS;
}

fn linuxListDir(allocator: std.mem.Allocator, path: []const u8) ListDirError!host.ListDirResult {
    const path_z = std.posix.toPosixPath(path) catch return error.NameTooLong;
    const flags: std.os.linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const fd = std.os.linux.openat(std.os.linux.AT.FDCWD, &path_z, flags, 0);
    switch (std.os.linux.errno(fd)) {
        .SUCCESS => {},
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        .MFILE, .NFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
    const directory_fd: host.Fd = @enumFromInt(@as(i32, @intCast(fd)));
    defer real_host.close(directory_fd) catch {};

    var entries: std.ArrayList(host.DirectoryEntry) = .empty;
    errdefer freeDirectoryEntryList(allocator, &entries);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_len = try linuxGetDents(directory_fd.raw(), &buffer);
        if (read_len == 0) break;
        var index: usize = 0;
        while (index < read_len) {
            const entry: *align(1) std.os.linux.dirent64 = @ptrCast(&buffer[index]);
            const name_start = index + @offsetOf(std.os.linux.dirent64, "name");
            const name_limit = entry.reclen - @offsetOf(std.os.linux.dirent64, "name");
            const name_len = std.mem.indexOfScalar(u8, buffer[name_start..][0..name_limit], 0) orelse name_limit;
            const name = buffer[name_start..][0..name_len];
            if (!isSpecialDirectoryEntry(name)) {
                const owned_name = try allocator.dupe(u8, name);
                entries.append(allocator, .{
                    .name = owned_name,
                    .kind = fileKindFromDirentType(entry.type),
                }) catch |err| {
                    allocator.free(owned_name);
                    return err;
                };
            }
            index += entry.reclen;
        }
    }

    const result: host.ListDirResult = .{ .allocator = allocator, .entries = try entries.toOwnedSlice(allocator) };
    result.validate();
    return result;
}

fn linuxGetDents(fd: i32, buffer: []u8) ListDirError!usize {
    while (true) {
        const rc = std.os.linux.getdents64(fd, buffer.ptr, buffer.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NAMETOOLONG => return error.NameTooLong,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

fn libcListDir(allocator: std.mem.Allocator, path: []const u8) ListDirError!host.ListDirResult {
    const path_z = std.posix.toPosixPath(path) catch return error.NameTooLong;
    const dir = std.c.opendir(&path_z) orelse return switch (std.c.errno(-1)) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        .MFILE, .NFILE, .NOMEM, .NOBUFS => error.SystemResources,
        else => error.Unexpected,
    };
    defer _ = std.c.closedir(dir);

    var entries: std.ArrayList(host.DirectoryEntry) = .empty;
    errdefer freeDirectoryEntryList(allocator, &entries);

    while (readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (isSpecialDirectoryEntry(name)) continue;
        const owned_name = try allocator.dupe(u8, name);
        entries.append(allocator, .{
            .name = owned_name,
            .kind = fileKindFromDirentType(entry.type),
        }) catch |err| {
            allocator.free(owned_name);
            return err;
        };
    }

    const result: host.ListDirResult = .{ .allocator = allocator, .entries = try entries.toOwnedSlice(allocator) };
    result.validate();
    return result;
}

fn linuxChangeDir(path: []const u8) ChangeDirError!void {
    const path_z = std.posix.toPosixPath(path) catch return error.NameTooLong;
    const rc = std.os.linux.chdir(&path_z);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        else => return error.Unexpected,
    }
}

fn libcChangeDir(path: []const u8) ChangeDirError!void {
    const path_z = std.posix.toPosixPath(path) catch return error.NameTooLong;
    const rc = std.c.chdir(&path_z);
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        else => return error.Unexpected,
    }
}

fn linuxCurrentDir(allocator: std.mem.Allocator) CurrentDirError![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&buffer, buffer.len);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {
            const len = if (rc != 0 and buffer[rc - 1] == 0) rc - 1 else rc;
            return allocator.dupe(u8, buffer[0..len]);
        },
        .ACCES, .PERM => return error.AccessDenied,
        .RANGE, .NAMETOOLONG => return error.NameTooLong,
        else => return error.Unexpected,
    }
}

fn libcCurrentDir(allocator: std.mem.Allocator) CurrentDirError![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&buffer, buffer.len)) |cwd| {
        return allocator.dupe(u8, std.mem.sliceTo(cwd, 0));
    }
    return switch (std.c.errno(-1)) {
        .ACCES, .PERM => error.AccessDenied,
        .RANGE, .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
}

fn isSpecialDirectoryEntry(name: []const u8) bool {
    return name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

fn freeDirectoryEntryList(allocator: std.mem.Allocator, entries: *std.ArrayList(host.DirectoryEntry)) void {
    for (entries.items) |entry| allocator.free(entry.name);
    entries.deinit(allocator);
}

fn fileKindFromDirentType(kind: u8) host.FileKind {
    return switch (kind) {
        std.c.DT.REG => .file,
        std.c.DT.DIR => .directory,
        std.c.DT.LNK => .symlink,
        else => .other,
    };
}

fn linuxFileKindFromMode(mode: std.os.linux.mode_t) host.FileKind {
    const S = std.os.linux.S;
    if (S.ISBLK(mode)) return .block_device;
    if (S.ISCHR(mode)) return .character_device;
    if (S.ISREG(mode)) return .file;
    if (S.ISDIR(mode)) return .directory;
    if (S.ISFIFO(mode)) return .named_pipe;
    if (S.ISLNK(mode)) return .symlink;
    if (S.ISSOCK(mode)) return .socket;
    return .other;
}

fn libcFileKindFromMode(mode: std.c.mode_t) host.FileKind {
    const S = std.c.S;
    if (S.ISBLK(mode)) return .block_device;
    if (S.ISCHR(mode)) return .character_device;
    if (S.ISREG(mode)) return .file;
    if (S.ISDIR(mode)) return .directory;
    if (S.ISFIFO(mode)) return .named_pipe;
    if (S.ISLNK(mode)) return .symlink;
    if (S.ISSOCK(mode)) return .socket;
    return .other;
}

fn linuxSpawn(request: host.SpawnRequest) SpawnError!host.SpawnResult {
    const linux = std.os.linux;
    const fork_rc = linux.fork();
    switch (linux.errno(fork_rc)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }

    const pid: i32 = @intCast(fork_rc);
    if (pid == 0) {
        if (request.process_group) |process_group| linuxSetProcessGroup(0, process_group) catch linux.exit(127);
        applyDefaultSignals(request.default_signals) catch linux.exit(127);
        applyLinuxFdActions(request.fd_actions);
        const exec_rc = linux.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
        if (linux.errno(exec_rc) == .NOEXEC) {
            if (request.fallback_argv) |argv| _ = linux.execve(default_shell_path.ptr, argv.ptr, request.envp.ptr);
        }
        linux.exit(127);
    }

    return .{ .pid = pid };
}

fn linuxExec(request: host.SpawnRequest) SpawnError!void {
    const linux = std.os.linux;
    if (request.process_group) |process_group| linuxSetProcessGroup(0, process_group) catch return error.Unexpected;
    applyDefaultSignals(request.default_signals) catch return error.Unexpected;
    applyLinuxFdActions(request.fd_actions);
    const exec_rc = linux.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
    if (linux.errno(exec_rc) == .NOEXEC) {
        if (request.fallback_argv) |argv| _ = linux.execve(default_shell_path.ptr, argv.ptr, request.envp.ptr);
    }
    return error.Unexpected;
}

fn linuxWait(pid: host.Pid) WaitError!host.WaitStatus {
    const linux = std.os.linux;
    var status: u32 = 0;
    while (true) {
        const wait_rc = linux.waitpid(pid, &status, 0);
        switch (linux.errno(wait_rc)) {
            .SUCCESS => return decodeWaitStatus(status),
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn linuxWaitNonBlocking(pid: host.Pid) WaitError!?host.WaitStatus {
    const linux = std.os.linux;
    var status: u32 = 0;
    while (true) {
        const wait_rc = linux.waitpid(pid, &status, linux.W.NOHANG | linux.W.UNTRACED);
        switch (linux.errno(wait_rc)) {
            .SUCCESS => return if (wait_rc == 0) null else decodeWaitStatus(status),
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn linuxWaitJobEvent(pid: host.Pid) WaitError!host.WaitStatus {
    const linux = std.os.linux;
    var status: u32 = 0;
    while (true) {
        const wait_rc = linux.waitpid(pid, &status, linux.W.UNTRACED);
        switch (linux.errno(wait_rc)) {
            .SUCCESS => return decodeWaitStatus(status),
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn linuxWaitJobEventInterruptible(pid: host.Pid) WaitError!host.WaitStatus {
    const linux = std.os.linux;
    var status: u32 = 0;
    while (true) {
        const wait_rc = linux.waitpid(pid, &status, linux.W.UNTRACED);
        switch (linux.errno(wait_rc)) {
            .SUCCESS => return decodeWaitStatus(status),
            .INTR => if (peekPendingSignal()) |signal| return .{ .signaled = signal } else continue,
            else => return error.Unexpected,
        }
    }
}

fn linuxWaitInterruptible(pid: host.Pid) WaitError!host.WaitStatus {
    const linux = std.os.linux;
    var status: u32 = 0;
    while (true) {
        const wait_rc = linux.waitpid(pid, &status, 0);
        switch (linux.errno(wait_rc)) {
            .SUCCESS => return decodeWaitStatus(status),
            .INTR => if (peekPendingSignal()) |signal| return .{ .signaled = signal } else continue,
            else => return error.Unexpected,
        }
    }
}

fn libcSpawn(request: host.SpawnRequest) SpawnError!host.SpawnResult {
    const fork_rc = std.c.fork();
    switch (std.c.errno(fork_rc)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }

    const pid: i32 = @intCast(fork_rc);
    if (pid == 0) {
        if (request.process_group) |process_group| libcSetProcessGroup(0, process_group) catch std.c._exit(127);
        applyDefaultSignals(request.default_signals) catch std.c._exit(127);
        applyLibcFdActions(request.fd_actions);
        const exec_rc = std.c.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
        if (std.c.errno(exec_rc) == .NOEXEC) {
            if (request.fallback_argv) |argv| _ = std.c.execve(default_shell_path.ptr, argv.ptr, request.envp.ptr);
        }
        std.c._exit(127);
    }

    return .{ .pid = pid };
}

fn libcExec(request: host.SpawnRequest) SpawnError!void {
    if (request.process_group) |process_group| libcSetProcessGroup(0, process_group) catch return error.Unexpected;
    applyDefaultSignals(request.default_signals) catch return error.Unexpected;
    applyLibcFdActions(request.fd_actions);
    const exec_rc = std.c.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
    if (std.c.errno(exec_rc) == .NOEXEC) {
        if (request.fallback_argv) |argv| _ = std.c.execve(default_shell_path.ptr, argv.ptr, request.envp.ptr);
    }
    return error.Unexpected;
}

const default_shell_path: [:0]const u8 = "/bin/sh";

fn libcWait(pid: host.Pid) WaitError!host.WaitStatus {
    var status: c_int = 0;
    while (true) {
        const wait_rc = std.c.waitpid(pid, &status, 0);
        switch (std.c.errno(wait_rc)) {
            .SUCCESS => return decodeWaitStatus(@bitCast(status)),
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn libcWaitNonBlocking(pid: host.Pid) WaitError!?host.WaitStatus {
    var status: c_int = 0;
    while (true) {
        const wait_rc = std.c.waitpid(pid, &status, std.c.W.NOHANG | std.c.W.UNTRACED);
        switch (std.c.errno(wait_rc)) {
            .SUCCESS => return if (wait_rc == 0) null else decodeWaitStatus(@bitCast(status)),
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn libcWaitJobEvent(pid: host.Pid) WaitError!host.WaitStatus {
    var status: c_int = 0;
    while (true) {
        const wait_rc = std.c.waitpid(pid, &status, std.c.W.UNTRACED);
        switch (std.c.errno(wait_rc)) {
            .SUCCESS => return decodeWaitStatus(@bitCast(status)),
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn libcWaitJobEventInterruptible(pid: host.Pid) WaitError!host.WaitStatus {
    var status: c_int = 0;
    while (true) {
        const wait_rc = std.c.waitpid(pid, &status, std.c.W.UNTRACED);
        switch (std.c.errno(wait_rc)) {
            .SUCCESS => return decodeWaitStatus(@bitCast(status)),
            .INTR => if (peekPendingSignal()) |signal| return .{ .signaled = signal } else continue,
            else => return error.Unexpected,
        }
    }
}

fn libcWaitInterruptible(pid: host.Pid) WaitError!host.WaitStatus {
    var status: c_int = 0;
    while (true) {
        const wait_rc = std.c.waitpid(pid, &status, 0);
        switch (std.c.errno(wait_rc)) {
            .SUCCESS => return decodeWaitStatus(@bitCast(status)),
            .INTR => if (peekPendingSignal()) |signal| return .{ .signaled = signal } else continue,
            else => return error.Unexpected,
        }
    }
}

fn applyDefaultSignals(signals: []const u8) SignalDispositionError!void {
    for (signals) |signal| try real_host.setSignalDefault(signal);
}

fn applyLinuxFdActions(actions: []const host.SpawnFdAction) void {
    const linux = std.os.linux;
    for (actions) |action| switch (action) {
        .close => |fd| {
            const rc = linux.close(fd.raw());
            if (linux.errno(rc) != .SUCCESS) linux.exit(127);
        },
        .duplicate => |dup| {
            const rc = linux.dup2(dup.from.raw(), dup.to.raw());
            if (linux.errno(rc) != .SUCCESS) linux.exit(127);
        },
    };
}

fn applyLibcFdActions(actions: []const host.SpawnFdAction) void {
    for (actions) |action| switch (action) {
        .close => |fd| {
            const rc = std.c.close(@intCast(fd.raw()));
            if (std.c.errno(rc) != .SUCCESS) std.c._exit(127);
        },
        .duplicate => |dup| {
            const rc = std.c.dup2(@intCast(dup.from.raw()), @intCast(dup.to.raw()));
            if (std.c.errno(rc) != .SUCCESS) std.c._exit(127);
        },
    };
}

fn resourceLimitKind(kind: host.ResourceLimitKind) std.posix.rlimit_resource {
    return switch (kind) {
        .core => .CORE,
        .data => .DATA,
        .file_size => .FSIZE,
        .open_files => .NOFILE,
        .stack => .STACK,
        .cpu_time => .CPU,
        .address_space => .AS,
    };
}

fn resourceLimitFromNative(value: @TypeOf(std.posix.RLIM.INFINITY)) ?u64 {
    if (value == std.posix.RLIM.INFINITY) return null;
    return @intCast(value);
}

fn resourceLimitToNative(value: ?u64) ResourceLimitError!@TypeOf(std.posix.RLIM.INFINITY) {
    const native = value orelse return std.posix.RLIM.INFINITY;
    return std.math.cast(@TypeOf(std.posix.RLIM.INFINITY), native) orelse error.LimitTooBig;
}

fn decodeWaitStatus(status: u32) host.WaitStatus {
    if ((status & 0xffff) == 0xffff) return .continued;
    if ((status & 0xff) == 0x7f) return .{ .stopped = @intCast((status >> 8) & 0xff) };
    if ((status & 0x7f) == 0) return .{ .exited = @intCast((status >> 8) & 0xff) };
    return .{ .signaled = @intCast(status & 0x7f) };
}

fn linuxOpenFlags(options: host.OpenOptions) std.os.linux.O {
    var flags: std.os.linux.O = .{ .ACCMODE = accessMode(std.posix.ACCMODE, options.access) };
    flags.CREAT = options.create;
    flags.TRUNC = options.truncate;
    flags.APPEND = options.append;
    flags.EXCL = options.exclusive;
    return flags;
}

fn libcOpenFlags(options: host.OpenOptions) std.c.O {
    var flags: std.c.O = .{ .ACCMODE = accessMode(std.posix.ACCMODE, options.access) };
    flags.CREAT = options.create;
    flags.TRUNC = options.truncate;
    flags.APPEND = options.append;
    flags.EXCL = options.exclusive;
    return flags;
}

fn accessMode(comptime AccessMode: type, access: host.OpenAccess) AccessMode {
    return switch (access) {
        .read_only => .RDONLY,
        .write_only => .WRONLY,
        .read_write => .RDWR,
    };
}
