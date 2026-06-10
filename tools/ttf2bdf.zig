//! Rasterize a TrueType (`glyf`-outline) font into a fixed-cell, 1-bit BDF
//! bitmap font for zt. Pure Zig, no external dependencies.
//!
//! Usage: ttf2bdf <input.ttf> <output.bdf> [--baseline B]
//!                [--xscale S] [--yscale S] [--xoff X] [--preview]
//!
//! Each glyph is rendered into a CELL_W x CELL_H monochrome cell, baseline-
//! aligned, MSB-first packed rows (matching zt's renderer and bdf2blob). Only
//! TrueType outlines (`glyf` + `loca`) are supported; CFF/OTF is not.

const std = @import("std");

const CELL_W: u32 = 8;
const CELL_H: u32 = 16;
const BEZIER_STEPS: u32 = 8;

const Pt = struct { x: f64, y: f64, on: bool };
const Edge = struct { x0: f64, y0: f64, x1: f64, y1: f64 };
const Xform = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,
    fn apply(t: Xform, x: f64, y: f64) [2]f64 {
        return .{ t.a * x + t.c * y + t.e, t.b * x + t.d * y + t.f };
    }
    fn compose(p: Xform, q: Xform) Xform {
        // result = p ∘ q  (apply q, then p)
        return .{
            .a = p.a * q.a + p.c * q.b,
            .b = p.b * q.a + p.d * q.b,
            .c = p.a * q.c + p.c * q.d,
            .d = p.b * q.c + p.d * q.d,
            .e = p.a * q.e + p.c * q.f + p.e,
            .f = p.b * q.e + p.d * q.f + p.f,
        };
    }
};

fn requireBytes(d: []const u8, o: usize, n: usize) void {
    if (o > d.len or n > d.len - o) {
        std.debug.print("error: invalid font data: need {d} bytes at offset {d}, file has {d} bytes\n", .{ n, o, d.len });
        std.process.exit(1);
    }
}

fn rdU16(d: []const u8, o: usize) u16 {
    requireBytes(d, o, 2);
    return std.mem.readInt(u16, d[o..][0..2], .big);
}
fn rdI16(d: []const u8, o: usize) i16 {
    requireBytes(d, o, 2);
    return std.mem.readInt(i16, d[o..][0..2], .big);
}
fn rdU32(d: []const u8, o: usize) u32 {
    requireBytes(d, o, 4);
    return std.mem.readInt(u32, d[o..][0..4], .big);
}

const XCross = struct { x: f64, dir: i32 };

const Font = struct {
    data: []const u8,
    units_per_em: f64,
    num_glyphs: u16,
    loc_long: bool,
    off_loca: usize,
    off_glyf: usize,
    off_cmap: usize,

    fn locaAt(self: Font, gid: u32) usize {
        if (self.loc_long) {
            return rdU32(self.data, self.off_loca + gid * 4);
        } else {
            return @as(usize, rdU16(self.data, self.off_loca + gid * 2)) * 2;
        }
    }
};

fn contourPoint(contours: []const []Pt, point_index: i32) ?*Pt {
    if (point_index < 0) return null;
    var remaining: usize = @intCast(point_index);
    for (contours) |pts| {
        if (remaining < pts.len) return &pts[remaining];
        remaining -= pts.len;
    }
    return null;
}

fn findTable(d: []const u8, tag: *const [4]u8) ?usize {
    const num = rdU16(d, 4);
    var i: usize = 0;
    while (i < num) : (i += 1) {
        const rec = 12 + i * 16;
        requireBytes(d, rec, 16);
        if (std.mem.eql(u8, d[rec..][0..4], tag)) return rdU32(d, rec + 8);
    }
    return null;
}

