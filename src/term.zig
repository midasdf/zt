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
    row_map: []u32, // row_map[logical_row] = physical_row
    dirty: std.DynamicBitSet, // indexed by logical position (y * cols + x)
    dirty_flag: bool = false, // O(1) hasDirty check
    all_dirty: bool = false, // true when entire screen is known dirty (skip per-cell checks)

    // Alternate screen buffer
    alt_cells: ?[]Cell = null,
    alt_row_map: ?[]u32 = null,
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
    scroll_row_shift: i32 = 0,
    scroll_shift_top: u32 = 0,
    scroll_shift_bot: u32 = 0,

    // Current drawing state
    current_fg: u8 = 7,
    current_bg: u8 = 0,
    current_attrs: Cell.Attrs = .{},
    current_fg_rgb: ?[3]u8 = null,
    current_bg_rgb: ?[3]u8 = null,

    // TrueColor flat arrays (indexed by physical cell index, null = no override)
    fg_rgb: []?[3]u8,
    bg_rgb: []?[3]u8,

    // Last printed graphic character (for REP / CSI b)
    last_printed_char: u21 = 0,

    // DEC mode flags
    decckm: bool = false,
    decawm: bool = true,
    cursor_visible: bool = true,
    bracketed_paste: bool = false,
    has_truecolor_cells: bool = false,

    pub fn init(allocator: Allocator, cols: u32, rows: u32) !Self {
        const total = @as(usize, cols) * @as(usize, rows);
        const cells = try allocator.alloc(Cell, total);
        @memset(cells, Cell{});

        const row_map = try allocator.alloc(u32, rows);
        for (0..rows) |i| row_map[i] = @intCast(i);

        const dirty = try std.DynamicBitSet.initEmpty(allocator, total);

        const fg_rgb = try allocator.alloc(?[3]u8, total);
        @memset(fg_rgb, null);
        const bg_rgb = try allocator.alloc(?[3]u8, total);
        @memset(bg_rgb, null);

        return Self{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .cells = cells,
            .row_map = row_map,
            .dirty = dirty,
            .scroll_bottom = rows -| 1,
            .fg_rgb = fg_rgb,
            .bg_rgb = bg_rgb,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.row_map);
        self.dirty.deinit();
        if (self.alt_cells) |alt| self.allocator.free(alt);
        if (self.alt_row_map) |arm| self.allocator.free(arm);
        if (self.alt_dirty != null) {
            self.alt_dirty.?.deinit();
        }
        self.allocator.free(self.fg_rgb);
        self.allocator.free(self.bg_rgb);
    }

    /// Physical cell index via row_map indirection
    inline fn cellIndex(self: *const Self, x: u32, y: u32) usize {
        return @as(usize, self.row_map[y]) * @as(usize, self.cols) + @as(usize, x);
    }

    /// Logical index for dirty bitmap (no row_map)
    inline fn dirtyIndex(_: *const Self, x: u32, y: u32, cols: u32) usize {
        return @as(usize, y) * @as(usize, cols) + @as(usize, x);
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
        const phys_idx = self.cellIndex(x, y);
        self.cells[phys_idx] = cell;
        self.dirty.set(self.dirtyIndex(x, y, self.cols));
        self.dirty_flag = true;
        self.fg_rgb[phys_idx] = null;
        self.bg_rgb[phys_idx] = null;
    }

    pub fn isDirty(self: *const Self, x: u32, y: u32) bool {
        return self.dirty.isSet(self.dirtyIndex(x, y, self.cols));
    }

    pub fn markDirty(self: *Self, x: u32, y: u32) void {
        if (x >= self.cols or y >= self.rows) return;
        self.dirty.set(self.dirtyIndex(x, y, self.cols));
        self.dirty_flag = true;
    }

    pub fn hasDirty(self: *const Self) bool {
        return self.dirty_flag;
    }

    /// Returns true if all cells are known to be dirty (avoids per-cell checks)
    pub fn isAllDirty(self: *const Self) bool {
        return self.all_dirty;
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
            var mask = masks[word_idx];
            if (start_bit > 0) mask &= ~((@as(usize, 1) << start_bit) - 1);
            if (end_bit > 0) mask &= (@as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(end_bit))) - 1;
            return mask != 0;
        }

        if (start_bit > 0) {
            if (masks[word_idx] & ~((@as(usize, 1) << start_bit) - 1) != 0) return true;
            word_idx += 1;
        }

        const full_end = if (end_bit > 0) word_end - 1 else word_end;
        for (masks[word_idx..full_end]) |m| {
            if (m != 0) return true;
        }

        if (end_bit > 0) {
            if (masks[word_end - 1] & ((@as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(end_bit))) - 1) != 0) return true;
        }

        return false;
    }

    pub fn clearDirty(self: *Self) void {
        // Direct memset on bitmask array — faster than setRangeValue's word-by-word loop
        const total = @as(usize, self.cols) * @as(usize, self.rows);
        const bit_size = @bitSizeOf(usize);
        const word_count = (total + bit_size - 1) / bit_size;
        @memset(self.dirty.unmanaged.masks[0..word_count], 0);
        self.dirty_flag = false;
        self.all_dirty = false;
    }

    /// Mark a range of logical cells dirty and set the O(1) flag
    pub inline fn markDirtyRange(self: *Self, range: std.bit_set.Range) void {
        if (self.all_dirty) return; // Already fully dirty, skip redundant bitset ops
        self.dirty.setRangeValue(range, true);
        self.dirty_flag = true;
    }

    pub fn scrollUp(self: *Self, n: u32) void {
        if (n == 0) return;
        const cols: usize = self.cols;
        const top: usize = self.scroll_top;
        const bot: usize = self.scroll_bottom;
        const region_height = bot - top + 1;
        const shift: usize = @min(n, @as(u32, @intCast(region_height)));

        // Clear recycled rows (top `shift` rows become new bottom rows)
        for (0..shift) |s| {
            const phys = self.row_map[top + s];
            @memset(self.cells[phys * cols .. (phys + 1) * cols], Cell{});
            if (self.has_truecolor_cells) self.clearRgbRow(phys);
        }

        // Rotate row_map: moves top rows to bottom in one pass
        std.mem.rotate(u32, self.row_map[top .. bot + 1], shift);

        // Accumulate scroll shift for pixel buffer memmove.
        if (self.scroll_shift_top != @as(u32, @intCast(top)) or self.scroll_shift_bot != @as(u32, @intCast(bot))) {
            // Scroll region changed — reset accumulator to avoid incorrect memmove
            self.scroll_row_shift = 0;
        }
        self.scroll_row_shift += @as(i32, @intCast(shift));
        self.scroll_shift_top = @intCast(top);
        self.scroll_shift_bot = @intCast(bot);

        // Dirty marking strategy:
        // - Full-screen scroll: always set all_dirty (guarantees correctness
        //   even if memmove is skipped due to double-buffer sync issues)
        // - Partial scroll region (DECSTBM): use memmove for non-saturated,
        //   full-region dirty for saturated
        if (top == 0 and bot + 1 == self.rows) {
            if (!self.all_dirty) {
                self.markDirtyRange(.{ .start = 0, .end = (bot + 1) * cols });
                self.all_dirty = true;
            }
        } else {
            const abs_shift: u32 = @intCast(if (self.scroll_row_shift >= 0) self.scroll_row_shift else -self.scroll_row_shift);
            if (abs_shift >= region_height) {
                self.markDirtyRange(.{ .start = top * cols, .end = (bot + 1) * cols });
            } else {
                for (0..shift) |s| {
                    const row = bot + 1 - shift + s;
                    self.markDirtyRange(.{ .start = row * cols, .end = (row + 1) * cols });
                }
            }
        }
    }

    pub fn scrollDown(self: *Self, n: u32) void {
        if (n == 0) return;
        const cols: usize = self.cols;
        const top: usize = self.scroll_top;
        const bot: usize = self.scroll_bottom;
        const region_height = bot - top + 1;
        const shift: usize = @min(n, @as(u32, @intCast(region_height)));

        // Clear recycled rows (bottom `shift` rows become new top rows)
        for (0..shift) |s| {
            const phys = self.row_map[bot - s];
            @memset(self.cells[phys * cols .. (phys + 1) * cols], Cell{});
            if (self.has_truecolor_cells) self.clearRgbRow(phys);
        }

        // Rotate row_map: moves bottom rows to top in one pass
        std.mem.rotate(u32, self.row_map[top .. bot + 1], region_height - shift);

        // Accumulate scroll shift (negative = scroll down)
        if (self.scroll_shift_top != @as(u32, @intCast(top)) or self.scroll_shift_bot != @as(u32, @intCast(bot))) {
            self.scroll_row_shift = 0;
        }
        self.scroll_row_shift -= @as(i32, @intCast(shift));
        self.scroll_shift_top = @intCast(top);
        self.scroll_shift_bot = @intCast(bot);

        if (top == 0 and bot + 1 == self.rows) {
            if (!self.all_dirty) {
                self.markDirtyRange(.{ .start = 0, .end = (bot + 1) * cols });
                self.all_dirty = true;
            }
        } else {
            const abs_shift: u32 = @intCast(if (self.scroll_row_shift >= 0) self.scroll_row_shift else -self.scroll_row_shift);
            if (abs_shift >= region_height) {
                self.markDirtyRange(.{ .start = top * cols, .end = (bot + 1) * cols });
            } else {
                for (0..shift) |s| {
                    const row = top + s;
                    self.markDirtyRange(.{ .start = row * cols, .end = (row + 1) * cols });
                }
            }
        }
    }

    pub fn resize(self: *Self, new_cols: u32, new_rows: u32) !void {
        const new_total = @as(usize, new_cols) * @as(usize, new_rows);
        const new_cells = try self.allocator.alloc(Cell, new_total);
        @memset(new_cells, Cell{});

        const new_row_map = try self.allocator.alloc(u32, new_rows);
        for (0..new_rows) |i| new_row_map[i] = @intCast(i);

        // Copy existing content (logical row order → identity physical order)
        const copy_cols: usize = @min(self.cols, new_cols);
        const copy_rows: usize = @min(self.rows, new_rows);
        for (0..copy_rows) |y| {
            const old_phys = self.row_map[y];
            const old_start = old_phys * @as(usize, self.cols);
            const new_start = y * @as(usize, new_cols);
            @memcpy(new_cells[new_start .. new_start + copy_cols], self.cells[old_start .. old_start + copy_cols]);
        }

        self.allocator.free(self.cells);
        self.allocator.free(self.row_map);
        self.cells = new_cells;
        self.row_map = new_row_map;

        // Resize dirty bitmap
        self.dirty.deinit();
        self.dirty = try std.DynamicBitSet.initFull(self.allocator, new_total);

        self.cols = new_cols;
        self.rows = new_rows;
        self.scroll_top = 0;
        self.scroll_bottom = new_rows -| 1;
        self.scroll_row_shift = 0;

        // Clamp cursor
        self.cursor_x = @min(self.cursor_x, new_cols -| 1);
        self.cursor_y = @min(self.cursor_y, new_rows -| 1);

        // Resize TrueColor arrays (physical indices invalidated)
        self.allocator.free(self.fg_rgb);
        self.allocator.free(self.bg_rgb);
        self.fg_rgb = try self.allocator.alloc(?[3]u8, new_total);
        @memset(self.fg_rgb, null);
        self.bg_rgb = try self.allocator.alloc(?[3]u8, new_total);
        @memset(self.bg_rgb, null);

        // Resize alt buffer if allocated
        if (self.alt_cells) |alt| {
            self.allocator.free(alt);
            self.alt_cells = try self.allocator.alloc(Cell, new_total);
            @memset(self.alt_cells.?, Cell{});
        }
        if (self.alt_row_map) |arm| {
            self.allocator.free(arm);
            self.alt_row_map = try self.allocator.alloc(u32, new_rows);
            for (0..new_rows) |i| self.alt_row_map.?[i] = @intCast(i);
        }
        if (self.alt_dirty) |*ad| {
            ad.deinit();
            self.alt_dirty = try std.DynamicBitSet.initFull(self.allocator, new_total);
        }
    }

    pub fn switchScreen(self: *Self, alt: bool) !void {
        if (alt == self.is_alt_screen) return;
        self.scroll_row_shift = 0;

        const total = @as(usize, self.cols) * @as(usize, self.rows);

        if (alt) {
            // Lazy-allocate alt buffer
            if (self.alt_cells == null) {
                self.alt_cells = try self.allocator.alloc(Cell, total);
                @memset(self.alt_cells.?, Cell{});
                self.alt_row_map = try self.allocator.alloc(u32, self.rows);
                for (0..self.rows) |i| self.alt_row_map.?[i] = @intCast(i);
                self.alt_dirty = try std.DynamicBitSet.initFull(self.allocator, total);
            }
            // Swap main <-> alt
            const tmp_cells = self.cells;
            self.cells = self.alt_cells.?;
            self.alt_cells = tmp_cells;

            const tmp_rm = self.row_map;
            self.row_map = self.alt_row_map.?;
            self.alt_row_map = tmp_rm;

            const tmp_dirty = self.dirty;
            self.dirty = self.alt_dirty.?;
            self.alt_dirty = tmp_dirty;
        } else {
            // Swap back
            const tmp_cells = self.cells;
            self.cells = self.alt_cells.?;
            self.alt_cells = tmp_cells;

            const tmp_rm = self.row_map;
            self.row_map = self.alt_row_map.?;
            self.alt_row_map = tmp_rm;

            const tmp_dirty = self.dirty;
            self.dirty = self.alt_dirty.?;
            self.alt_dirty = tmp_dirty;
        }

        self.is_alt_screen = alt;
        self.markDirtyRange(.{ .start = 0, .end = total });
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

    /// Fix wide character boundaries at the edges of an erase/delete range.
    fn fixWideBoundaries(self: *Self, logical_start: usize, logical_end: usize) void {
        const cols: usize = self.cols;
        // Check start: if it's a wide_dummy, clear the wide cell to its left
        if (logical_start > 0 and logical_start < @as(usize, self.rows) * cols) {
            const sy = @as(u32, @intCast(logical_start / cols));
            const sx = @as(u32, @intCast(logical_start % cols));
            if (self.getCell(sx, sy).attrs.wide_dummy and sx > 0) {
                self.setCell(sx - 1, sy, Cell{});
            }
        }
        // Check end: if it points at a wide_dummy, clear it
        if (logical_end < @as(usize, self.rows) * cols) {
            const ey = @as(u32, @intCast(logical_end / cols));
            const ex = @as(u32, @intCast(logical_end % cols));
            if (self.getCell(ex, ey).attrs.wide_dummy) {
                self.setCell(ex, ey, Cell{});
            }
        }
        // Check end-1: if last cell in range is wide, clear the dummy after it
        if (logical_end > 0 and logical_end <= @as(usize, self.rows) * cols) {
            const ly = @as(u32, @intCast((logical_end - 1) / cols));
            const lx = @as(u32, @intCast((logical_end - 1) % cols));
            if (self.getCell(lx, ly).attrs.wide) {
                const dx = lx + 1;
                if (dx < self.cols) self.setCell(dx, ly, Cell{});
            }
        }
    }

    pub fn eraseDisplay(self: *Self, mode: u8) void {
        const cols: usize = self.cols;
        switch (mode) {
            0 => {
                const start_x = self.cursor_x;
                const start_y = self.cursor_y;
                self.fixWideBoundaries(start_y * cols + start_x, @as(usize, self.rows) * cols);
                // Clear from cursor to end
                for (start_y..self.rows) |y| {
                    const phys = self.row_map[y];
                    const from: usize = if (y == start_y) start_x else 0;
                    @memset(self.cells[phys * cols + from .. (phys + 1) * cols], Cell{});
                }
                const logical_start = start_y * cols + start_x;
                const total = @as(usize, self.rows) * cols;
                self.markDirtyRange(.{ .start = logical_start, .end = total });
                self.clearRgbRange(start_y, self.rows, 0);
            },
            1 => {
                const end_x = self.cursor_x;
                const end_y = self.cursor_y;
                self.fixWideBoundaries(0, end_y * cols + end_x + 1);
                // Clear from start to cursor inclusive
                for (0..end_y + 1) |y| {
                    const phys = self.row_map[y];
                    const to: usize = if (y == end_y) end_x + 1 else cols;
                    @memset(self.cells[phys * cols .. phys * cols + to], Cell{});
                }
                self.markDirtyRange(.{ .start = 0, .end = end_y * cols + end_x + 1 });
                self.clearRgbRange(0, end_y + 1, 0);
            },
            2, 3 => {
                // Erase all — reset row_map to identity and memset entire array
                const total = @as(usize, self.cols) * @as(usize, self.rows);
                @memset(self.cells[0..total], Cell{});
                for (0..self.rows) |i| self.row_map[i] = @intCast(i);
                self.markDirtyRange(.{ .start = 0, .end = total });
                self.clearAllRgb();
                self.has_truecolor_cells = false;
                self.scroll_row_shift = 0;
            },
            else => {},
        }
    }

    pub fn eraseLine(self: *Self, mode: u8) void {
        const y = self.cursor_y;
        const cols: usize = self.cols;
        const phys = self.row_map[y];
        const row_start = @as(usize, y) * cols;

        switch (mode) {
            0 => {
                const cx: usize = self.cursor_x;
                self.fixWideBoundaries(row_start + cx, row_start + cols);
                @memset(self.cells[phys * cols + cx .. (phys + 1) * cols], Cell{});
                self.markDirtyRange(.{ .start = row_start + cx, .end = row_start + cols });
                self.clearRgbPhysRange(phys * cols + cx, (phys + 1) * cols);
            },
            1 => {
                const cx: usize = self.cursor_x;
                self.fixWideBoundaries(row_start, row_start + cx + 1);
                @memset(self.cells[phys * cols .. phys * cols + cx + 1], Cell{});
                self.markDirtyRange(.{ .start = row_start, .end = row_start + cx + 1 });
                self.clearRgbPhysRange(phys * cols, phys * cols + cx + 1);
            },
            2 => {
                @memset(self.cells[phys * cols .. (phys + 1) * cols], Cell{});
                self.markDirtyRange(.{ .start = row_start, .end = row_start + cols });
                self.clearRgbPhysRange(phys * cols, (phys + 1) * cols);
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
        const count: usize = @min(n, self.scroll_bottom - self.cursor_y + 1);
        if (count == 0) return;
        const cols: usize = self.cols;
        const bot: usize = self.scroll_bottom;
        const cy: usize = self.cursor_y;

        // Save physical rows being pushed off the bottom
        var saved: [256]u32 = undefined;
        for (0..count) |s| {
            const phys = self.row_map[bot - s];
            saved[s] = phys;
            @memset(self.cells[phys * cols .. (phys + 1) * cols], Cell{});
            self.clearRgbRow(phys);
        }

        // Shift row_map down within [cy, bot]
        const keep = bot - cy + 1 - count;
        if (keep > 0) {
            std.mem.copyBackwards(u32, self.row_map[cy + count .. cy + count + keep], self.row_map[cy .. cy + keep]);
        }

        // Put cleared rows at cy
        for (0..count) |s| {
            self.row_map[cy + s] = saved[count - 1 - s];
        }

        self.markDirtyRange(.{ .start = cy * cols, .end = (bot + 1) * cols });
    }

    pub fn deleteLines(self: *Self, n: u32) void {
        if (self.cursor_y < self.scroll_top or self.cursor_y > self.scroll_bottom) return;
        const count: usize = @min(n, self.scroll_bottom - self.cursor_y + 1);
        if (count == 0) return;
        const cols: usize = self.cols;
        const bot: usize = self.scroll_bottom;
        const cy: usize = self.cursor_y;

        // Save physical rows being deleted
        var saved: [256]u32 = undefined;
        for (0..count) |s| {
            const phys = self.row_map[cy + s];
            saved[s] = phys;
            @memset(self.cells[phys * cols .. (phys + 1) * cols], Cell{});
            self.clearRgbRow(phys);
        }

        // Shift row_map up within [cy, bot]
        const keep = bot - cy + 1 - count;
        if (keep > 0) {
            std.mem.copyForwards(u32, self.row_map[cy .. cy + keep], self.row_map[cy + count .. cy + count + keep]);
        }

        // Put cleared rows at bottom
        for (0..count) |s| {
            self.row_map[bot + 1 - count + s] = saved[s];
        }

        self.markDirtyRange(.{ .start = cy * cols, .end = (bot + 1) * cols });
    }

    pub fn deleteChars(self: *Self, n: u32) void {
        if (self.cursor_x >= self.cols or self.cursor_y >= self.rows) return;
        const cols: usize = self.cols;
        const cx: usize = self.cursor_x;
        const phys = self.row_map[self.cursor_y];
        const remaining = cols - cx;
        const count = @min(n, @as(u32, @intCast(remaining)));
        const row_base = phys * cols;
        const logical_row_start = @as(usize, self.cursor_y) * cols;

        // Fix wide boundaries using logical coords
        self.fixWideBoundaries(logical_row_start + cx, logical_row_start + cx + count);

        // Shift characters left (physical)
        const copy_len = remaining - count;
        if (copy_len > 0) {
            std.mem.copyForwards(Cell, self.cells[row_base + cx .. row_base + cx + copy_len], self.cells[row_base + cx + count .. row_base + cx + count + copy_len]);
        }

        // Clear rightmost characters
        @memset(self.cells[row_base + cols - count .. row_base + cols], Cell{});

        self.markDirtyRange(.{ .start = logical_row_start + cx, .end = logical_row_start + cols });
        self.clearRgbPhysRange(row_base + cx, row_base + cols);
    }

    pub fn insertChars(self: *Self, n: u32) void {
        if (self.cursor_x >= self.cols or self.cursor_y >= self.rows) return;
        const cols: usize = self.cols;
        const cx: usize = self.cursor_x;
        const phys = self.row_map[self.cursor_y];
        const remaining = cols - cx;
        const count = @min(n, @as(u32, @intCast(remaining)));
        const row_base = phys * cols;
        const logical_row_start = @as(usize, self.cursor_y) * cols;

        // Fix wide character boundaries at insertion point
        self.fixWideBoundaries(logical_row_start + cx, logical_row_start + cx + count);

        // Shift characters right (physical)
        const copy_len = remaining - count;
        if (copy_len > 0) {
            std.mem.copyBackwards(Cell, self.cells[row_base + cx + count .. row_base + cx + count + copy_len], self.cells[row_base + cx .. row_base + cx + copy_len]);
        }

        // Clear inserted characters
        @memset(self.cells[row_base + cx .. row_base + cx + count], Cell{});

        self.markDirtyRange(.{ .start = logical_row_start + cx, .end = logical_row_start + cols });
        self.clearRgbPhysRange(row_base + cx, row_base + cols);
    }

    pub fn eraseChars(self: *Self, n: u32) void {
        if (self.cursor_x >= self.cols or self.cursor_y >= self.rows) return;
        const cols: usize = self.cols;
        const cx: usize = self.cursor_x;
        const phys = self.row_map[self.cursor_y];
        const remaining = cols - cx;
        const count: usize = @min(n, @as(u32, @intCast(remaining)));
        const row_base = phys * cols;
        const logical_row_start = @as(usize, self.cursor_y) * cols;

        // Fix wide character boundaries at erase range
        self.fixWideBoundaries(logical_row_start + cx, logical_row_start + cx + count);
        @memset(self.cells[row_base + cx .. row_base + cx + count], Cell{});

        self.markDirtyRange(.{ .start = logical_row_start + cx, .end = logical_row_start + cx + count });
        self.clearRgbPhysRange(row_base + cx, row_base + cx + count);
    }

    /// Clear RGB entries for a physical row (O(1) memset)
    fn clearRgbRow(self: *Self, phys_row: usize) void {
        const cols: usize = self.cols;
        const start = phys_row * cols;
        @memset(self.fg_rgb[start .. start + cols], null);
        @memset(self.bg_rgb[start .. start + cols], null);
    }

    /// Clear RGB entries for a physical index range (O(1) memset)
    fn clearRgbPhysRange(self: *Self, start: usize, end: usize) void {
        @memset(self.fg_rgb[start..end], null);
        @memset(self.bg_rgb[start..end], null);
    }

    /// Clear RGB entries for logical rows [y_start, y_end)
    fn clearRgbRange(self: *Self, y_start: usize, y_end: usize, _: usize) void {
        const cols: usize = self.cols;
        for (y_start..y_end) |y| {
            const phys = self.row_map[y];
            const start = phys * cols;
            @memset(self.fg_rgb[start .. start + cols], null);
            @memset(self.bg_rgb[start .. start + cols], null);
        }
    }

    /// Clear all TrueColor entries.
    fn clearAllRgb(self: *Self) void {
        @memset(self.fg_rgb, null);
        @memset(self.bg_rgb, null);
    }

    // TrueColor helpers (indexed by physical cell position)
    pub fn setFgRgb(self: *Self, x: u32, y: u32, rgb: [3]u8) !void {
        self.fg_rgb[self.cellIndex(x, y)] = rgb;
        self.has_truecolor_cells = true;
    }

    pub fn getFgRgb(self: *const Self, x: u32, y: u32) ?[3]u8 {
        return self.fg_rgb[self.cellIndex(x, y)];
    }

    pub fn setBgRgb(self: *Self, x: u32, y: u32, rgb: [3]u8) !void {
        self.bg_rgb[self.cellIndex(x, y)] = rgb;
        self.has_truecolor_cells = true;
    }

    pub fn getBgRgb(self: *const Self, x: u32, y: u32) ?[3]u8 {
        return self.bg_rgb[self.cellIndex(x, y)];
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

test "Term: setCell / getCell roundtrip" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    term.setCell(5, 3, .{ .char = 'X', .fg = 1, .bg = 2 });
    const cell = term.getCell(5, 3);
    try testing.expectEqual(@as(u21, 'X'), cell.char);
    try testing.expectEqual(@as(u8, 1), cell.fg);
    try testing.expectEqual(@as(u8, 2), cell.bg);
}

test "Term: scrollUp moves rows via row_map" {
    var term = try Term.init(testing.allocator, 5, 4);
    defer term.deinit();
    // Write row identifiers
    term.setCell(0, 0, .{ .char = 'A' });
    term.setCell(0, 1, .{ .char = 'B' });
    term.setCell(0, 2, .{ .char = 'C' });
    term.setCell(0, 3, .{ .char = 'D' });
    term.scroll_bottom = 3;
    term.scrollUp(1);
    // Row 0 should now be old row 1
    try testing.expectEqual(@as(u21, 'B'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'C'), term.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, 'D'), term.getCell(0, 2).char);
    // New bottom row should be cleared
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 3).char);
}

