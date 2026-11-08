//! Terminal attribute access that is safe when libc is linked.
//!
//! On Linux, `std.posix.termios` is the kernel's struct even when libc is
//! linked, but `std.posix.tcgetattr` then calls the C library, whose struct
//! termios is larger (60 bytes against 44 with glibc on x86_64) and overruns
//! the caller's stack. The ioctl fills the kernel struct exactly, so Linux
//! goes through the system call; other systems use `std.posix`, whose struct
//! matches their C library.

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const linux = std.os.linux;

pub fn tcgetattr(fd: posix.fd_t) posix.TermiosGetError!posix.termios {
    if (builtin.os.tag != .linux) return posix.tcgetattr(fd);
    while (true) {
        var term: posix.termios = undefined;
        switch (linux.errno(linux.tcgetattr(fd, &term))) {
            .SUCCESS => return term,
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn tcsetattr(fd: posix.fd_t, action: posix.TCSA, term: posix.termios) posix.TermiosSetError!void {
    if (builtin.os.tag != .linux) return posix.tcsetattr(fd, action, term);
    while (true) {
        switch (linux.errno(linux.tcsetattr(fd, action, &term))) {
            .SUCCESS => return,
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            .IO => return error.ProcessOrphaned,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}
