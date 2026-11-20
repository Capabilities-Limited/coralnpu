#!/usr/bin/env bash
# Build and run the self-check of the Zvt reference model (include/rvv_zvt_model.svh).
# Needs verilator (with a C++ compiler) on PATH. Output goes to $TMPDIR (or /tmp).
# VLEN_DEFINE=VLEN_256 (etc.) checks the model at another VLEN; the default is VLEN_128.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${TMPDIR:-/tmp}/zvt_test
mkdir -p "${out}"
cd "${out}"
# VLEN and TE come from the backend's rvv_backend_define.svh (TE only exists with ZVT_ON), as in the TB build
vlen_define=${VLEN_DEFINE:-VLEN_128}
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-UNOPTFLAT -Wno-ENUMVALUE \
  --top-module zvt_model_tb +incdir+"${here}/../include" +incdir+"${here}/../../../inc" +define+"${vlen_define}" +define+ZVT_ON \
  "${here}/zvt_model_tb.sv" --Mdir obj >/dev/null
./obj/Vzvt_model_tb