/// Append the glyph's contours (in font units) to `contours`, applying `xf`.
fn collectGlyph(
    font: Font,
    gid: u32,
    xf: Xform,
    depth: u32,
    a: std.mem.Allocator,
    contours: *std.ArrayList([]Pt),
) !void {
    if (depth > 8) return;
    if (gid >= font.num_glyphs) fatal("cmap references glyph id beyond maxp numGlyphs");
    const start = font.locaAt(gid);
    const end = font.locaAt(gid + 1);
    if (end <= start) return; // empty glyph (e.g. space)
    const d = font.data;
    var o = font.off_glyf + start;
    const num_contours = rdI16(d, o);
    o += 10; // skip numberOfContours + bbox

    if (num_contours >= 0) {
        const nc: usize = @intCast(num_contours);
        var end_pts = try a.alloc(u16, nc);
        defer a.free(end_pts);
        for (0..nc) |i| {
            end_pts[i] = rdU16(d, o);
            o += 2;
        }
        const num_points: usize = if (nc == 0) 0 else @as(usize, end_pts[nc - 1]) + 1;
        const instr_len = rdU16(d, o);
        o += 2 + instr_len;

        // Flags (with repeat compression).
        var flags = try a.alloc(u8, num_points);
        defer a.free(flags);
        var i: usize = 0;
        while (i < num_points) {
            const fl = d[o];
            o += 1;
            flags[i] = fl;
            i += 1;
            if (fl & 0x08 != 0) {
                var rep = d[o];
                o += 1;
                while (rep > 0 and i < num_points) : (rep -= 1) {
                    flags[i] = fl;
                    i += 1;
                }
            }
        }

        // X coordinates.
        var xs = try a.alloc(f64, num_points);
        defer a.free(xs);
        var xv: i32 = 0;
        for (0..num_points) |k| {
            const fl = flags[k];
            if (fl & 0x02 != 0) {
                const dx: i32 = d[o];
                o += 1;
                xv += if (fl & 0x10 != 0) dx else -dx;
            } else if (fl & 0x10 == 0) {
                xv += @as(i32, rdI16(d, o));
                o += 2;
            }
            xs[k] = @floatFromInt(xv);
        }
        // Y coordinates.
        var ys = try a.alloc(f64, num_points);
        defer a.free(ys);
        var yv: i32 = 0;
        for (0..num_points) |k| {
            const fl = flags[k];
            if (fl & 0x04 != 0) {
                const dy: i32 = d[o];
                o += 1;
                yv += if (fl & 0x20 != 0) dy else -dy;
            } else if (fl & 0x20 == 0) {
                yv += @as(i32, rdI16(d, o));
                o += 2;
            }
            ys[k] = @floatFromInt(yv);
        }

        // Split into contours, applying the transform.
        var s: usize = 0;
        for (0..nc) |ci| {
            const e: usize = end_pts[ci];
            const len = e - s + 1;
            var pts = try a.alloc(Pt, len);
            for (0..len) |j| {
                const p = xf.apply(xs[s + j], ys[s + j]);
                pts[j] = .{ .x = p[0], .y = p[1], .on = (flags[s + j] & 0x01) != 0 };
            }
            try contours.append(a, pts);
            s = e + 1;
        }
    } else {
        // Composite glyph.
        while (true) {
            const comp_flags = rdU16(d, o);
            const comp_gid = rdU16(d, o + 2);
            o += 4;
            var arg1: i32 = undefined;
            var arg2: i32 = undefined;
            if (comp_flags & 0x0001 != 0) { // ARG_1_AND_2_ARE_WORDS
                arg1 = rdI16(d, o);
                arg2 = rdI16(d, o + 2);
                o += 4;
            } else {
                arg1 = @as(i8, @bitCast(d[o]));
                arg2 = @as(i8, @bitCast(d[o + 1]));
                o += 2;
            }
            var cxf = Xform{};
            if (comp_flags & 0x0008 != 0) { // WE_HAVE_A_SCALE
                const sc = f2dot14(rdI16(d, o));
                o += 2;
                cxf.a = sc;
                cxf.d = sc;
            } else if (comp_flags & 0x0040 != 0) { // X_AND_Y_SCALE
                cxf.a = f2dot14(rdI16(d, o));
                cxf.d = f2dot14(rdI16(d, o + 2));
                o += 4;
            } else if (comp_flags & 0x0080 != 0) { // TWO_BY_TWO
                cxf.a = f2dot14(rdI16(d, o));
                cxf.b = f2dot14(rdI16(d, o + 2));
                cxf.c = f2dot14(rdI16(d, o + 4));
                cxf.d = f2dot14(rdI16(d, o + 6));
                o += 8;
            }
            if (comp_flags & 0x0002 != 0) { // ARGS_ARE_XY_VALUES
                cxf.e = @floatFromInt(arg1);
                cxf.f = @floatFromInt(arg2);
                try collectGlyph(font, comp_gid, xf.compose(cxf), depth + 1, a, contours);
            } else {
                var component_contours: std.ArrayList([]Pt) = .empty;
                try collectGlyph(font, comp_gid, xf.compose(cxf), depth + 1, a, &component_contours);

                const parent_anchor = contourPoint(contours.items, arg1) orelse fatal("invalid composite parent point index");
                const child_anchor = contourPoint(component_contours.items, arg2) orelse fatal("invalid composite component point index");
                const dx = parent_anchor.x - child_anchor.x;
                const dy = parent_anchor.y - child_anchor.y;
                for (component_contours.items) |pts| {
                    for (pts) |*p| {
                        p.x += dx;
                        p.y += dy;
                    }
                }
                try contours.appendSlice(a, component_contours.items);
            }
            if (comp_flags & 0x0020 == 0) break; // no MORE_COMPONENTS
        }
    }
}

