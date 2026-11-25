# Out-of-context synthesis and implementation of BackendTop only.
# vivado -mode batch -nolog -nojournal -source Synthesis/Scripts/backend.tcl [-tclargs [part] [period_ns]]
#
# The lane mix, issue width, unroll and bypass all come from Core/Package/Parameters.sv.
# The I/O model is based on the routed CoreTop run, where BackendTop's real neighbours are:
#   - FrontendTop's issue capture flops (Frontend/Top.sv). The lanes use
#     REGISTERED_INPUT=1, so these ports go directly into operand select.
#   - FrontendTop's fetch/redirect logic, which uses stall/redirect_* in the
#     same cycle. The budget mirrors the late_controls input delay in
#     frontend.tcl (3.25 ns dual / 2.50 ns single issue, from ISSUE_WIDTH).
#   - A synchronous data memory peer on the same clock, modeled as an
#     unregistered RAMB36 behind a thin valid/ready shell.
# All delays are absolute ns. Changing the period changes only the backend's internal budget.

source [file join [file dirname [file normalize [info script]]] common.tcl]
if {[llength $argv] > 2} {
    error {Usage: backend.tcl [part] [period_ns]}
}
set backend_part [expr {[llength $argv] >= 1 ? [lindex $argv 0] : $anvil_default_part}]
set backend_period [expr {[llength $argv] >= 2 ? [lindex $argv 1] : 5.000}]
anvil_begin backend
create_project -in_memory -part $backend_part
read_verilog -sv [anvil_sources Core/Backend/Execute/Integer/*.sv Core/Backend/Execute/Memory/*.sv Core/Backend/Execute/Serial/*.sv \
    Core/Backend/Support/IntegerFile.sv Core/Backend/Top.sv]

# Frontend contract (frontend.tcl late_controls): the frontend closes with these
# controls arriving 3.25 ns (dual issue) or 2.50 ns (single issue) after the clock edge.
# Mirror that here as an output delay so the backend owns everything up to that point.
set parameter_handle [open [file join $anvil_root Core Package Parameters.sv] r]
set parameter_text [read $parameter_handle]
close $parameter_handle
if {![regexp {parameter\s+unsigned\s+ISSUE_WIDTH\s*=\s*(\d+)} $parameter_text -> backend_issue_width]} {
    error "ISSUE_WIDTH not found in Parameters.sv"
}
set frontend_control_arrival [expr {$backend_issue_width > 1 ? 3.250 : 2.500}]
set frontend_control_delay [format %.3f [expr {$backend_period - $frontend_control_arrival}]]
puts "ISSUE_WIDTH=$backend_issue_width: frontend controls must arrive by $frontend_control_arrival ns (output delay $frontend_control_delay ns)"
set backend_constraints "create_clock -name backend_clk -period $backend_period \[get_ports clk\]\n"
append backend_constraints "set frontend_control_delay $frontend_control_delay\n"
append backend_constraints {
# --- Issue packets and bus inputs: see backend_post_synth below ----------------

# --- Reset: synchronized and registered elsewhere --------------------------------
set_input_delay -clock backend_clk -max 1.000 [get_ports reset]
set_input_delay -clock backend_clk -min 1.000 [get_ports reset]

# --- external_stall: tied to 1'b0 in CoreTop -------------------------------------
set_input_delay -clock backend_clk -max 1.000 [get_ports external_stall]
set_input_delay -clock backend_clk -min 0.400 [get_ports external_stall]
# Interrupt lines: asynchronous sources are synchronized outside the core.
set_input_delay -clock backend_clk -max 1.000 [get_ports {interrupt interrupt_type[*]}]
set_input_delay -clock backend_clk -min 0.400 [get_ports {interrupt interrupt_type[*]}]
# interrupt_request is a few LUTs after serial-lane flops. Frontend assumes a 1.0 ns arrival;
# this output budget is looser than that and is a placeholder until a backend run.
set_output_delay -clock backend_clk -max 1.000 [get_ports {interrupt_request[*]}]
set_output_delay -clock backend_clk -min 0.000 [get_ports {interrupt_request[*]}]
set_case_analysis 0 [get_ports external_stall]

# --- Same-cycle controls consumed by the frontend ---------------------------------
# Same port group as frontend.tcl late_controls. Output delay = period - arrival time,
# so these must reach the port by the arrival time the frontend was closed against.
# The frontend's -min 2.0 assumption is not mirrored: it would force hold padding on
# registered outputs (redirect_taken, redirect_slot).
set frontend_controls [get_ports {stall redirect_fetch redirect_taken redirect_advanced redirect_trap redirect_slot[*] redirect_pc[*]}]
set_output_delay -clock backend_clk -max $frontend_control_delay $frontend_controls
set_output_delay -clock backend_clk -min 0.000 $frontend_controls

# --- result_trap: unconnected in CoreTop until precise exceptions exist ----------
set_output_delay -clock backend_clk -max 0.000 [get_ports {result_trap[*]}]
set_output_delay -clock backend_clk -min 0.000 [get_ports {result_trap[*]}]
set_output_delay -clock backend_clk -max 0.000 [get_ports trap]
set_output_delay -clock backend_clk -min 0.000 [get_ports trap]

# --- Data bus: applied after synthesis by anvil_bus_constraints (common.tcl) ---
}
anvil_constraints backend $backend_constraints

# Register-launched inputs. Input delays are normally measured from the ideal clock
# at the port, but the launching flops (frontend capture registers, memory peer)
# sit on the same clock tree as the backend's flops and pay the same insertion
# delay. -reference_pin measures each delay from a real backend clock pin instead,
# so the value is just the launching cell's clock-to-output; the boundary route is
# the port net. Applied after synthesis, when register pins exist.
proc backend_post_synth {} {
    set reference [anvil_reference_pin]
    # Issue packets: FrontendTop capture flops (FDRE clk->Q ~0.34 ns). The lanes use
    # REGISTERED_INPUT=1, so these ports go directly into operand select.
    set issue_inputs [get_ports {decoder_packet[*] issuer_packet[*] accept_vector[*] watch[*]}]
    set_input_delay -clock backend_clk -reference_pin $reference -max 0.400 $issue_inputs
    set_input_delay -clock backend_clk -reference_pin $reference -min 0.300 $issue_inputs
    anvil_bus_constraints backend_clk
}
anvil_implement backend BackendTop $backend_part
