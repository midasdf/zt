/// Wayland clipboard support: wl_data_device and zwp_primary_selection_device.
///
/// Implements paste-only clipboard (no selection/copy support yet).
/// Supports Ctrl+Shift+V (clipboard) and Shift+Insert (primary selection).
///
/// Wire protocol notes:
///   - wl_data_offer.receive: payload = mime_type string only.
///     The fd argument is sent via SCM_RIGHTS and occupies ZERO bytes in payload.
///   - All event parsing advances through payload using wire.getString / wire.getUint.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const wire = @import("wire.zig");

// ============================================================================
// Protocol opcodes — wl_data_device_manager requests
// ============================================================================

pub const WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE: u16 = 0;
pub const WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE: u16 = 1;

// wl_data_device events
pub const WL_DATA_DEVICE_EVENT_DATA_OFFER: u16 = 0;
pub const WL_DATA_DEVICE_EVENT_ENTER: u16 = 1;
pub const WL_DATA_DEVICE_EVENT_LEAVE: u16 = 2;
pub const WL_DATA_DEVICE_EVENT_MOTION: u16 = 3;
pub const WL_DATA_DEVICE_EVENT_DROP: u16 = 4;
pub const WL_DATA_DEVICE_EVENT_SELECTION: u16 = 5;

// wl_data_offer requests
pub const WL_DATA_OFFER_ACCEPT: u16 = 0;
pub const WL_DATA_OFFER_RECEIVE: u16 = 1;
pub const WL_DATA_OFFER_DESTROY: u16 = 2;

// wl_data_offer events
pub const WL_DATA_OFFER_EVENT_OFFER: u16 = 0;

// ============================================================================
// Protocol opcodes — zwp_primary_selection_device_manager_v1 requests
// ============================================================================

pub const ZWP_PRIMARY_SELECTION_DEVICE_MANAGER_CREATE_SOURCE: u16 = 0;
pub const ZWP_PRIMARY_SELECTION_DEVICE_MANAGER_GET_DEVICE: u16 = 1;

// zwp_primary_selection_device_v1 events
pub const ZWP_PRIMARY_SELECTION_DEVICE_EVENT_DATA_OFFER: u16 = 0;
pub const ZWP_PRIMARY_SELECTION_DEVICE_EVENT_SELECTION: u16 = 1;

// zwp_primary_selection_offer_v1 requests
pub const ZWP_PRIMARY_SELECTION_OFFER_RECEIVE: u16 = 0;
pub const ZWP_PRIMARY_SELECTION_OFFER_DESTROY: u16 = 1;

// zwp_primary_selection_offer_v1 events
pub const ZWP_PRIMARY_SELECTION_OFFER_EVENT_OFFER: u16 = 0;

// ============================================================================
// ClipboardState
// ============================================================================

pub const ClipboardState = struct {
    // wl_data_device
    data_device_id: u32 = 0,
    current_offer_id: u32 = 0,
    offer_has_text: bool = false,

    // primary selection
    primary_device_id: u32 = 0,
    primary_offer_id: u32 = 0,
    primary_has_text: bool = false,

    // Paste pipe (async read)
    paste_pipe_fd: posix.fd_t = -1,
    paste_buf: [16384]u8 = undefined,
    paste_len: usize = 0,
};

// ============================================================================
// Device setup requests
// ============================================================================

/// Send wl_data_device_manager.get_data_device — returns the new data_device object ID.
pub fn getDataDevice(
    conn: *wire.Connection,
    manager_id: u32,
    seat_id: u32,
) u32 {
    if (manager_id == 0 or seat_id == 0) return 0;
    const device_id = conn.id_alloc.next();
    var payload: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, device_id);
    wire.putUint(&payload, &pos, seat_id);
    conn.sendMessage(manager_id, WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE, payload[0..pos], &.{}) catch return 0;
    return device_id;
}

/// Send zwp_primary_selection_device_manager_v1.get_device — returns new device object ID.
pub fn getPrimaryDevice(
    conn: *wire.Connection,
    manager_id: u32,
    seat_id: u32,
) u32 {
    if (manager_id == 0 or seat_id == 0) return 0;
    const device_id = conn.id_alloc.next();
    var payload: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, device_id);
    wire.putUint(&payload, &pos, seat_id);
    conn.sendMessage(manager_id, ZWP_PRIMARY_SELECTION_DEVICE_MANAGER_GET_DEVICE, payload[0..pos], &.{}) catch return 0;
    return device_id;
}

// ============================================================================
// Paste request
// ============================================================================

/// Destroy an old clipboard offer object on the compositor and release its ID.
/// Call this before overwriting current_offer_id / primary_offer_id.
pub fn destroyOffer(conn: *wire.Connection, offer_id: u32, is_primary: bool) void {
    if (offer_id == 0) return;
    const opcode: u16 = if (is_primary) ZWP_PRIMARY_SELECTION_OFFER_DESTROY else WL_DATA_OFFER_DESTROY;
    conn.sendMessage(offer_id, opcode, &.{}, &.{}) catch {};
    // Do NOT release the ID here — the compositor will send wl_display.delete_id
    // which triggers ID recycling. Releasing here causes double-free.
}

