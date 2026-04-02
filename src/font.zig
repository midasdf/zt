const std = @import("std");

pub const Glyph = struct {
    codepoint: u21,
    width: u32,
    height: u32,
    bitmap_offset: usize,
    bitmap_len: usize,
};

pub fn Font(comptime bdf_data: []const u8) type {
    @setEvalBranchQuota(100_000_000);
    const parsed = parseBdf(bdf_data);
    return FontType(parsed.glyph_count, parsed.bitmap_size, parsed.glyphs, parsed.bitmap_data);
}

fn FontType(
    comptime n: usize,
    comptime bitmap_total: usize,
    comptime glyphs: [n]Glyph,
    comptime bitmap_data: [bitmap_total]u8,
) type {
    return struct {
        const sorted_glyphs: [n]Glyph = glyphs;
        const bitmaps: [bitmap_total]u8 = bitmap_data;

        pub fn getGlyph(codepoint: u21) ?GlyphView {
            var lo: usize = 0;
            var hi: usize = n;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const mid_cp = sorted_glyphs[mid].codepoint;
                if (mid_cp == codepoint) {
                    const g = sorted_glyphs[mid];
                    return .{
                        .codepoint = g.codepoint,
                        .width = g.width,
                        .height = g.height,
                        .bitmap = bitmaps[g.bitmap_offset..][0..g.bitmap_len],
                    };
                } else if (mid_cp < codepoint) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return null;
        }
    };
}

pub const GlyphView = struct {
    codepoint: u21,
    width: u32,
    height: u32,
    bitmap: []const u8,
};

/// Load a pre-compiled font blob (from bdf2blob.py).
/// Binary format: header(8) + glyph_table(n*16) + bitmap_data
/// This avoids comptime BDF parsing for large fonts.
pub fn FontBlob(comptime blob: []const u8) type {
    const glyph_count = std.mem.readInt(u32, blob[0..4], .little);
    const table_offset: usize = 8;
    const bitmap_offset: usize = table_offset + glyph_count * 16;

    return struct {
        // ASCII glyph cache: O(1) lookup for codepoints 0-127
        const ascii_cache: [128]?GlyphView = blk: {
            @setEvalBranchQuota(100_000);
            var cache: [128]?GlyphView = .{null} ** 128;
            for (0..128) |cp| {
                cache[cp] = getGlyphSlow(@intCast(cp));
            }
            break :blk cache;
        };

        pub fn getGlyph(codepoint: u21) ?GlyphView {
            // Fast path: ASCII (comptime cache)
            if (codepoint < 128) return ascii_cache[codepoint];

            // Runtime cache for non-ASCII (function-local static via struct pattern)
            const S = struct {
                const CACHE_SIZE: usize = 256;
                // valid=false means empty slot (avoids confusion with codepoint 0)
                var keys: [CACHE_SIZE]u21 = [_]u21{0} ** CACHE_SIZE;
                var vals: [CACHE_SIZE]?GlyphView = [_]?GlyphView{null} ** CACHE_SIZE;
                var valid: [CACHE_SIZE]bool = [_]bool{false} ** CACHE_SIZE;
            };

            // XOR folding: mix high bits into low bits to reduce collisions
            // for CJK ranges where codepoints differ only in upper bits
            const folded = codepoint ^ (codepoint >> 8);
            const idx = folded % S.CACHE_SIZE;
            if (S.valid[idx] and S.keys[idx] == codepoint) {
                return S.vals[idx];
            }

            // Cache miss: binary search
            const result = getGlyphSlow(codepoint);
            S.keys[idx] = codepoint;
            S.vals[idx] = result;
            S.valid[idx] = true;
            return result;
        }

        fn getGlyphSlow(codepoint: u21) ?GlyphView {
            // Binary search in glyph table
            var lo: usize = 0;
            var hi: usize = glyph_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const entry_off = table_offset + mid * 16;
                const entry_cp: u21 = @intCast(std.mem.readInt(u32, blob[entry_off..][0..4], .little));
                if (entry_cp == codepoint) {
                    const w = std.mem.readInt(u16, blob[entry_off + 4 ..][0..2], .little);
                    const h = std.mem.readInt(u16, blob[entry_off + 6 ..][0..2], .little);
                    const bmp_off = std.mem.readInt(u32, blob[entry_off + 8 ..][0..4], .little);
                    const bmp_len = std.mem.readInt(u16, blob[entry_off + 12 ..][0..2], .little);
                    return .{
                        .codepoint = codepoint,
                        .width = w,
                        .height = h,
                        .bitmap = blob[bitmap_offset + bmp_off ..][0..bmp_len],
                    };
                } else if (entry_cp < codepoint) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return null;
        }
    };
}

