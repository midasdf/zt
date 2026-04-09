/// zxdg_decoration_manager_v1 and zxdg_toplevel_decoration_v1 protocol.
const wire = @import("wire.zig");

// ============================================================================
// Protocol opcodes
// ============================================================================

// zxdg_decoration_manager_v1
pub const ZXDG_DECORATION_MANAGER_DESTROY: u16 = 0;
pub const ZXDG_DECORATION_MANAGER_GET_TOPLEVEL_DECORATION: u16 = 1;

// zxdg_toplevel_decoration_v1
pub const ZXDG_TOPLEVEL_DECORATION_DESTROY: u16 = 0;
pub const ZXDG_TOPLEVEL_DECORATION_SET_MODE: u16 = 1;
pub const ZXDG_TOPLEVEL_DECORATION_UNSET_MODE: u16 = 2;
pub const ZXDG_TOPLEVEL_DECORATION_EVENT_CONFIGURE: u16 = 0;

// Decoration modes
pub const MODE_CLIENT_SIDE: u32 = 1;
pub const MODE_SERVER_SIDE: u32 = 2;

// ============================================================================
// Requests
// ============================================================================

/// Send zxdg_decoration_manager_v1.get_toplevel_decoration — returns decoration object ID.
pub fn getToplevelDecoration(
    conn: *wire.Connection,
    manager_id: u32,
    toplevel_id: u32,
) !u32 {
    const deco_id = conn.id_alloc.next();
    var payload: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, deco_id);
    wire.putUint(&payload, &pos, toplevel_id);
    try conn.sendMessage(manager_id, ZXDG_DECORATION_MANAGER_GET_TOPLEVEL_DECORATION, payload[0..pos], &.{});
    return deco_id;
}

/// Send zxdg_toplevel_decoration_v1.set_mode.
/// Use MODE_SERVER_SIDE (2) to request server-side decorations.
pub fn setMode(conn: *wire.Connection, deco_id: u32, mode: u32) !void {
    var payload: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, mode);
    try conn.sendMessage(deco_id, ZXDG_TOPLEVEL_DECORATION_SET_MODE, payload[0..pos], &.{});
}
