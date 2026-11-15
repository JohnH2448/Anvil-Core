module DecodeStage
    import Enumerations::*;
    import Definitions::*;
    import DerivedParameters::*;
#(
    parameter unsigned ISSUE_WIDTH = 2,
    parameter unsigned EXECUTION_UNROLL = Parameters::EXECUTION_UNROLL,
    parameter unsigned SUPPORT_MUL = 1,
    parameter unsigned SUPPORT_DIV = 1,
    parameter unsigned SUPPORT_FLOAT = 1,
    parameter unsigned SUPPORT_ATOMIC = 1
)(

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
    input logic serve_valid_reg [ISSUE_WIDTH-1:0],
    input logic [31:0] serve_pc_reg [ISSUE_WIDTH-1:0],
    input logic serve_c_reg [ISSUE_WIDTH-1:0],
    input logic serve_taken_reg [ISSUE_WIDTH-1:0],
    input logic serve_branch_reg [ISSUE_WIDTH-1:0],

    // Output to Issue Stage
    output DecoderPacket_ packets_out [ISSUE_WIDTH-1:0],
    output LaneType_ lane_types_out [ISSUE_WIDTH-1:0],
    output logic packets_valid [ISSUE_WIDTH-1:0],
    output logic group_raw [ISSUE_WIDTH-1:0],
    output logic group_serial [ISSUE_WIDTH-1:0],
    output logic group_resource_bad [ISSUE_WIDTH-1:0],

    // Internal selection count: stall-masked, independent of reset/redirect.
    // Flush invalidates the queue and independently suppresses serve_consumed.
    input logic [$clog2(ISSUE_WIDTH+1)-1:0] issue_select_count,

    // Previous advancing-cycle producer writes from the issue buffer
    input logic [4:0] op_rd [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] op_lane [ISSUE_WIDTH-1:0],
    input logic op_write [ISSUE_WIDTH-1:0],
    input DecodeCapability_ op_type [ISSUE_WIDTH-1:0],

    // Acceptance Signals to Fetch
    output logic [$clog2(ISSUE_WIDTH+1)-1:0] serve_consumed,

    // Producer Table Reads
    output logic [4:0] rs1 [ISSUE_WIDTH-1:0],
    output logic [4:0] rs2 [ISSUE_WIDTH-1:0],

    // Producer Table Data, already aged for capture unless globally stalled
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

    // Generate Decoders and Produce Packets
    DecoderPacket_ packets [ISSUE_WIDTH-1:0];
    LaneType_ lane_types [ISSUE_WIDTH-1:0];
    for (genvar i = 0; i < ISSUE_WIDTH; i++) begin : decoders
        DecoderSlice #(
            .SUPPORT_MUL(SUPPORT_MUL),
            .SUPPORT_DIV(SUPPORT_DIV),
            .SUPPORT_FLOAT(SUPPORT_FLOAT),
            .SUPPORT_ATOMIC(SUPPORT_ATOMIC)
        ) decoder (
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
            .pc(serve_pc_reg[i]),
            .is_branch(serve_branch_reg[i]),
            .is_compressed(serve_c_reg[i]),
            .predicted_taken(serve_taken_reg[i]),
            .packet(packets[i]),
            .lane_type(lane_types[i])
        );
    end

    // Predecoded source addresses travel with the selected fetch window.
    assign rs1 = serve_rs1;
    assign rs2 = serve_rs2;
    // Fetch selects a registered speculative window after the clock edge.
    // Count that window's validity directly so metadata cannot lag its payload.
    logic [$clog2(ISSUE_WIDTH+1)-1:0] valid_inputs;
    always_comb begin
        valid_inputs = '0;
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++)
            valid_inputs += $clog2(ISSUE_WIDTH+1)'(serve_valid_reg[i]);
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
    assign serve_consumed = (reset || reset_reg || redirect_taken) ? '0 : serve_consumed_normal;

    always_ff @(posedge clk) begin
        if (reset || reset_reg || redirect_taken) empty_slots <= COUNT_W'(ISSUE_WIDTH);
        else empty_slots <= next_empty_slots;
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
        if (!stall) begin
            if (current.index < RF_INDEX) aged.index = current.index + 1'b1;
        end
        return aged;
    endfunction

    // Each buffered candidate advances independently of destination matching.
    SourceProducer_ write_producer [ISSUE_WIDTH];
    for (genvar slot = 0; slot < ISSUE_WIDTH; slot++) begin : write_progress
        assign write_producer[slot] = age_source({UNROLLED_W'(0),
            op_lane[slot], op_type[slot]});
    end

    // Update each fixed source slot before the late FIFO-selection signal.
    // All candidates are already aged to the capture edge before selection.
    // Prepare metadata even for unused operands; issue ignores it when rs*_valid
    // is low. Full instruction legality must not gate producer-write matching.
    function automatic SourceProducer_ refresh_source(
        input SourceProducer_ aged_current,
        input logic [4:0] source_register,
        input logic source_is_integer
    );
        SourceProducer_ selected;
        logic hit, matched;
        selected = '0;
        matched = 1'b0;
        for (int j = 0; j < ISSUE_WIDTH; j++) begin
            hit = op_write[j] && source_is_integer && op_rd[j] == source_register;
            selected |= {$bits(SourceProducer_){hit}} &
                write_producer[j];
            matched |= hit;
        end
        // All buffered writers precede every current packet, including slot zero.
        // Stall still permits absorption/refill, but all candidates remain unaged.
        return matched ? selected : aged_current;
    endfunction

    OperandProducers_ retained_producers [ISSUE_WIDTH];
    OperandProducers_ refill_producers [ISSUE_WIDTH];
    for (genvar source_slot = 0; source_slot < ISSUE_WIDTH; source_slot++) begin : producer_candidates
        SourceProducer_ old_1, old_2, fresh_1, fresh_2;
        assign old_1 = {rs1_index_out[source_slot], rs1_lane_out[source_slot], rs1_capability_out[source_slot]};
        assign old_2 = {rs2_index_out[source_slot], rs2_lane_out[source_slot], rs2_capability_out[source_slot]};
        // Table outputs already include capture-edge aging before address selection.
        assign fresh_1 = {rs1_index[source_slot], rs1_lane[source_slot], rs1_capability[source_slot]};
        assign fresh_2 = {rs2_index[source_slot], rs2_lane[source_slot], rs2_capability[source_slot]};
        always_comb begin
            retained_producers[source_slot].rs1 = refresh_source(age_source(old_1),
                packets_out[source_slot].common.rs1,
                !packets_out[source_slot].common.rs1_float);
            retained_producers[source_slot].rs2 = refresh_source(age_source(old_2),
                packets_out[source_slot].common.rs2,
                !packets_out[source_slot].common.rs2_float);
            refill_producers[source_slot].rs1 = refresh_source(fresh_1,
                serve_rs1[source_slot],
                !serve_rs1_float[source_slot]);
            refill_producers[source_slot].rs2 = refresh_source(fresh_2,
                serve_rs2[source_slot],
                !serve_rs2_float[source_slot]);
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
    logic pair_serial [SOURCE_COUNT][SOURCE_COUNT];
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
    localparam int unsigned MEMORY_LANE_BASE = 1 + Parameters::INTEGER_LANE_COUNT;
    localparam int unsigned FLOATING_LANE_BASE = MEMORY_LANE_BASE + Parameters::MEMORY_LANE_COUNT;
    logic [TOTAL_LANE_COUNT-1:0] compatible_lanes [SOURCE_COUNT];
    always_comb begin
        for (int unsigned i = 0; i < SOURCE_COUNT; i++) begin
            compatible_lanes[i] = '0;
            unique case (structural_sources[i].common.capability)
                CAP_ALU, CAP_BRU, CAP_MUL, CAP_DIV: begin
                    for (int unsigned lane = 0; lane < Parameters::INTEGER_LANE_COUNT; lane++) begin
                        if (lane < Parameters::INTEGER_LANE_COUNT) begin
                            unique case (structural_sources[i].common.capability)
                                CAP_ALU: compatible_lanes[i][lane+1] = Parameters::INTEGER_LANE_CAPABILITIES[lane][0];
                                CAP_BRU: compatible_lanes[i][lane+1] = Parameters::INTEGER_LANE_CAPABILITIES[lane][1];
                                CAP_MUL: compatible_lanes[i][lane+1] = Parameters::INTEGER_LANE_CAPABILITIES[lane][2];
                                CAP_DIV: compatible_lanes[i][lane+1] = Parameters::INTEGER_LANE_CAPABILITIES[lane][3];
                            endcase
                        end
                    end
                end
                CAP_MEMORY, CAP_ATOMIC: begin
                    for (int unsigned lane = 0; lane < Parameters::MEMORY_LANE_COUNT; lane++) begin
                        if (lane < Parameters::MEMORY_LANE_COUNT) begin
                            compatible_lanes[i][MEMORY_LANE_BASE + lane] =
                                Parameters::MEMORY_LANE_CAPABILITIES[lane][2'(structural_sources[i].common.capability == CAP_ATOMIC)];
                        end
                    end
                end
                CAP_FP_F, CAP_FP_CONVERT: begin
                    for (int unsigned lane = 0; lane < Parameters::FLOATING_LANE_COUNT; lane++) begin
                        if (lane < Parameters::FLOATING_LANE_COUNT) begin
                            compatible_lanes[i][FLOATING_LANE_BASE + lane] =
                                Parameters::FLOATING_LANE_CAPABILITIES[lane][structural_sources[i].common.capability == CAP_FP_CONVERT];
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

    logic single_resource_bad [SOURCE_COUNT];
    logic pair_resource_bad [SOURCE_COUNT][SOURCE_COUNT];
    for (genvar source_slot = 0; source_slot < SOURCE_COUNT; source_slot++) begin : single_resource
        assign single_resource_bad[source_slot] = !(|compatible_lanes[source_slot]);
    end
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
                // Oldest feasibility is checked separately by the issue prefix.
                assign pair_resource_bad[older][younger] =
                    single_resource_bad[younger] || !multiple_lanes;
                assign pair_raw[older][younger] = structural_usage[older][2] &&
                    ((structural_usage[younger][0] &&
                      structural_sources[older].common.rd == structural_sources[younger].common.rs1 &&
                      structural_sources[older].common.rd_float == structural_sources[younger].common.rs1_float) ||
                     (structural_usage[younger][1] &&
                      structural_sources[older].common.rd == structural_sources[younger].common.rs2 &&
                      structural_sources[older].common.rd_float == structural_sources[younger].common.rs2_float));
                assign pair_serial[older][younger] =
                    (structural_sources[older].common.capability inside {CAP_SYSTEM, CAP_CSR}) &&
                    (structural_sources[younger].common.capability inside {CAP_SYSTEM, CAP_CSR});
            end else begin : unordered_pair
                assign pair_resource_bad[older][younger] = 1'b0;
                assign pair_raw[older][younger] = 1'b0;
                assign pair_serial[older][younger] = 1'b0;
            end
        end
    end

    // Parallel constant slot comparisons replace variable source indexing and
    // the consumption -> retained-count arithmetic -> metadata-update chain.
    for (genvar destination = 0; destination < ISSUE_WIDTH; destination++) begin : fifo_slots
        logic keep [ISSUE_WIDTH];
        logic refill [ISSUE_WIDTH];
        DecoderPacket_ packet_next;
        LaneType_ lane_next;
        OperandProducers_ producers_next;
        logic valid_next;
        logic [2:0] usage_next;
        logic [ISSUE_WIDTH:0] raw_candidates, serial_candidates, resource_candidates;

        for (genvar source_slot = 0; source_slot < ISSUE_WIDTH; source_slot++) begin : choices
            if (source_slot >= destination) begin : retained_choice
                assign keep[source_slot] = packets_valid[source_slot] &&
                    issue_select_count == COUNT_W'(source_slot - destination);
            end else begin : no_retained_choice
                assign keep[source_slot] = 1'b0;
            end
            if (source_slot <= destination) begin : refill_choice
                logic position_matches;
                always_comb begin
                    position_matches = 1'b0;
                    // These loop indices are constants after elaboration. No
                    // runtime subtraction/addition is needed for payload selects.
                    for (int empty = 0; empty <= ISSUE_WIDTH; empty++) begin
                        for (int consumed = 0; consumed <= ISSUE_WIDTH - empty; consumed++) begin
                            if (ISSUE_WIDTH - empty - consumed == destination - source_slot)
                                position_matches |= empty_slots == COUNT_W'(empty) &&
                                    issue_select_count == COUNT_W'(consumed);
                        end
                    end
                end
                assign refill[source_slot] = position_matches && valid_inputs > COUNT_W'(source_slot);
            end else begin : no_refill_choice
                assign refill[source_slot] = 1'b0;
            end
        end

        // Each outcome is independent of live issue_select_count. Occupancy,
        // validity, flush and all pair reductions belong before the final mux.
        for (genvar consumed = 0; consumed <= ISSUE_WIDTH; consumed++) begin : structural_outcomes
            always_comb begin
                raw_candidates[consumed] = 1'b0;
                serial_candidates[consumed] = 1'b0;
                resource_candidates[consumed] = 1'b0;
                for (int empty = 0; empty <= ISSUE_WIDTH - consumed; empty++) begin
                    // Oldest needs one compatible lane. Younger needs a distinct
                    // pair; all source choices are constant after loop unrolling.
                    if (destination == 0) begin
                        int retained, source_slot;
                        retained = ISSUE_WIDTH - empty - consumed;
                        source_slot = retained > 0 ? consumed : ISSUE_WIDTH;
                        resource_candidates[consumed] |= empty_slots == COUNT_W'(empty) &&
                            structural_valid[source_slot] && single_resource_bad[source_slot];
                    end
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
                        serial_candidates[consumed] |= empty_slots == COUNT_W'(empty) &&
                            structural_valid[older] && structural_valid[younger] &&
                            pair_serial[older][younger];
                    end
                end
                if (reset || reset_reg || redirect_taken) begin
                    raw_candidates[consumed] = 1'b0;
                    serial_candidates[consumed] = 1'b0;
                    resource_candidates[consumed] = 1'b0;
                end
            end
        end
        // Direct consumption-selected bits into D: no selection masks, validity
        // qualification, reduction or hold enable after this mux.
        always_ff @(posedge clk) begin
            group_raw[destination] <= raw_candidates[issue_select_count];
            group_serial[destination] <= serial_candidates[issue_select_count];
            group_resource_bad[destination] <= resource_candidates[issue_select_count];
        end

        always_comb begin
            packet_next = '0;
            usage_next = '0;
            lane_next = LaneType_'('0);
            producers_next = '0;
            valid_next = 1'b0;
            for (int source_slot = 0; source_slot < ISSUE_WIDTH; source_slot++) begin
                usage_next |= {3{keep[source_slot]}} & structural_usage[source_slot];
                usage_next |= {3{refill[source_slot]}} & structural_usage[ISSUE_WIDTH + source_slot];
                packet_next |= {$bits(DecoderPacket_){keep[source_slot]}} & packets_out[source_slot];
                packet_next |= {$bits(DecoderPacket_){refill[source_slot]}} & packets[source_slot];
                lane_next = LaneType_'(lane_next |
                    ({$bits(LaneType_){keep[source_slot]}} & lane_types_out[source_slot]) |
                    ({$bits(LaneType_){refill[source_slot]}} & lane_types[source_slot]));
                producers_next |= {$bits(OperandProducers_){keep[source_slot]}} & retained_producers[source_slot];
                producers_next |= {$bits(OperandProducers_){refill[source_slot]}} & refill_producers[source_slot];
                valid_next |= keep[source_slot] || refill[source_slot];
            end
        end

        // Only validity is flush state. Payload registers have no hold enable
        // on redirect (or empty slots), and may contain arbitrary values.
        always_ff @(posedge clk) begin
            packets_valid[destination] <= (reset || reset_reg || redirect_taken) ? 1'b0 : valid_next;
            if (reset || reset_reg || redirect_taken || !valid_next) begin
                packets_out[destination] <= 'x;
                retained_usage[destination] <= 'x;
                lane_types_out[destination] <= LaneType_'('x);
                {rs1_index_out[destination], rs1_lane_out[destination], rs1_capability_out[destination]} <= 'x;
                {rs2_index_out[destination], rs2_lane_out[destination], rs2_capability_out[destination]} <= 'x;
            end else begin
                packets_out[destination] <= packet_next;
                retained_usage[destination] <= usage_next;
                lane_types_out[destination] <= lane_next;
                {rs1_index_out[destination], rs1_lane_out[destination], rs1_capability_out[destination]} <= producers_next.rs1;
                {rs2_index_out[destination], rs2_lane_out[destination], rs2_capability_out[destination]} <= producers_next.rs2;
            end
        end
    end
endmodule

// MOVE NEXT PC CALC FORWARD INTO INTEGER LANE OR SOMETHING

// not sure if this is presently being done but you dont need
// to zero serve_consumed on stall, only issue_select_count

// if 200-250MHz still evades, make decode a mini FIFO.
// Keep 4ish entries to keep it always ahead of issue.
// this entirely removes issue accept chained dependency