#!/usr/bin/env bash
# Batch (non-project mode) Vivado xsim flow for the DA matrix-vector
# multiplier regression.
#
# Requires the Xilinx Vivado tool suite (xsc, xvlog, xelab, xsim) on PATH,
# e.g. by sourcing <Vivado install>/settings64.sh first.
#
# NOTE: this script has been fixed up based on a real full pass against
# Vivado 2024.2 (Windows), via sim/vivado/run_vivado.bat -- see the
# "Running in Vivado" section in README.md for what's confirmed vs. still
# open specifically on this .sh (Linux) path, which itself remains
# unexercised.
#
# Runs directly from this directory (not from a cd'd-into work
# subdirectory): filelist.f's paths (../../rtl/..., ../../tb/...) are
# relative to sim/vivado/, and Xilinx's xvlog resolves -f file contents
# relative to the *invocation* directory, not relative to the -f file's
# own location -- cd'ing into a work subdirectory first (as an earlier
# version of this script did) breaks that resolution one level short.
# Xilinx's own build artifacts (xsim.dir/, .Xil/, golden_model.a, etc.)
# are left in this directory and gitignored, rather than relocated.
#
# IMPORTANT, confirmed against a real run: `xsim -R`'s own process exit
# code is 0 regardless of whether $fatal fired during simulation (checked
# directly with a standalone $fatal test: log correctly shows
# "Fatal: ...", but xsim still exits 0). So this script does NOT trust
# `xsim`'s exit code -- it captures the run's output to a log and greps
# it for "REGRESSION PASSED" itself, setting this script's own exit code
# accordingly. That's the reliable signal for CI use with Vivado.

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
xsim da_matvec_tb_sim -R "$@" | tee xsim_run.log

if grep -q "REGRESSION PASSED" xsim_run.log; then
    echo "== Vivado xsim run: PASSED (confirmed via log content, not xsim's own exit code) =="
    exit 0
else
    echo "== Vivado xsim run: FAILED or inconclusive (\"REGRESSION PASSED\" not found in xsim_run.log) =="
    exit 1
fi