/// Close an active paste pipe fd if one exists. Must be called before
/// overwriting paste_pipe_fd to avoid leaking fds and stale epoll entries.
pub fn closePastePipe(state: *ClipboardState, epoll_fd: posix.fd_t) void {
    if (state.paste_pipe_fd >= 0) {
        if (epoll_fd >= 0) {
            _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_DEL, state.paste_pipe_fd, null);
        }
        posix.close(state.paste_pipe_fd);
        state.paste_pipe_fd = -1;
        state.paste_len = 0;
    }
}

/// Request paste from the compositor: creates a pipe, sends data_offer.receive
/// with the write end via SCM_RIGHTS, then stores the read end for async polling.
///
/// Wire encoding for data_offer.receive:
///   payload = mime_type string only (fd sent via SCM_RIGHTS, zero payload bytes)
pub fn requestPaste(
    conn: *wire.Connection,
    offer_id: u32,
    state: *ClipboardState,
    opcode: u16,
    epoll_fd: posix.fd_t,
) !void {
    // Close any previous paste pipe to avoid fd leak
    closePastePipe(state, epoll_fd);

    // Create a non-blocking, close-on-exec pipe pair
    const fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const read_fd = fds[0];
    const write_fd = fds[1];
    defer posix.close(write_fd); // always close write end (compositor gets dup via SCM_RIGHTS)
    errdefer posix.close(read_fd);

    const mime = "text/plain;charset=utf-8";

    // Build payload: just the mime_type string.
    // The write_fd goes via SCM_RIGHTS in the fds slice of sendMessage.
    var payload: [64]u8 = undefined;
    var pos: usize = 0;
    wire.putString(&payload, &pos, mime);

    try conn.sendMessage(offer_id, opcode, payload[0..pos], &[_]posix.fd_t{write_fd});

    // Flush immediately so the compositor processes the receive request
    try conn.flush();

    state.paste_pipe_fd = read_fd;
    state.paste_len = 0;
}

/// Non-blocking read from paste pipe into state.paste_buf.
/// Returns true if more data may be available (EAGAIN not yet hit).
/// Returns false when EOF (read returns 0) or on error — caller should epoll DEL and queue paste.
pub fn readPastePipe(state: *ClipboardState) bool {
    if (state.paste_pipe_fd < 0) return false;

    while (state.paste_len < state.paste_buf.len) {
        const remaining = state.paste_buf.len - state.paste_len;
        const n = posix.read(state.paste_pipe_fd, state.paste_buf[state.paste_len..][0..remaining]) catch |err| switch (err) {
            error.WouldBlock => return true, // no more data right now, but pipe still open
            else => return false, // error — treat as EOF
        };
        if (n == 0) return false; // EOF
        state.paste_len += n;
    }
    // Buffer full — treat as done (truncate at 4096)
    return false;
}

// ============================================================================
// Data source send stub
// ============================================================================

/// Called when compositor sends wl_data_source.send — we have no selection to offer,
/// so just close the fd.
pub fn handleDataSourceSend(_: *ClipboardState, fd: posix.fd_t) void {
    posix.close(fd);
}

// ============================================================================
// Tests
// ============================================================================

test "ClipboardState default initialization" {
    const state = ClipboardState{};
    try std.testing.expectEqual(@as(u32, 0), state.data_device_id);
    try std.testing.expectEqual(@as(u32, 0), state.current_offer_id);
    try std.testing.expect(!state.offer_has_text);
    try std.testing.expectEqual(@as(u32, 0), state.primary_device_id);
    try std.testing.expectEqual(@as(u32, 0), state.primary_offer_id);
    try std.testing.expect(!state.primary_has_text);
    try std.testing.expectEqual(@as(posix.fd_t, -1), state.paste_pipe_fd);
    try std.testing.expectEqual(@as(usize, 0), state.paste_len);
}

test "readPastePipe — EOF on empty pipe" {
    // Create a pipe, close write end immediately → read returns EOF
    const fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    posix.close(fds[1]); // close write end

    var state = ClipboardState{};
    state.paste_pipe_fd = fds[0];
    state.paste_len = 0;

    const more = readPastePipe(&state);
    try std.testing.expect(!more); // EOF → false

    posix.close(fds[0]);
}

test "readPastePipe — reads data then EOF" {
    const fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const data = "hello clipboard";
    _ = try posix.write(fds[1], data);
    posix.close(fds[1]);

    var state = ClipboardState{};
    state.paste_pipe_fd = fds[0];
    state.paste_len = 0;

    const more = readPastePipe(&state);
    try std.testing.expect(!more); // EOF after reading
    try std.testing.expectEqualStrings(data, state.paste_buf[0..state.paste_len]);

    posix.close(fds[0]);
}
