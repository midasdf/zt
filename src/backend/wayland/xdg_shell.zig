/// XDG Shell protocol: xdg_wm_base, xdg_surface, xdg_toplevel.

const std = @import("std");
const wire = @import("wire.zig");

// ============================================================================
// Protocol opcodes
// ============================================================================

// xdg_wm_base
pub const XDG_WM_BASE_DESTROY: u16 = 0;
pub const XDG_WM_BASE_CREATE_POSITIONER: u16 = 1;
pub const XDG_WM_BASE_GET_XDG_SURFACE: u16 = 2;
pub const XDG_WM_BASE_PONG: u16 = 3;
pub const XDG_WM_BASE_EVENT_PING: u16 = 0;

// xdg_surface
pub const XDG_SURFACE_DESTROY: u16 = 0;
pub const XDG_SURFACE_GET_TOPLEVEL: u16 = 1;
pub const XDG_SURFACE_GET_POPUP: u16 = 2;
pub const XDG_SURFACE_SET_WINDOW_GEOMETRY: u16 = 3;
pub const XDG_SURFACE_ACK_CONFIGURE: u16 = 4;
pub const XDG_SURFACE_EVENT_CONFIGURE: u16 = 0;

// xdg_toplevel
pub const XDG_TOPLEVEL_DESTROY: u16 = 0;
pub const XDG_TOPLEVEL_SET_PARENT: u16 = 1;
pub const XDG_TOPLEVEL_SET_TITLE: u16 = 2;
pub const XDG_TOPLEVEL_SET_APP_ID: u16 = 3;
pub const XDG_TOPLEVEL_SHOW_WINDOW_MENU: u16 = 4;
pub const XDG_TOPLEVEL_MOVE: u16 = 5;
pub const XDG_TOPLEVEL_RESIZE: u16 = 6;
pub const XDG_TOPLEVEL_SET_MAX_SIZE: u16 = 7;
pub const XDG_TOPLEVEL_SET_MIN_SIZE: u16 = 8;
pub const XDG_TOPLEVEL_EVENT_CONFIGURE: u16 = 0;
pub const XDG_TOPLEVEL_EVENT_CLOSE: u16 = 1;

// xdg_toplevel state enum values
pub const XDG_TOPLEVEL_STATE_MAXIMIZED: u32 = 1;
pub const XDG_TOPLEVEL_STATE_FULLSCREEN: u32 = 2;
pub const XDG_TOPLEVEL_STATE_RESIZING: u32 = 3;
pub const XDG_TOPLEVEL_STATE_ACTIVATED: u32 = 4;

// ============================================================================
// Types
// ============================================================================

pub const ConfigureEvent = struct {
    width: i32,
    height: i32,
};

pub const ConfigureState = struct {
    activated: bool = false,
};

// ============================================================================
// xdg_wm_base requests
// ============================================================================

/// Send xdg_wm_base.get_xdg_surface — returns xdg_surface object ID.
pub fn getXdgSurface(
    conn: *wire.Connection,
    wm_base_id: u32,
    surface_id: u32,
) !u32 {
    const xdg_surface_id = conn.id_alloc.next();
    var payload: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, xdg_surface_id);
    wire.putUint(&payload, &pos, surface_id);
    try conn.sendMessage(wm_base_id, XDG_WM_BASE_GET_XDG_SURFACE, payload[0..pos], &.{});
    return xdg_surface_id;
}

/// Send xdg_wm_base.pong in response to a ping event.
/// MUST be called immediately when a ping is received.
pub fn pong(conn: *wire.Connection, wm_base_id: u32, serial: u32) !void {
    var payload: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, serial);
    try conn.sendMessage(wm_base_id, XDG_WM_BASE_PONG, payload[0..pos], &.{});
}

// ============================================================================
// xdg_surface requests
// ============================================================================

/// Send xdg_surface.get_toplevel — returns xdg_toplevel object ID.
pub fn getToplevel(conn: *wire.Connection, xdg_surface_id: u32) !u32 {
    const toplevel_id = conn.id_alloc.next();
    var payload: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, toplevel_id);
    try conn.sendMessage(xdg_surface_id, XDG_SURFACE_GET_TOPLEVEL, payload[0..pos], &.{});
    return toplevel_id;
}