test "Term: scrollDown moves rows via row_map" {
    var term = try Term.init(testing.allocator, 5, 4);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'A' });
    term.setCell(0, 1, .{ .char = 'B' });
    term.setCell(0, 2, .{ .char = 'C' });
    term.setCell(0, 3, .{ .char = 'D' });
    term.scroll_bottom = 3;
    term.scrollDown(1);
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'A'), term.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, 'B'), term.getCell(0, 2).char);
    try testing.expectEqual(@as(u21, 'C'), term.getCell(0, 3).char);
}

test "Term: clearDirty resets all bits" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    term.setCell(5, 5, .{ .char = 'X' });
    try testing.expect(term.hasDirty());
    term.clearDirty();
    try testing.expect(!term.hasDirty());
}

test "Term: eraseDisplay 2 resets row_map to identity" {
    var term = try Term.init(testing.allocator, 5, 4);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'A' });
    term.scroll_bottom = 3;
    term.scrollUp(1); // row_map is now shuffled
    term.eraseDisplay(2);
    // row_map should be identity
    for (0..4) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), term.row_map[i]);
    }
}

test "Term: isRowDirty returns false after clearDirty" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    term.setCell(10, 2, .{ .char = 'Z' });
    try testing.expect(term.isRowDirty(2));
    term.clearDirty();
    try testing.expect(!term.isRowDirty(2));
}

