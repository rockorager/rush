//! Signal wake pipes and raw fd helpers for the editor driver.

const std = @import("std");
const builtin = @import("builtin");

const event_loop = @import("../event_loop.zig");

const log = std.log.scoped(.editor_signal);
const invalid_fd: std.posix.fd_t = -1;

const ResizeSignalFd = struct {
    var value: std.atomic.Value(std.posix.fd_t) = .init(invalid_fd);
    var pending: std.atomic.Value(bool) = .init(false);
};

const ChildSignalFd = struct {
    var value: std.atomic.Value(std.posix.fd_t) = .init(invalid_fd);
    var pending: std.atomic.Value(bool) = .init(false);
};

pub const Pipe = struct {
    read: std.Io.File,
    write: std.Io.File,

    pub fn close(self: *Pipe, io: std.Io) void {
        self.read.close(io);
        self.write.close(io);
        self.* = undefined;
    }
};

pub const ResizeSource = struct {
    pipe: ?Pipe,
    previous: ?std.posix.Sigaction,

    pub fn init(io: std.Io) !ResizeSource {
        var pipe = try makePipe(io);
        errdefer pipe.close(io);
        try setNonBlocking(pipe.read.handle);
        try setNonBlocking(pipe.write.handle);

        ResizeSignalFd.pending.store(false, .release);
        ResizeSignalFd.value.store(pipe.write.handle, .release);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = resizeSignalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var previous: std.posix.Sigaction = undefined;
        std.posix.sigaction(.WINCH, &action, &previous);
        return .{ .pipe = pipe, .previous = previous };
    }

    pub fn readFd(self: ResizeSource) std.posix.fd_t {
        return self.pipe.?.read.handle;
    }

    pub fn drain(self: *ResizeSource) void {
        const pipe = self.pipe orelse return;
        drainPendingSignalPipe(pipe.read.handle, &ResizeSignalFd.pending);
    }

    pub fn disable(self: *ResizeSource, io: std.Io, loop: *event_loop.EventLoop) !void {
        ResizeSignalFd.value.store(invalid_fd, .release);
        ResizeSignalFd.pending.store(false, .release);
        if (self.previous) |previous| {
            std.posix.sigaction(.WINCH, &previous, null);
            self.previous = null;
        }
        if (self.pipe) |*pipe| {
            try loop.removeFd(pipe.read.handle);
            pipe.close(io);
            self.pipe = null;
        }
    }

    pub fn deinit(self: *ResizeSource, io: std.Io, loop: *event_loop.EventLoop) void {
        self.disable(io, loop) catch |err| log.debug("failed to disable resize signal source: {}", .{err});
        self.* = undefined;
    }

    pub fn deinitUnregistered(self: *ResizeSource, io: std.Io) void {
        ResizeSignalFd.value.store(invalid_fd, .release);
        ResizeSignalFd.pending.store(false, .release);
        if (self.previous) |previous| std.posix.sigaction(.WINCH, &previous, null);
        if (self.pipe) |*pipe| pipe.close(io);
        self.* = undefined;
    }
};

fn resizeSignalHandler(_: std.posix.SIG) callconv(.c) void {
    const fd = ResizeSignalFd.value.load(.acquire);
    if (fd == invalid_fd) return;
    if (ResizeSignalFd.pending.swap(true, .acq_rel)) return;
    _ = std.c.write(fd, "r", 1);
}

pub const ChildSource = struct {
    pipe: ?Pipe,
    previous: ?std.posix.Sigaction,

    pub fn init(io: std.Io) !ChildSource {
        var pipe = try makePipe(io);
        errdefer pipe.close(io);
        try setNonBlocking(pipe.read.handle);
        try setNonBlocking(pipe.write.handle);

        ChildSignalFd.pending.store(false, .release);
        ChildSignalFd.value.store(pipe.write.handle, .release);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = childSignalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var previous: std.posix.Sigaction = undefined;
        std.posix.sigaction(.CHLD, &action, &previous);
        return .{ .pipe = pipe, .previous = previous };
    }

    pub fn readFd(self: ChildSource) std.posix.fd_t {
        return self.pipe.?.read.handle;
    }

    pub fn drain(self: *ChildSource) void {
        const pipe = self.pipe orelse return;
        drainPendingSignalPipe(pipe.read.handle, &ChildSignalFd.pending);
    }

    pub fn deinit(self: *ChildSource, io: std.Io, loop: *event_loop.EventLoop) void {
        ChildSignalFd.value.store(invalid_fd, .release);
        ChildSignalFd.pending.store(false, .release);
        if (self.previous) |previous| {
            std.posix.sigaction(.CHLD, &previous, null);
            self.previous = null;
        }
        if (self.pipe) |*pipe| {
            loop.removeFd(pipe.read.handle) catch |err| log.debug("failed to remove child signal fd: {}", .{err});
            pipe.close(io);
            self.pipe = null;
        }
        self.* = undefined;
    }

    pub fn deinitUnregistered(self: *ChildSource, io: std.Io) void {
        ChildSignalFd.value.store(invalid_fd, .release);
        ChildSignalFd.pending.store(false, .release);
        if (self.previous) |previous| std.posix.sigaction(.CHLD, &previous, null);
        if (self.pipe) |*pipe| pipe.close(io);
        self.* = undefined;
    }
};

