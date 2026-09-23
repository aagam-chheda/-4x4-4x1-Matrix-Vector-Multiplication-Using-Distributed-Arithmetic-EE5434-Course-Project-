# synth_compare.tcl
#
# Synthesizes (and by default places + routes) ONE of the two RTL variants
# out-of-context in Vivado non-project mode and prints a one-line summary,
# so the original MSB-first da_matvec_mult and the LSB-first OBC variant
# da_matvec_mult_obc can be compared on LUTs, registers and timing.
#
# Usage (run once per module; run_synth_compare.bat/.sh do both):
#   vivado -mode batch -nojournal -nolog -source synth_compare.tcl \
#          -tclargs <top> [part] [period_ns] [impl: 1|0]
#     top        da_matvec_mult | da_matvec_mult_obc
#     part       default xc7a35tcpg236-1 (Artix-7; change it if that device
#                family is not installed on your machine)
#     period_ns  target clock period, default 3.0 (deliberately tight so the
#                slack reflects each design's real critical path)
#     impl       1 (default) also runs opt/place/route; 0 = synthesis only
#
# NOTE: written against Vivado's documented Tcl commands but not run in the
# environment this repo was authored in (no Vivado there). If a command
# fails, the exact error text is what's needed to fix it.

set top    [lindex $argv 0]
set part   "xc7a35tcpg236-1"
set period 3.0
set impl   1
if {[llength $argv] > 1} { set part   [lindex $argv 1] }
if {[llength $argv] > 2} { set period [lindex $argv 2] }
if {[llength $argv] > 3} { set impl   [lindex $argv 3] }

# Work from the repo root and use only RELATIVE, space-free paths from here
# on. read_verilog and synth_design -include_dirs take Tcl *lists*, so an
# absolute path containing a space (e.g. C:/Users/Aagam Chheda/...) gets
# split into two bogus entries ("File 'C:/Users/Aagam' is a directory" --
# confirmed on a real run). Relative paths sidestep that entirely.
set here [file dirname [file normalize [info script]]]
cd [file normalize [file join $here ..]]
set outdir [file join synth reports $top]
file mkdir $outdir

read_verilog -sv [file join rtl $top.sv]

# -include_dirs: the RTL pulls its default matrix in via a preprocessor
# include of matrix_a.inc.
synth_design -top $top -part $part -mode out_of_context \
             -include_dirs common

create_clock -name clk -period $period [get_ports clk]

report_utilization    -file [file join $outdir utilization_synth.rpt]
report_timing_summary -file [file join $outdir timing_synth.rpt]

if {$impl} {
    opt_design
    place_design
    route_design
    report_utilization    -file [file join $outdir utilization_routed.rpt]
    report_timing_summary -file [file join $outdir timing_routed.rpt]
}

# ---- one-line summary for easy side-by-side comparison ----
set util [report_utilization -return_string]
set luts "?"
set regs "?"
regexp {\|\s*(?:Slice|CLB) LUTs\*?\s*\|\s*(\d+)}      $util -> luts
regexp {\|\s*(?:Slice|CLB) Registers\s*\|\s*(\d+)}    $util -> regs

set slack "?"
set paths [get_timing_paths -max_paths 1 -setup]
if {[llength $paths] > 0} {
    set slack [get_property SLACK [lindex $paths 0]]
}
set stage "post-synth"
if {$impl} { set stage "post-route" }
puts "SUMMARY $top ($part, $stage): LUTs=$luts registers=$regs setup_slack_at_${period}ns=$slack"
puts "Full reports written to $outdir"
