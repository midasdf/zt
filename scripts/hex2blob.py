#!/usr/bin/env python3
"""Convert GNU Unifont HEX format to zt font blob.

Usage: python3 hex2blob.py <input.hex> <output.bin> [--range START-END ...]

The HEX format is: CODEPOINT:HEXBITMAP (one per line)
- 32 hex digits = 8x16 (half-width)
- 64 hex digits = 16x16 (full-width)
"""

import struct
import sys


def parse_hex_file(path, ranges=None):
    """Parse a Unifont HEX file, optionally filtering by codepoint ranges."""
    glyphs = []
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or ':' not in line:
                continue
            cp_str, hex_data = line.split(':', 1)
            cp = int(cp_str, 16)

            # Filter by range if specified
            if ranges:
                if not any(start <= cp <= end for start, end in ranges):
                    continue

            bitmap = bytes.fromhex(hex_data)
            if len(bitmap) == 16:
                w, h = 8, 16
            elif len(bitmap) == 32:
                w, h = 16, 16
            else:
                continue  # skip unusual sizes

            glyphs.append((cp, w, h, bitmap))

    return glyphs


def write_blob(glyphs, path):
    """Write glyphs in zt blob format."""
    glyphs.sort(key=lambda g: g[0])

    bitmap_data = bytearray()
    entries = []
    for cp, w, h, bmp in glyphs:
        offset = len(bitmap_data)
        bitmap_data.extend(bmp)
        entries.append((cp, w, h, offset, len(bmp)))

    with open(path, 'wb') as f:
        f.write(struct.pack('<II', len(entries), len(bitmap_data)))
        for cp, w, h, offset, bmp_len in entries:
            f.write(struct.pack('<IHHIHH', cp, w, h, offset, bmp_len, 0))
        f.write(bitmap_data)

    print(f"Written {len(entries)} glyphs, {len(bitmap_data)} bitmap bytes")
    print(f"Total: {8 + len(entries) * 16 + len(bitmap_data)} bytes")


def parse_range(s):
    """Parse 'START-END' hex range."""
    parts = s.split('-')
    return (int(parts[0], 16), int(parts[1], 16))


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input.hex> <output.bin> [--range START-END ...]")
        sys.exit(1)

    hex_path = sys.argv[1]
    out_path = sys.argv[2]

    ranges = []
    i = 3
    while i < len(sys.argv):
        if sys.argv[i] == '--range' and i + 1 < len(sys.argv):
            ranges.append(parse_range(sys.argv[i + 1]))
            i += 2
        else:
            i += 1

    glyphs = parse_hex_file(hex_path, ranges if ranges else None)
    print(f"Parsed {len(glyphs)} glyphs from {hex_path}")
    write_blob(glyphs, out_path)
