module IssueContract
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned ISSUE_WIDTH = 2,
    parameter unsigned BYPASS_ENABLED = 1,
    parameter unsigned INTEGER_LANE_COUNT = 2,
    parameter unsigned MEMORY_LANE_COUNT = 1,
    parameter unsigned FLOATING_LANE_COUNT = 1,
    parameter unsigned SERIAL_LANE_COUNT = 1,
    parameter unsigned SUPPORT_MUL = 1
)(
    // Input Metadata
    input logic redirect_taken,
    input DecoderPacket_ packets [ISSUE_WIDTH-1:0],
    input LaneType_ lane_types [ISSUE_WIDTH-1:0],
    input logic packets_valid [ISSUE_WIDTH-1:0],
    input logic serial_active [ISSUE_WIDTH-1:0],

    // Producer Table Recipient Data
    input logic [UNROLLED_W-1:0] rs1_index [ISSUE_WIDTH-1:0],
    input logic [UNROLLED_W-1:0] rs2_index [ISSUE_WIDTH-1:0],
    input logic [UNROLLED_W-1:0] rs1_countdown [ISSUE_WIDTH-1:0],
    input logic [UNROLLED_W-1:0] rs2_countdown [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] rs1_lane [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] rs2_lane [ISSUE_WIDTH-1:0],
    input DecodeCapability_ rs1_capability [ISSUE_WIDTH-1:0],
    input DecodeCapability_ rs2_capability [ISSUE_WIDTH-1:0],

    // Valid to Issue
    output logic issue_good [ISSUE_WIDTH-1:0]
);

    // Combined + Masked Authoritative Goods
    logic issue_good_internal [ISSUE_WIDTH-1:0];
    logic bad_redirect;
    logic bad_prior_serial;

    // Cause Specific Per Index
    logic bad_bypass [ISSUE_WIDTH-1:0];
    logic bad_raw [ISSUE_WIDTH-1:0];
    logic bad_valid [ISSUE_WIDTH-1:0];
    logic bad_operand [ISSUE_WIDTH-1:0];
    logic bad_execution_unit [ISSUE_WIDTH-1:0];
    logic bad_serial [ISSUE_WIDTH-1:0];

    // Bypass Check
    always_comb begin
        logic bad_bypass_1 [ISSUE_WIDTH-1:0];
        logic bad_bypass_2 [ISSUE_WIDTH-1:0];
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            bad_bypass_1[i] = '0;
            bad_bypass_2[i] = '0;
            if (packets[i].common.rs1_valid && rs1_index[i] == '0) begin
                if (BYPASS_ENABLED) begin
                    if (rs1_capability[i] == CAP_ALU) begin
                        bad_bypass[i] = '0;
                    end else begin
                        bad_bypass[i] = '1;
                    end
                end else begin
                    bad_bypass[i] = '1;
                end
            end
            if (packets[i].common.rs2_valid && rs2_index[i] == '0) begin
                if (BYPASS_ENABLED) begin
                    if (rs2_capability[i] == CAP_ALU) begin
                        bad_bypass_2[i] = '0;
                    end else begin
                        bad_bypass_2[i] = '1;
                    end
                end else begin
                    bad_bypass_2[i] = '1;
                end
            end
            bad_bypass[i] = bad_bypass_1[i] || bad_bypass_2[i];
        end
    end

    // RAW Check
    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            logic [4:0] destination;
            destination = packets[i].common.rd;
            bad_raw[i] = '0;
            for (int unsigned k = 0; k < ISSUE_WIDTH; k++) begin
                if (k > i) begin
                    logic [4:0] source_1;
                    logic [4:0] source_2;
                    source_1 = packets[k].common.rs1;
                    source_2 = packets[k].common.rs2;
                    if (destination == source_1 || destination == source_2) begin
                        bad_raw[k] = '1;
                    end
                end
            end
        end
    end // future consideration to conditionally allow
    // careful with state on younger instuctions with rd same as older rs. not a dependency but careful

    // Valid Check
    always_comb begin
        bad_valid = !packets_valid;
    end

    // Operand Check
    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            bad_operand[i] = '0;
            if (packets[i].common.rs1_valid && rs1_countdown[i] <= '1) begin
                bad_operand[i] = '1;
            end
            if (packets[i].common.rs2_valid && rs2_countdown[i] <= '1) begin
                bad_operand[i] = '1;
            end
        end
    end

    // Execution Unit Check
    localparam int unsigned MEMORY_LANE_BASE = Parameters::INTEGER_LANE_COUNT;
    localparam int unsigned FLOATING_LANE_BASE = MEMORY_LANE_BASE + Parameters::MEMORY_LANE_COUNT;
    localparam int unsigned SERIAL_LANE_BASE = FLOATING_LANE_BASE + Parameters::FLOATING_LANE_COUNT;
    localparam logic [ISSUE_WIDTH:0] SUBSET_LIMIT = {1'b1, {ISSUE_WIDTH{1'b0}}};
    always_comb begin
        logic [TOTAL_LANE_COUNT-1:0] compatible_lanes [ISSUE_WIDTH-1:0];
        logic [ISSUE_WIDTH-1:0] accepted_slots;
        accepted_slots = '0;
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            compatible_lanes[i] = '0;
            unique case (packets[i].common.capability)
                CAP_ALU, CAP_BRU, CAP_MUL, CAP_DIV: begin
                    for (int unsigned lane = 0; lane < Parameters::INTEGER_LANE_COUNT; lane++) begin
                        if (lane < INTEGER_LANE_COUNT) begin
                            unique case (packets[i].common.capability)
                                CAP_ALU: compatible_lanes[i][lane] = Parameters::INTEGER_LANE_CAPABILITIES[lane][0];
                                CAP_BRU: compatible_lanes[i][lane] = Parameters::INTEGER_LANE_CAPABILITIES[lane][1];
                                CAP_MUL: compatible_lanes[i][lane] = SUPPORT_MUL != 0 &&
                                    Parameters::INTEGER_LANE_CAPABILITIES[lane][2];
                                CAP_DIV: compatible_lanes[i][lane] = Parameters::INTEGER_LANE_CAPABILITIES[lane][3];
                                default: ;
                            endcase
                        end
                    end
                end
                CAP_MEMORY, CAP_ATOMIC: begin
                    for (int unsigned lane = 0; lane < Parameters::MEMORY_LANE_COUNT; lane++) begin
                        if (lane < MEMORY_LANE_COUNT) begin
                            compatible_lanes[i][MEMORY_LANE_BASE + lane] =
                                Parameters::MEMORY_LANE_CAPABILITIES[lane][packets[i].common.capability == CAP_ATOMIC];
                        end
                    end
                end
                CAP_FP_F, CAP_FP_CONVERT: begin
                    for (int unsigned lane = 0; lane < Parameters::FLOATING_LANE_COUNT; lane++) begin
                        if (lane < FLOATING_LANE_COUNT) begin
                            compatible_lanes[i][FLOATING_LANE_BASE + lane] =
                                Parameters::FLOATING_LANE_CAPABILITIES[lane][packets[i].common.capability == CAP_FP_CONVERT];
                        end
                    end
                end
                CAP_SYSTEM, CAP_CSR: begin
                    for (int unsigned lane = 0; lane < Parameters::SERIAL_LANE_COUNT; lane++) begin
                        compatible_lanes[i][SERIAL_LANE_BASE + lane] = lane < SERIAL_LANE_COUNT;
                    end
                end
            endcase
        end
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            logic [ISSUE_WIDTH-1:0] candidate_slots;
            candidate_slots = accepted_slots;
            candidate_slots[i] = 1'b1;
            bad_execution_unit[i] = 1'b0;

            if (packets_valid[i]) begin
                // Older accepted slots already fit. Only subsets containing
                // this candidate can introduce a new lane conflict.
                for (logic [ISSUE_WIDTH:0] subset = 1; subset < SUBSET_LIMIT; subset++) begin
                    logic [TOTAL_LANE_COUNT-1:0] lane_union;
                    lane_union = '0;
                    if (subset[i] && (subset[ISSUE_WIDTH-1:0] & ~candidate_slots) == '0) begin
                        for (int unsigned slot = 0; slot < ISSUE_WIDTH; slot++) begin
                            if (subset[slot]) lane_union |= compatible_lanes[slot];
                        end
                        if ($countones(lane_union) < $countones(subset)) begin
                            bad_execution_unit[i] = 1'b1;
                        end
                    end
                end
                accepted_slots[i] = !bad_execution_unit[i];
            end
        end
    end

    // Bad Serial
    always_comb begin
        logic serial_detected;
        serial_detected = 1'b0;
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            bad_serial[i] = 1'b0;
            if (serial_detected) begin
                bad_serial[i] = 1'b1;
            end
            if (packets[i].common.capability == CAP_SYSTEM || packets[i].common.capability == CAP_CSR) begin
                serial_detected = 1'b1;
            end
        end

        // bitmask already applied due to structural reasons. 
    end


endmodule

// PURE COMBINATIONAL EVAL FUNCTION

// CONSIDERATIONS
// - No redirect
// - No same cycle RAW
// - Require a distinct compatible lane for each structurally accepted slot
// - process producer table and check operands
// - Only bypass on bypass enable
// - Check valid packet inputs
// - Serial concerns are unique. prob need to block all issue on seral_active bit
// - Serial also needs gate all other instructions before issuing. single issue only
// - FP hasnt been though about much here
