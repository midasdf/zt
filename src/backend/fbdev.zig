const std = @import("std");

// Linux ioctl constants
const FBIOGET_VSCREENINFO: u32 = 0x4600;
const FBIOGET_FSCREENINFO: u32 = 0x4602;

// Keyboard mode constants
const KDGKBMODE: u32 = 0x4B44;
const KDSKBMODE: u32 = 0x4B45;
const K_RAW: i32 = 0x00;

// VT constants
const VT_SETMODE: u32 = 0x5602;
const VT_RELDISP: u32 = 0x5605;
const VT_ACKACQ: i32 = 0x02;
const VT_PROCESS: u8 = 1;

// evdev constants
const EV_KEY: u16 = 1;

// EVIOCGBIT(ev_type, len) = _IOC(_IOC_READ, 'E', 0x20 + ev_type, len)
// _IOC_READ = 2
// 'E' = 0x45
// For EV_KEY (1): EVIOCGBIT(1, 96) where 96 = ceil(KEY_MAX/8) ~ KEY_CNT/8
// _IOC(2, 0x45, 0x21, 96) = (2 << 30) | (96 << 16) | (0x45 << 8) | 0x21
const EVIOCGBIT_EV_KEY: u32 = (2 << 30) | (96 << 16) | (0x45 << 8) | 0x21;

const FbVarScreenInfo = extern struct {
    xres: u32,
    yres: u32,
    xres_virtual: u32,
    yres_virtual: u32,
    xoffset: u32,
    yoffset: u32,
    bits_per_pixel: u32,
    grayscale: u32,
    red: FbBitfield,
    green: FbBitfield,
    blue: FbBitfield,
    transp: FbBitfield,
    nonstd: u32,
    activate: u32,
    height: u32,
    width: u32,
    accel_flags: u32,
    pixclock: u32,
    left_margin: u32,
    right_margin: u32,
    upper_margin: u32,
    lower_margin: u32,
    hsync_len: u32,
    vsync_len: u32,
    sync: u32,
    vmode: u32,
    rotate: u32,
    colorspace: u32,
    reserved: [4]u32,
};

const FbBitfield = extern struct {
    offset: u32,
    length: u32,
    msb_right: u32,
};

const FbFixScreenInfo = extern struct {
    id: [16]u8,
    smem_start: usize,
    smem_len: u32,
    type_: u32,
    type_aux: u32,
    visual: u32,
    xpanstep: u16,
    ypanstep: u16,
    ywrapstep: u16,
    _pad: u16,
    line_length: u32,
    mmio_start: usize,
    mmio_len: u32,
    accel: u32,
    capabilities: u16,
    reserved: [2]u16,
};

const VtMode = extern struct {
    mode: u8,
    waitv: u8,
    relsig: i16,
    acqsig: i16,
    frsig: i16,
};

pub const InputEvent = struct {
    keycode: u16,
    pressed: bool,
    repeat: bool,
};

