#!/usr/bin/env bash
# Cadence Xcelium (xrun) flow for the true-parameterization presentation
# demo. Self-contained: does not touch sim/xcelium/ or its build
# artifacts, and does not run the verification suite.
#
# Requires `xrun` on PATH (site-specific -- see sim/xcelium/run_xcelium.sh
# and README.md's "Running in Cadence Xcelium" for how this project's
# server got it set up).
#
# No -R: confirmed on the main verification testbench (see
# sim/xcelium/run_xcelium.sh) that -R in a one-shot xrun invocation means
# "skip straight to running a previously-elaborated snapshot", not "run
# to completion after elaborating" -- xrun compiles, elaborates, and runs
# to completion by default when given HDL sources directly, no separate
# run-control flag needed.
#
# Unlike sim/xcelium/run_xcelium.sh, this doesn't grep the log for a
# pass/fail marker or set a meaningful exit code from it -- this demo has
# no scoreboard, it just prints three worked examples for a presentation.

set -euo pipefail
cd "$(dirname "$0")"

WORK_DIR=xcelium_work
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

xrun \
    -sv \
    -access +rwc \
    -top demo_tb \
    -incdir ../common \
    -incdir . \
    ../rtl/da_matvec_mult.sv \
    demo_tb.sv \
    -xmlibdirname "$WORK_DIR/xcelium.d" \
    -l "$WORK_DIR/xrun.log"
