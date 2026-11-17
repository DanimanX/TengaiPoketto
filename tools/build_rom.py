#!/usr/bin/env python3
"""Build Analogue Pocket .rom images for the Psikyo 68k core from MiSTer .mra files + MAME zips.

usage:
  build_rom.py GAME.mra ROMS_DIR OUT.rom
  build_rom.py --all MRA_DIR ROMS_DIR OUT_DIR     (recursive, OUT_DIR/<setname>.rom)
  build_rom.py --list MRA_DIR
  build_rom.py --selftest

Images are a 544-byte header followed by the assembled <rom index="0"> stream:
  [0..3] magic b"PSK\\x01"   [4] board flags (blob byte 0, 0 if none)   [5] header version = 1
  [6..7] board blob length (u16)          [8..11] payload length (u32)
  [12..15] payload CRC32 (u32)            [16..23] DIP defaults, 0xFF padded to 8 bytes
  [24..31] zero                           [32..543] board blob, 0x00 padded to 512 bytes
  [544..] payload, then 0xFF padding to a multiple of 4 bytes

Assembly follows mra-tools-c: <part> elements append in document order; a part without a crc
is a fill (its hex bytes repeated `repeat` times); a part with a crc is the zip member with
that CRC, cut by offset/length. In an <interleave output=bits> group each map digit is one
output byte, decremented and read from the last character backwards, so map="21" is verbatim
and map="12" swaps each pair. address= is ignored, as are <rom index="3"> and <nvram>.
"""
import argparse
import os
import sys
import tempfile
import zipfile
import zlib
import xml.etree.ElementTree as ET

MAGIC = b'PSK\x01'
HEADER_VERSION = 1
HEADER_SIZE = 544                  # 32-byte fixed fields + 512-byte board blob area
BLOB_MAX = 512
DIP_MAX = 8
DIP_PAD = 0xFF
TAIL_PAD = 0xFF
ALIGN = 4


class RomError(Exception):
    """Bad MRA or inconsistent romset."""


def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def hexint(text):
    """MRA numbers: '0x...' is hex, anything else decimal."""
    text = text.strip()
    return int(text, 16) if text.lower().startswith('0x') else int(text, 10)


def hexbytes(text):
    """Space/newline separated hex byte tokens -> bytes (board blob, fill parts)."""
    return bytes(int(tok, 16) for tok in (text or '').split())


def dips_text(dips):
    """DIP defaults padded with 0xFF to the 8 header bytes."""
    return ' '.join(f'{b:02X}' for b in bytes(dips) + bytes([DIP_PAD]) * (DIP_MAX - len(dips)))


def find_mras(top):
    for root, dirs, files in os.walk(top):
        dirs.sort()
        for name in sorted(files):
            if name.lower().endswith('.mra'):
                yield os.path.join(root, name)


def load_zips(zip_attr, roms_dir):
    """Open every zip named in the attribute; map CRC32 -> (ZipFile, ZipInfo)."""
    names = [n.strip() for n in (zip_attr or '').split('|') if n.strip()]
    if not names:
        raise RomError('rom index 0 has no zip attribute')
    by_crc, handles = {}, []
    for name in names:
        path = os.path.join(roms_dir, name)
        if os.path.isfile(path):
            zf = zipfile.ZipFile(path)
            handles.append(zf)
            for info in zf.infolist():
                by_crc.setdefault(info.CRC & 0xFFFFFFFF, (zf, info))
    if not handles:
        raise FileNotFoundError(f'missing romset zip: {", ".join(names)} in {roms_dir}')
    return by_crc, [os.path.basename(z.filename) for z in handles], handles


