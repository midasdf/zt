const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const term_mod = @import("term.zig");
const Cell = term_mod.Cell;

pub const ScrollbackView = struct {
    cells: []const Cell,
    fg_rgb: []const ?[3]u8,
    bg_rgb: []const ?[3]u8,
    ul_color_rgb: []const ?[3]u8,
    hyperlink_ids: []const u16,
    used_cols: u16,
    has_truecolor: bool,
};

pub const Scrollback = struct {
    allocator: Allocator,
    cols: u32,
    capacity: u32,
    head: u32 = 0,
    count: u32 = 0,

    cells: []Cell,
    fg_rgb: []?[3]u8,
    bg_rgb: []?[3]u8,
    ul_color_rgb: []?[3]u8,
    hyperlink_ids: []u16,
    used_cols: []u16,
    has_truecolor: []bool,

    const Self = @This();

    pub fn init(allocator: Allocator, capacity: u32, cols: u32) !Self {
        std.debug.assert(capacity > 0);
        std.debug.assert(cols > 0);
        const total: usize = @as(usize, capacity) * @as(usize, cols);

        const cells = try allocator.alloc(Cell, total);
        errdefer allocator.free(cells);
        const fg = try allocator.alloc(?[3]u8, total);
        errdefer allocator.free(fg);
        const bg = try allocator.alloc(?[3]u8, total);
        errdefer allocator.free(bg);
        const ul = try allocator.alloc(?[3]u8, total);
        errdefer allocator.free(ul);
        const hl = try allocator.alloc(u16, total);
        errdefer allocator.free(hl);
        const uc = try allocator.alloc(u16, capacity);
        errdefer allocator.free(uc);
        const tc = try allocator.alloc(bool, capacity);

        @memset(cells, Cell{});
        @memset(fg, null);
        @memset(bg, null);
        @memset(ul, null);
        @memset(hl, 0);
        @memset(uc, 0);
        @memset(tc, false);

        return .{
            .allocator = allocator,
            .cols = cols,
            .capacity = capacity,
            .cells = cells,
            .fg_rgb = fg,
            .bg_rgb = bg,
            .ul_color_rgb = ul,
            .hyperlink_ids = hl,
            .used_cols = uc,
            .has_truecolor = tc,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.fg_rgb);
        self.allocator.free(self.bg_rgb);
        self.allocator.free(self.ul_color_rgb);
        self.allocator.free(self.hyperlink_ids);
        self.allocator.free(self.used_cols);
        self.allocator.free(self.has_truecolor);
    }

    pub fn clear(self: *Self) void {
        self.head = 0;
        self.count = 0;
    }
};

test "Scrollback: init+deinit round-trip" {
    var sb = try Scrollback.init(testing.allocator, 100, 80);
    defer sb.deinit();
    try testing.expectEqual(@as(u32, 100), sb.capacity);
    try testing.expectEqual(@as(u32, 80), sb.cols);
    try testing.expectEqual(@as(u32, 0), sb.count);
    try testing.expectEqual(@as(u32, 0), sb.head);
}

test "Scrollback: clear resets head and count" {
    var sb = try Scrollback.init(testing.allocator, 10, 5);
    defer sb.deinit();
    sb.head = 3;
    sb.count = 5;
    sb.clear();
    try testing.expectEqual(@as(u32, 0), sb.head);
    try testing.expectEqual(@as(u32, 0), sb.count);
}
