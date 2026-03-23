const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Cell = struct {
    char: u21 = ' ',
    fg: u8 = 7,
    bg: u8 = 0,
    attrs: Attrs = .{},

    pub const Attrs = packed struct(u8) {
        bold: bool = false,
        italic: bool = false,
        underline: bool = false,
        reverse: bool = false,
        dim: bool = false,
        wide: bool = false,
        wide_dummy: bool = false,
        _pad: u1 = 0,
    };
};

const default_cell: Cell = .{};

pub const Term = struct {
    const Self = @This();

    allocator: Allocator,
    cols: u32,
    rows: u32,

    cells: []Cell,
    dirty: std.DynamicBitSet,

    // Alternate screen buffer
    alt_cells: ?[]Cell = null,
    alt_dirty: ?std.DynamicBitSet = null,
    is_alt_screen: bool = false,

    // Cursor
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    saved_cursor_x: u32 = 0,
    saved_cursor_y: u32 = 0,

    // Scroll region
    scroll_top: u32 = 0,
    scroll_bottom: u32 = 0,

    // Current drawing state
    current_fg: u8 = 7,
    current_bg: u8 = 0,
    current_attrs: Cell.Attrs = .{},
    current_fg_rgb: ?[3]u8 = null,
    current_bg_rgb: ?[3]u8 = null,

    // TrueColor sparse maps (keyed by cell index)
    fg_rgb_map: std.AutoHashMap(usize, [3]u8),
    bg_rgb_map: std.AutoHashMap(usize, [3]u8),

    // DEC mode flags
    decckm: bool = false,
    decawm: bool = true,
    cursor_visible: bool = true,
    bracketed_paste: bool = false,

    pub fn init(allocator: Allocator, cols: u32, rows: u32) !Self {
        const total = @as(usize, cols) * @as(usize, rows);
        const cells = try allocator.alloc(Cell, total);
        @memset(cells, Cell{});

        const dirty = try std.DynamicBitSet.initEmpty(allocator, total);

        return Self{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .cells = cells,
            .dirty = dirty,
            .scroll_bottom = rows -| 1,
            .fg_rgb_map = std.AutoHashMap(usize, [3]u8).init(allocator),
            .bg_rgb_map = std.AutoHashMap(usize, [3]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
        self.dirty.deinit();
        if (self.alt_cells) |alt| self.allocator.free(alt);
        if (self.alt_dirty != null) {
            self.alt_dirty.?.deinit();
        }
        self.fg_rgb_map.deinit();
        self.bg_rgb_map.deinit();
    }

    fn cellIndex(self: *const Self, x: u32, y: u32) usize {
        return @as(usize, y) * @as(usize, self.cols) + @as(usize, x);
    }

    pub fn getCell(self: *const Self, x: u32, y: u32) *const Cell {
        if (x >= self.cols or y >= self.rows) return &default_cell;
        return &self.cells[self.cellIndex(x, y)];
    }

    pub fn getCellMut(self: *Self, x: u32, y: u32) ?*Cell {
        if (x >= self.cols or y >= self.rows) return null;
        return &self.cells[self.cellIndex(x, y)];
    }

    pub fn setCell(self: *Self, x: u32, y: u32, cell: Cell) void {
        if (x >= self.cols or y >= self.rows) return;
        const idx = self.cellIndex(x, y);
        self.cells[idx] = cell;
        self.dirty.set(idx);
    }

    pub fn isDirty(self: *const Self, x: u32, y: u32) bool {
        return self.dirty.isSet(self.cellIndex(x, y));
    }

    pub fn markDirty(self: *Self, x: u32, y: u32) void {
        if (x >= self.cols or y >= self.rows) return;
        self.dirty.set(self.cellIndex(x, y));
    }

    pub fn hasDirty(self: *const Self) bool {
        const masks = self.dirty.unmanaged.masks;
        const num_masks = (self.dirty.unmanaged.bit_length + @bitSizeOf(usize) - 1) / @bitSizeOf(usize);
        for (masks[0..num_masks]) |m| {
            if (m != 0) return true;
        }
        return false;
    }

    pub fn isRowDirty(self: *const Self, y: u32) bool {
        if (y >= self.rows) return false;
        const start = @as(usize, y) * @as(usize, self.cols);
        const end = start + self.cols;
        const masks = self.dirty.unmanaged.masks;
        const bit_size = @bitSizeOf(usize);

        var word_idx = start / bit_size;
        const word_end = (end + bit_size - 1) / bit_size;
        const start_bit: std.math.Log2Int(usize) = @intCast(start % bit_size);
        const end_bit = end % bit_size;

        if (word_idx == word_end - 1) {
            // Row fits in a single word
            var mask = masks[word_idx];
            if (start_bit > 0) mask &= ~((@as(usize, 1) << start_bit) - 1);
            if (end_bit > 0) mask &= (@as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(end_bit))) - 1;
            return mask != 0;
        }

        // First partial word
        if (start_bit > 0) {
            if (masks[word_idx] & ~((@as(usize, 1) << start_bit) - 1) != 0) return true;
            word_idx += 1;
        }

        // Full words in the middle
        const full_end = if (end_bit > 0) word_end - 1 else word_end;
        for (masks[word_idx..full_end]) |m| {
            if (m != 0) return true;
        }

        // Last partial word
        if (end_bit > 0) {
            if (masks[word_end - 1] & ((@as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(end_bit))) - 1) != 0) return true;
        }

        return false;
    }

    pub fn clearDirty(self: *Self) void {
        const total = @as(usize, self.cols) * @as(usize, self.rows);
        self.dirty.setRangeValue(.{ .start = 0, .end = total }, false);
    }

    pub fn scrollUp(self: *Self, n: u32) void {
        if (n == 0) return;
        const cols: usize = self.cols;
        const top: usize = self.scroll_top;
        const bot: usize = self.scroll_bottom;
        const region_height = bot - top + 1;
        const shift: usize = @min(n, @as(u32, @intCast(region_height)));

        // Move rows up
        const dst_start = top * cols;
        const src_start = (top + shift) * cols;
        const copy_len = (region_height - shift) * cols;
        if (copy_len > 0) {
            std.mem.copyForwards(Cell, self.cells[dst_start .. dst_start + copy_len], self.cells[src_start .. src_start + copy_len]);
        }

        // Clear bottom n rows in scroll region
        const clear_start = (bot + 1 - shift) * cols;
        const clear_end = (bot + 1) * cols;
        @memset(self.cells[clear_start..clear_end], Cell{});

        // Mark entire scroll region dirty
        self.dirty.setRangeValue(.{ .start = top * cols, .end = (bot + 1) * cols }, true);

        // Shift TrueColor entries to match scrolled rows
        self.shiftRgbMapUp(shift);
    }

    pub fn scrollDown(self: *Self, n: u32) void {
        if (n == 0) return;
        const cols: usize = self.cols;
        const top: usize = self.scroll_top;
        const bot: usize = self.scroll_bottom;
        const region_height = bot - top + 1;
        const shift: usize = @min(n, @as(u32, @intCast(region_height)));

        // Move rows down (copy backwards to avoid overlap)
        const copy_rows = region_height - shift;
        if (copy_rows > 0) {
            const src_start = top * cols;
            const dst_start = (top + shift) * cols;
            std.mem.copyBackwards(Cell, self.cells[dst_start .. dst_start + copy_rows * cols], self.cells[src_start .. src_start + copy_rows * cols]);
        }

        // Clear top n rows in scroll region
        const clear_start = top * cols;
        const clear_end = (top + shift) * cols;
        @memset(self.cells[clear_start..clear_end], Cell{});

        // Mark entire scroll region dirty
        self.dirty.setRangeValue(.{ .start = top * cols, .end = (bot + 1) * cols }, true);

        // Shift TrueColor entries to match scrolled rows
        self.shiftRgbMapDown(shift);
    }

    pub fn resize(self: *Self, new_cols: u32, new_rows: u32) !void {
        const new_total = @as(usize, new_cols) * @as(usize, new_rows);
        const new_cells = try self.allocator.alloc(Cell, new_total);
        @memset(new_cells, Cell{});

        // Copy existing content that fits
        const copy_cols: usize = @min(self.cols, new_cols);
        const copy_rows: usize = @min(self.rows, new_rows);
        for (0..copy_rows) |y| {
            const old_start = y * @as(usize, self.cols);
            const new_start = y * @as(usize, new_cols);
            @memcpy(new_cells[new_start .. new_start + copy_cols], self.cells[old_start .. old_start + copy_cols]);
        }

        self.allocator.free(self.cells);
        self.cells = new_cells;

        // Resize dirty bitmap
        self.dirty.deinit();
        self.dirty = try std.DynamicBitSet.initFull(self.allocator, new_total);

        self.cols = new_cols;
        self.rows = new_rows;
        self.scroll_top = 0;
        self.scroll_bottom = new_rows -| 1;

        // Clamp cursor
        self.cursor_x = @min(self.cursor_x, new_cols -| 1);
        self.cursor_y = @min(self.cursor_y, new_rows -| 1);

        // Clear TrueColor maps (indices are invalidated by resize)
        self.clearAllRgb();

        // Resize alt buffer if allocated
        if (self.alt_cells) |alt| {
            self.allocator.free(alt);
            self.alt_cells = try self.allocator.alloc(Cell, new_total);
            @memset(self.alt_cells.?, Cell{});
        }
        if (self.alt_dirty) |*ad| {
            ad.deinit();
            self.alt_dirty = try std.DynamicBitSet.initFull(self.allocator, new_total);
        }
    }

    pub fn switchScreen(self: *Self, alt: bool) !void {
        if (alt == self.is_alt_screen) return;

        const total = @as(usize, self.cols) * @as(usize, self.rows);

        if (alt) {
            // Switch to alt screen
            // Lazy-allocate alt buffer
            if (self.alt_cells == null) {
                self.alt_cells = try self.allocator.alloc(Cell, total);
                @memset(self.alt_cells.?, Cell{});
                self.alt_dirty = try std.DynamicBitSet.initFull(self.allocator, total);
            }
            // Swap main <-> alt
            const tmp = self.cells;
            self.cells = self.alt_cells.?;
            self.alt_cells = tmp;

            const tmp_dirty = self.dirty;
            self.dirty = self.alt_dirty.?;
            self.alt_dirty = tmp_dirty;
        } else {
            // Switch back to main screen
            const tmp = self.cells;
            self.cells = self.alt_cells.?;
            self.alt_cells = tmp;

            const tmp_dirty = self.dirty;
            self.dirty = self.alt_dirty.?;
            self.alt_dirty = tmp_dirty;
        }

        self.is_alt_screen = alt;
        // Mark all dirty on screen switch
        self.dirty.setRangeValue(.{ .start = 0, .end = total }, true);
    }

    pub fn moveCursorTo(self: *Self, x: u32, y: u32) void {
        self.cursor_x = @min(x, self.cols -| 1);
        self.cursor_y = @min(y, self.rows -| 1);
    }

    pub fn moveCursorRel(self: *Self, dx: i32, dy: i32) void {
        const new_x = @as(i64, self.cursor_x) + @as(i64, dx);
        const new_y = @as(i64, self.cursor_y) + @as(i64, dy);
        self.cursor_x = @intCast(@as(u32, @intCast(std.math.clamp(new_x, 0, @as(i64, self.cols) - 1))));
        self.cursor_y = @intCast(@as(u32, @intCast(std.math.clamp(new_y, 0, @as(i64, self.rows) - 1))));
    }

    pub fn eraseDisplay(self: *Self, mode: u8) void {
        switch (mode) {
            0 => {
                // Erase below cursor (from cursor to end)
                const start = self.cellIndex(self.cursor_x, self.cursor_y);
                const total = @as(usize, self.cols) * @as(usize, self.rows);
                @memset(self.cells[start..total], Cell{});
                self.dirty.setRangeValue(.{ .start = start, .end = total }, true);
                self.clearRgbRange(start, total);
            },
            1 => {
                // Erase above cursor (from start to cursor inclusive)
                const end = self.cellIndex(self.cursor_x, self.cursor_y) + 1;
                @memset(self.cells[0..end], Cell{});
                self.dirty.setRangeValue(.{ .start = 0, .end = end }, true);
                self.clearRgbRange(0, end);
            },
            2, 3 => {
                // Erase all
                const total = @as(usize, self.cols) * @as(usize, self.rows);
                @memset(self.cells[0..total], Cell{});
                self.dirty.setRangeValue(.{ .start = 0, .end = total }, true);
                self.clearAllRgb();
            },
            else => {},
        }
    }

    pub fn eraseLine(self: *Self, mode: u8) void {
        const y: usize = self.cursor_y;
        const cols: usize = self.cols;
        const row_start = y * cols;

        switch (mode) {
            0 => {
                // Erase right of cursor (inclusive)
                const start = row_start + @as(usize, self.cursor_x);
                const end = row_start + cols;
                @memset(self.cells[start..end], Cell{});
                self.dirty.setRangeValue(.{ .start = start, .end = end }, true);
                self.clearRgbRange(start, end);
            },
            1 => {
                // Erase left of cursor (inclusive)
                const end = row_start + @as(usize, self.cursor_x) + 1;
                @memset(self.cells[row_start..end], Cell{});
                self.dirty.setRangeValue(.{ .start = row_start, .end = end }, true);
                self.clearRgbRange(row_start, end);
            },
            2 => {
                // Erase entire line
                const end = row_start + cols;
                @memset(self.cells[row_start..end], Cell{});
                self.dirty.setRangeValue(.{ .start = row_start, .end = end }, true);
                self.clearRgbRange(row_start, end);
            },
            else => {},
        }
    }

    pub fn insertNewline(self: *Self) void {
        if (self.cursor_y == self.scroll_bottom) {
            self.scrollUp(1);
        } else if (self.cursor_y < self.rows - 1) {
            self.cursor_y += 1;
        }
    }

    pub fn carriageReturn(self: *Self) void {
        self.cursor_x = 0;
    }

    pub fn setScrollRegion(self: *Self, top: u32, bottom: u32) void {
        self.scroll_top = @min(top, self.rows -| 1);
        self.scroll_bottom = @min(bottom, self.rows -| 1);
        if (self.scroll_top > self.scroll_bottom) {
            self.scroll_top = 0;
            self.scroll_bottom = self.rows -| 1;
        }
    }

    pub fn insertLines(self: *Self, n: u32) void {
        if (self.cursor_y < self.scroll_top or self.cursor_y > self.scroll_bottom) return;
        const count = @min(n, self.scroll_bottom - self.cursor_y + 1);
        if (count == 0) return;
        const cols: usize = self.cols;
        const bot: usize = self.scroll_bottom;
        const cy: usize = self.cursor_y;

        // Shift lines down within [cursor_y, scroll_bottom]
        const copy_rows = bot - cy + 1 - count;
        if (copy_rows > 0) {
            const src_start = cy * cols;
            const dst_start = (cy + count) * cols;
            std.mem.copyBackwards(Cell, self.cells[dst_start .. dst_start + copy_rows * cols], self.cells[src_start .. src_start + copy_rows * cols]);
        }

        // Clear inserted lines
        const clear_start = cy * cols;
        const clear_end = (cy + count) * cols;
        @memset(self.cells[clear_start..clear_end], Cell{});

        // Mark scroll region dirty
        self.dirty.setRangeValue(.{ .start = cy * cols, .end = (bot + 1) * cols }, true);
        self.clearAllRgb();
    }

    pub fn deleteLines(self: *Self, n: u32) void {
        if (self.cursor_y < self.scroll_top or self.cursor_y > self.scroll_bottom) return;
        const count = @min(n, self.scroll_bottom - self.cursor_y + 1);
        if (count == 0) return;
        const cols: usize = self.cols;
        const bot: usize = self.scroll_bottom;
        const cy: usize = self.cursor_y;

        // Shift lines up within [cursor_y, scroll_bottom]
        const copy_rows = bot - cy + 1 - count;
        if (copy_rows > 0) {
            const src_start = (cy + count) * cols;
            const dst_start = cy * cols;
            std.mem.copyForwards(Cell, self.cells[dst_start .. dst_start + copy_rows * cols], self.cells[src_start .. src_start + copy_rows * cols]);
        }

        // Clear bottom lines in region
        const clear_start = (bot + 1 - count) * cols;
        const clear_end = (bot + 1) * cols;
        @memset(self.cells[clear_start..clear_end], Cell{});

        // Mark scroll region dirty
        self.dirty.setRangeValue(.{ .start = cy * cols, .end = (bot + 1) * cols }, true);
        self.clearAllRgb();
    }

    pub fn deleteChars(self: *Self, n: u32) void {
        if (self.cursor_x >= self.cols or self.cursor_y >= self.rows) return;
        const cols: usize = self.cols;
        const cx: usize = self.cursor_x;
        const cy: usize = self.cursor_y;
        const remaining = cols - cx;
        const count = @min(n, @as(u32, @intCast(remaining)));
        const row_start = cy * cols;

        // Shift characters left
        const copy_len = remaining - count;
        if (copy_len > 0) {
            std.mem.copyForwards(Cell, self.cells[row_start + cx .. row_start + cx + copy_len], self.cells[row_start + cx + count .. row_start + cx + count + copy_len]);
        }

        // Clear rightmost characters
        const clear_start = row_start + cols - count;
        @memset(self.cells[clear_start .. row_start + cols], Cell{});

        self.dirty.setRangeValue(.{ .start = row_start + cx, .end = row_start + cols }, true);
        self.clearRgbRange(row_start + cx, row_start + cols);
    }

    pub fn insertChars(self: *Self, n: u32) void {
        if (self.cursor_x >= self.cols or self.cursor_y >= self.rows) return;
        const cols: usize = self.cols;
        const cx: usize = self.cursor_x;
        const cy: usize = self.cursor_y;
        const remaining = cols - cx;
        const count = @min(n, @as(u32, @intCast(remaining)));
        const row_start = cy * cols;

        // Shift characters right
        const copy_len = remaining - count;
        if (copy_len > 0) {
            std.mem.copyBackwards(Cell, self.cells[row_start + cx + count .. row_start + cx + count + copy_len], self.cells[row_start + cx .. row_start + cx + copy_len]);
        }

        // Clear inserted characters
        @memset(self.cells[row_start + cx .. row_start + cx + count], Cell{});

        self.dirty.setRangeValue(.{ .start = row_start + cx, .end = row_start + cols }, true);
        self.clearRgbRange(row_start + cx, row_start + cols);
    }

    pub fn eraseChars(self: *Self, n: u32) void {
        if (self.cursor_x >= self.cols or self.cursor_y >= self.rows) return;
        const cols: usize = self.cols;
        const cx: usize = self.cursor_x;
        const cy: usize = self.cursor_y;
        const remaining = cols - cx;
        const count: usize = @min(n, @as(u32, @intCast(remaining)));
        const row_start = cy * cols;

        @memset(self.cells[row_start + cx .. row_start + cx + count], Cell{});

        self.dirty.setRangeValue(.{ .start = row_start + cx, .end = row_start + cx + count }, true);
        self.clearRgbRange(row_start + cx, row_start + cx + count);
    }

    /// Remove TrueColor entries for cell indices in [start, end).
    fn clearRgbRange(self: *Self, start: usize, end: usize) void {
        if (self.fg_rgb_map.count() == 0 and self.bg_rgb_map.count() == 0) return;
        var idx = start;
        while (idx < end) : (idx += 1) {
            _ = self.fg_rgb_map.remove(idx);
            _ = self.bg_rgb_map.remove(idx);
        }
    }

    /// Clear all TrueColor entries.
    fn clearAllRgb(self: *Self) void {
        self.fg_rgb_map.clearRetainingCapacity();
        self.bg_rgb_map.clearRetainingCapacity();
    }

    /// Shift RGB map entries up by `shift` rows within scroll region.
    fn shiftRgbMapUp(self: *Self, shift: usize) void {
        if (self.fg_rgb_map.count() == 0 and self.bg_rgb_map.count() == 0) return;
        shiftOneRgbMap(&self.fg_rgb_map, self.allocator, self.cols, self.scroll_top, self.scroll_bottom, shift, true);
        shiftOneRgbMap(&self.bg_rgb_map, self.allocator, self.cols, self.scroll_top, self.scroll_bottom, shift, true);
    }

    /// Shift RGB map entries down by `shift` rows within scroll region.
    fn shiftRgbMapDown(self: *Self, shift: usize) void {
        if (self.fg_rgb_map.count() == 0 and self.bg_rgb_map.count() == 0) return;
        shiftOneRgbMap(&self.fg_rgb_map, self.allocator, self.cols, self.scroll_top, self.scroll_bottom, shift, false);
        shiftOneRgbMap(&self.bg_rgb_map, self.allocator, self.cols, self.scroll_top, self.scroll_bottom, shift, false);
    }

    fn shiftOneRgbMap(
        map: *std.AutoHashMap(usize, [3]u8),
        alloc: Allocator,
        cols: u32,
        scroll_top: u32,
        scroll_bottom: u32,
        shift: usize,
        comptime up: bool,
    ) void {
        const cols_z: usize = cols;
        const top: usize = scroll_top;
        const bot: usize = scroll_bottom;

        var new_map = std.AutoHashMap(usize, [3]u8).init(alloc);
        var iter = map.iterator();
        while (iter.next()) |entry| {
            const idx = entry.key_ptr.*;
            const row = idx / cols_z;
            const col = idx % cols_z;

            if (row < top or row > bot) {
                // Outside scroll region: keep
                new_map.put(idx, entry.value_ptr.*) catch {};
            } else if (up) {
                if (row >= top + shift) {
                    new_map.put((row - shift) * cols_z + col, entry.value_ptr.*) catch {};
                }
            } else {
                if (row + shift <= bot) {
                    new_map.put((row + shift) * cols_z + col, entry.value_ptr.*) catch {};
                }
            }
        }
        map.deinit();
        map.* = new_map;
    }

    // TrueColor helpers
    pub fn setFgRgb(self: *Self, x: u32, y: u32, rgb: [3]u8) !void {
        try self.fg_rgb_map.put(self.cellIndex(x, y), rgb);
    }

    pub fn getFgRgb(self: *const Self, x: u32, y: u32) ?[3]u8 {
        return self.fg_rgb_map.get(self.cellIndex(x, y));
    }

    pub fn setBgRgb(self: *Self, x: u32, y: u32, rgb: [3]u8) !void {
        try self.bg_rgb_map.put(self.cellIndex(x, y), rgb);
    }

    pub fn getBgRgb(self: *const Self, x: u32, y: u32) ?[3]u8 {
        return self.bg_rgb_map.get(self.cellIndex(x, y));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Term: init creates grid with default cells" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    const cell = term.getCell(0, 0);
    try testing.expectEqual(@as(u21, ' '), cell.char);
    try testing.expectEqual(@as(u8, 7), cell.fg);
}

test "Term: setCell marks dirty" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    try testing.expect(!term.isDirty(5, 3));
    term.setCell(5, 3, .{ .char = 'X', .fg = 1, .bg = 0 });
    try testing.expect(term.isDirty(5, 3));
}

