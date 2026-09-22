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
# NOTE: this script has not been executed against a real Xcelium install
# while authoring this repo (no Xcelium available in that environment) --
# functional sign-off there was done with Verilator (see
# sim/verilator/). Written directly against standard/documented `xrun`
# usage. See README.md's "Running in Cadence Xcelium" section for the
# specific points to double-check on first run, and report back anything
# that needs adjusting.
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

WORK_DIR=xcelium_work
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

xrun \
    -sv \
    -access +rwc \
    -top da_matvec_tb \
    -incdir ../../common \
    -f filelist.f \
    ../../dpi/golden_model.c \
    -xmlibdirname "$WORK_DIR/xcelium.d" \
    -l "$WORK_DIR/xrun.log" \
    -R \
    "$@" || true

if grep -q "REGRESSION PASSED" "$WORK_DIR/xrun.log" 2>/dev/null; then
    echo "== Xcelium xrun: PASSED (confirmed via log content, not xrun's own exit code) =="
    exit 0
else
    echo "== Xcelium xrun: FAILED or inconclusive (\"REGRESSION PASSED\" not found in $WORK_DIR/xrun.log) =="
    exit 1
fi
