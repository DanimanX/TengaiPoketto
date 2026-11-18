#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/obj_dir"
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_psk_romcheck \
    -Mdir "$here/obj_dir" "$here/../../src/fpga/rtl/memory/psk_romcheck.sv" \
    "$here/tb_psk_romcheck.sv" >/dev/null
"$here/obj_dir/Vtb_psk_romcheck"
