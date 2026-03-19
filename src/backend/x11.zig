const std = @import("std");
const config = @import("config");
const input_mod = @import("../input.zig");

const c = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/shm.h");
    @cInclude("sys/shm.h");
});

pub const Event = union(enum) {
    key: KeyEvent,
    resize: ResizeEvent,
    close: void,
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

        // 3. Dimensions: fill the screen, rounded down to cell grid
        const screen_w: u32 = @intCast(screen.*.width_in_pixels);
        const screen_h: u32 = @intCast(screen.*.height_in_pixels);
        const width: u32 = (screen_w / config.font_width) * config.font_width;
        const height: u32 = (screen_h / config.font_height) * config.font_height;
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

        // 6. Set up WM_DELETE_WINDOW protocol
        const protocols_cookie = c.xcb_intern_atom(connection, 1, 12, "WM_PROTOCOLS");
        const delete_cookie = c.xcb_intern_atom(connection, 0, 16, "WM_DELETE_WINDOW");

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

        return Self{
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
        };
    }

    pub fn deinit(self: *Self) void {
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
        // X11 SHM presents the entire buffer; dirty tracking not needed
        _ = self;
        _ = y_start;
        _ = y_end;
    }

    pub fn present(self: *Self) void {
        _ = c.xcb_shm_put_image(
            self.connection,
            self.window,
            self.gc,
            @intCast(self.width),
            @intCast(self.height),
            0,
            0, // src x, y
            @intCast(self.width),
            @intCast(self.height),
            0,
            0, // dst x, y
            self.screen.*.root_depth,
            c.XCB_IMAGE_FORMAT_Z_PIXMAP,
            0, // send_event
            self.shm_seg,
            0, // offset
        );
        _ = c.xcb_flush(self.connection);
    }

    pub fn getFd(self: *Self) ?std.posix.fd_t {
        return c.xcb_get_file_descriptor(self.connection);
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
        const event = c.xcb_poll_for_event(self.connection) orelse return null;
        defer std.c.free(event);

        const event_type = event.*.response_type & 0x7F;
        switch (event_type) {
            c.XCB_KEY_PRESS => {
                const key: *c.xcb_key_press_event_t = @ptrCast(@alignCast(event));
                return .{ .key = .{
                    // XCB keycodes are offset by 8 from evdev keycodes
                    .keycode = key.*.detail -| 8,
                    .pressed = true,
                    .modifiers = xcbStateToMods(key.*.state),
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
            c.XCB_CLIENT_MESSAGE => {
                const msg: *c.xcb_client_message_event_t = @ptrCast(@alignCast(event));
                if (msg.*.data.data32[0] == self.wm_delete_atom) {
                    return .close;
                }
                return null;
            },
            else => return null,
        }
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
