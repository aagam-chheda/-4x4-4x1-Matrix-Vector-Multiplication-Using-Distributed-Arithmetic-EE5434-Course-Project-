#!/usr/bin/env bash
# Synthesize both variants in Vivado and print a side-by-side summary.
# Requires vivado on PATH (source <install>/settings64.sh first).
# Usage: ./run_synth_compare.sh [part] [period_ns] [impl 1|0]
set -euo pipefail
cd "$(dirname "$0")"
for top in da_matvec_mult da_matvec_mult_obc; do
    vivado -mode batch -nojournal -nolog -source synth_compare.tcl \
           -tclargs "$top" "${1:-xc7a35tcpg236-1}" "${2:-3.0}" "${3:-1}" | tee "reports_${top}.log" | grep -E "SUMMARY|ERROR" || true
done
echo
echo "=== Summary ==="
grep -h SUMMARY reports_da_matvec_mult.log reports_da_matvec_mult_obc.log || echo "no SUMMARY lines found - see the reports_*.log files"
