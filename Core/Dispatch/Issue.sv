module Issuer 
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned UNROLL_CUTOFF = 1,
    parameter unsigned BYPASS_ENABLED = 1, 
    parameter unsigned ISSUE_WIDTH = 2 
)(

    // Standard Inputs
    input logic clk,
    input logic reset,
    input logic stall,
    input logic redirect_taken,

    // Decoder Popped Outputs
    input DecoderPacket_ packets_out [ISSUE_WIDTH-1:0],
    input LaneType_ lane_types_out [ISSUE_WIDTH-1:0],
    input logic packets_valid [ISSUE_WIDTH-1:0],

    // Consumption To Frontend
    output logic [$clog2(ISSUE_WIDTH+1)-1:0] issue_consumed,

    // Packets To Backend
    output DecoderPacket_ decoder_packet [ISSUE_WIDTH-1:0],
    output IssuerPacket_ issuer_packet [ISSUE_WIDTH-1:0],
    output logic accept_vector [TOTAL_LANE_COUNT-1:0],

    // Producer Table Reads
    output logic [4:0] rs1 [ISSUE_WIDTH-1:0],
    output logic [4:0] rs2 [ISSUE_WIDTH-1:0],

    // Producer Table Recipient Data
    input logic [UNROLLED_W-1:0] rs1_index [ISSUE_WIDTH-1:0],
    input logic [UNROLLED_W-1:0] rs2_index [ISSUE_WIDTH-1:0],
    input logic [UNROLLED_W-1:0] rs1_countdown [ISSUE_WIDTH-1:0],
    input logic [UNROLLED_W-1:0] rs2_countdown [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] rs1_lane [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] rs2_lane [ISSUE_WIDTH-1:0],
    input DecodeCapability_ rs1_capability [ISSUE_WIDTH-1:0],
    input DecodeCapability_ rs2_capability [ISSUE_WIDTH-1:0],

    // Producer Table Writes
    output logic [4:0] op_rd [ISSUE_WIDTH-1:0],
    output logic [LANE_WIDTH-1:0] op_lane [ISSUE_WIDTH-1:0],
    output logic op_accept [ISSUE_WIDTH-1:0],
    output logic [AGE_WIDTH-1:0] op_age [ISSUE_WIDTH-1:0],
    output DecodeCapability_ op_type [ISSUE_WIDTH-1:0],
    output logic op_wb [ISSUE_WIDTH-1:0]

);

    for (genvar i = 0; i < ISSUE_WIDTH; i++) begin : gen_prod_table_addr
        assign rs1[i] = packets_out[i].common.rs1;
        assign rs2[i] = packets_out[i].common.rs2;
    end

endmodule

// may need to pipeline this. low friction addition