// Shared constants only. Raw settings are deliberately not imported/re-exported.
package DerivedParameters;

    // Shared derived configuration: compute once, consume with DerivedParameters::NAME.
    localparam int unsigned TOTAL_LANE_COUNT = Parameters::INTEGER_LANE_COUNT + Parameters::MEMORY_LANE_COUNT +
        Parameters::FLOATING_LANE_COUNT + Parameters::SERIAL_LANE_COUNT;
    localparam int unsigned UNROLL_WIDTH = (Parameters::UNROLL_CUTOFF > 0) ? $clog2(Parameters::UNROLL_CUTOFF + 1) : 1;
    localparam int unsigned LANE_WIDTH = (TOTAL_LANE_COUNT > 1) ? $clog2(TOTAL_LANE_COUNT) : 1;

    function automatic int unsigned lane_counter_width(input int unsigned lane_count);
        return $unsigned((lane_count > 0) ? $clog2(lane_count + 1) : 1);
    endfunction

    // Counters represent zero through the number of lanes with each capability.
    localparam int unsigned CAP_ALU_LANE_W = lane_counter_width(
        Parameters::INTEGER_LANE_CAPABILITIES.sum() with (int'(item[0])));
    localparam int unsigned CAP_BRU_LANE_W = lane_counter_width(
        Parameters::INTEGER_LANE_CAPABILITIES.sum() with (int'(item[1])));
    localparam int unsigned CAP_MUL_LANE_W = lane_counter_width(
        Parameters::INTEGER_LANE_CAPABILITIES.sum() with (int'(item[2])));
    localparam int unsigned CAP_DIV_LANE_W = lane_counter_width(
        Parameters::INTEGER_LANE_CAPABILITIES.sum() with (int'(item[3])));
    localparam int unsigned CAP_FP_F_LANE_W = lane_counter_width(
        Parameters::FLOATING_LANE_CAPABILITIES.sum() with (int'(item[0])));
    localparam int unsigned CAP_MEMORY_LANE_W = lane_counter_width(
        Parameters::MEMORY_LANE_CAPABILITIES.sum() with (int'(item[0])));
    localparam int unsigned CAP_ATOMIC_LANE_W = lane_counter_width(
        Parameters::MEMORY_LANE_CAPABILITIES.sum() with (int'(item[1])));
    localparam int unsigned CAP_SYSTEM_LANE_W = lane_counter_width(Parameters::SERIAL_LANE_COUNT);
    localparam int unsigned CAP_CSR_LANE_W = lane_counter_width(Parameters::SERIAL_LANE_COUNT);
    localparam int unsigned CAP_FP_CONVERT_LANE_W = lane_counter_width(
        Parameters::FLOATING_LANE_CAPABILITIES.sum() with (int'(item[1])));

    localparam int unsigned AGE_WIDTH = (Parameters::ISSUE_WIDTH > 1) ? $clog2(Parameters::ISSUE_WIDTH) : 1;
    localparam int unsigned TOTAL_INTEGER_STAGES = Parameters::UNROLL_CUTOFF + 2;
    localparam int unsigned UNROLLED_W = $clog2(Parameters::UNROLL_CUTOFF+2) + 1; // extra room bit just in case

    /* verilator lint_off UNUSEDPARAM */
    // Placeholders until sthe execution topology supplies the forwarding points.
    localparam logic INT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][Parameters::UNROLL_CUTOFF:0] = '{default: '0};
    localparam logic READY_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][Parameters::UNROLL_CUTOFF:0] = '{default: '0};
    /* verilator lint_on UNUSEDPARAM */
    
endpackage