test "Term: clearDirty resets all bits" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'A' });
    term.clearDirty();
    try testing.expect(!term.isDirty(0, 0));
}

test "Term: scrollUp moves rows" {
    var term = try Term.init(testing.allocator, 80, 3);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'A' });
    term.setCell(0, 1, .{ .char = 'B' });
    term.setCell(0, 2, .{ .char = 'C' });
    term.scrollUp(1);
    try testing.expectEqual(@as(u21, 'B'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'C'), term.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 2).char);
}

test "Term: alternate screen switch preserves main" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'M' });
    try term.switchScreen(true);
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 0).char);
    term.setCell(0, 0, .{ .char = 'A' });
    try term.switchScreen(false);
    try testing.expectEqual(@as(u21, 'M'), term.getCell(0, 0).char);
}

test "Term: resize changes dimensions" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    try term.resize(120, 40);
    try testing.expectEqual(@as(u32, 120), term.cols);
    try testing.expectEqual(@as(u32, 40), term.rows);
}

test "Term: moveCursorTo clamps to bounds" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    term.moveCursorTo(100, 50);
    try testing.expectEqual(@as(u32, 79), term.cursor_x);
    try testing.expectEqual(@as(u32, 23), term.cursor_y);
}

test "Term: eraseDisplay clears all cells" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    term.setCell(5, 5, .{ .char = 'X' });
    term.eraseDisplay(2);
    try testing.expectEqual(@as(u21, ' '), term.getCell(5, 5).char);
}

