/// zwp_text_input_v3 protocol: IME composition support.
///
/// Handles preedit string (composition preview), commit string (final text),
/// and done events for input method integration.

const std = @import("std");
const wire = @import("wire.zig");

// ============================================================================
// Protocol opcodes
// ============================================================================

// zwp_text_input_manager_v3 requests
pub const ZWP_TEXT_INPUT_MANAGER_DESTROY: u16 = 0;
pub const ZWP_TEXT_INPUT_MANAGER_GET_TEXT_INPUT: u16 = 1;

// zwp_text_input_v3 requests
pub const ZWP_TEXT_INPUT_DESTROY: u16 = 0;
pub const ZWP_TEXT_INPUT_ENABLE: u16 = 1;
pub const ZWP_TEXT_INPUT_DISABLE: u16 = 2;
pub const ZWP_TEXT_INPUT_SET_SURROUNDING_TEXT: u16 = 3;
pub const ZWP_TEXT_INPUT_SET_TEXT_CHANGE_CAUSE: u16 = 4;
pub const ZWP_TEXT_INPUT_SET_CONTENT_TYPE: u16 = 5;
pub const ZWP_TEXT_INPUT_SET_CURSOR_RECTANGLE: u16 = 6;
pub const ZWP_TEXT_INPUT_COMMIT: u16 = 7;

// zwp_text_input_v3 events
pub const ZWP_TEXT_INPUT_EVENT_ENTER: u16 = 0;
pub const ZWP_TEXT_INPUT_EVENT_LEAVE: u16 = 1;
pub const ZWP_TEXT_INPUT_EVENT_PREEDIT_STRING: u16 = 2;
pub const ZWP_TEXT_INPUT_EVENT_COMMIT_STRING: u16 = 3;
pub const ZWP_TEXT_INPUT_EVENT_DELETE_SURROUNDING_TEXT: u16 = 4;
pub const ZWP_TEXT_INPUT_EVENT_DONE: u16 = 5;

// ============================================================================
// TextInputState
// ============================================================================

pub const TextInputState = struct {
    id: u32 = 0,
    enabled: bool = false,
    preedit_text: [256]u8 = undefined,
    preedit_len: usize = 0,
    pending_commit: [256]u8 = undefined,
    pending_commit_len: usize = 0,
    has_pending_commit: bool = false,

    pub fn preeditSlice(self: *const TextInputState) []const u8 {
        return self.preedit_text[0..self.preedit_len];
    }
};

// ============================================================================
// zwp_text_input_manager_v3 requests
// ============================================================================

/// Send zwp_text_input_manager_v3.get_text_input -- returns text_input object ID.
pub fn getTextInput(conn: *wire.Connection, manager_id: u32, seat_id: u32) !u32 {
    const text_input_id = conn.id_alloc.next();
    var payload: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, text_input_id);
    wire.putUint(&payload, &pos, seat_id);
    try conn.sendMessage(manager_id, ZWP_TEXT_INPUT_MANAGER_GET_TEXT_INPUT, payload[0..pos], &.{});
    return text_input_id;
}

// ============================================================================
// zwp_text_input_v3 requests
// ============================================================================

/// Send zwp_text_input_v3.enable.
pub fn enable(conn: *wire.Connection, text_input_id: u32) !void {
    try conn.sendMessage(text_input_id, ZWP_TEXT_INPUT_ENABLE, &.{}, &.{});
}

/// Send zwp_text_input_v3.disable.
pub fn disable(conn: *wire.Connection, text_input_id: u32) !void {
    try conn.sendMessage(text_input_id, ZWP_TEXT_INPUT_DISABLE, &.{}, &.{});
}

/// Send zwp_text_input_v3.set_content_type(hint, purpose).
/// For terminal: hint=0 (none), purpose=0 (normal).
pub fn setContentType(conn: *wire.Connection, text_input_id: u32, hint: u32, purpose: u32) !void {
    var payload: [8]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, hint);
    wire.putUint(&payload, &pos, purpose);
    try conn.sendMessage(text_input_id, ZWP_TEXT_INPUT_SET_CONTENT_TYPE, payload[0..pos], &.{});
}

/// Send zwp_text_input_v3.commit.
pub fn commit(conn: *wire.Connection, text_input_id: u32) !void {
    try conn.sendMessage(text_input_id, ZWP_TEXT_INPUT_COMMIT, &.{}, &.{});
}

// ============================================================================
// Event handlers
// ============================================================================

/// Handle zwp_text_input_v3.preedit_string event.
/// Payload: text(string) + cursor_begin(i32) + cursor_end(i32)
pub fn handlePreeditString(state: *TextInputState, payload: []const u8) void {
    var pos: usize = 0;
    const text = wire.getString(payload, &pos);
    // cursor_begin and cursor_end are present but not used for terminal
    const clamped = @min(text.len, state.preedit_text.len);
    @memcpy(state.preedit_text[0..clamped], text[0..clamped]);
    state.preedit_len = clamped;
}

/// Handle zwp_text_input_v3.commit_string event.
/// Payload: text(string)
pub fn handleCommitString(state: *TextInputState, payload: []const u8) void {
    var pos: usize = 0;
    const text = wire.getString(payload, &pos);
    const clamped = @min(text.len, state.pending_commit.len);
    @memcpy(state.pending_commit[0..clamped], text[0..clamped]);
    state.pending_commit_len = clamped;
    state.has_pending_commit = true;
}

/// Handle zwp_text_input_v3.done event.
/// If there is a pending commit, clear preedit (composition is finalized).
pub fn handleDone(state: *TextInputState) void {
    if (state.has_pending_commit) {
        state.preedit_len = 0;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "TextInputState preeditSlice returns correct slice" {
    var state = TextInputState{};
    const text = "hello";
    @memcpy(state.preedit_text[0..text.len], text);
    state.preedit_len = text.len;
    try std.testing.expectEqualStrings("hello", state.preeditSlice());
}

test "TextInputState preeditSlice empty" {
    const state = TextInputState{};
    try std.testing.expectEqual(@as(usize, 0), state.preeditSlice().len);
}

test "handlePreeditString stores text" {
    var state = TextInputState{};
    // Build a synthetic preedit_string payload: text(string) + cursor_begin(i32) + cursor_end(i32)
    var payload: [64]u8 = undefined;
    var pos: usize = 0;
    wire.putString(&payload, &pos, "test");
    wire.putInt(&payload, &pos, 0);
    wire.putInt(&payload, &pos, 4);
    handlePreeditString(&state, payload[0..pos]);
    try std.testing.expectEqualStrings("test", state.preeditSlice());
}

test "handleCommitString stores text and sets pending flag" {
    var state = TextInputState{};
    var payload: [32]u8 = undefined;
    var pos: usize = 0;
    wire.putString(&payload, &pos, "abc");
    handleCommitString(&state, payload[0..pos]);
    try std.testing.expect(state.has_pending_commit);
    try std.testing.expectEqual(@as(usize, 3), state.pending_commit_len);
    try std.testing.expectEqualStrings("abc", state.pending_commit[0..state.pending_commit_len]);
}

test "handleDone clears preedit when commit pending" {
    var state = TextInputState{};
    state.preedit_len = 5;
    state.has_pending_commit = true;
    handleDone(&state);
    try std.testing.expectEqual(@as(usize, 0), state.preedit_len);
}

test "handleDone does not clear preedit when no commit pending" {
    var state = TextInputState{};
    state.preedit_len = 5;
    state.has_pending_commit = false;
    handleDone(&state);
    try std.testing.expectEqual(@as(usize, 5), state.preedit_len);
}
