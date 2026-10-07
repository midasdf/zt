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

    // Big per-cell planes are NOT zero-initialized: a slot is only readable
    // after pushRow wrote it (rowAt gates on `count`), and the color/hyperlink
    // planes of a slot are only read when its has_truecolor/has_hyperlink
    // flag is set — i.e. when pushRow copied them. Untouched pages stay
    // non-resident, so a fresh ring costs ~0 RSS.
    cells: []Cell,
    fg_rgb: []?[3]u8,
    bg_rgb: []?[3]u8,
    ul_color_rgb: []?[3]u8,
    hyperlink_ids: []u16,
    used_cols: []u16,
    has_truecolor: []bool,
    has_hyperlink: []bool,
    // Shared all-blank metadata row (cols wide) returned by rowAt for slots
    // whose planes were never written.
    zero_rgb: []?[3]u8,
    zero_hl: []u16,

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
        errdefer allocator.free(tc);
        const hf = try allocator.alloc(bool, capacity);
        errdefer allocator.free(hf);
        const z_rgb = try allocator.alloc(?[3]u8, cols);
        errdefer allocator.free(z_rgb);
        const z_hl = try allocator.alloc(u16, cols);

        // Only the small capacity/cols-sized arrays are initialized; the big
        // per-cell planes stay untouched (see field comment).
        @memset(uc, 0);
        @memset(tc, false);
        @memset(hf, false);
        @memset(z_rgb, null);
        @memset(z_hl, 0);

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
            .has_hyperlink = hf,
            .zero_rgb = z_rgb,
            .zero_hl = z_hl,
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
        self.allocator.free(self.has_hyperlink);
        self.allocator.free(self.zero_rgb);
        self.allocator.free(self.zero_hl);
    }

    pub fn clear(self: *Self) void {
        self.head = 0;
        self.count = 0;
    }

    /// `may_have_rgb` / `may_have_hl` are conservative caller hints (from the
    /// terminal's screen-wide has_truecolor_cells / has_ul_hl_cells flags):
    /// when false the corresponding src planes are known all-blank, so both
    /// the scan and the copy are skipped and rowAt serves the shared zero row.
    pub fn pushRow(
        self: *Self,
        src_cells: []const Cell,
        src_fg: []const ?[3]u8,
        src_bg: []const ?[3]u8,
        src_ul: []const ?[3]u8,
        src_hl: []const u16,
        may_have_rgb: bool,
        may_have_hl: bool,
    ) void {
        std.debug.assert(src_cells.len == self.cols);
        std.debug.assert(src_fg.len == self.cols);
        std.debug.assert(src_bg.len == self.cols);
        std.debug.assert(src_ul.len == self.cols);
        std.debug.assert(src_hl.len == self.cols);

        const slot = self.head;
        const start: usize = @as(usize, slot) * @as(usize, self.cols);
        @memcpy(self.cells[start .. start + self.cols], src_cells);

        // Per-row truecolor scan (fg/bg/ul); copy those planes only when the
        // row actually carries color metadata.
        var has_tc = false;
        if (may_have_rgb) {
            for (src_fg) |v| {
                if (v != null) {
                    has_tc = true;
                    break;
                }
            }
            if (!has_tc) {
                for (src_bg) |v| {
                    if (v != null) {
                        has_tc = true;
                        break;
                    }
                }
            }
            if (!has_tc) {
                for (src_ul) |v| {
                    if (v != null) {
                        has_tc = true;
                        break;
                    }
                }
            }
        }
        if (has_tc) {
            @memcpy(self.fg_rgb[start .. start + self.cols], src_fg);
            @memcpy(self.bg_rgb[start .. start + self.cols], src_bg);
            @memcpy(self.ul_color_rgb[start .. start + self.cols], src_ul);
        }
        self.has_truecolor[slot] = has_tc;

        var has_hl = false;
        if (may_have_hl) {
            for (src_hl) |v| {
                if (v != 0) {
                    has_hl = true;
                    break;
                }
            }
        }
        if (has_hl) {
            @memcpy(self.hyperlink_ids[start .. start + self.cols], src_hl);
        }
        self.has_hyperlink[slot] = has_hl;

        // Compute used_cols: trim trailing default blanks for resize accuracy.
        // A "default blank" is char==' ' and no per-cell metadata override.
        var uc: u32 = self.cols;
        if (has_tc or has_hl) {
            while (uc > 0) {
                const i = uc - 1;
                const c = src_cells[i];
                if (c.char != ' ' or src_fg[i] != null or src_bg[i] != null or
                    src_ul[i] != null or src_hl[i] != 0) break;
                uc -= 1;
            }
        } else {
            // Metadata planes are all blank — only the glyphs matter.
            while (uc > 0) {
                if (src_cells[uc - 1].char != ' ') break;
                uc -= 1;
            }
        }
        self.used_cols[slot] = @intCast(uc);

        self.head = (self.head + 1) % self.capacity;
        if (self.count < self.capacity) self.count += 1;
    }

    pub fn resize(self: *Self, new_cols: u32) !void {
        std.debug.assert(new_cols > 0);
        if (new_cols == self.cols) return;

        const new_total: usize = @as(usize, self.capacity) * @as(usize, new_cols);

        const new_cells = try self.allocator.alloc(Cell, new_total);
        errdefer self.allocator.free(new_cells);
        const new_fg = try self.allocator.alloc(?[3]u8, new_total);
        errdefer self.allocator.free(new_fg);
        const new_bg = try self.allocator.alloc(?[3]u8, new_total);
        errdefer self.allocator.free(new_bg);
        const new_ul = try self.allocator.alloc(?[3]u8, new_total);
        errdefer self.allocator.free(new_ul);
        const new_hl = try self.allocator.alloc(u16, new_total);
        errdefer self.allocator.free(new_hl);
        const new_z_rgb = try self.allocator.alloc(?[3]u8, new_cols);
        errdefer self.allocator.free(new_z_rgb);
        const new_z_hl = try self.allocator.alloc(u16, new_cols);

        @memset(new_z_rgb, null);
        @memset(new_z_hl, 0);

        // Migrate only the occupied slots — unoccupied slots are never read
        // (rowAt gates on count), and plane rows without metadata are never
        // read either (rowAt serves the zero row), so neither needs init.
        const copy_cols: usize = @min(self.cols, new_cols);
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            const slot: u32 = @intCast((@as(u64, self.head) + self.capacity - self.count + i) % self.capacity);
            const old_start: usize = @as(usize, slot) * @as(usize, self.cols);
            const new_start: usize = @as(usize, slot) * @as(usize, new_cols);
            @memcpy(new_cells[new_start .. new_start + copy_cols], self.cells[old_start .. old_start + copy_cols]);
            if (new_cols > copy_cols) @memset(new_cells[new_start + copy_cols .. new_start + new_cols], Cell{});
            if (self.has_truecolor[slot]) {
                @memcpy(new_fg[new_start .. new_start + copy_cols], self.fg_rgb[old_start .. old_start + copy_cols]);
                @memcpy(new_bg[new_start .. new_start + copy_cols], self.bg_rgb[old_start .. old_start + copy_cols]);
                @memcpy(new_ul[new_start .. new_start + copy_cols], self.ul_color_rgb[old_start .. old_start + copy_cols]);
                if (new_cols > copy_cols) {
                    @memset(new_fg[new_start + copy_cols .. new_start + new_cols], null);
                    @memset(new_bg[new_start + copy_cols .. new_start + new_cols], null);
                    @memset(new_ul[new_start + copy_cols .. new_start + new_cols], null);
                }
            }
            if (self.has_hyperlink[slot]) {
                @memcpy(new_hl[new_start .. new_start + copy_cols], self.hyperlink_ids[old_start .. old_start + copy_cols]);
                if (new_cols > copy_cols) @memset(new_hl[new_start + copy_cols .. new_start + new_cols], 0);
            }

            // Wide-char boundary fix: a wide-left glyph stranded at the new
            // last column has its right half (the wide_dummy) dropped — blank
            // the orphan to prevent a half-rendered glyph.
            if (new_cols < self.cols and copy_cols > 0) {
                const last = new_start + copy_cols - 1;
                if (new_cells[last].attrs.wide) {
                    new_cells[last] = .{};
                    if (self.has_truecolor[slot]) {
                        new_fg[last] = null;
                        new_bg[last] = null;
                        new_ul[last] = null;
                    }
                    if (self.has_hyperlink[slot]) new_hl[last] = 0;
                }
            }

            // Clamp used_cols to the new width.
            if (self.used_cols[slot] > new_cols) self.used_cols[slot] = @intCast(new_cols);
        }

        self.allocator.free(self.cells);
        self.allocator.free(self.fg_rgb);
        self.allocator.free(self.bg_rgb);
        self.allocator.free(self.ul_color_rgb);
        self.allocator.free(self.hyperlink_ids);
        self.allocator.free(self.zero_rgb);
        self.allocator.free(self.zero_hl);

        self.cells = new_cells;
        self.fg_rgb = new_fg;
        self.bg_rgb = new_bg;
        self.ul_color_rgb = new_ul;
        self.hyperlink_ids = new_hl;
        self.zero_rgb = new_z_rgb;
        self.zero_hl = new_z_hl;
        self.cols = new_cols;
    }

    pub fn rowAt(self: *const Self, age: u32) ScrollbackView {
        std.debug.assert(self.count > 0);
        const a = if (age >= self.count) self.count - 1 else age;
        // newest row sits at slot (head - 1) mod capacity (= age 0).
        // Row of age k sits at (head - 1 - k) mod capacity.
        const cap_i: i64 = @intCast(self.capacity);
        const idx_i: i64 = @as(i64, @intCast(self.head)) - 1 - @as(i64, @intCast(a));
        const slot: u32 = @intCast(@mod(idx_i, cap_i));
        const start: usize = @as(usize, slot) * @as(usize, self.cols);
        const end = start + self.cols;
        const has_tc = self.has_truecolor[slot];
        return .{
            .cells = self.cells[start..end],
            // Slots without color/hyperlink metadata never had their planes
            // written — serve the shared zero row instead.
            .fg_rgb = if (has_tc) self.fg_rgb[start..end] else self.zero_rgb[0..self.cols],
            .bg_rgb = if (has_tc) self.bg_rgb[start..end] else self.zero_rgb[0..self.cols],
            .ul_color_rgb = if (has_tc) self.ul_color_rgb[start..end] else self.zero_rgb[0..self.cols],
            .hyperlink_ids = if (self.has_hyperlink[slot]) self.hyperlink_ids[start..end] else self.zero_hl[0..self.cols],
            .used_cols = self.used_cols[slot],
            .has_truecolor = has_tc,
        };
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

test "Scrollback: pushRow stores cells and rowAt(0) returns newest" {
    var sb = try Scrollback.init(testing.allocator, 10, 5);
    defer sb.deinit();

    const cells = [_]Cell{
        .{ .char = 'A' }, .{ .char = 'B' }, .{ .char = 'C' },
        .{ .char = 'D' }, .{ .char = 'E' },
    };
    const empty_rgb: [5]?[3]u8 = @splat(null);
    const empty_hl: [5]u16 = @splat(0);

    sb.pushRow(&cells, &empty_rgb, &empty_rgb, &empty_rgb, &empty_hl, true, true);

    try testing.expectEqual(@as(u32, 1), sb.count);
    const view = sb.rowAt(0);
    try testing.expectEqual(@as(u21, 'A'), view.cells[0].char);
    try testing.expectEqual(@as(u21, 'E'), view.cells[4].char);
    try testing.expectEqual(@as(u16, 5), view.used_cols);
    try testing.expectEqual(false, view.has_truecolor);
}

test "Scrollback: pushRow trims trailing default blanks for used_cols" {
    var sb = try Scrollback.init(testing.allocator, 10, 6);
    defer sb.deinit();

    const cells = [_]Cell{
        .{ .char = 'A' }, .{ .char = 'B' }, .{ .char = 'C' },
        .{ .char = ' ' }, .{ .char = ' ' }, .{ .char = ' ' },
    };
    const empty_rgb: [6]?[3]u8 = @splat(null);
    const empty_hl: [6]u16 = @splat(0);

    sb.pushRow(&cells, &empty_rgb, &empty_rgb, &empty_rgb, &empty_hl, true, true);
    try testing.expectEqual(@as(u16, 3), sb.rowAt(0).used_cols);
}

test "Scrollback: pushRow detects truecolor in fg/bg/ul" {
    var sb = try Scrollback.init(testing.allocator, 10, 3);
    defer sb.deinit();

    const cells = [_]Cell{ .{ .char = 'X' }, .{ .char = 'Y' }, .{ .char = 'Z' } };
    const empty_rgb: [3]?[3]u8 = @splat(null);
    const empty_hl: [3]u16 = @splat(0);

    var fg: [3]?[3]u8 = @splat(null);
    fg[1] = .{ 200, 100, 50 };
    sb.pushRow(&cells, &fg, &empty_rgb, &empty_rgb, &empty_hl, true, true);
    try testing.expectEqual(true, sb.rowAt(0).has_truecolor);

    sb.clear();
    var bg: [3]?[3]u8 = @splat(null);
    bg[2] = .{ 0, 0, 1 };
    sb.pushRow(&cells, &empty_rgb, &bg, &empty_rgb, &empty_hl, true, true);
    try testing.expectEqual(true, sb.rowAt(0).has_truecolor);

    sb.clear();
    var u: [3]?[3]u8 = @splat(null);
    u[0] = .{ 9, 9, 9 };
    sb.pushRow(&cells, &empty_rgb, &empty_rgb, &u, &empty_hl, true, true);
    try testing.expectEqual(true, sb.rowAt(0).has_truecolor);
}

test "Scrollback: capacity overflow drops oldest" {
    var sb = try Scrollback.init(testing.allocator, 3, 1);
    defer sb.deinit();

    const empty_rgb = [_]?[3]u8{null};
    const empty_hl = [_]u16{0};
    inline for (0..5) |i| {
        const cells = [_]Cell{.{ .char = 'A' + @as(u8, i) }};
        sb.pushRow(&cells, &empty_rgb, &empty_rgb, &empty_rgb, &empty_hl, true, true);
    }

    try testing.expectEqual(@as(u32, 3), sb.count);
    // Newest = 'E', then 'D', then 'C'. 'A' and 'B' fell off.
    try testing.expectEqual(@as(u21, 'E'), sb.rowAt(0).cells[0].char);
    try testing.expectEqual(@as(u21, 'D'), sb.rowAt(1).cells[0].char);
    try testing.expectEqual(@as(u21, 'C'), sb.rowAt(2).cells[0].char);
}

test "Scrollback: rowAt clamps age to count-1" {
    var sb = try Scrollback.init(testing.allocator, 10, 1);
    defer sb.deinit();
    const cells = [_]Cell{.{ .char = 'A' }};
    const empty_rgb = [_]?[3]u8{null};
    const empty_hl = [_]u16{0};
    sb.pushRow(&cells, &empty_rgb, &empty_rgb, &empty_rgb, &empty_hl, true, true);

    // Asking for an age beyond count returns the oldest available row
    // rather than panicking — defensive contract for callers.
    const view = sb.rowAt(99);
    try testing.expectEqual(@as(u21, 'A'), view.cells[0].char);
}

test "Scrollback: resize shrinks rows and preserves leading content" {
    var sb = try Scrollback.init(testing.allocator, 5, 5);
    defer sb.deinit();

    const cells = [_]Cell{
        .{ .char = 'A' }, .{ .char = 'B' }, .{ .char = 'C' },
        .{ .char = 'D' }, .{ .char = 'E' },
    };
    const empty_rgb: [5]?[3]u8 = @splat(null);
    const empty_hl: [5]u16 = @splat(0);
    sb.pushRow(&cells, &empty_rgb, &empty_rgb, &empty_rgb, &empty_hl, true, true);

    try sb.resize(3);
    try testing.expectEqual(@as(u32, 3), sb.cols);
    const v = sb.rowAt(0);
    try testing.expectEqual(@as(u21, 'A'), v.cells[0].char);
    try testing.expectEqual(@as(u21, 'B'), v.cells[1].char);
    try testing.expectEqual(@as(u21, 'C'), v.cells[2].char);
    try testing.expectEqual(@as(u16, 3), v.used_cols);
}

test "Scrollback: resize grows rows and pads with blanks" {
    var sb = try Scrollback.init(testing.allocator, 5, 3);
    defer sb.deinit();

    const cells = [_]Cell{ .{ .char = 'X' }, .{ .char = 'Y' }, .{ .char = 'Z' } };
    const empty_rgb: [3]?[3]u8 = @splat(null);
    const empty_hl: [3]u16 = @splat(0);
    sb.pushRow(&cells, &empty_rgb, &empty_rgb, &empty_rgb, &empty_hl, true, true);

    try sb.resize(6);
    try testing.expectEqual(@as(u32, 6), sb.cols);
    const v = sb.rowAt(0);
    try testing.expectEqual(@as(u21, 'X'), v.cells[0].char);
    try testing.expectEqual(@as(u21, 'Y'), v.cells[1].char);
    try testing.expectEqual(@as(u21, 'Z'), v.cells[2].char);
    try testing.expectEqual(@as(u21, ' '), v.cells[3].char);
    try testing.expectEqual(@as(u21, ' '), v.cells[5].char);
}

test "Scrollback: resize fixes wide-char left half stranded at new last column" {
    var sb = try Scrollback.init(testing.allocator, 5, 4);
    defer sb.deinit();

    const cells = [_]Cell{
        .{ .char = 'A' },
        .{ .char = '日', .attrs = .{ .wide = true } },
        .{ .char = ' ', .attrs = .{ .wide_dummy = true } },
        .{ .char = 'B' },
    };
    const empty_rgb: [4]?[3]u8 = @splat(null);
    const empty_hl: [4]u16 = @splat(0);
    sb.pushRow(&cells, &empty_rgb, &empty_rgb, &empty_rgb, &empty_hl, true, true);

    // Shrink to 2 cols — the wide char's right half (col 2) is dropped, so
    // the wide left half at col 1 must be replaced with blank.
    try sb.resize(2);
    const v = sb.rowAt(0);
    try testing.expectEqual(@as(u21, 'A'), v.cells[0].char);
    try testing.expectEqual(@as(u21, ' '), v.cells[1].char);
    try testing.expect(!v.cells[1].attrs.wide);
}

test "Scrollback: resize is no-op when new_cols == old_cols" {
    var sb = try Scrollback.init(testing.allocator, 5, 4);
    defer sb.deinit();

    const cells = [_]Cell{ .{ .char = 'A' }, .{ .char = 'B' }, .{ .char = 'C' }, .{ .char = 'D' } };
    const empty_rgb: [4]?[3]u8 = @splat(null);
    const empty_hl: [4]u16 = @splat(0);
    sb.pushRow(&cells, &empty_rgb, &empty_rgb, &empty_rgb, &empty_hl, true, true);

    try sb.resize(4);
    const v = sb.rowAt(0);
    try testing.expectEqual(@as(u21, 'A'), v.cells[0].char);
    try testing.expectEqual(@as(u21, 'D'), v.cells[3].char);
}
