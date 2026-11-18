#!/usr/bin/env python3
"""Expected psk_romcheck checksum for a Pocket .rom file.

Mirrors pk_io_psk's loader and psk_romcheck's write-side accumulator:
file offset >= 0x220 -> SDRAM byte address (offset - 0x220); each 32-bit
bridge word is written as two 16-bit words, low half first. Only addresses
below 0x100000 (68020 program region) are summed:

    wsum += {data ^ addr[16:1], data}   (mod 2**32)

The bridge's byte order inside a 32-bit word depends on the APF data slot
setting, so both interpretations are printed; the on-screen wsum matches one.

Usage: tools/romcheck_sum.py <game.rom>
"""
import sys


def checksum(blob: bytes, little: bool):
    wsum = words = 0
    end = min(len(blob), 0x220 + 0x100000)
    for off in range(0x220, end - 3, 4):
        w32 = int.from_bytes(blob[off:off + 4], "little" if little else "big")
        addr = off - 0x220
        for half, a in ((w32 & 0xFFFF, addr), (w32 >> 16, addr + 2)):
            wsum = (wsum + ((((half ^ (a >> 1)) & 0xFFFF) << 16) | half)) & 0xFFFFFFFF
            words += 1
    return wsum, words


def main():
    blob = open(sys.argv[1], "rb").read()
    for name, little in (("big-endian bridge words", False), ("little-endian bridge words", True)):
        wsum, words = checksum(blob, little)
        print(f"{name:28s} wsum={wsum:08X} ({wsum:032b}) words={words:05X} ({words:020b})")


if __name__ == "__main__":
    main()
