# Out-of-context synthesis and implementation of FrontendTop only.
# vivado -mode batch -nolog -nojournal -source Synthesis/Scripts/frontend.tcl [-tclargs [part]]
# Input delays specify arrival time after the launching clock edge.
# Outputs use zero external delay, leaving the full period for frontend logic.

source [file join [file dirname [file normalize [info script]]] common.tcl]
if {[llength $argv] > 1} {
    error {Usage: frontend.tcl [part]}
}
set frontend_part [expr {[llength $argv] >= 1 ? [lindex $argv 0] : $anvil_default_part}]
anvil_begin frontend
create_project -in_memory -part $frontend_part
read_verilog -sv [anvil_sources Core/Frontend/Fetch/*.sv Core/Frontend/Dispatch/*.sv Core/Frontend/Top.sv]
anvil_constraints frontend {
create_clock -name frontend_clk -period 2.500 [get_ports clk]

set late_controls [get_ports {stall redirect_fetch redirect_taken redirect_advanced redirect_slot[*] redirect_pc[*]}]
set_input_delay -clock frontend_clk -max 3.250 $late_controls 
# set_input_delay -clock frontend_clk -max 2.500 $late_controls 
set_input_delay -clock frontend_clk -min 2.000 $late_controls

# Relaxed controls arrive at 20% of the period (4 ns remains internally).
set easy_controls [get_ports {reset serial_active}]
set_input_delay -clock frontend_clk -max 1.000 $easy_controls
set_input_delay -clock frontend_clk -min 0.500 [get_ports serial_active]
# Reset is modeled as arriving 1 ns after the reference edge for both checks.
set_input_delay -clock frontend_clk -min 1.000 [get_ports reset]

set_output_delay -clock frontend_clk -max 0.000 [all_outputs]
set_output_delay -clock frontend_clk -min 0.000 [all_outputs]
}
anvil_implement frontend FrontendTop $frontend_part