test "Term: insertNewline scrolls at bottom" {
    var term = try Term.init(testing.allocator, 80, 3);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'A' });
    term.setCell(0, 1, .{ .char = 'B' });
    term.setCell(0, 2, .{ .char = 'C' });
    term.cursor_y = 2;
    term.insertNewline();
    // Row 0 should now have 'B' (scrolled up)
    try testing.expectEqual(@as(u21, 'B'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'C'), term.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 2).char);
    try testing.expectEqual(@as(u32, 2), term.cursor_y);
}

test "Term: resize preserves existing content" {
    var term = try Term.init(testing.allocator, 10, 5);
    defer term.deinit();
    term.setCell(3, 2, .{ .char = 'Z' });
    try term.resize(20, 10);
    try testing.expectEqual(@as(u21, 'Z'), term.getCell(3, 2).char);
}

test "Term: scrollUp within scroll region" {
    var term = try Term.init(testing.allocator, 80, 5);
    defer term.deinit();
    // Set content in all rows
    term.setCell(0, 0, .{ .char = '0' });
    term.setCell(0, 1, .{ .char = '1' });
    term.setCell(0, 2, .{ .char = '2' });
    term.setCell(0, 3, .{ .char = '3' });
    term.setCell(0, 4, .{ .char = '4' });
    // Set scroll region to rows 1..3
    term.setScrollRegion(1, 3);
    term.scrollUp(1);
    // Row 0 unchanged
    try testing.expectEqual(@as(u21, '0'), term.getCell(0, 0).char);
    // Rows 1-3 shifted up within region
    try testing.expectEqual(@as(u21, '2'), term.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '3'), term.getCell(0, 2).char);
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 3).char);
    // Row 4 unchanged
    try testing.expectEqual(@as(u21, '4'), term.getCell(0, 4).char);
}

