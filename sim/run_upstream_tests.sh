#!/bin/sh
# Run the upstream Psikyo testbenches that cover modules patched for the
# Pocket (src/fpga/rtl) with Verilator. Usage: sim/run_upstream_tests.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
R="$here/../src/fpga/rtl"
U="$here/../upstream/Arcade-Psikyo_MiSTer/sim"
out="$here/obj_upstream"
mkdir -p "$out"
VL="verilator --binary --timing -j 0 -Wno-fatal -Wno-lint -Wno-style"
fail=0

run() {  # name top sources...
    name=$1; top=$2; shift 2
    printf '%-24s ' "$name"
    if ! $VL --top-module "$top" -Mdir "$out/$name" "$@" >"$out/$name.build.log" 2>&1; then
        echo "BUILD FAILED (see $out/$name.build.log)"; fail=1; return
    fi
    # opl4_pcm loads its table from rtl/sound/opl4/..., relative to the cwd
    if (cd "$R/.." && "$out/$name/V$top") >"$out/$name.log" 2>&1 \
       && grep -qE 'ALL (TESTS )?PASS' "$out/$name.log"; then
        echo "PASS"
    else
        echo "FAIL (see $out/$name.log)"; fail=1
    fi
}

run sprite_line_diff tb_sprite_line_diff \
    "$R/memory/dpram.sv" "$R"/video/sprite_*.sv "$R/video/tile_row_decode.sv" \
    "$R/memory/sdram_narrow_bridge.sv" "$U/sprite_line_tb/tb_sprite_line_diff.sv"
run opl4 tb_opl4 "$R"/sound/opl4/*.sv "$U/opl4_tb/tb_opl4.sv"

exit $fail
