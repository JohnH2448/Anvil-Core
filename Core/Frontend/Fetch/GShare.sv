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

    // Early PHT read (see below), from the Queue.
    input DerivedParameters::fetch_pc_t lookup_pc [FETCH_WORDS*2-1:0],
    input logic lookup_capture,  // the arriving window enters staging
    input logic partial_capture, // the staging window transfers leaving a partial
    input logic use_partial,     // slot 0 of the staging window is that partial

    // Training Data (registered in BackendTop; valid fires once per resolved
    // conditional branch)
    input logic train_valid [BRU_LANE_COUNT-1:0],
    input logic train_taken [BRU_LANE_COUNT-1:0],
    input logic [AGE_WIDTH-1:0] train_age [BRU_LANE_COUNT-1:0],
    input logic [$clog2(GSHARE_PHT_DEPTH)-1:0] train_pht [BRU_LANE_COUNT-1:0]
);

    // Register Definitions
    logic [GSHARE_GHR_DEPTH-1:0] ghr;
    // Distributed (LUT) RAM: one write port per cycle, asynchronous reads
    // (synthesis replicates it per read port). No reset: it starts weakly
    // not-taken from its initial value, which only affects warm-up.
    (* ram_style = "distributed" *) logic [1:0] pht [GSHARE_PHT_DEPTH-1:0];
    initial for (int unsigned i = 0; i < GSHARE_PHT_DEPTH; i++) pht[i] = 2'b01;

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

    // Early PHT read (timing). The table is read one cycle before the window is
    // predicted, from the address of the window whose data is arriving
    // (lookup_pc[i] = that address + 2i), and the index and counter MSB are
    // registered with the data (lookup_capture = Queue fetch_accept). The
    // staging cycle then sees only flops for the direction, not the index XOR
    // and the PHT read mux. A slot-0 partial (32-bit instruction continued
    // from the previous window) has the PC of that window's last slot, so its
    // early read is captured when that window transfers (partial_capture).
    // The history is one cycle older than at the staging cycle; the GHR is
    // already updated at resolution, so this only adds one cycle of lag.
    logic [PHT_W-1:0] history;
    assign history = fold_ghr(ghr);
    logic [PHT_W-1:0] early_index [FETCH_WORDS*2];
    logic early_taken [FETCH_WORDS*2];
    logic [PHT_W-1:0] partial_index;
    logic partial_taken;
    always_ff @(posedge clk) begin
        if (lookup_capture)
            for (int unsigned i = 0; i < FETCH_WORDS*2; i++) begin
                early_index[i] <= PHT_W'(lookup_pc[i][PHT_W:1]) ^ history;
                early_taken[i] <= pht[PHT_W'(lookup_pc[i][PHT_W:1]) ^ history][1];
            end
        if (partial_capture) begin
            partial_index <= early_index[FETCH_WORDS*2-1];
            partial_taken <= early_taken[FETCH_WORDS*2-1];
        end
    end

    always_comb begin
        logic jump, counter_taken;
        for (int unsigned i = 0; i < FETCH_WORDS*2; i++) begin
            if (i == 0 && use_partial) begin
                branch_pht_index[i] = partial_index;
                counter_taken = partial_taken;
            end else begin
                branch_pht_index[i] = early_index[i];
                counter_taken = early_taken[i];
            end
            // JAL is opcode bit 3; C.J/C.JAL have funct3[2] (bit 14) clear.
            jump = branch_input[i].bp_compressed ? !branch_input[i].bp_instruction[14]
                                                 : branch_input[i].bp_instruction[3];
            branch_output[i].bp_redirect_pc = target_pc[i];
            branch_output[i].bp_target_wrapped = target_wrapped[i];
            branch_output[i].bp_valid = branch_input[i].bp_branch;
            branch_output[i].bp_taken = branch_input[i].bp_branch && (jump || counter_taken);
        end
    end

    // Registered Reset
    logic reset_reg;
    always_ff @(posedge clk) begin
        reset_reg <= reset;
    end

    // PHT Writes. Stage A selects the training lanes and reads their old
    // counters into flops; stage B computes the saturated values. The PHT is
    // LUT RAM, so it takes ONE write per cycle: updates go through a short
    // write queue (WQ) in age order and the oldest is written each cycle. A
    // stage-A read takes the newest pending value of its entry (queue, then
    // stage B), so no update is lost to the queue. If more than WQ updates are
    // waiting the newest are dropped (a training hint, never a correctness
    // issue). Same-cycle lanes on one entry: the higher lane is newer.
    localparam int unsigned WQ = 2;
    logic a_valid [BRU_LANE_COUNT], a_taken [BRU_LANE_COUNT];
    logic [PHT_W-1:0] a_index [BRU_LANE_COUNT];
    logic [1:0] a_old [BRU_LANE_COUNT], b_new [BRU_LANE_COUNT];
    logic wq_valid [WQ];
    logic [PHT_W-1:0] wq_index [WQ];
    logic [1:0] wq_value [WQ];
    always_comb
        for (int unsigned j = 0; j < BRU_LANE_COUNT; j++)
            b_new[j] = a_taken[j] ? (a_old[j] == 2'b11 ? 2'b11 : a_old[j] + 2'd1)
                                  : (a_old[j] == 2'b00 ? 2'b00 : a_old[j] - 2'd1);
    int unsigned oldest_index;
    always_comb begin
        logic oldest_valid;
        oldest_index = 0;
        oldest_valid = 1'b0;
        for (int unsigned i = 0; i < BRU_LANE_COUNT; i++)
            if (train_valid[i] && (!oldest_valid || train_age[i] < train_age[oldest_index])) begin
                oldest_index = i;
                oldest_valid = 1'b1;
            end
    end
    for (genvar i = 0; i < BRU_LANE_COUNT; i++) begin : train_stage_a
        logic [1:0] old;
        always_comb begin
            old = pht[train_pht[i]];
            for (int unsigned q = 0; q < WQ; q++)
                if (wq_valid[q] && wq_index[q] == train_pht[i]) old = wq_value[q];
            for (int unsigned j = 0; j < BRU_LANE_COUNT; j++)
                if (a_valid[j] && a_index[j] == train_pht[i]) old = b_new[j];
        end
        always_ff @(posedge clk) begin
            a_valid[i] <= !reset_reg && train_valid[i] && (TRAIN_SQUASHED_BRANCHES || i == oldest_index);
            a_taken[i] <= train_taken[i];
            a_index[i] <= train_pht[i];
            a_old[i] <= old;
        end
    end
    // Pending updates oldest first: the queue, then this cycle's stage B lanes.
    localparam int unsigned CANDIDATES = WQ + BRU_LANE_COUNT;
    logic c_valid [CANDIDATES];
    logic [PHT_W-1:0] c_index [CANDIDATES];
    logic [1:0] c_value [CANDIDATES];
    always_comb begin
        for (int unsigned q = 0; q < WQ; q++) begin
            c_valid[q] = wq_valid[q];
            c_index[q] = wq_index[q];
            c_value[q] = wq_value[q];
        end
        for (int unsigned j = 0; j < BRU_LANE_COUNT; j++) begin
            c_valid[WQ + j] = a_valid[j];
            c_index[WQ + j] = a_index[j];
            c_value[WQ + j] = b_new[j];
        end
    end
    // Write the oldest pending update; the next WQ wait in the queue.
    logic write_valid;
    logic [PHT_W-1:0] write_index;
    logic [1:0] write_value;
    logic next_valid [WQ];
    logic [PHT_W-1:0] next_index [WQ];
    logic [1:0] next_value [WQ];
    always_comb begin
        int unsigned taken;
        write_valid = 1'b0;
        write_index = 'x;
        write_value = 'x;
        for (int unsigned q = 0; q < WQ; q++) begin
            next_valid[q] = 1'b0;
            next_index[q] = 'x;
            next_value[q] = 'x;
        end
        taken = 0;
        for (int unsigned c = 0; c < CANDIDATES; c++) begin
            if (c_valid[c]) begin
                if (!write_valid) begin
                    write_valid = 1'b1;
                    write_index = c_index[c];
                    write_value = c_value[c];
                end else if (taken < WQ) begin
                    next_valid[taken] = 1'b1;
                    next_index[taken] = c_index[c];
                    next_value[taken] = c_value[c];
                    taken++;
                end
            end
        end
    end
    for (genvar q = 0; q < WQ; q++) begin : write_queue
        always_ff @(posedge clk) begin
            wq_valid[q] <= !reset_reg && next_valid[q];
            wq_index[q] <= next_index[q];
            wq_value[q] <= next_value[q];
        end
    end
    always_ff @(posedge clk)
        if (write_valid) pht[write_index] <= write_value;

    // GHT Writes
    if (TRAIN_SQUASHED_BRANCHES) begin : ghr_all
        // Every trained branch shifts in, oldest first, so the history follows
        // program order regardless of how branches paired at resolution.
        // Ages are distinct within a cycle; one pass per age keeps it a small
        // fixed mux chain on a register that is off the prediction path.
        always_ff @(posedge clk) begin
            logic [GSHARE_GHR_DEPTH-1:0] next;
            next = ghr;
            for (int unsigned age = 0; age < 2**AGE_WIDTH; age++)
                for (int unsigned i = 0; i < BRU_LANE_COUNT; i++)
                    if (train_valid[i] && train_age[i] == AGE_WIDTH'(age))
                        next = {next[GSHARE_GHR_DEPTH-2:0], train_taken[i]};
            ghr <= next;
        end
    end else begin : ghr_oldest
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
    end

endmodule
