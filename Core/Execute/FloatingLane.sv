module FloatingLane
    import DerivedParameters::*;
#(
    parameter IS_FLOAT = 1,
    parameter IS_CONVERT = 1,
    parameter UNROLL_CUTOFF = 1, // execution stages
    parameter ISSUE_WIDTH = 2, // for inter slice age bits
    parameter LANE_ID = 0, // 0 is first
    parameter logic FLOAT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][UNROLL_CUTOFF:0] = '{default: '0},
    parameter logic INT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][UNROLL_CUTOFF:0] = '{default: '0},
    parameter logic MEMORY_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][UNROLL_CUTOFF:0] = '{default: '0}
)(

);
endmodule