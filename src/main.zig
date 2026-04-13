const std = @import("std");
const builtin = @import("builtin");
const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const linux = if (is_linux) std.os.linux else struct {};
const config = @import("config");

const Term = @import("term.zig").Term;
const Cell = @import("term.zig").Cell;
const vt = @import("vt.zig");
const Pty = @import("pty.zig").Pty;
const input = @import("input.zig");
const render = @import("render.zig");
const font_mod = @import("font.zig");

// Backend selection at comptime
const Backend = switch (config.backend) {
    .fbdev => @import("backend/fbdev.zig").FbdevBackend,
    .x11 => @import("backend/x11.zig").X11Backend,
    .wayland => @import("backend/wayland.zig").WaylandBackend,
    .macos => @import("backend/macos.zig").MacosBackend,
};

const BackendEvent = switch (config.backend) {
    .x11 => @import("backend/x11.zig").Event,
    .wayland => @import("backend/wayland.zig").Event,
    .macos => @import("backend/macos.zig").Event,
    .fbdev => void,
};

const BackendMouseEvent = switch (config.backend) {
    .x11 => @import("backend/x11.zig").MouseEvent,
    .wayland => @import("backend/wayland.zig").MouseEvent,
    .macos => @import("backend/macos.zig").MouseEvent,
    .fbdev => void,
};
const MouseButton = if (config.backend == .fbdev) enum { none } else BackendMouseEvent.Button;

const EncodedMouse = struct {
    data: [32]u8 = undefined,
    len: u8 = 0,

    fn slice(self: *const EncodedMouse) []const u8 {
        return self.data[0..self.len];
    }
};

// Embed font at comptime
// Large fonts use pre-compiled blob (bdf2blob.py) to avoid slow comptime parsing
const FontType = font_mod.FontBlob(@embedFile("fonts/ufo-nf.bin"));

// =============================================================================
// Signal handling via signalfd
// =============================================================================

fn setupSignals() !std.posix.fd_t {
    if (is_linux) {
        var mask = linux.sigemptyset();
        linux.sigaddset(&mask, linux.SIG.CHLD);
        linux.sigaddset(&mask, linux.SIG.TERM);
        linux.sigaddset(&mask, linux.SIG.INT);
        linux.sigaddset(&mask, linux.SIG.HUP);
        linux.sigaddset(&mask, linux.SIG.USR1);
        linux.sigaddset(&mask, linux.SIG.USR2);

        // SIG_BLOCK = 0
        _ = linux.sigprocmask(0, &mask, null);

        // signalfd4(fd, mask, mask_size, flags)
        const SFD_NONBLOCK: u32 = 0o4000;
        const SFD_CLOEXEC: u32 = 0o2000000;
        const fd_raw = linux.syscall4(
            .signalfd4,
            @as(usize, @bitCast(@as(isize, -1))),
            @intFromPtr(&mask),
            @sizeOf(linux.sigset_t),
            SFD_NONBLOCK | SFD_CLOEXEC,
        );
        const fd_isize: isize = @bitCast(fd_raw);
        if (fd_isize < 0) return error.SignalFdFailed;
        return @intCast(fd_isize);
    } else {
        var mask = std.mem.zeroes(std.c.sigset_t);
        _ = std.c.sigaddset(&mask, std.c.SIG.CHLD);
        _ = std.c.sigaddset(&mask, std.c.SIG.TERM);
        _ = std.c.sigaddset(&mask, std.c.SIG.INT);
        _ = std.c.sigaddset(&mask, std.c.SIG.HUP);
        _ = std.c.sigprocmask(std.c.SIG.BLOCK, &mask, null);
        return -1;
    }
}

// =============================================================================
// Timer fd for cursor blink
// =============================================================================

fn createTimerFd(interval_ns: u64) !std.posix.fd_t {
    if (is_linux) {
        const fd_raw = linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        const fd_isize: isize = @bitCast(fd_raw);
        if (fd_isize < 0) return error.TimerFdFailed;
        const timer_fd: std.posix.fd_t = @intCast(fd_isize);

        const sec: isize = @intCast(interval_ns / std.time.ns_per_s);
        const nsec: isize = @intCast(interval_ns % std.time.ns_per_s);
        const ts = linux.timespec{ .sec = sec, .nsec = nsec };
        const spec = linux.itimerspec{ .it_interval = ts, .it_value = ts };
        const rc = linux.timerfd_settime(timer_fd, .{}, &spec, null);
        const rc_isize: isize = @bitCast(rc);
        if (rc_isize < 0) return error.TimerSetFailed;
        return timer_fd;
    } else {
        return -1;
    }
}

// =============================================================================
// Epoll helpers
// =============================================================================

const EpollTag = enum(u32) {
    pty = 0,
    signal = 1,
    timer = 2,
    backend = 3,
    // evdev fds start at 10
};
const EVDEV_BASE: u32 = 10;

fn epollAdd(epoll_fd: i32, fd: std.posix.fd_t, tag: u32) !void {
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .u32 = tag },
    };
    const rc = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev);
    const rc_isize: isize = @bitCast(rc);
    if (rc_isize < 0) return error.EpollCtlFailed;
}

fn epollSetPtyEvents(epoll_fd: i32, pty_fd: std.posix.fd_t, want_write: bool) void {
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN | if (want_write) linux.EPOLL.OUT else @as(u32, 0),
        .data = .{ .u32 = @intFromEnum(EpollTag.pty) },
    };
    _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_MOD, pty_fd, &ev);
}

// =============================================================================
// kqueue helpers (macOS)
// =============================================================================

// kqueue ident tags (macOS) — used in udata field for fd-based filters
const KqueueTag = enum(usize) {
    pty = 0,
    backend = 1,
};

// Timer and signal idents use their own filter types in kqueue,
// so they're identified by filter+ident, not by a tag.
const KQUEUE_TIMER_IDENT: usize = 100;

fn kqueueAddFd(kq: i32, fd: std.posix.fd_t, tag: usize) !void {
    const changelist = [1]std.posix.Kevent{.{
        .ident = @intCast(fd),
        .filter = std.c.EVFILT.READ,
        .flags = std.c.EV.ADD,
        .fflags = 0,
        .data = 0,
        .udata = tag,
    }};
    _ = try std.posix.kevent(kq, &changelist, &.{}, null);
}

