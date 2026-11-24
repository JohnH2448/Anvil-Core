# Detailed breakdown of the single worst hold path in a routed checkpoint.
# vivado -mode batch -nolog -nojournal -source Synthesis/Scripts/worst_hold_path.tcl [-tclargs [flow|checkpoint]]
# flow is a Build subdirectory (backend, frontend, cpu, ...); default backend.
# The report goes to Synthesis/Reports/<flow>/worst_hold_path.rpt. Read-only analysis.

source [file join [file dirname [file normalize [info script]]] common.tcl]
if {[llength $argv] > 1} {
    error {Usage: worst_hold_path.tcl [flow|checkpoint]}
}
set path_checkpoint [anvil_checkpoint [expr {[llength $argv] ? [lindex $argv 0] : "backend"}]]
set path_report [file join [anvil_report_dir [file tail [file dirname $path_checkpoint]]] worst_hold_path.rpt]
anvil_clean
open_checkpoint $path_checkpoint
if {[llength [get_timing_paths -delay_type min -max_paths 1]] == 0} {
    error "No constrained hold path found in $path_checkpoint"
}
# Query directly: -of_objects would ignore the detailed formatting options.
set path_text [report_timing -delay_type min -max_paths 1 -nworst 1 \
    -path_type full_clock_expanded -input_pins -return_string]
file mkdir [file dirname $path_report]
set path_handle [open $path_report w]
puts $path_handle "Checkpoint: $path_checkpoint"
puts $path_handle "Generated: [clock format [clock seconds]]"
puts $path_handle $path_text
close $path_handle
puts $path_text
puts "Worst hold path written to $path_report"
