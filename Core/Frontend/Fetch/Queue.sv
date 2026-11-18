module Queue
    import Definitions::*;
    import Enumerations::*;
#(
    parameter unsigned FETCH_WORDS = 2,
    parameter unsigned SUPPORT_MUL = Parameters::SUPPORT_MUL,
    parameter unsigned SUPPORT_DIV = Parameters::SUPPORT_DIV,
    parameter unsigned SUPPORT_FLOAT = Parameters::SUPPORT_FLOAT,
    parameter unsigned SUPPORT_ATOMIC = Parameters::SUPPORT_ATOMIC,
    parameter unsigned FIFO_WORDS = 8,
    parameter unsigned SERVE_WORDS = 2,
    parameter unsigned RESET_VECTOR = 32'h0000_0000
)(

    // Standard Inputs
    input logic clk,
    input logic reset,
    input logic flush,

    // Redirect Inputs
    input logic [31:0] redirect_pc,
    input logic redirect_taken,

    // Memory Request
    output logic [31:0] req_address,
    output logic req_valid,
    output logic req_ready,

    // Memory Response
    input logic [FETCH_WORDS*32-1:0] fetch_data,
    input logic fetch_valid,
    input logic fetch_error,

    // Linear Instruction Outputs
    output logic [31:0] serve_data_reg [SERVE_WORDS-1:0],
    output logic [4:0] serve_rs1 [SERVE_WORDS-1:0],
    output logic [4:0] serve_rs2 [SERVE_WORDS-1:0],
    output logic [4:0] serve_rd [SERVE_WORDS-1:0],
    output logic [4:0] serve_rs3 [SERVE_WORDS-1:0],
    output logic serve_rs1_float [SERVE_WORDS-1:0],
    output logic serve_rs2_float [SERVE_WORDS-1:0],
    output logic serve_rs3_float [SERVE_WORDS-1:0],
    output logic serve_rd_float [SERVE_WORDS-1:0],
    output logic serve_rs1_used [SERVE_WORDS-1:0],
    output logic serve_rs2_used [SERVE_WORDS-1:0],
    output logic serve_rd_written [SERVE_WORDS-1:0],
    output logic [$bits(DecodeCapability_)-1:0] serve_capability [SERVE_WORDS-1:0],
    output logic [13:0] serve_immediate_upper_select [SERVE_WORDS-1:0],
    output logic [4:0] serve_immediate_low [SERVE_WORDS-1:0],
    output logic [$bits(BranchOperation_)-1:0] serve_branch_operation [SERVE_WORDS-1:0],
    output logic serve_fp_consumer [SERVE_WORDS-1:0],
    output TrapType_ serve_trap [SERVE_WORDS-1:0],
    output DerivedParameters::fetch_pc_t serve_pc_reg [SERVE_WORDS-1:0],
    output logic serve_valid_reg [SERVE_WORDS-1:0],
    output logic serve_c_reg [SERVE_WORDS-1:0],
    output logic serve_taken_reg [SERVE_WORDS-1:0],
    output logic serve_branch_reg [SERVE_WORDS-1:0],

    // Branch Preditor Communication
    output BranchInput_ branch_input [FETCH_WORDS*2-1:0],
    input BranchOutput_ branch_output [FETCH_WORDS*2-1:0],

    // Number of consecutive serve lanes consumed, starting at lane zero
    input logic [$clog2(SERVE_WORDS+1)-1:0] serve_consumed,
    input logic [$clog2(SERVE_WORDS+1)-1:0] serve_select_count
);

    // Do not rely on redirect propagating through upstream consumption logic.
    logic [$clog2(SERVE_WORDS+1)-1:0] serve_consumed_active;
    assign serve_consumed_active = redirect_taken ? '0 : serve_consumed;

    // Derived Constants
    localparam unsigned FETCH_SLOTS = FETCH_WORDS * 2;
    localparam unsigned FIFO_INDEX_W = $clog2(FIFO_WORDS);
    localparam unsigned PUSH_COUNT_W = $clog2(FETCH_SLOTS + 1);
    localparam unsigned SERVE_COUNT_W = $clog2(SERVE_WORDS + 1);

    // FIFO Power of Two Check
    if (!(FIFO_WORDS > 0 && (FIFO_WORDS & (FIFO_WORDS - 1)) == 0)) begin : invalid_fifo_words
        initial $error("FIFO_WORDS must be a power of 2");
    end

    // Identifies 32-Bit Word Branches
    function automatic logic is_branch32(input logic [15:0] low_half);
        is_branch32 = (low_half[6:0] == 7'b1100011) ||
            (low_half[6:0] == 7'b1101111);
    endfunction

    // Identifies 16-Bit Word Branches
    function automatic logic is_branch16(input logic [15:0] half_word);
        is_branch16 = (half_word[1:0] == 2'b01) &&
            ((half_word[15:13] == 3'b101) ||
             (half_word[15:13] == 3'b001) ||
             (half_word[15:13] == 3'b110) ||
             (half_word[15:13] == 3'b111));
    endfunction

    // Calculates Cannonical Next PC Delta from Instruction Data
    function automatic logic [31:0] pc_step(
        input logic [31:0] instruction, input logic compressed, input logic taken);
        begin
            pc_step = compressed ? 32'd2 : 32'd4;
            if (taken) begin
                if (compressed) begin
                    if (instruction[15:14] == 2'b11)
                        pc_step = {{23{instruction[12]}}, instruction[12], instruction[6:5],
                            instruction[2], instruction[11:10], instruction[4:3], 1'b0};
                    else
                        pc_step = {{20{instruction[12]}}, instruction[12], instruction[8],
                            instruction[10:9], instruction[6], instruction[7], instruction[2],
                            instruction[11], instruction[5:3], 1'b0};
                end else if (instruction[6:0] == 7'b1101111)
                    pc_step = {{11{instruction[31]}}, instruction[31], instruction[19:12],
                        instruction[20], instruction[30:21], 1'b0};
                else
                    pc_step = {{19{instruction[31]}}, instruction[31], instruction[7],
                        instruction[30:25], instruction[11:8], 1'b0};
            end
        end
    endfunction

    // Fetch Address and Response Tracking
    DerivedParameters::fetch_pc_t prefetch_pc;
    DerivedParameters::fetch_pc_t prefetch_pc_next;
    DerivedParameters::fetch_pc_t response_pc_reg;

    // Registered Fetch Staging and Predecode
    logic [FETCH_WORDS*32-1:0] fetch_staging_reg;
    DerivedParameters::fetch_pc_t fetch_staging_pc;
    DerivedParameters::fetch_pc_t fetch_lane_pc [FETCH_SLOTS-1:0];
    logic fetch_staging_reg_valid;
    logic [FETCH_SLOTS-1:0] fetch_branch_reg;
    logic [FETCH_SLOTS-1:0] fetch_c_reg;

    // Registered Partial-Instruction Recovery
    logic tail_partial;
    logic [15:0] partial_half_reg;
    DerivedParameters::fetch_pc_t partial_pc_reg;
    logic partial_branch_reg;

    // Combinational Instruction Reconstruction
    logic [(FETCH_SLOTS+1)*16-1:0] packet_half_window;
    logic packet_start [FETCH_SLOTS-1:0];
    logic [31:0] packet_data [FETCH_SLOTS-1:0];
    DerivedParameters::fetch_pc_t packet_pc [FETCH_SLOTS-1:0];
    logic packet_valid [FETCH_SLOTS-1:0];
    logic packet_c [FETCH_SLOTS-1:0];
    logic packet_branch [FETCH_SLOTS-1:0];
    logic packet_new_partial;
    logic [15:0] packet_partial_half;
    DerivedParameters::fetch_pc_t packet_partial_pc;
    logic [PUSH_COUNT_W-1:0] stage_push_count;

    logic [4:0] packet_rs1 [FETCH_SLOTS-1:0];
    logic [4:0] packet_rs2 [FETCH_SLOTS-1:0];
    logic [4:0] packet_rd [FETCH_SLOTS-1:0];
    logic [4:0] packet_rs3 [FETCH_SLOTS-1:0];
    logic packet_rs1_float [FETCH_SLOTS-1:0];
    logic packet_rs2_float [FETCH_SLOTS-1:0];
    logic packet_rs3_float [FETCH_SLOTS-1:0];
    logic packet_rd_float [FETCH_SLOTS-1:0];
    logic packet_rs1_used [FETCH_SLOTS-1:0];
    logic packet_rs2_used [FETCH_SLOTS-1:0];
    logic packet_rd_written [FETCH_SLOTS-1:0];
    DecodeCapability_ packet_capability [FETCH_SLOTS-1:0];
    logic [4:0] prediction_rs1 [FETCH_SLOTS-1:0];
    logic [4:0] prediction_rs2 [FETCH_SLOTS-1:0];
    logic [4:0] prediction_rd [FETCH_SLOTS-1:0];
    logic [4:0] prediction_rs3 [FETCH_SLOTS-1:0];
    logic prediction_rs1_float [FETCH_SLOTS-1:0];
    logic prediction_rs2_float [FETCH_SLOTS-1:0];
    logic prediction_rs3_float [FETCH_SLOTS-1:0];
    logic prediction_rd_float [FETCH_SLOTS-1:0];
    logic prediction_rs1_used [FETCH_SLOTS-1:0];
    logic prediction_rs2_used [FETCH_SLOTS-1:0];
    logic prediction_rd_written [FETCH_SLOTS-1:0];
    logic [$bits(DecodeCapability_)-1:0] prediction_capability [FETCH_SLOTS-1:0];
    logic [4:0] fifo_rs1 [FIFO_WORDS-1:0];
    logic [4:0] fifo_rs2 [FIFO_WORDS-1:0];
    logic [4:0] fifo_rd [FIFO_WORDS-1:0];
    logic [4:0] fifo_rs3 [FIFO_WORDS-1:0];
    logic fifo_rs1_float [FIFO_WORDS-1:0];
    logic fifo_rs2_float [FIFO_WORDS-1:0];
    logic fifo_rs3_float [FIFO_WORDS-1:0];
    logic fifo_rd_float [FIFO_WORDS-1:0];
    logic fifo_rs1_used [FIFO_WORDS-1:0];
    logic fifo_rs2_used [FIFO_WORDS-1:0];
    logic fifo_rd_written [FIFO_WORDS-1:0];
    logic fifo_fp_consumer [FIFO_WORDS-1:0];
    BranchOperation_ prediction_branch_operation [FETCH_SLOTS-1:0];
    logic [$bits(BranchOperation_)-1:0] fifo_branch_operation [FIFO_WORDS-1:0];
    for (genvar lane = 0; lane < FETCH_SLOTS; lane++) begin : branch_operation_predecode
        BranchOperationPredecode operation_decode (
            .instruction(prediction_payload[lane].bp_instruction),
            .is_compressed(prediction_payload[lane].bp_compressed),
            .operation(prediction_branch_operation[lane])
        );
    end
    logic [4:0] prediction_immediate_low [FETCH_SLOTS-1:0];
    logic [4:0] fifo_immediate_low [FIFO_WORDS-1:0];
    for (genvar lane = 0; lane < FETCH_SLOTS; lane++) begin : immediate_low_predecode
        ImmediateLowPredecode #(.SUPPORT_FLOAT(SUPPORT_FLOAT)) low_decode (
            .instruction(prediction_payload[lane].bp_instruction),
            .is_compressed(prediction_payload[lane].bp_compressed),
            .immediate_low(prediction_immediate_low[lane])
        );
    end
    logic [13:0] prediction_immediate_upper_select [FETCH_SLOTS-1:0];
    logic [13:0] fifo_immediate_upper_select [FIFO_WORDS-1:0];
    for (genvar lane = 0; lane < FETCH_SLOTS; lane++) begin : immediate_predecode
        ImmediateUpperPredecode #(.SUPPORT_FLOAT(SUPPORT_FLOAT)) format_decode (
            .instruction(prediction_payload[lane].bp_instruction),
            .is_compressed(prediction_payload[lane].bp_compressed),
            .upper_select(prediction_immediate_upper_select[lane])
        );
    end
    logic [$bits(DecodeCapability_)-1:0] fifo_capability [FIFO_WORDS-1:0];
    for (genvar lane = 0; lane < FETCH_SLOTS; lane++) begin : predecode_sources
        RegisterSlice #(
            .SUPPORT_MUL(SUPPORT_MUL),
            .SUPPORT_DIV(SUPPORT_DIV),
            .SUPPORT_FLOAT(SUPPORT_FLOAT),
            .SUPPORT_ATOMIC(SUPPORT_ATOMIC)
        ) register_slice (
            .instruction(packet_data[lane]),
            .is_compressed(packet_c[lane]),
            .rs1(packet_rs1[lane]),
            .rs2(packet_rs2[lane]),
            .rd(packet_rd[lane]),
            .rs3(packet_rs3[lane]),
            .rs1_float(packet_rs1_float[lane]),
            .rs2_float(packet_rs2_float[lane]),
            .rs3_float(packet_rs3_float[lane]),
            .rd_float(packet_rd_float[lane]),
            .rs1_used(packet_rs1_used[lane]),
            .rs2_used(packet_rs2_used[lane]),
            .rd_written(packet_rd_written[lane]),
            .capability(packet_capability[lane])
        );
    end

    // Registered Prediction Result Stage
    logic prediction_stage_valid;
    logic prediction_lane_valid [FETCH_SLOTS-1:0];
    DerivedParameters::fetch_pc_t prediction_pc;
    BranchInput_ prediction_payload [FETCH_SLOTS-1:0];
    TrapType_ packet_system_trap [FETCH_SLOTS-1:0];
    TrapType_ prediction_system_trap [FETCH_SLOTS-1:0];
    for (genvar lane = 0; lane < FETCH_SLOTS; lane++) begin : system_trap_predecode
        SystemTrapPredecode #(.SUPPORT_FLOAT(SUPPORT_FLOAT)) system_decode (
            .instruction(branch_input[lane].bp_instruction),
            .trap(packet_system_trap[lane])
        );
    end
    BranchOutput_ prediction_result [FETCH_SLOTS-1:0];
    logic [PUSH_COUNT_W-1:0] packet_push_count;

    // Combinational Predicted-Path Selection
    logic [FETCH_SLOTS-1:0] packet_lane_taken;
    logic [FETCH_SLOTS-1:0] packet_lane_selected;
    logic packet_keep [FETCH_SLOTS-1:0];
    logic packet_taken;
    logic [31:0] packet_redirect_pc;

    // Pipeline Transfer Controls
    logic fetch_accept;
    logic stage_transfer;
    logic packet_commit;

    // Registered FIFO Contents
    logic [31:0] fifo_data [FIFO_WORDS-1:0];
    DerivedParameters::fetch_pc_t fifo_pc [FIFO_WORDS-1:0];
    logic fifo_c [FIFO_WORDS-1:0];
    logic fifo_branch [FIFO_WORDS-1:0];
    logic fifo_evaluated [FIFO_WORDS-1:0];
    logic fifo_taken [FIFO_WORDS-1:0];

    // Selected FIFO State and Registered Tail/Admission
    logic [FIFO_INDEX_W:0] fifo_occipied_slots;
    logic [FIFO_INDEX_W:0] fifo_free_slots;
    logic [FIFO_INDEX_W:0] fifo_tail;
    logic [FIFO_INDEX_W:0] fifo_head;
    logic fifo_full;
    logic fifo_empty;
    logic fifo_packet_room;

    localparam int unsigned TRAP_W = $bits(TrapType_);
    localparam int unsigned SERVE_ENTRY_W = DerivedParameters::FETCH_PC_WIDTH + 60 + 3 + 20 + $bits(BranchOperation_) + $bits(DecodeCapability_) + TRAP_W;
    // Combinational outcomes feed a single set of serve and FIFO state registers.
    logic [SERVE_ENTRY_W-1:0] serve_next [SERVE_WORDS][SERVE_WORDS+1];
    logic [FIFO_INDEX_W:0] head_next [SERVE_WORDS+1];
    logic [FIFO_INDEX_W:0] occupied_next [SERVE_WORDS+1];
    logic [FIFO_INDEX_W:0] free_next [SERVE_WORDS+1];

    // Decode-Consumption PC Tracking
    logic [31:0] real_pc;
    logic [31:0] consumed_pc_step;

    // Registers External Reset Signal
    logic reset_reg;
    always_ff @(posedge clk) begin
        reset_reg <= reset;
    end

    // Calculates True PC Delta from Serve Consumption
    always_comb begin
        consumed_pc_step = '0;
        for (int unsigned i = 0; i < SERVE_WORDS; i++) begin
            if (serve_valid_reg[i] && (i < $unsigned(int'(serve_consumed_active))))
                consumed_pc_step = consumed_pc_step +
                    pc_step(serve_data_reg[i], serve_c_reg[i], serve_taken_reg[i]);
        end
    end

    // Forms Instruction Packets From Staging Register + Handles Partial Instructions
    always_comb begin
        packet_half_window = {16'b0, fetch_staging_reg};
        packet_new_partial = 1'b0;
        packet_partial_half = '0;
        packet_partial_pc = '0;
        // Constructs Every Possible Packet
        for (int unsigned i = 0; i < FETCH_SLOTS; i++) begin
            packet_data[i] = fetch_c_reg[i] ?
                {16'b0, packet_half_window[i*16 +: 16]} 
                : packet_half_window[i*16 +: 32];
            packet_pc[i] = fetch_lane_pc[i];
            packet_valid[i] = 1'b0;
            packet_c[i] = fetch_c_reg[i];
            packet_branch[i] = fetch_branch_reg[i];
            packet_start[i] = 1'b0;
        end
        // Determines First Instruction Boundary
        packet_start[0] = !tail_partial;
        packet_start[1] = tail_partial || fetch_c_reg[0];
        // Creates All Subsequent Instruction Boundaries
        for (int unsigned i = 2; i < FETCH_SLOTS; i++) begin
            packet_start[i] =
                (packet_start[i-2] && !fetch_c_reg[i-2]) ||
                (packet_start[i-1] && fetch_c_reg[i-1]);
        end
        // Forms New Word from Prior Partial Register Data if Applicable
        if (tail_partial) begin
            packet_data[0] = {fetch_staging_reg[15:0], partial_half_reg};
            packet_pc[0] = partial_pc_reg;
            packet_valid[0] = 1'b1;
            packet_c[0] = 1'b0;
            packet_branch[0] = partial_branch_reg;
        end
        // Identifies Final Valid Packets and Forms New Partial Word if Applicable
        for (int unsigned i = 0; i < FETCH_SLOTS; i++) begin
            if (packet_start[i]) begin
                if (!fetch_c_reg[i] && i == FETCH_SLOTS-1) begin
                    packet_new_partial = 1'b1;
                    packet_partial_half = packet_half_window[i*16 +: 16];
                    packet_partial_pc = fetch_lane_pc[i];
                end else begin
                    packet_valid[i] = 1'b1;
                end
            end
        end
    end

    logic packet_access_fault [FETCH_SLOTS];
    logic prediction_access_fault [FETCH_SLOTS];
    for (genvar lane = 0; lane < FETCH_SLOTS; lane++) begin : check_instruction_extent
        // Use the reconstructed start PC, including split 32-bit instructions.
        assign packet_access_fault[lane] = packet_c[lane] ?
            (Parameters::MAX_MEMORY_ADDRESS < 1 || packet_pc[lane] > Parameters::MAX_MEMORY_ADDRESS - 1) :
            (Parameters::MAX_MEMORY_ADDRESS < 3 || packet_pc[lane] > Parameters::MAX_MEMORY_ADDRESS - 3);
    end

    // Feeds Branch Predictor and Flushes Instructions Past First Taken Prediction
    always_comb begin
        logic earlier_taken;
        earlier_taken = 1'b0;
        packet_redirect_pc = '0;
        for (int unsigned i = 0; i < FETCH_SLOTS; i++) begin
            // Operates on Fetch Staging Registered Data
            branch_input[i] = '{
                bp_pc: packet_pc[i],
                bp_instruction: packet_data[i],
                bp_compressed: packet_c[i],
                bp_branch: packet_valid[i] && packet_branch[i] && !packet_access_fault[i]
            };
            // Operates on Prediction Register Latched Data
            packet_lane_taken[i] = prediction_lane_valid[i] && prediction_payload[i].bp_branch &&
                prediction_result[i].bp_valid && prediction_result[i].bp_taken;
            packet_keep[i] = prediction_lane_valid[i] && !earlier_taken;
            packet_lane_selected[i] = packet_lane_taken[i] && !earlier_taken;
            packet_redirect_pc = packet_redirect_pc |
                ({32{packet_lane_selected[i]}} & prediction_result[i].bp_redirect_pc);
            earlier_taken = earlier_taken || packet_lane_taken[i];
        end
        // Operates on Prediction Register Latched Data
        packet_taken = prediction_stage_valid && |packet_lane_taken;
    end

    // Popcounts Valid Instructions to Check Into FIFO
    always_comb begin
        logic earlier_taken;
        earlier_taken = 1'b0;
        stage_push_count = '0;
        for (int unsigned i = 0; i < FETCH_SLOTS; i++) begin
            stage_push_count += PUSH_COUNT_W'(packet_valid[i] && !earlier_taken);
            earlier_taken |= packet_valid[i] && packet_branch[i] &&
                branch_output[i].bp_valid && branch_output[i].bp_taken;
        end
    end

    // Packet Check-In Data to FIFO is Valid
    assign packet_commit = prediction_stage_valid && fifo_packet_room;

    // Staging Register to Prediction Register Transfer Gate Bit
    assign stage_transfer = fetch_staging_reg_valid &&
        (!prediction_stage_valid || packet_commit) &&
        !(packet_commit && packet_taken) && !redirect_taken;

    // Staging Register Acceptance Gate Bit
    assign fetch_accept = fetch_valid && !fetch_error &&
        (!fetch_staging_reg_valid || stage_transfer) &&
        !(packet_commit && packet_taken) && !redirect_taken;

    // Calculates Next Address For Prefetching
    always_comb begin
        logic advance;
        advance = fetch_valid && !fetch_error &&
            (!fetch_staging_reg_valid || !prediction_stage_valid || packet_commit);
        prefetch_pc_next = prefetch_pc;
        if (reset || reset_reg) begin
            prefetch_pc_next = DerivedParameters::bound_fetch_pc(RESET_VECTOR);
        end else if (redirect_taken) begin
            prefetch_pc_next = DerivedParameters::bound_fetch_pc(redirect_pc);
        end else if (packet_commit && packet_taken) begin
            for (int unsigned i = 0; i < FETCH_SLOTS; i++) begin
                if (packet_lane_selected[i]) begin
                    prefetch_pc_next = prediction_result[i].bp_redirect_pc;
                end
            end
        end else if (advance) begin
            prefetch_pc_next = prefetch_pc > Parameters::MAX_MEMORY_ADDRESS ? prefetch_pc :
                DerivedParameters::bound_fetch_pc(32'(prefetch_pc) + FETCH_WORDS * 4);
        end
    end

    // Tie Into External Facing Signals
    assign req_address = prefetch_pc_next;
    assign req_valid = !reset && !reset_reg;
    assign req_ready = fetch_accept;

    // Registers PC State and Accepted Fetch Data
    always_ff @(posedge clk) begin
        if (reset || reset_reg) begin
            real_pc <= RESET_VECTOR;
            prefetch_pc <= DerivedParameters::bound_fetch_pc(RESET_VECTOR);
            response_pc_reg <= DerivedParameters::bound_fetch_pc(RESET_VECTOR);
            fetch_staging_reg <= '0;
            fetch_staging_pc <= DerivedParameters::bound_fetch_pc(RESET_VECTOR);
            fetch_staging_reg_valid <= 1'b0;
            fetch_branch_reg <= '0;
            fetch_c_reg <= '0;
            for (int unsigned i = 0; i < FETCH_SLOTS; i++) fetch_lane_pc[i] <= DerivedParameters::bound_fetch_pc(RESET_VECTOR + i*2);
        end else begin
            // Tracks Memory Response Address and Consumed Instruction PC
            response_pc_reg <= req_address;
            prefetch_pc <= prefetch_pc_next;
            real_pc <= redirect_taken ? redirect_pc : real_pc + consumed_pc_step;
            // Redirects Discard Younger Staging Data
            if (redirect_taken || (packet_commit && packet_taken)) begin
                fetch_staging_reg_valid <= 1'b0;
            end else if (fetch_accept) begin
                fetch_staging_reg <= fetch_data;
                // Predecodes Each Halfword Before Instruction Boundary Resolution
                for (int unsigned i = 0; i < FETCH_SLOTS; i++) begin
                    fetch_lane_pc[i] <= response_pc_reg > Parameters::MAX_MEMORY_ADDRESS ? response_pc_reg :
                        DerivedParameters::bound_fetch_pc(32'(response_pc_reg) + i*2);
                    fetch_c_reg[i] <= fetch_data[i*16 +: 2] != 2'b11;
                    fetch_branch_reg[i] <= is_branch16(fetch_data[i*16 +: 16]) ||
                        is_branch32(fetch_data[i*16 +: 16]);
                end
                fetch_staging_pc <= response_pc_reg;
                fetch_staging_reg_valid <= 1'b1;
            end else if (stage_transfer) begin
                // Clears Staging Valid When Transferred Without Replacement
                fetch_staging_reg_valid <= 1'b0;
            end
        end
    end

    // Registers Prediction Results and Supports Same-Cycle Drain and Refill
    always_ff @(posedge clk) begin
        if (reset || reset_reg || redirect_taken || (packet_commit && packet_taken)) begin
            prediction_stage_valid <= 1'b0;
            prediction_pc <= '0;
            packet_push_count <= '0;
            for (int unsigned i = 0; i < FETCH_SLOTS; i++) begin
                prediction_rs1[i] <= 'x;
                prediction_rd[i] <= 'x;
                prediction_rs3[i] <= 'x;
                prediction_rs1_float[i] <= 'x;
                prediction_rs2_float[i] <= 'x;
                prediction_rs3_float[i] <= 'x;
                prediction_rd_float[i] <= 'x;
                prediction_rs1_used[i] <= 'x;
                prediction_rs2_used[i] <= 'x;
                prediction_rd_written[i] <= 'x;
                prediction_capability[i] <= 'x;
                prediction_rs2[i] <= 'x;
                prediction_payload[i] <= 'x;
                prediction_system_trap[i] <= TrapType_'('x);
                prediction_result[i] <= 'x;
                prediction_lane_valid[i] <= 1'b0;
            end
            tail_partial <= 1'b0;
            partial_half_reg <= 'x;
            partial_pc_reg <= 'x;
            partial_branch_reg <= 1'b0;
        end else begin
            if (stage_transfer) begin
                // Latches Reconstructed Instructions and Parallel Predictions
                prediction_stage_valid <= 1'b1;
                prediction_pc <= fetch_staging_pc;
                packet_push_count <= stage_push_count;
                for (int unsigned i = 0; i < FETCH_SLOTS; i++) begin
                    prediction_rs1[i] <= packet_rs1[i];
                    prediction_rd[i] <= packet_rd[i];
                    prediction_rs3[i] <= packet_rs3[i];
                    prediction_rs1_float[i] <= packet_rs1_float[i];
                    prediction_rs2_float[i] <= packet_rs2_float[i];
                    prediction_rs3_float[i] <= packet_rs3_float[i];
                    prediction_rd_float[i] <= packet_rd_float[i];
                    prediction_rs1_used[i] <= packet_rs1_used[i];
                    prediction_rs2_used[i] <= packet_rs2_used[i];
                    prediction_rd_written[i] <= packet_rd_written[i];
                    prediction_capability[i] <= packet_capability[i];
                    prediction_rs2[i] <= packet_rs2[i];
                    prediction_payload[i] <= branch_input[i];
                    prediction_system_trap[i] <= packet_system_trap[i];
                    prediction_access_fault[i] <= packet_access_fault[i];
                    prediction_result[i] <= branch_output[i];
                    prediction_lane_valid[i] <= packet_valid[i];
                end
                // Saves Trailing Partial Data for the Next Reconstructed Packet
                // Reconstruction Can Be Ahead of Prediction; Redirects Clear Both
                tail_partial <= packet_new_partial;
                if (packet_new_partial) begin
                    partial_half_reg <= packet_partial_half;
                    partial_pc_reg <= packet_partial_pc;
                    partial_branch_reg <= fetch_branch_reg[FETCH_SLOTS-1];
                end
            end else if (packet_commit) begin
                // Clears Prediction Valid When Committed Without Replacement
                prediction_stage_valid <= 1'b0;
            end
        end
    end

    // Legality runs after prediction capture, in parallel with FIFO admission.
    // The same commit/keep/index as the instruction captures its result.
    TrapType_ prediction_trap [FETCH_SLOTS];
    TrapType_ fifo_trap [FIFO_WORDS];
    for (genvar lane = 0; lane < FETCH_SLOTS; lane++) begin : prediction_legality
        InstructionLegality #(
            .SUPPORT_MUL(SUPPORT_MUL),
            .SUPPORT_DIV(SUPPORT_DIV),
            .SUPPORT_FLOAT(SUPPORT_FLOAT),
            .SUPPORT_ATOMIC(SUPPORT_ATOMIC)
        ) legality (
            .instruction(prediction_payload[lane].bp_instruction),
            .is_compressed(prediction_payload[lane].bp_compressed),
            .system_trap_in(prediction_system_trap[lane]),
            .trap(prediction_trap[lane])
        );
    end

    // Compacts Kept Prediction Lanes Into FIFO Entries Through First Taken Branch
    always_ff @(posedge clk) begin
        if (!reset && !reset_reg && !redirect_taken && packet_commit) begin
            logic [PUSH_COUNT_W-1:0] write_offset;
            write_offset = '0;
            for (int unsigned i = 0; i < FETCH_SLOTS; i++) begin
                logic [FIFO_INDEX_W-1:0] index;
                index = fifo_tail[FIFO_INDEX_W-1:0] + FIFO_INDEX_W'(write_offset);
                if (packet_keep[i]) begin
                    fifo_rs1[index] <= prediction_rs1[i];
                    fifo_rd[index] <= prediction_rd[i];
                    fifo_rs3[index] <= prediction_rs3[i];
                    fifo_rs1_float[index] <= prediction_rs1_float[i];
                    fifo_rs2_float[index] <= prediction_rs2_float[i];
                    fifo_rs3_float[index] <= prediction_rs3_float[i];
                    fifo_rd_float[index] <= prediction_rd_float[i];
                    fifo_rs1_used[index] <= prediction_rs1_used[i];
                    fifo_rs2_used[index] <= prediction_rs2_used[i];
                    fifo_rd_written[index] <= prediction_rd_written[i];
                    fifo_branch_operation[index] <= prediction_branch_operation[i];
                    fifo_fp_consumer[index] <= SUPPORT_FLOAT &&
                        (prediction_capability[i] inside {CAP_FP_F, CAP_FP_CONVERT});
                    fifo_immediate_low[index] <= prediction_immediate_low[i];
                    fifo_immediate_upper_select[index] <= prediction_immediate_upper_select[i];
                    fifo_capability[index] <= prediction_capability[i];
                    fifo_rs2[index] <= prediction_rs2[i];
                    fifo_data[index] <= prediction_payload[i].bp_instruction;
                    fifo_trap[index] <= prediction_access_fault[i] ? INST_ACCESS_FAULT : prediction_trap[i];
                    fifo_pc[index] <= prediction_payload[i].bp_pc;
                    fifo_c[index] <= prediction_payload[i].bp_compressed;
                    fifo_branch[index] <= prediction_payload[i].bp_branch;
                    fifo_evaluated[index] <= 1'b1;
                    fifo_taken[index] <= packet_lane_taken[i];
                    write_offset = write_offset + PUSH_COUNT_W'(1);
                end
            end
        end
    end

    // Read registered FIFO head offsets once for all combinational outcomes.
    logic [SERVE_ENTRY_W-1:0] fifo_candidate [SERVE_WORDS];
    logic [SERVE_ENTRY_W-1:0] retained_candidate [SERVE_WORDS];
    logic [FIFO_INDEX_W:0] push_count;
    logic [FIFO_INDEX_W:0] admission_free;
    assign push_count = packet_commit ? (FIFO_INDEX_W+1)'(packet_push_count) : '0;
    assign admission_free = fifo_free_slots - push_count;

    assign fifo_full = fifo_free_slots == '0;
    assign fifo_empty = fifo_occipied_slots == '0;

    for (genvar lane = 0; lane < SERVE_WORDS; lane++) begin : serve_lanes
        logic [FIFO_INDEX_W-1:0] read_index;
        assign read_index = fifo_head[FIFO_INDEX_W-1:0] + FIFO_INDEX_W'(lane);
        assign fifo_candidate[lane] = {1'b1, fifo_c[read_index], fifo_taken[read_index],
            fifo_branch[read_index], fifo_data[read_index], fifo_pc[read_index], fifo_branch_operation[read_index], fifo_fp_consumer[read_index], fifo_immediate_low[read_index], fifo_immediate_upper_select[read_index],
            fifo_rs1[read_index], fifo_rs2[read_index], fifo_rd[read_index], fifo_rs3[read_index], fifo_rs1_float[read_index], fifo_rs2_float[read_index], fifo_rs3_float[read_index], fifo_rd_float[read_index], fifo_rs1_used[read_index], fifo_rs2_used[read_index], fifo_rd_written[read_index], fifo_capability[read_index], fifo_trap[read_index]};
        assign retained_candidate[lane] = {serve_valid_reg[lane], serve_c_reg[lane],
            serve_taken_reg[lane], serve_branch_reg[lane], serve_data_reg[lane], serve_pc_reg[lane], serve_branch_operation[lane], serve_fp_consumer[lane], serve_immediate_low[lane], serve_immediate_upper_select[lane],
            serve_rs1[lane], serve_rs2[lane], serve_rd[lane], serve_rs3[lane], serve_rs1_float[lane], serve_rs2_float[lane], serve_rs3_float[lane], serve_rd_float[lane], serve_rs1_used[lane], serve_rs2_used[lane], serve_rd_written[lane], serve_capability[lane], serve_trap[lane]};
        always_ff @(posedge clk) begin
            if (reset || reset_reg || redirect_taken)
                serve_valid_reg[lane] <= 1'b0;
            else
                serve_valid_reg[lane] <= serve_next[lane][serve_select_count][SERVE_ENTRY_W-1];
            {serve_c_reg[lane], serve_taken_reg[lane], serve_branch_reg[lane],
             serve_data_reg[lane], serve_pc_reg[lane], serve_branch_operation[lane],
             serve_fp_consumer[lane], serve_immediate_low[lane], serve_immediate_upper_select[lane],
             serve_rs1[lane], serve_rs2[lane], serve_rd[lane], serve_rs3[lane],
             serve_rs1_float[lane], serve_rs2_float[lane], serve_rs3_float[lane], serve_rd_float[lane],
             serve_rs1_used[lane], serve_rs2_used[lane], serve_rd_written[lane],
             serve_capability[lane], serve_trap[lane]} <=
                serve_next[lane][serve_select_count][SERVE_ENTRY_W-2:0];
        end
    end

    for (genvar consumed = 0; consumed <= SERVE_WORDS; consumed++) begin : serve_outcomes
        logic [SERVE_COUNT_W-1:0] keep_count;
        logic [SERVE_COUNT_W-1:0] pull_count;
        logic [SERVE_ENTRY_W-1:0] next_window [SERVE_WORDS];

        always_comb begin
            keep_count = '0;
            for (int unsigned lane = consumed; lane < SERVE_WORDS; lane++)
                keep_count += SERVE_COUNT_W'(serve_valid_reg[lane]);
        end
        // Only entries already in the FIFO can be pulled. Same-edge pushes
        // become available next cycle, just as with the original serve register.
        assign pull_count =
            ($unsigned(int'(fifo_occipied_slots)) < (SERVE_WORDS - $unsigned(int'(keep_count))))
            ? SERVE_COUNT_W'(fifo_occipied_slots)
            : SERVE_COUNT_W'(SERVE_WORDS - $unsigned(int'(keep_count)));

        for (genvar lane = 0; lane < SERVE_WORDS; lane++) begin : window_lanes
            logic [SERVE_ENTRY_W-1:0] retained;
            assign serve_next[lane][consumed] = next_window[lane];
            // Generate-time bounds keep every elaborated source index valid.
            if (lane + consumed < SERVE_WORDS) begin : retained_source
                assign retained = retained_candidate[lane + consumed];
            end else begin : no_retained_source
                assign retained = {1'b0, {(SERVE_ENTRY_W-1){1'bx}}};
            end
            always_comb begin
                next_window[lane] = {1'b0, {(SERVE_ENTRY_W-1){1'bx}}};
                if (lane < int'(keep_count)) begin
                    // Legal windows have a contiguous prefix of valid entries.
                    next_window[lane] = retained;
                end else begin
                    for (int unsigned source = 0; source <= lane; source++) begin
                        if (keep_count == SERVE_COUNT_W'(lane - source) &&
                            fifo_occipied_slots > (FIFO_INDEX_W+1)'(source))
                            next_window[lane] = fifo_candidate[source];
                    end
                end
            end
        end

        assign head_next[consumed] = fifo_head + (FIFO_INDEX_W+1)'(pull_count);
        assign occupied_next[consumed] = fifo_occipied_slots + push_count -
            (FIFO_INDEX_W+1)'(pull_count);
        assign free_next[consumed] = admission_free + (FIFO_INDEX_W+1)'(pull_count);
    end

    always_ff @(posedge clk) begin
        if (reset || reset_reg || redirect_taken) begin
            fifo_head <= '0;
            fifo_occipied_slots <= '0;
            fifo_free_slots <= (FIFO_INDEX_W+1)'(FIFO_WORDS);
        end else begin
            fifo_head <= head_next[serve_select_count];
            fifo_occipied_slots <= occupied_next[serve_select_count];
            fifo_free_slots <= free_next[serve_select_count];
        end
    end

    // Tail and admission use committed pushes.
    // Tail and admission do not
    // depend on this cycle's pulls; admission deliberately gives no pop credit.
    always_ff @(posedge clk) begin
        if (reset || reset_reg || redirect_taken) begin
            fifo_tail <= '0;
            fifo_packet_room <= 1'b1;
        end else begin
            fifo_tail <= fifo_tail + push_count;
            if (packet_commit && packet_taken) begin
                fifo_packet_room <= 1'b1;
            end else begin
                fifo_packet_room <= admission_free >= (stage_transfer ?
                    (FIFO_INDEX_W+1)'(stage_push_count) :
                    (FIFO_INDEX_W+1)'(packet_push_count));
            end
        end
    end
endmodule

// Need to change vector widths to cleaner style instead of the CONST:0 form currently
// being used

// definitely consider removing a staging register if timing can't get 250+

// Wire redirects direct onto address bus when possible.
