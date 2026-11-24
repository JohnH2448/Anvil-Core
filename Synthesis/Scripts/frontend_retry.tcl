# Post-route retry passes on a routed checkpoint (default: the frontend flow).
# vivado -mode batch -nolog -nojournal -source Synthesis/Scripts/frontend_retry.tcl [-tclargs [flow|checkpoint]]
# Uses the checkpoint's netlist, device and constraints; does not read current RTL.
# Checkpoints go to Synthesis/Build/<flow>_retry and reports to Synthesis/Reports/<flow>_retry.

source [file join [file dirname [file normalize [info script]]] common.tcl]
if {[llength $argv] > 1} {
    error {Usage: frontend_retry.tcl [flow|checkpoint]}
}
set retry_input [anvil_checkpoint [expr {[llength $argv] ? [lindex $argv 0] : "frontend"}]]
set retry_flow "[file tail [file dirname $retry_input]]_retry"
set retry_output [anvil_build_dir $retry_flow]
set retry_reports [anvil_report_dir $retry_flow]
if {[string match -nocase "[file normalize $retry_output]*" $retry_input]} {
    error "Input checkpoint is inside the output directory, which is wiped on each run: $retry_input"
}
anvil_begin $retry_flow
# Workaround attempt for the native crash; not a guarantee against tool bugs.
set_param general.maxThreads 1
open_checkpoint $retry_input

# Each pass saves a checkpoint only. Per-pass timing goes into one summary at the end.
set retry_summary {}
proc retry_save {stage output_dir} {
    global retry_summary last_saved
    set last_saved [file join $output_dir ${stage}.dcp]
    write_checkpoint -force $last_saved
    set setup [get_timing_paths -delay_type max -max_paths 1]
    set hold [get_timing_paths -delay_type min -max_paths 1]
    lappend retry_summary [format "%-20s WNS %8s  WHS %8s" $stage         [expr {[llength $setup] ? [get_property SLACK $setup] : "n/a"}]         [expr {[llength $hold] ? [get_property SLACK $hold] : "n/a"}]]
}
puts "Retrying routed checkpoint: $retry_input"
puts "Retry checkpoints: $retry_output"
retry_save baseline $retry_output

# Explicit passes avoid the combined AggressiveExplore phys-opt flow that crashed
# in Critical Path Optimization. A native crash still kills Vivado, but every
# earlier pass has already been saved as a checkpoint.
set retry_steps {
    {01_rerouted {route_design -directive AggressiveExplore}}
    {02_hold {phys_opt_design -hold_fix}}
    {03_hold_aggressive {phys_opt_design -aggressive_hold_fix}}
    {04_pins {phys_opt_design -critical_pin_opt}}
    {05_routing {phys_opt_design -routing_opt}}
    {06_clock {phys_opt_design -clock_opt}}
    {07_restructure {phys_opt_design -restruct_opt}}
    {08_rerouted {route_design -directive NoTimingRelaxation}}
    {09_hold_final {phys_opt_design -aggressive_hold_fix}}
}

foreach retry_step $retry_steps {
    lassign $retry_step retry_stage retry_command
    puts "Starting $retry_stage: $retry_command"
    flush stdout
    if {[catch {eval $retry_command} retry_error]} {
        # Tcl errors only: restore the last saved state and move to the next pass.
        puts stderr "Failed $retry_stage: $retry_error"
        lappend retry_summary [format "%-20s FAILED: %s" $retry_stage $retry_error]
        close_design
        open_checkpoint $last_saved
        continue
    }
    retry_save $retry_stage $retry_output
}

# Final reports describe the last saved checkpoint. That is not necessarily the best one; see the summary.
set prefix [file join $retry_reports final]
report_timing_summary -file ${prefix}_timing_summary.rpt
report_timing -delay_type max -max_paths 50 -path_type full_clock_expanded -file ${prefix}_worst_setup.rpt
report_timing -delay_type min -max_paths 20 -path_type full_clock_expanded -file ${prefix}_worst_hold.rpt
report_route_status -file ${prefix}_route_status.rpt
report_utilization -file ${prefix}_utilization.rpt
set summary_handle [open [file join $retry_reports retry_summary.rpt] w]
puts $summary_handle "Input: $retry_input"
puts $summary_handle "Final reports describe: $last_saved"
puts $summary_handle [join $retry_summary "
"]
close $summary_handle
puts "Retry complete. Checkpoints: $retry_output  Reports: $retry_reports"
