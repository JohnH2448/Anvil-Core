module MemoryLane
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned IS_MEMORY = 1,
    parameter unsigned IS_FLOAT = 1,
    parameter unsigned IS_ATOMIC = 1,
    parameter unsigned EXECUTION_UNROLL = 1, // execution stages
    parameter unsigned BYPASS_ENABLED = 1, // worth considering for only alu, no bru
    parameter unsigned ISSUE_WIDTH = 2, // for inter slice age bits
    parameter unsigned LANE_ID = 0, // 0 is first
    parameter logic FLOAT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0] = '{default: '0},
    parameter logic INT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0] = '{default: '0}
)(

    // Standard Inputs
    input logic clk,
    input logic reset,

    // Data From Issuer
    input DecoderPacket_ decoder_packet,
    input IssuerPacket_ issuer_packet,
    input logic accept,

    // Integer Forwarding Inputs
    input logic [31:0] forward_data [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0], // used by all valid int forward points
    input logic forward_ready [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0], // tie all non iterative/memory points to 1 in top

    // Forwarding Outputs
    output logic [31:0] forward_data_out [EXECUTION_UNROLL:0],
    output logic forward_ready_out, // only used if iteration point exists

    // Bypass Inputs
    input logic [31:0] bypass_data [TOTAL_LANE_COUNT-1:0],

    // Bypass Outputs
    output logic [31:0] bypass_data_out,

    // Redirect Inputs
    input logic redirect_taken [TOTAL_LANE_COUNT-1:0],
    input logic [AGE_WIDTH-1:0] redirect_age [TOTAL_LANE_COUNT-1:0],

    // Redirect Outputs
    output logic redirect_taken_out,
    output logic [AGE_WIDTH-1:0] redirect_age_out,
    output logic [31:0] redirect_pc_out,

    // Stall Controls
    output logic stall_out,
    input logic stall, // top needs to or all outs and pass an in

    // Result Broadcast
    output logic [31:0] result_data,
    output logic [4:0] result_destination,
    output logic [AGE_WIDTH-1:0] result_age, 
    output logic result_ready, 
    output logic result_trap,

    // Register File Read Ports
    output logic [4:0] reg_address_1,
    output logic [4:0] reg_address_2,
    input logic [31:0] read_data_1,
    input logic [31:0] read_data_2
);
endmodule

// MEMORY: +2 integer read ports, +1 integer write port
// FLOAT: +2 floating read ports, +1 floating write port


// only need stalls when iteration point is hit or operand needed
// use ready bits and latch responses
// use wide axi type bus with seperate response and request channels
// gives unroll cutoff extra utility for hiding load stalls