pub const FbdevBackend = struct {
    const Self = @This();

    fb_fd: std.posix.fd_t,
    fb_mem: []align(std.heap.page_size_min) u8,
    shadow: []u8,
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    stride: u32,
    bpp: u32,
    evdev_fds: [8]std.posix.fd_t,
    evdev_count: u8 = 0,
    tty_fd: std.posix.fd_t,
    original_kb_mode: i32 = 0,
    dirty_y_min: u32 = std.math.maxInt(u32),
    dirty_y_max: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !Self {
        // 1. Open /dev/fb0
        const fb_fd = try std.posix.open("/dev/fb0", .{ .ACCMODE = .RDWR }, 0);
        errdefer std.posix.close(fb_fd);

        // 2. Get variable screen info
        var vinfo: FbVarScreenInfo = undefined;
        const vinfo_ret = std.os.linux.ioctl(fb_fd, FBIOGET_VSCREENINFO, @intFromPtr(&vinfo));
        if (@as(isize, @bitCast(vinfo_ret)) < 0) return error.IoctlFailed;

        // 3. Get fixed screen info
        var finfo: FbFixScreenInfo = undefined;
        const finfo_ret = std.os.linux.ioctl(fb_fd, FBIOGET_FSCREENINFO, @intFromPtr(&finfo));
        if (@as(isize, @bitCast(finfo_ret)) < 0) return error.IoctlFailed;

        const fb_size = finfo.line_length * vinfo.yres;
        const bpp = vinfo.bits_per_pixel / 8;

        // Render loop hardcodes BGRA32 — validate pixel format and channel layout
        if (bpp != 4 or
            vinfo.blue.offset != 0 or vinfo.blue.length != 8 or
            vinfo.green.offset != 8 or vinfo.green.length != 8 or
            vinfo.red.offset != 16 or vinfo.red.length != 8)
        {
            std.log.err("fbdev: unsupported pixel format (need 32bpp BGRA, got {d}bpp R@{d}/{d} G@{d}/{d} B@{d}/{d})", .{
                vinfo.bits_per_pixel,
                vinfo.red.offset,   vinfo.red.length,
                vinfo.green.offset, vinfo.green.length,
                vinfo.blue.offset,  vinfo.blue.length,
            });
            return error.UnsupportedPixelFormat;
        }

        // 4. mmap the framebuffer
        const fb_mem = try std.posix.mmap(
            null,
            fb_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fb_fd,
            0,
        );

        // 5. Allocate shadow buffer
        const shadow = try allocator.alloc(u8, fb_size);
        @memset(shadow, 0);

        // 6. Scan for evdev keyboards
        var evdev_fds: [8]std.posix.fd_t = [_]std.posix.fd_t{-1} ** 8;
        var evdev_count: u8 = 0;

        for (0..32) |i| {
            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/dev/input/event{d}", .{i}) catch continue;
            // Null-terminate for open
            var c_path: [32:0]u8 = undefined;
            @memcpy(c_path[0..path.len], path);
            c_path[path.len] = 0;
            const fd = std.posix.open(&c_path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch continue;

            // Check if it's a keyboard
            var key_bits: [96]u8 = [_]u8{0} ** 96;
            const ev_ret = std.os.linux.ioctl(fd, EVIOCGBIT_EV_KEY, @intFromPtr(&key_bits));
            if (@as(isize, @bitCast(ev_ret)) < 0) {
                std.posix.close(fd);
                continue;
            }

            // Check for some common key bits (KEY_A = 30, KEY_ENTER = 28)
            // Byte 3, bit 4 = key 28; byte 3, bit 6 = key 30
            const has_enter = (key_bits[28 / 8] & (@as(u8, 1) << @intCast(28 % 8))) != 0;
            const has_a = (key_bits[30 / 8] & (@as(u8, 1) << @intCast(30 % 8))) != 0;
            if (has_enter and has_a) {
                evdev_fds[evdev_count] = fd;
                evdev_count += 1;
                if (evdev_count >= 8) break;
            } else {
                std.posix.close(fd);
            }
        }

        // 7. Open tty
        const tty_fd = std.posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch -1;

        return Self{
            .fb_fd = fb_fd,
            .fb_mem = fb_mem,
            .shadow = shadow,
            .allocator = allocator,
            .width = vinfo.xres,
            .height = vinfo.yres,
            .stride = finfo.line_length,
            .bpp = bpp,
            .evdev_fds = evdev_fds,
            .evdev_count = evdev_count,
            .tty_fd = tty_fd,
        };
    }

    pub fn deinit(self: *Self) void {
        self.restoreConsoleState();

        for (0..self.evdev_count) |i| {
            std.posix.close(self.evdev_fds[i]);
        }

        self.allocator.free(self.shadow);
        std.posix.munmap(self.fb_mem);
        std.posix.close(self.fb_fd);
        if (self.tty_fd >= 0) std.posix.close(self.tty_fd);
    }

    pub fn getBuffer(self: *Self) []u8 {
        return self.shadow;
    }

    pub fn getStride(self: *Self) u32 {
        return self.stride;
    }

    pub fn getWidth(self: *Self) u32 {
        return self.width;
    }

    pub fn getHeight(self: *Self) u32 {
        return self.height;
    }

    pub fn getBpp(self: *Self) u32 {
        return self.bpp;
    }

    pub fn markDirtyRows(self: *Self, y_start: u32, y_end: u32) void {
        if (y_start < self.dirty_y_min) self.dirty_y_min = y_start;
        if (y_end > self.dirty_y_max) self.dirty_y_max = y_end;
    }

    pub fn present(self: *Self) void {
        if (self.dirty_y_min > self.dirty_y_max) return;
        const start = self.dirty_y_min * self.stride;
        const end = @min((self.dirty_y_max + 1) * self.stride, @as(u32, @intCast(self.fb_mem.len)));
        @memcpy(self.fb_mem[start..end], self.shadow[start..end]);
        self.dirty_y_min = std.math.maxInt(u32);
        self.dirty_y_max = 0;
    }

    /// No-op for fbdev — present() writes directly to framebuffer.
    pub fn flush(_: *Self) void {}

    pub fn getFd(self: *Self) ?std.posix.fd_t {
        _ = self;
        return null;
    }

    pub fn resize(self: *Self, w: u32, h: u32) void {
        _ = self;
        _ = w;
        _ = h;
        // fbdev has fixed resolution, no-op
    }

    pub fn readEvdev(self: *Self, evdev_index: u32) ?InputEvent {
        if (evdev_index >= self.evdev_count) return null;
        const fd = self.evdev_fds[evdev_index];
        const InputEventRaw = extern struct {
            tv_sec: std.c.time_t, // C `long` — 4 bytes on 32-bit, 8 on 64-bit
            tv_usec: isize, // suseconds_t is C `long`
            type: u16,
            code: u16,
            value: i32,
        };
        var ev: InputEventRaw = undefined;
        const n = std.posix.read(fd, std.mem.asBytes(&ev)) catch return null;
        if (n < @sizeOf(InputEventRaw)) return null;
        const ev_type = ev.type;
        const ev_code = ev.code;
        const ev_value = ev.value;
        if (ev_type != EV_KEY) return null;
        return .{
            .keycode = ev_code,
            .pressed = ev_value == 1,
            .repeat = ev_value == 2,
        };
    }

    pub fn saveConsoleState(self: *Self) !void {
        if (self.tty_fd < 0) return;
        const ret = std.os.linux.ioctl(self.tty_fd, KDGKBMODE, @intFromPtr(&self.original_kb_mode));
        if (@as(isize, @bitCast(ret)) < 0) return error.IoctlFailed;
    }

    pub fn restoreConsoleState(self: *Self) void {
        if (self.tty_fd < 0) return;
        _ = std.os.linux.ioctl(self.tty_fd, KDSKBMODE, @as(usize, @intCast(self.original_kb_mode)));
    }

    pub fn setupVtSwitching(self: *Self) !void {
        if (self.tty_fd < 0) return error.NoTty;
        try self.saveConsoleState();

        var mode = VtMode{
            .mode = VT_PROCESS,
            .waitv = 0,
            .relsig = std.posix.SIG.USR1,
            .acqsig = std.posix.SIG.USR2,
            .frsig = 0,
        };
        const ret = std.os.linux.ioctl(self.tty_fd, VT_SETMODE, @intFromPtr(&mode));
        if (@as(isize, @bitCast(ret)) < 0) return error.IoctlFailed;
    }

    pub fn releaseVt(self: *Self) void {
        if (self.tty_fd < 0) return;
        _ = std.os.linux.ioctl(self.tty_fd, VT_RELDISP, @as(usize, 1));
    }

    pub fn acquireVt(self: *Self) void {
        if (self.tty_fd < 0) return;
        _ = std.os.linux.ioctl(self.tty_fd, VT_RELDISP, @as(usize, @intCast(VT_ACKACQ)));
        // Mark all rows dirty for full redraw
        self.dirty_y_min = 0;
        self.dirty_y_max = self.height -| 1;
    }
};
