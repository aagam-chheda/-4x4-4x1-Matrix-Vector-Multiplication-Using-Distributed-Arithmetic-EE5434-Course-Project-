#!/usr/bin/env bash
# Single-command Cadence Xcelium (xrun) flow for the DA matrix-vector
# multiplier regression: compiles, elaborates, and runs in one step.
#
# Usage:
#   ./run_xcelium.sh                # default (fixed) seed
#   ./run_xcelium.sh +SEED=1234     # override the CRV seed
#
# Requires `xrun` on PATH (e.g. after `module load xcelium` or sourcing
# your site's Xcelium setup script -- site-specific, not something this
# repo can set up for you).
#
# NOTE: confirmed against a real Xcelium 22.09-s003 run that `-R` in a
# single-shot invocation (compile+elaborate+run all in one xrun command)
# does NOT mean "run to completion after elaborating" the way it does for
# Vivado's `xsim -R` -- Xcelium's `-R` means "skip straight to running a
# previously-elaborated snapshot", a separate 2-phase workflow. Combined
# with HDL source files and -top in the same invocation, xrun warns
# `-TOP with -R option will be ignored` / `HDL source files with -R
# option will be ignored`, then fails with NOSTUP since no snapshot
# exists yet. Fixed by dropping -R entirely: xrun compiles, elaborates,
# and runs to completion by default when given HDL sources directly, with
# no separate run-control flag needed for that one-shot flow.
#
# IMPORTANT, learned the hard way on the Vivado flow (see
# sim/vivado/run_vivado.sh): do not assume a simulator's own process exit
# code reflects whether $fatal fired -- confirmed directly that Vivado's
# `xsim -R` always exits 0 even when $fatal fired mid-run, despite the
# log correctly showing "Fatal: ...". Whether Xcelium's `xrun -R` behaves
# the same way is unconfirmed (no install to test against), so this
# script doesn't trust `xrun`'s exit code either -- it greps the run's
# own log for "REGRESSION PASSED" and sets its own exit code from that,
# the same defensive pattern now used for Vivado.

set -euo pipefail
cd "$(dirname "$0")"

# MODE selects what to run. The default (orig) is exactly the flow that was
# confirmed on a real Xcelium install; the other two are additions that
# have not been run on Xcelium yet.
#   MODE=orig  (default) main regression against the original da_matvec_mult
#   MODE=obc   the same regression against the LSB-first OBC variant
#              (rtl/da_matvec_mult_obc.sv), selected via the DUT_OBC macro
#   MODE=equiv lockstep equivalence testbench (original + OBC side by side
#              over several matrices; no DPI golden model needed)
# Example:  MODE=obc ./run_xcelium.sh
MODE="${MODE:-orig}"
FILELIST=filelist.f
TOP=da_matvec_tb
DEFS=""
DPI_SRC="../../dpi/golden_model.c"
case "$MODE" in
    orig)  ;;
    obc)   FILELIST=filelist_obc.f; DEFS="-define DUT_OBC" ;;
    equiv) FILELIST=filelist_equiv.f; TOP=da_matvec_equiv_tb; DPI_SRC="" ;;
    *)     echo "Unknown MODE=$MODE (use orig, obc or equiv)"; exit 2 ;;
esac
echo "== MODE=$MODE (top=$TOP, filelist=$FILELIST) =="

WORK_DIR=xcelium_work
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# DEFS and DPI_SRC are deliberately unquoted so an empty value disappears
# from the command line (no spaces in any of these paths).
xrun \
    -sv \
    -access +rwc \
    -top "$TOP" \
    $DEFS \
    -incdir ../../common \
    -f "$FILELIST" \
    $DPI_SRC \
    -xmlibdirname "$WORK_DIR/xcelium.d" \
    -l "$WORK_DIR/xrun.log" \
    "$@" || true

if grep -q "REGRESSION PASSED" "$WORK_DIR/xrun.log" 2>/dev/null; then
    echo "== Xcelium xrun: PASSED (confirmed via log content, not xrun's own exit code) =="
    exit 0
else
    echo "== Xcelium xrun: FAILED or inconclusive (\"REGRESSION PASSED\" not found in $WORK_DIR/xrun.log) =="
    exit 1
fi