/// Send xdg_surface.ack_configure.
pub fn ackConfigure(conn: *wire.Connection, xdg_surface_id: u32, serial: u32) !void {
    var payload: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, serial);
    try conn.sendMessage(xdg_surface_id, XDG_SURFACE_ACK_CONFIGURE, payload[0..pos], &.{});
}

// ============================================================================
// xdg_toplevel requests
// ============================================================================

/// Send xdg_toplevel.set_title.
pub fn setTitle(conn: *wire.Connection, toplevel_id: u32, title: []const u8) !void {
    var payload: [256]u8 = undefined;
    var pos: usize = 0;
    wire.putString(&payload, &pos, title);
    try conn.sendMessage(toplevel_id, XDG_TOPLEVEL_SET_TITLE, payload[0..pos], &.{});
}

/// Send xdg_toplevel.set_app_id.
pub fn setAppId(conn: *wire.Connection, toplevel_id: u32, app_id: []const u8) !void {
    var payload: [256]u8 = undefined;
    var pos: usize = 0;
    wire.putString(&payload, &pos, app_id);
    try conn.sendMessage(toplevel_id, XDG_TOPLEVEL_SET_APP_ID, payload[0..pos], &.{});
}

/// Send xdg_toplevel.set_min_size.
pub fn setMinSize(conn: *wire.Connection, toplevel_id: u32, w: i32, h: i32) !void {
    var payload: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putInt(&payload, &pos, w);
    wire.putInt(&payload, &pos, h);
    try conn.sendMessage(toplevel_id, XDG_TOPLEVEL_SET_MIN_SIZE, payload[0..pos], &.{});
}

// ============================================================================
// xdg_toplevel event parsing
// ============================================================================

/// Parse an xdg_toplevel.configure event.
///
/// Payload: width(i32) + height(i32) + states(array of u32)
/// Scans the states array for STATE_ACTIVATED (=4).
pub fn parseToplevelConfigure(payload: []const u8) struct {
    event: ConfigureEvent,
    state: ConfigureState,
} {
    var pos: usize = 0;
    const width = wire.getInt(payload, &pos);
    const height = wire.getInt(payload, &pos);

    // Consume the states array
    const states_data = wire.getArray(payload, &pos);

    var state = ConfigureState{};
    // states_data is a flat array of u32 values
    var i: usize = 0;
    while (i + 4 <= states_data.len) : (i += 4) {
        const s = std.mem.readInt(u32, states_data[i..][0..4], .little);
        if (s == XDG_TOPLEVEL_STATE_ACTIVATED) {
            state.activated = true;
        }
    }

    return .{
        .event = .{ .width = width, .height = height },
        .state = state,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parseToplevelConfigure — activated state" {
    // Build a synthetic payload: width=800, height=600, states=[ACTIVATED]
    var payload: [32]u8 = undefined;
    var pos: usize = 0;
    wire.putInt(&payload, &pos, 800);
    wire.putInt(&payload, &pos, 600);
    // states array: length=4 (one u32), value=4 (STATE_ACTIVATED)
    wire.putUint(&payload, &pos, 4); // array byte length
    wire.putUint(&payload, &pos, XDG_TOPLEVEL_STATE_ACTIVATED);
    const result = parseToplevelConfigure(payload[0..pos]);
    try std.testing.expectEqual(@as(i32, 800), result.event.width);
    try std.testing.expectEqual(@as(i32, 600), result.event.height);
    try std.testing.expect(result.state.activated);
}

test "parseToplevelConfigure — no activated state" {
    var payload: [32]u8 = undefined;
    var pos: usize = 0;
    wire.putInt(&payload, &pos, 1280);
    wire.putInt(&payload, &pos, 720);
    // states array: length=4, value=MAXIMIZED(1)
    wire.putUint(&payload, &pos, 4);
    wire.putUint(&payload, &pos, XDG_TOPLEVEL_STATE_MAXIMIZED);
    const result = parseToplevelConfigure(payload[0..pos]);
    try std.testing.expectEqual(@as(i32, 1280), result.event.width);
    try std.testing.expectEqual(@as(i32, 720), result.event.height);
    try std.testing.expect(!result.state.activated);
}

test "parseToplevelConfigure — empty states array" {
    var payload: [16]u8 = undefined;
    var pos: usize = 0;
    wire.putInt(&payload, &pos, 0);
    wire.putInt(&payload, &pos, 0);
    wire.putUint(&payload, &pos, 0); // empty array
    const result = parseToplevelConfigure(payload[0..pos]);
    try std.testing.expect(!result.state.activated);
}
