module CoreTop
    import Parameters::*;
    import DerivedParameters::*;
    import Definitions::*;
(
    input logic clk, reset,

    // Instruction fetch port to the shared RAM (via the system Crossbar).
    // One request per cycle, response next cycle; fetch_valid low = not served.
    output logic fetch_request,
    output logic [31:0] fetch_address,
    input logic [FETCH_WORDS*32-1:0] fetch_data,
    input logic fetch_valid,

    // Interrupt sources from outside the core. timer_pending/software_pending
    // are the CLINT levels behind mip.MTIP/mip.MSIP; an INT_EXTERNAL pulse on
    // interrupt/interrupt_type sets the sticky mip.MEIP.
    input logic timer_pending, software_pending,
    input logic interrupt,
    input Enumerations::InterruptType_ interrupt_type,
    // CLINT mtime, read by the time/timeh CSRs.
    input logic [63:0] time_value,

    // Ordered integer data-memory bus. Stores also receive a response. No
    // errors: memory traps are detected in the AGU.
    output logic request_valid, request_write,
    output logic [31:0] request_address, request_data,
    output logic [3:0] request_mask,
    output logic [1:0] request_size, // MemorySize_
    input logic request_ready,
    input logic response_valid,
    input logic [31:0] response_data,
    output logic response_ready
);
    DecoderPacket_ decoder_packet [TOTAL_LANE_COUNT-1:0];
    IssuerPacket_ issuer_packet [TOTAL_LANE_COUNT-1:0];
    logic accept_vector [TOTAL_LANE_COUNT-1:0];
    logic watch [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0];
    logic stall, redirect_fetch, redirect_taken;
    logic [AGE_WIDTH-1:0] redirect_slot;
    logic redirect_advanced, redirect_trap;
    logic [31:0] redirect_pc;
    Enumerations::TrapType_ interrupt_request;
    // GShare training: BackendTop flops straight into the predictor.
    logic train_valid [BRU_LANE_COUNT-1:0], train_taken [BRU_LANE_COUNT-1:0];
    logic [AGE_WIDTH-1:0] train_age [BRU_LANE_COUNT-1:0];
    logic [PHT_INDEX_W-1:0] train_pht [BRU_LANE_COUNT-1:0];
    logic [RAS_RESTORE_W-1:0] redirect_ras; // RAS repair, with the registered redirect

    FrontendTop frontend (
        .clk, .reset,
        .fetch_request, .fetch_address, .fetch_data, .fetch_valid, .stall,
        .redirect_fetch, .redirect_taken, .redirect_pc, .redirect_slot, .redirect_advanced, .redirect_trap, .interrupt_request,
        .serial_active(1'b0),
        .train_valid, .train_taken, .train_age, .train_pht, .redirect_ras,
        .decoder_packet, .issuer_packet, .accept_vector, .watch
    );

    BackendTop backend (
        .clk, .reset, .external_stall(1'b0), .stall,
        .decoder_packet, .issuer_packet, .accept_vector, .watch,
        .redirect_fetch, .redirect_taken, .redirect_pc, .redirect_slot, .redirect_advanced, .redirect_trap, .result_trap(), .trap(),
        .train_valid, .train_taken, .train_age, .train_pht, .redirect_ras,
        .interrupt, .interrupt_type, .interrupt_request, .time_value, .timer_pending, .software_pending,
        .request_valid, .request_write, .request_address, .request_data,
        .request_mask, .request_size, .request_ready, .response_valid,
        .response_data, .response_ready
    );
endmodule

// redirect needs to hit the first staging reg and pc first, then next
// cycle everything else works off the latched bit