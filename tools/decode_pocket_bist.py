#!/usr/bin/env python3
"""Decode the ROM-check + SRAM BIST overlay bands from a Pocket screenshot.

Bands of 8 lines from the top (psikyo_pocket_top.sv, section 6): 32-bit
fields at 8 px per bit, MSB first, yellow = 1, blue = 0. Read at band centre.
"""
import sys
from PIL import Image

im = Image.open(sys.argv[1]).convert("RGB"); px = im.load()

def color(x, y):
    r, g, b = px[x, y]
    return "green" if g > 128 and r < 128 else "red" if r > 128 and g < 128 else \
           "grey" if abs(r - g) < 40 and 64 < r < 192 else f"?{r:02X}{g:02X}{b:02X}"

def field(band):
    y, v = 8 * band + 4, 0
    for i in range(32):
        r, g, b = px[8 * i + 4, y]
        bit = 1 if (r > 128 and g > 128 and b < 128) else 0 if (b > 128 and r < 128) else None
        if bit is None:
            raise SystemExit(f"band {band} bit {i}: unexpected colour {r:02X}{g:02X}{b:02X}")
        v = v << 1 | bit
    return v

print(f"ROM check : {color(160, 4)}   rsum {field(1):08X}  wsum {field(2):08X}  words {field(3):05X}")
print(f"SRAM BIST : slow {color(80, 36)}   normal {color(240, 36)}")
e = field(5)
print(f"errors    : slow {e >> 16}   normal {e & 0xFFFF}   (65535 = saturated)")
for name, b in (("normal", 6), ("slow", 8)):
    ag, er = field(b), field(b + 1)
    print(f"{name:7s}   : first fail addr {ag >> 16:04X} got {ag & 0xFFFF:04X} expected {er >> 16:04X}"
          f"   raw word0 {er & 0xFFFF:04X} (healthy = 5AA5)")