fn kqueueAddSignal(kq: i32, sig: u6) !void {
    const changelist = [1]std.posix.Kevent{.{
        .ident = sig,
        .filter = std.c.EVFILT.SIGNAL,
        .flags = std.c.EV.ADD,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    _ = try std.posix.kevent(kq, &changelist, &.{}, null);
}

fn kqueueAddTimer(kq: i32, ident: usize, interval_ms: isize) !void {
    const changelist = [1]std.posix.Kevent{.{
        .ident = ident,
        .filter = std.c.EVFILT.TIMER,
        .flags = std.c.EV.ADD,
        .fflags = 0, // default unit is milliseconds
        .data = interval_ms,
        .udata = 0,
    }};
    _ = try std.posix.kevent(kq, &changelist, &.{}, null);
}

fn kqueueSetPtyWrite(kq: i32, pty_fd: std.posix.fd_t, enable: bool) void {
    const flags: u16 = std.c.EV.ADD | if (enable) @as(u16, std.c.EV.ENABLE) else @as(u16, std.c.EV.DISABLE);
    const changelist = [1]std.posix.Kevent{.{
        .ident = @intCast(pty_fd),
        .filter = std.c.EVFILT.WRITE,
        .flags = flags,
        .fflags = 0,
        .data = 0,
        .udata = @intFromEnum(KqueueTag.pty),
    }};
    _ = std.posix.kevent(kq, &changelist, &.{}, null) catch |err| {
        std.log.debug("kqueueSetPtyWrite failed: {}", .{err});
    };
}

/// Write to PTY with buffering on WouldBlock.
/// Uses a 64KB buffer to avoid truncation on large pastes or IME commits.
fn ptyBufferedWrite(
    pty_ptr: *Pty,
    data: []const u8,
    write_buf: *[65536]u8,
    write_pending: *usize,
    epoll_fd: i32,
) bool {
    // If there's pending data, append to buffer (retry-write remaining on overflow)
    if (write_pending.* > 0) {
        const space = write_buf.len - write_pending.*;
        if (data.len <= space) {
            @memcpy(write_buf[write_pending.* .. write_pending.* + data.len], data);
            write_pending.* += data.len;
            return true;
        }
        // Buffer full — try flushing pending data first to make room
        const flushed = pty_ptr.write(write_buf[0..write_pending.*]) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return false,
        };
        if (flushed > 0) {
            const remaining = write_pending.* - flushed;
            if (remaining > 0) {
                std.mem.copyForwards(u8, write_buf[0..remaining], write_buf[flushed .. flushed + remaining]);
            }
            write_pending.* = remaining;
        }
        // Append after flush — chunk if data exceeds remaining space
        const space2 = write_buf.len - write_pending.*;
        if (data.len <= space2) {
            @memcpy(write_buf[write_pending.* .. write_pending.* + data.len], data);
            write_pending.* += data.len;
            return true;
        }
        // Write what fits, then chunk the rest via direct writes
        if (space2 > 0) {
            @memcpy(write_buf[write_pending.* .. write_pending.* + space2], data[0..space2]);
            write_pending.* += space2;
        }
        // Flush buffer then write remaining data in chunks
        var rest = data[space2..];
        while (rest.len > 0) {
            if (write_pending.* > 0) {
                const f = pty_ptr.write(write_buf[0..write_pending.*]) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return false,
                };
                if (f > 0) {
                    const rem = write_pending.* - f;
                    if (rem > 0) std.mem.copyForwards(u8, write_buf[0..rem], write_buf[f .. f + rem]);
                    write_pending.* = rem;
                }
                if (write_pending.* == write_buf.len) return true; // still full, retry later
            }
            const chunk = @min(rest.len, write_buf.len - write_pending.*);
            if (chunk == 0) return true; // buffer full, will retry on next flush
            @memcpy(write_buf[write_pending.* .. write_pending.* + chunk], rest[0..chunk]);
            write_pending.* += chunk;
            rest = rest[chunk..];
        }
        return true;
    }

    // Try direct write
    const written = pty_ptr.write(data) catch |err| switch (err) {
        error.WouldBlock => {
            // Buffer everything — chunk if data exceeds buffer capacity
            const to_buf = @min(data.len, write_buf.len);
            if (data.len > write_buf.len)
                std.log.warn("PTY write truncated: {d} bytes dropped", .{data.len - write_buf.len});
            @memcpy(write_buf[0..to_buf], data[0..to_buf]);
            write_pending.* = to_buf;
            if (is_linux) {
                epollSetPtyEvents(epoll_fd, pty_ptr.master_fd, true);
            } else {
                kqueueSetPtyWrite(epoll_fd, pty_ptr.master_fd, true);
            }
            return true;
        },
        else => return false,
    };

    // Partial write — buffer the rest (truncate to buffer capacity)
    if (written < data.len) {
        const remaining = data.len - written;
        const to_buf = @min(remaining, write_buf.len);
        if (remaining > write_buf.len)
            std.log.warn("PTY write truncated: {d} bytes dropped", .{remaining - write_buf.len});
        @memcpy(write_buf[0..to_buf], data[written .. written + to_buf]);
        write_pending.* = to_buf;
        if (is_linux) {
            epollSetPtyEvents(epoll_fd, pty_ptr.master_fd, true);
        } else {
            kqueueSetPtyWrite(epoll_fd, pty_ptr.master_fd, true);
        }
    }
    return true;
}

/// Flush pending write buffer.
fn ptyFlushPending(
    pty_ptr: *Pty,
    write_buf: *[65536]u8,
    write_pending: *usize,
    epoll_fd: i32,
) bool {
    if (write_pending.* == 0) return true;

    const written = pty_ptr.write(write_buf[0..write_pending.*]) catch |err| switch (err) {
        error.WouldBlock => return true, // try again later
        else => return false,
    };

    if (written >= write_pending.*) {
        write_pending.* = 0;
        if (is_linux) {
            epollSetPtyEvents(epoll_fd, pty_ptr.master_fd, false);
        } else {
            kqueueSetPtyWrite(epoll_fd, pty_ptr.master_fd, false);
        }
    } else {
        // Shift remaining data to front
        const remaining = write_pending.* - written;
        std.mem.copyForwards(u8, write_buf[0..remaining], write_buf[written .. written + remaining]);
        write_pending.* = remaining;
    }
    return true;
}

/// Reset cursor blink idle tracking on user input (all backend dispatch paths use handleBackendEvent).
fn refreshCursorBlinkOnUserInput(
    cursor_visible_blink: *bool,
    cursor_blink_active: *bool,
    last_input_ns: *i128,
) void {
    cursor_visible_blink.* = true;
    cursor_blink_active.* = true;
    last_input_ns.* = std.time.nanoTimestamp();
}

fn applyCursorBlinkTimerTick(
    term: *Term,
    backend_focused: bool,
    last_input_ns: i128,
    cursor_blink_active: *bool,
    cursor_visible_blink: *bool,
    idle_timeout_ns: i128,
) void {
    if (!backend_focused) return;
    // Sample time here, not from the pre-epoll_wait loop timestamp: last_input_ns may be
    // updated later in the same iteration (focus_in / input), and reusing an older
    // `loop_now` makes idle_ns negative and misroutes the idle vs blink branches.
    const idle_ns = std.time.nanoTimestamp() - last_input_ns;
    if (idle_ns > idle_timeout_ns) {
        if (cursor_blink_active.*) {
            cursor_blink_active.* = false;
            cursor_visible_blink.* = true;
            term.markDirty(term.cursor_x, term.cursor_y);
        }
    } else {
        cursor_blink_active.* = true;
        cursor_visible_blink.* = !cursor_visible_blink.*;
        term.markDirty(term.cursor_x, term.cursor_y);
    }
}

// =============================================================================
// Signal handler
// =============================================================================

const SIG_CHLD = if (is_linux) linux.SIG.CHLD else std.c.SIG.CHLD;
const SIG_TERM = if (is_linux) linux.SIG.TERM else std.c.SIG.TERM;
const SIG_INT = if (is_linux) linux.SIG.INT else std.c.SIG.INT;
const SIG_HUP = if (is_linux) linux.SIG.HUP else std.c.SIG.HUP;
const SIG_USR1 = if (is_linux) linux.SIG.USR1 else std.c.SIG.USR1;
const SIG_USR2 = if (is_linux) linux.SIG.USR2 else std.c.SIG.USR2;

