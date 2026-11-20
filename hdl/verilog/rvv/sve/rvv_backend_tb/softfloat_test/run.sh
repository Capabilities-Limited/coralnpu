#!/usr/bin/env bash
# Build and run the soft-float differential test. Usage: run.sh [N]
# Needs verilator (with a C++ compiler) on PATH. Output goes to $TMPDIR (or /tmp).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rtl=${here}/../../../design/rvv_backend_sqrt7_rec7.sv
out=${TMPDIR:-/tmp}/softfloat_test
mkdir -p "${out}"
cd "${out}"

# The rec7 / rsqrt7 tables of the RTL, to check the generated ones against.
{
  echo "localparam logic [6:0] RTL_REC7 [128] = '{"
  perl -ne 'if(/^\s*7\x27d\s*(\d+): pip2_rec7_man = 7\x27d(\d+);/){ $t[$1]=$2 } END{ print join(",\n", map {"  7\x27d@{[$t[$_]//0]}"} 0..127), "\n" }' "${rtl}"
  echo "};"
  echo "localparam logic [6:0] RTL_RSQRT7 [128] = '{"
  perl -ne 'if(/^\s*\{1\x27b([01]), 6\x27d\s*(\d+)\}: pip2_sqrt7_man = 7\x27d(\d+);/){ $t[$1*64+$2]=$3 } END{ print join(",\n", map {"  7\x27d@{[$t[$_]//0]}"} 0..127), "\n" }' "${rtl}"
  echo "};"
} > rtl_tables.svh

verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-UNOPTFLAT -Wno-ENUMVALUE \
  --top-module softfloat_tb +incdir+"${here}/../include" +incdir+"${out}" \
  "${here}/softfloat_tb.sv" "${here}/softfloat_ref.cpp" -CFLAGS -O0 -CFLAGS -frounding-math --Mdir obj >/dev/null
./obj/Vsoftfloat_tb +N="${1:-200000}"
