const std = @import("std");
const input_mod = @import("../input.zig");

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
// WaylandBackend — stub (not yet implemented)
// ============================================================================

pub const WaylandBackend = struct {
    const Self = @This();

    pub fn init() !Self {
        return error.NotImplemented;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn postInit(self: *Self) void {
        _ = self;
    }

    pub fn getBuffer(self: *Self) []u8 {
        _ = self;
        return &[_]u8{};
    }

    pub fn getStride(self: *Self) u32 {
        _ = self;
        return 0;
    }

    pub fn getWidth(self: *Self) u32 {
        _ = self;
        return 800;
    }

    pub fn getHeight(self: *Self) u32 {
        _ = self;
        return 600;
    }

    pub fn markDirtyRows(self: *Self, y_start: u32, y_end: u32) void {
        _ = self;
        _ = y_start;
        _ = y_end;
    }

    pub fn present(self: *Self) void {
        _ = self;
    }

    pub fn flush(self: *Self) void {
        _ = self;
    }

    pub fn resize(self: *Self, w: u32, h: u32) !void {
        _ = self;
        _ = w;
        _ = h;
    }

    pub fn queryGeometry(self: *Self) struct { w: u32, h: u32 } {
        _ = self;
        return .{ .w = 800, .h = 600 };
    }

    pub fn getFd(self: *Self) ?std.posix.fd_t {
        _ = self;
        return null;
    }

    pub fn pollEvents(self: *Self) ?Event {
        _ = self;
        return null;
    }

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
