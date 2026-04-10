const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const config = @import("config");
const input_mod = @import("../input.zig");

const wire = @import("wayland/wire.zig");
const core = @import("wayland/core.zig");
const xdg_shell = @import("wayland/xdg_shell.zig");
const decoration = @import("wayland/decoration.zig");
const seat_mod = @import("wayland/seat.zig");
const text_input_mod = @import("wayland/text_input.zig");
const clipboard_mod = @import("wayland/clipboard.zig");

// ============================================================================
// Event types — mirrors x11.zig's Event union
// ============================================================================

pub const MouseEvent = struct {
    x: u32, // pixel x
    y: u32, // pixel y
    button: Button,
    action: Action,
    modifiers: input_mod.Modifiers,

    pub const Button = enum(u3) {
        left = 0,
        middle = 1,
        right = 2,
        none = 3,
        wheel_up = 4,
        wheel_down = 5,
        wheel_left = 6,
        wheel_right = 7,
    };

    pub const Action = enum(u2) {
        press,
        release,
        motion,
    };
};

pub const Event = union(enum) {
    key: KeyEvent,
    text: TextEvent,
    paste: PasteEvent,
    resize: ResizeEvent,
    expose: void,
    close: void,
    focus_in: void,
    focus_out: void,
    mouse: MouseEvent,
};

pub const PasteEvent = struct {
    ptr: [*]const u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const PasteEvent) []const u8 {
        if (self.len == 0) return &.{};
        return self.ptr[0..self.len];
    }
};

pub const TextEvent = struct {
    data: [128]u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const TextEvent) []const u8 {
        return self.data[0..self.len];
    }
};

pub const KeyEvent = struct {
    keycode: u16,
    pressed: bool,
    modifiers: input_mod.Modifiers,
};

pub const ResizeEvent = struct {
    width: u32,
    height: u32,
};

// ============================================================================
// Internal epoll tags
// ============================================================================

const EPOLL_TAG_WAYLAND: u32 = 0;
const EPOLL_TAG_REPEAT: u32 = 1;
const EPOLL_TAG_CLIPBOARD: u32 = 2;

/// Block until the Wayland socket has data available for reading.
/// Used during init/postInit where we must wait for compositor responses
/// on a non-blocking socket.  Timeout of 5 seconds prevents hanging forever.
fn waitForSocket(epoll_fd: posix.fd_t) !void {
    var events: [1]linux.epoll_event = undefined;
    while (true) {
        const rc = linux.epoll_wait(epoll_fd, &events, 1, 5000);
        const n: isize = @bitCast(rc);
        if (n < 0) {
            const err: u32 = @intCast(-n);
            if (err == @intFromEnum(posix.E.INTR)) continue;
            return error.EpollWaitFailed;
        }
        if (n == 0) return error.InitTimeout;
        return; // data available
    }
}

// ============================================================================
// WaylandBackend
// ============================================================================