fn parseBdf(comptime bdf_data: []const u8) struct {
    glyph_count: usize,
    bitmap_size: usize,
    glyphs: [countGlyphs(bdf_data)]Glyph,
    bitmap_data: [countBitmapBytes(bdf_data)]u8,
} {
    @setEvalBranchQuota(100_000_000);
    const n = countGlyphs(bdf_data);
    const total_bytes = countBitmapBytes(bdf_data);
    var glyphs: [n]Glyph = undefined;
    var all_bitmap: [total_bytes]u8 = undefined;
    var glyph_idx: usize = 0;
    var bitmap_offset: usize = 0;

    var lines = std.mem.splitScalar(u8, bdf_data, '\n');
    var in_bitmap = false;
    var current_codepoint: u21 = 0;
    var current_width: u32 = 0;
    var current_height: u32 = 0;
    var bytes_per_row: usize = 0;
    var glyph_bitmap_start: usize = 0;

    while (lines.next()) |line_raw| {
        const line = trimRight(line_raw);
        if (line.len == 0) continue;

        if (in_bitmap) {
            if (std.mem.eql(u8, line, "ENDCHAR")) {
                in_bitmap = false;
                glyphs[glyph_idx] = .{
                    .codepoint = current_codepoint,
                    .width = current_width,
                    .height = current_height,
                    .bitmap_offset = glyph_bitmap_start,
                    .bitmap_len = bitmap_offset - glyph_bitmap_start,
                };
                glyph_idx += 1;
            } else {
                // Parse hex row
                var i: usize = 0;
                while (i < bytes_per_row * 2 and i + 1 < line.len) : (i += 2) {
                    all_bitmap[bitmap_offset] = parseHexByte(line[i], line[i + 1]);
                    bitmap_offset += 1;
                }
            }
        } else if (startsWith(line, "ENCODING ")) {
            current_codepoint = parseEncoding(line);
        } else if (startsWith(line, "BBX ")) {
            const bbx = parseBBX(line);
            current_width = bbx[0];
            current_height = bbx[1];
            bytes_per_row = (current_width + 7) / 8;
        } else if (std.mem.eql(u8, line, "BITMAP")) {
            in_bitmap = true;
            glyph_bitmap_start = bitmap_offset;
        }
    }

    // Sort by codepoint (insertion sort)
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j: usize = i;
        while (j > 0 and glyphs[j - 1].codepoint > glyphs[j].codepoint) : (j -= 1) {
            const tmp = glyphs[j];
            glyphs[j] = glyphs[j - 1];
            glyphs[j - 1] = tmp;
        }
    }

    return .{
        .glyph_count = n,
        .bitmap_size = total_bytes,
        .glyphs = glyphs,
        .bitmap_data = all_bitmap,
    };
}

fn countGlyphs(comptime bdf_data: []const u8) usize {
    @setEvalBranchQuota(100_000_000);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bdf_data, '\n');
    while (lines.next()) |line_raw| {
        const line = trimRight(line_raw);
        if (std.mem.eql(u8, line, "ENDCHAR")) {
            count += 1;
        }
    }
    return count;
}

fn countBitmapBytes(comptime bdf_data: []const u8) usize {
    @setEvalBranchQuota(100_000_000);
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, bdf_data, '\n');
    var in_bitmap = false;
    var bytes_per_row: usize = 0;

    while (lines.next()) |line_raw| {
        const line = trimRight(line_raw);
        if (line.len == 0) continue;

        if (in_bitmap) {
            if (std.mem.eql(u8, line, "ENDCHAR")) {
                in_bitmap = false;
            } else {
                total += bytes_per_row;
            }
        } else if (startsWith(line, "BBX ")) {
            const bbx = parseBBX(line);
            bytes_per_row = (bbx[0] + 7) / 8;
        } else if (std.mem.eql(u8, line, "BITMAP")) {
            in_bitmap = true;
        }
    }
    return total;
}

fn trimRight(s: []const u8) []const u8 {
    var end: usize = s.len;
    while (end > 0 and (s[end - 1] == '\r' or s[end - 1] == ' ' or s[end - 1] == '\t')) {
        end -= 1;
    }
    return s[0..end];
}

