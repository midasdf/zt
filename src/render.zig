const std = @import("std");
const testing = std.testing;
const font_mod = @import("font.zig");
const term = @import("term.zig");

pub const Cell = term.Cell;
pub const GlyphView = font_mod.GlyphView;

pub const Color = struct { r: u8, g: u8, b: u8 };

pub const PixelFormat = enum {
    bgra32,
    rgb565,
    rgb24,
};

/// xterm-256color palette, built at comptime.
pub const palette: [256]Color = buildPalette();

fn buildPalette() [256]Color {
    var pal: [256]Color = undefined;

    // 0-7: standard colors
    pal[0] = .{ .r = 0, .g = 0, .b = 0 };
    pal[1] = .{ .r = 128, .g = 0, .b = 0 };
    pal[2] = .{ .r = 0, .g = 128, .b = 0 };
    pal[3] = .{ .r = 128, .g = 128, .b = 0 };
    pal[4] = .{ .r = 0, .g = 0, .b = 128 };
    pal[5] = .{ .r = 128, .g = 0, .b = 128 };
    pal[6] = .{ .r = 0, .g = 128, .b = 128 };
    pal[7] = .{ .r = 192, .g = 192, .b = 192 };

    // 8-15: bright colors
    pal[8] = .{ .r = 128, .g = 128, .b = 128 };
    pal[9] = .{ .r = 255, .g = 0, .b = 0 };
    pal[10] = .{ .r = 0, .g = 255, .b = 0 };
    pal[11] = .{ .r = 255, .g = 255, .b = 0 };
    pal[12] = .{ .r = 0, .g = 0, .b = 255 };
    pal[13] = .{ .r = 255, .g = 0, .b = 255 };
    pal[14] = .{ .r = 0, .g = 255, .b = 255 };
    pal[15] = .{ .r = 255, .g = 255, .b = 255 };

    // 16-231: 6x6x6 color cube
    const cube_values = [6]u8{ 0, 95, 135, 175, 215, 255 };
    for (16..232) |i| {
        const idx = i - 16;
        const ri = idx / 36;
        const gi = (idx / 6) % 6;
        const bi = idx % 6;
        pal[i] = .{
            .r = cube_values[ri],
            .g = cube_values[gi],
            .b = cube_values[bi],
        };
    }

    // 232-255: grayscale ramp
    for (232..256) |i| {
        const v: u8 = @intCast(8 + (i - 232) * 10);
        pal[i] = .{ .r = v, .g = v, .b = v };
    }

    return pal;
}

pub inline fn writePixel(buffer: []u8, offset: usize, color: Color, comptime fmt: PixelFormat) void {
    switch (fmt) {
        .bgra32 => {
            buffer[offset] = color.b;
            buffer[offset + 1] = color.g;
            buffer[offset + 2] = color.r;
            buffer[offset + 3] = 0xFF;
        },
        .rgb565 => {
            const val: u16 = (@as(u16, color.r >> 3) << 11) |
                (@as(u16, color.g >> 2) << 5) |
                @as(u16, color.b >> 3);
            buffer[offset] = @truncate(val);
            buffer[offset + 1] = @truncate(val >> 8);
        },
        .rgb24 => {
            buffer[offset] = color.r;
            buffer[offset + 1] = color.g;
            buffer[offset + 2] = color.b;
        },
    }
}

