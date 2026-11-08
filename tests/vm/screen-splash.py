#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Does a screenshot show the boot screen (docs/TESTING.md, "The boot screen")?
#   screen-splash.py SHOT.png
# Reads QEMU's screendump (an 8-bit RGB PNG) and checks it against the theme in
# image/files/usr/share/plymouth/themes/nyra: the screen is the theme's dark background nearly
# everywhere, and in the middle there are the logo's white planet and the moon in the accent colour.
# Exits 0 when it does, 1 when it does not. The greeter, the desktop, a
# black screen and a text console all fail: each lacks the background, the white, or the blue.
# The sizes are shares of the screen's shorter side, as the theme's are, so the test does not depend on
# the VM's resolution.
import struct
import sys
import zlib

BACKGROUND = (11, 14, 20)  # nyra.script: 0.043, 0.055, 0.078 (plymouth draws it as 10, 14, 19)
ACCENT = (36, 89, 216)  # the moon, #2459D8 in the logo and the ring
NEAR = 30  # how far a channel may be from the colour and still count as it


def pixels(path):
    """The size of the image and its rows, each a bytes object of R, G, B (no alpha) per pixel."""
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
    prev, rows = bytearray(stride), []
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
        prev = row
        rows.append(bytes(row[i] for i in range(stride) if bpp == 3 or i % 4 != 3))
    return width, height, rows


def near(p, colour):
    return all(abs(p[i] - colour[i]) <= NEAR for i in range(3))


(shot,) = sys.argv[1:]
width, height, rows = pixels(shot)
unit = min(width, height)
middle = range(width // 2 - unit // 4, width // 2 + unit // 4)  # the middle square, half of the shorter side
background = white = blue = 0
for y, row in enumerate(rows):
    for x in range(width):
        p = row[3 * x:3 * x + 3]
        if near(p, BACKGROUND):
            background += 1
        elif x in middle and abs(y - height // 2) < unit // 4:
            white += min(p) >= 230
            blue += near(p, ACCENT)
share = background / (width * height)
print(f"{shot}: {width}x{height}, background {share:.1%}, white {white} and blue {blue} pixels in the middle")
# The logo's planet is about 0.4 % of the shorter side squared, the moon 0.06 %: half of each.
if share >= 0.9 and white >= 0.002 * unit * unit and blue >= 0.0003 * unit * unit:
    sys.exit(0)
sys.exit(f"{shot} does not show the boot screen: it needs at least 90 % background, {0.002 * unit * unit:.0f} white and {0.0003 * unit * unit:.0f} blue pixels in the middle")