test "Term: scrollDown within scroll region" {
    var term = try Term.init(testing.allocator, 80, 5);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = '0' });
    term.setCell(0, 1, .{ .char = '1' });
    term.setCell(0, 2, .{ .char = '2' });
    term.setCell(0, 3, .{ .char = '3' });
    term.setCell(0, 4, .{ .char = '4' });
    term.setScrollRegion(1, 3);
    term.scrollDown(1);
    try testing.expectEqual(@as(u21, '0'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, '1'), term.getCell(0, 2).char);
    try testing.expectEqual(@as(u21, '2'), term.getCell(0, 3).char);
    try testing.expectEqual(@as(u21, '4'), term.getCell(0, 4).char);
}

test "Term: eraseDisplay mode 0 (below cursor)" {
    var term = try Term.init(testing.allocator, 10, 3);
    defer term.deinit();
    // Fill all cells
    for (0..3) |y| {
        for (0..10) |x| {
            term.setCell(@intCast(x), @intCast(y), .{ .char = 'X' });
        }
    }
    term.clearDirty();
    term.moveCursorTo(5, 1);
    term.eraseDisplay(0);
    // Before cursor: still 'X'
    try testing.expectEqual(@as(u21, 'X'), term.getCell(4, 1).char);
    // At cursor: cleared
    try testing.expectEqual(@as(u21, ' '), term.getCell(5, 1).char);
    // After cursor: cleared
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 2).char);
    // Row 0: untouched
    try testing.expectEqual(@as(u21, 'X'), term.getCell(0, 0).char);
}