pub const WaylandBackend = struct {
    const Self = @This();

    conn: wire.Connection,
    globals: core.Globals = .{},
    registry_id: u32 = 0,

    // Object IDs for xdg shell objects
    surface_id: u32 = 0,
    xdg_surface_id: u32 = 0,
    toplevel_id: u32 = 0,
    decoration_id: u32 = 0,

    // SHM rendering
    shm_buffers: ?core.ShmBuffer = null,

    // Window state
    width: u32,
    height: u32,
    configured: bool = false,

    // Dirty tracking
    dirty_y_min: u32 = std.math.maxInt(u32),
    dirty_y_max: u32 = 0,

    // Internal epoll (wraps wayland socket + key repeat timer + clipboard pipe)
    internal_epoll_fd: posix.fd_t = -1,

    // Event queue (pollEvents returns one event at a time).
    // Large enough for IME bursts + fast typing; small queues silently dropped
    // events and caused lost keys (main ignores key releases, which used to
    // consume half the slots).
    pending_events: [256]Event = undefined,
    pending_count: usize = 0,
    pending_read: usize = 0,
    pending_overflow_warned: bool = false,

    // Focus state
    focused: bool = false,
    was_focused: bool = false,

    // Input
    keyboard: seat_mod.KeyboardState = .{},
    keyboard_id: u32 = 0,
    pointer_id: u32 = 0,
    cursor_shape_device_id: u32 = 0,
    fallback_cursor_surface_id: u32 = 0, // reuse across pointer.enter events
    pointer_serial: u32 = 0,
    pointer_x: u32 = 0, // last known pixel x
    pointer_y: u32 = 0, // last known pixel y
    pointer_button: Event.MouseEvent.Button = .none, // currently held button
    repeat_registered: bool = false,

    // IME
    text_input: text_input_mod.TextInputState = .{},

    // Clipboard
    clipboard: clipboard_mod.ClipboardState = .{},

    // IME cursor position (surface-local pixels)
    ime_cursor_x: i32 = 0,
    ime_cursor_y: i32 = 0,
    ime_cursor_h: i32 = 16,

    // Seat capabilities captured during init (processed in postInit)
    init_seat_caps: u32 = 0,

    pub fn init() !Self {
        // 1. Connect to Wayland compositor
        var conn = try wire.Connection.connect();
        errdefer conn.deinit();

        // 2. Create internal epoll fd
        const epoll_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        const epoll_isize: isize = @bitCast(epoll_rc);
        if (epoll_isize < 0) return error.EpollCreateFailed;
        const internal_epoll_fd: posix.fd_t = @intCast(epoll_isize);
        errdefer posix.close(internal_epoll_fd);

        // 3. Register wayland socket fd in internal epoll
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .u32 = EPOLL_TAG_WAYLAND },
        };
        const ctl_rc = linux.epoll_ctl(internal_epoll_fd, linux.EPOLL.CTL_ADD, conn.fd, &ev);
        const ctl_isize: isize = @bitCast(ctl_rc);
        if (ctl_isize < 0) return error.EpollCtlFailed;

        // 4. Get registry
        const registry_id = try core.getRegistry(&conn);
        try conn.flush();

        // 5. Receive registry globals
        var globals = core.Globals{};
        var sync_callback_id: u32 = 0;

        // Event loop to receive registry globals
        while (true) {
            try waitForSocket(internal_epoll_fd);
            _ = conn.recvEvents() catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            while (conn.nextEvent()) |header| {
                const payload = conn.consumeEvent(header.size);
                if (header.object_id == 1) {
                    // wl_display events
                    if (header.opcode == core.WL_DISPLAY_EVENT_ERROR) {
                        return core.handleDisplayError(payload);
                    }
                    // delete_id — ignore during init
                } else if (header.object_id == registry_id) {
                    if (header.opcode == core.WL_REGISTRY_EVENT_GLOBAL) {
                        core.handleRegistryGlobal(&globals, payload);
                    }
                }
                // Other events are ignored during init
            }

            // After processing a batch, check if we have essential globals
            if (globals.compositor_id != 0 and globals.shm_id != 0 and globals.xdg_wm_base_id != 0) {
                break;
            }
        }

        // 6. Send sync and wait for callback done to drain remaining events
        sync_callback_id = try core.sync(&conn);
        try conn.flush();

        var sync_done = false;
        while (!sync_done) {
            try waitForSocket(internal_epoll_fd);
            _ = conn.recvEvents() catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            while (conn.nextEvent()) |header| {
                const payload = conn.consumeEvent(header.size);
                if (header.object_id == sync_callback_id and header.opcode == core.WL_CALLBACK_EVENT_DONE) {
                    sync_done = true;
                    // Don't release during init — reused IDs can race with compositor's delete_id
                } else if (header.object_id == registry_id) {
                    if (header.opcode == core.WL_REGISTRY_EVENT_GLOBAL) {
                        core.handleRegistryGlobal(&globals, payload);
                    }
                } else if (header.object_id == 1) {
                    if (header.opcode == core.WL_DISPLAY_EVENT_ERROR) {
                        return core.handleDisplayError(payload);
                    }
                    // delete_id — ignore
                }
            }
        }

        // 7. Bind all discovered globals
        try core.bindGlobals(&conn, &globals, registry_id);
        try conn.flush();

        // 7b. Set up clipboard devices (requires data_device_manager + seat bound above)
        var clipboard = clipboard_mod.ClipboardState{};
        if (globals.data_device_manager != 0 and globals.seat != 0) {
            clipboard.data_device_id = clipboard_mod.getDataDevice(&conn, globals.data_device_manager, globals.seat);
        }
        if (globals.primary_selection_manager != 0 and globals.seat != 0) {
            clipboard.primary_device_id = clipboard_mod.getPrimaryDevice(&conn, globals.primary_selection_manager, globals.seat);
        }
        if (clipboard.data_device_id != 0 or clipboard.primary_device_id != 0) {
            try conn.flush();
        }

        // Track input devices acquired during init
        // 8. Receive wl_shm.format events and verify ARGB8888 support
        // Also capture seat capabilities (sent once after bind, must not be missed)
        var seat_caps: u32 = 0;
        sync_callback_id = try core.sync(&conn);
        try conn.flush();

        sync_done = false;
        while (!sync_done) {
            try waitForSocket(internal_epoll_fd);
            _ = conn.recvEvents() catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            while (conn.nextEvent()) |header| {
                const payload = conn.consumeEvent(header.size);
                if (header.object_id == sync_callback_id and header.opcode == core.WL_CALLBACK_EVENT_DONE) {
                    sync_done = true;
                } else if (globals.shm != 0 and header.object_id == globals.shm and header.opcode == core.WL_SHM_EVENT_FORMAT) {
                    var pos: usize = 0;
                    const format = wire.getUint(payload, &pos);
                    if (format == core.SHM_FORMAT_ARGB8888) {
                        globals.argb8888_supported = true;
                    }
                } else if (globals.seat != 0 and header.object_id == globals.seat and header.opcode == seat_mod.WL_SEAT_EVENT_CAPABILITIES) {
                    var pos: usize = 0;
                    seat_caps = wire.getUint(payload, &pos);
                } else if (header.object_id == 1) {
                    if (header.opcode == core.WL_DISPLAY_EVENT_ERROR) {
                        return core.handleDisplayError(payload);
                    }
                }
            }
        }

        if (!globals.argb8888_supported) {
            std.log.err("wayland: compositor does not support ARGB8888 pixel format", .{});
            return error.NoArgb8888;
        }

        // 9. Create wl_surface
        const surface_id = try core.createSurface(&conn, globals.compositor);

        // 10. Create xdg_surface and xdg_toplevel
        const xdg_surface_id = try xdg_shell.getXdgSurface(&conn, globals.xdg_wm_base, surface_id);
        const toplevel_id = try xdg_shell.getToplevel(&conn, xdg_surface_id);

        // 11. Set title, app_id, min_size
        try xdg_shell.setTitle(&conn, toplevel_id, "zt");
        try xdg_shell.setAppId(&conn, toplevel_id, "zt");
        try xdg_shell.setMinSize(&conn, toplevel_id, @intCast(config.cell_width * 10), @intCast(config.cell_height * 3));

        // 12. Request server-side decorations if available
        var decoration_id: u32 = 0;
        if (globals.decoration_manager != 0) {
            decoration_id = try decoration.getToplevelDecoration(&conn, globals.decoration_manager, toplevel_id);
            try decoration.setMode(&conn, decoration_id, decoration.MODE_SERVER_SIDE);
        }

        // 13. Initial commit triggers configure sequence
        try core.surfaceCommit(&conn, surface_id);
        try conn.flush();

        // 14. Wait for xdg_surface.configure + xdg_toplevel.configure
        var conf_width: u32 = 0;
        var conf_height: u32 = 0;
        var got_configure = false;
        var focused = false;

        while (!got_configure) {
            try waitForSocket(internal_epoll_fd);
            _ = conn.recvEvents() catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            while (conn.nextEvent()) |header| {
                const payload = conn.consumeEvent(header.size);
                if (header.object_id == toplevel_id and header.opcode == xdg_shell.XDG_TOPLEVEL_EVENT_CONFIGURE) {
                    const result = xdg_shell.parseToplevelConfigure(payload);
                    if (result.event.width > 0) conf_width = @intCast(result.event.width);
                    if (result.event.height > 0) conf_height = @intCast(result.event.height);
                    if (result.state.activated) focused = true;
                } else if (header.object_id == xdg_surface_id and header.opcode == xdg_shell.XDG_SURFACE_EVENT_CONFIGURE) {
                    // ack the configure
                    var pos: usize = 0;
                    const serial = wire.getUint(payload, &pos);
                    try xdg_shell.ackConfigure(&conn, xdg_surface_id, serial);
                    got_configure = true;
                } else if (globals.xdg_wm_base != 0 and header.object_id == globals.xdg_wm_base and header.opcode == xdg_shell.XDG_WM_BASE_EVENT_PING) {
                    var pos: usize = 0;
                    const serial = wire.getUint(payload, &pos);
                    try xdg_shell.pong(&conn, globals.xdg_wm_base, serial);
                } else if (globals.seat != 0 and header.object_id == globals.seat and header.opcode == seat_mod.WL_SEAT_EVENT_CAPABILITIES) {
                    var pos: usize = 0;
                    seat_caps = wire.getUint(payload, &pos);
                } else if (header.object_id == 1) {
                    if (header.opcode == core.WL_DISPLAY_EVENT_ERROR) {
                        return core.handleDisplayError(payload);
                    }
                }
            }
        }

        // If compositor suggested 0x0, use default 80x24 cells
        if (conf_width == 0 or conf_height == 0) {
            conf_width = 80 * config.cell_width;
            conf_height = 24 * config.cell_height;
        }

        // 15. Create SHM buffers with final dimensions
        var shm_buffers = try core.createShmBuffers(&conn, &globals, conf_width, conf_height);

        // 15b. Fill both SHM buffers with opaque background (ARGB 0xFF000000)
        //      mmap returns zeroed memory → alpha=0 → transparent on Wayland compositors
        {
            const render = @import("../render.zig");
            const default_bg = render.palette[config.default_bg];
            const bg_packed = [4]u8{ default_bg.b, default_bg.g, default_bg.r, 0xFF };
            const total_pixels = @as(usize, conf_width) * @as(usize, conf_height);
            for (0..2) |page| {
                const offset = page * shm_buffers.page_size;
                const page_buf: [*][4]u8 = @ptrCast(shm_buffers.data.ptr + offset);
                @memset(page_buf[0..total_pixels], bg_packed);
            }
        }

        // 16. Set buffer scale
        try core.surfaceSetBufferScale(&conn, surface_id, @intCast(config.scale));

        // 17. First surface commit with attached buffer
        try core.surfaceAttach(&conn, surface_id, shm_buffers.buffer_ids[shm_buffers.current]);
        try core.surfaceDamageBuffer(&conn, surface_id, 0, 0, @intCast(conf_width), @intCast(conf_height));
        try core.surfaceCommit(&conn, surface_id);
        try conn.flush();

        // Mark the submitted buffer as not released (compositor owns it now)
        shm_buffers.released[shm_buffers.current] = false;
        // Swap to the other buffer for rendering
        shm_buffers.current ^= 1;

        return Self{
            .conn = conn,
            .globals = globals,
            .registry_id = registry_id,
            .surface_id = surface_id,
            .xdg_surface_id = xdg_surface_id,
            .toplevel_id = toplevel_id,
            .decoration_id = decoration_id,
            .shm_buffers = shm_buffers,
            .width = conf_width,
            .height = conf_height,
            .configured = true,
            .internal_epoll_fd = internal_epoll_fd,
            .focused = focused,
            .was_focused = focused,
            .clipboard = clipboard,
            .init_seat_caps = seat_caps,
        };
    }

    pub fn deinit(self: *Self) void {
        self.keyboard.deinit();
        if (self.shm_buffers) |*bufs| {
            bufs.deinit();
        }
        if (self.internal_epoll_fd >= 0) {
            posix.close(self.internal_epoll_fd);
        }
        if (self.clipboard.paste_pipe_fd >= 0) {
            posix.close(self.clipboard.paste_pipe_fd);
        }
        self.conn.deinit();
    }

    pub fn postInit(self: *Self) void {
        // Initialize xkbcommon context for keyboard input
        self.keyboard = seat_mod.KeyboardState.init();

        // Use seat capabilities captured during init to bind keyboard/pointer.
        // The capabilities event is sent once after wl_seat.bind and was consumed
        // (but saved) during init's sync loops.
        const caps = self.init_seat_caps;
        if (self.globals.seat == 0 or caps == 0) return;

        if (caps & seat_mod.CAPABILITY_KEYBOARD != 0) {
            self.keyboard_id = seat_mod.getKeyboard(&self.conn, self.globals.seat) catch 0;
        }
        if (caps & seat_mod.CAPABILITY_POINTER != 0) {
            self.pointer_id = seat_mod.getPointer(&self.conn, self.globals.seat) catch 0;
            if (self.pointer_id != 0 and self.globals.cursor_shape_manager != 0) {
                self.cursor_shape_device_id = seat_mod.getCursorShapeDevice(&self.conn, self.globals.cursor_shape_manager, self.pointer_id) catch 0;
            }
        }
        if (self.globals.text_input_manager != 0) {
            self.text_input.id = text_input_mod.getTextInput(&self.conn, self.globals.text_input_manager, self.globals.seat) catch 0;
        }
        self.conn.flush() catch {
            std.log.err("wayland postInit: failed to flush seat bind requests", .{});
            return;
        };

        if (self.keyboard_id == 0) {
            std.log.warn("wayland postInit: no keyboard capability", .{});
            return;
        }

        // Sync round-trip to drain keyboard events (keymap fd, repeat_info, enter, modifiers).
        // Safe to release sync_id here because all prior requests (getKeyboard etc.) have been
        // flushed and processed — the compositor has already freed any earlier IDs by this point.
        // (During init we do NOT release sync IDs because the compositor may not have sent
        // delete_id yet when we immediately reuse them for subsequent object bindings.)
        const sync_id = core.sync(&self.conn) catch return;
        self.conn.flush() catch return;

        var done = false;
        while (!done) {
            waitForSocket(self.internal_epoll_fd) catch {
                std.log.err("wayland postInit: timeout waiting for keyboard events", .{});
                return;
            };
            _ = self.conn.recvEvents() catch |err| switch (err) {
                error.WouldBlock => continue,
                else => {
                    std.log.err("wayland postInit: socket error during sync", .{});
                    return;
                },
            };
            while (self.conn.nextEvent()) |header| {
                const payload = self.conn.consumeEvent(header.size);
                if (header.object_id == sync_id and header.opcode == core.WL_CALLBACK_EVENT_DONE) {
                    done = true;
                    // Do NOT release sync_id here — the compositor will send
                    // wl_display.delete_id later, and dispatchEvent handles it.
                    // Releasing here causes double-free on the ID free list,
                    // leading to two objects sharing the same ID → protocol error.
                } else if (self.globals.xdg_wm_base != 0 and header.object_id == self.globals.xdg_wm_base and header.opcode == xdg_shell.XDG_WM_BASE_EVENT_PING) {
                    var pos: usize = 0;
                    const serial = wire.getUint(payload, &pos);
                    xdg_shell.pong(&self.conn, self.globals.xdg_wm_base, serial) catch {};
                } else if (header.object_id == self.keyboard_id) {
                    self.handlePostInitKeyboardEvent(header.opcode, payload);
                } else if (self.text_input.id != 0 and header.object_id == self.text_input.id) {
                    self.dispatchTextInputEvent(header.opcode, payload);
                } else if (header.object_id == 1) {
                    if (header.opcode == core.WL_DISPLAY_EVENT_ERROR) {
                        core.handleDisplayError(payload) catch {};
                        return;
                    }
                }
            }
            self.conn.flush() catch {};
        }

        if (self.keyboard.xkb_keymap == null) {
            std.log.warn("wayland postInit: no keymap received from compositor", .{});
        }
    }

    /// Handle keyboard events during postInit sync loop.
    /// Subset of dispatchKeyboardEvent — only events expected before main loop.
    fn handlePostInitKeyboardEvent(self: *Self, opcode: u16, payload: []const u8) void {
        switch (opcode) {
            seat_mod.WL_KEYBOARD_EVENT_KEYMAP => {
                var pos: usize = 0;
                _ = wire.getUint(payload, &pos);
                const size = wire.getUint(payload, &pos);
                const fd = self.conn.consumeFd() orelse return;
                self.keyboard.handleKeymap(fd, size);
            },
            seat_mod.WL_KEYBOARD_EVENT_REPEAT_INFO => {
                var pos: usize = 0;
                const rate = wire.getInt(payload, &pos);
                const delay = wire.getInt(payload, &pos);
                self.keyboard.repeat_rate = rate;
                self.keyboard.repeat_delay = delay;
            },
            seat_mod.WL_KEYBOARD_EVENT_ENTER => {
                var pos: usize = 0;
                const serial = wire.getUint(payload, &pos);
                _ = wire.getUint(payload, &pos); // surface
                _ = wire.getArray(payload, &pos); // keys
                self.keyboard.focused = true;
                self.keyboard.last_serial = serial;
                self.focused = true;
                if (self.text_input.id != 0) {
                    text_input_mod.enable(&self.conn, self.text_input.id) catch {};
                    text_input_mod.setContentType(&self.conn, self.text_input.id, 0, 0) catch {};
                    text_input_mod.setCursorRectangle(&self.conn, self.text_input.id, self.ime_cursor_x, self.ime_cursor_y, 1, self.ime_cursor_h) catch {};
                    text_input_mod.commit(&self.conn, self.text_input.id) catch {};
                    self.text_input.enabled = true;
                    self.conn.flush() catch {};
                }
            },
            seat_mod.WL_KEYBOARD_EVENT_MODIFIERS => {
                var pos: usize = 0;
                _ = wire.getUint(payload, &pos); // serial
                const depressed = wire.getUint(payload, &pos);
                const latched = wire.getUint(payload, &pos);
                const locked = wire.getUint(payload, &pos);
                const group = wire.getUint(payload, &pos);
                self.keyboard.handleModifiers(depressed, latched, locked, group);
            },
            else => {},
        }
    }

    // ========================================================================
    // Buffer access
    // ========================================================================

    pub fn getBuffer(self: *Self) []u8 {
        return self.shm_buffers.?.getPixels();
    }

    pub fn getStride(self: *Self) u32 {
        return self.shm_buffers.?.stride;
    }

    pub fn getWidth(self: *Self) u32 {
        return self.width;
    }

    pub fn getHeight(self: *Self) u32 {
        return self.height;
    }

    pub fn getBpp(_: *Self) u32 {
        return 4;
    }

    // ========================================================================
    // Dirty tracking & presentation
    // ========================================================================

    pub fn markDirtyRows(self: *Self, y_start: u32, y_end: u32) void {
        self.dirty_y_min = @min(self.dirty_y_min, y_start);
        self.dirty_y_max = @max(self.dirty_y_max, y_end);
    }

    pub fn present(self: *Self) void {
        if (self.dirty_y_min > self.dirty_y_max) return; // nothing to present

        var bufs = &(self.shm_buffers orelse return);

        const current = bufs.current;

        // Check if the current buffer is released by the compositor
        if (!bufs.released[current]) return; // skip frame — compositor still owns it

        const y_start = self.dirty_y_min;
        const y_end = @min(self.dirty_y_max + 1, self.height);
        const stride = bufs.stride;

        // Copy dirty region from current buffer to the other buffer BEFORE submitting
        // The other buffer will become our new rendering target after swap
        const other: u1 = current ^ 1;
        const byte_start = @as(usize, y_start) * @as(usize, stride);
        const byte_end = @as(usize, y_end) * @as(usize, stride);
        const current_pixels = bufs.getPixels();
        const other_offset = @as(usize, other) * bufs.page_size;
        const other_pixels = bufs.data[other_offset .. other_offset + bufs.page_size];
        @memcpy(other_pixels[byte_start..byte_end], current_pixels[byte_start..byte_end]);

        // Attach and commit the current buffer
        core.surfaceAttach(&self.conn, self.surface_id, bufs.buffer_ids[current]) catch return;
        core.surfaceDamageBuffer(
            &self.conn,
            self.surface_id,
            0,
            @intCast(y_start),
            @intCast(self.width),
            @intCast(y_end - y_start),
        ) catch return;
        core.surfaceCommit(&self.conn, self.surface_id) catch return;

        // Mark current buffer as not released (compositor owns it)
        bufs.released[current] = false;
        // Swap to the other buffer (which now has the copied content)
        bufs.current = other;

        // Reset dirty tracking
        self.dirty_y_min = std.math.maxInt(u32);
        self.dirty_y_max = 0;
    }

    pub fn flush(self: *Self) void {
        self.conn.flush() catch {};
    }

    /// Update IME cursor position (surface-local pixels).
    /// Sends set_cursor_rectangle + commit so the compositor repositions
    /// the candidate window near the text cursor.
    pub fn updateImeCursorPos(self: *Self, x: u32, y: u32) void {
        const new_x: i32 = @intCast(x);
        const new_y: i32 = @intCast(y);
        if (new_x == self.ime_cursor_x and new_y == self.ime_cursor_y) return;
        self.ime_cursor_x = new_x;
        self.ime_cursor_y = new_y;
        if (self.text_input.id != 0 and self.text_input.enabled) {
            text_input_mod.setCursorRectangle(&self.conn, self.text_input.id, new_x, new_y, 1, self.ime_cursor_h) catch {};
            text_input_mod.commit(&self.conn, self.text_input.id) catch {};
        }
    }

    /// Update the Wayland window title via xdg_toplevel.set_title.
    pub fn updateTitle(self: *Self, title: []const u8) void {
        // Clamp to 251 bytes — putString uses 4 (len) + N + 1 (NUL) + padding in 256-byte payload
        const clamped = title[0..@min(title.len, 251)];
        xdg_shell.setTitle(&self.conn, self.toplevel_id, clamped) catch {};
    }

    // ========================================================================
    // Resize
    // ========================================================================

    pub fn resize(self: *Self, w: u32, h: u32) !void {
        if (w == self.width and h == self.height) return;
        if (w == 0 or h == 0) return;

        if (self.shm_buffers) |*bufs| {
            // Reuse existing pool — avoids pool ID churn and fd-based
            // sendMessage that forces mid-resize flush
            try bufs.resizeBuffers(&self.conn, w, h);
        } else {
            self.shm_buffers = try core.createShmBuffers(&self.conn, &self.globals, w, h);
        }
        self.width = w;
        self.height = h;
    }

    // ========================================================================
    // Geometry query
    // ========================================================================

    pub fn queryGeometry(self: *Self) struct { w: u32, h: u32 } {
        return .{ .w = self.width, .h = self.height };
    }

    // ========================================================================
    // FD for external epoll
    // ========================================================================

    pub fn getFd(self: *Self) ?posix.fd_t {
        return self.internal_epoll_fd;
    }

    // ========================================================================
    // Event dispatch
    // ========================================================================

    fn queueEvent(self: *Self, event: Event) void {
        if (self.pending_count >= self.pending_events.len) {
            if (!self.pending_overflow_warned) {
                std.log.warn("Wayland event queue full; dropping event", .{});
                self.pending_overflow_warned = true;
            }
            return;
        }
        self.pending_events[self.pending_count] = event;
        self.pending_count += 1;
    }

    fn dequeueEvent(self: *Self) ?Event {
        if (self.pending_read < self.pending_count) {
            const event = self.pending_events[self.pending_read];
            self.pending_read += 1;
            // Reset when fully consumed
            if (self.pending_read >= self.pending_count) {
                self.pending_read = 0;
                self.pending_count = 0;
                self.pending_overflow_warned = false;
            }
            return event;
        }
        return null;
    }

    /// Register the repeat timer fd in the internal epoll (idempotent).
    fn ensureRepeatTimerRegistered(self: *Self) void {
        if (self.repeat_registered) return;
        if (self.keyboard.repeat_timer_fd < 0) return;
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .u32 = EPOLL_TAG_REPEAT },
        };
        _ = linux.epoll_ctl(self.internal_epoll_fd, linux.EPOLL.CTL_ADD, self.keyboard.repeat_timer_fd, &ev);
        self.repeat_registered = true;
    }

    /// Check if an evdev keycode is a special key handled via escape sequences.
    fn isSpecialKey(evdev_keycode: u16) bool {
        const K = input_mod.KEY;
        return switch (evdev_keycode) {
            K.ESC,
            K.ENTER,
            K.BACKSPACE,
            K.TAB,
            K.UP,
            K.DOWN,
            K.LEFT,
            K.RIGHT,
            K.HOME,
            K.END,
            K.INSERT,
            K.DELETE,
            K.PAGEUP,
            K.PAGEDOWN,
            K.F1,
            K.F2,
            K.F3,
            K.F4,
            K.F5,
            K.F6,
            K.F7,
            K.F8,
            K.F9,
            K.F10,
            K.F11,
            K.F12,
            => true,
            else => false,
        };
    }

    /// Dispatch a single Wayland event by object ID and opcode.
    fn dispatchEvent(self: *Self, header: wire.Header, payload: []const u8) void {
        if (header.object_id == 1) {
            // wl_display events
            if (header.opcode == core.WL_DISPLAY_EVENT_ERROR) {
                // handleDisplayError logs and always returns error; we queue close
                core.handleDisplayError(payload) catch {};
                self.queueEvent(.close);
            } else if (header.opcode == core.WL_DISPLAY_EVENT_DELETE_ID) {
                // Release the deleted object ID for reuse
                var pos: usize = 0;
                const deleted_id = wire.getUint(payload, &pos);
                self.conn.id_alloc.release(deleted_id);
            }
        } else if (header.object_id == self.registry_id) {
            if (header.opcode == core.WL_REGISTRY_EVENT_GLOBAL) {
                core.handleRegistryGlobal(&self.globals, payload);
            }
        } else if (header.object_id == self.globals.xdg_wm_base) {
            if (header.opcode == xdg_shell.XDG_WM_BASE_EVENT_PING) {
                var pos: usize = 0;
                const serial = wire.getUint(payload, &pos);
                xdg_shell.pong(&self.conn, self.globals.xdg_wm_base, serial) catch {};
                self.conn.flush() catch {};
            }
        } else if (header.object_id == self.xdg_surface_id) {
            if (header.opcode == xdg_shell.XDG_SURFACE_EVENT_CONFIGURE) {
                var pos: usize = 0;
                const serial = wire.getUint(payload, &pos);
                xdg_shell.ackConfigure(&self.conn, self.xdg_surface_id, serial) catch {};
            }
        } else if (header.object_id == self.toplevel_id) {
            if (header.opcode == xdg_shell.XDG_TOPLEVEL_EVENT_CONFIGURE) {
                const result = xdg_shell.parseToplevelConfigure(payload);
                const new_focused = result.state.activated;

                // Queue resize if dimensions changed and are non-zero.
                // Coalesce: replace any existing pending resize event rather than
                // accumulating multiple resizes. Rapid configure events (e.g. window
                // dragged to screen edge) would otherwise cause repeated destroy/create
                // buffer cycles, increasing the chance of protocol errors.
                if (result.event.width > 0 and result.event.height > 0) {
                    const new_w: u32 = @intCast(result.event.width);
                    const new_h: u32 = @intCast(result.event.height);
                    if (new_w != self.width or new_h != self.height) {
                        var replaced = false;
                        var i: usize = self.pending_read;
                        while (i < self.pending_count) : (i += 1) {
                            switch (self.pending_events[i]) {
                                .resize => {
                                    self.pending_events[i] = .{ .resize = .{ .width = new_w, .height = new_h } };
                                    replaced = true;
                                    break;
                                },
                                else => {},
                            }
                        }
                        if (!replaced) {
                            self.queueEvent(.{ .resize = .{ .width = new_w, .height = new_h } });
                        }
                    }
                }

                // Track focus changes
                self.focused = new_focused;
            } else if (header.opcode == xdg_shell.XDG_TOPLEVEL_EVENT_CLOSE) {
                self.queueEvent(.close);
            }
        } else if (self.globals.seat != 0 and header.object_id == self.globals.seat) {
            // wl_seat events
            if (header.opcode == seat_mod.WL_SEAT_EVENT_CAPABILITIES) {
                var pos: usize = 0;
                const caps = wire.getUint(payload, &pos);

                // Get keyboard if available and not yet acquired
                if (caps & seat_mod.CAPABILITY_KEYBOARD != 0 and self.keyboard_id == 0) {
                    self.keyboard_id = seat_mod.getKeyboard(&self.conn, self.globals.seat) catch 0;
                }

                // Get pointer if available and not yet acquired
                if (caps & seat_mod.CAPABILITY_POINTER != 0 and self.pointer_id == 0) {
                    self.pointer_id = seat_mod.getPointer(&self.conn, self.globals.seat) catch 0;

                    // Get cursor shape device if manager is available
                    if (self.pointer_id != 0 and self.globals.cursor_shape_manager != 0 and self.cursor_shape_device_id == 0) {
                        self.cursor_shape_device_id = seat_mod.getCursorShapeDevice(
                            &self.conn,
                            self.globals.cursor_shape_manager,
                            self.pointer_id,
                        ) catch 0;
                    }
                }

                // Get text input if manager is available
                if (self.globals.text_input_manager != 0 and self.text_input.id == 0) {
                    self.text_input.id = text_input_mod.getTextInput(
                        &self.conn,
                        self.globals.text_input_manager,
                        self.globals.seat,
                    ) catch 0;
                }

                self.conn.flush() catch {};
            }
            // WL_SEAT_EVENT_NAME (opcode 1) -- ignore
        } else if (self.keyboard_id != 0 and header.object_id == self.keyboard_id) {
            // wl_keyboard events
            self.dispatchKeyboardEvent(header.opcode, payload);
        } else if (self.pointer_id != 0 and header.object_id == self.pointer_id) {
            // wl_pointer events
            self.dispatchPointerEvent(header.opcode, payload);
        } else if (self.text_input.id != 0 and header.object_id == self.text_input.id) {
            // zwp_text_input_v3 events
            self.dispatchTextInputEvent(header.opcode, payload);
        } else if (self.clipboard.data_device_id != 0 and header.object_id == self.clipboard.data_device_id) {
            // wl_data_device events
            self.dispatchDataDeviceEvent(header.opcode, payload);
        } else if (self.clipboard.current_offer_id != 0 and header.object_id == self.clipboard.current_offer_id) {
            // wl_data_offer events (clipboard)
            if (header.opcode == clipboard_mod.WL_DATA_OFFER_EVENT_OFFER) {
                var pos: usize = 0;
                const mime = wire.getString(payload, &pos);
                if (std.mem.eql(u8, mime, "text/plain;charset=utf-8") or
                    std.mem.eql(u8, mime, "text/plain"))
                {
                    self.clipboard.offer_has_text = true;
                }
            }
        } else if (self.clipboard.primary_device_id != 0 and header.object_id == self.clipboard.primary_device_id) {
            // zwp_primary_selection_device_v1 events
            self.dispatchPrimaryDeviceEvent(header.opcode, payload);
        } else if (self.clipboard.primary_offer_id != 0 and header.object_id == self.clipboard.primary_offer_id) {
            // zwp_primary_selection_offer_v1 events
            if (header.opcode == clipboard_mod.ZWP_PRIMARY_SELECTION_OFFER_EVENT_OFFER) {
                var pos: usize = 0;
                const mime = wire.getString(payload, &pos);
                if (std.mem.eql(u8, mime, "text/plain;charset=utf-8") or
                    std.mem.eql(u8, mime, "text/plain"))
                {
                    self.clipboard.primary_has_text = true;
                }
            }
        } else if (self.shm_buffers != null) {
            // Check for wl_buffer.release events
            const bufs = &(self.shm_buffers.?);
            if (header.object_id == bufs.buffer_ids[0] and header.opcode == core.WL_BUFFER_EVENT_RELEASE) {
                bufs.released[0] = true;
            } else if (header.object_id == bufs.buffer_ids[1] and header.opcode == core.WL_BUFFER_EVENT_RELEASE) {
                bufs.released[1] = true;
            }
        }
    }

    /// Handle wl_keyboard events.
    fn dispatchKeyboardEvent(self: *Self, opcode: u16, payload: []const u8) void {
        switch (opcode) {
            seat_mod.WL_KEYBOARD_EVENT_KEYMAP => {
                // Payload: format(u32) + size(u32), fd via SCM_RIGHTS
                var pos: usize = 0;
                _ = wire.getUint(payload, &pos); // format (XKB_V1 = 1)
                const size = wire.getUint(payload, &pos);
                const fd = self.conn.consumeFd() orelse return;
                self.keyboard.handleKeymap(fd, size);
            },
            seat_mod.WL_KEYBOARD_EVENT_ENTER => {
                // Payload: serial(u32) + surface(u32) + keys(array)
                var pos: usize = 0;
                const serial = wire.getUint(payload, &pos);
                _ = wire.getUint(payload, &pos); // surface
                _ = wire.getArray(payload, &pos); // currently pressed keys -- consume

                self.keyboard.focused = true;
                self.keyboard.last_serial = serial;
                self.focused = true;

                // Enable text input
                if (self.text_input.id != 0) {
                    text_input_mod.enable(&self.conn, self.text_input.id) catch {};
                    text_input_mod.setContentType(&self.conn, self.text_input.id, 0, 0) catch {};
                    text_input_mod.setCursorRectangle(&self.conn, self.text_input.id, self.ime_cursor_x, self.ime_cursor_y, 1, self.ime_cursor_h) catch {};
                    text_input_mod.commit(&self.conn, self.text_input.id) catch {};
                    self.text_input.enabled = true;
                    self.conn.flush() catch {};
                }
            },
            seat_mod.WL_KEYBOARD_EVENT_LEAVE => {
                // Payload: serial(u32) + surface(u32)
                self.keyboard.focused = false;
                self.keyboard.stopRepeat();
                self.focused = false;

                // Disable text input
                if (self.text_input.id != 0 and self.text_input.enabled) {
                    text_input_mod.disable(&self.conn, self.text_input.id) catch {};
                    text_input_mod.commit(&self.conn, self.text_input.id) catch {};
                    self.text_input.enabled = false;
                    self.conn.flush() catch {};
                }

                self.queueEvent(.focus_out);
            },
            seat_mod.WL_KEYBOARD_EVENT_KEY => {
                // Payload: serial(u32) + time(u32) + key(u32) + state(u32)
                var pos: usize = 0;
                const serial = wire.getUint(payload, &pos);
                _ = wire.getUint(payload, &pos); // time
                const key = wire.getUint(payload, &pos);
                const state = wire.getUint(payload, &pos); // 1 = pressed, 0 = released

                self.keyboard.last_serial = serial;
                const evdev_keycode: u16 = @intCast(key & 0xFFFF);
                const mods = self.keyboard.getModifiers();
                const pressed = (state == 1);

                if (pressed) {
                    // Handle key repeat
                    self.keyboard.startRepeat(key);
                    self.ensureRepeatTimerRegistered();

                    // Shift+Insert -> primary selection paste
                    if (evdev_keycode == input_mod.KEY.INSERT and mods.shift) {
                        if (self.clipboard.primary_offer_id != 0 and self.clipboard.primary_has_text) {
                            clipboard_mod.requestPaste(&self.conn, self.clipboard.primary_offer_id, &self.clipboard, clipboard_mod.ZWP_PRIMARY_SELECTION_OFFER_RECEIVE, self.internal_epoll_fd) catch {};
                            if (self.clipboard.paste_pipe_fd >= 0) {
                                var epev = linux.epoll_event{
                                    .events = linux.EPOLL.IN | linux.EPOLL.HUP,
                                    .data = .{ .u32 = EPOLL_TAG_CLIPBOARD },
                                };
                                _ = linux.epoll_ctl(self.internal_epoll_fd, linux.EPOLL.CTL_ADD, self.clipboard.paste_pipe_fd, &epev);
                            }
                        }
                        return;
                    }

                    // Ctrl+Shift+V -> clipboard paste
                    if (evdev_keycode == input_mod.KEY.V and mods.ctrl and mods.shift) {
                        if (self.clipboard.current_offer_id != 0 and self.clipboard.offer_has_text) {
                            clipboard_mod.requestPaste(&self.conn, self.clipboard.current_offer_id, &self.clipboard, clipboard_mod.WL_DATA_OFFER_RECEIVE, self.internal_epoll_fd) catch {};
                            if (self.clipboard.paste_pipe_fd >= 0) {
                                var epev = linux.epoll_event{
                                    .events = linux.EPOLL.IN | linux.EPOLL.HUP,
                                    .data = .{ .u32 = EPOLL_TAG_CLIPBOARD },
                                };
                                _ = linux.epoll_ctl(self.internal_epoll_fd, linux.EPOLL.CTL_ADD, self.clipboard.paste_pipe_fd, &epev);
                            }
                        }
                        return;
                    }

                    // Special keys -> KeyEvent
                    if (isSpecialKey(evdev_keycode)) {
                        self.queueEvent(.{ .key = .{
                            .keycode = evdev_keycode,
                            .pressed = true,
                            .modifiers = mods,
                        } });
                        return;
                    }

                    // Ctrl+letter -> KeyEvent (for control sequences)
                    if (mods.ctrl) {
                        self.queueEvent(.{ .key = .{
                            .keycode = evdev_keycode,
                            .pressed = true,
                            .modifiers = mods,
                        } });
                        return;
                    }

                    // Use xkbcommon for layout-aware text translation.
                    // Skip if IME is active — text_input.commit_string handles it.
                    var utf8_buf: [32]u8 = undefined;
                    const utf8_len = if (self.text_input.enabled) @as(usize, 0) else self.keyboard.getUtf8(key, &utf8_buf);
                    if (utf8_len > 0) {
                        var text_ev: TextEvent = .{};
                        if (mods.alt) {
                            // Alt+key -> prefix with ESC
                            text_ev.data[0] = 0x1b;
                            const clamped: u32 = @intCast(@min(utf8_len, 127));
                            @memcpy(text_ev.data[1 .. 1 + clamped], utf8_buf[0..clamped]);
                            text_ev.len = clamped + 1;
                        } else {
                            const clamped: u32 = @intCast(@min(utf8_len, 128));
                            @memcpy(text_ev.data[0..clamped], utf8_buf[0..clamped]);
                            text_ev.len = clamped;
                        }
                        self.queueEvent(.{ .text = text_ev });
                        return;
                    }

                    // Fallback: KeyEvent
                    self.queueEvent(.{ .key = .{
                        .keycode = evdev_keycode,
                        .pressed = true,
                        .modifiers = mods,
                    } });
                } else {
                    // Key released — update repeat state only. Do not queue a KeyEvent:
                    // main.zig only handles pressed==true for PTY output, so releases
                    // wasted queue slots and could overflow the small pending buffer,
                    // dropping real keypress/text events.
                    if (self.keyboard.repeat_key) |rk| {
                        if (rk == key) {
                            self.keyboard.stopRepeat();
                        }
                    }
                }
            },
            seat_mod.WL_KEYBOARD_EVENT_MODIFIERS => {
                // Payload: serial(u32) + depressed(u32) + latched(u32) + locked(u32) + group(u32)
                var pos: usize = 0;
                _ = wire.getUint(payload, &pos); // serial
                const depressed = wire.getUint(payload, &pos);
                const latched = wire.getUint(payload, &pos);
                const locked = wire.getUint(payload, &pos);
                const group = wire.getUint(payload, &pos);
                self.keyboard.handleModifiers(depressed, latched, locked, group);
            },
            seat_mod.WL_KEYBOARD_EVENT_REPEAT_INFO => {
                // Payload: rate(i32) + delay(i32)
                var pos: usize = 0;
                const rate = wire.getInt(payload, &pos);
                const delay = wire.getInt(payload, &pos);
                self.keyboard.repeat_rate = rate;
                self.keyboard.repeat_delay = delay;
            },
            else => {},
        }
    }

    /// Handle wl_pointer events.
    fn dispatchPointerEvent(self: *Self, opcode: u16, payload: []const u8) void {
        switch (opcode) {
            seat_mod.WL_POINTER_EVENT_ENTER => {
                // Payload: serial(u32) + surface(u32) + x(fixed) + y(fixed)
                var pos: usize = 0;
                const serial = wire.getUint(payload, &pos);
                self.pointer_serial = serial;
                _ = wire.getUint(payload, &pos); // surface
                const x_fixed_e: i32 = @bitCast(wire.getUint(payload, &pos));
                const y_fixed_e: i32 = @bitCast(wire.getUint(payload, &pos));
                self.pointer_x = @intCast(@max(0, x_fixed_e >> 8));
                self.pointer_y = @intCast(@max(0, y_fixed_e >> 8));

                // Set cursor shape
                if (self.cursor_shape_device_id != 0) {
                    seat_mod.setCursorShape(&self.conn, self.cursor_shape_device_id, serial, seat_mod.CURSOR_TEXT) catch {};
                } else if (self.fallback_cursor_surface_id != 0) {
                    // Reuse existing fallback cursor surface
                    seat_mod.setPointerCursor(&self.conn, self.pointer_id, serial, self.fallback_cursor_surface_id) catch {};
                } else {
                    self.fallback_cursor_surface_id = seat_mod.setFallbackCursor(&self.conn, self.pointer_id, serial, self.globals.compositor, self.globals.shm) catch 0;
                }
                self.conn.flush() catch {};
            },
            seat_mod.WL_POINTER_EVENT_LEAVE => {
                self.pointer_button = .none;
            },
            seat_mod.WL_POINTER_EVENT_MOTION => {
                // Payload: time(u32) + x(fixed) + y(fixed)
                var pos: usize = 0;
                _ = wire.getUint(payload, &pos); // time
                const x_fixed: i32 = @bitCast(wire.getUint(payload, &pos));
                const y_fixed: i32 = @bitCast(wire.getUint(payload, &pos));
                // wl_fixed_t: signed 24.8 format — clamp negative to 0
                self.pointer_x = @intCast(@max(0, x_fixed >> 8));
                self.pointer_y = @intCast(@max(0, y_fixed >> 8));

                self.queueEvent(.{ .mouse = .{
                    .x = self.pointer_x,
                    .y = self.pointer_y,
                    .button = self.pointer_button,
                    .action = .motion,
                    .modifiers = .{},
                } });
            },
            seat_mod.WL_POINTER_EVENT_BUTTON => {
                // Payload: serial(u32) + time(u32) + button(u32) + state(u32)
                var pos: usize = 0;
                const serial = wire.getUint(payload, &pos);
                self.pointer_serial = serial;
                _ = wire.getUint(payload, &pos); // time
                const linux_button = wire.getUint(payload, &pos);
                const state = wire.getUint(payload, &pos);

                const button: Event.MouseEvent.Button = switch (linux_button) {
                    0x110 => .left, // BTN_LEFT
                    0x111 => .right, // BTN_RIGHT
                    0x112 => .middle, // BTN_MIDDLE
                    else => return,
                };
                const action: Event.MouseEvent.Action = if (state != 0) .press else .release;

                // Track button state for motion events
                if (action == .press) {
                    self.pointer_button = button;
                } else {
                    self.pointer_button = .none;
                }

                self.queueEvent(.{ .mouse = .{
                    .x = self.pointer_x,
                    .y = self.pointer_y,
                    .button = button,
                    .action = action,
                    .modifiers = .{}, // Will get modifiers from keyboard state if available
                } });
            },
            seat_mod.WL_POINTER_EVENT_AXIS => {
                // Payload: time(u32) + axis(u32) + value(fixed)
                var pos: usize = 0;
                _ = wire.getUint(payload, &pos); // time
                const axis = wire.getUint(payload, &pos);
                const value_fixed: i32 = @bitCast(wire.getUint(payload, &pos));
                // axis 0 = vertical, 1 = horizontal
                // value > 0 = down/right, < 0 = up/left
                const button: Event.MouseEvent.Button = if (axis == 0)
                    (if (value_fixed > 0) .wheel_down else .wheel_up)
                else
                    (if (value_fixed > 0) .wheel_right else .wheel_left);
                self.queueEvent(.{ .mouse = .{
                    .x = self.pointer_x,
                    .y = self.pointer_y,
                    .button = button,
                    .action = .press,
                    .modifiers = .{},
                } });
            },
            else => {},
        }
    }

    /// Handle wl_data_device events.
    fn dispatchDataDeviceEvent(self: *Self, opcode: u16, payload: []const u8) void {
        switch (opcode) {
            clipboard_mod.WL_DATA_DEVICE_EVENT_DATA_OFFER => {
                // Compositor announcing a new data offer object.
                // Payload: new_id(u32)
                var pos: usize = 0;
                const new_id = wire.getUint(payload, &pos);
                // Destroy previous offer to avoid compositor-side accumulation
                clipboard_mod.destroyOffer(&self.conn, self.clipboard.current_offer_id, false);
                self.clipboard.current_offer_id = new_id;
                self.clipboard.offer_has_text = false;
            },
            clipboard_mod.WL_DATA_DEVICE_EVENT_SELECTION => {
                // The current offer is now the active clipboard selection.
                // Payload: offer_id(u32) — may be 0 meaning no selection.
                var pos: usize = 0;
                const offer_id = wire.getUint(payload, &pos);
                if (offer_id == 0) {
                    // Selection cleared — destroy the old offer
                    clipboard_mod.destroyOffer(&self.conn, self.clipboard.current_offer_id, false);
                    self.clipboard.current_offer_id = 0;
                    self.clipboard.offer_has_text = false;
                }
                // If non-zero: current_offer_id was already set by DATA_OFFER event
            },
            else => {},
        }
    }

    /// Handle zwp_primary_selection_device_v1 events.
    fn dispatchPrimaryDeviceEvent(self: *Self, opcode: u16, payload: []const u8) void {
        switch (opcode) {
            clipboard_mod.ZWP_PRIMARY_SELECTION_DEVICE_EVENT_DATA_OFFER => {
                // Payload: new_id(u32)
                var pos: usize = 0;
                const new_id = wire.getUint(payload, &pos);
                // Destroy previous offer to avoid compositor-side accumulation
                clipboard_mod.destroyOffer(&self.conn, self.clipboard.primary_offer_id, true);
                self.clipboard.primary_offer_id = new_id;
                self.clipboard.primary_has_text = false;
            },
            clipboard_mod.ZWP_PRIMARY_SELECTION_DEVICE_EVENT_SELECTION => {
                // Payload: offer_id(u32) — may be 0 meaning no selection.
                var pos: usize = 0;
                const offer_id = wire.getUint(payload, &pos);
                if (offer_id == 0) {
                    // Selection cleared — destroy the old offer
                    clipboard_mod.destroyOffer(&self.conn, self.clipboard.primary_offer_id, true);
                    self.clipboard.primary_offer_id = 0;
                    self.clipboard.primary_has_text = false;
                }
            },
            else => {},
        }
    }

    /// Handle zwp_text_input_v3 events.
    fn dispatchTextInputEvent(self: *Self, opcode: u16, payload: []const u8) void {
        switch (opcode) {
            // enter/leave are informational — we enable/disable text input based
            // on wl_keyboard focus instead, so these are intentionally no-ops.
            text_input_mod.ZWP_TEXT_INPUT_EVENT_ENTER => {},
            text_input_mod.ZWP_TEXT_INPUT_EVENT_LEAVE => {},
            text_input_mod.ZWP_TEXT_INPUT_EVENT_PREEDIT_STRING => {
                text_input_mod.handlePreeditString(&self.text_input, payload);
            },
            text_input_mod.ZWP_TEXT_INPUT_EVENT_COMMIT_STRING => {
                text_input_mod.handleCommitString(&self.text_input, payload);
            },
            text_input_mod.ZWP_TEXT_INPUT_EVENT_DONE => {
                text_input_mod.handleDone(&self.text_input);

                // If there is a committed string, queue a text event
                if (self.text_input.has_pending_commit and self.text_input.pending_commit_len > 0) {
                    var text_ev: TextEvent = .{};
                    const len: u32 = @intCast(@min(self.text_input.pending_commit_len, text_ev.data.len));
                    @memcpy(text_ev.data[0..len], self.text_input.pending_commit[0..len]);
                    text_ev.len = len;
                    self.queueEvent(.{ .text = text_ev });

                    self.text_input.has_pending_commit = false;
                    self.text_input.pending_commit_len = 0;
                }
            },
            else => {},
        }
    }

    pub fn pollEvents(self: *Self) ?Event {
        // 1. Return pending events first
        if (self.dequeueEvent()) |event| {
            return event;
        }

        // 2. Check focus state changes
        if (self.focused != self.was_focused) {
            self.was_focused = self.focused;
            if (self.focused) {
                self.queueEvent(.focus_in);
            } else {
                self.queueEvent(.focus_out);
            }
            return self.dequeueEvent();
        }

        // 3. epoll_wait on internal epoll (non-blocking)
        var events: [8]linux.epoll_event = undefined;
        const n_rc = linux.epoll_wait(self.internal_epoll_fd, &events, events.len, 0);
        const n_isize: isize = @bitCast(n_rc);
        if (n_isize <= 0) return null;
        const n_events: usize = @intCast(n_isize);

        // Pass 1: Process Wayland socket first so key releases clear repeat_key
        // before the repeat timer is checked in pass 2.
        for (events[0..n_events]) |epoll_ev| {
            const tag = epoll_ev.data.u32;
            if (tag == EPOLL_TAG_WAYLAND) {
                // Read from wayland socket
                _ = self.conn.recvEvents() catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => {
                        self.queueEvent(.close);
                        continue;
                    },
                };

                // Process all complete messages
                while (self.conn.nextEvent()) |header| {
                    const payload = self.conn.consumeEvent(header.size);
                    self.dispatchEvent(header, payload);
                }

                // Flush immediately so pong/ack_configure reach the compositor
                // without waiting for the next render cycle
                self.conn.flush() catch {};
            }
        }

        // Pass 2: Process timers and clipboard after Wayland events
        for (events[0..n_events]) |epoll_ev| {
            const tag = epoll_ev.data.u32;
            if (tag == EPOLL_TAG_REPEAT) {
                // Key repeat timer fired -- read to acknowledge
                var timer_buf: [8]u8 = undefined;
                _ = posix.read(self.keyboard.repeat_timer_fd, &timer_buf) catch {};

                if (self.keyboard.repeat_key) |rk| {
                    const evdev_keycode: u16 = @intCast(rk & 0xFFFF);
                    const mods = self.keyboard.getModifiers();

                    // Special keys -> KeyEvent
                    if (isSpecialKey(evdev_keycode)) {
                        self.queueEvent(.{ .key = .{
                            .keycode = evdev_keycode,
                            .pressed = true,
                            .modifiers = mods,
                        } });
                    } else if (mods.ctrl) {
                        // Ctrl+letter -> KeyEvent
                        self.queueEvent(.{ .key = .{
                            .keycode = evdev_keycode,
                            .pressed = true,
                            .modifiers = mods,
                        } });
                    } else {
                        // Text repeat via xkbcommon (skip if IME active)
                        var utf8_buf: [32]u8 = undefined;
                        const utf8_len = if (self.text_input.enabled) @as(usize, 0) else self.keyboard.getUtf8(rk, &utf8_buf);
                        if (utf8_len > 0) {
                            var text_ev: TextEvent = .{};
                            if (mods.alt) {
                                text_ev.data[0] = 0x1b;
                                const clamped: u32 = @intCast(@min(utf8_len, 127));
                                @memcpy(text_ev.data[1 .. 1 + clamped], utf8_buf[0..clamped]);
                                text_ev.len = clamped + 1;
                            } else {
                                const clamped: u32 = @intCast(@min(utf8_len, 128));
                                @memcpy(text_ev.data[0..clamped], utf8_buf[0..clamped]);
                                text_ev.len = clamped;
                            }
                            self.queueEvent(.{ .text = text_ev });
                        } else {
                            self.queueEvent(.{ .key = .{
                                .keycode = evdev_keycode,
                                .pressed = true,
                                .modifiers = mods,
                            } });
                        }
                    }
                }
            }
            if (tag == EPOLL_TAG_CLIPBOARD) {
                // Read data from paste pipe (non-blocking)
                const more = clipboard_mod.readPastePipe(&self.clipboard);
                if (!more) {
                    // EOF or error: remove from epoll and queue paste event
                    if (self.clipboard.paste_pipe_fd >= 0) {
                        _ = linux.epoll_ctl(self.internal_epoll_fd, linux.EPOLL.CTL_DEL, self.clipboard.paste_pipe_fd, null);
                        posix.close(self.clipboard.paste_pipe_fd);
                        self.clipboard.paste_pipe_fd = -1;
                    }
                    if (self.clipboard.paste_len > 0) {
                        const len: u32 = @intCast(@min(self.clipboard.paste_len, self.clipboard.paste_buf.len));
                        self.queueEvent(.{ .paste = .{ .ptr = &self.clipboard.paste_buf, .len = len } });
                        self.clipboard.paste_len = 0;
                    }
                }
            }
        }

        // Return next pending event
        return self.dequeueEvent();
    }

    // ========================================================================
    // VT switching stubs (not applicable to Wayland)
    // ========================================================================

    pub fn saveConsoleState(self: *Self) !void {
        _ = self;
    }

    pub fn restoreConsoleState(self: *Self) void {
        _ = self;
    }

    pub fn setupVtSwitching(self: *Self) !void {
        _ = self;
    }

    pub fn releaseVt(self: *Self) void {
        _ = self;
    }

    pub fn acquireVt(self: *Self) void {
        _ = self;
    }
};
