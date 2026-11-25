# Shared by every script in Synthesis/Scripts.
#   Synthesis/Scripts/   flow scripts (this directory)
#   Synthesis/Build/<flow>/    checkpoints and generated XDC
#   Synthesis/Reports/<flow>/  final reports
# Launch Vivado with -nolog -nojournal so no vivado.log or vivado.jou is created.
# Scripts run from the repository root, so relative RTL paths
# (for example program.hex) resolve regardless of where Vivado was started.

set anvil_scripts [file dirname [file normalize [info script]]]
set anvil_synthesis [file dirname $anvil_scripts]
set anvil_root [file dirname $anvil_synthesis]
set anvil_default_part xc7a100tcsg324-3

proc anvil_build_dir {flow} {
    global anvil_synthesis
    return [file join $anvil_synthesis Build $flow]
}
proc anvil_report_dir {flow} {
    global anvil_synthesis
    return [file join $anvil_synthesis Reports $flow]
}

# Remove Vivado clutter. Files locked by another running Vivado are skipped.
proc anvil_clean {} {
    global anvil_root anvil_synthesis
    foreach dir [list $anvil_root $anvil_synthesis $anvil_synthesis/Scripts] {
        foreach pattern {vivado*.jou vivado*.log vivado_pid*.str webtalk* usage_statistics_webtalk.*
                         clockInfo.txt dfx_runtime.txt tight_setup_hold_pins.txt hs_err_pid*.log} {
            foreach stale [glob -nocomplain -directory $dir $pattern] {
                catch {file delete -force $stale}
            }
        }
        foreach stale [glob -nocomplain -directory [file join $dir .Xil] *] {
            catch {file delete -force $stale}
        }
    }
}

# Start a flow: clean, replace its Build and Reports directories, enter the repository root.
proc anvil_begin {flow} {
    global anvil_root
    anvil_clean
    foreach dir [list [anvil_build_dir $flow] [anvil_report_dir $flow]] {
        file delete -force $dir
        file mkdir $dir
    }
    cd $anvil_root
}

# Package sources from packages.f, then the listed globs/files (relative to the root).
proc anvil_sources {args} {
    global anvil_root
    set sources {}
    set package_list [open [file join $anvil_root Core Package packages.f] r]
    foreach line [split [read $package_list] "\n"] {
        set line [string trim $line]
        if {$line ne "" && ![string match "#*" $line]} {
            lappend sources [file join $anvil_root $line]
        }
    }
    close $package_list
    foreach pattern $args {
        set matches [lsort [glob -nocomplain [file join $anvil_root $pattern]]]
        if {[llength $matches] == 0} { error "No sources match $pattern" }
        lappend sources {*}$matches
    }
    return $sources
}

proc anvil_clock_source {part} {
    # Estimate OOC clock insertion and skew from a real global-buffer site.
    set sites [lsort [get_sites -filter {SITE_TYPE =~ BUFG*}]]
    if {[llength $sites] == 0} { error "No global clock-buffer site found for $part" }
    set_property HD.CLK_SRC [lindex $sites 0] [get_ports clk]
    puts "OOC clock-source estimate: [get_property HD.CLK_SRC [get_ports clk]]"
}

proc anvil_final_reports {report_dir} {
    report_timing_summary -file [file join $report_dir timing_summary.rpt]
    report_timing -delay_type max -max_paths 50 -path_type full_clock_expanded \
        -file [file join $report_dir worst_setup.rpt]
    report_timing -delay_type min -max_paths 20 -path_type full_clock_expanded \
        -file [file join $report_dir worst_hold.rpt]
    report_utilization -file [file join $report_dir utilization.rpt]
    report_route_status -file [file join $report_dir route_status.rpt]
}

# Synthesis plus reduced-effort implementation with post-place fanout optimization.
# Keep directives identical across revisions so runs stay comparable.
proc anvil_implement {flow top part} {
    set build [anvil_build_dir $flow]
    synth_design -top $top -mode out_of_context -part $part -directive Default
    anvil_clock_source $part
    # Optional per-flow hook for constraints that need the synthesized netlist.
    if {[info procs ${flow}_post_synth] ne ""} { ${flow}_post_synth }
    write_checkpoint -force [file join $build ${flow}_synth.dcp]
    opt_design -directive RuntimeOptimized
    place_design -directive RuntimeOptimized
    # Placement-aware replication of high-fanout drivers (for example the lane
    # operand registers, fanout 90-180) near each consumer cluster. No RTL change.
    phys_opt_design -directive AggressiveFanoutOpt
    write_checkpoint -force [file join $build ${flow}_placed.dcp]
    route_design -directive RuntimeOptimized
    write_checkpoint -force [file join $build ${flow}_routed.dcp]
    anvil_final_reports [anvil_report_dir $flow]
    puts "Checkpoints: $build"
    puts "Reports: [anvil_report_dir $flow]"
}

