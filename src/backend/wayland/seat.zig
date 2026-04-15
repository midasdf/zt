/// Wayland seat protocol: keyboard input, pointer, and cursor shape.
///
/// Handles wl_seat capabilities, wl_keyboard events (keymap, key, modifiers,
/// repeat_info), wl_pointer events (enter, button), and wp_cursor_shape_device_v1.
const std = @import("std");
const posix = @import("../../posix.zig");
const linux = std.os.linux;
const wire = @import("wire.zig");
const core = @import("core.zig");
const input_mod = @import("../../input.zig");

const c = @import("c_xkb");

// ============================================================================
// Protocol opcodes
// ============================================================================

// wl_seat requests
pub const WL_SEAT_GET_POINTER: u16 = 0;
pub const WL_SEAT_GET_KEYBOARD: u16 = 1;

// wl_seat events
pub const WL_SEAT_EVENT_CAPABILITIES: u16 = 0;
pub const WL_SEAT_EVENT_NAME: u16 = 1;

// wl_seat capability flags
pub const CAPABILITY_POINTER: u32 = 1;
pub const CAPABILITY_KEYBOARD: u32 = 2;

// wl_keyboard events
pub const WL_KEYBOARD_EVENT_KEYMAP: u16 = 0;
pub const WL_KEYBOARD_EVENT_ENTER: u16 = 1;
pub const WL_KEYBOARD_EVENT_LEAVE: u16 = 2;
pub const WL_KEYBOARD_EVENT_KEY: u16 = 3;
pub const WL_KEYBOARD_EVENT_MODIFIERS: u16 = 4;
pub const WL_KEYBOARD_EVENT_REPEAT_INFO: u16 = 5;

// wl_pointer events
pub const WL_POINTER_EVENT_ENTER: u16 = 0;
pub const WL_POINTER_EVENT_LEAVE: u16 = 1;
pub const WL_POINTER_EVENT_MOTION: u16 = 2;
pub const WL_POINTER_EVENT_BUTTON: u16 = 3;
pub const WL_POINTER_EVENT_AXIS: u16 = 4;
pub const WL_POINTER_EVENT_FRAME: u16 = 5;

// wl_pointer requests
pub const WL_POINTER_SET_CURSOR: u16 = 0;

// wp_cursor_shape_manager_v1 requests
pub const WP_CURSOR_SHAPE_MANAGER_GET_POINTER: u16 = 1;

// wp_cursor_shape_device_v1 requests
// opcode 0 = destroy, opcode 1 = set_shape
pub const WP_CURSOR_SHAPE_DEVICE_SET_SHAPE: u16 = 1;

// wp_cursor_shape_device_v1 shape enum values (from cursor-shape-v1.xml)
pub const CURSOR_DEFAULT: u32 = 1;
pub const CURSOR_TEXT: u32 = 9;

// ============================================================================
// KeyboardState
// ============================================================================

