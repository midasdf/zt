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
    comptime wide: bool,
    comptime scale: u32,
) void {
    const render_w: u32 = if (wide) font_w * 2 else font_w;
    const scaled_w: u32 = render_w * scale;
    const scaled_h: u32 = font_h * scale;

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
        fg_color.r = @intCast(@as(u16, fg_color.r) * 3 / 5);
        fg_color.g = @intCast(@as(u16, fg_color.g) * 3 / 5);
        fg_color.b = @intCast(@as(u16, fg_color.b) * 3 / 5);
    }

    // 4. Bytes per pixel
    const bpp: u32 = switch (pixel_format) {
        .bgra32 => 4,
        .rgb565 => 2,
        .rgb24 => 3,
    };

    // 5. Bounds + scaled pixel offset
    const max_offset = buffer.len;
    const px_x = cell_x * font_w * scale;
    const px_y = cell_y * font_h * scale;

    // 6. Fill background rect (scaled dimensions)
    if (pixel_format == .bgra32) {
        const bg_packed = [4]u8{ bg_color.b, bg_color.g, bg_color.r, 0xFF };
        for (0..scaled_h) |row| {
            const row_offset = (px_y + @as(u32, @intCast(row))) * stride + px_x * bpp;
            if (row_offset + scaled_w * 4 > max_offset) continue;
            const pixels: [*][4]u8 = @ptrCast(buffer.ptr + row_offset);
            @memset(pixels[0..scaled_w], bg_packed);
        }
    } else {
        for (0..scaled_h) |row| {
            const row_offset = (px_y + @as(u32, @intCast(row))) * stride + px_x * bpp;
            for (0..scaled_w) |col| {
                const offset = row_offset + @as(u32, @intCast(col)) * bpp;
                if (offset + bpp > max_offset) continue;
                writePixel(buffer, offset, bg_color, pixel_format);
            }
        }
    }

    // 7. Draw glyph bitmap (iterate at original size, write scale x scale blocks)
    if (glyph) |g| {
        const bytes_per_row = (g.width + 7) / 8;
        if (pixel_format == .bgra32) {
            const fg_packed = [4]u8{ fg_color.b, fg_color.g, fg_color.r, 0xFF };
            for (0..@min(g.height, font_h)) |bmp_row| {
                // Write first scaled row of this bitmap row
                const first_y = px_y + @as(u32, @intCast(bmp_row)) * scale;
                const first_row_base = first_y * stride + px_x * 4;
                if (first_row_base + scaled_w * 4 > max_offset) continue;

                for (0..@min(g.width, render_w)) |bmp_col| {
                    const byte_idx = bmp_row * bytes_per_row + bmp_col / 8;
                    const bit = @as(u8, 0x80) >> @intCast(bmp_col % 8);
                    if (byte_idx < g.bitmap.len and g.bitmap[byte_idx] & bit != 0) {
                        const screen_x = @as(u32, @intCast(bmp_col)) * scale;
                        for (0..scale) |sx| {
                            const px_off = first_row_base + (screen_x + @as(u32, @intCast(sx))) * 4;
                            @as(*[4]u8, @ptrCast(buffer.ptr + px_off)).* = fg_packed;
                        }
                        // Bold: adjacent bitmap column
                        if (cell.attrs.bold and bmp_col + 1 < render_w) {
                            const bold_x = (@as(u32, @intCast(bmp_col)) + 1) * scale;
                            for (0..scale) |sx| {
                                const px_off = first_row_base + (bold_x + @as(u32, @intCast(sx))) * 4;
                                @as(*[4]u8, @ptrCast(buffer.ptr + px_off)).* = fg_packed;
                            }
                        }
                    }
                }
                // Duplicate first row to remaining scale-1 rows via memcpy
                const row_bytes = scaled_w * 4;
                const src = buffer[first_row_base .. first_row_base + row_bytes];
                for (1..scale) |sy| {
                    const dest_y = first_y + @as(u32, @intCast(sy));
                    const dest_base = dest_y * stride + px_x * 4;
                    if (dest_base + row_bytes > max_offset) continue;
                    @memcpy(buffer[dest_base .. dest_base + row_bytes], src);
                }
            }
        } else {
            for (0..@min(g.height, font_h)) |bmp_row| {
                for (0..@min(g.width, render_w)) |bmp_col| {
                    const byte_idx = bmp_row * bytes_per_row + bmp_col / 8;
                    const bit = @as(u8, 0x80) >> @intCast(bmp_col % 8);
                    if (byte_idx < g.bitmap.len and g.bitmap[byte_idx] & bit != 0) {
                        for (0..scale) |sy| {
                            for (0..scale) |sx| {
                                const offset = (px_y + @as(u32, @intCast(bmp_row)) * scale + @as(u32, @intCast(sy))) * stride + (px_x + @as(u32, @intCast(bmp_col)) * scale + @as(u32, @intCast(sx))) * bpp;
                                if (offset + bpp > max_offset) continue;
                                writePixel(buffer, offset, fg_color, pixel_format);
                            }
                        }
                        if (cell.attrs.bold and bmp_col + 1 < render_w) {
                            for (0..scale) |sy| {
                                for (0..scale) |sx| {
                                    const bold_offset = (px_y + @as(u32, @intCast(bmp_row)) * scale + @as(u32, @intCast(sy))) * stride + (px_x + (@as(u32, @intCast(bmp_col)) + 1) * scale + @as(u32, @intCast(sx))) * bpp;
                                    if (bold_offset + bpp > max_offset) continue;
                                    writePixel(buffer, bold_offset, fg_color, pixel_format);
                                }
                            }
                        }
                    }
                }
            }
        }
    } else if (cell.char != ' ' and cell.char != 0) {
        // Missing glyph fallback: box outline with scale-pixel border
        for (0..scaled_h) |row| {
            for (0..scaled_w) |col| {
                if (row < scale or row >= scaled_h - scale or col < scale or col >= scaled_w - scale) {
                    const offset = (px_y + @as(u32, @intCast(row))) * stride + (px_x + @as(u32, @intCast(col))) * bpp;
                    if (offset + bpp > max_offset) continue;
                    writePixel(buffer, offset, fg_color, pixel_format);
                }
            }
        }
    }

    // 8. Underline: at (font_h - 2) * scale with scale-pixel thickness
    if (cell.attrs.underline) {
        const ul_start = (font_h - 2) * scale;
        if (pixel_format == .bgra32) {
            const fg_packed = [4]u8{ fg_color.b, fg_color.g, fg_color.r, 0xFF };
            for (0..scale) |s| {
                const row_offset = (px_y + ul_start + @as(u32, @intCast(s))) * stride + px_x * bpp;
                if (row_offset + scaled_w * 4 <= max_offset) {
                    const pixels: [*][4]u8 = @ptrCast(buffer.ptr + row_offset);
                    @memset(pixels[0..scaled_w], fg_packed);
                }
            }
        } else {
            for (0..scale) |s| {
                const row_offset = (px_y + ul_start + @as(u32, @intCast(s))) * stride + px_x * bpp;
                for (0..scaled_w) |col| {
                    const offset = row_offset + @as(u32, @intCast(col)) * bpp;
                    if (offset + bpp > max_offset) continue;
                    writePixel(buffer, offset, fg_color, pixel_format);
                }
            }
        }
    }
}

