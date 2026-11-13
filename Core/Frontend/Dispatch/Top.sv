module DispatchTop
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned ISSUE_WIDTH = Parameters::ISSUE_WIDTH,
    parameter unsigned EXECUTION_UNROLL = Parameters::EXECUTION_UNROLL,
    parameter unsigned BYPASS_ENABLED = Parameters::BYPASS_ENABLED
)(
    input logic clk,
    input logic reset,
    input logic redirect_taken,
    input logic stall,
    input logic serial_active,

    // FetchTop serve interface
    input logic [31:0] serve_data_reg [ISSUE_WIDTH-1:0],
    input logic [4:0] serve_rs1 [ISSUE_WIDTH-1:0],
    input logic [4:0] serve_rs2 [ISSUE_WIDTH-1:0],
    input logic [31:0] serve_pc_reg [ISSUE_WIDTH-1:0],
    input logic serve_valid_reg [ISSUE_WIDTH-1:0],
    input logic serve_c_reg [ISSUE_WIDTH-1:0],
    input logic serve_taken_reg [ISSUE_WIDTH-1:0],
    input logic serve_branch_reg [ISSUE_WIDTH-1:0],
    output logic [$clog2(ISSUE_WIDTH+1)-1:0] serve_consumed,

    // Issuer outputs to the backend
    output DecoderPacket_ decoder_packet [TOTAL_LANE_COUNT-1:0],
    output IssuerPacket_ issuer_packet [TOTAL_LANE_COUNT-1:0],
    output logic accept_vector [TOTAL_LANE_COUNT-1:0]
);

    DecoderPacket_ packets_out [ISSUE_WIDTH-1:0];
    LaneType_ lane_types_out [ISSUE_WIDTH-1:0];
    logic packets_valid [ISSUE_WIDTH-1:0];
    logic [$clog2(ISSUE_WIDTH+1)-1:0] issue_consumed;

    // ProducerTable lookups
    logic [4:0] rs1 [ISSUE_WIDTH-1:0];
    logic [4:0] rs2 [ISSUE_WIDTH-1:0];
    logic [UNROLLED_W-1:0] rs1_index [ISSUE_WIDTH-1:0];
    logic [UNROLLED_W-1:0] rs2_index [ISSUE_WIDTH-1:0];
    logic [UNROLLED_W-1:0] rs1_countdown [ISSUE_WIDTH-1:0];
    logic [UNROLLED_W-1:0] rs2_countdown [ISSUE_WIDTH-1:0];
    logic [LANE_WIDTH-1:0] rs1_lane [ISSUE_WIDTH-1:0];
    logic [LANE_WIDTH-1:0] rs2_lane [ISSUE_WIDTH-1:0];
    DecodeCapability_ rs1_capability [ISSUE_WIDTH-1:0];
    DecodeCapability_ rs2_capability [ISSUE_WIDTH-1:0];

    // Registered producer lookups from decode to issue
    logic [UNROLLED_W-1:0] rs1_index_out [ISSUE_WIDTH-1:0];
    logic [UNROLLED_W-1:0] rs2_index_out [ISSUE_WIDTH-1:0];
    logic [UNROLLED_W-1:0] rs1_countdown_out [ISSUE_WIDTH-1:0];
    logic [UNROLLED_W-1:0] rs2_countdown_out [ISSUE_WIDTH-1:0];
    logic [LANE_WIDTH-1:0] rs1_lane_out [ISSUE_WIDTH-1:0];
    logic [LANE_WIDTH-1:0] rs2_lane_out [ISSUE_WIDTH-1:0];
    DecodeCapability_ rs1_capability_out [ISSUE_WIDTH-1:0];
    DecodeCapability_ rs2_capability_out [ISSUE_WIDTH-1:0];

    // ProducerTable updates from accepted issue slots
    logic [4:0] op_rd [ISSUE_WIDTH-1:0];
    logic [LANE_WIDTH-1:0] op_lane [ISSUE_WIDTH-1:0];
    logic op_accept [ISSUE_WIDTH-1:0];
    logic [AGE_WIDTH-1:0] op_age [ISSUE_WIDTH-1:0];
    DecodeCapability_ op_type [ISSUE_WIDTH-1:0];
    logic op_wb [ISSUE_WIDTH-1:0];

    DecodeStage #(
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .EXECUTION_UNROLL(EXECUTION_UNROLL),
        .SUPPORT_MUL(Parameters::SUPPORT_MUL),
        .SUPPORT_DIV(Parameters::SUPPORT_DIV),
        .SUPPORT_FLOAT(Parameters::SUPPORT_FLOAT),
        .SUPPORT_ATOMIC(Parameters::SUPPORT_ATOMIC)
    ) decode_stage (
        .clk(clk),
        .stall(stall),
        .reset(reset),
        .redirect_taken(redirect_taken),
        .serve_data_reg(serve_data_reg),
        .serve_rs1(serve_rs1),
        .serve_rs2(serve_rs2),
        .serve_pc_reg(serve_pc_reg),
        .serve_valid_reg(serve_valid_reg),
        .serve_c_reg(serve_c_reg),
        .serve_taken_reg(serve_taken_reg),
        .serve_branch_reg(serve_branch_reg),
        .packets_out(packets_out),
        .lane_types_out(lane_types_out),
        .packets_valid(packets_valid),
        .issue_consumed(issue_consumed),
        .serve_consumed(serve_consumed),
        .op_rd(op_rd),
        .op_lane(op_lane),
        .op_accept(op_accept),
        .op_wb(op_wb),
        .op_type(op_type),
        .rs1(rs1),
        .rs2(rs2),
        .rs1_index(rs1_index),
        .rs2_index(rs2_index),
        .rs1_countdown(rs1_countdown),
        .rs2_countdown(rs2_countdown),
        .rs1_lane(rs1_lane),
        .rs2_lane(rs2_lane),
        .rs1_capability(rs1_capability),
        .rs2_capability(rs2_capability),
        .rs1_index_out(rs1_index_out),
        .rs2_index_out(rs2_index_out),
        .rs1_countdown_out(rs1_countdown_out),
        .rs2_countdown_out(rs2_countdown_out),
        .rs1_lane_out(rs1_lane_out),
        .rs2_lane_out(rs2_lane_out),
        .rs1_capability_out(rs1_capability_out),
        .rs2_capability_out(rs2_capability_out)
    );

    Issuer #(
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .EXECUTION_UNROLL(EXECUTION_UNROLL),
        .BYPASS_ENABLED(BYPASS_ENABLED)
    ) issuer (
        .clk(clk),
        .reset(reset),
        .redirect_taken(redirect_taken),
        .stall(stall),
        .serial_active(serial_active),
        .packets_out(packets_out),
        .lane_types_out(lane_types_out),
        .packets_valid(packets_valid),
        .issue_consumed(issue_consumed),
        .decoder_packet(decoder_packet),
        .issuer_packet(issuer_packet),
        .accept_vector(accept_vector),
        .rs1_index_in(rs1_index_out),
        .rs2_index_in(rs2_index_out),
        .rs1_countdown_in(rs1_countdown_out),
        .rs2_countdown_in(rs2_countdown_out),
        .rs1_lane_in(rs1_lane_out),
        .rs2_lane_in(rs2_lane_out),
        .rs1_capability_in(rs1_capability_out),
        .rs2_capability_in(rs2_capability_out),
        .op_rd(op_rd),
        .op_lane(op_lane),
        .op_accept(op_accept),
        .op_age(op_age),
        .op_type(op_type),
        .op_wb(op_wb)
    );

    ProducerTable #(
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .EXECUTION_UNROLL(EXECUTION_UNROLL)
    ) producer_table (
        .clk(clk),
        .reset(reset),
        .redirect_taken(redirect_taken),
        .stall(stall),
        .rs1(rs1),
        .rs2(rs2),
        .rs1_index(rs1_index),
        .rs2_index(rs2_index),
        .rs1_countdown(rs1_countdown),
        .rs2_countdown(rs2_countdown),
        .rs1_lane(rs1_lane),
        .rs2_lane(rs2_lane),
        .rs1_capability(rs1_capability),
        .rs2_capability(rs2_capability),
        .op_rd(op_rd),
        .op_lane(op_lane),
        .op_accept(op_accept),
        .op_age(op_age),
        .op_type(op_type),
        .op_wb(op_wb)
    );

endmodule