pub const KeyboardState = struct {
    xkb_context: ?*c.xkb_context = null,
    xkb_keymap: ?*c.xkb_keymap = null,
    xkb_state: ?*c.xkb_state = null,
    repeat_rate: i32 = 0,
    repeat_delay: i32 = 0,
    repeat_key: ?u32 = null,
    repeat_timer_fd: posix.fd_t = -1,
    focused: bool = false,
    last_serial: u32 = 0,

    pub fn init() KeyboardState {
        const ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
        return .{ .xkb_context = ctx };
    }

    pub fn deinit(self: *KeyboardState) void {
        self.stopRepeat();
        if (self.repeat_timer_fd >= 0) {
            posix.close(self.repeat_timer_fd);
            self.repeat_timer_fd = -1;
        }
        if (self.xkb_state) |s| c.xkb_state_unref(s);
        if (self.xkb_keymap) |km| c.xkb_keymap_unref(km);
        if (self.xkb_context) |ctx| c.xkb_context_unref(ctx);
        self.xkb_state = null;
        self.xkb_keymap = null;
        self.xkb_context = null;
    }

    /// Handle wl_keyboard.keymap event: mmap the fd, create xkb keymap + state.
    pub fn handleKeymap(self: *KeyboardState, fd: posix.fd_t, size: u32) void {
        defer posix.close(fd);

        const ctx = self.xkb_context orelse return;

        // mmap the keymap fd
        const map = posix.mmap(
            null,
            size,
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        ) catch return;
        defer posix.munmap(map);

        // Free old state/keymap if any
        if (self.xkb_state) |s| c.xkb_state_unref(s);
        if (self.xkb_keymap) |km| c.xkb_keymap_unref(km);
        self.xkb_state = null;
        self.xkb_keymap = null;

        // Create new keymap from the string
        const km = c.xkb_keymap_new_from_string(
            ctx,
            @ptrCast(map.ptr),
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return;
        self.xkb_keymap = km;

        const state = c.xkb_state_new(km) orelse return;
        self.xkb_state = state;
    }

    /// Handle wl_keyboard.modifiers event: update xkb modifier state.
    pub fn handleModifiers(
        self: *KeyboardState,
        depressed: u32,
        latched: u32,
        locked: u32,
        group: u32,
    ) void {
        const state = self.xkb_state orelse return;
        _ = c.xkb_state_update_mask(
            state,
            depressed,
            latched,
            locked,
            0,
            0,
            group,
        );
    }

    /// Get UTF-8 text for a keycode using xkbcommon.
    /// xkbcommon uses evdev+8 keycodes internally.
    pub fn getUtf8(self: *KeyboardState, keycode: u32, buf: *[32]u8) usize {
        const state = self.xkb_state orelse return 0;
        const len = c.xkb_state_key_get_utf8(state, keycode + 8, buf, buf.len);
        if (len < 0) return 0;
        return @intCast(len);
    }

    /// Extract current modifier state from xkb_state.
    pub fn getModifiers(self: *KeyboardState) input_mod.Modifiers {
        const state = self.xkb_state orelse return .{};
        return .{
            .shift = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_SHIFT, c.XKB_STATE_MODS_EFFECTIVE) == 1,
            .ctrl = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_EFFECTIVE) == 1,
            .alt = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_ALT, c.XKB_STATE_MODS_EFFECTIVE) == 1,
            .meta = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_LOGO, c.XKB_STATE_MODS_EFFECTIVE) == 1,
        };
    }

    /// Start key repeat timer. Creates timerfd on first call.
    pub fn startRepeat(self: *KeyboardState, key: u32) void {
        if (self.repeat_rate <= 0 or self.repeat_delay <= 0) return;

        self.repeat_key = key;

        // Create timerfd lazily
        if (self.repeat_timer_fd < 0) {
            const fd_raw = linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
            const fd_isize: isize = @bitCast(fd_raw);
            if (fd_isize < 0) return;
            self.repeat_timer_fd = @intCast(fd_isize);
        }

        // Set timer: initial delay, then interval = 1000/rate ms
        const delay_ms: u64 = @intCast(self.repeat_delay);
        const interval_ms: u64 = @intCast(@divTrunc(@as(u64, 1000), @as(u64, @intCast(self.repeat_rate))));

        const delay_sec: isize = @intCast(delay_ms / 1000);
        const delay_nsec: isize = @intCast((delay_ms % 1000) * 1_000_000);
        const interval_sec: isize = @intCast(interval_ms / 1000);
        const interval_nsec: isize = @intCast((interval_ms % 1000) * 1_000_000);

        const spec = linux.itimerspec{
            .it_value = .{ .sec = delay_sec, .nsec = delay_nsec },
            .it_interval = .{ .sec = interval_sec, .nsec = interval_nsec },
        };
        _ = linux.timerfd_settime(self.repeat_timer_fd, .{}, &spec, null);
    }

    /// Stop key repeat by disarming the timer.
    pub fn stopRepeat(self: *KeyboardState) void {
        self.repeat_key = null;
        if (self.repeat_timer_fd >= 0) {
            const zero = linux.itimerspec{
                .it_value = .{ .sec = 0, .nsec = 0 },
                .it_interval = .{ .sec = 0, .nsec = 0 },
            };
            _ = linux.timerfd_settime(self.repeat_timer_fd, .{}, &zero, null);
        }
    }
};