def part_bytes(el, by_crc, zips):
    """Bytes from one <part>: a hex fill, or a zip member looked up by CRC."""
    crc_attr = el.get('crc')
    if crc_attr is None:
        data = hexbytes(el.text)
        if not data:
            raise RomError('fill <part> has no hex bytes')
        return data * hexint(el.get('repeat', '1'))
    crc = int(crc_attr, 16)
    if crc not in by_crc:
        raise RomError(f'part {el.get("name") or "?"} (crc {crc:08x}) not found in {", ".join(zips)}')
    zf, info = by_crc[crc]
    data, off, length = zf.read(info), hexint(el.get('offset', '0')), el.get('length')
    if off or length is not None:
        end = off + hexint(length) if length is not None else len(data)
        data = data[off:end]
    return data


def interleave_bytes(el, by_crc, zips):
    """<interleave output=bits>: spread the parts across each group of output bytes."""
    out_bits = hexint(el.get('output', '8'))
    if out_bits % 8:
        raise RomError(f'interleave output={out_bits} is not a whole number of bytes')
    osize = out_bits // 8
    lanes = []                     # (data, {output byte -> source byte in group}, group width)
    for part in el.findall('part'):
        mapping, name = part.get('map'), part.get('name') or '?'
        if mapping is None or len(mapping) != osize:
            raise RomError(f'part {name} map="{mapping}" does not cover output={out_bits}')
        data = part_bytes(part, by_crc, zips)
        # mra-tools-c: decrement each digit, emit from the last character backwards.
        lane = {pos: int(ch, 16) - 1 for pos, ch in enumerate(reversed(mapping)) if ch != '0'}
        width = len(lane)
        if not width:
            raise RomError(f'part {name} map="{mapping}" selects no bytes')
        if any(src < 0 or src >= width for src in lane.values()):
            raise RomError(f'part {name} map="{mapping}" indexes past its {width}-byte group')
        if len(data) % width:
            raise RomError(f'part {name} length {len(data)} is not a multiple of {width}')
        lanes.append((data, lane, width))
    groups = len(lanes[0][0]) // lanes[0][2]
    if any(len(data) // width != groups for data, _lane, width in lanes):
        raise RomError('interleave parts have different lengths')
    out, filled = bytearray(osize * groups), bytearray(osize * groups)
    for data, lane, width in lanes:
        for g in range(groups):
            for pos, src in lane.items():
                i = g * osize + pos
                out[i] = data[g * width + src]
                filled[i] += 1
    if any(n != 1 for n in filled):
        raise RomError('interleave does not fill every output byte exactly once')
    return bytes(out)


def read_mra(path):
    """Parse setname/name, board blob, DIP defaults, zip names and the index-0 rom element."""
    root = ET.parse(path).getroot()
    rom0, blob = None, b''
    for rom in root.findall('rom'):
        if rom.get('index') == '0':
            rom0 = rom
        elif rom.get('index') == '1':          # board blob: hex bytes, maybe over several parts
            blob = bytes(b for part in rom.findall('part') for b in hexbytes(part.text))
    if rom0 is None:
        raise RomError(f'{path}: no <rom index="0">')
    switches = root.find('switches')
    dips = [int(b, 16) for b in (switches.get('default') if switches is not None else '').split(',')
            if b.strip()]
    if len(dips) > DIP_MAX:
        raise RomError(f'{path}: {len(dips)} DIP bytes, at most {DIP_MAX} fit the header')
    return {'setname': (root.findtext('setname') or os.path.splitext(os.path.basename(path))[0]).strip(),
            'name': (root.findtext('name') or '').strip(), 'zips': rom0.get('zip') or '',
            'rom0': rom0, 'blob': blob, 'flags': blob[0] if blob else 0, 'dips': dips}


def make_image(payload, blob, dips):
    if len(blob) > BLOB_MAX:
        raise RomError(f'board blob is {len(blob)} bytes, max {BLOB_MAX}')
    image = bytearray(HEADER_SIZE)
    image[0:4] = MAGIC
    image[4], image[5] = (blob[0] if blob else 0), HEADER_VERSION
    image[6:8] = len(blob).to_bytes(2, 'little')
    image[8:12] = len(payload).to_bytes(4, 'little')
    image[12:16] = crc32(payload).to_bytes(4, 'little')
    image[16:24] = bytes(dips) + bytes([DIP_PAD]) * (DIP_MAX - len(dips))
    image[32:32 + len(blob)] = blob            # the rest of the 512-byte area stays 0x00
    return image + payload + bytes([TAIL_PAD]) * (-(HEADER_SIZE + len(payload)) % ALIGN)


def build_image(mra_path, roms_dir):
    mra = read_mra(mra_path)
    by_crc, zips, handles = load_zips(mra['zips'], roms_dir)
    try:
        payload = bytearray()
        for el in mra['rom0']:
            if el.tag == 'part':
                payload += part_bytes(el, by_crc, zips)
            elif el.tag == 'interleave':
                payload += interleave_bytes(el, by_crc, zips)
    finally:
        for zf in handles:
            zf.close()
    return mra, bytes(payload), make_image(payload, mra['blob'], mra['dips'])


def write_file(path, data):
    tmp = path + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.replace(tmp, path)


def cmd_build(mra_path, roms_dir, out_path):
    mra, payload, image = build_image(mra_path, roms_dir)
    write_file(out_path, image)
    print(f'Built {out_path}: {len(image)} bytes (payload {len(payload)}, flags 0x{mra["flags"]:02X}, '
          f'dips {dips_text(mra["dips"])}, CRC {crc32(payload):08X})')


def cmd_all(mra_dir, roms_dir, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    built, skipped = 0, []
    for path in find_mras(mra_dir):
        try:
            mra, payload, image = build_image(path, roms_dir)
        except FileNotFoundError as exc:
            skipped.append((path, str(exc)))
        except (RomError, OSError, zipfile.BadZipFile, ET.ParseError) as exc:
            skipped.append((path, f'{type(exc).__name__}: {exc}'))
        else:
            out_path = os.path.join(out_dir, mra['setname'] + '.rom')
            write_file(out_path, image)
            print(f'Built {out_path}: {len(image)} bytes (payload {len(payload)}, '
                  f'CRC {crc32(payload):08X})')
            built += 1
    print(f'\n{built} built, {len(skipped)} skipped')
    for path, reason in skipped:
        print(f'  skipped {os.path.basename(path)}: {reason}')
    return 0 if built else 1


def cmd_list(mra_dir):
    for path in find_mras(mra_dir):
        mra = read_mra(path)
        print(f'{mra["setname"]:<12} flags=0x{mra["flags"]:02X} '
              f'dips={dips_text(mra["dips"])}  {mra["name"]}')
    return 0


def selftest():
    plain, p = bytes(range(0x40, 0x4A)), bytes(range(0x80, 0x88))
    a, b = bytes(range(0x01, 0x09)), bytes(range(0x11, 0x19))   # 4 groups of 2 bytes each
    # expected payload, written out longhand rather than reusing the implementation
    il32 = bytes(x for g in range(4)
                 for x in (a[2 * g + 1], a[2 * g], b[2 * g + 1], b[2 * g]))   # 0012 / 1200
    swapped = bytes(x for i in range(0, len(p), 2) for x in (p[i + 1], p[i]))  # map 12
    expected = plain + b'\xA5' * 16 + il32 + swapped + p                       # map 21 = verbatim
    mra_text = f'''<misterromdescription>
    <name>Selftest</name>
    <setname>selftest</setname>
    <rom index="1"><part>7A 00 11</part></rom>
    <rom index="0" zip="test.zip" md5="none" address="0x30000000">
        <part name="plain.bin" crc="{crc32(plain):08x}"/>
        <part repeat="0x10">A5</part>
        <interleave output="32">
            <part name="a.bin" crc="{crc32(a):08x}" map="0012"/>
            <part name="b.bin" crc="{crc32(b):08x}" map="1200"/>
        </interleave>
        <interleave output="16"><part name="p.bin" crc="{crc32(p):08x}" map="12"/></interleave>
        <interleave output="16"><part name="p.bin" crc="{crc32(p):08x}" map="21"/></interleave>
    </rom>
    <rom index="3"><part>19 9A 57</part></rom>
    <nvram index="4" size="72"/>
    <switches default="FD,0A"><dip name="x" bits="0" ids="On,Off"/></switches>
</misterromdescription>'''

    def build(tmp, mra_src):
        zips = os.path.join(tmp, 'roms')
        os.makedirs(zips, exist_ok=True)
        with zipfile.ZipFile(os.path.join(zips, 'test.zip'), 'w') as zf:
            for name, data in (('plain.bin', plain), ('a.bin', a), ('b.bin', b), ('p.bin', p)):
                zf.writestr(name, data)
        mra_path, out_path = os.path.join(tmp, 'test.mra'), os.path.join(tmp, 'test.rom')
        with open(mra_path, 'w', encoding='utf-8') as f:
            f.write(mra_src)
        cmd_build(mra_path, zips, out_path)
        with open(out_path, 'rb') as f:
            return f.read()

    def check(ok, what):
        if not ok:
            raise AssertionError(f'selftest: {what}')

    with tempfile.TemporaryDirectory() as tmp:
        img = build(tmp, mra_text)
    payload = img[HEADER_SIZE:]
    check(img[0:4] == MAGIC, f'magic {img[0:4]!r}')
    check(img[4] == 0x7A and img[5] == HEADER_VERSION, f'flags/version {img[4]:#04x}/{img[5]}')
    check(int.from_bytes(img[6:8], 'little') == 3, 'blob length')
    check(int.from_bytes(img[8:12], 'little') == len(expected), 'payload length')
    check(int.from_bytes(img[12:16], 'little') == crc32(expected), 'payload crc')
    check(img[16:24] == bytes([0xFD, 0x0A] + [0xFF] * 6), f'dips {img[16:24].hex(" ")}')
    check(img[24:32] == bytes(8), 'reserved bytes')
    check(img[32:544] == b'\x7A\x00\x11' + bytes(509), 'board blob area')
    check(payload[:len(expected)] == expected, 'payload bytes')
    check(all(x == TAIL_PAD for x in payload[len(expected):]), 'tail padding')
    check(len(payload) % ALIGN == 0 and len(payload) - len(expected) < ALIGN, 'tail alignment')

    # a missing CRC must name the part and the zip
    with tempfile.TemporaryDirectory() as tmp:
        try:
            build(tmp, mra_text.replace(f'crc="{crc32(a):08x}"', 'crc="deadbeef"'))
        except RomError as exc:
            check('a.bin' in str(exc) and 'test.zip' in str(exc), f'error text {exc}')
        else:
            raise AssertionError('selftest: missing CRC did not raise')
    print('OK')


def main(argv=None):
    ap = argparse.ArgumentParser(description='Build Analogue Pocket .rom images for the Psikyo core')
    ap.add_argument('--all', nargs=3, metavar=('MRA_DIR', 'ROMS_DIR', 'OUT_DIR'),
                    help='build every .mra under MRA_DIR into OUT_DIR/<setname>.rom')
    ap.add_argument('--list', nargs=1, metavar='MRA_DIR', help='list setname/flags/dips/name')
    ap.add_argument('--selftest', action='store_true', help='run the built-in self test')
    ap.add_argument('paths', nargs='*', metavar='GAME.mra ROMS_DIR OUT.rom')
    args = ap.parse_args(argv)
    try:
        if args.selftest:
            selftest()
        elif args.all:
            return cmd_all(*args.all)
        elif args.list:
            return cmd_list(args.list[0])
        elif len(args.paths) != 3:
            ap.print_help()
            return 2
        else:
            cmd_build(*args.paths)
        return 0
    except (RomError, FileNotFoundError, zipfile.BadZipFile, ET.ParseError) as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
