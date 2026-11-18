module Issuer 
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned EXECUTION_UNROLL = 1,
    parameter unsigned BYPASS_ENABLED = 1, 
    parameter unsigned ISSUE_WIDTH = 2
)(

    // Standard Inputs
    input logic clk,
    input logic reset,
    input logic stall,
    input logic redirect_taken,

    // Decoder Popped Outputs
    input DecoderPacket_ packets_out [ISSUE_WIDTH-1:0],
    input LaneType_ lane_types_out [ISSUE_WIDTH-1:0],
    input logic packets_valid [ISSUE_WIDTH-1:0],
    input logic group_raw [ISSUE_WIDTH-1:0],
    input logic group_resource_bad [ISSUE_WIDTH-1:0],
    input logic operands_ready [ISSUE_WIDTH-1:0],
    input logic [ISSUE_WIDTH-1:0] rs1_buffer_match [ISSUE_WIDTH-1:0],
    input logic [ISSUE_WIDTH-1:0] rs2_buffer_match [ISSUE_WIDTH-1:0],

    // Consumption To Frontend
    output logic [$clog2(ISSUE_WIDTH+1)-1:0] issue_consumed,
    // Unmasked Decode candidate controls; Decode captures only when advancing.
    output logic [$clog2(ISSUE_WIDTH+1)-1:0] issue_select_count,
    output logic issue_select_any,
    output logic issue_select_two,

    // Packets To Backend
    output DecoderPacket_ decoder_packet [TOTAL_LANE_COUNT-1:0],
    output IssuerPacket_ issuer_packet [TOTAL_LANE_COUNT-1:0],
    output logic accept_vector [TOTAL_LANE_COUNT-1:0], // Forced low directly on stall/redirect.

    // Latched Producer Table Data from Decode
    input logic [UNROLLED_W-1:0] rs1_index_in [ISSUE_WIDTH-1:0],
    input logic [UNROLLED_W-1:0] rs2_index_in [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] rs1_lane_in [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] rs2_lane_in [ISSUE_WIDTH-1:0],
    input DecodeCapability_ rs1_capability_in [ISSUE_WIDTH-1:0],
    input DecodeCapability_ rs2_capability_in [ISSUE_WIDTH-1:0],

    // Buffered integer writes; committed/absorbed on the next advancing edge
    output logic [4:0] op_rd [ISSUE_WIDTH-1:0],
    output logic [LANE_WIDTH-1:0] op_lane [ISSUE_WIDTH-1:0],
    output logic op_write [ISSUE_WIDTH-1:0], // Accepted nonzero integer destination write.
    output logic [AGE_WIDTH-1:0] op_age [ISSUE_WIDTH-1:0],
    output DecodeCapability_ op_type [ISSUE_WIDTH-1:0],

    // Serial Lane Status Bit
    input logic serial_active
);

    // One advancing-cycle write buffer. Invalid slots need no payload reset.
    logic [4:0] issue_rd [ISSUE_WIDTH];
    logic [LANE_WIDTH-1:0] issue_lane [ISSUE_WIDTH];
    logic issue_write [ISSUE_WIDTH];
    logic buffer_write [ISSUE_WIDTH];
    DecodeCapability_ issue_type [ISSUE_WIDTH];
    always_comb begin
        for (int slot = 0; slot < ISSUE_WIDTH; slot++) begin
            buffer_write[slot] = issue_write[slot];
            for (int younger = slot + 1; younger < ISSUE_WIDTH; younger++)
                if (issue_write[younger] && issue_rd[younger] == issue_rd[slot])
                    buffer_write[slot] = 1'b0;
        end
    end
    always_ff @(posedge clk) begin
        if (reset || redirect_taken) begin
            op_write <= '{default: 1'b0};
        end else if (!stall) begin
            for (int slot = 0; slot < ISSUE_WIDTH; slot++) begin
                op_write[slot] <= buffer_write[slot];
                op_rd[slot] <= issue_rd[slot];
                op_lane[slot] <= issue_lane[slot];
                op_type[slot] <= issue_type[slot];
            end
        end
    end
    for (genvar slot = 0; slot < ISSUE_WIDTH; slot++) begin : buffer_age_tag
        assign op_age[slot] = AGE_WIDTH'(slot);
    end

    typedef struct packed {
        logic [UNROLLED_W-1:0] index;
        logic [LANE_WIDTH-1:0] lane;
        DecodeCapability_ capability;
    } SourceProducer_;
    SourceProducer_ corrected_1 [ISSUE_WIDTH];
    SourceProducer_ corrected_2 [ISSUE_WIDTH];
    SourceProducer_ buffered_producer [ISSUE_WIDTH];
    for (genvar slot = 0; slot < ISSUE_WIDTH; slot++) begin : buffer_payload
        assign buffered_producer[slot] = {UNROLLED_W'(0),
            op_lane[slot], op_type[slot]};
    end
    function automatic SourceProducer_ correct_source(
        input SourceProducer_ snapshot,
        input logic [ISSUE_WIDTH-1:0] source_matches
    );
        SourceProducer_ selected;
        logic matched, hit;
        selected = '0;
        matched = 1'b0;
        for (int slot = 0; slot < ISSUE_WIDTH; slot++) begin
            hit = op_write[slot] && source_matches[slot];
            selected |= {$bits(SourceProducer_){hit}} & buffered_producer[slot];
            matched |= hit;
        end
        return matched ? selected : snapshot;
    endfunction
    for (genvar slot = 0; slot < ISSUE_WIDTH; slot++) begin : source_correction
        assign corrected_1[slot] = correct_source(
            {rs1_index_in[slot], rs1_lane_in[slot], rs1_capability_in[slot]},
            rs1_buffer_match[slot]);
        assign corrected_2[slot] = correct_source(
            {rs2_index_in[slot], rs2_lane_in[slot], rs2_capability_in[slot]},
            rs2_buffer_match[slot]);
    end

    logic [UNROLLED_W-1:0] rs1_index_corrected [ISSUE_WIDTH-1:0];
    logic [LANE_WIDTH-1:0] rs1_lane_corrected [ISSUE_WIDTH-1:0];
    DecodeCapability_ rs1_capability_corrected [ISSUE_WIDTH-1:0];
    logic [UNROLLED_W-1:0] rs2_index_corrected [ISSUE_WIDTH-1:0];
    logic [LANE_WIDTH-1:0] rs2_lane_corrected [ISSUE_WIDTH-1:0];
    DecodeCapability_ rs2_capability_corrected [ISSUE_WIDTH-1:0];
    for (genvar slot = 0; slot < ISSUE_WIDTH; slot++) begin : corrected_fields
        assign rs1_index_corrected[slot] = corrected_1[slot].index;
        assign rs1_lane_corrected[slot] = corrected_1[slot].lane;
        assign rs1_capability_corrected[slot] = corrected_1[slot].capability;
        assign rs2_index_corrected[slot] = corrected_2[slot].index;
        assign rs2_lane_corrected[slot] = corrected_2[slot].lane;
        assign rs2_capability_corrected[slot] = corrected_2[slot].capability;
    end

    // Instructions Valid to Issue
    logic issue_good [ISSUE_WIDTH-1:0];

    // Early oldest eligibility does not wait for the younger readiness cone.
    // Stall/flush act on capture/effective acceptance, not candidate selection.
    assign issue_select_any = issue_good[0];
    if (ISSUE_WIDTH == 2) begin : second_selection
        assign issue_select_two = issue_good[1];
    end else begin : single_selection
        assign issue_select_two = 1'b0;
    end

    // Consumption depends only on the contract, independently of lane selection.
    always_comb begin
        issue_select_count = '0;
        for (int unsigned slot = 0; slot < ISSUE_WIDTH; slot++) begin
            issue_select_count += $clog2(ISSUE_WIDTH+1)'(issue_good[slot]);
        end
        issue_consumed = (reset || redirect_taken || stall) ? '0 : issue_select_count;
    end

    // The current lookahead allocator guarantees the contract's mask at widths 1/2.
    if (ISSUE_WIDTH > 2) begin : unsupported_direct_consumption
        initial $fatal(1, "Direct contract consumption requires an exact allocator for ISSUE_WIDTH > 2");
    end

    // Registered lookahead drives readiness; corrected producer metadata now feeds
    // forwarding payload only, independently of acceptance.
    IssueContract #(
        .ISSUE_WIDTH(ISSUE_WIDTH)
    ) issue_contract (
        .packets(packets_out),
        .lane_types(lane_types_out),
        .packets_valid(packets_valid),
        .group_raw(group_raw),
        .group_resource_bad(group_resource_bad),
        .operands_ready(operands_ready),
        .serial_active(serial_active),
        .issue_good(issue_good)
    );

    // Issue Packet Construction
    IssuerPacket_ issuer_packet_internal [ISSUE_WIDTH-1:0];
    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            issuer_packet_internal[i].input_age = AGE_WIDTH'(i);

            issuer_packet_internal[i].forward_lane_1 = rs1_lane_corrected[i];
            issuer_packet_internal[i].forward_index_1 = UNROLL_WIDTH'(rs1_index_corrected[i]);
            issuer_packet_internal[i].read_reg_file_1 = rs1_index_corrected[i] >= (EXECUTION_UNROLL+1); // in reg file next cycle
            issuer_packet_internal[i].use_bypass_1 = (rs1_index_corrected[i] == 0); // already gated by issue contract on bad cases

            issuer_packet_internal[i].forward_lane_2 = rs2_lane_corrected[i];
            issuer_packet_internal[i].forward_index_2 = UNROLL_WIDTH'(rs2_index_corrected[i]);
            issuer_packet_internal[i].read_reg_file_2 = rs2_index_corrected[i] >= (EXECUTION_UNROLL+1); // in reg file next cycle
            issuer_packet_internal[i].use_bypass_2 = (rs2_index_corrected[i] == 0); // already gated by issue contract on bad cases


        end
    end

    function automatic logic [TOTAL_LANE_COUNT-1:0] first_lane(
        input logic [TOTAL_LANE_COUNT-1:0] mask);
        logic seen;
        seen = 1'b0;
        for (int lane = 0; lane < TOTAL_LANE_COUNT; lane++) begin
            first_lane[lane] = mask[lane] && !seen;
            seen |= mask[lane];
        end
    endfunction

    // Preselect lanes from packet capabilities/validity, independently of readiness.
    logic [AGE_WIDTH-1:0] index_array [TOTAL_LANE_COUNT-1:0];
    logic [TOTAL_LANE_COUNT-1:0] assigned_lanes [ISSUE_WIDTH-1:0];
    localparam int unsigned INT_LANE_MAX = 1 + Parameters::INTEGER_LANE_COUNT;
    localparam int unsigned MEM_LANE_MAX = INT_LANE_MAX + Parameters::MEMORY_LANE_COUNT;
    always_comb begin
        logic [TOTAL_LANE_COUNT-1:0] compatible [ISSUE_WIDTH-1:0];
        logic [TOTAL_LANE_COUNT-1:0] used_lanes;

        used_lanes = '0;
        index_array = '{default: 'x};
        issue_lane = '{default: 'x};

        for (int unsigned slot = 0; slot < ISSUE_WIDTH; slot++) begin
            compatible[slot] = '0;
            case (packets_out[slot].common.capability)
                CAP_SYSTEM, CAP_CSR: compatible[slot][0] = 1'b1;
                CAP_ALU, CAP_BRU, CAP_MUL, CAP_DIV: begin
                    for (int unsigned lane = 0; lane < Parameters::INTEGER_LANE_COUNT; lane++) begin
                        case (packets_out[slot].common.capability)
                            CAP_ALU: compatible[slot][lane+1] = DerivedParameters::EFFECTIVE_INTEGER_CAPS[lane][0];
                            CAP_BRU: compatible[slot][lane+1] = DerivedParameters::EFFECTIVE_INTEGER_CAPS[lane][1];
                            CAP_MUL: compatible[slot][lane+1] = DerivedParameters::EFFECTIVE_INTEGER_CAPS[lane][2];
                            CAP_DIV: compatible[slot][lane+1] = DerivedParameters::EFFECTIVE_INTEGER_CAPS[lane][3];
                            default: ;
                        endcase
                    end
                end
                CAP_MEMORY, CAP_ATOMIC: begin
                    for (int unsigned lane = 0; lane < Parameters::MEMORY_LANE_COUNT; lane++) begin
                        compatible[slot][INT_LANE_MAX+lane] = DerivedParameters::EFFECTIVE_MEMORY_CAPS[lane]
                            [2'(packets_out[slot].common.capability == CAP_ATOMIC)];
                    end
                end
                CAP_FP_F, CAP_FP_CONVERT: begin
                    for (int unsigned lane = 0; lane < Parameters::FLOATING_LANE_COUNT; lane++) begin
                        compatible[slot][MEM_LANE_MAX+lane] = DerivedParameters::EFFECTIVE_FLOATING_CAPS[lane]
                            [packets_out[slot].common.capability == CAP_FP_CONVERT];
                    end
                end
                default: ;
            endcase
            // Invalid packets can have unspecified capability; do not reserve lanes.
            if (!packets_valid[slot]) compatible[slot] = '0;
        end

        for (int unsigned slot = 0; slot < ISSUE_WIDTH; slot++) begin
            logic [TOTAL_LANE_COUNT-1:0] available, younger_lanes, preferred, chosen;

            available = compatible[slot] & ~used_lanes;
            younger_lanes = '0;
            for (int unsigned younger = 0; younger < ISSUE_WIDTH; younger++) begin
                if (younger > slot)
                    younger_lanes |= compatible[younger];
            end
            preferred = available & ~younger_lanes;
            // Priority encode both choices in parallel; late preference selects
            // one-hot results rather than feeding another priority encoder.
            chosen = (|preferred) ? first_lane(preferred) : first_lane(available);
            assigned_lanes[slot] = chosen;
            if (|chosen) begin
                for (int lane = 0; lane < TOTAL_LANE_COUNT; lane++) begin
                    if (chosen[lane]) begin
                        index_array[lane] = AGE_WIDTH'(slot);
                        issue_lane[slot] = LANE_WIDTH'(lane);
                    end
                end
                used_lanes |= chosen;
            end
        end
    end

    // The contract signs off on fixed assignments. It never steers payload muxes.
    always_comb begin
        accept_vector = '{default: 1'b0};
        for (int lane = 0; lane < TOTAL_LANE_COUNT; lane++) begin
            for (int slot = 0; slot < ISSUE_WIDTH; slot++) begin
                accept_vector[lane] |= assigned_lanes[slot][lane] && issue_good[slot];
            end
        end
        if (reset || stall || redirect_taken)
            accept_vector = '{default: 1'b0};
    end
    for (genvar i = 0; i < TOTAL_LANE_COUNT; i++) begin : gen_lane_mux
        // Remove the reserved field before lane selection so it has no mux.
        DecoderPacket_ candidates [ISSUE_WIDTH];
        for (genvar slot = 0; slot < ISSUE_WIDTH; slot++) begin : packet_candidates
            always_comb begin
                candidates[slot] = packets_out[slot];
                candidates[slot].common.next_pc = 'x;
            end
        end
        assign decoder_packet[i] = candidates[index_array[i]];
        assign issuer_packet[i] = issuer_packet_internal[index_array[i]];
    end

    // Describe each accepted instruction's producer.
    // Capture qualifying writes into the buffer; only lane payload waits for allocation.
    always_comb begin
        for (int unsigned slot = 0; slot < ISSUE_WIDTH; slot++) begin
            issue_rd[slot] = packets_out[slot].common.rd;
            issue_type[slot] = packets_out[slot].common.capability;
            // This table tracks integer registers; FP writes must not alias x registers.
            // Contract success guarantees allocation for supported widths.
            // Only lane payload waits for allocation; write enable does not.
            issue_write[slot] = issue_good[slot] && !reset && !stall && !redirect_taken &&
                packets_out[slot].common.rd_valid && !packets_out[slot].common.rd_float &&
                packets_out[slot].common.rd != 0;
        end

    end



