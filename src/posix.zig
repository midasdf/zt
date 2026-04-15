//! Thin compatibility shim over std.os.linux / std.c for APIs that Zig 0.16.0
//! removed from std.posix. Keeps zt on a familiar ergonomic surface while the
//! stdlib continues churning.
//!
//! All wrappers are `inline` so the codegen is identical to calling
//! std.os.linux.* directly. Surviving std.posix items are re-exported as
//! aliases to keep call sites uniform.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

// Re-exports (unchanged in 0.16) --------------------------------------------
pub const fd_t = std.posix.fd_t;
pub const pid_t = std.posix.pid_t;
pub const mode_t = std.posix.mode_t;
pub const Kevent = std.posix.Kevent;
pub const timespec = std.posix.timespec;
pub const PROT = std.posix.PROT;
pub const SIG = std.posix.SIG;
pub const E = std.posix.E;
pub const O = std.posix.O;
pub const AF = std.posix.AF;
pub const F = std.posix.F;
pub const SOCK = std.posix.SOCK;
pub const SOL = std.posix.SOL;
pub const sockaddr = std.posix.sockaddr;
pub const iovec = std.posix.iovec;
pub const iovec_const = std.posix.iovec_const;
pub const mmap = std.posix.mmap;
pub const munmap = std.posix.munmap;
pub const read = std.posix.read;
pub const kill = std.posix.kill;
pub const unexpectedErrno = std.posix.unexpectedErrno;

// Missing-in-0.16 shims -----------------------------------------------------
pub const WriteError = error{
    WouldBlock,
    BrokenPipe,
    InputOutput,
    NoSpaceLeft,
    DiskQuota,
    FileTooBig,
    ConnectionResetByPeer,
    Unexpected,
};

pub inline fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    const rc = linux.write(fd, bytes.ptr, bytes.len);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => 0,
        .AGAIN => error.WouldBlock,
        .BADF => error.Unexpected,
        .DESTADDRREQ => error.Unexpected,
        .DQUOT => error.DiskQuota,
        .FAULT => unreachable,
        .FBIG => error.FileTooBig,
        .INVAL => error.Unexpected,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .PERM => error.Unexpected,
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionResetByPeer,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub inline fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub const PipeError = error{ SystemFdQuotaExceeded, ProcessFdQuotaExceeded, Unexpected };

