#!/usr/bin/env bash
# Build + run the pk_io_psk Verilator testbench.
set -euo pipefail

cd "$(dirname "$0")"

DUT=../../src/fpga/pocket_rtl/pk_io_psk.sv
OBJ=obj_dir

mkdir -p "$OBJ"

verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style \
	--top-module tb_pk_io \
	--Mdir "$OBJ" \
	-o tb_pk_io \
	dcfifo_model.sv tb_pk_io.sv "$DUT"

exec "./$OBJ/tb_pk_io" "$@"
