#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_psk_sram \
    -Mdir "$here/obj_dir" "$here/../../src/fpga/pocket_rtl/psk_sram.sv" "$here/tb_psk_sram.sv" >/dev/null
"$here/obj_dir/Vtb_psk_sram"
