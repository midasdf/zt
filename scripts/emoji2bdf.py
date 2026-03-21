#!/usr/bin/env python3
"""Generate monochrome emoji BDF font by rendering NotoColorEmoji via Pillow.

Usage: python3 emoji2bdf.py <output.bdf> [pixel_size]

Renders emoji at a large size and downscales to pixel_size (default 16).
Output is 16px wide (full-width) monochrome glyphs.
"""

import sys
import struct
from PIL import Image, ImageFont, ImageDraw

# Emoji ranges to include
EMOJI_RANGES = [
    (0x231A, 0x231B),   # Watch, Hourglass
    (0x23E9, 0x23F3),   # Playback symbols
    (0x23F8, 0x23FA),   # Playback symbols
    (0x25AA, 0x25AB),   # Small squares
    (0x25B6, 0x25B6),   # Play button
    (0x25C0, 0x25C0),   # Reverse button
    (0x25FB, 0x25FE),   # Medium squares
    (0x2614, 0x2615),   # Umbrella, hot beverage
    (0x2648, 0x2653),   # Zodiac
    (0x267F, 0x267F),   # Wheelchair
    (0x2693, 0x2693),   # Anchor
    (0x26A1, 0x26A1),   # Lightning
    (0x26AA, 0x26AB),   # Circles
    (0x26BD, 0x26BE),   # Sports
    (0x26C4, 0x26C5),   # Snowman, sun
    (0x26D4, 0x26D4),   # No entry
    (0x26EA, 0x26EA),   # Church
    (0x26F2, 0x26F3),   # Fountain, golf
    (0x26F5, 0x26F5),   # Sailboat
    (0x26FA, 0x26FA),   # Tent
    (0x26FD, 0x26FD),   # Fuel pump
    (0x2702, 0x2702),   # Scissors
    (0x2705, 0x2705),   # Check mark
    (0x2708, 0x270D),   # Various
    (0x270F, 0x270F),   # Pencil
    (0x2712, 0x2712),   # Black nib
    (0x2714, 0x2714),   # Check mark
    (0x2716, 0x2716),   # X mark
    (0x271D, 0x271D),   # Cross
    (0x2721, 0x2721),   # Star of David
    (0x2728, 0x2728),   # Sparkles
    (0x2733, 0x2734),   # Asterisks
    (0x2744, 0x2744),   # Snowflake
    (0x2747, 0x2747),   # Sparkle
    (0x274C, 0x274C),   # Cross mark
    (0x274E, 0x274E),   # Cross mark
    (0x2753, 0x2755),   # Question/exclamation
    (0x2757, 0x2757),   # Exclamation
    (0x2763, 0x2764),   # Hearts
    (0x2795, 0x2797),   # Math
    (0x27A1, 0x27A1),   # Right arrow
    (0x27B0, 0x27B0),   # Curly loop
    (0x27BF, 0x27BF),   # Double curly loop
    (0x2934, 0x2935),   # Arrows
    (0x2B05, 0x2B07),   # Arrows
    (0x2B1B, 0x2B1C),   # Squares
    (0x2B50, 0x2B50),   # Star
    (0x2B55, 0x2B55),   # Circle
    (0x1F004, 0x1F004), # Mahjong
    (0x1F0CF, 0x1F0CF), # Joker
    (0x1F170, 0x1F171), # A/B buttons
    (0x1F17E, 0x1F17F), # O/P buttons
    (0x1F18E, 0x1F18E), # AB button
    (0x1F191, 0x1F19A), # Squared words
    (0x1F1E0, 0x1F1FF), # Regional indicators (flags)
    (0x1F201, 0x1F202), # Japanese symbols
    (0x1F21A, 0x1F21A),
    (0x1F22F, 0x1F22F),
    (0x1F232, 0x1F23A),
    (0x1F250, 0x1F251),
    (0x1F300, 0x1F321), # Weather, nature
    (0x1F324, 0x1F393), # More weather, objects
    (0x1F396, 0x1F397),
    (0x1F399, 0x1F39B),
    (0x1F39E, 0x1F3F0), # Entertainment
    (0x1F3F3, 0x1F3F5),
    (0x1F3F7, 0x1F4FD), # Objects
    (0x1F4FF, 0x1F53D), # More objects
    (0x1F549, 0x1F54E),
    (0x1F550, 0x1F567), # Clock faces
    (0x1F56F, 0x1F570),
    (0x1F573, 0x1F57A),
    (0x1F587, 0x1F587),
    (0x1F58A, 0x1F58D),
    (0x1F590, 0x1F590),
    (0x1F595, 0x1F596),
    (0x1F5A4, 0x1F5A5),
    (0x1F5A8, 0x1F5A8),
    (0x1F5B1, 0x1F5B2),
    (0x1F5BC, 0x1F5BC),
    (0x1F5C2, 0x1F5C4),
    (0x1F5D1, 0x1F5D3),
    (0x1F5DC, 0x1F5DE),
    (0x1F5E1, 0x1F5E1),
    (0x1F5E3, 0x1F5E3),
    (0x1F5E8, 0x1F5E8),
    (0x1F5EF, 0x1F5EF),
    (0x1F5F3, 0x1F5F3),
    (0x1F5FA, 0x1F64F), # Maps, people
    (0x1F680, 0x1F6C5), # Transport
    (0x1F6CB, 0x1F6D2),
    (0x1F6D5, 0x1F6D7),
    (0x1F6E0, 0x1F6E5),
    (0x1F6E9, 0x1F6E9),
    (0x1F6EB, 0x1F6EC),
    (0x1F6F0, 0x1F6F0),
    (0x1F6F3, 0x1F6FC),
    (0x1F7E0, 0x1F7EB), # Colored circles/squares
    (0x1F90C, 0x1F93A),
    (0x1F93C, 0x1F945),
    (0x1F947, 0x1F9FF), # People, body, food, etc.
    (0x1FA00, 0x1FA53),
    (0x1FA60, 0x1FA6D),
    (0x1FA70, 0x1FA74),
    (0x1FA78, 0x1FA7A),
    (0x1FA80, 0x1FA86),
    (0x1FA90, 0x1FAA8),
    (0x1FAB0, 0x1FAB6),
    (0x1FAC0, 0x1FAC2),
    (0x1FAD0, 0x1FAD6),
]