pub fn renderCell(
    buffer: []u8,
    stride: u32,
    cell_x: u32,
    cell_y: u32,
    cell: Cell,
    fg_rgb_override: ?[3]u8,
    bg_rgb_override: ?[3]u8,
    glyph: ?GlyphView,
    comptime font_w: u32,
    comptime font_h: u32,
    comptime pixel_format: PixelFormat,
) void {
    // 1. Determine fg/bg colors
    var fg_color = if (fg_rgb_override) |rgb| Color{ .r = rgb[0], .g = rgb[1], .b = rgb[2] } else palette[cell.fg];
    var bg_color = if (bg_rgb_override) |rgb| Color{ .r = rgb[0], .g = rgb[1], .b = rgb[2] } else palette[cell.bg];

    // 2. Handle reverse
    if (cell.attrs.reverse) {
        const tmp = fg_color;
        fg_color = bg_color;
        bg_color = tmp;
    }

    // 3. Handle dim
    if (cell.attrs.dim) {
        fg_color.r /= 2;
        fg_color.g /= 2;
        fg_color.b /= 2;
    }

    // 4. Bytes per pixel
    const bpp: u32 = switch (pixel_format) {
        .bgra32 => 4,
        .rgb565 => 2,
        .rgb24 => 3,
    };

    // 5. Bounds limits to prevent buffer overflow
    const max_offset = buffer.len;
    const px_x = cell_x * font_w;
    const px_y = cell_y * font_h;

    // 6. Fill background rect
    for (0..font_h) |row| {
        const row_offset = (px_y + @as(u32, @intCast(row))) * stride + px_x * bpp;
        for (0..font_w) |col| {
            const offset = row_offset + @as(u32, @intCast(col)) * bpp;
            if (offset + bpp > max_offset) continue;
            writePixel(buffer, offset, bg_color, pixel_format);
        }
    }

    // 7. Draw glyph bitmap
    if (glyph) |g| {
        const bytes_per_row = (g.width + 7) / 8;
        for (0..@min(g.height, font_h)) |row| {
            for (0..@min(g.width, font_w)) |col| {
                const byte_idx = row * bytes_per_row + col / 8;
                const bit = @as(u8, 0x80) >> @intCast(col % 8);
                if (byte_idx < g.bitmap.len and g.bitmap[byte_idx] & bit != 0) {
                    const offset = (px_y + @as(u32, @intCast(row))) * stride + (px_x + @as(u32, @intCast(col))) * bpp;
                    if (offset + bpp > max_offset) continue;
                    writePixel(buffer, offset, fg_color, pixel_format);
                    // Bold: draw 1px to the right
                    if (cell.attrs.bold and col + 1 < font_w) {
                        const bold_offset = offset + bpp;
                        if (bold_offset + bpp <= max_offset) {
                            writePixel(buffer, bold_offset, fg_color, pixel_format);
                        }
                    }
                }
            }
        }
    } else {
        // Missing glyph fallback: draw a box outline
        for (0..font_h) |row| {
            for (0..font_w) |col| {
                if (row == 0 or row == font_h - 1 or col == 0 or col == font_w - 1) {
                    const offset = (px_y + @as(u32, @intCast(row))) * stride + (px_x + @as(u32, @intCast(col))) * bpp;
                    if (offset + bpp > max_offset) continue;
                    writePixel(buffer, offset, fg_color, pixel_format);
                }
            }
        }
    }

    // 8. Underline: draw horizontal line at font_h - 2
    if (cell.attrs.underline) {
        const row_offset = (px_y + font_h - 2) * stride + px_x * bpp;
        for (0..font_w) |col| {
            const offset = row_offset + @as(u32, @intCast(col)) * bpp;
            if (offset + bpp > max_offset) continue;
            writePixel(buffer, offset, fg_color, pixel_format);
        }
    }
}

pub fn renderCursor(
    buffer: []u8,
    stride: u32,
    cell_x: u32,
    cell_y: u32,
    cell: Cell,
    glyph: ?GlyphView,
    comptime font_w: u32,
    comptime font_h: u32,
    comptime pixel_format: PixelFormat,
) void {
    // Block cursor = render cell with fg/bg swapped
    var inverted = cell;
    const tmp = inverted.fg;
    inverted.fg = inverted.bg;
    inverted.bg = tmp;
    renderCell(buffer, stride, cell_x, cell_y, inverted, null, null, glyph, font_w, font_h, pixel_format);
}

// --- Tests ---

test "Render: palette color 0 is black" {
    try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, palette[0]);
}

test "Render: palette color 1 is red" {
    const c = palette[1];
    try testing.expect(c.r > 0);
    try testing.expectEqual(@as(u8, 0), c.g);
    try testing.expectEqual(@as(u8, 0), c.b);
}

test "Render: palette color 15 is bright white" {
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, palette[15]);
}

test "Render: palette grayscale 232 is dark gray" {
    const c = palette[232];
    try testing.expectEqual(c.r, c.g);
    try testing.expectEqual(c.g, c.b);
    try testing.expectEqual(@as(u8, 8), c.r);
}

test "Render: renderCell writes pixels to buffer" {
    const w = 8;
    const h = 16;
    const bpp = 4;
    const stride = w * bpp;
    var buffer: [stride * h]u8 = [_]u8{0} ** (stride * h);

    // Create a simple glyph (A-like pattern)
    const bitmap = [_]u8{ 0x00, 0x00, 0x18, 0x24, 0x42, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x42, 0x00, 0x00, 0x00, 0x00 };
    const glyph = GlyphView{ .codepoint = 'A', .width = 8, .height = 16, .bitmap = &bitmap };

    renderCell(&buffer, stride, 0, 0, .{ .char = 'A', .fg = 7, .bg = 0 }, null, null, glyph, w, h, .bgra32);

    // Row 2 (0x18 = bits 3,4) should have white pixels at columns 3 and 4
    const row2_start = 2 * stride;
    const col3_offset = row2_start + 3 * bpp;
    try testing.expect(buffer[col3_offset + 2] > 0); // R channel
}

test "Render: writePixel RGB565 format" {
    var buf: [2]u8 = undefined;
    writePixel(&buf, 0, Color{ .r = 255, .g = 0, .b = 0 }, .rgb565);
    // Pure red in RGB565 = 0xF800 = little-endian: 0x00, 0xF8
    try testing.expectEqual(@as(u8, 0x00), buf[0]);
    try testing.expectEqual(@as(u8, 0xF8), buf[1]);
}