fn childSignalHandler(_: std.posix.SIG) callconv(.c) void {
    const fd = ChildSignalFd.value.load(.acquire);
    if (fd == invalid_fd) return;
    if (ChildSignalFd.pending.swap(true, .acq_rel)) return;
    _ = std.c.write(fd, "c", 1);
}

fn drainPendingSignalPipe(fd: std.posix.fd_t, pending: *std.atomic.Value(bool)) void {
    var buffer: [64]u8 = undefined;
    while (true) {
        // Clear before draining so a concurrent handler either writes a new
        // wake byte or is observed by the load below and consumed in this pass.
        pending.store(false, .release);
        while (true) {
            const n = rawRead(fd, &buffer) catch break;
            if (n == 0) break;
        }
        if (!pending.load(.acquire)) return;
    }
}

pub fn makePipe(io: std.Io) !Pipe {
    const fds = switch (builtin.target.os.tag) {
        .linux => blk: {
            var fds: [2]i32 = undefined;
            const rc = std.os.linux.pipe2(&fds, .{ .CLOEXEC = true });
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {},
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                else => return error.Unexpected,
            }
            break :blk .{ fds[0], fds[1] };
        },
        .macos, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => blk: {
            var fds: [2]std.c.fd_t = undefined;
            const rc = std.c.pipe(&fds);
            switch (std.c.errno(rc)) {
                .SUCCESS => {},
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                else => return error.Unexpected,
            }
            errdefer {
                closeFd(io, fds[0]);
                closeFd(io, fds[1]);
            }
            try setCloseOnExec(fds[0]);
            try setCloseOnExec(fds[1]);
            break :blk .{ fds[0], fds[1] };
        },
        else => return error.Unsupported,
    };

    return .{
        .read = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .write = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
}

pub fn rawRead(fd: std.posix.fd_t, buffer: []u8) !usize {
    while (true) {
        return std.posix.read(fd, buffer) catch |err| switch (err) {
            error.WouldBlock => return err,
            error.InputOutput => return err,
            error.IsDir => return err,
            error.SystemResources => return err,
            error.ConnectionResetByPeer => return err,
            error.Unexpected => return err,
            else => return err,
        };
    }
}

pub fn rawWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = try rawWrite(fd, remaining);
        remaining = remaining[written..];
    }
}

fn rawWrite(fd: std.posix.fd_t, bytes: []const u8) !usize {
    if (builtin.target.os.tag == .linux and !builtin.link_libc) {
        const rc = std.os.linux.write(fd, bytes.ptr, bytes.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return rc,
            .BADF => return error.BadFileDescriptor,
            .INTR => return rawWrite(fd, bytes),
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PIPE => return error.BrokenPipe,
            else => return error.Unexpected,
        }
    }
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, bytes.len);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PIPE => return error.BrokenPipe,
            else => return error.Unexpected,
        }
    }
}

fn closeFd(io: std.Io, fd: std.posix.fd_t) void {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.close(io);
}

fn setCloseOnExec(fd: std.posix.fd_t) !void {
    if (builtin.target.os.tag == .linux and !builtin.link_libc) return;
    const rc = std.c.fcntl(fd, @as(c_int, std.c.F.SETFD), @as(c_int, std.c.FD_CLOEXEC));
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        .BADF => return error.BadFileDescriptor,
        .INVAL => return error.Unexpected,
        else => return error.Unexpected,
    }
}

pub fn setNonBlocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, @as(c_int, std.c.F.GETFL));
    switch (std.c.errno(flags)) {
        .SUCCESS => {},
        .BADF => return error.BadFileDescriptor,
        else => return error.Unexpected,
    }
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const rc = std.c.fcntl(fd, @as(c_int, std.c.F.SETFL), flags | nonblock);
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        .BADF => return error.BadFileDescriptor,
        else => return error.Unexpected,
    }
}

test "child signal source reports SIGCHLD through event loop" {
    var source = try ChildSource.init(std.testing.io);
    var loop = try event_loop.EventLoop.init();
    defer loop.deinit();
    defer source.deinit(std.testing.io, &loop);
    try loop.addReadFd(source.readFd(), .child_signal);

    try std.posix.raise(.CHLD);

    var events: [4]event_loop.Event = undefined;
    const ready = try loop.waitTimeout(&events, 1000);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(event_loop.Source.child_signal, ready[0].source);
    source.drain();
}
