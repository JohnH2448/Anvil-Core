# Out-of-context synthesis and implementation of the whole core (CoreTop).
# vivado -mode batch -nolog -nojournal -source Synthesis/Scripts/cpu.tcl [-tclargs [part] [period_ns]]
#
# Everything between frontend and backend is real logic and routing here, so
# frontend/backend boundary paths (stall, redirect, issue packets) are measured,
# not modeled. Only the data bus and reset are external. The bus model matches
# backend.tcl (anvil_bus_constraints) so the two runs can be compared directly.

source [file join [file dirname [file normalize [info script]]] common.tcl]
if {[llength $argv] > 2} {
    error {Usage: cpu.tcl [part] [period_ns]}
}
set cpu_part [expr {[llength $argv] >= 1 ? [lindex $argv 0] : $anvil_default_part}]
set cpu_period [expr {[llength $argv] >= 2 ? [lindex $argv 1] : 5.000}]
anvil_begin cpu
create_project -in_memory -part $cpu_part
read_verilog -sv [anvil_sources Core/Frontend/Fetch/*.sv Core/Frontend/Dispatch/*.sv Core/Frontend/Top.sv \
    Core/Backend/Execute/Integer/*.sv Core/Backend/Execute/Memory/*.sv \
    Core/Backend/Support/IntegerFile.sv Core/Backend/Top.sv Core/Top.sv]
set cpu_constraints "create_clock -name cpu_clk -period $cpu_period \[get_ports clk\]\n"
append cpu_constraints {
# Reset: synchronized and registered elsewhere.
set_input_delay -clock cpu_clk -max 1.000 [get_ports reset]
set_input_delay -clock cpu_clk -min 1.000 [get_ports reset]
}
anvil_constraints cpu $cpu_constraints
proc cpu_post_synth {} {
    anvil_bus_constraints cpu_clk
}
anvil_implement cpu CoreTop $cpu_part