test "Term: eraseDisplay mode 1 (above cursor)" {
    var term = try Term.init(testing.allocator, 10, 3);
    defer term.deinit();
    for (0..3) |y| {
        for (0..10) |x| {
            term.setCell(@intCast(x), @intCast(y), .{ .char = 'X' });
        }
    }
    term.clearDirty();
    term.moveCursorTo(5, 1);
    term.eraseDisplay(1);
    // At and before cursor: cleared
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, ' '), term.getCell(5, 1).char);
    // After cursor: still 'X'
    try testing.expectEqual(@as(u21, 'X'), term.getCell(6, 1).char);
    try testing.expectEqual(@as(u21, 'X'), term.getCell(0, 2).char);
}

test "Term: eraseLine all three modes" {
    // Mode 0: right of cursor
    {
        var term = try Term.init(testing.allocator, 10, 1);
        defer term.deinit();
        for (0..10) |x| {
            term.setCell(@intCast(x), 0, .{ .char = 'X' });
        }
        term.moveCursorTo(5, 0);
        term.eraseLine(0);
        try testing.expectEqual(@as(u21, 'X'), term.getCell(4, 0).char);
        try testing.expectEqual(@as(u21, ' '), term.getCell(5, 0).char);
        try testing.expectEqual(@as(u21, ' '), term.getCell(9, 0).char);
    }
    // Mode 1: left of cursor
    {
        var term = try Term.init(testing.allocator, 10, 1);
        defer term.deinit();
        for (0..10) |x| {
            term.setCell(@intCast(x), 0, .{ .char = 'X' });
        }
        term.moveCursorTo(5, 0);
        term.eraseLine(1);
        try testing.expectEqual(@as(u21, ' '), term.getCell(0, 0).char);
        try testing.expectEqual(@as(u21, ' '), term.getCell(5, 0).char);
        try testing.expectEqual(@as(u21, 'X'), term.getCell(6, 0).char);
    }
    // Mode 2: entire line
    {
        var term = try Term.init(testing.allocator, 10, 1);
        defer term.deinit();
        for (0..10) |x| {
            term.setCell(@intCast(x), 0, .{ .char = 'X' });
        }
        term.moveCursorTo(5, 0);
        term.eraseLine(2);
        try testing.expectEqual(@as(u21, ' '), term.getCell(0, 0).char);
        try testing.expectEqual(@as(u21, ' '), term.getCell(9, 0).char);
    }
}

