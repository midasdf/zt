//! Convert a BDF font to a binary blob for zt's font module.
//!
//! Usage: bdf2blob <input.bdf> <output.bin>
//!
//! Binary format:
//!   Header:
//!     u32 LE: glyph_count
//!     u32 LE: bitmap_data_total_bytes
//!   Glyph table (glyph_count entries, sorted by codepoint):
//!     u32 LE: codepoint
//!     u16 LE: width
//!     u16 LE: height
//!     u32 LE: bitmap_offset (into bitmap data)
//!     u16 LE: bitmap_len (bytes)
//!     u16 LE: padding (0)
//!   Bitmap data:
//!     Raw bitmap bytes (1 bit per pixel, row-major, packed)

const std = @import("std");
const Io = std.Io;

const Glyph = struct {
    codepoint: u32,
    width: u16,
    height: u16,
    bitmap: []const u8,
};

fn glyphLessThan(_: void, a: Glyph, b: Glyph) bool {
    return a.codepoint < b.codepoint;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Decode a BDF hex row (e.g. "FF", "C3 80") into packed bytes.
/// Non-hex characters (whitespace) are ignored, matching Python's bytes.fromhex.
fn appendHexBytes(out: *std.ArrayList(u8), gpa: std.mem.Allocator, row: []const u8) !void {
    var hi: ?u8 = null;
    for (row) |c| {
        const v = hexVal(c) orelse continue;
        if (hi) |h| {
            try out.append(gpa, (h << 4) | v);
            hi = null;
        } else {
            hi = v;
        }
    }
    if (hi != null) return error.InvalidHexRow;
}

fn putU16(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

fn putU32(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    var ait = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    defer ait.deinit();
    const prog = ait.next() orelse "bdf2blob";
    const input_path = ait.next();
    const output_path = ait.next();
    if (input_path == null or output_path == null or ait.next() != null) {
        std.debug.print("Usage: {s} <input.bdf> <output.bin>\n", .{prog});
        std.process.exit(1);
    }

    const cwd = Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, input_path.?, a, .unlimited);

    var glyphs: std.ArrayList(Glyph) = .empty;

    var in_bitmap = false;
    var codepoint: i64 = -1;
    var width: u16 = 0;
    var height: u16 = 0;
    var rows: std.ArrayList([]const u8) = .empty;

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "STARTCHAR")) {
            in_bitmap = false;
            codepoint = -1;
            width = 0;
            height = 0;
            rows.clearRetainingCapacity();
        } else if (std.mem.startsWith(u8, line, "ENCODING")) {
            var t = std.mem.tokenizeScalar(u8, line, ' ');
            _ = t.next(); // "ENCODING"
            if (t.next()) |tok| codepoint = std.fmt.parseInt(i64, tok, 10) catch -1;
        } else if (std.mem.startsWith(u8, line, "BBX")) {
            var t = std.mem.tokenizeScalar(u8, line, ' ');
            _ = t.next(); // "BBX"
            const w = t.next() orelse continue;
            const h = t.next() orelse continue;
            width = @intCast(std.fmt.parseInt(i64, w, 10) catch 0);
            height = @intCast(std.fmt.parseInt(i64, h, 10) catch 0);
        } else if (std.mem.eql(u8, line, "BITMAP")) {
            in_bitmap = true;
        } else if (std.mem.eql(u8, line, "ENDCHAR")) {
            if (in_bitmap and codepoint >= 0) {
                var bytes: std.ArrayList(u8) = .empty;
                for (rows.items) |row| try appendHexBytes(&bytes, a, row);
                try glyphs.append(a, .{
                    .codepoint = @intCast(codepoint),
                    .width = width,
                    .height = height,
                    .bitmap = bytes.items,
                });
            }
            in_bitmap = false;
        } else if (in_bitmap) {
            try rows.append(a, line); // slice into `data`, stable for program lifetime
        }
    }

    std.sort.pdq(Glyph, glyphs.items, {}, glyphLessThan);

    const glyph_count: u32 = @intCast(glyphs.items.len);
    var bitmap_total: u32 = 0;
    for (glyphs.items) |g| bitmap_total += @intCast(g.bitmap.len);

    var out: std.ArrayList(u8) = .empty;
    // Header
    try putU32(&out, a, glyph_count);
    try putU32(&out, a, bitmap_total);
    // Glyph table
    var offset: u32 = 0;
    for (glyphs.items) |g| {
        try putU32(&out, a, g.codepoint);
        try putU16(&out, a, g.width);
        try putU16(&out, a, g.height);
        try putU32(&out, a, offset);
        try putU16(&out, a, @intCast(g.bitmap.len));
        try putU16(&out, a, 0); // padding
        offset += @intCast(g.bitmap.len);
    }
    // Bitmap data
    for (glyphs.items) |g| try out.appendSlice(a, g.bitmap);

    try cwd.writeFile(io, .{ .sub_path = output_path.?, .data = out.items });

    std.debug.print("Written {d} glyphs, {d} bitmap bytes\n", .{ glyph_count, bitmap_total });
    std.debug.print("Glyph table: {d} bytes\n", .{glyph_count * 16});
    std.debug.print("Total blob: {d} bytes\n", .{8 + glyph_count * 16 + bitmap_total});
}
