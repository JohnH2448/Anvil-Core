// Shared constants only. Raw settings are deliberately not imported/re-exported.
package DerivedParameters;

    // Shared derived configuration: compute once, consume with DerivedParameters::NAME.
    localparam int TOTAL_LANE_COUNT = Parameters::INTEGER_LANE_COUNT + Parameters::MEMORY_LANE_COUNT +
        Parameters::FLOATING_LANE_COUNT + Parameters::SERIAL_LANE_COUNT;
    localparam int UNROLL_WIDTH = (Parameters::UNROLL_CUTOFF > 0) ? $clog2(Parameters::UNROLL_CUTOFF + 1) : 1;
    localparam int LANE_WIDTH = (TOTAL_LANE_COUNT > 1) ? $clog2(TOTAL_LANE_COUNT) : 1;
    localparam int AGE_WIDTH = (Parameters::ISSUE_WIDTH > 1) ? $clog2(Parameters::ISSUE_WIDTH) : 1;
    localparam int TOTAL_INTEGER_STAGES = Parameters::UNROLL_CUTOFF + 2;

    /* verilator lint_off UNUSEDPARAM */
    // Placeholders until the execution topology supplies the forwarding points.
    localparam logic INT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][Parameters::UNROLL_CUTOFF:0] = '{default: '0};
    localparam logic READY_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][Parameters::UNROLL_CUTOFF:0] = '{default: '0};
    /* verilator lint_on UNUSEDPARAM */
endpackage
