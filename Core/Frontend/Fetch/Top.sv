module FetchTop
    import Parameters::*;
    import DerivedParameters::*;
    import Enumerations::*;
(

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
    output fetch_pc_t serve_pc_reg [ISSUE_WIDTH-1:0],
    output logic serve_valid_reg [ISSUE_WIDTH-1:0],
    output logic serve_c_reg [ISSUE_WIDTH-1:0],
    output logic serve_taken_reg [ISSUE_WIDTH-1:0],
    output logic serve_branch_reg [ISSUE_WIDTH-1:0],
    output logic [PHT_INDEX_W-1:0] serve_pht_reg [ISSUE_WIDTH-1:0],
    output logic [RAS_TARGET_W-1:0] serve_ras_reg [ISSUE_WIDTH-1:0],
    output logic [RAS_SNAP_W-1:0] serve_snap_reg [ISSUE_WIDTH-1:0],
    // RAS repair: {enable, pop, snapshot} with the registered branch redirect.
    input logic [RAS_RESTORE_W-1:0] redirect_ras,

    // GShare training (registered, fires once per resolved conditional branch).
    // Unused when ENABLE_GSHARE = 0.
    input logic train_valid [BRU_LANE_COUNT-1:0],
    input logic train_taken [BRU_LANE_COUNT-1:0],
    input logic [AGE_WIDTH-1:0] train_age [BRU_LANE_COUNT-1:0],
    input logic [PHT_INDEX_W-1:0] train_pht [BRU_LANE_COUNT-1:0],

    // Consumption from Decode Stage
    input logic stall,
    input logic [$clog2(ISSUE_WIDTH+1)-1:0] serve_normal_count
);

    Definitions::BranchInput_ branch_input [FETCH_WORDS*2-1:0];
    Definitions::BranchOutput_ branch_output [FETCH_WORDS*2-1:0]; // to the Queue (after the RAS override)
    Definitions::BranchOutput_ raw_output [FETCH_WORDS*2-1:0];    // direction predictor
    logic ras_commit;
    fetch_pc_t early_lookup_pc [FETCH_WORDS*2-1:0];
    logic early_lookup_capture, early_partial_capture, early_use_partial;
    logic ras_stage_transfer, ras_prediction_valid;
    logic ras_stage_keep [FETCH_WORDS*2-1:0];
    logic [RAS_SNAP_W-1:0] ras_snapshot;
    fetch_pc_t ras_top; // RAS top for return-kind BTB steers
    Definitions::BranchInput_ ras_commit_payload [FETCH_WORDS*2-1:0];
    logic ras_commit_keep [FETCH_WORDS*2-1:0], ras_commit_taken [FETCH_WORDS*2-1:0];
    logic [PHT_INDEX_W-1:0] branch_pht_index [FETCH_WORDS*2-1:0];
    logic [31:0] req_address;
    logic req_valid;
    logic req_ready;
    assign fetch_request = req_valid;
    assign fetch_address = req_address;

    Queue queue (
        .clk(clk),
        .flush(1'b0), // Reserved queue interface; redirects perform the active flush.
        .reset(reset),
        .ras_top(ras_top),

        .redirect_fetch(redirect_fetch),
        .redirect_pc(redirect_pc),
        .redirect_taken(redirect_taken),

        .req_address(req_address),
        .req_valid(req_valid),
        .req_ready(req_ready),

        .fetch_data(fetch_data),
        .fetch_valid(fetch_valid),

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
        .serve_ras_reg(serve_ras_reg),
        .serve_snap_reg(serve_snap_reg),
        .ras_snapshot,
        .ras_commit, .ras_commit_payload, .ras_commit_keep, .ras_commit_taken,
        .early_lookup_pc, .early_lookup_capture, .early_partial_capture, .early_use_partial,
        .ras_stage_transfer, .ras_prediction_valid, .ras_stage_keep,

        .branch_input(branch_input),
        .branch_output(branch_output),
        .branch_pht_index(branch_pht_index),

        .stall(stall),
        .serve_normal_count(serve_normal_count)
    );

    // Direction predictor: GShare, or the static BTFNT per slot. The PHT index
    // is a constant zero without GShare, so its carried bit is removed.
    if (ENABLE_GSHARE) begin : gshare_predictor
        GShare gshare (
            .clk(clk),
            .reset(reset),
            .branch_input(branch_input),
            .branch_output(raw_output),
            .branch_pht_index(branch_pht_index),
            .lookup_pc(early_lookup_pc),
            .lookup_capture(early_lookup_capture),
            .partial_capture(early_partial_capture),
            .use_partial(early_use_partial),
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
                .branch_output(raw_output[i])
            );
            assign branch_pht_index[i] = '0;
        end
    end

    // Return address stack: overrides the direction predictor for JALR-class
    // slots. A return predicts taken to the top of stack (a flop) when the
    // stack is not empty; any other JALR predicts not taken. One 2:1 select
    // after the predictor, in parallel decode from the staging data.
    if (ENABLE_RAS) begin : return_stack
        logic slot_jalr [FETCH_WORDS*2-1:0], slot_return [FETCH_WORDS*2-1:0];
        logic top_valid;
        fetch_pc_t top;
        RAS ras (
            .clk(clk),
            .reset(reset),
            .redirect_taken(redirect_taken),
            .branch_input(branch_input),
            .slot_jalr(slot_jalr),
            .slot_return(slot_return),
            .top_valid(top_valid),
            .top(top),
            .commit(ras_commit),
            .commit_payload(ras_commit_payload),
            .commit_keep(ras_commit_keep),
            .commit_taken(ras_commit_taken),
            .stage_transfer(ras_stage_transfer),
            .stage_keep(ras_stage_keep),
            .prediction_valid(ras_prediction_valid),
            .snapshot(ras_snapshot),
            .restore(redirect_ras)
        );
        assign ras_top = top;
        always_comb begin
            for (int unsigned i = 0; i < FETCH_WORDS*2; i++) begin
                branch_output[i] = raw_output[i];
                if (slot_jalr[i]) begin
                    branch_output[i].bp_taken = branch_input[i].bp_branch && slot_return[i] && top_valid;
                    branch_output[i].bp_redirect_pc = top;
                    branch_output[i].bp_target_wrapped = 1'b0; // a pushed return address is in range
                end
            end
        end
    end else begin : no_return_stack
        assign branch_output = raw_output;
        assign ras_snapshot = '0;
        assign ras_top = '0;
    end


endmodule
