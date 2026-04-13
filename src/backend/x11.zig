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
    copy_selection: void,
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

pub const X11Backend = struct {
    const Self = @This();

    connection: *c.xcb_connection_t,
    window: c.xcb_window_t,
    gc: c.xcb_gcontext_t,
    screen: *c.xcb_screen_t,
    // SHM double buffer
    shm_seg: [2]c.xcb_shm_seg_t,
    shm_id: [2]c_int,
    buffers: [2][]u8,
    buf_idx: u1 = 0, // current back buffer index
    shm_busy: bool = false, // true while X server is reading the front buffer
    shm_busy_ns: i128 = 0, // timestamp when shm_busy was set (for timeout fallback)
    shm_event_base: u8 = 0, // SHM extension first_event for completion detection
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
    net_wm_name_atom: c.xcb_atom_t = 0,
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
    forwarded_mods: input_mod.Modifiers = .{}, // modifiers from forwarded key
    has_forwarded_key: bool = false,
    pending_xim_keycode: u8 = 0, // key sent to IM, awaiting response
    pending_xim_mods: input_mod.Modifiers = .{}, // modifiers from pending XIM key
    has_pending_xim: bool = false,
    xim_pending_ns: i128 = 0, // timestamp when XIM key was forwarded (for timeout)
    suppress_xim_result: bool = false, // discard next XIM result (IME toggle key)
    last_ime_x: i16 = -1, // last cursor position sent to IME (-1 = never set)
    last_ime_y: i16 = -1,
    pending_event: ?*c.xcb_generic_event_t = null, // event pushed back during coalescing
    keyboard_initialized: bool = false, // XKB + XIM lazy init on first key
    paste_buf_data: [16384]u8 = undefined,
    paste_buf_len: u32 = 0,
    screen_id: c_int = 0,
    // XEmbed state (embedding into another window via -w)
    embed_parent: u32 = 0,
    xembed_atom: c.xcb_atom_t = 0,
    xembed_info_atom: c.xcb_atom_t = 0,
    embedder_window: u32 = 0,
    xembed_version: u32 = 0,
    xembed_active: bool = false,

    pub fn init(embed_window: u32) !Self {
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

        // 3. Dimensions: use parent geometry if embedded, else 80x24 cells
        var width: u32 = 80 * config.cell_width;
        var height: u32 = 24 * config.cell_height;
        if (embed_window != 0) {
            const geo_cookie = c.xcb_get_geometry(connection, embed_window);
            const geo_reply = c.xcb_get_geometry_reply(connection, geo_cookie, null);
            if (geo_reply) |r| {
                defer std.c.free(r);
                width = r.*.width;
                height = r.*.height;
            }
        }
        const stride: u32 = width * 4;

        // 4. Create window
        const window = c.xcb_generate_id(connection);
        const event_mask: u32 = c.XCB_EVENT_MASK_KEY_PRESS |
            c.XCB_EVENT_MASK_KEY_RELEASE |
            c.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
            c.XCB_EVENT_MASK_EXPOSURE |
            c.XCB_EVENT_MASK_FOCUS_CHANGE |
            c.XCB_EVENT_MASK_BUTTON_PRESS |
            c.XCB_EVENT_MASK_BUTTON_RELEASE |
            c.XCB_EVENT_MASK_BUTTON_MOTION;
        const parent = if (embed_window != 0) embed_window else screen.*.root;
        const values = [_]u32{ 0, event_mask }; // back_pixel=black, event_mask
        _ = c.xcb_create_window(
            connection,
            c.XCB_COPY_FROM_PARENT, // depth
            window,
            parent,
            0,
            0, // x, y
            @intCast(width),
            @intCast(height),
            0, // border_width
            c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            screen.*.root_visual,
            c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK,
            &values,
        );

        // 5. Set WM_CLASS and WM_NAME (skip in embedded mode)
        if (embed_window == 0) {
            const wm_name = "zt " ++ config.version;
            _ = c.xcb_change_property(
                connection,
                c.XCB_PROP_MODE_REPLACE,
                window,
                c.XCB_ATOM_WM_NAME,
                c.XCB_ATOM_STRING,
                8,
                wm_name.len,
                wm_name,
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
        }

        // 6. Intern atoms
        const protocols_cookie = c.xcb_intern_atom(connection, 0, 12, "WM_PROTOCOLS");
        const delete_cookie = c.xcb_intern_atom(connection, 0, 16, "WM_DELETE_WINDOW");
        const clipboard_cookie = c.xcb_intern_atom(connection, 0, 9, "CLIPBOARD");
        const utf8_cookie = c.xcb_intern_atom(connection, 0, 11, "UTF8_STRING");
        const paste_cookie = c.xcb_intern_atom(connection, 0, 8, "ZT_PASTE");
        const net_wm_name_cookie = c.xcb_intern_atom(connection, 0, 12, "_NET_WM_NAME");
        const xembed_cookie = c.xcb_intern_atom(connection, 0, 7, "_XEMBED");
        const xembed_info_cookie = c.xcb_intern_atom(connection, 0, 12, "_XEMBED_INFO");

        const protocols_reply = c.xcb_intern_atom_reply(connection, protocols_cookie, null);
        defer if (protocols_reply) |r| std.c.free(r);

        const delete_reply = c.xcb_intern_atom_reply(connection, delete_cookie, null);
        defer if (delete_reply) |r| std.c.free(r);

        var wm_delete_atom: c.xcb_atom_t = 0;
        if (protocols_reply) |pr| {
            if (delete_reply) |dr| {
                wm_delete_atom = dr.*.atom;
                // Only set WM_PROTOCOLS property in top-level mode
                if (embed_window == 0) {
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

        const net_wm_name_reply = c.xcb_intern_atom_reply(connection, net_wm_name_cookie, null);
        defer if (net_wm_name_reply) |r| std.c.free(r);
        var net_wm_name_atom: c.xcb_atom_t = 0;
        if (net_wm_name_reply) |r| net_wm_name_atom = r.*.atom;

        const xembed_reply = c.xcb_intern_atom_reply(connection, xembed_cookie, null);
        defer if (xembed_reply) |r| std.c.free(r);
        const xembed_info_reply = c.xcb_intern_atom_reply(connection, xembed_info_cookie, null);
        defer if (xembed_info_reply) |r| std.c.free(r);

        var xembed_atom: c.xcb_atom_t = 0;
        var xembed_info_atom: c.xcb_atom_t = 0;
        if (xembed_reply) |r| xembed_atom = r.*.atom;
        if (xembed_info_reply) |r| xembed_info_atom = r.*.atom;

        // 7. Set up SHM (second buffer created lazily on first present)
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
        _ = c.shmctl(shm_id, c.IPC_RMID, null);

        const shm_segs: [2]c.xcb_shm_seg_t = .{ shm_seg, 0 };
        const shm_ids: [2]c_int = .{ shm_id, -1 };
        const shm_buffers: [2][]u8 = .{ buffer, &.{} };

        // 8. Create GC
        const gc = c.xcb_generate_id(connection);
        _ = c.xcb_create_gc(connection, gc, window, 0, null);

        // 9. Set _XEMBED_INFO property in embedded mode
        if (embed_window != 0 and xembed_info_atom != 0) {
            const xembed_info = [2]u32{
                0, // version
                1, // flags: XEMBED_MAPPED
            };
            _ = c.xcb_change_property(
                connection,
                c.XCB_PROP_MODE_REPLACE,
                window,
                xembed_info_atom,
                xembed_info_atom, // type = _XEMBED_INFO (per spec)
                32,
                2,
                @ptrCast(&xembed_info),
            );
        }

        // 10. Query SHM extension first_event for completion events
        var shm_event_base: u8 = 0;
        if (c.xcb_get_extension_data(connection, &c.xcb_shm_id)) |ext| {
            if (ext.*.present != 0) {
                shm_event_base = ext.*.first_event;
            }
        }

        // 11. Map window and flush
        _ = c.xcb_map_window(connection, window);
        _ = c.xcb_flush(connection);

        const self = Self{
            .connection = connection,
            .window = window,
            .gc = gc,
            .screen = screen,
            .shm_seg = shm_segs,
            .shm_id = shm_ids,
            .buffers = shm_buffers,
            .width = width,
            .height = height,
            .stride = stride,
            .wm_delete_atom = wm_delete_atom,
            .clipboard_atom = clipboard_atom,
            .utf8_string_atom = utf8_string_atom,
            .zt_paste_atom = zt_paste_atom,
            .net_wm_name_atom = net_wm_name_atom,
            .shm_event_base = shm_event_base,
            .screen_id = screen_num,
            .embed_parent = embed_window,
            .xembed_atom = xembed_atom,
            .xembed_info_atom = xembed_info_atom,
        };

        // NOTE: XKB and XIM are initialized via postInit() after the struct
        // is at its final memory address. init() returns by value, so 'self'
        // here would become a dangling pointer in callbacks.

        return self;
    }

    /// Must be called after init() when the struct is at its final address.
    /// Initializes XKB (keyboard layout) and XIM (input method).
    /// Called lazily on first key event, not at startup.
    pub fn postInit(self: *Self) void {
        _ = self;
        // XKB + XIM now lazy-initialized on first key press
    }

    fn ensureKeyboardInit(self: *Self) void {
        if (self.keyboard_initialized) return;
        self.keyboard_initialized = true;
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

        const device_id = c.xkb_x11_get_core_keyboard_device_id(self.connection);
        if (device_id < 0) {
            c.xkb_context_unref(ctx);
            return;
        }

        const km = c.xkb_x11_keymap_new_from_device(ctx, self.connection, device_id, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse {
            c.xkb_context_unref(ctx);
            return;
        };

        const state = c.xkb_x11_state_new_from_device(km, self.connection, device_id) orelse {
            c.xkb_keymap_unref(km);
            c.xkb_context_unref(ctx);
            return;
        };

        self.xkb_ctx = ctx;
        self.xkb_keymap = km;
        self.xkb_state = state;
    }

    /// Check if an evdev keycode is a special key (arrows, function keys, etc.)
    /// that should be handled via escape sequences, not as text.
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
    /// Preserves modifiers from the original X event for correct key translation.
    fn processKeycode(self: *Self, xcb_keycode: u8, mods: input_mod.Modifiers) ?Event {
        const evdev_keycode: u16 = @as(u16, xcb_keycode) -| 8;

        // Special keys → KeyEvent (preserve modifiers)
        if (isSpecialKey(evdev_keycode)) {
            return .{ .key = .{ .keycode = evdev_keycode, .pressed = true, .modifiers = mods } };
        }

        // XKB text translation
        if (self.xkb_state) |state| {
            var xkb_buf: [128]u8 = undefined;
            const len = c.xkb_state_key_get_utf8(state, xcb_keycode, &xkb_buf, xkb_buf.len);
            if (len > 0) {
                const ulen: u32 = @intCast(len);
                var text_ev: TextEvent = .{};
                if (mods.alt) {
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
        }

        // Fallback (preserve modifiers)
        return .{ .key = .{ .keycode = evdev_keycode, .pressed = true, .modifiers = mods } };
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

        // PreeditNothing: IME handles preedit display in its own popup.
        // XNSpotLocation tells the IME where to position it.
        const input_style: u32 = 0x0008 | 0x0400; // XIMPreeditNothing | XIMStatusNothing
        var spot = c.xcb_point_t{ .x = 0, .y = 0 };
        var nested = c.xcb_xim_create_nested_list(xim, c.XCB_XIM_XNSpotLocation, &spot, @as(?*anyopaque, null));
        defer std.c.free(nested.data);
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
            c.XCB_XIM_XNPreeditAttributes,
            &nested,
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
            self.forwarded_mods = xcbStateToMods(ev.state);
            self.has_forwarded_key = true;
            self.has_pending_xim = false;
        }
    }

    fn disconnectedCallback(xim: ?*c.xcb_xim_t, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(user_data));
        self.xim_connected = false;
        self.xic = 0;
        // Attempt to reconnect — ximOpenCallback will restore xim_connected
        if (xim) |x| {
            _ = c.xcb_xim_open(x, ximOpenCallback, true, user_data);
        }
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
        for (0..2) |i| {
            if (self.buffers[i].len > 0) {
                _ = c.xcb_shm_detach(self.connection, self.shm_seg[i]);
                _ = c.shmdt(self.buffers[i].ptr);
            }
        }
        // Free GC and window
        _ = c.xcb_free_gc(self.connection, self.gc);
        _ = c.xcb_destroy_window(self.connection, self.window);
        _ = c.xcb_flush(self.connection);
        c.xcb_disconnect(self.connection);
    }

    pub fn getBuffer(self: *Self) []u8 {
        return self.buffers[self.buf_idx];
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

    fn initSecondBuffer(self: *Self) !void {
        const buf_size = self.stride * self.height;
        const new_shm_id = c.shmget(c.IPC_PRIVATE, buf_size, c.IPC_CREAT | 0o600);
        if (new_shm_id < 0) return error.ShmGetFailed;
        const ptr = c.shmat(new_shm_id, null, 0);
        if (ptr == @as(*allowzero anyopaque, @ptrFromInt(std.math.maxInt(usize)))) {
            _ = c.shmctl(new_shm_id, c.IPC_RMID, null);
            return error.ShmAtFailed;
        }
        const buf: []u8 = @as([*]u8, @ptrCast(ptr))[0..buf_size];
        // Copy current buffer content so back buffer starts in sync
        @memcpy(buf, self.buffers[self.buf_idx]);
        const seg = c.xcb_generate_id(self.connection);
        _ = c.xcb_shm_attach(self.connection, seg, @intCast(new_shm_id), 0);
        _ = c.shmctl(new_shm_id, c.IPC_RMID, null);
        const back: u1 = self.buf_idx ^ 1;
        self.shm_seg[back] = seg;
        self.shm_id[back] = new_shm_id;
        self.buffers[back] = buf;
    }

    pub fn getBpp(_: *Self) u32 {
        return 4;
    }

    /// Ring the X11 bell (urgency hint).
    pub fn bell(self: *Self) void {
        _ = c.xcb_bell(self.connection, 0);
    }

    /// Update the X11 window title (WM_NAME + _NET_WM_NAME for UTF-8).
    pub fn updateTitle(self: *Self, title: []const u8) void {
        _ = c.xcb_change_property(
            self.connection,
            c.XCB_PROP_MODE_REPLACE,
            self.window,
            c.XCB_ATOM_WM_NAME,
            c.XCB_ATOM_STRING,
            8,
            @intCast(title.len),
            title.ptr,
        );
        // Also set _NET_WM_NAME with UTF8_STRING for proper Unicode support
        if (self.net_wm_name_atom != 0 and self.utf8_string_atom != 0) {
            _ = c.xcb_change_property(
                self.connection,
                c.XCB_PROP_MODE_REPLACE,
                self.window,
                self.net_wm_name_atom,
                self.utf8_string_atom,
                8,
                @intCast(title.len),
                title.ptr,
            );
        }
    }

    /// Update IME candidate window position to follow the terminal cursor.
    /// Uses set_ic_values with XNSpotLocation (standard XIM protocol).
    /// Only sends when position changes to avoid IME instability.
    pub fn updateImeCursorPos(self: *Self, pixel_x: u32, pixel_y: u32) void {
        const x: i16 = if (pixel_x > std.math.maxInt(i16)) std.math.maxInt(i16) else @intCast(pixel_x);
        const y: i16 = if (pixel_y > std.math.maxInt(i16)) std.math.maxInt(i16) else @intCast(pixel_y);
        if (x == self.last_ime_x and y == self.last_ime_y) return;

        if (self.xim) |xim| {
            if (self.xim_connected and self.xic != 0) {
                var spot = c.xcb_point_t{ .x = x, .y = y };
                var nested = c.xcb_xim_create_nested_list(xim, c.XCB_XIM_XNSpotLocation, &spot, @as(?*anyopaque, null));
                defer std.c.free(nested.data);
                _ = c.xcb_xim_set_ic_values(xim, self.xic, setIcValuesCallback, @ptrCast(self), c.XCB_XIM_XNPreeditAttributes, &nested, @as(?*anyopaque, null));
                self.last_ime_x = x;
                self.last_ime_y = y;
            }
        }
    }

    fn setIcValuesCallback(_: ?*c.xcb_xim_t, _: c.xcb_xic_t, _: ?*anyopaque) callconv(.c) void {}

    pub fn markDirtyRows(self: *Self, y_start: u32, y_end: u32) void {
        if (y_start < self.dirty_y_min) self.dirty_y_min = y_start;
        if (y_end > self.dirty_y_max) self.dirty_y_max = y_end;
    }

    pub fn present(self: *Self) void {
        if (self.dirty_y_min > self.dirty_y_max) return; // nothing to present

        // Skip if X server is still reading the previous front buffer.
        // Keep dirty state so the next frame will include these regions.
        // Timeout after 100ms in case the SHM_COMPLETION event was lost.
        if (self.shm_busy) {
            const now = std.time.nanoTimestamp();
            if (now - self.shm_busy_ns < 100_000_000) return;
            self.shm_busy = false;
        }

        const front = self.buf_idx;
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
            0,
            @intCast(self.width),
            @intCast(dirty_h),
            0,
            @intCast(y_start),
            self.screen.*.root_depth,
            c.XCB_IMAGE_FORMAT_Z_PIXMAP,
            1, // send_event=1: X server sends SHM_COMPLETION when done reading
            self.shm_seg[front],
            shm_offset,
        );
        self.shm_busy = true;
        self.shm_busy_ns = std.time.nanoTimestamp();

        // Lazy-init second buffer on first present, then swap
        const back: u1 = front ^ 1;
        if (self.buffers[back].len == 0) {
            self.initSecondBuffer() catch {
                self.dirty_y_min = std.math.maxInt(u32);
                self.dirty_y_max = 0;
                return;
            };
        }
        const byte_start = y_start * self.stride;
        const byte_end = y_end * self.stride;
        @memcpy(self.buffers[back][byte_start..byte_end], self.buffers[front][byte_start..byte_end]);
        self.buf_idx = back;

        self.dirty_y_min = std.math.maxInt(u32);
        self.dirty_y_max = 0;
    }

    /// Flush XCB output buffer. Called once per event loop iteration
    /// after present() to batch put_image requests.
    pub fn flush(self: *Self) void {
        _ = c.xcb_flush(self.connection);
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

        // Allocate new SHM buffer BEFORE destroying old ones — if this fails,
        // the old buffers remain valid and the terminal keeps working.
        const new_shm_id = c.shmget(c.IPC_PRIVATE, new_size, c.IPC_CREAT | 0o600);
        if (new_shm_id < 0) return error.ShmGetFailed;
        const new_ptr = c.shmat(new_shm_id, null, 0);
        if (new_ptr == @as(*allowzero anyopaque, @ptrFromInt(std.math.maxInt(usize)))) {
            _ = c.shmctl(new_shm_id, c.IPC_RMID, null);
            return error.ShmAtFailed;
        }

        // Ensure X server is not reading the old buffer before we detach.
        // xcb_get_input_focus is a cheap round-trip that guarantees all prior
        // SHM requests (including any in-flight shm_put_image) have completed.
        if (self.shm_busy) {
            _ = c.xcb_get_input_focus_reply(self.connection, c.xcb_get_input_focus(self.connection), null);
            self.shm_busy = false;
        }

        // New buffer ready — now safe to destroy old ones
        for (0..2) |i| {
            if (self.buffers[i].len > 0) {
                _ = c.xcb_shm_detach(self.connection, self.shm_seg[i]);
                _ = c.shmdt(self.buffers[i].ptr);
                self.buffers[i] = &.{};
            }
        }

        self.buffers[0] = @as([*]u8, @ptrCast(new_ptr))[0..new_size];
        @memset(self.buffers[0], 0);
        const new_seg = c.xcb_generate_id(self.connection);
        _ = c.xcb_shm_attach(self.connection, new_seg, @intCast(new_shm_id), 0);
        _ = c.shmctl(new_shm_id, c.IPC_RMID, null);
        self.shm_seg[0] = new_seg;
        self.shm_id[0] = new_shm_id;
        self.buf_idx = 0;
        self.width = w;
        self.height = h;
        self.stride = new_stride;
    }

    pub fn pollEvents(self: *Self) ?Event {
        // Check for X connection errors (embedded parent destroyed, etc.)
        if (c.xcb_connection_has_error(self.connection) != 0) {
            return .close;
        }

        // XIM timeout: if IM server hasn't responded within 5 seconds,
        // assume it crashed and clear pending state. Do NOT emit a fallback
        // character — during Japanese romaji composition, consonants sit in
        // the preedit buffer for extended periods waiting for the next key
        // to disambiguate (e.g., "n" waits to see if "a" follows for "な"
        // or "n" follows for "ん"). Emitting a fallback would leak raw ASCII.
        if (self.has_pending_xim) {
            const now = std.time.nanoTimestamp();
            if (now - self.xim_pending_ns > 5_000_000_000) {
                self.has_pending_xim = false;
                self.suppress_xim_result = false;
                // Mark XIM as disconnected so subsequent keys fall back to
                // local XKB instead of being forwarded into a dead IM server.
                self.xim_connected = false;
                self.xic = 0;
                // Attempt to reconnect — ximOpenCallback will restore xim_connected
                if (self.xim) |xim| {
                    _ = c.xcb_xim_open(xim, ximOpenCallback, true, @ptrCast(self));
                }
            }
        }

        // First, check if XIM callbacks produced events
        if (self.has_committed) {
            self.has_committed = false;
            if (self.suppress_xim_result) {
                self.suppress_xim_result = false;
            } else {
                return .{ .text = self.committed_text };
            }
        }
        if (self.has_forwarded_key) {
            self.has_forwarded_key = false;
            if (self.suppress_xim_result) {
                self.suppress_xim_result = false;
            } else {
                return self.processKeycode(self.forwarded_keycode, self.forwarded_mods);
            }
        }

        // Loop until we find a handled event or the queue is empty.
        // Unhandled event types (ReparentNotify, MapNotify, etc.) are skipped
        // so they don't block processing of subsequent events like ConfigureNotify.
        while (true) {
            const event = if (self.pending_event) |pe| blk: {
                self.pending_event = null;
                break :blk pe;
            } else c.xcb_poll_for_event(self.connection) orelse {
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
                        if (self.suppress_xim_result) {
                            self.suppress_xim_result = false;
                        } else {
                            return .{ .text = self.committed_text };
                        }
                    }
                    if (self.has_forwarded_key) {
                        self.has_forwarded_key = false;
                        if (self.suppress_xim_result) {
                            self.suppress_xim_result = false;
                        } else {
                            return self.processKeycode(self.forwarded_keycode, self.forwarded_mods);
                        }
                    }
                    continue; // XIM consumed event but produced nothing, try next
                }
            }

            const event_type = event.*.response_type & 0x7F;
            switch (event_type) {
                c.XCB_KEY_PRESS => {
                    // Lazy-init XKB+XIM on first key press (not on non-key events,
                    // so transient XIM failures don't permanently disable IME)
                    self.ensureKeyboardInit();
                    const key: *c.xcb_key_press_event_t = @ptrCast(@alignCast(event));
                    const mods = xcbStateToMods(key.*.state);
                    const evdev_keycode = key.*.detail -| 8;
                    const xcb_keycode: u32 = key.*.detail;

                    // Sync XKB modifier state from X server. Using update_mask (not
                    // update_key) avoids state desync when XIM consumes key releases.
                    // Decompose X11 state bits: CapsLock (LockMask=0x02) is always a
                    // lock modifier. NumLock's real modifier bit is resolved dynamically
                    // via xkb_keymap_mod_get_index (typically Mod2=0x10 but not guaranteed).
                    if (self.xkb_state) |state| {
                        const x_state: u32 = key.*.state;
                        var lock_mask: u32 = 0x02; // LockMask (CapsLock) is always bit 1
                        if (self.xkb_keymap) |km| {
                            const num_idx = c.xkb_keymap_mod_get_index(km, "Mod2");
                            if (num_idx != c.XKB_MOD_INVALID) {
                                lock_mask |= @as(u32, 1) << @intCast(num_idx);
                            }
                        }
                        const lock_bits: u32 = x_state & lock_mask;
                        _ = c.xkb_state_update_mask(
                            state,
                            x_state & ~lock_bits, // depressed (Shift, Ctrl, Alt, etc.)
                            0, // latched
                            lock_bits, // locked (CapsLock, NumLock)
                            0,
                            0,
                            0, // group: base, latched, locked
                        );
                    }

                    // Ctrl+Shift+C → copy selection to clipboard
                    if (evdev_keycode == 46 and mods.ctrl and mods.shift and !mods.alt) {
                        return .{ .copy_selection = {} };
                    }

                    // Ctrl+Shift+V → paste from clipboard
                    if (evdev_keycode == 47 and mods.ctrl and mods.shift and !mods.alt) {
                        self.requestPaste();
                        continue; // don't return null — drain remaining XCB events
                    }

                    // Forward key to XIM if IC is active — IM server processes
                    // and replies via commit_string or forward_event callback.
                    // Skip XIM for Ctrl-modified keys: XIM is for text composition,
                    // and Ctrl+letter must produce control characters (e.g. Ctrl+P = 0x10)
                    // without IM interference.
                    if (!mods.ctrl) {
                        if (self.xim) |xim| {
                            if (self.xim_connected and self.xic != 0) {
                                // Shift+Space → let fcitx5 toggle IME, but suppress
                                // the leaked space character it sends back.
                                // For any other key, clear stale suppress flag so
                                // committed text from actual input isn't discarded.
                                const is_ime_toggle = evdev_keycode == 57 and mods.shift and !mods.alt and !mods.meta;
                                if (is_ime_toggle) {
                                    self.suppress_xim_result = true;
                                } else {
                                    self.suppress_xim_result = false;
                                }

                                // Save pending key for fallback if IM doesn't respond
                                self.pending_xim_keycode = key.*.detail;
                                self.pending_xim_mods = xcbStateToMods(key.*.state);
                                self.has_pending_xim = true;
                                self.xim_pending_ns = std.time.nanoTimestamp();
                                _ = c.xcb_xim_forward_event(xim, self.xic, key);
                                // Flush immediately so the IM server receives the
                                // forwarded key. Without this, the key sits in libxcb's
                                // output buffer until end-of-loop flush, and the IM
                                // server cannot fire the commit/forward callback —
                                // leaving has_pending_xim stuck true indefinitely.
                                _ = c.xcb_flush(self.connection);
                                // Check if forwarding produced immediate results
                                if (self.has_committed) {
                                    self.has_committed = false;
                                    if (!self.suppress_xim_result) {
                                        return .{ .text = self.committed_text };
                                    }
                                    self.suppress_xim_result = false;
                                }
                                if (self.has_forwarded_key) {
                                    self.has_forwarded_key = false;
                                    if (!self.suppress_xim_result) {
                                        return self.processKeycode(self.forwarded_keycode, self.forwarded_mods);
                                    }
                                    self.suppress_xim_result = false;
                                }
                                // Continue draining XCB event queue — do NOT return null here.
                                // xcb_poll_for_event may have buffered multiple events from
                                // a single socket read; returning null would exit the caller's
                                // while(pollEvents) loop, and epoll won't wake because the fd
                                // has no new data (it's already in libxcb's internal buffer).
                                continue;
                            }
                        }
                    }

                    // Suppress IME toggle keys (Shift+Space) — don't produce text
                    // Only when IME is actually connected; otherwise Shift+Space should work normally
                    if (evdev_keycode == 57 and mods.shift and !mods.ctrl and !mods.alt and self.xim_connected and self.xic != 0) {
                        continue; // don't return null — drain remaining XCB events
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
                        continue; // don't return null — drain remaining XCB events
                    }

                    // Fallback: no XKB → use hardcoded keymap via KeyEvent
                    return .{ .key = .{
                        .keycode = evdev_keycode,
                        .pressed = true,
                        .modifiers = mods,
                    } };
                },
                c.XCB_KEY_RELEASE => {
                    // Update XKB state on release so modifier tracking stays in sync.
                    // Use update_key(UP) instead of update_mask because the X11
                    // state field in a release event reflects the PRE-release state.
                    const key: *c.xcb_key_release_event_t = @ptrCast(@alignCast(event));
                    if (self.xkb_state) |state| {
                        _ = c.xkb_state_update_key(state, key.*.detail, c.XKB_KEY_UP);
                    }
                    continue;
                },
                c.XCB_CONFIGURE_NOTIFY => {
                    const cfg: *c.xcb_configure_notify_event_t = @ptrCast(@alignCast(event));
                    var latest_w: u32 = cfg.*.width;
                    var latest_h: u32 = cfg.*.height;
                    // Coalesce: drain all queued ConfigureNotify, keep only last size
                    while (c.xcb_poll_for_queued_event(self.connection)) |next| {
                        const next_type = next.*.response_type & 0x7F;
                        if (next_type == c.XCB_CONFIGURE_NOTIFY) {
                            const next_cfg: *c.xcb_configure_notify_event_t = @ptrCast(@alignCast(next));
                            latest_w = next_cfg.*.width;
                            latest_h = next_cfg.*.height;
                            std.c.free(next);
                        } else {
                            // Non-ConfigureNotify event — store for next pollEvents call.
                            // Free any previously stored event to avoid memory leak.
                            if (self.pending_event) |old| std.c.free(old);
                            self.pending_event = next;
                            break;
                        }
                    }
                    if (latest_w != self.width or latest_h != self.height) {
                        return .{ .resize = .{ .width = latest_w, .height = latest_h } };
                    }
                    continue;
                },
                c.XCB_SELECTION_NOTIFY => {
                    const sel: *c.xcb_selection_notify_event_t = @ptrCast(@alignCast(event));
                    if (sel.*.property == 0) continue; // selection request failed

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
                            const clamped = @min(len, 16384);
                            @memcpy(self.paste_buf_data[0..clamped], data[0..clamped]);
                            self.paste_buf_len = clamped;
                            return .{ .paste = .{ .ptr = &self.paste_buf_data, .len = clamped } };
                        }
                    }
                    continue; // property data empty — skip
                },
                c.XCB_EXPOSE => {
                    // Window (re-)exposed — tell main loop to force full redraw.
                    // Don't present() here: after a resize the SHM buffer is zeroed,
                    // and presenting it would flash a black frame.
                    return .expose;
                },
                c.XCB_CLIENT_MESSAGE => {
                    const msg: *c.xcb_client_message_event_t = @ptrCast(@alignCast(event));
                    // XEmbed messages: type == _XEMBED, code in data32[1]
                    if (self.xembed_atom != 0 and msg.*.type == self.xembed_atom) {
                        const xembed_msg = msg.*.data.data32[1];
                        switch (xembed_msg) {
                            0 => { // XEMBED_EMBEDDED_NOTIFY
                                self.embedder_window = msg.*.data.data32[3];
                                self.xembed_version = 0;
                            },
                            1 => { // XEMBED_WINDOW_ACTIVATE
                                self.xembed_active = true;
                            },
                            2 => { // XEMBED_WINDOW_DEACTIVATE
                                self.xembed_active = false;
                            },
                            4 => { // XEMBED_FOCUS_IN
                                return .focus_in;
                            },
                            5 => { // XEMBED_FOCUS_OUT
                                return .focus_out;
                            },
                            10, 11 => {}, // MODALITY_ON/OFF — no-op
                            else => {},
                        }
                        continue;
                    }
                    // WM_DELETE_WINDOW (top-level mode)
                    if (msg.*.data.data32[0] == self.wm_delete_atom) {
                        return .close;
                    }
                    continue;
                },
                c.XCB_DESTROY_NOTIFY => return .close,
                c.XCB_FOCUS_IN => {
                    // Re-establish XIM IC focus so the IM server accepts forwarded keys
                    if (self.xim) |xim| {
                        if (self.xim_connected and self.xic != 0) {
                            _ = c.xcb_xim_set_ic_focus(xim, self.xic);
                        }
                    }
                    return .focus_in;
                },
                c.XCB_FOCUS_OUT => {
                    // Clear stale XIM pending state — the IM server will not
                    // respond to a key forwarded before focus was lost.
                    self.has_pending_xim = false;
                    self.suppress_xim_result = false;
                    // Notify IM server that IC lost focus
                    if (self.xim) |xim| {
                        if (self.xim_connected and self.xic != 0) {
                            _ = c.xcb_xim_unset_ic_focus(xim, self.xic);
                        }
                    }
                    return .focus_out;
                },
                c.XCB_BUTTON_PRESS => {
                    const btn_ev: *c.xcb_button_press_event_t = @ptrCast(@alignCast(event));
                    // Skip unknown buttons (> 7)
                    if (btn_ev.*.detail == 0 or btn_ev.*.detail > 7) continue;
                    const mods = xcbStateToMods(btn_ev.*.state);
                    const button: MouseEvent.Button = switch (btn_ev.*.detail) {
                        1 => .left,
                        2 => .middle,
                        3 => .right,
                        4 => .wheel_up,
                        5 => .wheel_down,
                        6 => .wheel_left,
                        7 => .wheel_right,
                        else => unreachable,
                    };
                    return .{ .mouse = .{
                        .x = @intCast(@max(0, btn_ev.*.event_x)),
                        .y = @intCast(@max(0, btn_ev.*.event_y)),
                        .button = button,
                        .action = .press,
                        .modifiers = mods,
                    } };
                },
                c.XCB_BUTTON_RELEASE => {
                    const btn_ev: *c.xcb_button_release_event_t = @ptrCast(@alignCast(event));
                    // Ignore wheel button releases (4-7)
                    if (btn_ev.*.detail >= 4) continue;
                    const mods = xcbStateToMods(btn_ev.*.state);
                    const button: MouseEvent.Button = switch (btn_ev.*.detail) {
                        1 => .left,
                        2 => .middle,
                        3 => .right,
                        else => continue,
                    };
                    return .{ .mouse = .{
                        .x = @intCast(@max(0, btn_ev.*.event_x)),
                        .y = @intCast(@max(0, btn_ev.*.event_y)),
                        .button = button,
                        .action = .release,
                        .modifiers = mods,
                    } };
                },
                c.XCB_MOTION_NOTIFY => {
                    const motion: *c.xcb_motion_notify_event_t = @ptrCast(@alignCast(event));
                    const mods = xcbStateToMods(motion.*.state);
                    // Determine which button is held from X11 state bits
                    const button: MouseEvent.Button = if (motion.*.state & c.XCB_BUTTON_MASK_1 != 0)
                        .left
                    else if (motion.*.state & c.XCB_BUTTON_MASK_2 != 0)
                        .middle
                    else if (motion.*.state & c.XCB_BUTTON_MASK_3 != 0)
                        .right
                    else
                        .none;
                    return .{ .mouse = .{
                        .x = @intCast(@max(0, motion.*.event_x)),
                        .y = @intCast(@max(0, motion.*.event_y)),
                        .button = button,
                        .action = .motion,
                        .modifiers = mods,
                    } };
                },
                else => {
                    // SHM_COMPLETION: X server finished reading the front buffer
                    if (self.shm_event_base != 0 and event_type == self.shm_event_base + c.XCB_SHM_COMPLETION) {
                        self.shm_busy = false;
                    }
                    continue; // Skip unhandled events (ReparentNotify, MapNotify, etc.)
                },
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
