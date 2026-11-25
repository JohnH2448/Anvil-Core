module FetchTop
    import Enumerations::*;
#(
    parameter unsigned FETCH_WORDS = 2,
    parameter unsigned SUPPORT_MUL = Parameters::SUPPORT_MUL,
    parameter unsigned SUPPORT_DIV = Parameters::SUPPORT_DIV,
    parameter unsigned SUPPORT_FLOAT = Parameters::SUPPORT_FLOAT,
    parameter unsigned SUPPORT_ATOMIC = Parameters::SUPPORT_ATOMIC,
    parameter unsigned FIFO_WORDS = 8,
    parameter unsigned ISSUE_WIDTH = 2,
    parameter unsigned RESET_VECTOR = 32'h0000_0000,
    parameter unsigned USE_GSHARE = Parameters::USE_GSHARE
)(

    // Standard Inputs
    input logic clk,
    input logic reset,

    // Instruction fetch port to the shared RAM (via the system Crossbar).
    // One request per cycle; the response arrives the next cycle. A cycle
    // with fetch_valid low means the request was not served and Fetch
    // re-requests the same address.
    output logic fetch_request,
    output logic [31:0] fetch_address,
    input logic [FETCH_WORDS*32-1:0] fetch_data,
    input logic fetch_valid,
    input logic fetch_error,

    // Redirect Inputs
    input logic [31:0] redirect_pc,
    input logic redirect_fetch, // Registered recovery launch; pulses with redirect_taken.
    input logic redirect_taken, // Registered recovery pulse.

    // Output to Decode Stage
    output logic [31:0] serve_data_reg [ISSUE_WIDTH-1:0],
    output logic [4:0] serve_rs1 [ISSUE_WIDTH-1:0],
    output logic [4:0] serve_rs2 [ISSUE_WIDTH-1:0],
    output logic [4:0] serve_rd [ISSUE_WIDTH-1:0],
    output logic [4:0] serve_rs3 [ISSUE_WIDTH-1:0],
    output logic serve_rs1_float [ISSUE_WIDTH-1:0],
    output logic serve_rs2_float [ISSUE_WIDTH-1:0],
    output logic serve_rs3_float [ISSUE_WIDTH-1:0],
    output logic serve_rd_float [ISSUE_WIDTH-1:0],
    output logic serve_rs1_used [ISSUE_WIDTH-1:0],
    output logic serve_rs2_used [ISSUE_WIDTH-1:0],
    output logic serve_rd_written [ISSUE_WIDTH-1:0],
    output logic [$bits(DecodeCapability_)-1:0] serve_capability [ISSUE_WIDTH-1:0],
    output logic [6:0] serve_immediate_upper_select [ISSUE_WIDTH-1:0],
    output logic serve_fp_consumer [ISSUE_WIDTH-1:0],
    output TrapType_ serve_trap [ISSUE_WIDTH-1:0],
    output DerivedParameters::fetch_pc_t serve_pc_reg [ISSUE_WIDTH-1:0],
    output logic serve_valid_reg [ISSUE_WIDTH-1:0],
    output logic serve_c_reg [ISSUE_WIDTH-1:0],
    output logic serve_taken_reg [ISSUE_WIDTH-1:0],
    output logic serve_branch_reg [ISSUE_WIDTH-1:0],
    output logic [DerivedParameters::PHT_INDEX_W-1:0] serve_pht_reg [ISSUE_WIDTH-1:0],

    // GShare training (registered, fires once per resolved conditional branch).
    // Unused when USE_GSHARE = 0.
    input logic train_valid [DerivedParameters::BRU_LANE_COUNT-1:0],
    input logic train_taken [DerivedParameters::BRU_LANE_COUNT-1:0],
    input logic [DerivedParameters::AGE_WIDTH-1:0] train_age [DerivedParameters::BRU_LANE_COUNT-1:0],
    input logic [DerivedParameters::PHT_INDEX_W-1:0] train_pht [DerivedParameters::BRU_LANE_COUNT-1:0],

    // Consumption from Decode Stage
    input logic stall,
    input logic [$clog2(ISSUE_WIDTH+1)-1:0] serve_normal_count
);

    Definitions::BranchInput_ branch_input [FETCH_WORDS*2-1:0];
    Definitions::BranchOutput_ branch_output [FETCH_WORDS*2-1:0];
    logic [DerivedParameters::PHT_INDEX_W-1:0] branch_pht_index [FETCH_WORDS*2-1:0];
    logic [31:0] req_address;
    logic req_valid;
    logic req_ready;
    assign fetch_request = req_valid;
    assign fetch_address = req_address;

    Queue #(
        .FETCH_WORDS(FETCH_WORDS),
        .SUPPORT_MUL(SUPPORT_MUL),
        .SUPPORT_DIV(SUPPORT_DIV),
        .SUPPORT_FLOAT(SUPPORT_FLOAT),
        .SUPPORT_ATOMIC(SUPPORT_ATOMIC),
        .FIFO_WORDS(FIFO_WORDS),
        .SERVE_WORDS(ISSUE_WIDTH),
        .RESET_VECTOR(RESET_VECTOR)
    ) queue (
        .clk(clk),
        .flush(1'b0), // Reserved queue interface; redirects perform the active flush.
        .reset(reset),

        .redirect_fetch(redirect_fetch),
        .redirect_pc(redirect_pc),
        .redirect_taken(redirect_taken),

        .req_address(req_address),
        .req_valid(req_valid),
        .req_ready(req_ready),

        .fetch_data(fetch_data),
        .fetch_valid(fetch_valid),
        .fetch_error(fetch_error),

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
        .serve_fp_consumer(serve_fp_consumer),
        .serve_trap(serve_trap),
        .serve_pc_reg(serve_pc_reg),
        .serve_valid_reg(serve_valid_reg),
        .serve_c_reg(serve_c_reg),
        .serve_taken_reg(serve_taken_reg),
        .serve_branch_reg(serve_branch_reg),
        .serve_pht_reg(serve_pht_reg),

        .branch_input(branch_input),
        .branch_output(branch_output),
        .branch_pht_index(branch_pht_index),

        .stall(stall),
        .serve_normal_count(serve_normal_count)
    );

    // Direction predictor: GShare, or the static BTFNT per slot. The PHT index
    // is a constant zero without GShare, so its carried bit is removed.
    if (USE_GSHARE) begin : gshare_predictor
        GShare #(.FETCH_WORDS(FETCH_WORDS)) gshare (
            .clk(clk),
            .reset(reset),
            .branch_input(branch_input),
            .branch_output(branch_output),
            .branch_pht_index(branch_pht_index),
            .train_valid(train_valid),
            .train_taken(train_taken),
            .train_age(train_age),
            .train_pht(train_pht)
        );
    end else begin : static_predictors
        for (genvar i = 0; i < FETCH_WORDS*2; i++) begin : predictors
            Predictor predictor (
                .clk(clk),
                .reset(reset),
                .branch_input(branch_input[i]),
                .branch_output(branch_output[i])
            );
            assign branch_pht_index[i] = '0;
        end
    end


endmodule
