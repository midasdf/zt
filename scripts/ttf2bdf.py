#!/usr/bin/env python3
"""Convert a TTF/OTF font to BDF format by rendering glyphs with Pillow.

Usage: python3 ttf2bdf.py <input.ttf> <output.bdf> [pixel_size]

Renders each glyph at the given pixel size and outputs a BDF file.
Half-width chars get 8px wide cells, full-width (CJK) get 16px wide.
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


def render_glyph(font, cp: int, cell_w: int, cell_h: int, ascent: int) -> list[int] | None:
    """Render a single glyph, return list of bitmap row bytes, or None if empty."""
    char = chr(cp)

    # Check if font has this glyph
    try:
        bbox = font.getbbox(char)
    except Exception:
        return None

    if bbox is None:
        return None

    # Render onto an image
    img = Image.new('L', (cell_w, cell_h), 0)
    draw = ImageDraw.Draw(img)

    # Center the glyph horizontally, align to baseline
    glyph_bbox = font.getbbox(char)
    glyph_w = glyph_bbox[2] - glyph_bbox[0]
    x_offset = max(0, (cell_w - glyph_w) // 2) - glyph_bbox[0]
    y_offset = ascent - font.getmetrics()[0]  # rough baseline alignment

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

    if all_zero and cp != 0x20:  # space is allowed to be all zero
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

    print(f"Render size: {render_size}px, ascent={ascent}, descent={descent}, cell={cell_h}px")

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
        (0x2500, 0x257F),   # Box Drawing
        (0x2580, 0x259F),   # Block Elements
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
            bitmap = render_glyph(font, cp, w, cell_h, ascent)
            if bitmap is not None:
                glyphs.append((cp, w, cell_h, bitmap))

    print(f"Rendered {len(glyphs)} glyphs at {pixel_size}px")

    # Write BDF
    font_name = f"-PlemolJP-ConsoleNF-Medium-R-Normal--{cell_h}-{cell_h*10}-72-72-C-{half_w*10}-ISO10646-1"

    with open(bdf_path, 'w') as f:
        f.write("STARTFONT 2.1\n")
        f.write(f"FONT {font_name}\n")
        f.write(f"SIZE {cell_h} 72 72\n")
        f.write(f"FONTBOUNDINGBOX {full_w} {cell_h} 0 0\n")
        f.write(f"STARTPROPERTIES 4\n")
        f.write(f"FONT_ASCENT {ascent}\n")
        f.write(f"FONT_DESCENT {cell_h - ascent}\n")
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