test "Term: isDirty tracks per-cell" {
    var term = try Term.init(testing.allocator, 5, 3);
    defer term.deinit();
    term.clearDirty();
    term.markDirty(0, 0);
    try testing.expect(term.isDirty(0, 0));
    try testing.expect(!term.isDirty(1, 0));
}

test "Term: isRowDirty single cell" {
    var term = try Term.init(testing.allocator, 5, 3);
    defer term.deinit();
    term.clearDirty();
    term.markDirty(4, 1); // last col of row 1
    try testing.expect(!term.isRowDirty(0));
    try testing.expect(term.isRowDirty(1));
    try testing.expect(!term.isRowDirty(2));
}

test "Term: isRowDirty out of bounds" {
    var term = try Term.init(testing.allocator, 5, 3);
    defer term.deinit();
    term.clearDirty();
    term.markDirty(130, 1);
    try testing.expect(!term.isRowDirty(1));
}

test "Term: hasDirty with single bit" {
    var term = try Term.init(testing.allocator, 5, 3);
    defer term.deinit();
    term.clearDirty();
    try testing.expect(!term.hasDirty());
    term.markDirty(0, 0);
    try testing.expect(term.hasDirty());
    term.clearDirty();
    try testing.expect(!term.hasDirty());
    term.markDirty(4, 1);
    try testing.expect(term.hasDirty());
}
