// Shared constants only. Raw settings are deliberately not imported/re-exported.
package DerivedParameters;
    localparam int unsigned MEMORY_ADDRESS_BITS =
        $clog2({1'b0, Parameters::MAX_MEMORY_ADDRESS} + 33'd1);
    localparam int unsigned FETCH_PC_WIDTH = MEMORY_ADDRESS_BITS > 0 ? MEMORY_ADDRESS_BITS : 1;
    typedef logic [FETCH_PC_WIDTH-1:0] fetch_pc_t;

    typedef logic [3:0] integer_caps_t [(Parameters::INTEGER_LANE_COUNT > 0 ? Parameters::INTEGER_LANE_COUNT : 1)];
    function automatic integer_caps_t build_integer_caps();
        integer_caps_t caps;
        caps = '{default: '0};
        for (int lane = 0; lane < Parameters::INTEGER_LANE_COUNT; lane++)
            caps[lane] = Parameters::INTEGER_LANE_CAPABILITIES[lane] & {(Parameters::SUPPORT_DIV != 0), (Parameters::SUPPORT_MUL != 0), 2'b11};
        return caps;
    endfunction
    localparam integer_caps_t EFFECTIVE_INTEGER_CAPS = build_integer_caps();

    typedef logic [2:0] memory_caps_t [(Parameters::MEMORY_LANE_COUNT > 0 ? Parameters::MEMORY_LANE_COUNT : 1)];
    function automatic memory_caps_t build_memory_caps();
        memory_caps_t caps;
        caps = '{default: '0};
        for (int lane = 0; lane < Parameters::MEMORY_LANE_COUNT; lane++)
            caps[lane] = Parameters::MEMORY_LANE_CAPABILITIES[lane] & {(Parameters::SUPPORT_FLOAT != 0), (Parameters::SUPPORT_ATOMIC != 0), 1'b1};
        return caps;
    endfunction
    localparam memory_caps_t EFFECTIVE_MEMORY_CAPS = build_memory_caps();

    typedef logic [1:0] floating_caps_t [(Parameters::FLOATING_LANE_COUNT > 0 ? Parameters::FLOATING_LANE_COUNT : 1)];
    function automatic floating_caps_t build_floating_caps();
        floating_caps_t caps;
        caps = '{default: '0};
        for (int lane = 0; lane < Parameters::FLOATING_LANE_COUNT; lane++)
            caps[lane] = Parameters::FLOATING_LANE_CAPABILITIES[lane] & {2{Parameters::SUPPORT_FLOAT != 0}};
        return caps;
    endfunction
    localparam floating_caps_t EFFECTIVE_FLOATING_CAPS = build_floating_caps();

    // Shared derived configuration: compute once, consume with DerivedParameters::NAME.
    // Physical lane order: serial, integer, memory, floating.
    localparam int unsigned SERIAL_LANE_ID = 0;
    localparam int unsigned TOTAL_LANE_COUNT = 1 + Parameters::INTEGER_LANE_COUNT +
        Parameters::MEMORY_LANE_COUNT + Parameters::FLOATING_LANE_COUNT;
    localparam int unsigned UNROLL_WIDTH = (Parameters::EXECUTION_UNROLL > 0) ? $clog2(Parameters::EXECUTION_UNROLL + 1) : 1;
    localparam int unsigned LANE_WIDTH = (TOTAL_LANE_COUNT > 1) ? $clog2(TOTAL_LANE_COUNT) : 1;

    function automatic int unsigned lane_counter_width(input int unsigned lane_count);
        return $unsigned((lane_count > 0) ? $clog2(lane_count + 1) : 1);
    endfunction

    function automatic int unsigned count_integer_lanes(input int unsigned capability_bit);
        int unsigned count;
        count = 0;
        for (int unsigned lane = 0; lane < Parameters::INTEGER_LANE_COUNT; lane++) begin
            count += int'(EFFECTIVE_INTEGER_CAPS[lane][capability_bit]);
        end
        return count;
    endfunction

    function automatic int unsigned count_memory_lanes(input int unsigned capability_bit);
        int unsigned count;
        count = 0;
        for (int unsigned lane = 0; lane < Parameters::MEMORY_LANE_COUNT; lane++) begin
            count += int'(EFFECTIVE_MEMORY_CAPS[lane][capability_bit]);
        end
        return count;
    endfunction

    function automatic int unsigned count_floating_lanes(input int unsigned capability_bit);
        int unsigned count;
        count = 0;
        for (int unsigned lane = 0; lane < Parameters::FLOATING_LANE_COUNT; lane++) begin
            count += int'(EFFECTIVE_FLOATING_CAPS[lane][capability_bit]);
        end
        return count;
    endfunction

    // Counters represent zero through the number of lanes with each capability.
    localparam int unsigned CAP_ALU_LANE_W = lane_counter_width(
        count_integer_lanes(0));
    localparam int unsigned CAP_BRU_LANE_W = lane_counter_width(
        count_integer_lanes(1));
    localparam int unsigned CAP_MUL_LANE_W = lane_counter_width(
        count_integer_lanes(2));
    localparam int unsigned CAP_DIV_LANE_W = lane_counter_width(
        count_integer_lanes(3));
    localparam int unsigned CAP_FP_F_LANE_W = lane_counter_width(
        count_floating_lanes(0));
    localparam int unsigned CAP_MEMORY_LANE_W = lane_counter_width(
        count_memory_lanes(0));
    localparam int unsigned CAP_ATOMIC_LANE_W = lane_counter_width(
        count_memory_lanes(1));
    localparam int unsigned CAP_FP_CONVERT_LANE_W = lane_counter_width(
        count_floating_lanes(1));

    localparam int unsigned AGE_WIDTH = (Parameters::ISSUE_WIDTH > 1) ? $clog2(Parameters::ISSUE_WIDTH) : 1;
    localparam int unsigned TOTAL_INTEGER_STAGES = Parameters::EXECUTION_UNROLL + 2;
    localparam int unsigned UNROLLED_W = $clog2(Parameters::EXECUTION_UNROLL+2) + 1; // extra room bit just in case

    /* verilator lint_off UNUSEDPARAM */
    // Placeholders until sthe execution topology supplies the forwarding points.
    localparam logic INT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][Parameters::EXECUTION_UNROLL:0] = '{default: '0};
    localparam logic READY_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][Parameters::EXECUTION_UNROLL:0] = '{default: '0};
    /* verilator lint_on UNUSEDPARAM */
    
endpackage