// ============================================================================
// wl_seat requests
// ============================================================================

/// Send wl_seat.get_keyboard -- returns the new keyboard object ID.
pub fn getKeyboard(conn: *wire.Connection, seat_id: u32) !u32 {
    const keyboard_id = conn.id_alloc.next();
    var payload: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, keyboard_id);
    try conn.sendMessage(seat_id, WL_SEAT_GET_KEYBOARD, payload[0..pos], &.{});
    return keyboard_id;
}

/// Send wl_seat.get_pointer -- returns the new pointer object ID.
pub fn getPointer(conn: *wire.Connection, seat_id: u32) !u32 {
    const pointer_id = conn.id_alloc.next();
    var payload: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, pointer_id);
    try conn.sendMessage(seat_id, WL_SEAT_GET_POINTER, payload[0..pos], &.{});
    return pointer_id;
}

// ============================================================================
// wp_cursor_shape_manager_v1 / wp_cursor_shape_device_v1 requests
// ============================================================================

/// Send wp_cursor_shape_manager_v1.get_pointer -- returns cursor shape device ID.
pub fn getCursorShapeDevice(conn: *wire.Connection, manager_id: u32, pointer_id: u32) !u32 {
    const device_id = conn.id_alloc.next();
    var payload: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, device_id);
    wire.putUint(&payload, &pos, pointer_id);
    try conn.sendMessage(manager_id, WP_CURSOR_SHAPE_MANAGER_GET_POINTER, payload[0..pos], &.{});
    return device_id;
}

/// Send wp_cursor_shape_device_v1.set_shape.
pub fn setCursorShape(conn: *wire.Connection, device_id: u32, serial: u32, shape: u32) !void {
    var payload: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, serial);
    wire.putUint(&payload, &pos, shape);
    try conn.sendMessage(device_id, WP_CURSOR_SHAPE_DEVICE_SET_SHAPE, payload[0..pos], &.{});
}

/// Reuse an existing cursor surface for subsequent pointer.enter events.
pub fn setPointerCursor(conn: *wire.Connection, pointer_id: u32, serial: u32, cursor_surface_id: u32) !void {
    var buf: [16]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&buf, &pos, serial);
    wire.putUint(&buf, &pos, cursor_surface_id);
    wire.putInt(&buf, &pos, 0); // hotspot_x
    wire.putInt(&buf, &pos, 0); // hotspot_y
    try conn.sendMessage(pointer_id, WL_POINTER_SET_CURSOR, buf[0..pos], &.{});
}