fn handleSignal(sig_fd: std.posix.fd_t, signo_override: ?u32, backend: *Backend) bool {
    const signo: u32 = signo_override orelse blk: {
        if (!is_linux) return true; // macOS always provides signo_override via kqueue
        var siginfo: linux.signalfd_siginfo = undefined;
        _ = std.posix.read(sig_fd, std.mem.asBytes(&siginfo)) catch return true;
        break :blk siginfo.signo;
    };

    return switch (signo) {
        SIG_CHLD => blk: {
            // Reap zombie children (clipboard helpers, etc.) without exiting.
            // PTY child death is detected by read() returning 0 in the event loop.
            // Use raw syscall to handle ECHILD gracefully (std.posix.waitpid panics on it).
            if (is_linux) {
                while (true) {
                    // Use raw syscall: wait4(-1, NULL, WNOHANG, NULL)
                    const rc = linux.syscall4(
                        .wait4,
                        @as(usize, @bitCast(@as(isize, -1))),
                        0,
                        linux.W.NOHANG,
                        0,
                    );
                    const rc_isize: isize = @bitCast(rc);
                    if (rc_isize <= 0) break; // ECHILD or no more children
                }
            } else {
                // macOS: use std.c.waitpid which returns -1/ECHILD safely
                while (true) {
                    const rc = std.c.waitpid(-1, null, 1); // WNOHANG=1
                    if (rc <= 0) break;
                }
            }
            break :blk true;
        },
        SIG_TERM, SIG_INT, SIG_HUP => false,
        SIG_USR1 => blk: {
            backend.releaseVt();
            break :blk true;
        },
        SIG_USR2 => blk: {
            backend.acquireVt();
            break :blk true;
        },
        else => true,
    };
}

/// Handle a single backend event (key, text, paste, resize, etc.).
/// Returns false if the event loop should stop (close event or write failure).
/// Dispatch clipboard copy via external tool (xclip for X11, wl-copy for Wayland).
/// Non-blocking: forks a child process and writes data to its stdin.
fn dispatchClipboardCopy(data: []const u8) void {
    const argv: [*:null]const ?[*:0]const u8 = switch (config.backend) {
        .x11 => &[_:null]?[*:0]const u8{ "xclip", "-selection", "clipboard" },
        .wayland => &[_:null]?[*:0]const u8{"wl-copy"},
        else => return,
    };

    // Block SIGPIPE to prevent write() from killing us if child dies early
    const SIG_PIPE = if (is_linux) linux.SIG.PIPE else std.c.SIG.PIPE;
    const SIG_BLOCK: u32 = if (is_linux) linux.SIG.BLOCK else 1; // SIG_BLOCK=1 on macOS/BSD
    const SIG_UNBLOCK: u32 = if (is_linux) linux.SIG.UNBLOCK else 2;
    if (is_linux) {
        var mask = linux.sigemptyset();
        linux.sigaddset(&mask, SIG_PIPE);
        _ = linux.sigprocmask(SIG_BLOCK, &mask, null);
    } else if (is_macos) {
        // macOS: use signal(SIGPIPE, SIG_IGN) around the write
        _ = std.c.signal(SIG_PIPE, std.c.SIG.IGN);
    }

    const pipe_fds = std.posix.pipe() catch return;
    const pid = std.posix.fork() catch {
        std.posix.close(pipe_fds[0]);
        std.posix.close(pipe_fds[1]);
        return;
    };

    if (pid == 0) {
        // Child: redirect stdin from pipe read end
        std.posix.dup2(pipe_fds[0], 0) catch std.posix.exit(1);
        std.posix.close(pipe_fds[0]);
        std.posix.close(pipe_fds[1]);

        // Use minimal environment to avoid LD_PRELOAD/PATH hijacking
        var display_env_buf: [128]u8 = undefined;
        var wayland_env_buf: [128]u8 = undefined;
        var xdg_env_buf: [256]u8 = undefined;
        var xauth_env_buf: [256]u8 = undefined;
        var clip_env: [8:null]?[*:0]const u8 = .{null} ** 8;
        var ci: usize = 0;
        clip_env[ci] = "PATH=/usr/local/bin:/usr/bin:/bin";
        ci += 1;
        if (std.posix.getenv("DISPLAY")) |v| {
            clip_env[ci] = (std.fmt.bufPrintZ(&display_env_buf, "DISPLAY={s}", .{v}) catch null);
            if (clip_env[ci] != null) ci += 1;
        }
        if (std.posix.getenv("XAUTHORITY")) |v| {
            clip_env[ci] = (std.fmt.bufPrintZ(&xauth_env_buf, "XAUTHORITY={s}", .{v}) catch null);
            if (clip_env[ci] != null) ci += 1;
        }
        if (std.posix.getenv("WAYLAND_DISPLAY")) |v| {
            clip_env[ci] = (std.fmt.bufPrintZ(&wayland_env_buf, "WAYLAND_DISPLAY={s}", .{v}) catch null);
            if (clip_env[ci] != null) ci += 1;
        }
        if (std.posix.getenv("XDG_RUNTIME_DIR")) |v| {
            clip_env[ci] = (std.fmt.bufPrintZ(&xdg_env_buf, "XDG_RUNTIME_DIR={s}", .{v}) catch null);
            if (clip_env[ci] != null) ci += 1;
        }
        const clip_envp: [*:null]const ?[*:0]const u8 = &clip_env;
        _ = std.posix.execvpeZ(
            argv[0].?,
            argv,
            clip_envp,
        ) catch {};
        std.posix.exit(1);
    }

    // Parent: write data to pipe write end, close read end immediately
    std.posix.close(pipe_fds[0]);
    if (data.len > 0) {
        _ = std.posix.write(pipe_fds[1], data) catch {};
    }
    std.posix.close(pipe_fds[1]); // EOF signals end of data to child

    // Restore SIGPIPE handling
    if (is_linux) {
        var mask = linux.sigemptyset();
        linux.sigaddset(&mask, SIG_PIPE);
        _ = linux.sigprocmask(SIG_UNBLOCK, &mask, null);
    } else if (is_macos) {
        _ = std.c.signal(SIG_PIPE, std.c.SIG.DFL);
    }
}

