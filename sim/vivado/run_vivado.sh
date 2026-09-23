#!/usr/bin/env bash
# Batch (non-project mode) Vivado xsim flow for the DA matrix-vector
# multiplier regression.
#
# Usage:
#   ./run_vivado.sh          # default (fixed) seed
#   ./run_vivado.sh 1234     # override the CRV seed
#
# Requires the Xilinx Vivado tool suite (xsc, xvlog, xelab, xsim) on PATH,
# e.g. by sourcing <Vivado install>/settings64.sh first.
#
# Takes the seed as a plain positional argument (not the raw
# `-testplusarg "SEED=<n>"` xsim needs) and builds that switch internally
# with correct quoting -- confirmed directly that xsim mishandles an
# *unquoted* `-testplusarg SEED=1234` (fails with "Expected a switch but
# found 1"), so forwarding a bare `+SEED=1234`-style arg through
# unquoted, the way the Verilator/Xcelium flows do, isn't safe here.
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

# MODE selects what to run. The default (orig) is exactly the flow that was
# confirmed on a real Vivado install (via run_vivado.bat); the other two are
# additions that have not been run on Vivado yet.
#   MODE=orig  (default) main regression against the original da_matvec_mult
#   MODE=obc   the same regression against the LSB-first OBC variant
#              (rtl/da_matvec_mult_obc.sv), selected via the DUT_OBC macro
#   MODE=equiv lockstep equivalence testbench (original + OBC side by side
#              over several matrices; no DPI golden model needed)
# Example:  MODE=obc ./run_vivado.sh        or   MODE=equiv ./run_vivado.sh 1234
MODE="${MODE:-orig}"
FILELIST=filelist.f
TOP=da_matvec_tb
DEFS=""
USE_DPI=1
case "$MODE" in
    orig)  ;;
    obc)   FILELIST=filelist_obc.f; DEFS="-d DUT_OBC" ;;
    equiv) FILELIST=filelist_equiv.f; TOP=da_matvec_equiv_tb; USE_DPI=0 ;;
    *)     echo "Unknown MODE=$MODE (use orig, obc or equiv)"; exit 2 ;;
esac
echo "== MODE=$MODE (top=$TOP, filelist=$FILELIST) =="

SVLIB=""
if [ "$USE_DPI" = "1" ]; then
    echo "== Compiling DPI-C golden model with xsc =="
    xsc ../../dpi/golden_model.c -o golden_model
    SVLIB="-sv_lib golden_model"
fi

echo "== Compiling SystemVerilog sources with xvlog =="
# -i points xvlog's `include search path at common/matrix_a.inc (the
# single source of truth for matrix A, shared with the DPI-C golden model).
# DEFS and SVLIB are deliberately unquoted so an empty value disappears
# from the command line.
xvlog --sv $DEFS -i ../../common -f "$FILELIST"

echo "== Elaborating with xelab (linking DPI-C shared lib when used) =="
xelab "$TOP" $SVLIB -s da_matvec_tb_sim

echo "== Running with xsim (batch mode) =="
if [ -n "${1:-}" ]; then
    xsim da_matvec_tb_sim -R -testplusarg "SEED=$1" | tee xsim_run.log
else
    xsim da_matvec_tb_sim -R | tee xsim_run.log
fi

if grep -q "REGRESSION PASSED" xsim_run.log; then
    echo "== Vivado xsim run: PASSED (confirmed via log content, not xsim's own exit code) =="
    exit 0
else
    echo "== Vivado xsim run: FAILED or inconclusive (\"REGRESSION PASSED\" not found in xsim_run.log) =="
    exit 1
fi
