module MemoryLane #(
    parameter IS_MEMORY = 1,
    parameter IS_FLOAT = 1,
    parameter IS_ATOMIC = 1,
    parameter UNROLL_CUTOFF = 4, // 5 stages total. should never be <= 0
    parameter ISSUE_WIDTH = 2, // for inter slice age bits
    parameter LANE_ID = 0, // 0 is first
    parameter INTEGER_LANE_COUNT = 1, // 1 lane
    parameter MEMORY_LANE_COUNT = 1, 
    parameter FLOATING_LANE_COUNT = 1,
    parameter SERIAL_LANE_COUNT = 1, 
    parameter TOTAL_LANE_COUNT = INTEGER_LANE_COUNT + MEMORY_LANE_COUNT + FLOATING_LANE_COUNT + SERIAL_LANE_COUNT,
    parameter logic FLOAT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][UNROLL_CUTOFF:0] = '0,
    parameter logic INT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][UNROLL_CUTOFF:0] = '0,
    parameter logic MEMORY_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][UNROLL_CUTOFF:0] = '0,
    parameter AGE_WIDTH = (ISSUE_WIDTH > 1) ? $clog2(ISSUE_WIDTH) : 1
)(

);
endmodule