fn handleBackendEvent(
    event: *const BackendEvent,
    term: *Term,
    pty_ptr: *Pty,
    backend: *Backend,
    write_buf: *[65536]u8,
    write_pending: *usize,
    evloop_fd: i32,
    cursor_visible_blink: *bool,
    cursor_blink_active: *bool,
    last_input_ns: *i128,
    last_render_ns: *i128,
    backend_focused: *bool,
    last_pressed_button: *MouseButton,
) bool {
    switch (event.*) {
        .key => |key_ev| {
            refreshCursorBlinkOnUserInput(cursor_visible_blink, cursor_blink_active, last_input_ns);
            if (key_ev.pressed) {
                const bytes = input.translateKey(key_ev.keycode, key_ev.modifiers, term.decckm, term.decbkm);
                if (bytes.len > 0) {
                    if (!ptyBufferedWrite(pty_ptr, bytes, write_buf, write_pending, evloop_fd)) {
                        return false;
                    }
                }
            }
        },
        .text => |text_ev| {
            refreshCursorBlinkOnUserInput(cursor_visible_blink, cursor_blink_active, last_input_ns);
            const text = text_ev.slice();
            if (text.len > 0) {
                if (!ptyBufferedWrite(pty_ptr, text, write_buf, write_pending, evloop_fd)) {
                    return false;
                }
            }
        },
        .paste => |paste_ev| {
            refreshCursorBlinkOnUserInput(cursor_visible_blink, cursor_blink_active, last_input_ns);
            const text = paste_ev.slice();
            if (text.len > 0) {
                // Wrap paste in bracketed paste sequences if application enabled DECSET 2004
                if (term.bracketed_paste) {
                    if (!ptyBufferedWrite(pty_ptr, "\x1b[200~", write_buf, write_pending, evloop_fd)) return false;
                }
                if (!ptyBufferedWrite(pty_ptr, text, write_buf, write_pending, evloop_fd)) {
                    return false;
                }
                if (term.bracketed_paste) {
                    if (!ptyBufferedWrite(pty_ptr, "\x1b[201~", write_buf, write_pending, evloop_fd)) return false;
                }
            }
        },
        .resize => |rsz| {
            const new_cols = rsz.width / config.cell_width;
            const new_rows = rsz.height / config.cell_height;
            if (new_cols > 0 and new_rows > 0) {
                term.resize(new_cols, new_rows) catch |err| {
                    std.log.err("term resize: {}", .{err});
                };
                pty_ptr.resize(@intCast(@min(new_cols, 65535)), @intCast(@min(new_rows, 65535))) catch |err| {
                    std.log.err("pty resize: {}", .{err});
                };
                backend.resize(rsz.width, rsz.height) catch |err| {
                    std.log.err("backend resize: {}", .{err});
                };
            }
        },
        .expose => {
            const total = @as(usize, term.cols) * @as(usize, term.rows);
            term.markDirtyRange(.{ .start = 0, .end = total });
            term.all_dirty = true;
        },
        .focus_in => {
            // Restore blink + input clock so idle-timeout does not stay "stuck" across focus changes.
            // Mark cursor dirty and drop frame throttle so the first paint after refocus is immediate.
            backend_focused.* = true;
            cursor_visible_blink.* = true;
            cursor_blink_active.* = true;
            last_input_ns.* = std.time.nanoTimestamp();
            last_render_ns.* = 0;
            term.markDirty(term.cursor_x, term.cursor_y);
            if (term.focus_events) {
                if (!ptyBufferedWrite(pty_ptr, "\x1b[I", write_buf, write_pending, evloop_fd)) {
                    return false;
                }
            }
        },
        .focus_out => {
            backend_focused.* = false;
            cursor_blink_active.* = false;
            cursor_visible_blink.* = true;
            term.markDirty(term.cursor_x, term.cursor_y);
            if (term.focus_events) {
                if (!ptyBufferedWrite(pty_ptr, "\x1b[O", write_buf, write_pending, evloop_fd)) {
                    return false;
                }
            }
        },
        .mouse => |mouse_ev| {
            refreshCursorBlinkOnUserInput(cursor_visible_blink, cursor_blink_active, last_input_ns);

            // Pixel → cell coordinate conversion
            const col: u32 = mouse_ev.x / config.cell_width;
            const row: u32 = mouse_ev.y / config.cell_height;
            const cx = @min(col, term.cols -| 1);
            const cy = @min(row, term.rows -| 1);

            // Shift held → terminal selection (bypass app mouse capture)
            if (mouse_ev.modifiers.shift) {
                handleTerminalSelection(term, mouse_ev, cx, cy);
                return true;
            }

            // App captures mouse → encode VT sequence
            if (term.mouse_mode != .none) {
                const seq = encodeMouseEvent(term, mouse_ev, cx, cy, last_pressed_button);
                if (seq.len > 0) {
                    if (!ptyBufferedWrite(pty_ptr, seq.slice(), write_buf, write_pending, evloop_fd)) {
                        return false;
                    }
                }
            } else {
                // No app mouse mode → terminal selection
                handleTerminalSelection(term, mouse_ev, cx, cy);
            }
        },
        .copy_selection => {
            if (term.selection != null) {
                var clipboard_buf: [16384]u8 = undefined;
                const text = extractSelectionText(term, &clipboard_buf);
                if (text.len > 0) {
                    dispatchClipboardCopy(text);
                }
            }
        },
        .close => {
            return false;
        },
    }
    return true;
}

fn encodeMouseEvent(term: *const Term, ev: BackendMouseEvent, cx: u32, cy: u32, last_btn: *MouseButton) EncodedMouse {
    // Filter events based on mouse mode
    switch (term.mouse_mode) {
        .none => return .{},
        .x10 => {
            if (ev.action != .press) return .{};
        },
        .normal => {
            if (ev.action == .motion) return .{};
        },
        .button => {
            // ?1002: motion only while button held (drag)
            if (ev.action == .motion and ev.button == .none) return .{};
        },
        .any => {}, // report everything
    }

    // Track pressed button for SGR release
    if (ev.action == .press and ev.button != .none) {
        last_btn.* = ev.button;
    }

    // Build button byte
    var btn: u8 = switch (ev.action) {
        .release => switch (term.mouse_encoding) {
            .sgr => switch (last_btn.*) {
                .left => 0,
                .middle => 1,
                .right => 2,
                else => 3,
            },
            else => 3, // X10/UTF-8/URXVT: generic release
        },
        else => switch (ev.button) {
            .left => 0,
            .middle => 1,
            .right => 2,
            .none => 3,
            .wheel_up => 64,
            .wheel_down => 65,
            .wheel_left => 66,
            .wheel_right => 67,
        },
    };

    if (ev.action == .release) {
        last_btn.* = .none;
    }

    // Modifier bits (not for X10 mode)
    if (term.mouse_mode != .x10) {
        if (ev.modifiers.shift) btn |= 4;
        if (ev.modifiers.alt) btn |= 8;
        if (ev.modifiers.ctrl) btn |= 16;
    }

    // Motion flag
    if (ev.action == .motion) btn |= 32;

    var result: EncodedMouse = .{};

    switch (term.mouse_encoding) {
        .sgr => {
            // CSI < Pb ; Px ; Py M/m
            const suffix: u8 = if (ev.action == .release) 'm' else 'M';
            result.len = @intCast((std.fmt.bufPrint(&result.data, "\x1b[<{d};{d};{d}{c}", .{
                btn, cx + 1, cy + 1, suffix,
            }) catch return .{}).len);
        },
        .x10 => {
            // CSI M Cb Cx Cy (max 223)
            if (cx + 1 > 223 or cy + 1 > 223) return .{};
            result.data[0] = 0x1b;
            result.data[1] = '[';
            result.data[2] = 'M';
            result.data[3] = btn + 32;
            result.data[4] = @intCast(cx + 1 + 32);
            result.data[5] = @intCast(cy + 1 + 32);
            result.len = 6;
        },
        .utf8 => {
            // Like X10 but coords encoded as UTF-8
            result.data[0] = 0x1b;
            result.data[1] = '[';
            result.data[2] = 'M';
            result.data[3] = btn + 32;
            var pos: u8 = 4;
            pos += encodeUtf8Coord(cx + 1 + 32, result.data[pos..]);
            pos += encodeUtf8Coord(cy + 1 + 32, result.data[pos..]);
            result.len = pos;
        },
        .urxvt => {
            // CSI Pb ; Px ; Py M
            result.len = @intCast((std.fmt.bufPrint(&result.data, "\x1b[{d};{d};{d}M", .{
                btn + 32, cx + 1, cy + 1,
            }) catch return .{}).len);
        },
    }
    return result;
}

fn extractSelectionText(term: *const Term, buf: []u8) []const u8 {
    const sel = term.selection orelse return &.{};
    const o = sel.ordered();
    var pos: usize = 0;

    var y = o.sy;
    while (y <= o.ey) : (y += 1) {
        const start_x = if (y == o.sy) o.sx else 0;
        const end_x = if (y == o.ey) o.ex else term.cols - 1;

        const phys_row = term.row_map[y];
        const row_base = @as(usize, phys_row) * @as(usize, term.cols);
        const row_cells = term.cells[row_base..][0..term.cols];

        const row_start_pos = pos;
        var x = start_x;
        while (x <= end_x) : (x += 1) {
            const ch = row_cells[x].char;
            if (ch == 0 or row_cells[x].attrs.wide_dummy) continue;
            var encode_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(ch, &encode_buf) catch continue;
            if (pos + len > buf.len) break;
            @memcpy(buf[pos..][0..len], encode_buf[0..len]);
            pos += len;
        }
        // Trim trailing spaces from each line
        while (pos > row_start_pos and buf[pos - 1] == ' ') {
            pos -= 1;
        }
        // Add newline between rows (not after last)
        if (y < o.ey and pos < buf.len) {
            buf[pos] = '\n';
            pos += 1;
        }
    }
    return buf[0..pos];
}

