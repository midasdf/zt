const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const posix = std.posix;

// ioctl constants (Linux x86_64 / aarch64)
const TIOCSPTLCK: u32 = 0x40045431;
const TIOCGPTN: u32 = 0x80045430;
const TIOCSCTTY: u32 = 0x540E;
const TIOCSWINSZ: u32 = 0x5414;

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,

    pub fn spawn(cols: u16, rows: u16, shell_path: [*:0]const u8) !Pty {
        // 1. Open /dev/ptmx
        const master_fd = try posix.open(
            "/dev/ptmx",
            .{ .ACCMODE = .RDWR, .NOCTTY = true },
            0,
        );
        errdefer posix.close(master_fd);

        // 2. Unlock slave
        var unlock: c_int = 0;
        const unlock_rc = linux.ioctl(
            @intCast(master_fd),
            TIOCSPTLCK,
            @intFromPtr(&unlock),
        );
        if (unlock_rc != 0) return error.IoctlFailed;

        // 3. Get slave pts number
        var pty_num: c_int = undefined;
        const ptn_rc = linux.ioctl(
            @intCast(master_fd),
            TIOCGPTN,
            @intFromPtr(&pty_num),
        );
        if (ptn_rc != 0) return error.IoctlFailed;

        // Build slave path: "/dev/pts/" ++ number
        var slave_path_buf: [32]u8 = undefined;
        const slave_path = std.fmt.bufPrintZ(
            &slave_path_buf,
            "/dev/pts/{d}",
            .{pty_num},
        ) catch return error.PathTooLong;

        // 4. Fork
        const pid = try posix.fork();

        if (pid == 0) {
            // === Child process ===
            // Close master in child
            posix.close(master_fd);

            // a. Create new session
            _ = linux.syscall0(.setsid);

            // b. Open slave fd
            const slave_fd = posix.open(
                slave_path,
                .{ .ACCMODE = .RDWR },
                0,
            ) catch {
                std.posix.exit(1);
            };

            // c. Set controlling terminal
            _ = linux.ioctl(@intCast(slave_fd), TIOCSCTTY, 0);

            // f. Set window size before dup2
            var ws = Winsize{ .ws_row = rows, .ws_col = cols };
            _ = linux.ioctl(@intCast(slave_fd), TIOCSWINSZ, @intFromPtr(&ws));

            // d. Redirect stdin/stdout/stderr
            posix.dup2(slave_fd, 0) catch std.posix.exit(1);
            posix.dup2(slave_fd, 1) catch std.posix.exit(1);
            posix.dup2(slave_fd, 2) catch std.posix.exit(1);

            // e. Close original slave fd (now duped to 0/1/2)
            if (slave_fd > 2) posix.close(slave_fd);

            // g. Set up environment
            var col_env_buf: [32]u8 = undefined;
            var row_env_buf: [32]u8 = undefined;
            const col_env = std.fmt.bufPrintZ(&col_env_buf, "COLUMNS={d}", .{cols}) catch "COLUMNS=80";
            const row_env = std.fmt.bufPrintZ(&row_env_buf, "LINES={d}", .{rows}) catch "LINES=24";

            const env: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
                "TERM=xterm-256color",
                "COLORTERM=truecolor",
                "PATH=/usr/local/bin:/usr/bin:/bin",
                "LANG=en_US.UTF-8",
                col_env,
                row_env,
            };

            // h. execve
            const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
                shell_path,
            };

            _ = posix.execveZ(shell_path, argv, env) catch {};
            std.posix.exit(1);
        }

        // === Parent process ===
        // Set master_fd nonblocking
        const F_GETFL = 3;
        const F_SETFL = 4;
        const O_NONBLOCK = 0x800;
        const flags = try posix.fcntl(master_fd, F_GETFL, 0);
        _ = try posix.fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);

        return Pty{
            .master_fd = master_fd,
            .child_pid = pid,
        };
    }

    pub fn deinit(self: *Pty) void {
        posix.close(self.master_fd);
        // Kill child if still running
        posix.kill(self.child_pid, posix.SIG.TERM) catch {};
        _ = posix.waitpid(self.child_pid, 0);
    }

    pub fn read(self: *Pty, buf: []u8) !usize {
        return posix.read(self.master_fd, buf);
    }

    pub fn write(self: *Pty, data: []const u8) !usize {
        return posix.write(self.master_fd, data);
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        var ws = Winsize{ .ws_row = rows, .ws_col = cols };
        const rc = linux.ioctl(
            @intCast(self.master_fd),
            TIOCSWINSZ,
            @intFromPtr(&ws),
        );
        if (rc != 0) return error.IoctlFailed;
    }
};

test "Pty: spawn and read echo output" {
    var pty = try Pty.spawn(80, 24, "/bin/echo");
    defer pty.deinit();

    // Wait for output
    std.Thread.sleep(100 * std.time.ns_per_ms);

    var buf: [256]u8 = undefined;
    const n = pty.read(&buf) catch 0;
    // echo with no args outputs "\r\n" or "\n"
    try testing.expect(n > 0);
}