fn startsWith(s: []const u8, comptime prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return std.mem.eql(u8, s[0..prefix.len], prefix);
}

fn parseEncoding(comptime line: []const u8) u21 {
    const num_str = line["ENCODING ".len..];
    return parseUint(u21, num_str);
}

fn parseBBX(line: []const u8) [2]u32 {
    const rest = line["BBX ".len..];
    var parts = std.mem.splitScalar(u8, rest, ' ');
    const w = parseUint(u32, parts.next().?);
    const h = parseUint(u32, parts.next().?);
    return .{ w, h };
}

fn parseUint(comptime T: type, s: []const u8) T {
    var val: T = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        val = val * 10 + @as(T, @intCast(c - '0'));
    }
    return val;
}

fn parseHexByte(hi: u8, lo: u8) u8 {
    return (hexVal(hi) << 4) | hexVal(lo);
}

fn hexVal(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

// ── Tests ──

const TestFont = Font(@embedFile("fonts/test_minimal.bdf"));

test "glyph A exists" {
    const g = TestFont.getGlyph('A');
    try std.testing.expect(g != null);
}

test "glyph A dimensions are 8x16" {
    const g = TestFont.getGlyph('A').?;
    try std.testing.expectEqual(@as(u32, 8), g.width);
    try std.testing.expectEqual(@as(u32, 16), g.height);
}

test "glyph A bitmap row 2 is 0x18" {
    const g = TestFont.getGlyph('A').?;
    try std.testing.expectEqual(@as(u8, 0x18), g.bitmap[2]);
}

test "space glyph is all zeros" {
    const g = TestFont.getGlyph(' ').?;
    for (g.bitmap[0..g.height]) |b| {
        try std.testing.expectEqual(@as(u8, 0x00), b);
    }
}

test "missing glyph returns null" {
    const g = TestFont.getGlyph(9999);
    try std.testing.expect(g == null);
}

test "CJK double-width glyph" {
    const g = TestFont.getGlyph(0x3042);
    try std.testing.expect(g != null);
    try std.testing.expectEqual(@as(u32, 16), g.?.width);
    try std.testing.expectEqual(@as(u32, 16), g.?.height);
    // 2 bytes per row * 16 rows = 32 bytes total
    try std.testing.expectEqual(@as(usize, 32), g.?.bitmap.len);
}

test "FontBlob: repeated non-ASCII lookup returns same glyph" {
    const BlobFont = FontBlob(@embedFile("fonts/ufo-nf.bin"));

    const g1 = BlobFont.getGlyph(0x3042);
    try std.testing.expect(g1 != null);

    const g2 = BlobFont.getGlyph(0x3042);
    try std.testing.expect(g2 != null);

    try std.testing.expectEqual(g1.?.codepoint, g2.?.codepoint);
    try std.testing.expectEqual(g1.?.width, g2.?.width);
    try std.testing.expectEqual(g1.?.height, g2.?.height);
    try std.testing.expectEqual(g1.?.bitmap.len, g2.?.bitmap.len);
}

test "FontBlob: rounded corners exist and have non-zero bitmaps" {
    const BlobFont = FontBlob(@embedFile("fonts/ufo-nf.bin"));

    const corners = [_]u21{ 0x256D, 0x256E, 0x256F, 0x2570 }; // ╭ ╮ ╯ ╰
    for (corners) |cp| {
        const g = BlobFont.getGlyph(cp);
        try std.testing.expect(g != null);
        try std.testing.expectEqual(@as(u32, 8), g.?.width);
        try std.testing.expectEqual(@as(u32, 16), g.?.height);
        // Bitmap should not be all zeros
        var has_nonzero = false;
        for (g.?.bitmap) |b| {
            if (b != 0) has_nonzero = true;
        }
        try std.testing.expect(has_nonzero);
    }
}

test "FontBlob: block chars for Claude Code logo exist" {
    const BlobFont = FontBlob(@embedFile("fonts/ufo-nf.bin"));

    const blocks = [_]u21{ 0x2590, 0x259B, 0x2588, 0x259C, 0x258C, 0x2598, 0x259D, 0x2733 };
    for (blocks) |cp| {
        const g = BlobFont.getGlyph(cp);
        try std.testing.expect(g != null);
        var has_nonzero = false;
        for (g.?.bitmap) |b| {
            if (b != 0) has_nonzero = true;
        }
        try std.testing.expect(has_nonzero);
    }
}
