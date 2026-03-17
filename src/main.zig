const std = @import("std");
const linux = std.os.linux;
const config = @import("config");

const Term = @import("term.zig").Term;
const Cell = @import("term.zig").Cell;
const vt = @import("vt.zig");
const Pty = @import("pty.zig").Pty;
const input = @import("input.zig");
const render = @import("render.zig");
const font_mod = @import("font.zig");

// Backend selection at comptime
const Backend = if (config.backend == .fbdev)
    @import("backend/fbdev.zig").FbdevBackend
else
    @import("backend/x11.zig").X11Backend;

// X11 Event type (only used for x11 backend)
const X11Event = if (config.backend == .x11)
    @import("backend/x11.zig").Event
else
    void;

// Embed font at comptime
// Large fonts use pre-compiled blob (bdf2blob.py) to avoid slow comptime parsing
const FontType = font_mod.FontBlob(@embedFile("fonts/ufo-nf.bin"));

// =============================================================================
// Signal handling via signalfd
// =============================================================================

fn setupSignals() !std.posix.fd_t {
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
}

// =============================================================================
// Timer fd for cursor blink
// =============================================================================

fn createTimerFd(interval_ns: u64) !std.posix.fd_t {
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

// =============================================================================
// Signal handler
// =============================================================================

fn handleSignal(sig_fd: std.posix.fd_t, backend: *Backend) bool {
    var siginfo: linux.signalfd_siginfo = undefined;
    _ = std.posix.read(sig_fd, std.mem.asBytes(&siginfo)) catch return true;

    return switch (siginfo.signo) {
        linux.SIG.CHLD, linux.SIG.TERM, linux.SIG.INT, linux.SIG.HUP => false,
        linux.SIG.USR1 => blk: {
            backend.releaseVt();
            break :blk true;
        },
        linux.SIG.USR2 => blk: {
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Init backend
    var backend = if (config.backend == .fbdev)
        try Backend.init(allocator)
    else
        try Backend.init();
    defer backend.deinit();

    // 2. Save console state (fbdev only, noop for X11)
    try backend.saveConsoleState();
    defer backend.restoreConsoleState();

    // 3. Setup VT switching (fbdev only, noop for X11)
    backend.setupVtSwitching() catch {};

    // 4. Calculate grid dimensions
    const cols: u32 = backend.getWidth() / config.font_width;
    const rows: u32 = backend.getHeight() / config.font_height;

    // 5. Init term
    var term = try Term.init(allocator, cols, rows);
    defer term.deinit();

    // 6. Spawn PTY
    var pty = try Pty.spawn(@intCast(cols), @intCast(rows), config.shell);
    defer pty.deinit();

    // 7. Setup signals
    const sig_fd = try setupSignals();
    defer std.posix.close(sig_fd);

    // 8. Setup cursor blink timer (500ms)
    const timer_fd = try createTimerFd(500_000_000);
    defer std.posix.close(timer_fd);

    // 9. Setup epoll
    const epoll_fd_raw = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    const epoll_isize: isize = @bitCast(epoll_fd_raw);
    if (epoll_isize < 0) return error.EpollCreateFailed;
    const epoll_fd: i32 = @intCast(epoll_isize);
    defer std.posix.close(epoll_fd);

    try epollAdd(epoll_fd, pty.master_fd, @intFromEnum(EpollTag.pty));
    try epollAdd(epoll_fd, sig_fd, @intFromEnum(EpollTag.signal));
    try epollAdd(epoll_fd, timer_fd, @intFromEnum(EpollTag.timer));

    // Backend event fd (X11 has xcb fd, fbdev returns null)
    if (backend.getFd()) |fd| {
        try epollAdd(epoll_fd, fd, @intFromEnum(EpollTag.backend));
    }

    // For fbdev: register evdev fds
    if (config.backend == .fbdev) {
        for (0..backend.evdev_count) |i| {
            try epollAdd(epoll_fd, backend.evdev_fds[i], EVDEV_BASE + @as(u32, @intCast(i)));
        }
    }

    // 10. Event loop
    var parser = vt.Parser{};
    var running = true;
    var pty_buf: [65536]u8 = undefined;
    var cursor_visible_blink = true;

    while (running) {
        var events: [16]linux.epoll_event = undefined;
        const n_raw = linux.epoll_wait(epoll_fd, &events, events.len, -1);
        const n_isize: isize = @bitCast(n_raw);
        if (n_isize < 0) continue; // EINTR
        const n: usize = @intCast(n_raw);

        for (events[0..n]) |ev| {
            switch (ev.data.u32) {
                @intFromEnum(EpollTag.pty) => {
                    // PTY readable — bulk read + batch parse
                    const bytes_read = pty.read(&pty_buf) catch {
                        running = false;
                        break;
                    };
                    if (bytes_read == 0) {
                        running = false;
                        break;
                    }
                    for (pty_buf[0..bytes_read]) |byte| {
                        const action = parser.feed(byte);
                        vt.executeAction(action, &term);
                    }
                },
                @intFromEnum(EpollTag.signal) => {
                    running = handleSignal(sig_fd, &backend);
                },
                @intFromEnum(EpollTag.timer) => {
                    // Read timer to acknowledge
                    var exp: u64 = 0;
                    _ = std.posix.read(timer_fd, std.mem.asBytes(&exp)) catch {};
                    cursor_visible_blink = !cursor_visible_blink;
                    // Mark cursor cell dirty for redraw
                    if (term.cursor_x < term.cols and term.cursor_y < term.rows) {
                        term.setCell(term.cursor_x, term.cursor_y, term.getCell(term.cursor_x, term.cursor_y).*);
                    }
                },
                @intFromEnum(EpollTag.backend) => {
                    // X11 events (keys, resize, close)
                    if (config.backend == .x11) {
                        while (backend.pollEvents()) |event| {
                            switch (event) {
                                .key => |key_ev| {
                                    if (key_ev.pressed) {
                                        const bytes = input.translateKey(key_ev.keycode, key_ev.modifiers, term.decckm);
                                        if (bytes.len > 0) {
                                            _ = pty.write(bytes) catch |err| switch (err) {
                                                error.WouldBlock => {},
                                                else => {
                                                    running = false;
                                                    break;
                                                },
                                            };
                                        }
                                    }
                                },
                                .resize => |rsz| {
                                    const new_cols = rsz.width / config.font_width;
                                    const new_rows = rsz.height / config.font_height;
                                    if (new_cols > 0 and new_rows > 0) {
                                        term.resize(new_cols, new_rows) catch {};
                                        pty.resize(@intCast(new_cols), @intCast(new_rows)) catch {};
                                        backend.resize(rsz.width, rsz.height) catch {};
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
                        if (backend.readEvdev(evdev_idx)) |input_event| {
                            if (input_event.pressed or input_event.repeat) {
                                const bytes = input.translateKey(input_event.keycode, .{}, term.decckm);
                                if (bytes.len > 0) {
                                    _ = pty.write(bytes) catch |err| switch (err) {
                                        error.WouldBlock => {},
                                        else => {
                                            running = false;
                                            break;
                                        },
                                    };
                                }
                            }
                        }
                    }
                },
            }
        }

        // Render dirty cells
        const buf = backend.getBuffer();
        const stride = backend.getStride();
        var y: u32 = 0;
        while (y < term.rows) : (y += 1) {
            var x: u32 = 0;
            while (x < term.cols) : (x += 1) {
                if (term.isDirty(x, y)) {
                    const cell = term.getCell(x, y);
                    const fg_rgb = term.getFgRgb(x, y);
                    const bg_rgb = term.getBgRgb(x, y);
                    const glyph = FontType.getGlyph(cell.char);

                    // Is this the cursor cell?
                    const is_cursor = (x == term.cursor_x and y == term.cursor_y and term.cursor_visible and cursor_visible_blink);

                    if (is_cursor) {
                        render.renderCursor(buf, stride, x, y, cell.*, glyph, config.font_width, config.font_height, .bgra32);
                    } else {
                        render.renderCell(buf, stride, x, y, cell.*, fg_rgb, bg_rgb, glyph, config.font_width, config.font_height, .bgra32);
                    }

                    backend.markDirtyRows(y * config.font_height, (y + 1) * config.font_height - 1);
                }
            }
        }
        term.clearDirty();
        backend.present();
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
