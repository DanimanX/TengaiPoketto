#!/usr/bin/env python3
"""Decode a Pocket Memories screenshot taken with "Debug Overlay" on.

Screen pixel (x, y) is (hcnt, vcnt). Layout: src/fpga/rtl/psikyo_core.sv,
g_tracer. Pocket screenshots keep only ~5 bits per channel and dither, so
rows 64+ (one 24-bit value per line) are sent as saturated bits by
psikyo_pocket_top.sv: 8 blocks of 8 px, block k carries bits 23-3k (R),
22-3k (G), 21-3k (B), the pattern repeating every 64 px. Each bit is read at
the block centre of every repeat and majority-voted. Rows 0-63 are raw and
only approximate.
"""
import argparse
from PIL import Image

COUNTERS = {210: "aud_wrap", 211: "aud_clip", 212: "aud_peak", 213: "aud_samples",
            214: "adpcma_late", 215: "sp_render_max", 217: "l0_overrun_cnt",
            218: "l1_overrun_cnt", 219: "sp_overrun_cnt", 220: "frames",
            221: "adpcma_stall", 222: "adpcmb_stall"}
FAULT_LO, FAULT_HI = 0x04, 0x32       # word range of the tracer trigger
VEC = {2: "bus error", 3: "address error", 4: "illegal instr", 5: "zero divide",
       6: "CHK", 7: "TRAPV", 8: "privilege", 9: "trace", 10: "line A", 11: "line F",
       13: "coproc protocol", 14: "format error", 15: "uninit IRQ", 24: "spurious IRQ"}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("png")
    ap.add_argument("--raw", action="store_true", help="also dump rows 0-63 (approximate)")
    a = ap.parse_args()

    im = Image.open(a.png).convert("RGB")
    if im.size != (320, 224):
        raise SystemExit(f"expected 320x224, got {im.size}")
    px = im.load()
    bad = []

    def row(y):
        v = 0
        for k in range(8):
            for c in range(3):
                votes = [px[64 * r + 8 * k + 4, y][c] >= 0x80 for r in range(5)]
                if 0 < sum(votes) < 5:
                    bad.append(y)
                v |= (sum(votes) >= 3) << (23 - 3 * k - c)
        return v

    e = row(216)
    print(f"control echo {e:06X}: marker {'OK' if e >> 16 == 0xA5 else 'BAD (%02X)' % (e >> 16)}"
          f"  const1={e & 1}  dbg_src={(e >> 1) & 3} (ring={(e >> 1) & 1} trig={(e >> 2) & 1})"
          f"  window={(e >> 3) & 15}  rearm={(e >> 7) & 1}")
    print(f"  frozen: addr={(e >> 9) & 1} data={(e >> 8) & 1}   l0_en={(e >> 11) & 1} l1_en={(e >> 10) & 1}"
          f"  overrun: l0={(e >> 13) & 1} l1={(e >> 12) & 1} sp={(e >> 15) & 1}")

    words = [row(y) & 0x7FFFF for y in range(64, 192)]
    data = {i: row(192 + i) for i in range(18)}
    faults = [i for i, w in enumerate(words) if FAULT_LO <= w < FAULT_HI]
    # In ring mode with the trigger, the buffer froze with the first fault
    # vector fetch as its NEWEST entry: rotate so it prints last.
    start = (faults[0] + 1) % 128 if len(faults) == 1 else 0
    if len(faults) == 1:
        print(f"\nCPU ROM reads leading to the first fault (ring rotated, slot {faults[0]} is newest)")
    else:
        print(f"\nCPU ROM reads in buffer order ({len(faults)} fault-vector reads, no rotation)")
    for n in range(128):
        i = (start + n) % 128
        w = words[i]
        note = ""
        if FAULT_LO <= w < FAULT_HI:
            note = f"  <- vector {w // 2} ({VEC.get(w // 2, '?')})"
        if i in data:
            d = data[i]
            note = f"  data {d & 0xFFFF:04X} (addr_lo {(d >> 16) & 0xFF:02X})" + note
        print(f"{n:3d} [slot {i:3d}]  byte {w * 2:06X}{note}")

    print("\ncounters")
    for y, name in COUNTERS.items():
        v = row(y) & 0xFFFFF
        print(f"  {name:15s} {v:8d}  0x{v:05X}")
    v = row(223)
    print(f"  adpcma_max {(v >> 12) & 0xFFF}  adpcmb_max {v & 0xFFF}")
    if bad:
        print(f"\nWARNING: split votes on rows {sorted(set(bad))[:20]} -- buffer changing during capture?")

    if a.raw:
        for y in range(64):
            print(f"row {y:2d}: " + " ".join("%02X%02X%02X" % px[x, y] for x in range(0, 320, 8)))


if __name__ == "__main__":
    main()
