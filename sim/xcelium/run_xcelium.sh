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
    "$@"