fn handleTerminalSelection(term: *Term, ev: BackendMouseEvent, cx: u32, cy: u32) void {
    switch (ev.action) {
        .press => switch (ev.button) {
            .left => {
                // Start new selection
                term.selection = .{
                    .start_x = cx,
                    .start_y = cy,
                    .end_x = cx,
                    .end_y = cy,
                    .active = true,
                };
                // Mark screen dirty for selection highlight
                const total = @as(usize, term.cols) * @as(usize, term.rows);
                term.markDirtyRange(.{ .start = 0, .end = total });
            },
            .wheel_up, .wheel_down => {
                // When no app captures mouse and in alt screen,
                // translate wheel to arrow keys for less/man etc.
                // TODO: scrollback when implemented
            },
            else => {},
        },
        .motion => {
            if (term.selection) |*sel| {
                if (sel.active) {
                    sel.end_x = cx;
                    sel.end_y = cy;
                    // Mark dirty for selection update
                    const total = @as(usize, term.cols) * @as(usize, term.rows);
                    term.markDirtyRange(.{ .start = 0, .end = total });
                }
            }
        },
        .release => {
            if (ev.button == .left) {
                if (term.selection) |*sel| {
                    sel.active = false;
                    // If start == end, clear selection (was just a click)
                    if (sel.start_x == sel.end_x and sel.start_y == sel.end_y) {
                        term.selection = null;
                    } else {
                        // Copy selection text to clipboard
                        var clipboard_buf: [16384]u8 = undefined;
                        const text = extractSelectionText(term, &clipboard_buf);
                        if (text.len > 0) {
                            dispatchClipboardCopy(text);
                        }
                    }
                }
                const total = @as(usize, term.cols) * @as(usize, term.rows);
                term.markDirtyRange(.{ .start = 0, .end = total });
            }
        },
    }
}

