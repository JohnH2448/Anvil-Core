module GShare 
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned FETCH_WORDS,
    parameter unsigned GSHARE_GHR_DEPTH = Parameters::GSHARE_GHR_DEPTH,
    parameter unsigned GSHARE_PHT_DEPTH = Parameters::GSHARE_PHT_DEPTH,
    parameter unsigned TRAIN_SQUASHED_BRANCHES = Parameters::TRAIN_SQUASHED_BRANCHES
)(
    // Standard Inputs
    input logic clk,
    input logic reset,

    // Preditiction Handshake (potential optimization here not to pass every pc, since information density is high)
    input Definitions::BranchInput_ branch_input [FETCH_WORDS*2-1:0],
    output Definitions::BranchOutput_ branch_output [FETCH_WORDS*2-1:0],
    output logic [$clog2(GSHARE_PHT_DEPTH)-1:0] branch_pht_index [FETCH_WORDS*2-1:0],

    // Training Data (registered in BackendTop; valid fires once per resolved
    // conditional branch)
    input logic train_valid [BRU_LANE_COUNT-1:0],
    input logic train_taken [BRU_LANE_COUNT-1:0],
    input logic [AGE_WIDTH-1:0] train_age [BRU_LANE_COUNT-1:0],
    input logic [$clog2(GSHARE_PHT_DEPTH)-1:0] train_pht [BRU_LANE_COUNT-1:0]
);

    // Register Definitions
    logic [GSHARE_GHR_DEPTH-1:0] ghr;
    logic [1:0] pht [GSHARE_PHT_DEPTH-1:0];

    localparam int unsigned PHT_W = $unsigned($clog2(GSHARE_PHT_DEPTH));

    // GSHARE_PHT_DEPTH is an entry count. The index is $clog2 of it, so it must
    // be a power of two (an index can never point past the table) and at least
    // 2 (a nonzero index width).
    if (GSHARE_PHT_DEPTH < 2 || (GSHARE_PHT_DEPTH & (GSHARE_PHT_DEPTH - 1)) != 0) begin : bad_pht_depth
        $fatal(1, "GShare: GSHARE_PHT_DEPTH (%0d) must be a power of two >= 2", GSHARE_PHT_DEPTH);
    end

    function automatic logic [PHT_W-1:0] fold_ghr(input logic [GSHARE_GHR_DEPTH-1:0] history);
        fold_ghr = '0;
        for (int unsigned b = 0; b < GSHARE_GHR_DEPTH; b++)
            fold_ghr[b % PHT_W] ^= history[b];
    endfunction

    // Target decode only (shared with the static predictor, no direction logic).
    DerivedParameters::fetch_pc_t target_pc [FETCH_WORDS*2-1:0];
    logic target_wrapped [FETCH_WORDS*2-1:0];
    for (genvar i = 0; i < FETCH_WORDS*2; i++) begin : targets
        BranchTarget target (
            .branch_input(branch_input[i]),
            .redirect_pc(target_pc[i]),
            .target_wrapped(target_wrapped[i])
        );
    end

    // The folded history is a function of the GHR flop only, so it is off the
    // per-slot path; each slot adds one XOR level and the PHT read mux.
    logic [PHT_W-1:0] history;
    assign history = fold_ghr(ghr);
    always_comb begin
        logic jump;
        for (int unsigned i = 0; i < FETCH_WORDS*2; i++) begin
            branch_pht_index[i] = PHT_W'(branch_input[i].bp_pc[PHT_W:1]) ^ history;
            // JAL is opcode bit 3; C.J/C.JAL have funct3[2] (bit 14) clear.
            jump = branch_input[i].bp_compressed ? !branch_input[i].bp_instruction[14]
                                                 : branch_input[i].bp_instruction[3];
            branch_output[i].bp_redirect_pc = target_pc[i];
            branch_output[i].bp_target_wrapped = target_wrapped[i];
            branch_output[i].bp_valid = branch_input[i].bp_branch;
            branch_output[i].bp_taken = branch_input[i].bp_branch &&
                (jump || pht[branch_pht_index[i]][1]);
        end
    end

    // Registered Reset
    logic reset_reg;
    always_ff @(posedge clk) begin
        reset_reg <= reset;
    end

    // PHT Writes
    always_ff @(posedge clk) begin
        if (reset_reg) begin
            // Reset Mostly For Dhrystone Performance, Doesnt Really Matter
            // Whole-array assignment: Verilator rejects NBAs to array elements in for loops.
            pht <= '{default: 2'b01};
        end else begin
            if (TRAIN_SQUASHED_BRANCHES) begin
                for (int unsigned i = 0; i < BRU_LANE_COUNT; i++) begin
                    if (train_valid[i]) begin
                        if (train_taken[i]) begin
                            if (pht[train_pht[i]] != 2'b11) begin
                                pht[train_pht[i]] <= pht[train_pht[i]] + 1;
                            end
                        end else begin
                            if (pht[train_pht[i]] != 2'b00) begin
                                pht[train_pht[i]] <= pht[train_pht[i]] - 1;
                            end
                        end
                    end
                end
            end else begin
                int unsigned oldest_index;
                logic oldest_valid;
                oldest_index = '0;
                oldest_valid = 1'b0;
                for (int unsigned i = 0; i < BRU_LANE_COUNT; i++) begin
                    if (train_valid[i] &&
                        (!oldest_valid || train_age[i] < train_age[oldest_index])) begin
                        oldest_index = i;
                        oldest_valid = 1'b1;
                    end
                end
                if (train_valid[oldest_index]) begin
                    if (train_taken[oldest_index]) begin
                        if (pht[train_pht[oldest_index]] != 2'b11) begin
                            pht[train_pht[oldest_index]] <= pht[train_pht[oldest_index]] + 1;
                        end
                    end else begin
                        if (pht[train_pht[oldest_index]] != 2'b00) begin
                            pht[train_pht[oldest_index]] <= pht[train_pht[oldest_index]] - 1;
                        end
                    end
                end
            end
        end
    end

    // GHT Writes
    always_ff @(posedge clk) begin
        int unsigned oldest_index;
        logic oldest_valid;
        oldest_index = '0;
        oldest_valid = 1'b0;
        for (int unsigned i = 0; i < BRU_LANE_COUNT; i++) begin
            if (train_valid[i] &&
                (!oldest_valid || train_age[i] < train_age[oldest_index])) begin
                oldest_index = i;
                oldest_valid = 1'b1;
            end
        end
        if (train_valid[oldest_index]) begin
            ghr <= {ghr[GSHARE_GHR_DEPTH-2:0], train_taken[oldest_index]};
        end else begin
            ghr <= ghr;
        end
    end

endmodule
