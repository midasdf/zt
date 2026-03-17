#!/usr/bin/env python3
"""Convert BDF font to a binary blob for zt's font module.

Binary format:
  Header:
    u32 LE: glyph_count
    u32 LE: bitmap_data_total_bytes
  Glyph table (glyph_count entries, sorted by codepoint):
    u32 LE: codepoint
    u16 LE: width
    u16 LE: height
    u32 LE: bitmap_offset (into bitmap data)
    u16 LE: bitmap_len (bytes)
    u16 LE: padding (0)
  Bitmap data:
    Raw bitmap bytes (1 bit per pixel, row-major, packed)
"""

import struct
import sys
import re


def parse_bdf(path):
    glyphs = []
    with open(path, 'r') as f:
        in_char = False
        in_bitmap = False
        codepoint = 0
        width = 0
        height = 0
        bitmap_rows = []

        for line in f:
            line = line.strip()
            if line.startswith('STARTCHAR'):
                in_char = True
                codepoint = 0
                width = 0
                height = 0
                bitmap_rows = []
            elif line.startswith('ENCODING'):
                codepoint = int(line.split()[1])
            elif line.startswith('BBX'):
                parts = line.split()
                width = int(parts[1])
                height = int(parts[2])
            elif line == 'BITMAP':
                in_bitmap = True
            elif line == 'ENDCHAR':
                if in_bitmap and codepoint >= 0:
                    bitmap_bytes = b''
                    for row_hex in bitmap_rows:
                        bitmap_bytes += bytes.fromhex(row_hex)
                    glyphs.append((codepoint, width, height, bitmap_bytes))
                in_char = False
                in_bitmap = False
            elif in_bitmap:
                bitmap_rows.append(line)

    # Sort by codepoint
    glyphs.sort(key=lambda g: g[0])
    return glyphs


def write_blob(glyphs, output_path):
    glyph_count = len(glyphs)

    # Build bitmap data blob
    bitmap_data = bytearray()
    glyph_entries = []

    for cp, w, h, bmp in glyphs:
        offset = len(bitmap_data)
        bitmap_data.extend(bmp)
        glyph_entries.append((cp, w, h, offset, len(bmp)))

    bitmap_total = len(bitmap_data)

    with open(output_path, 'wb') as f:
        # Header
        f.write(struct.pack('<II', glyph_count, bitmap_total))

        # Glyph table
        for cp, w, h, offset, bmp_len in glyph_entries:
            f.write(struct.pack('<IHHIHH', cp, w, h, offset, bmp_len, 0))

        # Bitmap data
        f.write(bitmap_data)

    print(f"Written {glyph_count} glyphs, {bitmap_total} bitmap bytes")
    print(f"Glyph table: {glyph_count * 16} bytes")
    print(f"Total blob: {8 + glyph_count * 16 + bitmap_total} bytes")


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.bdf> <output.bin>")
        sys.exit(1)

    glyphs = parse_bdf(sys.argv[1])
    write_blob(glyphs, sys.argv[2])
