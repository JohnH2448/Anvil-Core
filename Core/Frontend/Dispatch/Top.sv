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
    input logic [4:0] serve_rd [ISSUE_WIDTH-1:0],
    input logic [4:0] serve_rs3 [ISSUE_WIDTH-1:0],
    input logic serve_rs1_float [ISSUE_WIDTH-1:0],
    input logic serve_rs2_float [ISSUE_WIDTH-1:0],
    input logic serve_rs3_float [ISSUE_WIDTH-1:0],
    input logic serve_rd_float [ISSUE_WIDTH-1:0],
    input logic serve_rs1_used [ISSUE_WIDTH-1:0],
    input logic serve_rs2_used [ISSUE_WIDTH-1:0],
    input logic serve_rd_written [ISSUE_WIDTH-1:0],
    input logic [$bits(DecodeCapability_)-1:0] serve_capability [ISSUE_WIDTH-1:0],
    input logic [13:0] serve_immediate_upper_select [ISSUE_WIDTH-1:0],
    input logic [4:0] serve_immediate_low [ISSUE_WIDTH-1:0],
    input logic [$bits(BranchOperation_)-1:0] serve_branch_operation [ISSUE_WIDTH-1:0],
    input logic serve_fp_consumer [ISSUE_WIDTH-1:0],
    input TrapType_ serve_trap [ISSUE_WIDTH-1:0],
    input logic [31:0] serve_pc_reg [ISSUE_WIDTH-1:0],
    input logic serve_valid_reg [ISSUE_WIDTH-1:0],
    input logic serve_c_reg [ISSUE_WIDTH-1:0],
    input logic serve_taken_reg [ISSUE_WIDTH-1:0],
    input logic serve_branch_reg [ISSUE_WIDTH-1:0],
    output logic [$clog2(ISSUE_WIDTH+1)-1:0] serve_consumed,
    output logic [$clog2(ISSUE_WIDTH+1)-1:0] serve_select_count,

    // Issuer outputs to the backend
    output DecoderPacket_ decoder_packet [TOTAL_LANE_COUNT-1:0],
    output IssuerPacket_ issuer_packet [TOTAL_LANE_COUNT-1:0],
    output logic accept_vector [TOTAL_LANE_COUNT-1:0]
);

    DecoderPacket_ packets_out [ISSUE_WIDTH-1:0];
    LaneType_ lane_types_out [ISSUE_WIDTH-1:0];
    logic packets_valid [ISSUE_WIDTH-1:0];
    logic group_raw [ISSUE_WIDTH-1:0];
    logic group_serial [ISSUE_WIDTH-1:0];
    logic group_resource_bad [ISSUE_WIDTH-1:0];
    logic operands_ready [ISSUE_WIDTH-1:0];
    logic [ISSUE_WIDTH-1:0] rs1_buffer_match [ISSUE_WIDTH-1:0];
    logic [ISSUE_WIDTH-1:0] rs2_buffer_match [ISSUE_WIDTH-1:0];
    logic [$clog2(ISSUE_WIDTH+1)-1:0] issue_consumed;
    logic [$clog2(ISSUE_WIDTH+1)-1:0] issue_select_count;
    logic issue_select_any, issue_select_two;

    // ProducerTable lookups
    logic [4:0] rs1 [ISSUE_WIDTH-1:0];
    logic [4:0] rs2 [ISSUE_WIDTH-1:0];
    logic [UNROLLED_W-1:0] rs1_index [ISSUE_WIDTH-1:0];
    logic [UNROLLED_W-1:0] rs2_index [ISSUE_WIDTH-1:0];
    logic [LANE_WIDTH-1:0] rs1_lane [ISSUE_WIDTH-1:0];
    logic [LANE_WIDTH-1:0] rs2_lane [ISSUE_WIDTH-1:0];
    DecodeCapability_ rs1_capability [ISSUE_WIDTH-1:0];
    DecodeCapability_ rs2_capability [ISSUE_WIDTH-1:0];

    logic rs1_capture_ready [ISSUE_WIDTH-1:0];
    logic rs2_capture_ready [ISSUE_WIDTH-1:0];

    // Registered producer lookups from decode to issue
    logic [UNROLLED_W-1:0] rs1_index_out [ISSUE_WIDTH-1:0];
    logic [UNROLLED_W-1:0] rs2_index_out [ISSUE_WIDTH-1:0];
    logic [LANE_WIDTH-1:0] rs1_lane_out [ISSUE_WIDTH-1:0];
    logic [LANE_WIDTH-1:0] rs2_lane_out [ISSUE_WIDTH-1:0];
    DecodeCapability_ rs1_capability_out [ISSUE_WIDTH-1:0];
    DecodeCapability_ rs2_capability_out [ISSUE_WIDTH-1:0];

    // Registered issue write buffer, shared by table commit and decode absorption
    logic [4:0] op_rd [ISSUE_WIDTH-1:0];
    logic [LANE_WIDTH-1:0] op_lane [ISSUE_WIDTH-1:0];
    logic op_write [ISSUE_WIDTH-1:0];
    logic [AGE_WIDTH-1:0] op_age [ISSUE_WIDTH-1:0];
    DecodeCapability_ op_type [ISSUE_WIDTH-1:0];

    DecodeStage #(
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .EXECUTION_UNROLL(EXECUTION_UNROLL),
        .BYPASS_ENABLED(BYPASS_ENABLED),
        .DIVIDER_AUTO_PIPE(Parameters::DIVIDER_AUTO_PIPE),
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
        .serve_rd(serve_rd),
        .serve_rs3(serve_rs3),
        .serve_rs1_float(serve_rs1_float),
        .serve_rs2_float(serve_rs2_float),
        .serve_rs3_float(serve_rs3_float),
        .serve_rd_float(serve_rd_float),
        .serve_rs1_used(serve_rs1_used),
        .serve_rs2_used(serve_rs2_used),
        .serve_rd_written(serve_rd_written),
        .serve_capability(serve_capability),
        .serve_immediate_upper_select(serve_immediate_upper_select),
        .serve_immediate_low(serve_immediate_low),
        .serve_branch_operation(serve_branch_operation),
        .serve_fp_consumer(serve_fp_consumer),
        .serve_trap(serve_trap),
        .serve_pc_reg(serve_pc_reg),
        .serve_valid_reg(serve_valid_reg),
        .serve_c_reg(serve_c_reg),
        .serve_taken_reg(serve_taken_reg),
        .serve_branch_reg(serve_branch_reg),
        .packets_out(packets_out),
        .lane_types_out(lane_types_out),
        .packets_valid(packets_valid),
        .group_raw(group_raw),
        .group_serial(group_serial),
        .group_resource_bad(group_resource_bad),
        .operands_ready(operands_ready),
        .rs1_buffer_match(rs1_buffer_match),
        .rs2_buffer_match(rs2_buffer_match),
        .issue_select_count(issue_select_count),
        .issue_select_any(issue_select_any),
        .issue_select_two(issue_select_two),
        .serve_consumed(serve_consumed),
        .serve_select_count(serve_select_count),
        .op_rd(op_rd),
        .op_lane(op_lane),
        .op_write(op_write),
        .op_type(op_type),
        .rs1(rs1),
        .rs2(rs2),
        .rs1_capture_ready(rs1_capture_ready),
        .rs2_capture_ready(rs2_capture_ready),
        .rs1_index(rs1_index),
        .rs2_index(rs2_index),
        .rs1_lane(rs1_lane),
        .rs2_lane(rs2_lane),
        .rs1_capability(rs1_capability),
        .rs2_capability(rs2_capability),
        .rs1_index_out(rs1_index_out),
        .rs2_index_out(rs2_index_out),
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
        .group_raw(group_raw),
        .group_serial(group_serial),
        .group_resource_bad(group_resource_bad),
        .operands_ready(operands_ready),
        .rs1_buffer_match(rs1_buffer_match),
        .rs2_buffer_match(rs2_buffer_match),
        .issue_consumed(issue_consumed),
        .issue_select_count(issue_select_count),
        .issue_select_any(issue_select_any),
        .issue_select_two(issue_select_two),
        .decoder_packet(decoder_packet),
        .issuer_packet(issuer_packet),
        .accept_vector(accept_vector),
        .rs1_index_in(rs1_index_out),
        .rs2_index_in(rs2_index_out),
        .rs1_lane_in(rs1_lane_out),
        .rs2_lane_in(rs2_lane_out),
        .rs1_capability_in(rs1_capability_out),
        .rs2_capability_in(rs2_capability_out),
        .op_rd(op_rd),
        .op_lane(op_lane),
        .op_write(op_write),
        .op_age(op_age),
        .op_type(op_type)
    );

    ProducerTable #(
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .EXECUTION_UNROLL(EXECUTION_UNROLL),
        .DIVIDER_AUTO_PIPE(Parameters::DIVIDER_AUTO_PIPE)
    ) producer_table (
        .clk(clk),
        .reset(reset),
        .redirect_taken(redirect_taken),
        .stall(stall),
        .rs1(rs1),
        .rs2(rs2),
        .rs1_capture_ready(rs1_capture_ready),
        .rs2_capture_ready(rs2_capture_ready),
        .rs1_index(rs1_index),
        .rs2_index(rs2_index),
        .rs1_lane(rs1_lane),
        .rs2_lane(rs2_lane),
        .rs1_capability(rs1_capability),
        .rs2_capability(rs2_capability),
        .op_rd(op_rd),
        .op_lane(op_lane),
        .op_write(op_write),
        .op_age(op_age),
        .op_type(op_type)
    );

endmodule
