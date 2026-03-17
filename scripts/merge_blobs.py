#!/usr/bin/env python3
"""Merge two font blobs. Base font takes priority; supplement fills gaps.

Usage: python3 merge_blobs.py <base.bin> <supplement.bin> <output.bin>
"""

import struct
import sys


def read_blob(path):
    with open(path, 'rb') as f:
        data = f.read()

    glyph_count = struct.unpack_from('<I', data, 0)[0]
    bitmap_total = struct.unpack_from('<I', data, 4)[0]
    table_off = 8
    bitmap_off = table_off + glyph_count * 16

    glyphs = []
    for i in range(glyph_count):
        off = table_off + i * 16
        cp, w, h, bmp_offset, bmp_len, _ = struct.unpack_from('<IHHIHH', data, off)
        bmp = data[bitmap_off + bmp_offset: bitmap_off + bmp_offset + bmp_len]
        glyphs.append((cp, w, h, bmp))

    return glyphs


def write_blob(glyphs, path):
    # Sort by codepoint
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


if __name__ == '__main__':
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <base.bin> <supplement.bin> <output.bin>")
        sys.exit(1)

    base = read_blob(sys.argv[1])
    supplement = read_blob(sys.argv[2])

    base_cps = {g[0] for g in base}
    added = 0
    for g in supplement:
        if g[0] not in base_cps:
            base.append(g)
            added += 1

    print(f"Base: {len(base_cps)} glyphs")
    print(f"Added from supplement: {added} glyphs")

    write_blob(base, sys.argv[3])