/// Fallback cursor: create a 1x1 surface with a single pixel, set as cursor.
/// Used when wp_cursor_shape_manager_v1 is not available.
pub fn setFallbackCursor(
    conn: *wire.Connection,
    pointer_id: u32,
    serial: u32,
    compositor_id: u32,
    shm_id: u32,
) !u32 {
    // Create a 1x1 wl_surface
    const cursor_surface_id = try core.createSurface(conn, compositor_id);

    // Create memfd for 4 bytes (1 pixel ARGB8888)
    const memfd_name = "zt-cursor";
    const fd_rc = linux.syscall2(
        linux.SYS.memfd_create,
        @intFromPtr(memfd_name.ptr),
        linux.MFD.CLOEXEC,
    );
    const fd_isize: isize = @bitCast(fd_rc);
    if (fd_isize < 0) return error.MemfdCreateFailed;
    const fd: posix.fd_t = @intCast(fd_isize);
    defer posix.close(fd);

    // Set size to 4 bytes
    try posix.ftruncate(fd, 4);

    // Write a white pixel
    const pixel_data = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF }; // ARGB white
    _ = try posix.write(fd, &pixel_data);

    // Create wl_shm_pool
    const pool_id = conn.id_alloc.next();
    {
        var payload: [8]u8 = undefined;
        var pos: usize = 0;
        wire.putUint(&payload, &pos, pool_id);
        wire.putInt(&payload, &pos, 4); // size = 4 bytes
        try conn.sendMessage(shm_id, core.WL_SHM_CREATE_POOL, payload[0..pos], &[_]posix.fd_t{fd});
    }

    // Create wl_buffer from pool
    const buffer_id = conn.id_alloc.next();
    {
        var payload: [20]u8 = undefined;
        var pos: usize = 0;
        wire.putUint(&payload, &pos, buffer_id);
        wire.putInt(&payload, &pos, 0); // offset
        wire.putInt(&payload, &pos, 1); // width
        wire.putInt(&payload, &pos, 1); // height
        wire.putInt(&payload, &pos, 4); // stride
        wire.putUint(&payload, &pos, core.SHM_FORMAT_ARGB8888);
        try conn.sendMessage(pool_id, core.WL_SHM_POOL_CREATE_BUFFER, payload[0..pos], &.{});
    }

    // Attach buffer to cursor surface
    try core.surfaceAttach(conn, cursor_surface_id, buffer_id);
    try core.surfaceDamageBuffer(conn, cursor_surface_id, 0, 0, 1, 1);
    try core.surfaceCommit(conn, cursor_surface_id);

    // wl_pointer.set_cursor(serial, surface, hotspot_x=0, hotspot_y=0)
    {
        var payload: [16]u8 = undefined;
        var pos: usize = 0;
        wire.putUint(&payload, &pos, serial);
        wire.putUint(&payload, &pos, cursor_surface_id);
        wire.putInt(&payload, &pos, 0); // hotspot_x
        wire.putInt(&payload, &pos, 0); // hotspot_y
        try conn.sendMessage(pointer_id, WL_POINTER_SET_CURSOR, payload[0..pos], &.{});
    }

    return cursor_surface_id;
}

// ============================================================================
// Tests
// ============================================================================

test "KeyboardState init/deinit" {
    var kb = KeyboardState.init();
    defer kb.deinit();
    // xkb_context should be non-null (if libxkbcommon is available)
    try std.testing.expect(kb.xkb_context != null);
}

test "KeyboardState getModifiers returns default when no state" {
    var kb = KeyboardState{};
    const mods = kb.getModifiers();
    try std.testing.expect(!mods.shift);
    try std.testing.expect(!mods.ctrl);
    try std.testing.expect(!mods.alt);
    try std.testing.expect(!mods.meta);
}

test "KeyboardState getUtf8 returns 0 when no state" {
    var kb = KeyboardState{};
    var buf: [32]u8 = undefined;
    const len = kb.getUtf8(30, &buf); // KEY_A
    try std.testing.expectEqual(@as(usize, 0), len);
}

test "KeyboardState startRepeat/stopRepeat with no rate" {
    var kb = KeyboardState{};
    defer kb.deinit();
    // repeat_rate = 0, should not create timer
    kb.startRepeat(30);
    try std.testing.expect(kb.repeat_timer_fd < 0);
    try std.testing.expect(kb.repeat_key == null);
}

test "KeyboardState startRepeat creates timer and stopRepeat clears key" {
    var kb = KeyboardState{};
    defer kb.deinit();
    kb.repeat_rate = 25;
    kb.repeat_delay = 600;
    kb.startRepeat(30);
    try std.testing.expect(kb.repeat_timer_fd >= 0);
    try std.testing.expect(kb.repeat_key != null);
    try std.testing.expectEqual(@as(u32, 30), kb.repeat_key.?);
    kb.stopRepeat();
    try std.testing.expect(kb.repeat_key == null);
}
