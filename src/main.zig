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
    const changelist = [1]std.posix.Kevent{.{
        .ident = @intCast(pty_fd),
        .filter = std.c.EVFILT.WRITE,
        .flags = std.c.EV.ADD | if (enable) std.c.EV.ENABLE else std.c.EV.DISABLE,
        .fflags = 0,
        .data = 0,
        .udata = @intFromEnum(KqueueTag.pty),
    }};
    _ = std.posix.kevent(kq, &changelist, &.{}, null) catch |err| {
        std.log.debug("kqueueSetPtyWrite failed: {}", .{err});
    };
}

/// Write to PTY with buffering on WouldBlock.
fn ptyBufferedWrite(
    pty_ptr: *Pty,
    data: []const u8,
    write_buf: *[4096]u8,
    write_pending: *usize,
    epoll_fd: i32,
) bool {
    // If there's pending data, just append to buffer
    if (write_pending.* > 0) {
        const space = write_buf.len - write_pending.*;
        const to_copy = @min(data.len, space);
        if (to_copy > 0) {
            @memcpy(write_buf[write_pending.* .. write_pending.* + to_copy], data[0..to_copy]);
            write_pending.* += to_copy;
        }
        return true; // still running
    }

    // Try direct write
    const written = pty_ptr.write(data) catch |err| switch (err) {
        error.WouldBlock => {
            // Buffer everything
            const to_copy = @min(data.len, write_buf.len);
            @memcpy(write_buf[0..to_copy], data[0..to_copy]);
            write_pending.* = to_copy;
            if (is_linux) {
                epollSetPtyEvents(epoll_fd, pty_ptr.master_fd, true);
            } else {
                kqueueSetPtyWrite(epoll_fd, pty_ptr.master_fd, true);
            }
            return true;
        },
        else => return false,
    };

    // Partial write — buffer the rest
    if (written < data.len) {
        const remaining = data.len - written;
        const to_copy = @min(remaining, write_buf.len);
        @memcpy(write_buf[0..to_copy], data[written .. written + to_copy]);
        write_pending.* = to_copy;
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
    write_buf: *[4096]u8,
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
    const signo: u32 = if (signo_override) |s| s else blk: {
        var siginfo: linux.signalfd_siginfo = undefined;
        _ = std.posix.read(sig_fd, std.mem.asBytes(&siginfo)) catch return true;
        break :blk siginfo.signo;
    };

    return switch (signo) {
        SIG_CHLD, SIG_TERM, SIG_INT, SIG_HUP => false,
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
    const args = std.process.argsAlloc(allocator) catch null;
    defer if (args) |a| std.process.argsFree(allocator, a);
    if (args) |argv| {
        var i: usize = 1; // skip argv[0]
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "-e")) {
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
        .x11, .wayland, .macos => try Backend.init(),
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
                pty.resize(@intCast(new_cols), @intCast(new_rows)) catch {};
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
    var prev_cursor_x: u32 = 0;
    var prev_cursor_y: u32 = 0;
    var write_buf: [4096]u8 = undefined;
    var write_pending: usize = 0;
    var last_render_ns: i128 = 0;
    var bytes_since_render: usize = 0;

    while (running) {
        const loop_now = std.time.nanoTimestamp();
        // Adaptive frame rate: smoothly reduce render frequency during heavy output
        // Tier 0: <64KB  → frame_min_ns (default 8ms = 120fps)
        // Tier 1: 64KB+  → frame_min_ns * 2 (default 16ms = 60fps)
        // Tier 2: 256KB+ → frame_min_ns * 8 (default 64ms = ~15fps)
        // Tier 3: 1MB+   → frame_min_ns * 24 (default 192ms = ~5fps)
        const effective_frame_ns: i128 = if (config.frame_min_ns == 0)
            0
        else if (bytes_since_render > 1_048_576)
            @as(i128, config.frame_min_ns) * 24
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

        if (is_linux) {
            // ---- Linux epoll dispatch ----
            var events: [16]linux.epoll_event = undefined;
            const n_raw = linux.epoll_wait(evloop_fd, &events, events.len, event_timeout);
            const n_isize: isize = @bitCast(n_raw);
            if (n_isize < 0) continue; // EINTR
            const n: usize = @intCast(n_raw);

            for (events[0..n]) |ev| {
                switch (ev.data.u32) {
                    @intFromEnum(EpollTag.pty) => {
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
                                vt.feedBulk(&parser, pty_buf[0..bytes_read], &term, pty.master_fd);
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
                        cursor_visible_blink = !cursor_visible_blink;
                        // Mark cursor cell dirty for redraw
                        term.markDirty(term.cursor_x, term.cursor_y);
                    },
                    @intFromEnum(EpollTag.backend) => {
                        // Backend events (X11, Wayland or macOS)
                        if (config.backend == .x11 or config.backend == .wayland or config.backend == .macos) {
                            while (backend.pollEvents()) |event| {
                                switch (event) {
                                    .key => |key_ev| {
                                        if (key_ev.pressed) {
                                            const bytes = input.translateKey(key_ev.keycode, key_ev.modifiers, term.decckm);
                                            if (bytes.len > 0) {
                                                if (!ptyBufferedWrite(&pty, bytes, &write_buf, &write_pending, evloop_fd)) {
                                                    running = false;
                                                    break;
                                                }
                                            }
                                        }
                                    },
                                    .text => |text_ev| {
                                        // IME committed text -- write UTF-8 directly to PTY
                                        const text = text_ev.slice();
                                        if (text.len > 0) {
                                            if (!ptyBufferedWrite(&pty, text, &write_buf, &write_pending, evloop_fd)) {
                                                running = false;
                                                break;
                                            }
                                        }
                                    },
                                    .paste => |paste_ev| {
                                        // Clipboard paste -- write to PTY
                                        const text = paste_ev.slice();
                                        if (text.len > 0) {
                                            if (!ptyBufferedWrite(&pty, text, &write_buf, &write_pending, evloop_fd)) {
                                                running = false;
                                                break;
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
                                            pty.resize(@intCast(new_cols), @intCast(new_rows)) catch |err| {
                                                std.log.err("pty resize: {}", .{err});
                                            };
                                            backend.resize(rsz.width, rsz.height) catch |err| {
                                                std.log.err("backend resize: {}", .{err});
                                            };
                                        }
                                    },
                                    .expose => {
                                        // Force full redraw — mark all term cells dirty
                                        const total = @as(usize, term.cols) * @as(usize, term.rows);
                                        term.markDirtyRange(.{ .start = 0, .end = total });
                                        term.all_dirty = true;
                                    },
                                    .focus_in => {
                                        if (term.focus_events) {
                                            if (!ptyBufferedWrite(&pty, "\x1b[I", &write_buf, &write_pending, evloop_fd)) {
                                                running = false;
                                                break;
                                            }
                                        }
                                    },
                                    .focus_out => {
                                        if (term.focus_events) {
                                            if (!ptyBufferedWrite(&pty, "\x1b[O", &write_buf, &write_pending, evloop_fd)) {
                                                running = false;
                                                break;
                                            }
                                        }
                                    },
                                    .close => {
                                        running = false;
                                    },
                                }
                            }
                        }
                    },
                    else => {
                        // evdev fds (fbdev backend)
                        if (config.backend == .fbdev) {
                            const evdev_idx = ev.data.u32 - EVDEV_BASE;
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
                                            const bytes = input.translateKey(input_event.keycode, mod_state, term.decckm);
                                            if (bytes.len > 0) {
                                                if (!ptyBufferedWrite(&pty, bytes, &write_buf, &write_pending, evloop_fd)) {
                                                    running = false;
                                                    break;
                                                }
                                            }
                                        }
                                    },
                                }
                            }
                        }
                    },
                }
            }
        } else {
            // ---- macOS kqueue dispatch ----
            const timeout_spec: ?std.posix.timespec = if (event_timeout < 0) null else .{
                .sec = @divFloor(@as(isize, event_timeout), 1000),
                .nsec = @rem(@as(isize, event_timeout), 1000) * 1_000_000,
            };
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
                            vt.feedBulk(&parser, pty_buf[0..bytes_read], &term, pty.master_fd);
                        }
                    } else if (kev.udata == @intFromEnum(KqueueTag.backend)) {
                        // Backend events (X11, Wayland or macOS)
                        if (config.backend == .x11 or config.backend == .wayland or config.backend == .macos) {
                            while (backend.pollEvents()) |event| {
                                switch (event) {
                                    .key => |key_ev| {
                                        if (key_ev.pressed) {
                                            const bytes = input.translateKey(key_ev.keycode, key_ev.modifiers, term.decckm);
                                            if (bytes.len > 0) {
                                                if (!ptyBufferedWrite(&pty, bytes, &write_buf, &write_pending, evloop_fd)) {
                                                    running = false;
                                                    break;
                                                }
                                            }
                                        }
                                    },
                                    .text => |text_ev| {
                                        const text = text_ev.slice();
                                        if (text.len > 0) {
                                            if (!ptyBufferedWrite(&pty, text, &write_buf, &write_pending, evloop_fd)) {
                                                running = false;
                                                break;
                                            }
                                        }
                                    },
                                    .paste => |paste_ev| {
                                        const text = paste_ev.slice();
                                        if (text.len > 0) {
                                            if (!ptyBufferedWrite(&pty, text, &write_buf, &write_pending, evloop_fd)) {
                                                running = false;
                                                break;
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
                                            pty.resize(@intCast(new_cols), @intCast(new_rows)) catch |err| {
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
                                        if (term.focus_events) {
                                            if (!ptyBufferedWrite(&pty, "\x1b[I", &write_buf, &write_pending, evloop_fd)) {
                                                running = false;
                                                break;
                                            }
                                        }
                                    },
                                    .focus_out => {
                                        if (term.focus_events) {
                                            if (!ptyBufferedWrite(&pty, "\x1b[O", &write_buf, &write_pending, evloop_fd)) {
                                                running = false;
                                                break;
                                            }
                                        }
                                    },
                                    .close => {
                                        running = false;
                                    },
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
                    cursor_visible_blink = !cursor_visible_blink;
                    term.markDirty(term.cursor_x, term.cursor_y);
                }
            }
        }

        // Extra PTY drain: data may have arrived during event processing.
        // Capped at 1MB to prevent render starvation from infinite producers (yes, cat /dev/urandom).
        if (running) {
            var extra_total: usize = 0;
            while (extra_total < config.pty_buf_size * 4) {
                const extra = pty.read(&pty_buf) catch break;
                if (extra == 0) { running = false; break; }
                bytes_since_render += extra;
                extra_total += extra;
                vt.feedBulk(&parser, pty_buf[0..extra], &term, pty.master_fd);
            }
        }

        // Mark old cursor position dirty if cursor moved
        if (prev_cursor_x != term.cursor_x or prev_cursor_y != term.cursor_y) {
            term.markDirty(prev_cursor_x, prev_cursor_y);
            term.markDirty(term.cursor_x, term.cursor_y);
        }
        prev_cursor_x = term.cursor_x;
        prev_cursor_y = term.cursor_y;

        // Render dirty cells — skip entirely if nothing changed
        if (!term.hasDirty()) continue;

        // Synchronized output (DEC 2026): defer render until ESU
        if (term.sync_update) continue;

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
            const total_pixels = @as(usize, backend.getWidth()) * @as(usize, backend.getHeight());
            const pixel_buf: [*][4]u8 = @ptrCast(buf.ptr);
            @memset(pixel_buf[0..total_pixels], bg_packed);
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
            const dirty_row_base = @as(usize, y) * @as(usize, term.cols);

            var x: u32 = 0;
            while (x < term.cols) : (x += 1) {
                if (!all_dirty and !term.dirty.isSet(dirty_row_base + x)) continue;

                const cell = &row_cells[x];
                if (cell.attrs.wide_dummy) continue;

                var fg_rgb = row_fg[x];
                var bg_rgb = row_bg[x];
                const glyph = if (cell.char == ' ' or cell.char == 0) null else FontType.getGlyph(cell.char);
                const is_cursor = (x == term.cursor_x and y == term.cursor_y and term.cursor_visible and cursor_visible_blink);

                var render_cell = cell.*;
                if (is_cursor) {
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
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, true, config.scale, true);
                    } else {
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, false, config.scale, true);
                    }
                } else {
                    if (cell.attrs.wide) {
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, true, config.scale, false);
                    } else {
                        render.renderCell(buf, stride, x, y, render_cell, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32, false, config.scale, false);
                    }
                }

                backend.markDirtyRows(y * config.cell_height, (y + 1) * config.cell_height - 1);
            }
        }
        term.clearDirty();
        last_render_ns = loop_now;
        bytes_since_render = 0;

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
