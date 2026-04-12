const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const posix = std.posix;
const builtin = @import("builtin");
const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

comptime {
    if (!is_macos and !is_linux) {
        @compileError("PTY support is only implemented for Linux and macOS");
    }
}

const c = if (is_macos) @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
}) else struct {};

// ioctl constants — stored as u32 for Linux (linux.ioctl takes u32).
// On macOS, std.c.ioctl takes c_int, so callers use @bitCast(TIOCSWINSZ)
// to reinterpret the u32 bit pattern as c_int. The kernel reads the
// 32-bit request code from the low bits of the register regardless of
// sign extension — this matches how C compilers pass ioctl constants.
const TIOCSPTLCK: u32 = 0x40045431; // Linux only, not used on macOS
const TIOCGPTN: u32 = 0x80045430; // Linux only, not used on macOS
const TIOCSCTTY: u32 = if (is_macos) 0x20007461 else 0x540E;
const TIOCSWINSZ: u32 = if (is_macos) 0x80087467 else 0x5414;

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

fn shellBasename(shell_path: []const u8) []const u8 {
    const end = std.mem.lastIndexOfNone(u8, shell_path, "/") orelse return "sh";
    const trimmed = shell_path[0 .. end + 1];
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
    return if (slash) |idx| trimmed[idx + 1 ..] else trimmed;
}

fn makeLoginShellArg0(shell_path: []const u8, buf: *[256]u8) [:0]const u8 {
    const base = shellBasename(shell_path);
    const copy_len = @min(base.len, buf.len - 2);
    buf[0] = '-';
    @memcpy(buf[1..][0..copy_len], base[0..copy_len]);
    buf[1 + copy_len] = 0;
    return buf[0 .. 1 + copy_len :0];
}

pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,

    pub fn spawn(cols: u16, rows: u16, shell_path: [*:0]const u8, exec_argv: ?[]const [:0]const u8) !Pty {
        // 1. Open master PTY
        const master_fd: posix.fd_t = if (is_macos) blk: {
            // macOS: posix_openpt(O_RDWR | O_NOCTTY)
            // O_RDWR=2, O_NOCTTY=0x20000 on macOS
            const fd = c.posix_openpt(@as(c_int, 2 | 0x20000));
            if (fd < 0) return error.OpenFailed;
            // Set CLOEXEC to prevent master_fd leaking to child processes
            if (c.fcntl(fd, @as(c_int, 2), @as(c_int, 1)) < 0) { // F_SETFD=2, FD_CLOEXEC=1
                _ = c.close(fd);
                return error.OpenFailed;
            }
            break :blk @intCast(fd);
        } else try posix.open(
            "/dev/ptmx",
            .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true },
            0,
        );
        errdefer posix.close(master_fd);

        // 2. Unlock slave
        if (is_macos) {
            if (c.grantpt(master_fd) != 0) return error.IoctlFailed;
            if (c.unlockpt(master_fd) != 0) return error.IoctlFailed;
        } else {
            var unlock: c_int = 0;
            const unlock_rc = linux.ioctl(
                @intCast(master_fd),
                TIOCSPTLCK,
                @intFromPtr(&unlock),
            );
            if (@as(isize, @bitCast(unlock_rc)) < 0) return error.IoctlFailed;
        }

        // 3. Get slave pts path
        var slave_path_buf: [64]u8 = undefined;
        const slave_path: [:0]const u8 = if (is_macos) blk: {
            const name_ptr = c.ptsname(master_fd);
            if (name_ptr == null) return error.IoctlFailed;
            const name_slice = std.mem.span(name_ptr);
            if (name_slice.len + 1 > slave_path_buf.len) return error.PathTooLong;
            @memcpy(slave_path_buf[0..name_slice.len], name_slice);
            slave_path_buf[name_slice.len] = 0;
            break :blk slave_path_buf[0..name_slice.len :0];
        } else blk: {
            var pty_num: c_int = undefined;
            const ptn_rc = linux.ioctl(
                @intCast(master_fd),
                TIOCGPTN,
                @intFromPtr(&pty_num),
            );
            if (@as(isize, @bitCast(ptn_rc)) < 0) return error.IoctlFailed;
            break :blk std.fmt.bufPrintZ(
                &slave_path_buf,
                "/dev/pts/{d}",
                .{pty_num},
            ) catch return error.PathTooLong;
        };

        // 4. Fork
        const pid = try posix.fork();

        if (pid == 0) {
            // === Child process ===
            // Close master in child
            posix.close(master_fd);

            // a. Create new session
            if (is_macos) {
                _ = std.c.setsid();
            } else {
                _ = linux.syscall0(.setsid);
            }

            // Reset signal mask — parent may have blocked signals for signalfd
            if (is_linux) {
                var empty_set = linux.sigemptyset();
                _ = linux.sigprocmask(linux.SIG.SETMASK, &empty_set, null);
            }

            // b. Open slave fd
            const slave_fd = posix.open(
                slave_path,
                .{ .ACCMODE = .RDWR },
                0,
            ) catch {
                std.posix.exit(1);
            };

            // c. Set controlling terminal
            if (is_macos) {
                _ = std.c.ioctl(@intCast(slave_fd), @bitCast(TIOCSCTTY), @as(c_int, 0));
            } else {
                _ = linux.ioctl(@intCast(slave_fd), TIOCSCTTY, 0);
            }

            // f. Set window size before dup2
            var ws = Winsize{ .ws_row = rows, .ws_col = cols };
            if (is_macos) {
                _ = std.c.ioctl(@intCast(slave_fd), @bitCast(TIOCSWINSZ), @intFromPtr(&ws));
            } else {
                _ = linux.ioctl(@intCast(slave_fd), TIOCSWINSZ, @intFromPtr(&ws));
            }

            // d. Redirect stdin/stdout/stderr
            posix.dup2(slave_fd, 0) catch std.posix.exit(1);
            posix.dup2(slave_fd, 1) catch std.posix.exit(1);
            posix.dup2(slave_fd, 2) catch std.posix.exit(1);

            // e. Close original slave fd (now duped to 0/1/2)
            if (slave_fd > 2) posix.close(slave_fd);

            // g. Set up environment
            var col_env_buf: [32]u8 = undefined;
            var row_env_buf: [32]u8 = undefined;
            var shell_env_buf: [256]u8 = undefined;
            var home_env_buf: [256]u8 = undefined;
            var user_env_buf: [128]u8 = undefined;
            const col_env = std.fmt.bufPrintZ(&col_env_buf, "COLUMNS={d}", .{cols}) catch "COLUMNS=80";
            const row_env = std.fmt.bufPrintZ(&row_env_buf, "LINES={d}", .{rows}) catch "LINES=24";
            const shell_env = std.fmt.bufPrintZ(&shell_env_buf, "SHELL={s}", .{shell_path}) catch "SHELL=/bin/sh";

            // Inherit key environment variables from parent
            const home_val = std.posix.getenv("HOME") orelse "/root";
            const user_val = std.posix.getenv("USER") orelse "root";
            const lang_val = std.posix.getenv("LANG") orelse "C.UTF-8";
            const path_val = std.posix.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
            const home_env = std.fmt.bufPrintZ(&home_env_buf, "HOME={s}", .{home_val}) catch "HOME=/root";
            const user_env = std.fmt.bufPrintZ(&user_env_buf, "USER={s}", .{user_val}) catch "USER=root";
            var lang_env_buf: [64]u8 = undefined;
            const lang_env = std.fmt.bufPrintZ(&lang_env_buf, "LANG={s}", .{lang_val}) catch "LANG=C.UTF-8";
            var path_env_buf: [1024]u8 = undefined;
            const path_env = std.fmt.bufPrintZ(&path_env_buf, "PATH={s}", .{path_val}) catch "PATH=/usr/local/bin:/usr/bin:/bin";

            // Capacity 32 entries; currently max 15 used (10 base + 5 Linux display vars).
            // If adding more entries, verify ei stays < 31 (last slot must be null sentinel).
            var env_arr: [32:null]?[*:0]const u8 = .{null} ** 32;
            var ei: usize = 0;
            env_arr[ei] = "TERM=xterm-256color";
            ei += 1;
            env_arr[ei] = "COLORTERM=truecolor";
            ei += 1;
            env_arr[ei] = "TERM_PROGRAM=zt";
            ei += 1;
            env_arr[ei] = path_env;
            ei += 1;
            env_arr[ei] = lang_env;
            ei += 1;
            env_arr[ei] = shell_env;
            ei += 1;
            env_arr[ei] = home_env;
            ei += 1;
            env_arr[ei] = user_env;
            ei += 1;
            env_arr[ei] = col_env;
            ei += 1;
            env_arr[ei] = row_env;
            ei += 1;

            // X11 / Wayland display variables (Linux only)
            if (!is_macos) {
                var display_env_buf: [128]u8 = undefined;
                var wayland_env_buf: [128]u8 = undefined;
                var xauth_env_buf: [256]u8 = undefined;
                var xdg_runtime_buf: [256]u8 = undefined;
                var dbus_env_buf: [256]u8 = undefined;
                const display_env: ?[*:0]const u8 = if (std.posix.getenv("DISPLAY")) |_| (std.fmt.bufPrintZ(&display_env_buf, "DISPLAY={s}", .{std.posix.getenv("DISPLAY").?}) catch null) else null;
                const wayland_env: ?[*:0]const u8 = if (std.posix.getenv("WAYLAND_DISPLAY")) |_| (std.fmt.bufPrintZ(&wayland_env_buf, "WAYLAND_DISPLAY={s}", .{std.posix.getenv("WAYLAND_DISPLAY").?}) catch null) else null;
                const xauth_env: ?[*:0]const u8 = if (std.posix.getenv("XAUTHORITY")) |_| (std.fmt.bufPrintZ(&xauth_env_buf, "XAUTHORITY={s}", .{std.posix.getenv("XAUTHORITY").?}) catch null) else null;
                const xdg_runtime_env: ?[*:0]const u8 = if (std.posix.getenv("XDG_RUNTIME_DIR")) |_| (std.fmt.bufPrintZ(&xdg_runtime_buf, "XDG_RUNTIME_DIR={s}", .{std.posix.getenv("XDG_RUNTIME_DIR").?}) catch null) else null;
                const dbus_env: ?[*:0]const u8 = if (std.posix.getenv("DBUS_SESSION_BUS_ADDRESS")) |_| (std.fmt.bufPrintZ(&dbus_env_buf, "DBUS_SESSION_BUS_ADDRESS={s}", .{std.posix.getenv("DBUS_SESSION_BUS_ADDRESS").?}) catch null) else null;
                if (display_env) |e| {
                    env_arr[ei] = e;
                    ei += 1;
                }
                if (wayland_env) |e| {
                    env_arr[ei] = e;
                    ei += 1;
                }
                if (xauth_env) |e| {
                    env_arr[ei] = e;
                    ei += 1;
                }
                if (xdg_runtime_env) |e| {
                    env_arr[ei] = e;
                    ei += 1;
                }
                if (dbus_env) |e| {
                    env_arr[ei] = e;
                    ei += 1;
                }
            }

            const env: [*:null]const ?[*:0]const u8 = &env_arr;

            // h. execvpe (PATH-searching exec)
            if (exec_argv) |eargv| {
                // -e mode: build null-terminated argv for execvpe
                var exec_ptrs: [64:null]?[*:0]const u8 = .{null} ** 64;
                const count = @min(eargv.len, 63);
                for (0..count) |idx| {
                    exec_ptrs[idx] = eargv[idx].ptr;
                }
                const exec_path: [*:0]const u8 = eargv[0].ptr;
                _ = posix.execvpeZ(exec_path, &exec_ptrs, env) catch {
                    _ = posix.write(2, "zt: execvpe failed\n") catch {};
                };
            } else {
                // Default: login shell. A leading '-' in argv[0] is portable across
                // POSIX sh, bash, zsh, fish, and similar shells; "--login" is not.
                var login_arg0_buf: [256]u8 = undefined;
                const login_arg0 = makeLoginShellArg0(std.mem.span(shell_path), &login_arg0_buf);
                const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{login_arg0.ptr};
                _ = posix.execvpeZ(shell_path, argv, env) catch {
                    _ = posix.write(2, "zt: execvpe failed\n") catch {};
                };
            }
            std.posix.exit(1);
        }

        // === Parent process ===
        // Set master_fd nonblocking
        {
            const cur_flags = try posix.fcntl(master_fd, posix.F.GETFL, 0);
            const O_NONBLOCK: usize = @intCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
            _ = try posix.fcntl(master_fd, posix.F.SETFL, cur_flags | O_NONBLOCK);
        }

        return Pty{
            .master_fd = master_fd,
            .child_pid = pid,
        };
    }

    pub fn deinit(self: *Pty) void {
        // Kill child first, then close — avoids SIGHUP+SIGTERM race
        posix.kill(self.child_pid, posix.SIG.TERM) catch {};
        posix.close(self.master_fd);
        // Use WNOHANG: child may already be reaped by SIGCHLD handler.
        // Use raw syscall because std.posix.waitpid panics on ECHILD.
        if (is_linux) {
            // wait4(pid, NULL, WNOHANG, NULL)
            _ = linux.syscall4(.wait4, @as(usize, @intCast(self.child_pid)), 0, linux.W.NOHANG, 0);
        } else {
            _ = std.c.waitpid(self.child_pid, null, 1); // WNOHANG=1
        }
    }

    pub fn read(self: *Pty, buf: []u8) !usize {
        return posix.read(self.master_fd, buf);
    }

    pub fn write(self: *Pty, data: []const u8) !usize {
        return posix.write(self.master_fd, data);
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        var ws = Winsize{ .ws_row = rows, .ws_col = cols };
        if (is_macos) {
            const rc = std.c.ioctl(@intCast(self.master_fd), @bitCast(TIOCSWINSZ), @intFromPtr(&ws));
            if (rc < 0) return error.IoctlFailed;
        } else {
            const rc = linux.ioctl(
                @intCast(self.master_fd),
                TIOCSWINSZ,
                @intFromPtr(&ws),
            );
            if (@as(isize, @bitCast(rc)) < 0) return error.IoctlFailed;
        }
    }
};

test "Pty: login shell argv0 uses portable leading dash" {
    var buf: [256]u8 = undefined;

    try testing.expectEqualSlices(u8, "-sh", makeLoginShellArg0("/bin/sh", &buf));
    try testing.expectEqualSlices(u8, "-fish", makeLoginShellArg0("/usr/bin/fish", &buf));
    try testing.expectEqualSlices(u8, "-zsh", makeLoginShellArg0("zsh", &buf));
    try testing.expectEqualSlices(u8, "-bin", makeLoginShellArg0("/usr/bin/", &buf));
}

test "Pty: spawn and read echo output" {
    // Skip when /dev/ptmx (Linux) is missing or invisible (e.g. restricted CI/sandbox).
    var pty = Pty.spawn(80, 24, "/bin/echo", null) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer pty.deinit();

    // Wait for output
    std.Thread.sleep(100 * std.time.ns_per_ms);

    var buf: [256]u8 = undefined;
    const n = pty.read(&buf) catch 0;
    // echo with no args outputs "\r\n" or "\n"
    try testing.expect(n > 0);
}