test "Term: TrueColor sparse map" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    // No RGB by default
    try testing.expectEqual(@as(?[3]u8, null), term.getFgRgb(5, 5));
    // Set and retrieve
    try term.setFgRgb(5, 5, .{ 255, 128, 0 });
    const rgb = term.getFgRgb(5, 5);
    try testing.expect(rgb != null);
    try testing.expectEqual(@as(u8, 255), rgb.?[0]);
    try testing.expectEqual(@as(u8, 128), rgb.?[1]);
    try testing.expectEqual(@as(u8, 0), rgb.?[2]);
}

test "Term: isRowDirty with clean and dirty rows" {
    var term = try Term.init(testing.allocator, 80, 5);
    defer term.deinit();
    term.clearDirty();
    // All rows should be clean
    for (0..5) |y| {
        try testing.expect(!term.isRowDirty(@intCast(y)));
    }
    // Mark one cell dirty in row 2
    term.markDirty(10, 2);
    try testing.expect(!term.isRowDirty(0));
    try testing.expect(!term.isRowDirty(1));
    try testing.expect(term.isRowDirty(2));
    try testing.expect(!term.isRowDirty(3));
    try testing.expect(!term.isRowDirty(4));
}

test "Term: isRowDirty with word-boundary-aligned columns" {
    // 64 cols = exactly 1 word per row (on 64-bit)
    var term = try Term.init(testing.allocator, 64, 3);
    defer term.deinit();
    term.clearDirty();
    try testing.expect(!term.isRowDirty(0));
    term.markDirty(0, 0);
    try testing.expect(term.isRowDirty(0));
    try testing.expect(!term.isRowDirty(1));
}

