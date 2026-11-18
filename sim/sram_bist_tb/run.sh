#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
R="$here/../../src/fpga/pocket_rtl"
for dead in 0 1; do
  verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_psk_sram_bist -GDEAD=$dead \
      -Mdir "$here/obj_$dead" "$R/psk_sram.sv" "$R/psk_sram_bist.sv" "$here/tb_psk_sram_bist.sv" >/dev/null
  "$here/obj_$dead/Vtb_psk_sram_bist"
done
