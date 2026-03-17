#!/usr/bin/env python3
"""Convert a TTF/OTF font to BDF format by rendering glyphs with Pillow.

Usage: python3 ttf2bdf.py <input.ttf> <output.bdf> [pixel_size]

Renders each glyph at the given pixel size and outputs a BDF file.
Half-width chars get cell_w/2 wide cells, full-width (CJK) get cell_w wide.
Box Drawing characters (U+2500-257F) are rendered procedurally.
"""

import sys
import unicodedata
from PIL import Image, ImageFont, ImageDraw


def is_wide(cp: int) -> bool:
    """Check if a codepoint is East Asian wide/fullwidth."""
    try:
        eaw = unicodedata.east_asian_width(chr(cp))
        return eaw in ('W', 'F')
    except (ValueError, OverflowError):
        return False


def render_box_drawing(cp: int, cell_w: int, cell_h: int) -> list[list[int]] | None:
    """Procedurally render Box Drawing characters (U+2500-257F)."""
    if cp < 0x2500 or cp > 0x257F:
        return None

    img = Image.new('L', (cell_w, cell_h), 0)
    draw = ImageDraw.Draw(img)

    cx = cell_w // 2  # center x
    cy = cell_h // 2  # center y
    lw = 1  # line width for light
    hw = 3  # line width for heavy

    # Box drawing encoding: which sides have lines
    # Format: (left, right, up, down) — 0=none, 1=light, 2=heavy, 3=double
    box_map = {
        0x2500: (1,1,0,0), 0x2501: (2,2,0,0), 0x2502: (0,0,1,1), 0x2503: (0,0,2,2),
        0x250C: (0,1,0,1), 0x250D: (0,2,0,1), 0x250E: (0,1,0,2), 0x250F: (0,2,0,2),
        0x2510: (1,0,0,1), 0x2511: (2,0,0,1), 0x2512: (1,0,0,2), 0x2513: (2,0,0,2),
        0x2514: (0,1,1,0), 0x2515: (0,2,1,0), 0x2516: (0,1,2,0), 0x2517: (0,2,2,0),
        0x2518: (1,0,1,0), 0x2519: (2,0,1,0), 0x251A: (1,0,2,0), 0x251B: (2,0,2,0),
        0x251C: (0,1,1,1), 0x251D: (0,2,1,1), 0x251E: (0,1,2,1), 0x251F: (0,1,1,2),
        0x2520: (0,1,2,2), 0x2521: (0,2,2,1), 0x2522: (0,2,1,2), 0x2523: (0,2,2,2),
        0x2524: (1,0,1,1), 0x2525: (2,0,1,1), 0x2526: (1,0,2,1), 0x2527: (1,0,1,2),
        0x2528: (1,0,2,2), 0x2529: (2,0,2,1), 0x252A: (2,0,1,2), 0x252B: (2,0,2,2),
        0x252C: (1,1,0,1), 0x252D: (2,1,0,1), 0x252E: (1,2,0,1), 0x252F: (2,2,0,1),
        0x2530: (1,1,0,2), 0x2531: (2,1,0,2), 0x2532: (1,2,0,2), 0x2533: (2,2,0,2),
        0x2534: (1,1,1,0), 0x2535: (2,1,1,0), 0x2536: (1,2,1,0), 0x2537: (2,2,1,0),
        0x2538: (1,1,2,0), 0x2539: (2,1,2,0), 0x253A: (1,2,2,0), 0x253B: (2,2,2,0),
        0x253C: (1,1,1,1), 0x253D: (2,1,1,1), 0x253E: (1,2,1,1), 0x253F: (2,2,1,1),
        0x2540: (1,1,2,1), 0x2541: (1,1,1,2), 0x2542: (1,1,2,2),
        0x2543: (2,1,2,1), 0x2544: (1,2,2,1), 0x2545: (2,1,1,2), 0x2546: (1,2,1,2),
        0x2547: (2,2,2,1), 0x2548: (2,2,1,2), 0x2549: (2,1,2,2), 0x254A: (1,2,2,2),
        0x254B: (2,2,2,2),
    }

    # Block elements
    block_map = {
        0x2580: 'upper_half',  0x2584: 'lower_half',
        0x2588: 'full',        0x258C: 'left_half',
        0x2590: 'right_half',
        0x2591: 'light_shade', 0x2592: 'medium_shade', 0x2593: 'dark_shade',
    }

    if cp in box_map:
        left, right, up, down = box_map[cp]

        def w_for(strength):
            return hw if strength == 2 else lw

        if left:
            w = w_for(left)
            draw.rectangle([0, cy - w//2, cx, cy + w//2], fill=255)
        if right:
            w = w_for(right)
            draw.rectangle([cx, cy - w//2, cell_w - 1, cy + w//2], fill=255)
        if up:
            w = w_for(up)
            draw.rectangle([cx - w//2, 0, cx + w//2, cy], fill=255)
        if down:
            w = w_for(down)
            draw.rectangle([cx - w//2, cy, cx + w//2, cell_h - 1], fill=255)

    elif cp in block_map:
        kind = block_map[cp]
        if kind == 'full':
            draw.rectangle([0, 0, cell_w-1, cell_h-1], fill=255)
        elif kind == 'upper_half':
            draw.rectangle([0, 0, cell_w-1, cell_h//2-1], fill=255)
        elif kind == 'lower_half':
            draw.rectangle([0, cell_h//2, cell_w-1, cell_h-1], fill=255)
        elif kind == 'left_half':
            draw.rectangle([0, 0, cell_w//2-1, cell_h-1], fill=255)
        elif kind == 'right_half':
            draw.rectangle([cell_w//2, 0, cell_w-1, cell_h-1], fill=255)
        elif kind == 'light_shade':
            for y in range(cell_h):
                for x in range(cell_w):
                    if (x + y) % 4 == 0:
                        img.putpixel((x, y), 255)
        elif kind == 'medium_shade':
            for y in range(cell_h):
                for x in range(cell_w):
                    if (x + y) % 2 == 0:
                        img.putpixel((x, y), 255)
        elif kind == 'dark_shade':
            for y in range(cell_h):
                for x in range(cell_w):
                    if (x + y) % 4 != 0:
                        img.putpixel((x, y), 255)
    else:
        # Dashes, arcs, diagonals — fall through to font rendering
        return None

    # Convert to bitmap
    pixels = img.load()
    bytes_per_row = (cell_w + 7) // 8
    rows = []
    for y in range(cell_h):
        row_bytes = []
        for byte_idx in range(bytes_per_row):
            val = 0
            for bit in range(8):
                px = byte_idx * 8 + bit
                if px < cell_w and pixels[px, y] > 127:
                    val |= (0x80 >> bit)
            row_bytes.append(val)
        rows.append(row_bytes)
    return rows


def render_glyph(font, cp: int, cell_w: int, cell_h: int, y_pad: int) -> list[list[int]] | None:
    """Render a single glyph, return list of bitmap row bytes, or None if empty."""
    # Try procedural box drawing first
    box = render_box_drawing(cp, cell_w, cell_h)
    if box is not None:
        return box

    char = chr(cp)

    try:
        bbox = font.getbbox(char)
    except Exception:
        return None
    if bbox is None:
        return None

    img = Image.new('L', (cell_w, cell_h), 0)
    draw = ImageDraw.Draw(img)

    # Position glyph:
    # - x: left-aligned for monospace (with small centering adjustment)
    # - y: shifted down by y_pad to vertically center in cell
    glyph_bbox = font.getbbox(char)
    glyph_w = glyph_bbox[2] - glyph_bbox[0]

    # Horizontal: center in cell, compensate for bearing
    x_offset = max(0, (cell_w - glyph_w) // 2) - glyph_bbox[0]

    # Vertical: add padding to push baseline down into cell
    y_offset = y_pad

    draw.text((x_offset, y_offset), char, fill=255, font=font)

    # Convert to 1-bit bitmap rows
    pixels = img.load()
    bytes_per_row = (cell_w + 7) // 8
    rows = []
    all_zero = True

    for y in range(cell_h):
        row_bytes = []
        for byte_idx in range(bytes_per_row):
            val = 0
            for bit in range(8):
                px = byte_idx * 8 + bit
                if px < cell_w and pixels[px, y] > 127:
                    val |= (0x80 >> bit)
                    all_zero = False
            row_bytes.append(val)
        rows.append(row_bytes)

    if all_zero and cp != 0x20:
        return None

    return rows


def generate_bdf(ttf_path: str, bdf_path: str, pixel_size: int = 16):
    # Find the largest font size that fits in pixel_size cell height
    render_size = pixel_size
    for sz in range(pixel_size, 8, -1):
        test_font = ImageFont.truetype(ttf_path, sz)
        a, d = test_font.getmetrics()
        if a + d <= pixel_size:
            render_size = sz
            break

    font = ImageFont.truetype(ttf_path, render_size)
    ascent, descent = font.getmetrics()
    cell_h = pixel_size
    half_w = pixel_size // 2  # 8 for 16px
    full_w = pixel_size       # 16 for 16px

    # Calculate vertical padding to center text in cell
    total_font_height = ascent + descent
    y_pad = max(0, (cell_h - total_font_height) // 2)

    # Verify with 'A' positioning
    test_bbox = font.getbbox('A')
    # 'A' top should be near row 3-4 for comfortable reading
    a_top_at_ypad = test_bbox[1] + y_pad
    # If 'A' starts too high, add more padding
    if a_top_at_ypad < 2:
        y_pad += (2 - a_top_at_ypad)

    print(f"Render size: {render_size}px, ascent={ascent}, descent={descent}, cell={cell_h}px, y_pad={y_pad}")

    # Codepoint ranges to include
    ranges = [
        (0x0020, 0x007F),   # Basic ASCII
        (0x00A0, 0x00FF),   # Latin-1 Supplement
        (0x0100, 0x024F),   # Latin Extended-A/B
        (0x0300, 0x036F),   # Combining Diacritical Marks
        (0x2000, 0x206F),   # General Punctuation
        (0x2070, 0x209F),   # Superscripts and Subscripts
        (0x20A0, 0x20CF),   # Currency Symbols
        (0x2100, 0x214F),   # Letterlike Symbols
        (0x2190, 0x21FF),   # Arrows
        (0x2200, 0x22FF),   # Mathematical Operators
        (0x2300, 0x23FF),   # Misc Technical
        (0x2500, 0x257F),   # Box Drawing (procedural)
        (0x2580, 0x259F),   # Block Elements (procedural)
        (0x25A0, 0x25FF),   # Geometric Shapes
        (0x2600, 0x26FF),   # Misc Symbols
        (0x2700, 0x27BF),   # Dingbats
        (0x3000, 0x303F),   # CJK Symbols and Punctuation
        (0x3040, 0x309F),   # Hiragana
        (0x30A0, 0x30FF),   # Katakana
        (0x31F0, 0x31FF),   # Katakana Extension
        (0x3200, 0x32FF),   # Enclosed CJK Letters
        (0x3300, 0x33FF),   # CJK Compatibility
        (0x4E00, 0x9FFF),   # CJK Unified Ideographs
        (0xE000, 0xE0FF),   # Nerd Fonts (subset of PUA)
        (0xE100, 0xE1FF),   # Nerd Fonts
        (0xE200, 0xE2FF),   # Nerd Fonts
        (0xE700, 0xE7FF),   # Nerd Fonts (devicons etc)
        (0xF000, 0xF0FF),   # Nerd Fonts
        (0xF100, 0xF2FF),   # Nerd Fonts (Font Awesome)
        (0xF300, 0xF3FF),   # Nerd Fonts
        (0xF400, 0xF4FF),   # Nerd Fonts
        (0xF500, 0xF5FF),   # Nerd Fonts
        (0xFF00, 0xFF60),   # Fullwidth Forms
        (0xFF61, 0xFFEF),   # Halfwidth Forms
    ]

    # Render all glyphs
    glyphs = []
    for start, end in ranges:
        for cp in range(start, end + 1):
            wide = is_wide(cp)
            w = full_w if wide else half_w
            bitmap = render_glyph(font, cp, w, cell_h, y_pad)
            if bitmap is not None:
                glyphs.append((cp, w, cell_h, bitmap))

    print(f"Rendered {len(glyphs)} glyphs at {pixel_size}px")

    # Write BDF
    font_name = f"-PlemolJP-ConsoleNF-Medium-R-Normal--{cell_h}-{cell_h*10}-72-72-C-{half_w*10}-ISO10646-1"
    font_ascent = ascent + y_pad
    font_descent = cell_h - font_ascent

    with open(bdf_path, 'w') as f:
        f.write("STARTFONT 2.1\n")
        f.write(f"FONT {font_name}\n")
        f.write(f"SIZE {cell_h} 72 72\n")
        f.write(f"FONTBOUNDINGBOX {full_w} {cell_h} 0 0\n")
        f.write(f"STARTPROPERTIES 4\n")
        f.write(f"FONT_ASCENT {font_ascent}\n")
        f.write(f"FONT_DESCENT {font_descent}\n")
        f.write(f"DEFAULT_CHAR 32\n")
        f.write(f"SPACING \"C\"\n")
        f.write(f"ENDPROPERTIES\n")
        f.write(f"CHARS {len(glyphs)}\n")

        for cp, w, h, bitmap in glyphs:
            name = f"U+{cp:04X}"
            bytes_per_row = (w + 7) // 8
            dwidth = w

            f.write(f"STARTCHAR {name}\n")
            f.write(f"ENCODING {cp}\n")
            f.write(f"SWIDTH {dwidth * 1000 // cell_h} 0\n")
            f.write(f"DWIDTH {dwidth} 0\n")
            f.write(f"BBX {w} {h} 0 0\n")
            f.write("BITMAP\n")
            for row in bitmap:
                hex_str = ''.join(f"{b:02X}" for b in row)
                f.write(f"{hex_str}\n")
            f.write("ENDCHAR\n")

        f.write("ENDFONT\n")

    print(f"Written to {bdf_path}")


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input.ttf> <output.bdf> [pixel_size]")
        sys.exit(1)

    ttf = sys.argv[1]
    bdf = sys.argv[2]
    size = int(sys.argv[3]) if len(sys.argv) > 3 else 16

    generate_bdf(ttf, bdf, size)