fn f2dot14(v: i16) f64 {
    return @as(f64, @floatFromInt(v)) / 16384.0;
}

/// Flatten one contour into edges (in pixel space already), via the supplied
/// unit->pixel mapping closure parameters.
fn flattenContour(pts: []const Pt, a: std.mem.Allocator, edges: *std.ArrayList(Edge)) !void {
    if (pts.len < 2) return;

    // Build an on-curve-normalized point list: insert implicit midpoints
    // between consecutive off-curve points.
    var exp: std.ArrayList(Pt) = .empty;
    defer exp.deinit(a);
    for (pts, 0..) |p, k| {
        try exp.append(a, p);
        const nxt = pts[(k + 1) % pts.len];
        if (!p.on and !nxt.on) {
            try exp.append(a, .{ .x = (p.x + nxt.x) / 2, .y = (p.y + nxt.y) / 2, .on = true });
        }
    }
    // Rotate so the first point is on-curve.
    var first_on: ?usize = null;
    for (exp.items, 0..) |p, k| {
        if (p.on) {
            first_on = k;
            break;
        }
    }
    if (first_on == null) return; // all off-curve: degenerate, skip
    const rot = first_on.?;

    const n = exp.items.len;
    var seq = try a.alloc(Pt, n + 1);
    defer a.free(seq);
    for (0..n) |k| seq[k] = exp.items[(rot + k) % n];
    seq[n] = seq[0]; // close

    var cur = seq[0];
    var idx: usize = 1;
    while (idx < seq.len) {
        const p = seq[idx];
        if (p.on) {
            try edges.append(a, .{ .x0 = cur.x, .y0 = cur.y, .x1 = p.x, .y1 = p.y });
            cur = p;
            idx += 1;
        } else {
            const ctrl = p;
            const e = seq[idx + 1]; // guaranteed on-curve
            var t: u32 = 1;
            var prev = cur;
            while (t <= BEZIER_STEPS) : (t += 1) {
                const u = @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(BEZIER_STEPS));
                const mu = 1.0 - u;
                const qx = mu * mu * cur.x + 2 * mu * u * ctrl.x + u * u * e.x;
                const qy = mu * mu * cur.y + 2 * mu * u * ctrl.y + u * u * e.y;
                try edges.append(a, .{ .x0 = prev.x, .y0 = prev.y, .x1 = qx, .y1 = qy });
                prev = .{ .x = qx, .y = qy, .on = true };
            }
            cur = e;
            idx += 2;
        }
    }
}

/// Nonzero-winding scanline fill into a CELL_W x CELL_H 1-bit cell.
/// Returns 16 bytes (one per row, MSB = leftmost pixel).
fn rasterize(edges: []const Edge, a: std.mem.Allocator) ![CELL_H]u8 {
    var cell = [_]u8{0} ** CELL_H;
    var xs: std.ArrayList(XCross) = .empty;
    defer xs.deinit(a);

    var row: u32 = 0;
    while (row < CELL_H) : (row += 1) {
        const yc = @as(f64, @floatFromInt(row)) + 0.5;
        xs.clearRetainingCapacity();
        for (edges) |e| {
            const y0 = e.y0;
            const y1 = e.y1;
            if (y0 == y1) continue;
            const lo = @min(y0, y1);
            const hi = @max(y0, y1);
            if (yc < lo or yc >= hi) continue;
            const t = (yc - y0) / (y1 - y0);
            const x = e.x0 + t * (e.x1 - e.x0);
            try xs.append(a, .{ .x = x, .dir = if (y1 > y0) 1 else -1 });
        }
        if (xs.items.len < 2) continue;
        std.sort.pdq(XCross, xs.items, {}, struct {
            fn lt(_: void, p: XCross, q: XCross) bool {
                return p.x < q.x;
            }
        }.lt);

        var wind: i32 = 0;
        var i: usize = 0;
        while (i + 1 < xs.items.len) : (i += 1) {
            wind += xs.items[i].dir;
            if (wind == 0) continue;
            const xa = xs.items[i].x;
            const xb = xs.items[i + 1].x;
            var col: u32 = 0;
            while (col < CELL_W) : (col += 1) {
                const xc = @as(f64, @floatFromInt(col)) + 0.5;
                if (xc >= xa and xc < xb) {
                    cell[row] |= @as(u8, 0x80) >> @intCast(col);
                }
            }
        }
    }
    return cell;
}

