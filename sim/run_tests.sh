#!/bin/sh
# Run the Verilator test suite: the upstream Psikyo testbenches covering the
# modules patched for the Pocket (src/fpga/rtl), plus the Pocket loader test.
# Usage: sim/run_tests.sh
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
       && grep -qE 'ALL (TESTS )?PASS|^PASS: (adpcma_sample_cache|sprite_render_engine renders)|^PASS: tb_sdram' "$out/$name.log" && ! grep -q FAIL "$out/$name.log"; then
        echo "PASS"
    else
        echo "FAIL (see $out/$name.log)"; fail=1
    fi
}

run sprite_line_diff tb_sprite_line_diff \
    "$R/memory/dpram.sv" "$R"/video/sprite_*.sv "$R/video/tile_row_decode.sv" \
    "$R/memory/sdram_narrow_bridge.sv" "$U/sprite_line_tb/tb_sprite_line_diff.sv"
SD="$R/memory/sdram/sdram.sv $R/memory/sdram_phy.sv $(find "$R/memory" -name '*.sv' ! -path '*/sdram/sdram.sv' ! -name sdram_phy.sv) $R/sound/adpcma_sample_cache.sv $R/video/*.sv $U/sdram_tb/sdram_chip_model.sv"
# shellcheck disable=SC2086
run sdram tb_sdram $SD "$U/sdram_tb/tb_sdram.sv"
# shellcheck disable=SC2086
run psikyo_sdram_top tb_psikyo_sdram_top $SD "$U/psikyo_sdram_top_tb/tb_psikyo_sdram_top.sv"
# shellcheck disable=SC2086
run port2_sdram tb_port2_sdram $SD "$U/port2_sdram_tb/tb_port2_sdram.sv"
run opl4 tb_opl4 "$R"/sound/opl4/*.sv "$U/opl4_tb/tb_opl4.sv"
run adpcma_sample_cache tb_adpcma_sample_cache "$R/sound/adpcma_sample_cache.sv" \
    "$R/memory/sdram/sdram.sv" "$R/memory/sdram_phy.sv" \
    "$U/sdram_tb/sdram_chip_model.sv" "$U/adpcma_sample_cache_tb/tb_adpcma_sample_cache.sv"

printf '%-24s ' pk_io_psk
if "$here/pk_io_tb/run.sh" >"$out/pk_io.log" 2>&1 && grep -q 'ALL PASS' "$out/pk_io.log"; then
    echo PASS
else
    echo "FAIL (see $out/pk_io.log)"; fail=1
fi

printf '%-24s ' psk_sram
if "$here/sram_tb/run.sh" >"$out/sram.log" 2>&1 && grep -q 'ALL PASS' "$out/sram.log"; then
    echo PASS
else
    echo "FAIL (see $out/sram.log)"; fail=1
fi

exit $fail
