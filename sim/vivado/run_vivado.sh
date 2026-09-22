#!/usr/bin/env bash
# Batch (non-project mode) Vivado xsim flow for the DA matrix-vector
# multiplier regression.
#
# Requires the Xilinx Vivado tool suite (xsc, xvlog, xelab, xsim) on PATH,
# e.g. by sourcing <Vivado install>/settings64.sh first.
#
# NOTE: this script has not been executed against a real Vivado install in
# this environment (Vivado is not installed here) -- functional sign-off in
# this repo was done with Verilator (see sim/verilator/). Double-check the
# points flagged in README.md's "Verilator vs. Vivado" section, in
# particular:
#   - DPI-C linkage: xsc must successfully build golden_model.c into a
#     shared library and xelab must be given -sv_lib to link it.
#   - $fatal/$finish exit-code propagation from `xsim -R` in batch mode.

set -euo pipefail
cd "$(dirname "$0")"

WORK_DIR=xsim_work
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "== Compiling DPI-C golden model with xsc =="
xsc ../../../dpi/golden_model.c -o golden_model

echo "== Compiling SystemVerilog sources with xvlog =="
# -i points xvlog's `include search path at common/matrix_a.inc (the
# single source of truth for matrix A, shared with the DPI-C golden model).
xvlog --sv -i ../../../common -f ../filelist.f

echo "== Elaborating with xelab (linking DPI-C shared lib) =="
xelab da_matvec_tb -sv_lib golden_model -s da_matvec_tb_sim

echo "== Running with xsim (batch mode) =="
xsim da_matvec_tb_sim -R