const Opts = struct {
    // Optional overrides; when null they are derived from font metrics.
    xscale: ?f64 = null,
    yscale: ?f64 = null,
    baseline: ?f64 = null,
    xoff: f64 = 0.0,
    preview: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    var ait = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    defer ait.deinit();
    const prog = ait.next() orelse "ttf2bdf";
    const input_path = ait.next();
    const output_path = ait.next();
    if (input_path == null or output_path == null) {
        std.debug.print("Usage: {s} <input.ttf> <output.bdf> [--baseline B] [--xscale S] [--yscale S] [--xoff X] [--preview]\n", .{prog});
        std.process.exit(1);
    }
    var opts = Opts{};
    while (ait.next()) |arg| {
        if (std.mem.eql(u8, arg, "--preview")) {
            opts.preview = true;
        } else if (std.mem.eql(u8, arg, "--xscale")) {
            const val = ait.next() orelse fatal("missing value for --xscale");
            opts.xscale = std.fmt.parseFloat(f64, val) catch fatal("invalid value for --xscale");
        } else if (std.mem.eql(u8, arg, "--yscale")) {
            const val = ait.next() orelse fatal("missing value for --yscale");
            opts.yscale = std.fmt.parseFloat(f64, val) catch fatal("invalid value for --yscale");
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            const val = ait.next() orelse fatal("missing value for --baseline");
            opts.baseline = std.fmt.parseFloat(f64, val) catch fatal("invalid value for --baseline");
        } else if (std.mem.eql(u8, arg, "--xoff")) {
            const val = ait.next() orelse fatal("missing value for --xoff");
            opts.xoff = std.fmt.parseFloat(f64, val) catch fatal("invalid value for --xoff");
        } else {
            std.debug.print("error: unknown option '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, input_path.?, a, .unlimited);

    requireBytes(data, 0, 4);
    if (rdU32(data, 0) != 0x00010000 and !std.mem.eql(u8, data[0..4], "true")) {
        std.debug.print("error: not a TrueType (glyf) font; CFF/OTF is unsupported\n", .{});
        std.process.exit(1);
    }

    const off_head = findTable(data, "head") orelse fatal("missing head");
    const off_maxp = findTable(data, "maxp") orelse fatal("missing maxp");
    const off_hhea = findTable(data, "hhea") orelse fatal("missing hhea");
    const off_hmtx = findTable(data, "hmtx") orelse fatal("missing hmtx");
    const off_loca = findTable(data, "loca") orelse fatal("missing loca (CFF font?)");
    const off_glyf = findTable(data, "glyf") orelse fatal("missing glyf (CFF font?)");
    const off_cmap = findTable(data, "cmap") orelse fatal("missing cmap");

    const font = Font{
        .data = data,
        .units_per_em = @floatFromInt(rdU16(data, off_head + 18)),
        .num_glyphs = rdU16(data, off_maxp + 4),
        .loc_long = rdI16(data, off_head + 50) != 0,
        .off_loca = off_loca,
        .off_glyf = off_glyf,
        .off_cmap = off_cmap,
    };

    // Derive the unit->pixel mapping from font metrics so the cell is filled:
    //  - horizontal: advance width -> CELL_W
    //  - vertical:   ascent..descent span -> CELL_H, baseline at ascent
    const advance: f64 = @floatFromInt(rdU16(data, off_hmtx)); // advanceWidth[0]
    const ascent: f64 = @floatFromInt(rdI16(data, off_hhea + 4));
    const descent: f64 = @floatFromInt(rdI16(data, off_hhea + 6)); // negative
    const scale_x = opts.xscale orelse (@as(f64, @floatFromInt(CELL_W)) / advance);
    const scale_y = opts.yscale orelse (@as(f64, @floatFromInt(CELL_H)) / (ascent - descent));
    const baseline = opts.baseline orelse (ascent * scale_y);
    const ydescent_rows = @as(i32, @intCast(CELL_H)) - @as(i32, @intFromFloat(@round(baseline)));

    // Build codepoint -> glyph id from a Unicode cmap format-4 subtable.
    var map = std.AutoHashMap(u21, u16).init(a);
    try parseCmap4(data, off_cmap, &map);

    var out: std.ArrayList(u8) = .empty;
    try out.print(a,
        \\STARTFONT 2.1
        \\FONT -zt-TopazNG-Medium-R-Normal--16-160-75-75-C-80-ISO10646-1
        \\SIZE 16 75 75
        \\FONTBOUNDINGBOX {d} {d} 0 {d}
        \\CHARS {d}
        \\
    , .{ CELL_W, CELL_H, -ydescent_rows, map.count() });

    var rendered: u32 = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        const cp = entry.key_ptr.*;
        const gid = entry.value_ptr.*;
        if (gid >= font.num_glyphs) fatal("cmap references glyph id beyond maxp numGlyphs");

        var glyph_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer glyph_arena.deinit();
        const ga = glyph_arena.allocator();

        var contours: std.ArrayList([]Pt) = .empty;
        var edges: std.ArrayList(Edge) = .empty;

        // Unit -> pixel transform baked into the collected contour points.
        const xf = Xform{
            .a = scale_x,
            .d = -scale_y,
            .e = opts.xoff,
            .f = baseline,
        };
        try collectGlyph(font, gid, xf, 0, ga, &contours);

        for (contours.items) |c| try flattenContour(c, ga, &edges);
        const cell = try rasterize(edges.items, ga);

        try out.print(a,
            \\STARTCHAR U+{X:0>4}
            \\ENCODING {d}
            \\SWIDTH 500 0
            \\DWIDTH {d} 0
            \\BBX {d} {d} 0 {d}
            \\BITMAP
            \\
        , .{ cp, cp, CELL_W, CELL_W, CELL_H, -ydescent_rows });
        for (cell) |byte| try out.print(a, "{X:0>2}\n", .{byte});
        try out.appendSlice(a, "ENDCHAR\n");
        rendered += 1;

        if (opts.preview and isPreviewCp(cp)) previewCell(cp, cell);
    }
    try out.appendSlice(a, "ENDFONT\n");

    try cwd.writeFile(io, .{ .sub_path = output_path.?, .data = out.items });
    std.debug.print("Rendered {d} glyphs at {d}x{d} (scale_x={d:.5}, scale_y={d:.5}, baseline={d:.2})\n", .{ rendered, CELL_W, CELL_H, scale_x, scale_y, baseline });
}

fn fatal(comptime msg: []const u8) noreturn {
    std.debug.print("error: {s}\n", .{msg});
    std.process.exit(1);
}

fn parseCmap4(d: []const u8, off_cmap: usize, map: *std.AutoHashMap(u21, u16)) !void {
    const ntab = rdU16(d, off_cmap + 2);
    var best: ?usize = null;
    var i: usize = 0;
    while (i < ntab) : (i += 1) {
        const rec = off_cmap + 4 + i * 8;
        const pid = rdU16(d, rec);
        const eid = rdU16(d, rec + 2);
        const so = rdU32(d, rec + 4);
        const fmt = rdU16(d, off_cmap + so);
        const unicode = (pid == 3 and (eid == 1 or eid == 10)) or pid == 0;
        if (fmt == 4 and unicode) {
            best = off_cmap + so;
            if (pid == 3 and eid == 1) break; // prefer Windows BMP
        }
    }
    const sub = best orelse fatal("no Unicode cmap format-4 subtable");
    const seg_x2 = rdU16(d, sub + 6);
    const segs = seg_x2 / 2;
    const end_o = sub + 14;
    const start_o = end_o + seg_x2 + 2;
    const delta_o = start_o + seg_x2;
    const range_o = delta_o + seg_x2;
    for (0..segs) |s| {
        const end_c = rdU16(d, end_o + s * 2);
        const start_c = rdU16(d, start_o + s * 2);
        const delta = rdU16(d, delta_o + s * 2);
        const range = rdU16(d, range_o + s * 2);
        if (start_c == 0xFFFF) continue;
        var c: u32 = start_c;
        while (c <= end_c) : (c += 1) {
            var gid: u16 = 0;
            const cc: u16 = @truncate(c);
            if (range == 0) {
                gid = cc +% delta;
            } else {
                const gi_off = range_o + s * 2 + range + (c - start_c) * 2;
                const g = rdU16(d, gi_off);
                if (g != 0) gid = g +% delta;
            }
            if (gid != 0) try map.put(@intCast(c), gid);
        }
    }
}

fn isPreviewCp(cp: u21) bool {
    return switch (cp) {
        'A', 'a', 'g', 'M', 'x', '0', '@', 0x2502, 0x2588, 0x250C => true,
        else => false,
    };
}

fn previewCell(cp: u21, cell: [CELL_H]u8) void {
    std.debug.print("U+{X:0>4}:\n", .{cp});
    for (cell) |byte| {
        var col: u32 = 0;
        var line = [_]u8{'.'} ** CELL_W;
        while (col < CELL_W) : (col += 1) {
            if (byte & (@as(u8, 0x80) >> @intCast(col)) != 0) line[col] = '#';
        }
        std.debug.print("  {s}\n", .{line});
    }
}
