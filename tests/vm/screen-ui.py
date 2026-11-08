#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Does a screenshot show real UI, or only the wallpaper (docs/TESTING.md, "Level 2 on aarch64")?
#   screen-ui.py MIN OUT SHOT.png...
# Counts the sharp horizontal colour edges in the bottom 7 % of each screenshot (QEMU's screendump, an
# 8-bit RGB PNG), in the given order, and copies the first with at least MIN of them to OUT. Exit 1 when none
# has. Why the bottom strip: the greeter's session and keyboard labels and Plasma's panel are there, and the
# wallpaper and the lock screen (a clock in the upper part) are not. The wallpaper's own edges are soft: its
# strip counts 0, the greeter's about 1200 and the panel's about 800, so MIN 300 separates them with room.
import shutil
import struct
import sys
import zlib

EDGE = 150  # the summed difference of the three channels between two neighbouring pixels


def bottom_strip_edges(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{path}: not a PNG file")
    pos, idat = 8, b""
    while pos < len(data):
        size, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + size]
        pos += 12 + size
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"IDAT":
            idat += chunk
    if depth != 8 or colour not in (2, 6) or interlace:
        sys.exit(f"{path}: expected an 8-bit RGB(A) PNG without interlacing")
    bpp = 3 if colour == 2 else 4
    stride, raw = width * bpp, zlib.decompress(idat)
    prev, count = bytearray(stride), 0
    for y in range(height):
        base = y * (stride + 1)
        kind, row = raw[base], bytearray(raw[base + 1:base + 1 + stride])
        for x in range(stride):  # undo the PNG row filter
            a = row[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if kind == 1:
                row[x] = (row[x] + a) & 255
            elif kind == 2:
                row[x] = (row[x] + b) & 255
            elif kind == 3:
                row[x] = (row[x] + (a + b) // 2) & 255
            elif kind == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                row[x] = (row[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        if y >= height * 93 // 100:
            for x in range(bpp, stride, bpp):
                if sum(abs(row[x + i] - row[x - bpp + i]) for i in range(3)) >= EDGE:
                    count += 1
        prev = row
    return count


minimum, out, shots = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
for shot in shots:
    edges = bottom_strip_edges(shot)
    print(f"{shot}: {edges} edges in the bottom strip (at least {minimum} means UI)")
    if edges >= minimum:
        shutil.copyfile(shot, out)
        print(f"{out}: copied from {shot}")
        sys.exit(0)
sys.exit(f"no screenshot shows UI (only the wallpaper or a lock screen): {' '.join(shots)}")
