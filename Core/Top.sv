module CoreTop
    import DerivedParameters::*;
    import Definitions::*;
#(
    parameter unsigned IMEM_DEPTH_WORDS = 512,
    parameter IMEM_HEX_FILE = "Core/Frontend/Fetch/program.hex"
)(
    input logic clk, reset,

    // Ordered integer data-memory bus. Stores also receive a response.
    output logic request_valid, request_write,
    output logic [31:0] request_address, request_data,
    output logic [3:0] request_mask,
    input logic request_ready,
    input logic response_valid, response_error,
    input logic [31:0] response_data,
    output logic response_ready
);
    DecoderPacket_ decoder_packet [TOTAL_LANE_COUNT-1:0];
    IssuerPacket_ issuer_packet [TOTAL_LANE_COUNT-1:0];
    logic accept_vector [TOTAL_LANE_COUNT-1:0];
    logic watch [TOTAL_LANE_COUNT-1:0][Parameters::EXECUTION_UNROLL:0];
    logic stall, redirect_fetch, redirect_taken;
    logic [AGE_WIDTH-1:0] redirect_slot;
    logic redirect_advanced;
    logic [31:0] redirect_pc;

    FrontendTop #(
        .IMEM_DEPTH_WORDS(IMEM_DEPTH_WORDS),
        .IMEM_HEX_FILE(IMEM_HEX_FILE)
    ) frontend (
        .clk, .reset, .stall,
        .redirect_fetch, .redirect_taken, .redirect_pc, .redirect_slot, .redirect_advanced,
        .serial_active(1'b0),
        .decoder_packet, .issuer_packet, .accept_vector, .watch
    );

    BackendTop backend (
        .clk, .reset, .external_stall(1'b0), .stall,
        .decoder_packet, .issuer_packet, .accept_vector, .watch,
        .redirect_fetch, .redirect_taken, .redirect_pc, .redirect_slot, .redirect_advanced, .result_trap(),
        .request_valid, .request_write, .request_address, .request_data,
        .request_mask, .request_ready, .response_valid, .response_error,
        .response_data, .response_ready
    );
endmodule

// redirect needs to hit the first staging reg and pc first, then next
// cycle everything else works off the latched bit