pub inline fn pipe() PipeError![2]fd_t {
    var fds: [2]i32 = undefined;
    const rc = linux.pipe(&fds);
    return switch (linux.errno(rc)) {
        .SUCCESS => fds,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub inline fn pipe2(flags: linux.O) PipeError![2]fd_t {
    var fds: [2]i32 = undefined;
    const rc = linux.pipe2(&fds, flags);
    return switch (linux.errno(rc)) {
        .SUCCESS => fds,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub const ForkError = error{ SystemResources, Unexpected };

pub inline fn fork() ForkError!linux.pid_t {
    const rc = linux.fork();
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(@as(isize, @bitCast(rc))),
        .AGAIN, .NOMEM => error.SystemResources,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub const Dup2Error = error{Unexpected};

pub inline fn dup2(old_fd: fd_t, new_fd: fd_t) Dup2Error!void {
    const rc = linux.dup2(old_fd, new_fd);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub inline fn exit(status: u8) noreturn {
    linux.exit_group(status);
}

/// Caller (`main`) must call this once with `init.environ` before any
/// `getenv` invocation. Stored for later lookup since Zig 0.16 no longer
/// exposes a process-wide `std.os.environ`.
pub var environ: std.process.Environ = .empty;

/// Block the current thread for `nanoseconds`. Replacement for
/// `std.Thread.sleep` (removed in Zig 0.16).
pub inline fn sleep(nanoseconds: u64) void {
    var req: timespec = .{
        .sec = @intCast(nanoseconds / std.time.ns_per_s),
        .nsec = @intCast(nanoseconds % std.time.ns_per_s),
    };
    while (true) {
        const rc = linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = false }, &req, &req);
        if (linux.errno(rc) != .INTR) break;
    }
}

/// Monotonic-clock nanoseconds since boot. Replacement for
/// `std.time.nanoTimestamp` (removed in Zig 0.16).
pub inline fn nanoTimestamp() i128 {
    var ts: timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

pub inline fn getenv(key: []const u8) ?[]const u8 {
    return environ.getPosix(key);
}

/// Fork + exec replacement for `std.posix.execvpeZ` (removed in 0.16).
/// Falls back to raw execve via PATH search.
pub inline fn execvpeZ(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) error{Unexpected} {
    // Try file as an absolute or relative path first.
    _ = linux.execve(file, argv, envp);
    // Then walk PATH.
    const path = getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.splitScalar(u8, path, ':');
    const file_slice = std.mem.span(file);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, file_slice }) catch continue;
        _ = linux.execve(full.ptr, argv, envp);
    }
    return error.Unexpected;
}

// kqueue/kevent — macOS only. Stubs on Linux keep the file semantically valid
// but any call on Linux is a comptime reachability error at the call site,
// which zt already gates on builtin.os.tag.
pub inline fn kqueue() !i32 {
    if (builtin.os.tag == .macos) {
        return @intCast(std.c.kqueue());
    }
    @compileError("kqueue is macOS-only");
}

pub inline fn kevent(
    kq: i32,
    changelist: []const Kevent,
    eventlist: []Kevent,
    timeout: ?*const timespec,
) !usize {
    if (builtin.os.tag == .macos) {
        const rc = std.c.kevent(
            kq,
            changelist.ptr,
            @intCast(changelist.len),
            eventlist.ptr,
            @intCast(eventlist.len),
            timeout,
        );
        if (rc < 0) return error.Unexpected;
        return @intCast(rc);
    }
    @compileError("kevent is macOS-only");
}

pub const OpenError = error{
    FileNotFound,
    AccessDenied,
    IsDir,
    NotDir,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    NameTooLong,
    SystemResources,
    NoSpaceLeft,
    FileTooBig,
    WouldBlock,
    BadPathName,
    Unexpected,
};

pub inline fn open(path: []const u8, flags: linux.O, mode: linux.mode_t) OpenError!fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return openZ(@ptrCast(buf[0..path.len :0]), flags, mode);
}

pub const FcntlError = error{ Locked, ProcessFdQuotaExceeded, SystemFdQuotaExceeded, Unexpected };

pub inline fn fcntl(fd: fd_t, cmd: i32, arg: usize) FcntlError!usize {
    const rc = linux.fcntl(fd, cmd, arg);
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .ACCES, .AGAIN => error.Locked,
        .MFILE => error.ProcessFdQuotaExceeded,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub const TruncateError = error{ FileTooBig, InputOutput, AccessDenied, Unexpected };

pub inline fn ftruncate(fd: fd_t, length: u64) TruncateError!void {
    const rc = linux.ftruncate(fd, @intCast(length));
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .FBIG => error.FileTooBig,
        .IO => error.InputOutput,
        .PERM, .ACCES => error.AccessDenied,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub const SocketError = error{ AddressFamilyNotSupported, ProtocolFamilyNotAvailable, ProcessFdQuotaExceeded, SystemFdQuotaExceeded, SystemResources, ProtocolNotSupported, SocketTypeNotSupported, PermissionDenied, Unexpected };

pub inline fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!fd_t {
    const rc = linux.socket(domain, socket_type, protocol);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .PROTONOSUPPORT => error.ProtocolNotSupported,
        .PROTOTYPE => error.SocketTypeNotSupported,
        .ACCES => error.PermissionDenied,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub const ConnectError = error{ PermissionDenied, AddressInUse, AddressNotAvailable, AddressFamilyNotSupported, AlreadyConnected, ConnectionRefused, ConnectionResetByPeer, ConnectionTimedOut, NetworkUnreachable, FileNotFound, WouldBlock, Unexpected };

pub inline fn connect(sockfd: fd_t, sock_addr: *const anyopaque, len: u32) ConnectError!void {
    const rc = linux.connect(sockfd, sock_addr, len);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .ACCES, .PERM => error.PermissionDenied,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .ISCONN => error.AlreadyConnected,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.ConnectionTimedOut,
        .NETUNREACH => error.NetworkUnreachable,
        .NOENT => error.FileNotFound,
        .AGAIN, .INPROGRESS => error.WouldBlock,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

pub inline fn openZ(path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) OpenError!fd_t {
    const rc = linux.open(path, flags, mode);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES => error.AccessDenied,
        .EXIST => error.Unexpected,
        .FBIG => error.FileTooBig,
        .OVERFLOW => error.FileTooBig,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .NODEV => error.NoDevice,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .NOSPC => error.NoSpaceLeft,
        .NOTDIR => error.NotDir,
        .PERM => error.AccessDenied,
        .AGAIN => error.WouldBlock,
        else => |err| std.posix.unexpectedErrno(err),
    };
}
