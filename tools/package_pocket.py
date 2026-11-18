#!/usr/bin/env python3
"""Assemble the Analogue Pocket SD-card package for TengaiPoketto.

  release/sd_card/Cores/danimanx.TengaiPoketto/   core JSONs + bitstream.rbf_r
  release/sd_card/Platforms/                      psikyo.json + _images/psikyo.bin
  release/sd_card/Assets/psikyo/                  instance JSONs + common/README.txt
  release/TengaiPoketto_Pocket_<version>.zip

bitstream.rbf_r is the Quartus .rbf with every byte bit-reversed (APF rule).
Game .rom files are NOT packaged: build them with tools/build_rom.py and copy
them to Assets/psikyo/common/.
"""
import argparse, json, os, shutil, sys, zipfile

CORE = "danimanx.TengaiPoketto"
REV = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))

def main():
    here = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rbf", default="src/fpga/output_files/pocket_tengai.rbf")
    ap.add_argument("--out", default="release")
    a = ap.parse_args()

    rbf = os.path.join(here, a.rbf)
    if not os.path.isfile(rbf):
        sys.exit(f"error: {rbf} not found (compile src/fpga/pocket_tengai.qpf first)")
    core_json = os.path.join(here, "apf", "Cores", CORE, "core.json")
    version = json.load(open(core_json))["core"]["metadata"]["version"]

    out = os.path.join(here, a.out)
    sd = os.path.join(out, "sd_card")
    shutil.rmtree(sd, ignore_errors=True)
    for d in ("Cores", "Platforms", "Assets"):
        shutil.copytree(os.path.join(here, "apf", d), os.path.join(sd, d))

    data = open(rbf, "rb").read().translate(REV)
    open(os.path.join(sd, "Cores", CORE, "bitstream.rbf_r"), "wb").write(data)

    common = os.path.join(sd, "Assets", "psikyo", "common")
    os.makedirs(common, exist_ok=True)
    open(os.path.join(common, "README.txt"), "w").write(
        "Put the game .rom files here (tengai.rom, s1945.rom, gunbird.rom, ...).\n"
        "Build them from your MAME zips with:\n"
        "  python3 tools/build_rom.py --all upstream/Arcade-Psikyo_MiSTer/releases <zips> <out>\n")

    zpath = os.path.join(out, f"TengaiPoketto_Pocket_v{version}.zip")
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(sd):
            for f in sorted(files):
                p = os.path.join(root, f)
                z.write(p, os.path.relpath(p, sd))
    print(f"bitstream.rbf_r: {len(data)} bytes")
    print(f"package: {zpath}")

if __name__ == "__main__":
    main()