def render_emoji(font, cp, cell_w, cell_h, render_size):
    """Render an emoji to a monochrome bitmap."""
    char = chr(cp)

    try:
        bbox = font.getbbox(char)
    except Exception:
        return None
    if bbox is None:
        return None

    # Render at large size
    big = Image.new('L', (render_size, render_size), 0)
    draw = ImageDraw.Draw(big)

    # Center the glyph
    gw = bbox[2] - bbox[0]
    gh = bbox[3] - bbox[1]
    x_off = (render_size - gw) // 2 - bbox[0]
    y_off = (render_size - gh) // 2 - bbox[1]
    draw.text((x_off, y_off), char, fill=255, font=font)

    # Downscale to cell size with antialiasing
    small = big.resize((cell_w, cell_h), Image.LANCZOS)

    # Convert to 1-bit bitmap
    pixels = small.load()
    bytes_per_row = (cell_w + 7) // 8
    rows = []
    all_zero = True

    for y in range(cell_h):
        row_bytes = []
        for byte_idx in range(bytes_per_row):
            val = 0
            for bit in range(8):
                px = byte_idx * 8 + bit
                if px < cell_w and pixels[px, y] > 80:  # threshold
                    val |= (0x80 >> bit)
                    all_zero = False
            row_bytes.append(val)
        rows.append(row_bytes)

    if all_zero:
        return None
    return rows


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <output.bdf> [pixel_size]")
        sys.exit(1)

    bdf_path = sys.argv[1]
    pixel_size = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    cell_w = pixel_size  # full-width emoji
    cell_h = pixel_size

    emoji_font_path = '/usr/share/fonts/noto/NotoColorEmoji.ttf'

    # NotoColorEmoji only works at size 109
    try:
        font = ImageFont.truetype(emoji_font_path, 109)
    except Exception as e:
        print(f"Cannot load {emoji_font_path}: {e}")
        print("Trying system default...")
        # Fallback: try Symbola or other emoji-capable fonts
        for path in ['/usr/share/fonts/TTF/Symbola.ttf',
                     '/usr/share/fonts/noto/NotoEmoji-Regular.ttf']:
            try:
                font = ImageFont.truetype(path, pixel_size * 4)
                break
            except Exception:
                continue
        else:
            print("No emoji font found!")
            sys.exit(1)

    render_size = 128  # render at this size before downscaling

    glyphs = []
    for start, end in EMOJI_RANGES:
        for cp in range(start, end + 1):
            bitmap = render_emoji(font, cp, cell_w, cell_h, render_size)
            if bitmap is not None:
                glyphs.append((cp, cell_w, cell_h, bitmap))

    print(f"Rendered {len(glyphs)} emoji glyphs at {pixel_size}px")

    # Write BDF
    with open(bdf_path, 'w') as f:
        f.write("STARTFONT 2.1\n")
        f.write(f"FONT -Emoji-Medium-R-Normal--{cell_h}-{cell_h*10}-72-72-C-{cell_w*10}-ISO10646-1\n")
        f.write(f"SIZE {cell_h} 72 72\n")
        f.write(f"FONTBOUNDINGBOX {cell_w} {cell_h} 0 0\n")
        f.write(f"STARTPROPERTIES 3\n")
        f.write(f"FONT_ASCENT {cell_h}\n")
        f.write(f"FONT_DESCENT 0\n")
        f.write(f"DEFAULT_CHAR 32\n")
        f.write(f"ENDPROPERTIES\n")
        f.write(f"CHARS {len(glyphs)}\n")

        for cp, w, h, bitmap in glyphs:
            name = f"U+{cp:04X}"
            bytes_per_row = (w + 7) // 8

            f.write(f"STARTCHAR {name}\n")
            f.write(f"ENCODING {cp}\n")
            f.write(f"SWIDTH {w * 1000 // cell_h} 0\n")
            f.write(f"DWIDTH {w} 0\n")
            f.write(f"BBX {w} {h} 0 0\n")
            f.write("BITMAP\n")
            for row in bitmap:
                hex_str = ''.join(f"{b:02X}" for b in row)
                f.write(f"{hex_str}\n")
            f.write("ENDCHAR\n")

        f.write("ENDFONT\n")

    print(f"Written to {bdf_path}")


if __name__ == '__main__':
    main()
