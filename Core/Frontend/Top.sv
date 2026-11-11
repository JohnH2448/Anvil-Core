module FrontendTop
    import DerivedParameters::*;
    import Definitions::*;
#(
    parameter unsigned FETCH_WORDS = Parameters::CACHE_LINE_WORDS,
    parameter unsigned FIFO_WORDS = Parameters::FETCH_FIFO_WORDS,
    parameter unsigned ISSUE_WIDTH = Parameters::ISSUE_WIDTH,
    parameter unsigned EXECUTION_UNROLL = Parameters::EXECUTION_UNROLL,
    parameter unsigned BYPASS_ENABLED = Parameters::BYPASS_ENABLED,
    parameter unsigned RESET_VECTOR = Parameters::RESET_VECTOR,
    parameter unsigned IMEM_DEPTH_WORDS = 512,
    parameter IMEM_HEX_FILE = "Core/Frontend/Fetch/program.hex"
)(
    input logic clk,
    input logic reset,
    input logic [31:0] redirect_pc,
    input logic redirect_taken,
    input logic stall,
    input logic serial_active,

    output DecoderPacket_ decoder_packet [TOTAL_LANE_COUNT-1:0],
    output IssuerPacket_ issuer_packet [TOTAL_LANE_COUNT-1:0],
    output logic accept_vector [TOTAL_LANE_COUNT-1:0]
);

    logic [31:0] serve_data_reg [ISSUE_WIDTH-1:0];
    logic [31:0] serve_pc_reg [ISSUE_WIDTH-1:0];
    logic serve_valid_reg [ISSUE_WIDTH-1:0];
    logic serve_c_reg [ISSUE_WIDTH-1:0];
    logic serve_taken_reg [ISSUE_WIDTH-1:0];
    logic serve_branch_reg [ISSUE_WIDTH-1:0];
    logic incoming_serve_valid [ISSUE_WIDTH-1:0];
    logic [$clog2(ISSUE_WIDTH+1)-1:0] serve_consumed;

    FetchTop #(
        .FETCH_WORDS(FETCH_WORDS),
        .FIFO_WORDS(FIFO_WORDS),
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .RESET_VECTOR(RESET_VECTOR),
        .IMEM_DEPTH_WORDS(IMEM_DEPTH_WORDS),
        .IMEM_HEX_FILE(IMEM_HEX_FILE)
    ) fetch (
        .clk(clk),
        .reset(reset),
        .redirect_pc(redirect_pc),
        .redirect_taken(redirect_taken),
        .serve_data_reg(serve_data_reg),
        .serve_pc_reg(serve_pc_reg),
        .serve_valid_reg(serve_valid_reg),
        .serve_c_reg(serve_c_reg),
        .serve_taken_reg(serve_taken_reg),
        .serve_branch_reg(serve_branch_reg),
        .incoming_serve_valid(incoming_serve_valid),
        .serve_consumed(serve_consumed)
    );

    DispatchTop #(
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .EXECUTION_UNROLL(EXECUTION_UNROLL),
        .BYPASS_ENABLED(BYPASS_ENABLED)
    ) dispatch (
        .clk(clk),
        .reset(reset),
        .redirect_taken(redirect_taken),
        .stall(stall),
        .serial_active(serial_active),
        .serve_data_reg(serve_data_reg),
        .serve_pc_reg(serve_pc_reg),
        .serve_valid_reg(serve_valid_reg),
        .serve_c_reg(serve_c_reg),
        .serve_taken_reg(serve_taken_reg),
        .serve_branch_reg(serve_branch_reg),
        .incoming_serve_valid(incoming_serve_valid),
        .serve_consumed(serve_consumed),
        .decoder_packet(decoder_packet),
        .issuer_packet(issuer_packet),
        .accept_vector(accept_vector)
    );

endmodule