endmodule

// may need to pipeline this. low friction addition
// Dual issue finds any available pairing; wider issue uses a lane preference heuristic.
// Older instructions retain priority when allocation fails.

// Lanes are ordered as following: example:
// 0: Serial
// 1-2: Integer
// 3: Memory
// 4: Float

// this needs to do several major things:
// - reference a producer table
// - manage producer table writes
// - maintain an issue contract
// - slot remaining instructions into lanes
// - fill out metadata
// - understand lane ids

// stall and redirect gate done here

// for the serial lane, probably just set producer table to dictate
// operand readieness at wb time and reuse existing machinary. 
// then, serial lane must maintain a single "occupied" bit.
// it is non pipelined, and uses multicycle comb execution
// plus a little counter fsm. occupied bit only blocks other
// serial lane instructions, not pipeline flow.
// ALWAYS SINGLE SERIAL LANE
// serial maybe only needs to block other serial lane instructions

// wire pops direct into frontend queue. late/bad fills in decode are ok
// this could eliminate the full dependency chain

// USE BRAMS FOR PRODUCER TABLE AND OTHER STUFF. TAKE ADVANTAGE DECODE STAGE
// TO REGISTER EVERYTHING
// POSSIBLY READ PRODUCER TABLE IN DECODE STAGE (can change though)

// at some point get chatgpt to rethink my parameter sourcing as its messy right now

// Producer metadata is read and maintained in decode alongside each packet.
// Buffered writes correct readiness/forwarding and are absorbed by decode and table.

// ENSURE REDIRECT HAS PRIORITY OVER STALL IF TIMING ALLOWS FOR IPC REASONS
// backend pipeline stages MUST NOT LATCH ON STALL