fn encodeUtf8Coord(val: u32, buf: []u8) u8 {
    if (val < 0x80) {
        buf[0] = @intCast(val);
        return 1;
    } else if (val < 0x800) {
        buf[0] = @intCast(0xC0 | (val >> 6));
        buf[1] = @intCast(0x80 | (val & 0x3F));
        return 2;
    } else {
        buf[0] = @intCast(0xE0 | (val >> 12));
        buf[1] = @intCast(0x80 | ((val >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (val & 0x3F));
        return 3;
    }
}

fn drainBackendEvents(
    term: *Term,
    pty_ptr: *Pty,
    backend: *Backend,
    write_buf: *[65536]u8,
    write_pending: *usize,
    evloop_fd: i32,
    cursor_visible_blink: *bool,
    cursor_blink_active: *bool,
    last_input_ns: *i128,
    last_render_ns: *i128,
    backend_focused: *bool,
    last_pressed_button: *MouseButton,
    max_events: u32,
) bool {
    var drain: u32 = 0;
    while (drain < max_events) : (drain += 1) {
        const event = backend.pollEvents() orelse break;
        if (!handleBackendEvent(&event, term, pty_ptr, backend, write_buf, write_pending, evloop_fd, cursor_visible_blink, cursor_blink_active, last_input_ns, last_render_ns, backend_focused, last_pressed_button)) {
            return false;
        }
    }
    return true;
}

// =============================================================================
// Main
// =============================================================================

pub fn main() !void {
    // Debug: GPA for leak detection; Release: lightweight allocator
    var gpa = if (builtin.mode == .Debug)
        std.heap.GeneralPurposeAllocator(.{}){}
    else {};
    defer if (builtin.mode == .Debug) {
        _ = gpa.deinit();
    };
    const allocator = if (builtin.mode == .Debug)
        gpa.allocator()
    else if (config.backend == .x11 or config.backend == .wayland or config.backend == .macos)
        std.heap.c_allocator
    else
        std.heap.page_allocator;

    // 0. Parse command-line arguments
    var exec_argv: ?[]const [:0]const u8 = null;
    var embed_window: u32 = 0;
    const args = std.process.argsAlloc(allocator) catch null;
    defer if (args) |a| std.process.argsFree(allocator, a);
    if (args) |argv| {
        var i: usize = 1; // skip argv[0]
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "-w")) {
                if (i + 1 >= argv.len) {
                    const stderr_msg = "zt: -w requires a window id\n";
                    _ = std.posix.write(2, stderr_msg) catch {};
                    std.process.exit(1);
                }
                i += 1;
                embed_window = std.fmt.parseInt(u32, argv[i], 10) catch {
                    const stderr_msg = "zt: -w requires a numeric window id\n";
                    _ = std.posix.write(2, stderr_msg) catch {};
                    std.process.exit(1);
                };
            } else if (std.mem.eql(u8, argv[i], "-e")) {
                if (i + 1 >= argv.len) {
                    const stderr_msg = "zt: -e requires a command\n";
                    _ = std.posix.write(2, stderr_msg) catch {};
                    std.process.exit(1);
                }
                // Everything after -e is the command + args
                exec_argv = argv[i + 1 ..];
                break;
            }
        }
    }

    // 1. Init backend
    var backend = switch (config.backend) {
        .fbdev => try Backend.init(allocator),
        .x11 => try Backend.init(embed_window),
        .wayland, .macos => try Backend.init(),
    };
    defer backend.deinit();

    // 1b. Post-init for X11/Wayland/macOS (XKB + XIM, needs stable self pointer)
    if (config.backend == .x11 or config.backend == .wayland or config.backend == .macos) {
        backend.postInit();
    }

    // 2. Save console state (fbdev only, noop for X11)
    try backend.saveConsoleState();
    defer backend.restoreConsoleState();

    // 3. Setup VT switching (fbdev only, noop for X11)
    backend.setupVtSwitching() catch {};

    // 4. Calculate grid dimensions
    const cols: u32 = backend.getWidth() / config.cell_width;
    const rows: u32 = backend.getHeight() / config.cell_height;

    // 5. Init term
    var term = try Term.init(allocator, cols, rows);
    defer term.deinit();

    // 6. Spawn PTY
    var pty = try Pty.spawn(@intCast(cols), @intCast(rows), config.shell, exec_argv);
    defer pty.deinit();

    // 7. Setup signals
    const sig_fd = try setupSignals();
    defer if (sig_fd >= 0) std.posix.close(sig_fd);

    // 8. Setup cursor blink timer (500ms)
    const timer_fd = try createTimerFd(500_000_000);
    defer if (timer_fd >= 0) std.posix.close(timer_fd);

    // 9. Setup event loop (epoll on Linux, kqueue on macOS)
    const evloop_fd: i32 = if (is_linux) blk: {
        const raw = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        const isize_val: isize = @bitCast(raw);
        if (isize_val < 0) return error.EpollCreateFailed;
        break :blk @intCast(isize_val);
    } else blk: {
        break :blk try std.posix.kqueue();
    };
    defer std.posix.close(evloop_fd);

    if (is_linux) {
        try epollAdd(evloop_fd, pty.master_fd, @intFromEnum(EpollTag.pty));
        try epollAdd(evloop_fd, sig_fd, @intFromEnum(EpollTag.signal));
        try epollAdd(evloop_fd, timer_fd, @intFromEnum(EpollTag.timer));
        if (backend.getFd()) |fd| {
            try epollAdd(evloop_fd, fd, @intFromEnum(EpollTag.backend));
        }
        if (config.backend == .fbdev) {
            for (0..backend.evdev_count) |i| {
                try epollAdd(evloop_fd, backend.evdev_fds[i], EVDEV_BASE + @as(u32, @intCast(i)));
            }
        }
    } else {
        try kqueueAddFd(evloop_fd, pty.master_fd, @intFromEnum(KqueueTag.pty));
        try kqueueAddSignal(evloop_fd, std.c.SIG.CHLD);
        try kqueueAddSignal(evloop_fd, std.c.SIG.TERM);
        try kqueueAddSignal(evloop_fd, std.c.SIG.INT);
        try kqueueAddSignal(evloop_fd, std.c.SIG.HUP);
        try kqueueAddTimer(evloop_fd, KQUEUE_TIMER_IDENT, 500);
        if (backend.getFd()) |fd| {
            try kqueueAddFd(evloop_fd, fd, @intFromEnum(KqueueTag.backend));
        }
    }

    // 10. Sync with actual window geometry.
    //     A tiling WM may have resized our window between creation and now
    //     (e.g., during MapRequest handling). Query the real geometry and
    //     update PTY/term/backend to match. This handles the initial resize
    //     that event-based detection might miss due to buffering.
    if (config.backend == .x11 or config.backend == .wayland or config.backend == .macos) {
        const actual = backend.queryGeometry();
        if (actual.w > 0 and actual.h > 0 and (actual.w != backend.getWidth() or actual.h != backend.getHeight())) {
            const new_cols = actual.w / config.cell_width;
            const new_rows = actual.h / config.cell_height;
            if (new_cols > 0 and new_rows > 0) {
                term.resize(new_cols, new_rows) catch {};
                pty.resize(@intCast(@min(new_cols, 65535)), @intCast(@min(new_rows, 65535))) catch {};
                backend.resize(actual.w, actual.h) catch {};
            }
        }
    }

    // 11. Event loop
    var parser = vt.Parser{};
    var running = true;
    var mod_state: input.Modifiers = .{};
    var pty_buf: [config.pty_buf_size]u8 = undefined;
    var cursor_visible_blink = true;
    var cursor_blink_active = true; // false after idle timeout — stops blink rendering
    // false while unfocused: skip cursor timer toggles (avoids stale idle blink + extra wakeups)
    var backend_focused = true;
    var last_pressed_button: MouseButton = .none;
    var last_input_ns: i128 = std.time.nanoTimestamp();
    const cursor_idle_timeout_ns: i128 = 5 * std.time.ns_per_s;
    var prev_cursor_x: u32 = 0;
    var prev_cursor_y: u32 = 0;
    var write_buf: [65536]u8 = undefined;
    var write_pending: usize = 0;
    var last_render_ns: i128 = 0;
    var bytes_since_render: usize = 0;
    var sync_update_start_ns: i128 = 0; // timestamp when sync_update was first seen

    while (running) {
        const loop_now = std.time.nanoTimestamp();
        // Adaptive frame rate: smoothly reduce render frequency during heavy output
        // Tier 0: <64KB  → frame_min_ns (default 8ms = 120fps)
        // Tier 1: 64KB+  → frame_min_ns * 2 (default 16ms = 60fps)
        // Tier 2: 256KB+ → frame_min_ns * 8 (default 64ms = ~15fps)
        // Tier 3: 1MB+   → capped at 64ms to keep input responsive
        const effective_frame_ns: i128 = if (config.frame_min_ns == 0)
            0
        else if (bytes_since_render > 1_048_576)
            @min(@as(i128, config.frame_min_ns) * 24, 64_000_000)
        else if (bytes_since_render > 262_144)
            @as(i128, config.frame_min_ns) * 8
        else if (bytes_since_render > 65_536)
            @as(i128, config.frame_min_ns) * 2
        else
            @as(i128, config.frame_min_ns);

        // Dynamic event loop timeout: short wait when render pending, block otherwise
        const event_timeout: i32 = if (effective_frame_ns > 0 and term.hasDirty()) blk: {
            const elapsed = loop_now - last_render_ns;
            if (elapsed >= effective_frame_ns) break :blk 0;
            const remaining_ms = @divFloor(effective_frame_ns - elapsed, 1_000_000);
            break :blk @intCast(@max(remaining_ms, 1));
        } else -1;

        // Proactively flush pending writes before blocking on events.
        // This ensures buffered keystrokes reach the child ASAP, preventing
        // input starvation when heavy output keeps the write buffer occupied.
        if (write_pending > 0) {
            if (!ptyFlushPending(&pty, &write_buf, &write_pending, evloop_fd)) {
                running = false;
                continue;
            }
        }

        if (is_linux) {
            // X11/Wayland/macos backends can buffer events internally even when their
            // fd is no longer readable. Drain a bounded amount every loop so input
            // never appears "stuck" waiting for unrelated socket traffic.
            if (config.backend == .x11 or config.backend == .wayland or config.backend == .macos) {
                if (!drainBackendEvents(&term, &pty, &backend, &write_buf, &write_pending, evloop_fd, &cursor_visible_blink, &cursor_blink_active, &last_input_ns, &last_render_ns, &backend_focused, &last_pressed_button, 8192)) {
                    running = false;
                    continue;
                }
            }

            // ---- Linux epoll dispatch ----
            var events: [16]linux.epoll_event = undefined;
            const n_raw = linux.epoll_wait(evloop_fd, &events, events.len, event_timeout);
            const n_isize: isize = @bitCast(n_raw);
            if (n_isize < 0) continue; // EINTR
            const n: usize = @intCast(n_raw);

            for (events[0..n]) |ev| {
                switch (ev.data.u32) {
                    @intFromEnum(EpollTag.pty) => {
                        // Handle hangup/error when no EPOLLIN (child died)
                        if (ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR) != 0 and ev.events & linux.EPOLL.IN == 0) {
                            running = false;
                            break;
                        }
                        // Flush pending writes if EPOLLOUT
                        if (ev.events & linux.EPOLL.OUT != 0) {
                            if (!ptyFlushPending(&pty, &write_buf, &write_pending, evloop_fd)) {
                                running = false;
                                break;
                            }
                        }
                        // PTY readable — drain all available data before rendering
                        if (ev.events & linux.EPOLL.IN != 0) {
                            while (true) {
                                const bytes_read = pty.read(&pty_buf) catch |err| switch (err) {
                                    error.WouldBlock => break,
                                    else => {
                                        running = false;
                                        break;
                                    },
                                };
                                if (bytes_read == 0) {
                                    running = false;
                                    break;
                                }
                                bytes_since_render += bytes_read;
                                // Clear selection when terminal content changes
                                if (term.selection != null) {
                                    term.selection = null;
                                    term.all_dirty = true;
                                }
                                vt.feedBulk(&parser, pty_buf[0..bytes_read], &term, pty.master_fd);
                                // Flush VT responses after each chunk to prevent overflow
                                if (term.vt_response_len > 0) {
                                    if (!ptyBufferedWrite(&pty, term.vt_response_buf[0..term.vt_response_len], &write_buf, &write_pending, evloop_fd)) {
                                        running = false;
                                        break;
                                    }
                                    term.vt_response_len = 0;
                                }
                            }
                        }
                    },
                    @intFromEnum(EpollTag.signal) => {
                        running = handleSignal(sig_fd, null, &backend);
                    },
                    @intFromEnum(EpollTag.timer) => {
                        // Read timer to acknowledge
                        var exp: u64 = 0;
                        _ = std.posix.read(timer_fd, std.mem.asBytes(&exp)) catch {};
                        applyCursorBlinkTimerTick(
                            &term,
                            backend_focused,
                            last_input_ns,
                            &cursor_blink_active,
                            &cursor_visible_blink,
                            cursor_idle_timeout_ns,
                        );
                    },
                    @intFromEnum(EpollTag.backend) => {
                        // Backend events (X11, Wayland or macOS)
                        if (config.backend == .x11 or config.backend == .wayland or config.backend == .macos) {
                            if (!drainBackendEvents(&term, &pty, &backend, &write_buf, &write_pending, evloop_fd, &cursor_visible_blink, &cursor_blink_active, &last_input_ns, &last_render_ns, &backend_focused, &last_pressed_button, 8192)) {
                                running = false;
                                break;
                            }
                        }
                    },
                    else => {
                        // evdev fds (fbdev backend)
                        if (config.backend == .fbdev) {
                            const evdev_idx = ev.data.u32 - EVDEV_BASE;
                            var had_input = false;
                            while (backend.readEvdev(evdev_idx)) |input_event| {
                                const K = input.KEY;
                                switch (input_event.keycode) {
                                    K.LEFTSHIFT, K.RIGHTSHIFT => {
                                        mod_state.shift = input_event.pressed;
                                    },
                                    K.LEFTCTRL, K.RIGHTCTRL => {
                                        mod_state.ctrl = input_event.pressed;
                                    },
                                    K.LEFTALT, K.RIGHTALT => {
                                        mod_state.alt = input_event.pressed;
                                    },
                                    K.LEFTMETA, K.RIGHTMETA => {
                                        mod_state.meta = input_event.pressed;
                                    },
                                    else => {
                                        if (input_event.pressed or input_event.repeat) {
                                            const bytes = input.translateKey(input_event.keycode, mod_state, term.decckm, term.decbkm);
                                            if (bytes.len > 0) {
                                                had_input = true;
                                                if (!ptyBufferedWrite(&pty, bytes, &write_buf, &write_pending, evloop_fd)) {
                                                    running = false;
                                                    break;
                                                }
                                            }
                                        }
                                    },
                                }
                            }
                            if (had_input) {
                                refreshCursorBlinkOnUserInput(&cursor_visible_blink, &cursor_blink_active, &last_input_ns);
                            }
                        }
                    },
                }
            }
        } else {
            // ---- macOS kqueue dispatch ----
            // On macOS, we must pump the Cocoa run loop regularly for window
            // display and event delivery. Never block indefinitely — cap at
            // 16ms (~60hz) so the UI stays responsive even when idle.
            const macos_timeout: i32 = if (event_timeout < 0) 16 else @min(event_timeout, 16);
            var timeout_buf: std.posix.timespec = .{
                .sec = @divFloor(@as(isize, macos_timeout), 1000),
                .nsec = @rem(@as(isize, macos_timeout), 1000) * 1_000_000,
            };
            const timeout_spec: ?*const std.posix.timespec = &timeout_buf;
            var kevents: [16]std.posix.Kevent = undefined;
            const n = std.posix.kevent(evloop_fd, &.{}, &kevents, timeout_spec) catch 0;

            for (kevents[0..n]) |kev| {
                if (kev.filter == std.c.EVFILT.READ) {
                    if (kev.udata == @intFromEnum(KqueueTag.pty)) {
                        // PTY readable — drain all available data
                        while (true) {
                            const bytes_read = pty.read(&pty_buf) catch |err| switch (err) {
                                error.WouldBlock => break,
                                else => {
                                    running = false;
                                    break;
                                },
                            };
                            if (bytes_read == 0) {
                                running = false;
                                break;
                            }
                            bytes_since_render += bytes_read;
                            // Clear selection when terminal content changes
                            if (term.selection != null) {
                                term.selection = null;
                                term.all_dirty = true;
                            }
                            vt.feedBulk(&parser, pty_buf[0..bytes_read], &term, pty.master_fd);
                            // Flush VT responses after each chunk to prevent overflow
                            if (term.vt_response_len > 0) {
                                if (!ptyBufferedWrite(&pty, term.vt_response_buf[0..term.vt_response_len], &write_buf, &write_pending, evloop_fd)) {
                                    running = false;
                                    break;
                                }
                                term.vt_response_len = 0;
                            }
                        }
                    } else if (kev.udata == @intFromEnum(KqueueTag.backend)) {
                        // Backend events (X11, Wayland or macOS)
                        if (config.backend == .x11 or config.backend == .wayland or config.backend == .macos) {
                            while (backend.pollEvents()) |event| {
                                if (!handleBackendEvent(&event, &term, &pty, &backend, &write_buf, &write_pending, evloop_fd, &cursor_visible_blink, &cursor_blink_active, &last_input_ns, &last_render_ns, &backend_focused, &last_pressed_button)) {
                                    running = false;
                                    break;
                                }
                            }
                        }
                    }
                } else if (kev.filter == std.c.EVFILT.WRITE) {
                    // PTY writable
                    if (!ptyFlushPending(&pty, &write_buf, &write_pending, evloop_fd)) {
                        running = false;
                        break;
                    }
                } else if (kev.filter == std.c.EVFILT.SIGNAL) {
                    running = handleSignal(-1, @intCast(kev.ident), &backend);
                } else if (kev.filter == std.c.EVFILT.TIMER) {
                    applyCursorBlinkTimerTick(
                        &term,
                        backend_focused,
                        last_input_ns,
                        &cursor_blink_active,
                        &cursor_visible_blink,
                        cursor_idle_timeout_ns,
                    );
                }
            }

            // Always pump Cocoa events, even if kqueue returned nothing.
            // The Cocoa run loop must be serviced for window display, input
            // delivery, and system event handling. Without this, the window
            // never appears because Cocoa callbacks never fire.
            if (config.backend == .macos) {
                while (backend.pollEvents()) |event| {
                    if (!handleBackendEvent(&event, &term, &pty, &backend, &write_buf, &write_pending, evloop_fd, &cursor_visible_blink, &cursor_blink_active, &last_input_ns, &last_render_ns, &backend_focused, &last_pressed_button)) {
                        running = false;
                        break;
                    }
                }
            }
        }

        // Extra PTY drain: data may have arrived during event processing.
        // Capped at pty_buf_size to keep event loop responsive for input.
        if (running) {
            var extra_total: usize = 0;
            while (extra_total < config.pty_buf_size) {
                const extra = pty.read(&pty_buf) catch break;
                if (extra == 0) {
                    running = false;
                    break;
                }
                bytes_since_render += extra;
                extra_total += extra;
                // Clear selection when terminal content changes
                if (term.selection != null) {
                    term.selection = null;
                    term.all_dirty = true;
                }
                vt.feedBulk(&parser, pty_buf[0..extra], &term, pty.master_fd);
                // Flush VT responses after each chunk to prevent overflow
                if (term.vt_response_len > 0) {
                    if (!ptyBufferedWrite(&pty, term.vt_response_buf[0..term.vt_response_len], &write_buf, &write_pending, evloop_fd)) {
                        running = false;
                        break;
                    }
                    term.vt_response_len = 0;
                }
            }
        }

        // Flush VT response buffer (DA1, DSR, DECRQSS, etc.) via buffered PTY write
        if (term.vt_response_len > 0) {
            if (!ptyBufferedWrite(&pty, term.vt_response_buf[0..term.vt_response_len], &write_buf, &write_pending, evloop_fd)) {
                running = false;
            }
            term.vt_response_len = 0;
        }

        // OSC 52: copy to system clipboard via external tool
        if (term.osc52_pending) {
            term.osc52_pending = false;
            dispatchClipboardCopy(term.osc52_buf[0..term.osc52_len]);
        }

        // Mark old cursor position dirty if cursor moved
        if (prev_cursor_x != term.cursor_x or prev_cursor_y != term.cursor_y) {
            term.markDirty(prev_cursor_x, prev_cursor_y);
            term.markDirty(term.cursor_x, term.cursor_y);
        }
        prev_cursor_x = term.cursor_x;
        prev_cursor_y = term.cursor_y;

        // Flush protocol responses every iteration, even when we skip rendering.
        // Wayland: without this, the compositor marks us "not responding"
        //          because pong sits in the send buffer.
        // X11:     without this, XIM forward_event messages sit in the XCB
        //          output buffer until the next render, causing 0-500ms input
        //          latency and XIM timeout fallback that leaks raw ASCII
        //          alongside committed IME text.
        if (config.backend == .wayland or config.backend == .x11) backend.flush();

        // Handle BEL, title, and IME updates regardless of dirty state
        if (term.bell_pending) {
            term.bell_pending = false;
            if (@hasDecl(Backend, "bell")) {
                backend.bell();
            }
        }

        // Update window title if changed by OSC 0/2
        if (term.title_changed) {
            term.title_changed = false;
            if (@hasDecl(Backend, "updateTitle")) {
                if (term.title_len > 0) {
                    // Prefix with "zt — " so the version/app name stays visible
                    var title_buf: [280]u8 = undefined;
                    const prefix = "zt " ++ config.version ++ " — ";
                    @memcpy(title_buf[0..prefix.len], prefix);
                    const tlen: usize = term.title_len;
                    @memcpy(title_buf[prefix.len..][0..tlen], term.title[0..tlen]);
                    backend.updateTitle(title_buf[0 .. prefix.len + tlen]);
                } else {
                    backend.updateTitle("zt " ++ config.version);
                }
            }
        }

        // Render dirty cells — skip entirely if nothing changed
        if (!term.hasDirty()) continue;

        // Synchronized output (DEC 2026): defer render until ESU
        // Timeout after 3 seconds to prevent permanent freeze if app crashes
        if (term.sync_update) {
            if (sync_update_start_ns == 0) {
                sync_update_start_ns = loop_now;
            } else if (loop_now - sync_update_start_ns > 3_000_000_000) {
                term.sync_update = false;
                sync_update_start_ns = 0;
                last_render_ns = 0; // force immediate render after timeout
            } else {
                continue;
            }
        } else {
            sync_update_start_ns = 0;
        }

        // Frame rate limiting: skip render if too soon since last frame
        if (effective_frame_ns > 0) {
            if (loop_now - last_render_ns < effective_frame_ns) continue;
        }

        const buf = backend.getBuffer();
        const stride = backend.getStride();

        const all_dirty = term.isAllDirty();

        // Global background fill when all cells dirty — one memset
        // replaces 30,720 individual per-cell memsets (80×24×16 rows)
        if (all_dirty) {
            const default_bg = render.palette[config.default_bg];
            const bg_packed = [4]u8{ default_bg.b, default_bg.g, default_bg.r, 0xFF };
            const row_pixels = backend.getWidth();
            var py: u32 = 0;
            while (py < backend.getHeight()) : (py += 1) {
                const row_offset = @as(usize, py) * @as(usize, stride);
                const pixel_buf: [*][4]u8 = @ptrCast(buf.ptr + row_offset);
                @memset(pixel_buf[0..row_pixels], bg_packed);
            }
            backend.markDirtyRows(0, backend.getHeight() - 1);
        }

        var y: u32 = 0;
        while (y < term.rows) : (y += 1) {
            if (!all_dirty and !term.isRowDirty(y)) continue;

            // Resolve physical row once per row — eliminates per-cell
            // bounds checks, row_map lookups, and multiplications
            const phys_row = term.row_map[y];
            const row_base = @as(usize, phys_row) * @as(usize, term.cols);
            const row_cells = term.cells[row_base..][0..term.cols];
            const row_fg = term.fg_rgb[row_base..][0..term.cols];
            const row_bg = term.bg_rgb[row_base..][0..term.cols];
            const row_ul = term.ul_color_rgb[row_base..][0..term.cols];
            const row_hl = term.hyperlink_ids[row_base..][0..term.cols];
            const dirty_row_base = @as(usize, y) * @as(usize, term.cols);

            var x: u32 = 0;
            while (x < term.cols) : (x += 1) {
                if (!all_dirty and !term.dirty.isSet(dirty_row_base + x)) continue;

                const cell = &row_cells[x];
                if (cell.attrs.wide_dummy) continue;

                var fg_rgb = row_fg[x];
                var bg_rgb = row_bg[x];
                const ul_rgb = row_ul[x];
                const glyph = if (cell.char == ' ' or cell.char == 0) null else FontType.getGlyph(cell.char);
                const is_cursor = (x == term.cursor_x and y == term.cursor_y and term.cursor_visible and cursor_visible_blink);

                var render_cell = cell.*;
                // Hyperlinked cells: show underline if not already underlined
                if (row_hl[x] != 0 and render_cell.attrs.underline_style == 0) {
                    render_cell.attrs.underline_style = 1;
                }
                const in_selection = if (term.selection) |sel| sel.contains(x, y) else false;

                // Invert fg/bg for cursor or selection, but not both
                // (double inversion cancels out, making cursor invisible)
                if (is_cursor != in_selection) {
                    const tmp_idx = render_cell.fg;
                    render_cell.fg = render_cell.bg;
                    render_cell.bg = tmp_idx;
                    const tmp_rgb = fg_rgb;
                    fg_rgb = bg_rgb;
                    bg_rgb = tmp_rgb;
                }

                // Skip per-cell bg fill when global fill was applied, UNLESS:
                // - cell has non-default bg color (palette index != default)
                // - cell has TrueColor bg override
                // - cell has reverse attribute (swaps fg/bg, so bg won't match default)
                const skip_bg = all_dirty and (render_cell.bg == config.default_bg) and (bg_rgb == null) and !render_cell.attrs.reverse;
                if (skip_bg) {
                    if (cell.attrs.wide) {
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, ul_rgb, glyph, config.font_width, config.font_height, .bgra32, true, config.scale, true);
                    } else {
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, ul_rgb, glyph, config.font_width, config.font_height, .bgra32, false, config.scale, true);
                    }
                } else {
                    if (cell.attrs.wide) {
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, ul_rgb, glyph, config.font_width, config.font_height, .bgra32, true, config.scale, false);
                    } else {
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, ul_rgb, glyph, config.font_width, config.font_height, .bgra32, false, config.scale, false);
                    }
                }
            }
            // Mark dirty once per row instead of per cell
            if (!all_dirty) backend.markDirtyRows(y * config.cell_height, (y + 1) * config.cell_height - 1);
        }
        term.clearDirty();
        last_render_ns = std.time.nanoTimestamp();
        bytes_since_render = 0;

        // Update IME cursor position only on render (avoids XIM request storms during heavy output)
        if (@hasDecl(Backend, "updateImeCursorPos")) {
            backend.updateImeCursorPos(
                term.cursor_x * config.cell_width,
                (term.cursor_y + 1) * config.cell_height,
            );
        }

        backend.present();
        backend.flush();
    }
}

test {
    _ = @import("font.zig");
    _ = @import("term.zig");
    _ = @import("vt.zig");
    _ = @import("pty.zig");
    _ = @import("input.zig");
    _ = @import("render.zig");
}
