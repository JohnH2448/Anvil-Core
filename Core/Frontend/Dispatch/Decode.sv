module DecodeStage
    import Parameters::*;
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
(

    // Standard Inputs
    input logic clk,
    input logic reset,
    input logic stall,
    input logic redirect_taken,

    // Served Data from Fetch
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
    input logic [6:0] serve_immediate_upper_select [ISSUE_WIDTH-1:0],
    input logic serve_fp_consumer [ISSUE_WIDTH-1:0],
    input TrapType_ serve_trap [ISSUE_WIDTH-1:0],
    // Pending enabled interrupt (NONE if none) from the serial lane's flops.
    input TrapType_ interrupt_request,
    input logic serve_valid_reg [ISSUE_WIDTH-1:0],
    input fetch_pc_t serve_pc_reg [ISSUE_WIDTH-1:0],
    input logic serve_c_reg [ISSUE_WIDTH-1:0],
    input logic serve_taken_reg [ISSUE_WIDTH-1:0],
    input logic [PHT_INDEX_W-1:0] serve_pht_reg [ISSUE_WIDTH-1:0],
    input logic [RAS_TARGET_W-1:0] serve_ras_reg [ISSUE_WIDTH-1:0],
    input logic [RAS_SNAP_W-1:0] serve_snap_reg [ISSUE_WIDTH-1:0],
    input logic serve_branch_reg [ISSUE_WIDTH-1:0],

    // Output to Issue Stage
    output DecoderPacket_ packets_out [ISSUE_WIDTH-1:0],
    output LaneType_ lane_types_out [ISSUE_WIDTH-1:0],
    output logic packets_valid [ISSUE_WIDTH-1:0],
    output logic group_raw [ISSUE_WIDTH-1:0],
    output logic group_resource_bad [ISSUE_WIDTH-1:0],
    output logic operands_ready [ISSUE_WIDTH-1:0],
    output logic [ISSUE_WIDTH-1:0] rs1_buffer_match [ISSUE_WIDTH-1:0],
    output logic [ISSUE_WIDTH-1:0] rs2_buffer_match [ISSUE_WIDTH-1:0],

    // Unmasked candidate selection; state captures only when not stalled.
    // Flush invalidates the queue; Fetch applies flush and stall to its pop.
    input logic [$clog2(ISSUE_WIDTH+1)-1:0] issue_select_count,
    input logic issue_select_any,
    input logic issue_select_two,

    // Previous advancing-cycle producer writes from the issue buffer
    input logic [4:0] op_rd [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] op_lane [ISSUE_WIDTH-1:0],
    input logic op_write [ISSUE_WIDTH-1:0],
    input DecodeCapability_ op_type [ISSUE_WIDTH-1:0],

    // Acceptance Signals to Fetch
    // Stall-free pop count. Fetch builds its next state from this and applies
    // stall only as the final select, keeping stall off the pointer arithmetic.
    output logic [$clog2(ISSUE_WIDTH+1)-1:0] serve_normal_count,

    // Producer Table Reads

    input logic rs1_capture_ready [ISSUE_WIDTH-1:0],
    input logic rs2_capture_ready [ISSUE_WIDTH-1:0],

    // Current Producer Table Data; fresh snapshots are aged locally for capture.
    input logic [UNROLLED_W-1:0] rs1_index [ISSUE_WIDTH-1:0],
    input logic [UNROLLED_W-1:0] rs2_index [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] rs1_lane [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] rs2_lane [ISSUE_WIDTH-1:0],
    input DecodeCapability_ rs1_capability [ISSUE_WIDTH-1:0],
    input DecodeCapability_ rs2_capability [ISSUE_WIDTH-1:0],

    // Registered Producer Table Data to Issue
    output logic [UNROLLED_W-1:0] rs1_index_out [ISSUE_WIDTH-1:0],
    output logic [UNROLLED_W-1:0] rs2_index_out [ISSUE_WIDTH-1:0],
    output logic [LANE_WIDTH-1:0] rs1_lane_out [ISSUE_WIDTH-1:0],
    output logic [LANE_WIDTH-1:0] rs2_lane_out [ISSUE_WIDTH-1:0],
    output DecodeCapability_ rs1_capability_out [ISSUE_WIDTH-1:0],
    output DecodeCapability_ rs2_capability_out [ISSUE_WIDTH-1:0]

);

    // Register Resets
    logic reset_reg;
    always_ff @(posedge clk) begin
        reset_reg <= reset;
    end

    // Admission ordering around traps and MRET. Once a decode-known trap
    // (fetch trap, ILLEGAL, ECALL/EBREAK, interrupt tag) or an MRET is
    // admitted, nothing younger is admitted until recovery, so no younger
    // store can reach the bus before the trap reaches writeback. Older work
    // finishes normally.
    // - ends_group: a conservative superset computed only from registered
    //   serve fields (no DecoderSlice logic), because it sits on the pop count
    //   to Fetch. It ends the admitted window after the slot; a false positive
    //   only splits a window.
    // - wait_recovery: set from the exact decoded packet, which is a flop D
    //   input and off the pop path.
    // Trap entry re-checks interrupt enables, so a CSR write that disables an
    // interrupt after tagging needs no decode hold (the instruction refetches).
    logic wait_recovery;
    wire admit = !wait_recovery;
    wire inject_interrupt = admit && interrupt_request != NONE && serve_valid_reg[0];
    TrapType_ trap_in [ISSUE_WIDTH-1:0];
    always_comb begin
        foreach (trap_in[i]) trap_in[i] = serve_trap[i];
        if (inject_interrupt) trap_in[0] = interrupt_request;
    end

    // Generate Decoders and Produce Packets
    DecoderPacket_ packets [ISSUE_WIDTH-1:0];
    LaneType_ lane_types [ISSUE_WIDTH-1:0];
    for (genvar i = 0; i < ISSUE_WIDTH; i++) begin : decoders
        DecoderSlice decoder (
            .instruction(serve_data_reg[i]),
            .rs1_in(serve_rs1[i]),
            .rs2_in(serve_rs2[i]),
            .rd_in(serve_rd[i]),
            .rs3_in(serve_rs3[i]),
            .rs1_float_in(serve_rs1_float[i]),
            .rs2_float_in(serve_rs2_float[i]),
            .rs3_float_in(serve_rs3_float[i]),
            .rd_float_in(serve_rd_float[i]),
            .capability_in(DecodeCapability_'(serve_capability[i])),
            .immediate_upper_select_in(serve_immediate_upper_select[i]),
            .fp_consumer_in(serve_fp_consumer[i]),
            .trap_in(trap_in[i]),
            .rs1_used_in(serve_rs1_used[i]),
            .rs2_used_in(serve_rs2_used[i]),
            .rd_written_in(serve_rd_written[i]),
            .pc(serve_pc_reg[i]),
            .is_branch(serve_branch_reg[i]),
            .is_compressed(serve_c_reg[i]),
            .predicted_taken(serve_taken_reg[i]),
            .pht_index(serve_pht_reg[i]),
            .ras_target(serve_ras_reg[i]),
            .ras_snap(serve_snap_reg[i]),
            .packet(packets[i]),
            .lane_type(lane_types[i])
        );
    end

    // Fetch selects a registered speculative window after the clock edge.
    // Count that window's validity directly so metadata cannot lag its payload.
    logic [$clog2(ISSUE_WIDTH+1)-1:0] valid_inputs;
    logic ends_group [ISSUE_WIDTH], recovers [ISSUE_WIDTH];
    for (genvar i = 0; i < ISSUE_WIDTH; i++) begin : admission_boundary
        // Superset of every decode-known trap and MRET: fetch traps, all
        // SYSTEM/CSR encodings (ECALL, EBREAK, MRET, RO-CSR and FP-CSR
        // ILLEGAL), FP state accesses (ILLEGAL while FS is Off), and the
        // slot-0 interrupt tag. CSR/SYSTEM already issue one per group.
        assign ends_group[i] = serve_trap[i] != NONE ||
            DecodeCapability_'(serve_capability[i]) inside {CAP_SYSTEM, CAP_CSR} ||
            (SUPPORT_FLOAT && (DecodeCapability_'(serve_capability[i]) inside {CAP_FP_F, CAP_FP_CONVERT} ||
                serve_rd_float[i] || serve_rs2_float[i])) ||
            (i == 0 && inject_interrupt);
        // Exact: the decoded packet traps, or is MRET, FENCE or FENCE.I (all
        // flush and redirect at writeback).
        assign recovers[i] = packets[i].common.trap_type != NONE ||
            packets[i].system.operation inside {SYS_MRET, SYS_FENCE, SYS_FENCE_I};
    end
    always_comb begin
        logic open_slot;
        open_slot = admit;
        valid_inputs = '0;
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            if (open_slot && serve_valid_reg[i]) valid_inputs++;
            open_slot &= serve_valid_reg[i] && !ends_group[i];
        end
    end

    // Normal FIFO counts are independent of flush. Only the outward-facing
    // consumption and registered validity are forced low on redirect.
    localparam int unsigned COUNT_W = $unsigned($clog2(ISSUE_WIDTH + 1));
    logic [COUNT_W-1:0] empty_slots;
    logic [COUNT_W-1:0] available_slots;
    logic [COUNT_W-1:0] serve_consumed_normal;
    logic [COUNT_W-1:0] next_empty_slots;
    assign available_slots = empty_slots + issue_select_count;
    assign serve_consumed_normal = valid_inputs < available_slots ? valid_inputs : available_slots;
    assign next_empty_slots = available_slots - serve_consumed_normal;
    // Flush and stall are applied in Fetch: stall as a late 2:1 select between
    // the consumed-zero and normal outcomes, flush through queue validity.
    assign serve_normal_count = serve_consumed_normal;
    always_ff @(posedge clk) begin
        if (reset || reset_reg || redirect_taken) begin
            wait_recovery <= 1'b0;
        end else begin
            for (int i = 0; i < ISSUE_WIDTH; i++)
                if (!stall && i < int'(serve_consumed_normal) && recovers[i])
                    wait_recovery <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (reset || reset_reg || redirect_taken) empty_slots <= COUNT_W'(ISSUE_WIDTH);
        else if (!stall) empty_slots <= next_empty_slots;
    end

    typedef struct packed {
        logic [UNROLLED_W-1:0] index;
        logic [LANE_WIDTH-1:0] lane;
        DecodeCapability_ capability;
    } SourceProducer_;
    typedef struct packed {
        SourceProducer_ rs1;
        SourceProducer_ rs2;
    } OperandProducers_;

    localparam logic [UNROLLED_W-1:0] RF_INDEX = UNROLLED_W'(EXECUTION_UNROLL + 2);
    function automatic SourceProducer_ age_source(input SourceProducer_ current);
        SourceProducer_ aged;
        aged = current;
        if (current.index < RF_INDEX) aged.index = current.index + 1'b1;
        return aged;
    endfunction

    // Each buffered candidate advances independently of destination matching.
    SourceProducer_ write_producer [ISSUE_WIDTH];
    for (genvar slot = 0; slot < ISSUE_WIDTH; slot++) begin : write_progress
        assign write_producer[slot] = age_source({UNROLLED_W'(0),
            op_lane[slot], op_type[slot]});
    end

    // Update each fixed source slot before the late FIFO-selection signal.
    // Candidates assume an advancing capture edge; stall holds snapshot registers.
    // Retained sources reuse registered matches against the current write buffer.
    // Fresh arrivals compare addresses before correction. Prepare metadata even
    // for unused operands; issue ignores it when rs*_valid
    // is low. Full instruction legality must not gate producer-write matching.
    function automatic SourceProducer_ refresh_source(
        input SourceProducer_ aged_current,
        input logic [ISSUE_WIDTH-1:0] source_matches
    );
        SourceProducer_ selected;
        logic hit, matched;
        selected = '0;
        matched = 1'b0;
        for (int j = 0; j < ISSUE_WIDTH; j++) begin
            hit = op_write[j] && source_matches[j];
            selected |= {$bits(SourceProducer_){hit}} &
                write_producer[j];
            matched |= hit;
        end
        // All buffered writers precede every current packet, including slot zero.
        // Stall defers absorption/refill; buffered writers hold until advancement.
        return matched ? selected : aged_current;
    endfunction

    OperandProducers_ retained_producers [ISSUE_WIDTH];
    OperandProducers_ refill_producers [ISSUE_WIDTH];
    for (genvar source_slot = 0; source_slot < ISSUE_WIDTH; source_slot++) begin : producer_candidates
        SourceProducer_ old_1, old_2, fresh_1, fresh_2;
        logic [ISSUE_WIDTH-1:0] fresh_matches_1, fresh_matches_2;
        for (genvar writer = 0; writer < ISSUE_WIDTH; writer++) begin : fresh_matches
            assign fresh_matches_1[writer] = !serve_rs1_float[source_slot] &&
                op_rd[writer] == serve_rs1[source_slot];
            assign fresh_matches_2[writer] = !serve_rs2_float[source_slot] &&
                op_rd[writer] == serve_rs2[source_slot];
        end
        assign old_1 = {rs1_index_out[source_slot], rs1_lane_out[source_slot], rs1_capability_out[source_slot]};
        assign old_2 = {rs2_index_out[source_slot], rs2_lane_out[source_slot], rs2_capability_out[source_slot]};
        // Raw table reads receive the same local capture-edge aging as retained sources.
        assign fresh_1 = {rs1_index[source_slot], rs1_lane[source_slot], rs1_capability[source_slot]};
        assign fresh_2 = {rs2_index[source_slot], rs2_lane[source_slot], rs2_capability[source_slot]};
        always_comb begin
            retained_producers[source_slot].rs1 = refresh_source(age_source(old_1),
                rs1_buffer_match[source_slot]);
            retained_producers[source_slot].rs2 = refresh_source(age_source(old_2),
                rs2_buffer_match[source_slot]);
            refill_producers[source_slot].rs1 = refresh_source(age_source(fresh_1),
                fresh_matches_1);
            refill_producers[source_slot].rs2 = refresh_source(age_source(fresh_2),
                fresh_matches_2);
        end
    end

    // Compare fixed packet sources before the late consumption selection.
    // Retained packets precede fresh packets in program order. The FIFO masks
    // below are evaluated for each constant consumption outcome before selection.
    localparam int unsigned SOURCE_COUNT = 2 * ISSUE_WIDTH;
    DecoderPacket_ structural_sources [SOURCE_COUNT];
    logic structural_valid [SOURCE_COUNT];
    logic [2:0] retained_usage [ISSUE_WIDTH];
    logic [2:0] structural_usage [SOURCE_COUNT];
    logic pair_raw [SOURCE_COUNT][SOURCE_COUNT];
    for (genvar source_slot = 0; source_slot < ISSUE_WIDTH; source_slot++) begin : structural_sources_gen
        assign structural_usage[source_slot] = retained_usage[source_slot];
        assign structural_usage[ISSUE_WIDTH + source_slot] =
            {serve_rd_written[source_slot], serve_rs2_used[source_slot], serve_rs1_used[source_slot]};
        assign structural_valid[source_slot] = packets_valid[source_slot];
        assign structural_valid[ISSUE_WIDTH + source_slot] = valid_inputs > COUNT_W'(source_slot);
        assign structural_sources[source_slot] = packets_out[source_slot];
        assign structural_sources[ISSUE_WIDTH + source_slot] = packets[source_slot];
    end
    // Static lane feasibility for fixed retained/refill sources.
    localparam int unsigned MEMORY_LANE_BASE = 1 + INTEGER_LANE_COUNT;
    localparam int unsigned FLOATING_LANE_BASE = MEMORY_LANE_BASE + MEMORY_LANE_COUNT;
    logic [TOTAL_LANE_COUNT-1:0] compatible_lanes [SOURCE_COUNT];
    always_comb begin
        for (int unsigned i = 0; i < SOURCE_COUNT; i++) begin
            compatible_lanes[i] = '0;
            unique case (structural_sources[i].common.capability)
                CAP_ALU, CAP_BRU, CAP_MUL, CAP_DIV: begin
                    for (int unsigned lane = 0; lane < INTEGER_LANE_COUNT; lane++) begin
                        if (lane < INTEGER_LANE_COUNT) begin
                            unique case (structural_sources[i].common.capability)
                                CAP_ALU: compatible_lanes[i][lane+1] = EFFECTIVE_INTEGER_CAPS[lane][0];
                                CAP_BRU: compatible_lanes[i][lane+1] = EFFECTIVE_INTEGER_CAPS[lane][1];
                                CAP_MUL: compatible_lanes[i][lane+1] = EFFECTIVE_INTEGER_CAPS[lane][2];
                                CAP_DIV: compatible_lanes[i][lane+1] = EFFECTIVE_INTEGER_CAPS[lane][3];
                            endcase
                        end
                    end
                end
                CAP_MEMORY, CAP_ATOMIC: begin
                    for (int unsigned lane = 0; lane < MEMORY_LANE_COUNT; lane++) begin
                        if (lane < MEMORY_LANE_COUNT) begin
                            compatible_lanes[i][MEMORY_LANE_BASE + lane] =
                                EFFECTIVE_MEMORY_CAPS[lane][2'(structural_sources[i].common.capability == CAP_ATOMIC)];
                        end
                    end
                end
                CAP_FP_F, CAP_FP_CONVERT: begin
                    for (int unsigned lane = 0; lane < FLOATING_LANE_COUNT; lane++) begin
                        if (lane < FLOATING_LANE_COUNT) begin
                            compatible_lanes[i][FLOATING_LANE_BASE + lane] =
                                EFFECTIVE_FLOATING_CAPS[lane][structural_sources[i].common.capability == CAP_FP_CONVERT];
                        end
                    end
                end
                CAP_SYSTEM, CAP_CSR: begin
                    compatible_lanes[i][SERIAL_LANE_ID] = 1'b1;
                end
            endcase

            // Decode never emits a disabled capability. Leave its mask
            // unspecified so synthesis can eliminate that decode path.
            if ((SUPPORT_MUL == 0 && structural_sources[i].common.capability == CAP_MUL) ||
                (SUPPORT_DIV == 0 && structural_sources[i].common.capability == CAP_DIV) ||
                (SUPPORT_FLOAT == 0 && structural_sources[i].common.capability inside {CAP_FP_F, CAP_FP_CONVERT}) ||
                (SUPPORT_ATOMIC == 0 && structural_sources[i].common.capability == CAP_ATOMIC)) begin
                compatible_lanes[i] = 'x;
            end
        end
    end

    logic pair_resource_bad [SOURCE_COUNT][SOURCE_COUNT];
    // Issuer's allocator supports one or two instructions, not wider groups.
    initial begin
        if (ISSUE_WIDTH > 2) $fatal(1, "Decode resource precomputation supports ISSUE_WIDTH <= 2");
    end

    for (genvar older = 0; older < SOURCE_COUNT; older++) begin : structural_older
        for (genvar younger = 0; younger < SOURCE_COUNT; younger++) begin : structural_younger
            if (older < younger) begin : ordered_pair
                logic [TOTAL_LANE_COUNT-1:0] lane_union;
                logic multiple_lanes;
                assign lane_union = compatible_lanes[older] | compatible_lanes[younger];
                always_comb begin
                    logic seen;
                    seen = 1'b0;
                    multiple_lanes = 1'b0;
                    for (int lane = 0; lane < TOTAL_LANE_COUNT; lane++) begin
                        multiple_lanes |= seen && lane_union[lane];
                        seen |= lane_union[lane];
                    end
                end
                // Each enabled capability has a lane. A pair needs two distinct lanes.
                assign pair_resource_bad[older][younger] = !multiple_lanes;
                assign pair_raw[older][younger] = structural_usage[older][2] &&
                    ((structural_usage[younger][0] &&
                      structural_sources[older].common.rd == structural_sources[younger].common.rs1 &&
                      structural_sources[older].common.rd_float == structural_sources[younger].common.rs1_float) ||
                     (structural_usage[younger][1] &&
                      structural_sources[older].common.rd == structural_sources[younger].common.rs2 &&
                      structural_sources[older].common.rd_float == structural_sources[younger].common.rs2_float));
            end else begin : unordered_pair
                assign pair_resource_bad[older][younger] = 1'b0;
                assign pair_raw[older][younger] = 1'b0;
            end
        end
    end

    // Compare fixed next-packet sources against candidate writers BEFORE issue
    // selection. Issuer captures packets_out[writer].common.rd as op_rd on this
    // same edge. Next-cycle op_write qualifies acceptance, bank, x0 and dedup.
    logic [ISSUE_WIDTH-1:0] next_rs1_match [SOURCE_COUNT];
    logic [ISSUE_WIDTH-1:0] next_rs2_match [SOURCE_COUNT];
    for (genvar source_slot = 0; source_slot < SOURCE_COUNT; source_slot++) begin : next_buffer_matches
        for (genvar writer = 0; writer < ISSUE_WIDTH; writer++) begin : writers
            assign next_rs1_match[source_slot][writer] =
                !structural_sources[source_slot].common.rs1_float &&
                structural_sources[source_slot].common.rs1 == packets_out[writer].common.rd;
            assign next_rs2_match[source_slot][writer] =
                !structural_sources[source_slot].common.rs2_float &&
                structural_sources[source_slot].common.rs2 == packets_out[writer].common.rd;
        end
    end

    // Evaluate next-cycle readiness for every possible accepted prefix. No live
    // acceptance gates these computations: consumption selects only final bits.
    // Evaluate each old buffer writer at capture position one, independently
    // of source matching. Data correction and eligibility correction run in parallel.
    logic buffered_capture_ready [ISSUE_WIDTH];
    for (genvar writer = 0; writer < ISSUE_WIDTH; writer++) begin : buffered_readiness
        assign buffered_capture_ready[writer] = producer_capture_ready(UNROLLED_W'(0),
            op_type[writer], EXECUTION_UNROLL, DIVIDER_AUTO_PIPE);
    end
    typedef struct packed {
        logic matched;
        logic ready;
    } WriterReadiness_;

    function automatic WriterReadiness_ buffered_override(
        input logic [4:0] source_register,
        input logic source_float,
        input logic rf_only
    );
        logic hit, matched, selected;
        matched = 1'b0;
        selected = 1'b0;
        for (int writer = 0; writer < ISSUE_WIDTH; writer++) begin
            hit = op_write[writer] && !source_float && op_rd[writer] == source_register;
            matched |= hit;
            selected |= hit && !rf_only && buffered_capture_ready[writer];
        end
        return {matched, selected};
    endfunction

    logic candidate_writes [ISSUE_WIDTH];
    logic candidate_bypass_ready [ISSUE_WIDTH];
    for (genvar writer = 0; writer < ISSUE_WIDTH; writer++) begin : prospective_writers
        // Mirrors issue_write except acceptance/stall/flush, which are implicit
        // in the chosen outcome and the capture enable/validity.
        assign candidate_writes[writer] = writes_integer_producer(packets_out[writer]);
        // Sole source of index-zero (bypass) eligibility. Shifts and compares
        // are included only with ENABLE_SHIFT_BYPASS / ENABLE_COMPARE_BYPASS;
        // otherwise they wait for the index-one registered forward.
        assign candidate_bypass_ready[writer] = ENABLE_BYPASS &&
            packets_out[writer].common.capability == CAP_ALU &&
            alu_bypassable(packets_out[writer].alu.operation);
    end
    logic source_ready_by_pop [ISSUE_WIDTH+1][SOURCE_COUNT];
    for (genvar source_slot = 0; source_slot < SOURCE_COUNT; source_slot++) begin : readiness_sources
        logic snapshot_rs1_ready, snapshot_rs2_ready;
        WriterReadiness_ buffered_1, buffered_2;
        logic rf_only_consumer, rf_only_1, rf_only_2;
        assign rf_only_consumer =
            (SUPPORT_FLOAT && structural_sources[source_slot].common.fp_consumer) ||
            (structural_sources[source_slot].common.capability == CAP_CSR);
        assign rf_only_1 = rf_only_consumer && !structural_sources[source_slot].common.rs1_float;
        assign rf_only_2 = rf_only_consumer && !structural_sources[source_slot].common.rs2_float;
        if (source_slot < ISSUE_WIDTH) begin : retained
            assign snapshot_rs1_ready = rf_only_1 ?
                (rs1_index_out[source_slot] >= EXECUTION_UNROLL+1) : producer_capture_ready(rs1_index_out[source_slot],
                rs1_capability_out[source_slot], EXECUTION_UNROLL, DIVIDER_AUTO_PIPE);
            assign snapshot_rs2_ready = rf_only_2 ?
                (rs2_index_out[source_slot] >= EXECUTION_UNROLL+1) : producer_capture_ready(rs2_index_out[source_slot],
                rs2_capability_out[source_slot], EXECUTION_UNROLL, DIVIDER_AUTO_PIPE);
        end else begin : fresh
            assign snapshot_rs1_ready = rf_only_1 ?
                (rs1_index[source_slot - ISSUE_WIDTH] >= EXECUTION_UNROLL+1) : rs1_capture_ready[source_slot - ISSUE_WIDTH];
            assign snapshot_rs2_ready = rf_only_2 ?
                (rs2_index[source_slot - ISSUE_WIDTH] >= EXECUTION_UNROLL+1) : rs2_capture_ready[source_slot - ISSUE_WIDTH];
        end
        assign buffered_1 = buffered_override(
            structural_sources[source_slot].common.rs1, structural_sources[source_slot].common.rs1_float, rf_only_1);
        assign buffered_2 = buffered_override(
            structural_sources[source_slot].common.rs2, structural_sources[source_slot].common.rs2_float, rf_only_2);
        for (genvar consumed = 0; consumed <= ISSUE_WIDTH; consumed++) begin : outcome
            always_comb begin
                WriterReadiness_ writer_1, writer_2;
                logic ready_1, ready_2;
                writer_1 = buffered_1;
                writer_2 = buffered_2;
                // New buffer writers start at zero NEXT cycle. Ascending priority
                // reproduces youngest-writer dedup without live op_write gating.
                for (int writer = 0; writer < consumed; writer++) begin
                    if (candidate_writes[writer] && next_rs1_match[source_slot][writer])
                        writer_1 = {1'b1, !rf_only_1 && candidate_bypass_ready[writer]};
                    if (candidate_writes[writer] && next_rs2_match[source_slot][writer])
                        writer_2 = {1'b1, !rf_only_2 && candidate_bypass_ready[writer]};
                end
                // Resolve writer priority independently of the late CAM result.
                ready_1 = writer_1.matched ? writer_1.ready : snapshot_rs1_ready;
                ready_2 = writer_2.matched ? writer_2.ready : snapshot_rs2_ready;
                source_ready_by_pop[consumed][source_slot] =
                    (!structural_sources[source_slot].common.rs1_valid || ready_1) &&
                    (!structural_sources[source_slot].common.rs2_valid || ready_2);
            end
        end
    end

    // Packet movement uses the issue prefix directly: oldest chooses zero/one
    // consumption early, then younger chooses the full-pop outcome at the end.
    typedef struct packed {
        DecoderPacket_ packet;
        LaneType_ lane;
        logic [2:0] usage_bits;
        logic valid;
        logic [ISSUE_WIDTH-1:0] rs1_match;
        logic [ISSUE_WIDTH-1:0] rs2_match;
    } PacketChoice_;
    for (genvar destination = 0; destination < ISSUE_WIDTH; destination++) begin : fifo_slots
        PacketChoice_ packet_outcomes [2];
        PacketChoice_ early_packet, selected_packet;
        OperandProducers_ producer_outcomes [ISSUE_WIDTH+1];
        logic [ISSUE_WIDTH:0] raw_candidates, resource_candidates;
        logic [ISSUE_WIDTH:0] ready_candidates;

        // Combinational source choices only; no candidate packet bank is stored.
        for (genvar consumed = 0; consumed <= 1; consumed++) begin : packet_selection
            PacketChoice_ occupancy_outcomes [ISSUE_WIDTH-consumed+1];
            for (genvar empty = 0; empty <= ISSUE_WIDTH - consumed; empty++) begin : occupancy
                localparam int RETAINED = ISSUE_WIDTH - empty - consumed;
                if (destination < RETAINED) begin : keep_source
                    assign occupancy_outcomes[empty] = {
                        packets_out[destination + consumed], lane_types_out[destination + consumed],
                        retained_usage[destination + consumed], packets_valid[destination + consumed],
                        next_rs1_match[destination + consumed], next_rs2_match[destination + consumed]};
                end else begin : refill_source
                    localparam int SOURCE = destination - RETAINED;
                    assign occupancy_outcomes[empty] = {packets[SOURCE], lane_types[SOURCE],
                        structural_usage[ISSUE_WIDTH + SOURCE], structural_valid[ISSUE_WIDTH + SOURCE],
                        next_rs1_match[ISSUE_WIDTH + SOURCE], next_rs2_match[ISSUE_WIDTH + SOURCE]};
                end
            end
            always_comb begin
                packet_outcomes[consumed] = 'x;
                for (int empty = 0; empty <= ISSUE_WIDTH - consumed; empty++) begin
                    if (empty_slots == COUNT_W'(empty))
                        packet_outcomes[consumed] = occupancy_outcomes[empty];
                end
            end
        end
        assign early_packet = issue_select_any ? packet_outcomes[1] : packet_outcomes[0];
        if (ISSUE_WIDTH == 2) begin : final_pair_selection
            // Both issued implies both old slots were valid, hence no retained
            // packet: fresh destination is the full-pop result without occupancy.
            PacketChoice_ full_pop_packet;
            assign full_pop_packet = {packets[destination], lane_types[destination],
                structural_usage[ISSUE_WIDTH + destination], structural_valid[ISSUE_WIDTH + destination],
                next_rs1_match[ISSUE_WIDTH + destination], next_rs2_match[ISSUE_WIDTH + destination]};
            assign selected_packet = issue_select_two ? full_pop_packet : early_packet;
        end else begin : final_single_selection
            assign selected_packet = early_packet;
        end

        // Resolve occupancy for each fixed pop count before the late selector.
        // The fixed sources already include capture-edge aging and write refresh.
        for (genvar consumed = 0; consumed <= ISSUE_WIDTH; consumed++) begin : producer_selection
            OperandProducers_ occupancy_outcomes [ISSUE_WIDTH-consumed+1];
            for (genvar empty = 0; empty <= ISSUE_WIDTH - consumed; empty++) begin : occupancy
                localparam int RETAINED = ISSUE_WIDTH - empty - consumed;
                if (destination < RETAINED) begin : keep_source
                    assign occupancy_outcomes[empty] = retained_producers[destination + consumed];
                end else begin : refill_source
                    assign occupancy_outcomes[empty] = refill_producers[destination - RETAINED];
                end
            end
            always_comb begin
                producer_outcomes[consumed] = 'x;
                for (int empty = 0; empty <= ISSUE_WIDTH - consumed; empty++) begin
                    if (empty_slots == COUNT_W'(empty))
                        producer_outcomes[consumed] = occupancy_outcomes[empty];
                end
            end
        end
        OperandProducers_ selected_producers;
        logic retained_rs1_match, retained_rs2_match;
        logic rs1_identity_enable, rs2_identity_enable;
        assign selected_producers = producer_outcomes[issue_select_count];
        // Use the same integer-bank/write-valid match as refresh_source, without
        // legality/operand-use qualification. Incoming sources are corrected in
        // their own candidates and do not need to match the outgoing packet.
        always_comb begin
            retained_rs1_match = 1'b0;
            retained_rs2_match = 1'b0;
            for (int writer = 0; writer < ISSUE_WIDTH; writer++) begin
                retained_rs1_match |= op_write[writer] && rs1_buffer_match[destination][writer];
                retained_rs2_match |= op_write[writer] && rs2_buffer_match[destination][writer];
            end
        end
        // Any pop permits replacement; empty slots permit refill. Deliberately
        // allow extra captures rather than derive an exact value-change enable.
        assign rs1_identity_enable = !stall &&
            (issue_select_any || !packets_valid[destination] || retained_rs1_match);
        assign rs2_identity_enable = !stall &&
            (issue_select_any || !packets_valid[destination] || retained_rs2_match);
        always_ff @(posedge clk) begin
            // Position progresses even when the same packet waits without a hit.
            if (!stall) begin
                rs1_index_out[destination] <= selected_producers.rs1.index;
                rs2_index_out[destination] <= selected_producers.rs2.index;
            end
            if (rs1_identity_enable) begin
                rs1_lane_out[destination] <= selected_producers.rs1.lane;
                rs1_capability_out[destination] <= selected_producers.rs1.capability;
            end
            if (rs2_identity_enable) begin
                rs2_lane_out[destination] <= selected_producers.rs2.lane;
                rs2_capability_out[destination] <= selected_producers.rs2.capability;
            end
        end

        // Each outcome is independent of live issue_select_count. Occupancy,
        // validity, flush and all pair reductions belong before the final mux.
        for (genvar consumed = 0; consumed <= ISSUE_WIDTH; consumed++) begin : structural_outcomes
            always_comb begin
                raw_candidates[consumed] = 1'b0;
                resource_candidates[consumed] = 1'b0;
                for (int empty = 0; empty <= ISSUE_WIDTH - consumed; empty++) begin
                    // Constant after unrolling: retained suffix followed by refill.
                    for (int older_slot = 0; older_slot < destination; older_slot++) begin
                        int retained, older, younger;
                        retained = ISSUE_WIDTH - empty - consumed;
                        older = older_slot < retained ? older_slot + consumed :
                            ISSUE_WIDTH + older_slot - retained;
                        younger = destination < retained ? destination + consumed :
                            ISSUE_WIDTH + destination - retained;
                        resource_candidates[consumed] |= empty_slots == COUNT_W'(empty) &&
                            structural_valid[older] && structural_valid[younger] &&
                            pair_resource_bad[older][younger];
                        raw_candidates[consumed] |= empty_slots == COUNT_W'(empty) &&
                            structural_valid[older] && structural_valid[younger] &&
                            pair_raw[older][younger];
                    end
                end
            end
        end
        // Source identity is resolved for each constant pop/occupancy combination
        // before the late count mux, exactly as for the associated packet.
        for (genvar consumed = 0; consumed <= ISSUE_WIDTH; consumed++) begin : readiness_selection
            logic occupancy_ready [ISSUE_WIDTH-consumed+1];
            for (genvar empty = 0; empty <= ISSUE_WIDTH - consumed; empty++) begin : occupancy
                localparam int RETAINED = ISSUE_WIDTH - empty - consumed;
                localparam int SOURCE = destination < RETAINED ? destination + consumed :
                    ISSUE_WIDTH + destination - RETAINED;
                assign occupancy_ready[empty] = source_ready_by_pop[consumed][SOURCE];
            end
            always_comb begin
                ready_candidates[consumed] = 1'b0;
                for (int empty = 0; empty <= ISSUE_WIDTH - consumed; empty++) begin
                    if (empty_slots == COUNT_W'(empty))
                        ready_candidates[consumed] = occupancy_ready[empty];
                end
            end
        end
        always_ff @(posedge clk) begin
            if (reset || reset_reg || redirect_taken)
                operands_ready[destination] <= 1'b0;
            else if (!stall)
                operands_ready[destination] <= ready_candidates[issue_select_count];
        end

        // Structural flags freeze with their packet; flush overrides the hold.
        always_ff @(posedge clk) begin
            if (reset || reset_reg || redirect_taken) begin
                group_raw[destination] <= 1'b0;
                group_resource_bad[destination] <= 1'b0;
            end else if (!stall) begin
                group_raw[destination] <= raw_candidates[issue_select_count];
                group_resource_bad[destination] <= resource_candidates[issue_select_count];
            end
        end

        // Flush validity even when stalled. Payload holds on global stall and
        // may be arbitrary when invalid; no gated clock is generated.
        always_ff @(posedge clk) begin
            if (reset || reset_reg || redirect_taken)
                packets_valid[destination] <= 1'b0;
            else if (!stall)
                packets_valid[destination] <= selected_packet.valid;
            if (!stall) begin
                packets_out[destination] <= selected_packet.packet;
                rs1_buffer_match[destination] <= selected_packet.rs1_match;
                rs2_buffer_match[destination] <= selected_packet.rs2_match;
                retained_usage[destination] <= selected_packet.usage_bits;
                lane_types_out[destination] <= selected_packet.lane;
            end
        end
    end
endmodule

// next_pc remains unassigned; execution must derive it later.
