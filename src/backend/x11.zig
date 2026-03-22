const std = @import("std");
const config = @import("config");
const input_mod = @import("../input.zig");

const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/shm.h");
    @cInclude("sys/shm.h");
    @cInclude("xcb-imdkit/imclient.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-x11.h");
});

pub const Event = union(enum) {
    key: KeyEvent,
    text: TextEvent,
    paste: PasteEvent,
    resize: ResizeEvent,
    close: void,
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

pub const X11Backend = struct {
    const Self = @This();

    connection: *c.xcb_connection_t,
    window: c.xcb_window_t,
    gc: c.xcb_gcontext_t,
    screen: *c.xcb_screen_t,
    // SHM
    shm_seg: c.xcb_shm_seg_t,
    shm_id: c_int,
    buffer: []u8,
    // Dimensions
    width: u32,
    height: u32,
    stride: u32,
    bpp: u32 = 4,
    // WM_DELETE_WINDOW atom for graceful close
    wm_delete_atom: c.xcb_atom_t,
    // Dirty row tracking
    dirty_y_min: u32 = std.math.maxInt(u32),
    dirty_y_max: u32 = 0,
    // Clipboard atoms
    clipboard_atom: c.xcb_atom_t = 0,
    utf8_string_atom: c.xcb_atom_t = 0,
    zt_paste_atom: c.xcb_atom_t = 0, // property for receiving paste data
    // XKB (keyboard layout)
    xkb_ctx: ?*c.xkb_context = null,
    xkb_keymap: ?*c.xkb_keymap = null,
    xkb_state: ?*c.xkb_state = null,
    // XIM (Input Method)
    xim: ?*c.xcb_xim_t = null,
    xic: c.xcb_xic_t = 0,
    xim_connected: bool = false,
    xim_active: bool = false,
    committed_text: TextEvent = .{},
    has_committed: bool = false,
    forwarded_keycode: u8 = 0, // XCB keycode (detail) from forward_event callback
    has_forwarded_key: bool = false,
    pending_xim_keycode: u8 = 0, // key sent to IM, awaiting response
    has_pending_xim: bool = false,
    paste_buf: PasteEvent = .{},
    screen_id: c_int = 0,

    pub fn init() !Self {
        // 1. Connect to X server
        var screen_num: c_int = 0;
        const connection = c.xcb_connect(null, &screen_num) orelse return error.XcbConnectFailed;
        errdefer c.xcb_disconnect(connection);

        if (c.xcb_connection_has_error(connection) != 0) {
            return error.XcbConnectionError;
        }

        // 2. Get screen
        const setup = c.xcb_get_setup(connection);
        var iter = c.xcb_setup_roots_iterator(setup);
        // Advance to the correct screen
        var i: c_int = 0;
        while (i < screen_num) : (i += 1) {
            c.xcb_screen_next(&iter);
        }
        const screen = iter.data orelse return error.NoScreen;

        // 3. Dimensions: 80x24 cells (standard terminal size)
        const width: u32 = 80 * config.font_width;
        const height: u32 = 24 * config.font_height;
        const stride: u32 = width * 4;

        // 4. Create window
        const window = c.xcb_generate_id(connection);
        const event_mask: u32 = c.XCB_EVENT_MASK_KEY_PRESS |
            c.XCB_EVENT_MASK_KEY_RELEASE |
            c.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
            c.XCB_EVENT_MASK_EXPOSURE;
        const values = [_]u32{event_mask};
        _ = c.xcb_create_window(
            connection,
            c.XCB_COPY_FROM_PARENT, // depth
            window,
            screen.*.root,
            0,
            0, // x, y
            @intCast(width),
            @intCast(height),
            0, // border_width
            c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            screen.*.root_visual,
            c.XCB_CW_EVENT_MASK,
            &values,
        );

        // 5. Set WM_CLASS and WM_NAME
        _ = c.xcb_change_property(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            window,
            c.XCB_ATOM_WM_NAME,
            c.XCB_ATOM_STRING,
            8,
            2,
            "zt",
        );
        // WM_CLASS: "zt\0zt\0" (instance\0class\0)
        _ = c.xcb_change_property(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            window,
            c.XCB_ATOM_WM_CLASS,
            c.XCB_ATOM_STRING,
            8,
            6,
            "zt\x00zt\x00",
        );

        // 6. Intern atoms
        const protocols_cookie = c.xcb_intern_atom(connection, 0, 12, "WM_PROTOCOLS");
        const delete_cookie = c.xcb_intern_atom(connection, 0, 16, "WM_DELETE_WINDOW");
        const clipboard_cookie = c.xcb_intern_atom(connection, 0, 9, "CLIPBOARD");
        const utf8_cookie = c.xcb_intern_atom(connection, 0, 11, "UTF8_STRING");
        const paste_cookie = c.xcb_intern_atom(connection, 0, 8, "ZT_PASTE");

        const protocols_reply = c.xcb_intern_atom_reply(connection, protocols_cookie, null);
        defer if (protocols_reply) |r| std.c.free(r);

        const delete_reply = c.xcb_intern_atom_reply(connection, delete_cookie, null);
        defer if (delete_reply) |r| std.c.free(r);

        var wm_delete_atom: c.xcb_atom_t = 0;
        if (protocols_reply) |pr| {
            if (delete_reply) |dr| {
                wm_delete_atom = dr.*.atom;
                _ = c.xcb_change_property(
                    connection,
                    c.XCB_PROP_MODE_REPLACE,
                    window,
                    pr.*.atom,
                    c.XCB_ATOM_ATOM,
                    32,
                    1,
                    @ptrCast(&dr.*.atom),
                );
            }
        }

        // 6b. Get clipboard atoms
        const clipboard_reply = c.xcb_intern_atom_reply(connection, clipboard_cookie, null);
        defer if (clipboard_reply) |r| std.c.free(r);
        const utf8_reply = c.xcb_intern_atom_reply(connection, utf8_cookie, null);
        defer if (utf8_reply) |r| std.c.free(r);
        const paste_reply = c.xcb_intern_atom_reply(connection, paste_cookie, null);
        defer if (paste_reply) |r| std.c.free(r);

        var clipboard_atom: c.xcb_atom_t = 0;
        var utf8_string_atom: c.xcb_atom_t = 0;
        var zt_paste_atom: c.xcb_atom_t = 0;
        if (clipboard_reply) |r| clipboard_atom = r.*.atom;
        if (utf8_reply) |r| utf8_string_atom = r.*.atom;
        if (paste_reply) |r| zt_paste_atom = r.*.atom;

        // 7. Set up SHM
        const buffer_size = stride * height;
        const shm_id = c.shmget(c.IPC_PRIVATE, buffer_size, c.IPC_CREAT | 0o600);
        if (shm_id < 0) return error.ShmGetFailed;
        errdefer _ = c.shmctl(shm_id, c.IPC_RMID, null);

        const shm_ptr = c.shmat(shm_id, null, 0);
        if (shm_ptr == @as(*allowzero anyopaque, @ptrFromInt(std.math.maxInt(usize)))) {
            return error.ShmAtFailed;
        }
        const buffer: []u8 = @as([*]u8, @ptrCast(shm_ptr))[0..buffer_size];
        @memset(buffer, 0);

        const shm_seg = c.xcb_generate_id(connection);
        _ = c.xcb_shm_attach(connection, shm_seg, @intCast(shm_id), 0);

        // Mark for deletion when detached
        _ = c.shmctl(shm_id, c.IPC_RMID, null);

        // 8. Create GC
        const gc = c.xcb_generate_id(connection);
        _ = c.xcb_create_gc(connection, gc, window, 0, null);

        // 9. Map window and flush
        _ = c.xcb_map_window(connection, window);
        _ = c.xcb_flush(connection);

        const self = Self{
            .connection = connection,
            .window = window,
            .gc = gc,
            .screen = screen,
            .shm_seg = shm_seg,
            .shm_id = shm_id,
            .buffer = buffer,
            .width = width,
            .height = height,
            .stride = stride,
            .wm_delete_atom = wm_delete_atom,
            .clipboard_atom = clipboard_atom,
            .utf8_string_atom = utf8_string_atom,
            .zt_paste_atom = zt_paste_atom,
            .screen_id = screen_num,
        };

        // NOTE: XKB and XIM are initialized via postInit() after the struct
        // is at its final memory address. init() returns by value, so 'self'
        // here would become a dangling pointer in callbacks.

        return self;
    }

    /// Must be called after init() when the struct is at its final address.
    /// Initializes XKB (keyboard layout) and XIM (input method).
    pub fn postInit(self: *Self) void {
        self.initXkb();
        self.initXim();
    }

    fn initXkb(self: *Self) void {
        // Set up XKB extension
        const xkb_result = c.xkb_x11_setup_xkb_extension(
            self.connection,
            c.XKB_X11_MIN_MAJOR_XKB_VERSION,
            c.XKB_X11_MIN_MINOR_XKB_VERSION,
            c.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
            null,
            null,
            null,
            null,
        );
        if (xkb_result == 0) return;

        const ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return;
        self.xkb_ctx = ctx;

        const device_id = c.xkb_x11_get_core_keyboard_device_id(self.connection);
        if (device_id < 0) return;

        const km = c.xkb_x11_keymap_new_from_device(ctx, self.connection, device_id, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
        self.xkb_keymap = km;

        const state = c.xkb_x11_state_new_from_device(km, self.connection, device_id) orelse return;
        self.xkb_state = state;
    }

    /// Check if an evdev keycode is a special key (arrows, function keys, etc.)
    /// that should be handled via escape sequences, not as text.
    fn isSpecialKey(evdev_keycode: u16) bool {
        const K = input_mod.KEY;
        return switch (evdev_keycode) {
            K.ESC, K.ENTER, K.BACKSPACE, K.TAB,
            K.UP, K.DOWN, K.LEFT, K.RIGHT,
            K.HOME, K.END, K.INSERT, K.DELETE,
            K.PAGEUP, K.PAGEDOWN,
            K.F1, K.F2, K.F3, K.F4, K.F5, K.F6,
            K.F7, K.F8, K.F9, K.F10, K.F11, K.F12,
            => true,
            else => false,
        };
    }

    /// Request clipboard paste from X11 CLIPBOARD selection.
    pub fn requestPaste(self: *Self) void {
        if (self.clipboard_atom == 0 or self.utf8_string_atom == 0) return;
        _ = c.xcb_convert_selection(
            self.connection,
            self.window,
            self.clipboard_atom,
            self.utf8_string_atom,
            self.zt_paste_atom,
            c.XCB_CURRENT_TIME,
        );
        _ = c.xcb_flush(self.connection);
    }

    /// Convert an XCB keycode (detail) to an Event using XKB or fallback keymap.
    fn processKeycode(self: *Self, xcb_keycode: u8) ?Event {
        const evdev_keycode: u16 = @as(u16, xcb_keycode) -| 8;

        // Special keys → KeyEvent
        if (isSpecialKey(evdev_keycode)) {
            return .{ .key = .{ .keycode = evdev_keycode, .pressed = true, .modifiers = .{} } };
        }

        // XKB text translation
        if (self.xkb_state) |state| {
            var xkb_buf: [128]u8 = undefined;
            const len = c.xkb_state_key_get_utf8(state, xcb_keycode, &xkb_buf, xkb_buf.len);
            if (len > 0) {
                const ulen: u32 = @intCast(len);
                var text_ev: TextEvent = .{};
                const clamped = @min(ulen, 128);
                @memcpy(text_ev.data[0..clamped], xkb_buf[0..clamped]);
                text_ev.len = clamped;
                return .{ .text = text_ev };
            }
        }

        // Fallback
        return .{ .key = .{ .keycode = evdev_keycode, .pressed = true, .modifiers = .{} } };
    }

    fn initXim(self: *Self) void {
        // Try XMODIFIERS first (user-configured), then auto-detect common IMEs
        const im_names = [_]?[*:0]const u8{ null, "@im=fcitx", "@im=ibus" };
        var xim: ?*c.xcb_xim_t = null;
        for (im_names) |name| {
            xim = c.xcb_xim_create(self.connection, self.screen_id, name);
            if (xim != null) break;
        }
        if (xim == null) return;
        self.xim = xim;

        c.xcb_xim_set_use_utf8_string(xim.?, true);

        // Static lifetime — xcb_xim_set_im_callback stores the pointer
        const S = struct {
            var callbacks = c.xcb_xim_im_callback{
            .set_event_mask = null,
            .forward_event = forwardEventCallback,
            .commit_string = commitStringCallback,
            .geometry = null,
            .preedit_start = null,
            .preedit_draw = null,
            .preedit_caret = null,
            .preedit_done = null,
            .status_start = null,
            .status_draw_text = null,
            .status_draw_bitmap = null,
            .status_done = null,
            .sync = null,
            .disconnected = disconnectedCallback,
        };
        };
        c.xcb_xim_set_im_callback(xim.?, &S.callbacks, @ptrCast(self));

        _ = c.xcb_xim_open(xim.?, ximOpenCallback, true, @ptrCast(self));
        _ = c.xcb_flush(self.connection);
    }

    fn ximOpenCallback(xim: ?*c.xcb_xim_t, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(user_data));
        self.xim_connected = true;

        // Create Input Context with XIMPreeditNothing | XIMStatusNothing
        const input_style: u32 = 0x0008 | 0x0400; // XIMPreeditNothing | XIMStatusNothing
        _ = c.xcb_xim_create_ic(
            xim,
            ximCreateIcCallback,
            user_data,
            c.XCB_XIM_XNInputStyle,
            &input_style,
            c.XCB_XIM_XNClientWindow,
            &self.window,
            c.XCB_XIM_XNFocusWindow,
            &self.window,
            @as(?*anyopaque, null),
        );
    }

    fn ximCreateIcCallback(_: ?*c.xcb_xim_t, ic: c.xcb_xic_t, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(user_data));
        self.xic = ic;
        if (self.xim) |xim| {
            _ = c.xcb_xim_set_ic_focus(xim, ic);
        }
    }

    fn commitStringCallback(
        _: ?*c.xcb_xim_t,
        _: c.xcb_xic_t,
        _: u32,
        str: [*c]u8,
        length: u32,
        _: [*c]u32,
        _: usize,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(user_data));
        var data = str[0..length];

        // Strip ISO 2022 Compound Text wrappers if present
        // ESC % G (switch to UTF-8) = 1b 25 47
        if (data.len >= 3 and data[0] == 0x1b and data[1] == 0x25 and data[2] == 0x47) {
            data = data[3..];
        }
        // ESC % @ (switch back to Latin-1) = 1b 25 40
        if (data.len >= 3 and data[data.len - 3] == 0x1b and data[data.len - 2] == 0x25 and data[data.len - 1] == 0x40) {
            data = data[0 .. data.len - 3];
        }

        const len = @min(data.len, 128);
        @memcpy(self.committed_text.data[0..len], data[0..len]);
        self.committed_text.len = @intCast(len);
        self.has_committed = true;
        self.has_pending_xim = false;
    }

    fn forwardEventCallback(
        _: ?*c.xcb_xim_t,
        _: c.xcb_xic_t,
        event: ?*c.xcb_key_press_event_t,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        // IME didn't consume this key — inject it back as a regular key event
        const self: *Self = @ptrCast(@alignCast(user_data));
        if (event) |ev| {
            const is_press = (ev.response_type & 0x7F) == c.XCB_KEY_PRESS;
            if (!is_press) return; // ignore key release from IM
            self.forwarded_keycode = ev.detail;
            self.has_forwarded_key = true;
            self.has_pending_xim = false;
        }
    }

    fn disconnectedCallback(_: ?*c.xcb_xim_t, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(user_data));
        self.xim_connected = false;
        self.xic = 0;
    }

    pub fn deinit(self: *Self) void {
        // Clean up XIM
        if (self.xim) |xim| {
            if (self.xim_connected) {
                c.xcb_xim_close(xim);
            }
            c.xcb_xim_destroy(xim);
            self.xim = null;
        }
        // Clean up XKB
        if (self.xkb_state) |s| c.xkb_state_unref(s);
        if (self.xkb_keymap) |km| c.xkb_keymap_unref(km);
        if (self.xkb_ctx) |ctx| c.xkb_context_unref(ctx);
        // Detach SHM from X server
        _ = c.xcb_shm_detach(self.connection, self.shm_seg);
        // Detach from process
        _ = c.shmdt(self.buffer.ptr);
        // Free GC and window
        _ = c.xcb_free_gc(self.connection, self.gc);
        _ = c.xcb_destroy_window(self.connection, self.window);
        _ = c.xcb_flush(self.connection);
        c.xcb_disconnect(self.connection);
    }

    pub fn getBuffer(self: *Self) []u8 {
        return self.buffer;
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

    pub fn getBpp(_: *Self) u32 {
        return 4;
    }

    pub fn markDirtyRows(self: *Self, y_start: u32, y_end: u32) void {
        if (y_start < self.dirty_y_min) self.dirty_y_min = y_start;
        if (y_end > self.dirty_y_max) self.dirty_y_max = y_end;
    }

    pub fn present(self: *Self) void {
        if (self.dirty_y_min > self.dirty_y_max) return; // nothing to present

        const y_start = self.dirty_y_min;
        const y_end = @min(self.dirty_y_max + 1, self.height);
        const dirty_h = y_end - y_start;
        const shm_offset = y_start * self.stride;

        _ = c.xcb_shm_put_image(
            self.connection,
            self.window,
            self.gc,
            @intCast(self.width),
            @intCast(dirty_h),
            0,
            0, // src x, y (within the sub-image)
            @intCast(self.width),
            @intCast(dirty_h),
            0,
            @intCast(y_start), // dst x, y
            self.screen.*.root_depth,
            c.XCB_IMAGE_FORMAT_Z_PIXMAP,
            0, // send_event
            self.shm_seg,
            shm_offset, // offset into SHM
        );
        _ = c.xcb_flush(self.connection);

        self.dirty_y_min = std.math.maxInt(u32);
        self.dirty_y_max = 0;
    }

    pub fn getFd(self: *Self) ?std.posix.fd_t {
        return c.xcb_get_file_descriptor(self.connection);
    }

    /// Query the actual window geometry from the X server.
    /// Used to detect WM-initiated resizes that happened during init.
    pub fn queryGeometry(self: *Self) struct { w: u32, h: u32 } {
        const cookie = c.xcb_get_geometry(self.connection, self.window);
        const reply = c.xcb_get_geometry_reply(self.connection, cookie, null);
        if (reply) |r| {
            defer std.c.free(r);
            return .{ .w = r.*.width, .h = r.*.height };
        }
        return .{ .w = self.width, .h = self.height };
    }

    pub fn resize(self: *Self, w: u32, h: u32) !void {
        if (w == self.width and h == self.height) return;

        const new_stride = w * 4;
        const new_size = new_stride * h;

        // 1. Detach old SHM from X server
        _ = c.xcb_shm_detach(self.connection, self.shm_seg);
        // 2. Detach old shared memory from process
        _ = c.shmdt(self.buffer.ptr);

        // 3. Create new shared memory segment
        const new_shm_id = c.shmget(c.IPC_PRIVATE, new_size, c.IPC_CREAT | 0o600);
        if (new_shm_id < 0) return error.ShmGetFailed;

        const new_ptr = c.shmat(new_shm_id, null, 0);
        if (new_ptr == @as(*allowzero anyopaque, @ptrFromInt(std.math.maxInt(usize)))) {
            _ = c.shmctl(new_shm_id, c.IPC_RMID, null);
            return error.ShmAtFailed;
        }
        const new_buffer: []u8 = @as([*]u8, @ptrCast(new_ptr))[0..new_size];
        @memset(new_buffer, 0);

        // 4. Attach new SHM to X server
        const new_seg = c.xcb_generate_id(self.connection);
        _ = c.xcb_shm_attach(self.connection, new_seg, @intCast(new_shm_id), 0);
        _ = c.shmctl(new_shm_id, c.IPC_RMID, null);

        // 5. Update state
        self.shm_seg = new_seg;
        self.shm_id = new_shm_id;
        self.buffer = new_buffer;
        self.width = w;
        self.height = h;
        self.stride = new_stride;
    }

    pub fn pollEvents(self: *Self) ?Event {
        // First, check if XIM callbacks produced events
        if (self.has_committed) {
            self.has_committed = false;
            return .{ .text = self.committed_text };
        }
        if (self.has_forwarded_key) {
            self.has_forwarded_key = false;
            return self.processKeycode(self.forwarded_keycode);
        }

        // Loop until we find a handled event or the queue is empty.
        // Unhandled event types (ReparentNotify, MapNotify, etc.) are skipped
        // so they don't block processing of subsequent events like ConfigureNotify.
        while (true) {
        const event = c.xcb_poll_for_event(self.connection) orelse {
            // No XCB event — if we have a pending XIM key with no response,
            // process it directly as fallback (prevents freeze if IM is unresponsive)
            if (self.has_pending_xim) {
                self.has_pending_xim = false;
                return self.processKeycode(self.pending_xim_keycode);
            }
            return null;
        };
        defer std.c.free(event);

        // Let XIM filter the event first — MUST run even before xim_connected
        // because xcb-imdkit uses this to process the XIM protocol handshake
        if (self.xim) |xim| {
            if (c.xcb_xim_filter_event(xim, event)) {
                // XIM consumed the event — check if it produced committed text
                if (self.has_committed) {
                    self.has_committed = false;
                    return .{ .text = self.committed_text };
                }
                if (self.has_forwarded_key) {
                    self.has_forwarded_key = false;
                    return self.processKeycode(self.forwarded_keycode);
                }
                continue; // XIM consumed event but produced nothing, try next
            }
        }

        const event_type = event.*.response_type & 0x7F;
        switch (event_type) {
            c.XCB_KEY_PRESS => {
                const key: *c.xcb_key_press_event_t = @ptrCast(@alignCast(event));
                const mods = xcbStateToMods(key.*.state);
                const evdev_keycode = key.*.detail -| 8;
                const xcb_keycode: u32 = key.*.detail;

                // Ctrl+Shift+V → paste from clipboard
                if (evdev_keycode == 47 and mods.ctrl and mods.shift and !mods.alt) {
                    self.requestPaste();
                    return null;
                }

                // Forward key to XIM if IC is active — IM server processes
                // and replies via commit_string or forward_event callback
                if (self.xim) |xim| {
                    if (self.xim_connected and self.xic != 0) {
                        // Save pending key for fallback if IM doesn't respond
                        self.pending_xim_keycode = key.*.detail;
                        self.has_pending_xim = true;
                        _ = c.xcb_xim_forward_event(xim, self.xic, key);
                        // Check if forwarding produced immediate results
                        if (self.has_committed) {
                            self.has_committed = false;
                            return .{ .text = self.committed_text };
                        }
                        if (self.has_forwarded_key) {
                            self.has_forwarded_key = false;
                            return self.processKeycode(self.forwarded_keycode);
                        }
                        return null; // wait for async response
                    }
                }

                // Shift+Space → toggle IME via XIM trigger
                if (evdev_keycode == 57 and mods.shift and !mods.ctrl and !mods.alt and !mods.meta) {
                    if (self.xim) |xim| {
                        if (self.xim_connected and self.xic != 0) {
                            if (c.xcb_xim_trigger_notify(xim, self.xic, 0, self.xim_active)) {
                                self.xim_active = !self.xim_active;
                                return null; // consume the event
                            }
                        }
                    }
                }

                // Special keys (Enter, Backspace, arrows, Fn...) → KeyEvent for escape sequence handling
                if (isSpecialKey(evdev_keycode)) {
                    return .{ .key = .{
                        .keycode = evdev_keycode,
                        .pressed = true,
                        .modifiers = mods,
                    } };
                }

                // Ctrl+letter → KeyEvent (for ctrl sequences like Ctrl+C)
                if (mods.ctrl) {
                    return .{ .key = .{
                        .keycode = evdev_keycode,
                        .pressed = true,
                        .modifiers = mods,
                    } };
                }

                // Use XKB for layout-aware text translation
                if (self.xkb_state) |state| {
                    var xkb_buf: [128]u8 = undefined;
                    const len = c.xkb_state_key_get_utf8(state, xcb_keycode, &xkb_buf, xkb_buf.len);
                    if (len > 0) {
                        const ulen: u32 = @intCast(len);
                        var text_ev: TextEvent = .{};
                        if (mods.alt) {
                            // Alt+key → prefix with ESC
                            text_ev.data[0] = 0x1b;
                            const clamped = @min(ulen, 127);
                            @memcpy(text_ev.data[1 .. 1 + clamped], xkb_buf[0..clamped]);
                            text_ev.len = clamped + 1;
                        } else {
                            const clamped = @min(ulen, 128);
                            @memcpy(text_ev.data[0..clamped], xkb_buf[0..clamped]);
                            text_ev.len = clamped;
                        }
                        return .{ .text = text_ev };
                    }
                    // XKB returned nothing (modifier-only key etc.) → ignore
                    return null;
                }

                // Fallback: no XKB → use hardcoded keymap via KeyEvent
                return .{ .key = .{
                    .keycode = evdev_keycode,
                    .pressed = true,
                    .modifiers = mods,
                } };
            },
            c.XCB_KEY_RELEASE => {
                const key: *c.xcb_key_release_event_t = @ptrCast(@alignCast(event));
                return .{ .key = .{
                    .keycode = key.*.detail -| 8,
                    .pressed = false,
                    .modifiers = xcbStateToMods(key.*.state),
                } };
            },
            c.XCB_CONFIGURE_NOTIFY => {
                const cfg: *c.xcb_configure_notify_event_t = @ptrCast(@alignCast(event));
                if (cfg.*.width != self.width or cfg.*.height != self.height) {
                    return .{ .resize = .{ .width = cfg.*.width, .height = cfg.*.height } };
                }
                return null;
            },
            c.XCB_SELECTION_NOTIFY => {
                const sel: *c.xcb_selection_notify_event_t = @ptrCast(@alignCast(event));
                if (sel.*.property == 0) return null; // selection request failed

                // Read the property data
                const prop_cookie = c.xcb_get_property(
                    self.connection,
                    1, // delete after reading
                    self.window,
                    sel.*.property,
                    c.XCB_ATOM_ANY,
                    0,
                    1024 * 1024, // max 1MB
                );
                const prop_reply = c.xcb_get_property_reply(self.connection, prop_cookie, null);
                if (prop_reply) |reply| {
                    defer std.c.free(reply);
                    const len: u32 = @intCast(c.xcb_get_property_value_length(reply));
                    if (len > 0) {
                        const data: [*]const u8 = @ptrCast(c.xcb_get_property_value(reply));
                        const clamped = @min(len, 4096);
                        @memcpy(self.paste_buf.data[0..clamped], data[0..clamped]);
                        self.paste_buf.len = clamped;
                        return .{ .paste = self.paste_buf };
                    }
                }
                return null;
            },
            c.XCB_EXPOSE => {
                // Window (re-)exposed — repaint entire buffer
                self.dirty_y_min = 0;
                self.dirty_y_max = self.height -| 1;
                self.present();
                return null;
            },
            c.XCB_CLIENT_MESSAGE => {
                const msg: *c.xcb_client_message_event_t = @ptrCast(@alignCast(event));
                if (msg.*.data.data32[0] == self.wm_delete_atom) {
                    return .close;
                }
                return null;
            },
            c.XCB_DESTROY_NOTIFY => return .close,
            else => continue, // Skip unhandled events (ReparentNotify, MapNotify, etc.)
        }
        } // while (true)
    }

    // No VT switching for X11
    pub fn setupVtSwitching(self: *Self) !void {
        _ = self;
    }

    pub fn saveConsoleState(self: *Self) !void {
        _ = self;
    }

    pub fn restoreConsoleState(self: *Self) void {
        _ = self;
    }

    pub fn releaseVt(self: *Self) void {
        _ = self;
    }

    pub fn acquireVt(self: *Self) void {
        _ = self;
    }
};

fn xcbStateToMods(state: u16) input_mod.Modifiers {
    return .{
        .shift = (state & c.XCB_MOD_MASK_SHIFT) != 0,
        .ctrl = (state & c.XCB_MOD_MASK_CONTROL) != 0,
        .alt = (state & c.XCB_MOD_MASK_1) != 0, // Mod1 = Alt
        .meta = (state & c.XCB_MOD_MASK_4) != 0, // Mod4 = Super
    };
}