test "Term: isRowDirty with small column count" {
    // 5 cols — row fits in a single word, partial bits
    var term = try Term.init(testing.allocator, 5, 3);
    defer term.deinit();
    term.clearDirty();
    term.markDirty(4, 1); // last col of row 1
    try testing.expect(!term.isRowDirty(0));
    try testing.expect(term.isRowDirty(1));
    try testing.expect(!term.isRowDirty(2));
}

test "Term: isRowDirty spanning multiple words" {
    // 200 cols — spans ~3+ words per row on 64-bit
    var term = try Term.init(testing.allocator, 200, 2);
    defer term.deinit();
    term.clearDirty();
    try testing.expect(!term.isRowDirty(0));
    try testing.expect(!term.isRowDirty(1));
    // Dirty a cell in the middle of row 1 (will be in a middle word)
    term.markDirty(130, 1);
    try testing.expect(!term.isRowDirty(0));
    try testing.expect(term.isRowDirty(1));
}

test "Term: isRowDirty first and last cell" {
    var term = try Term.init(testing.allocator, 80, 2);
    defer term.deinit();
    term.clearDirty();
    // First cell of row 0
    term.markDirty(0, 0);
    try testing.expect(term.isRowDirty(0));
    try testing.expect(!term.isRowDirty(1));
    term.clearDirty();
    // Last cell of row 1
    term.markDirty(79, 1);
    try testing.expect(!term.isRowDirty(0));
    try testing.expect(term.isRowDirty(1));
}
