const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const config = @import("config");
const input_mod = @import("../input.zig");

const wire = @import("wayland/wire.zig");
const core = @import("wayland/core.zig");
const xdg_shell = @import("wayland/xdg_shell.zig");
const decoration = @import("wayland/decoration.zig");

// ============================================================================
// Event types — mirrors x11.zig's Event union
// ============================================================================

pub const Event = union(enum) {
    key: KeyEvent,
    text: TextEvent,
    paste: PasteEvent,
    resize: ResizeEvent,
    expose: void,
    close: void,
    focus_in: void,
    focus_out: void,
};

pub const PasteEvent = struct {
    data: [4096]u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const PasteEvent) []const u8 {
        return self.data[0..self.len];
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

    // Event queue (pollEvents returns one event at a time)
    pending_events: [16]Event = undefined,
    pending_count: usize = 0,
    pending_read: usize = 0,

    // Focus state
    focused: bool = false,
    was_focused: bool = false,

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
            _ = try conn.recvEvents();
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
            _ = try conn.recvEvents();
            while (conn.nextEvent()) |header| {
                const payload = conn.consumeEvent(header.size);
                if (header.object_id == sync_callback_id and header.opcode == core.WL_CALLBACK_EVENT_DONE) {
                    sync_done = true;
                    conn.id_alloc.release(sync_callback_id);
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

        // 8. Receive wl_shm.format events and verify ARGB8888 support
        sync_callback_id = try core.sync(&conn);
        try conn.flush();

        sync_done = false;
        while (!sync_done) {
            _ = try conn.recvEvents();
            while (conn.nextEvent()) |header| {
                const payload = conn.consumeEvent(header.size);
                if (header.object_id == sync_callback_id and header.opcode == core.WL_CALLBACK_EVENT_DONE) {
                    sync_done = true;
                    conn.id_alloc.release(sync_callback_id);
                } else if (header.object_id == globals.shm and header.opcode == core.WL_SHM_EVENT_FORMAT) {
                    var pos: usize = 0;
                    const format = wire.getUint(payload, &pos);
                    if (format == core.SHM_FORMAT_ARGB8888) {
                        globals.argb8888_supported = true;
                    }
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
            _ = try conn.recvEvents();
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
                } else if (header.object_id == globals.xdg_wm_base and header.opcode == xdg_shell.XDG_WM_BASE_EVENT_PING) {
                    var pos: usize = 0;
                    const serial = wire.getUint(payload, &pos);
                    try xdg_shell.pong(&conn, globals.xdg_wm_base, serial);
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
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.shm_buffers) |*bufs| {
            bufs.deinit();
        }
        if (self.internal_epoll_fd >= 0) {
            posix.close(self.internal_epoll_fd);
        }
        self.conn.deinit();
    }

    pub fn postInit(self: *Self) void {
        _ = self;
        // Keyboard/input will be initialized in later chunks
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

    // ========================================================================
    // Resize
    // ========================================================================

    pub fn resize(self: *Self, w: u32, h: u32) !void {
        if (w == self.width and h == self.height) return;
        if (w == 0 or h == 0) return;

        // Destroy old SHM buffers
        if (self.shm_buffers) |*bufs| {
            bufs.deinit();
            self.shm_buffers = null;
        }

        // Create new SHM buffers with new dimensions
        self.shm_buffers = try core.createShmBuffers(&self.conn, &self.globals, w, h);
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
        if (self.pending_count < self.pending_events.len) {
            self.pending_events[self.pending_count] = event;
            self.pending_count += 1;
        }
    }

    fn dequeueEvent(self: *Self) ?Event {
        if (self.pending_read < self.pending_count) {
            const event = self.pending_events[self.pending_read];
            self.pending_read += 1;
            // Reset when fully consumed
            if (self.pending_read >= self.pending_count) {
                self.pending_read = 0;
                self.pending_count = 0;
            }
            return event;
        }
        return null;
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
                // Must respond immediately or compositor kills us
                var pos: usize = 0;
                const serial = wire.getUint(payload, &pos);
                xdg_shell.pong(&self.conn, self.globals.xdg_wm_base, serial) catch {};
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

                // Queue resize if dimensions changed and are non-zero
                if (result.event.width > 0 and result.event.height > 0) {
                    const new_w: u32 = @intCast(result.event.width);
                    const new_h: u32 = @intCast(result.event.height);
                    if (new_w != self.width or new_h != self.height) {
                        self.queueEvent(.{ .resize = .{ .width = new_w, .height = new_h } });
                    }
                }

                // Track focus changes
                self.focused = new_focused;
            } else if (header.opcode == xdg_shell.XDG_TOPLEVEL_EVENT_CLOSE) {
                self.queueEvent(.close);
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
        // All other events (seat, keyboard, pointer, etc.) will be handled
        // in later chunks
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
            }
            // EPOLL_TAG_REPEAT and EPOLL_TAG_CLIPBOARD will be handled in later chunks
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
