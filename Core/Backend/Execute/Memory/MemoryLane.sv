module MemoryLane
    import DerivedParameters::*;
#(
    parameter unsigned IS_MEMORY = 1,
    parameter unsigned IS_FLOAT = 1,
    parameter unsigned IS_ATOMIC = 1,
    parameter unsigned EXECUTION_UNROLL = 1, // execution stages
    parameter unsigned ISSUE_WIDTH = 2, // for inter slice age bits
    parameter unsigned LANE_ID = 0, // 0 is first
    parameter logic FLOAT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0] = '{default: '0},
    parameter logic INT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0] = '{default: '0},
    parameter logic MEMORY_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0] = '{default: '0}
)(

);
endmodule

// only need stalls when iteration point is hit or operand needed
// use ready bits and latch responses
// use wide axi type bus with seperate response and request channels
// gives unroll cutoff extra utility for hiding load stalls