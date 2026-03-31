const std = @import("std");
const config = @import("config");
const input_mod = @import("../input.zig");

// Stub: macOS backend (to be implemented in Tasks 7-10)

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

pub const MacosBackend = struct {
    const Self = @This();

    width: u32 = 0,
    height: u32 = 0,

    pub fn init() !Self {
        return error.NotImplemented;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn postInit(self: *Self) void {
        _ = self;
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

    pub fn getWidth(self: *const Self) u32 {
        return self.width;
    }

    pub fn getHeight(self: *const Self) u32 {
        return self.height;
    }

    pub fn getFd(self: *const Self) ?std.posix.fd_t {
        _ = self;
        return null;
    }

    pub fn queryGeometry(self: *const Self) struct { w: u32, h: u32 } {
        return .{ .w = self.width, .h = self.height };
    }

    pub fn pollEvents(self: *Self) ?Event {
        _ = self;
        return null;
    }

    pub fn resize(self: *Self, w: u32, h: u32) !void {
        self.width = w;
        self.height = h;
    }

    pub fn releaseVt(self: *Self) void {
        _ = self;
    }

    pub fn acquireVt(self: *Self) void {
        _ = self;
    }

    pub fn getBuffer(self: *Self) [*]u8 {
        _ = self;
        return undefined;
    }

    pub fn getStride(self: *const Self) u32 {
        _ = self;
        return 0;
    }

    pub fn markDirtyRows(self: *Self, top: u32, bottom: u32) void {
        _ = self;
        _ = top;
        _ = bottom;
    }

    pub fn present(self: *Self) void {
        _ = self;
    }

    pub fn flush(self: *Self) void {
        _ = self;
    }
};