pub fn renderCursor(
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
    comptime wide: bool,
    comptime scale: u32,
) void {
    var inverted = cell;
    const tmp = inverted.fg;
    inverted.fg = inverted.bg;
    inverted.bg = tmp;
    renderCell(buffer, stride, cell_x, cell_y, inverted, bg_rgb_override, fg_rgb_override, glyph, font_w, font_h, pixel_format, wide, scale);
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

    renderCell(&buffer, stride, 0, 0, .{ .char = 'A', .fg = 7, .bg = 0 }, null, null, glyph, w, h, .bgra32, false, 1);

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

test "Render: renderCell scale=2 writes 2x2 pixel blocks" {
    const w = 8;
    const h = 16;
    const scale = 2;
    const bpp = 4;
    const stride = w * scale * bpp; // 64 bytes per row (16 pixels wide)
    var buffer: [stride * h * scale]u8 = [_]u8{0} ** (stride * h * scale);

    // Bitmap row 2 = 0x18 = 00011000 (bits 3 and 4 set)
    const bitmap = [_]u8{ 0x00, 0x00, 0x18, 0x24, 0x42, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42, 0x42, 0x00, 0x00, 0x00, 0x00 };
    const glyph = GlyphView{ .codepoint = 'A', .width = 8, .height = 16, .bitmap = &bitmap };

    renderCell(&buffer, stride, 0, 0, .{ .char = 'A', .fg = 7, .bg = 0 }, null, null, glyph, w, h, .bgra32, false, scale);

    // Bitmap pixel (3, 2) at scale=2 → screen pixels (6, 4), (7, 4), (6, 5), (7, 5)
    // Check top-left of 2x2 block: screen row 4, col 6
    const row4_start = 4 * stride;
    const col6_offset = row4_start + 6 * bpp;
    try testing.expect(buffer[col6_offset + 2] > 0); // R channel at (6, 4)

    // Check bottom-right of 2x2 block: screen row 5, col 7
    const row5_start = 5 * stride;
    const col7_offset = row5_start + 7 * bpp;
    try testing.expect(buffer[col7_offset + 2] > 0); // R channel at (7, 5)

    // Verify all 4 corners of the 2x2 block
    const col7_row4 = row4_start + 7 * bpp;
    try testing.expect(buffer[col7_row4 + 2] > 0); // top-right at (7, 4)
    const col6_row5 = row5_start + 6 * bpp;
    try testing.expect(buffer[col6_row5 + 2] > 0); // bottom-left at (6, 5)

    // bmp_col=2 is not set in 0x18, so screen col 4-5 in row 4 must be background
    const col4_row4 = row4_start + 4 * bpp;
    try testing.expectEqual(@as(u8, 0), buffer[col4_row4 + 2]);

    // Bitmap row 1 = 0x00, so screen row 2 (second sub-row of bitmap row 1) is background
    const screen_row2 = 2 * stride;
    const screen_col3 = screen_row2 + 3 * bpp;
    try testing.expectEqual(@as(u8, 0), buffer[screen_col3 + 2]); // must be background
}

test "Render: space with null glyph produces background only" {
    const w = 8;
    const h = 16;
    const bpp = 4;
    const stride = w * bpp;
    var buffer: [stride * h]u8 = [_]u8{0} ** (stride * h);

    renderCell(&buffer, stride, 0, 0, .{ .char = ' ', .fg = 7, .bg = 0 }, null, null, null, w, h, .bgra32, false, 1);

    try testing.expectEqual(@as(u8, 0), buffer[2]);

    const interior = 4 * stride + 4 * bpp;
    try testing.expectEqual(@as(u8, 0), buffer[interior + 2]);
}