# A real register clock pin, for -reference_pin input delays: register-launched
# inputs then pay the same clock insertion as internal flops. Needs a netlist.
proc anvil_reference_pin {} {
    # 7-series flops are FDRE/FDSE/FDCE/FDPE (PRIMITIVE_TYPE FLOP_LATCH.flop.*).
    set reference [lindex [get_pins -of_objects [lindex [get_cells -hierarchical         -filter {REF_NAME =~ FD*}] 0] -filter {REF_PIN_NAME == C}] 0]
    if {$reference eq ""} { error "No register clock pin found for input reference" }
    puts "Input delay reference pin: $reference"
    return $reference
}

# Shared data-bus model: a synchronous peer on the same clock, an unregistered
# RAMB36 behind a thin valid/ready shell. Call after synthesis.
proc anvil_bus_constraints {clock} {
    set reference [anvil_reference_pin]
    # Read data straight from RAMB36 DO pins, no output register (clk->DO ~1.8 ns).
    set response_payload [get_ports {response_data[*] response_error}]
    set_input_delay -clock $clock -reference_pin $reference -max 1.800 $response_payload
    set_input_delay -clock $clock -reference_pin $reference -min 0.600 $response_payload
    # Peer handshake flags come from flops.
    set bus_flags [get_ports {request_ready response_valid}]
    set_input_delay -clock $clock -reference_pin $reference -max 0.400 $bus_flags
    set_input_delay -clock $clock -reference_pin $reference -min 0.300 $bus_flags
    # Requests are captured on RAM address/data/WE pins (setup ~0.45 ns plus routing).
    set request_payload [get_ports {request_address[*] request_data[*] request_mask[*] request_size[*] request_write}]
    set_output_delay -clock $clock -max 1.000 $request_payload
    set_output_delay -clock $clock -min 0.000 $request_payload
    # Valid and response_ready also pass through one LUT level of peer handshake logic.
    set request_handshake [get_ports {request_valid response_ready}]
    set_output_delay -clock $clock -max 1.300 $request_handshake
    set_output_delay -clock $clock -min 0.000 $request_handshake
}

# Shared-RAM fetch port (CoreTop/FrontendTop since instruction memory moved
# into the system RAM). Assumptions, unmeasured: fetch_data comes from the
# RAM bank DO pins through the window rotate/halfword mux; fetch_valid is a
# Crossbar flop; fetch_address feeds the Crossbar bank-conflict check and
# the RAM's per-bank address mux before the BRAM address pins.
proc anvil_fetch_constraints {clock} {
    set reference [anvil_reference_pin]
    set_input_delay -clock $clock -reference_pin $reference -max 2.000 [get_ports {fetch_data[*]}]
    set_input_delay -clock $clock -reference_pin $reference -min 0.600 [get_ports {fetch_data[*]}]
    set_input_delay -clock $clock -reference_pin $reference -max 0.400 [get_ports {fetch_valid fetch_error}]
    set_input_delay -clock $clock -reference_pin $reference -min 0.300 [get_ports {fetch_valid fetch_error}]
    set_output_delay -clock $clock -max 1.000 [get_ports {fetch_address[*] fetch_request}]
    set_output_delay -clock $clock -min 0.000 [get_ports {fetch_address[*] fetch_request}]
}

# Write constraint text to Build/<flow>/<flow>.xdc and read it.
proc anvil_constraints {flow text} {
    set xdc [file join [anvil_build_dir $flow] ${flow}.xdc]
    set handle [open $xdc w]
    puts $handle $text
    close $handle
    read_xdc $xdc
}

# Resolve a routed checkpoint from a flow name (backend, frontend, cpu, ...) or a path.
proc anvil_checkpoint {name} {
    if {[file isfile $name]} { return [file normalize $name] }
    set dcp [file join [anvil_build_dir $name] ${name}_routed.dcp]
    if {![file isfile $dcp]} { error "Routed checkpoint not found: $dcp" }
    return $dcp
}
