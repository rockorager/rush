//! Host effects boundary for the rewritten shell.

const std = @import("std");
const zig_builtin = @import("builtin");

pub const RealHost = if (!zig_builtin.cpu.arch.isWasm())
    // ziglint-ignore: Z028 RealHost is omitted on wasm so posix is not analyzed
    @import("host/RealHost.zig")
else
    struct {};

pub const WasmHost = @import("host/WasmHost.zig");
pub const WasmSession = @import("host/WasmSession.zig");

pub const Fd = enum(i32) {
    stdin = 0,
    stdout = 1,
    stderr = 2,
    _,

    pub fn raw(self: Fd) i32 {
        return @intFromEnum(self);
    }
};

pub const Pid = i32;

pub const OpenAccess = enum {
    read_only,
    write_only,
    read_write,
};

pub const OpenOptions = struct {
    access: OpenAccess = .read_only,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    exclusive: bool = false,
    mode: u32 = 0o666,
};

pub const SeekError = error{Unexpected};

pub const Pipe = struct {
    read: Fd,
    write: Fd,
};

pub const FileKind = enum {
    block_device,
    character_device,
    file,
    directory,
    named_pipe,
    symlink,
    socket,
    other,
};

pub const FileStatus = struct {
    kind: FileKind,
    size: u64 = 0,
    mode: u32 = 0,
    device: u64 = 0,
    inode: u64 = 0,
    mtime_sec: i64 = 0,
    mtime_nsec: i64 = 0,

    pub fn sameFile(self: FileStatus, other: FileStatus) bool {
        return self.device == other.device and self.inode == other.inode;
    }

    pub fn newerThan(self: FileStatus, other: FileStatus) bool {
        return self.mtime_sec > other.mtime_sec or
            (self.mtime_sec == other.mtime_sec and self.mtime_nsec > other.mtime_nsec);
    }

    pub fn olderThan(self: FileStatus, other: FileStatus) bool {
        return self.mtime_sec < other.mtime_sec or
            (self.mtime_sec == other.mtime_sec and self.mtime_nsec < other.mtime_nsec);
    }
};

pub const FileAccess = enum {
    read,
    write,
    execute,
};

pub const DirectoryEntry = struct {
    name: []const u8,
    kind: FileKind = .other,

    pub fn validate(self: DirectoryEntry) void {
        std.debug.assert(self.name.len != 0);
    }
};

/// Deeply owns the entry slice and every entry name through `allocator`.
pub const ListDirResult = struct {
    allocator: std.mem.Allocator,
    entries: []const DirectoryEntry,

    pub fn deinit(self: *ListDirResult) void {
        for (self.entries) |entry| self.allocator.free(entry.name);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn validate(self: ListDirResult) void {
        for (self.entries) |entry| entry.validate();
    }
};

pub const ListDirError = error{
    AccessDenied,
    FileNotFound,
    NotDir,
    NameTooLong,
    SystemResources,
    Unexpected,
};

pub const DeleteFileError = error{
    AccessDenied,
    FileNotFound,
    NotDir,
    NameTooLong,
    Unexpected,
};

pub const ChangeDirError = error{
    AccessDenied,
    FileNotFound,
    NotDir,
    NameTooLong,
    Unexpected,
};

pub const CurrentDirError = error{
    AccessDenied,
    NameTooLong,
    Unexpected,
};

pub const FileStatusError = error{
    AccessDenied,
    FileNotFound,
    NotDir,
    NameTooLong,
    SystemResources,
    Unexpected,
};

pub const FdFlagError = error{
    BadFd,
    Unexpected,
};

pub const KillError = error{
    AccessDenied,
    NoSuchProcess,
    InvalidSignal,
    Unexpected,
};

pub const ProcessGroupError = error{
    AccessDenied,
    NoSuchProcess,
    Unexpected,
};

pub const TerminalProcessGroupError = error{
    NotATerminal,
    NotAPgrpMember,
    Unexpected,
};

pub const SignalDispositionError = error{
    InvalidSignal,
    Unexpected,
};

pub const ResourceLimitKind = enum {
    core,
    data,
    file_size,
    open_files,
    stack,
    cpu_time,
    address_space,
};

pub const ResourceLimit = struct {
    soft: ?u64,
    hard: ?u64,
};

pub const ResourceLimitError = error{
    PermissionDenied,
    LimitTooBig,
    Unexpected,
};

pub const SpawnFdAction = union(enum) {
    close: Fd,
    duplicate: struct {
        from: Fd,
        to: Fd,
    },
};

pub const SpawnRequest = struct {
    path: [:0]const u8,
    argv: [:null]const ?[*:0]const u8,
    fallback_argv: ?[:null]const ?[*:0]const u8 = null,
    envp: [:null]const ?[*:0]const u8,
    cwd: ?[]const u8 = null,
    fd_actions: []const SpawnFdAction = &.{},
    default_signals: []const u8 = &.{},
    ignored_signals: []const u8 = &.{},
    process_group: ?Pid = null,

    pub fn validate(self: SpawnRequest) void {
        std.debug.assert(self.path.len != 0);
        std.debug.assert(self.argv.len != 0);
        std.debug.assert(self.argv[0] != null);
        for (self.default_signals) |signal| std.debug.assert(signal != 0);
    }
};

pub const SpawnResult = struct {
    pid: Pid,
};

/// Child dispositions are installed before delivery of signals resumes after
/// fork. Ignores take precedence over defaults; the parent is unchanged.
pub const ForkOptions = struct {
    default_signals: []const u8 = &.{},
    ignored_signals: []const u8 = &.{},
};

pub const ForkResult = union(enum) {
    child,
    parent: Pid,
};

pub const CloseError = error{
    Interrupted,
    InputOutput,
    Unexpected,
};

pub const ReadError = error{
    WouldBlock,
    InputOutput,
    SystemResources,
    Unexpected,
};

pub const TimedReadResult = union(enum) {
    read: usize,
    timeout,
};

pub const DuplicateError = error{
    BadFd,
    Interrupted,
    SystemResources,
    Unexpected,
};

pub const PipeError = error{
    SystemResources,
    Unexpected,
};

pub const ForkError = error{
    SystemResources,
    Unexpected,
};

pub const WaitStatus = union(enum) {
    exited: u8,
    signaled: u8,
    stopped: u8,
    continued,

    pub fn shellStatus(self: WaitStatus) u8 {
        return switch (self) {
            .exited => |status| status,
            .signaled => |signal| 128 + signal,
            .stopped => |signal| 128 + signal,
            .continued => 0,
        };
    }
};

/// An interrupted wait may also have consumed a child event. The caller must
/// retain that event for a later wait rather than treating interruption as death.
pub const InterruptibleWait = union(enum) {
    status: WaitStatus,
    interrupted: struct { signal: u8, status: ?WaitStatus = null },

    pub fn shellStatus(self: InterruptibleWait) u8 {
        return switch (self) {
            .status => |status| status.shellStatus(),
            .interrupted => |interrupted| 128 + interrupted.signal,
        };
    }
};

test {
    _ = WasmHost;
    _ = WasmSession;
}
