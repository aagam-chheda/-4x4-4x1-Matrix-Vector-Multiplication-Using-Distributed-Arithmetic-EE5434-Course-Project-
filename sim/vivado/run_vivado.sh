#!/usr/bin/env bash
# Batch (non-project mode) Vivado xsim flow for the DA matrix-vector
# multiplier regression.
#
# Requires the Xilinx Vivado tool suite (xsc, xvlog, xelab, xsim) on PATH,
# e.g. by sourcing <Vivado install>/settings64.sh first.
#
# NOTE: this script has been fixed up based on a real first run against
# Vivado 2024.2 (Windows), via sim/vivado/run_vivado.bat -- see the
# "Verilator vs. Vivado" / "Running in Vivado" sections in README.md for
# what's still unverified specifically on this .sh (Linux) path.
#
# Runs directly from this directory (not from a cd'd-into work
# subdirectory): filelist.f's paths (../../rtl/..., ../../tb/...) are
# relative to sim/vivado/, and Xilinx's xvlog resolves -f file contents
# relative to the *invocation* directory, not relative to the -f file's
# own location -- cd'ing into a work subdirectory first (as an earlier
# version of this script did) breaks that resolution one level short.
# Xilinx's own build artifacts (xsim.dir/, .Xil/, golden_model.a, etc.)
# are left in this directory and gitignored, rather than relocated.

set -euo pipefail
cd "$(dirname "$0")"

rm -rf xsim.dir .Xil golden_model.a golden_model.so *.jou *.log *.wdb *.pb 2>/dev/null || true

echo "== Compiling DPI-C golden model with xsc =="
xsc ../../dpi/golden_model.c -o golden_model

echo "== Compiling SystemVerilog sources with xvlog =="
# -i points xvlog's `include search path at common/matrix_a.inc (the
# single source of truth for matrix A, shared with the DPI-C golden model).
xvlog --sv -i ../../common -f filelist.f

echo "== Elaborating with xelab (linking DPI-C shared lib) =="
xelab da_matvec_tb -sv_lib golden_model -s da_matvec_tb_sim

echo "== Running with xsim (batch mode) =="
xsim da_matvec_tb_sim -R "$@"
