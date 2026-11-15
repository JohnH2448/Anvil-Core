module IssueContract
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned ISSUE_WIDTH = 2,
    parameter unsigned EXECUTION_UNROLL = Parameters::EXECUTION_UNROLL,
    parameter unsigned DIVIDER_AUTO_PIPE = Parameters::DIVIDER_AUTO_PIPE,
    parameter unsigned BYPASS_ENABLED = 1,
    parameter unsigned INTEGER_LANE_COUNT = 2,
    parameter unsigned MEMORY_LANE_COUNT = 1,
    parameter unsigned FLOATING_LANE_COUNT = 1,
    parameter unsigned SUPPORT_MUL = Parameters::SUPPORT_MUL,
    parameter unsigned SUPPORT_DIV = Parameters::SUPPORT_DIV,
    parameter unsigned SUPPORT_FLOAT = Parameters::SUPPORT_FLOAT,
    parameter unsigned SUPPORT_ATOMIC = Parameters::SUPPORT_ATOMIC
)(
    // Input Metadata
    input DecoderPacket_ packets [ISSUE_WIDTH-1:0],
    input LaneType_ lane_types [ISSUE_WIDTH-1:0],
    input logic packets_valid [ISSUE_WIDTH-1:0],
    input logic group_raw [ISSUE_WIDTH-1:0],
    input logic group_serial [ISSUE_WIDTH-1:0],
    input logic group_resource_bad [ISSUE_WIDTH-1:0],
    input logic serial_active,

    // Producer Table Recipient Data
    input logic [UNROLLED_W-1:0] rs1_index [ISSUE_WIDTH-1:0],
    input logic [UNROLLED_W-1:0] rs2_index [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] rs1_lane [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] rs2_lane [ISSUE_WIDTH-1:0],
    input DecodeCapability_ rs1_capability [ISSUE_WIDTH-1:0],
    input DecodeCapability_ rs2_capability [ISSUE_WIDTH-1:0],

    // Valid to Issue
    output logic issue_good [ISSUE_WIDTH-1:0]
);

    // Combined + Masked Authoritative Goods
    logic issue_good_internal [ISSUE_WIDTH-1:0];

    // Cause Specific Per Index
    logic bad_bypass [ISSUE_WIDTH-1:0];
    logic bad_raw [ISSUE_WIDTH-1:0];
    logic bad_valid [ISSUE_WIDTH-1:0];
    logic bad_operand [ISSUE_WIDTH-1:0];
    logic bad_execution_unit [ISSUE_WIDTH-1:0];
    logic bad_serial [ISSUE_WIDTH-1:0];

    // Producer position 0 is operand select now. It reaches execute while
    // this consumer selects operands next cycle, requiring ALU bypass.
    // Positions >= 1 use registered forwarding or the register file.
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
                        bad_bypass_1[i] = '0;
                    end else begin
                        bad_bypass_1[i] |= '1;
                    end
                end else begin
                    bad_bypass_1[i] |= '1;
                end
            end
            if (packets[i].common.rs2_valid && rs2_index[i] == '0) begin
                if (BYPASS_ENABLED) begin
                    if (rs2_capability[i] == CAP_ALU) begin
                        bad_bypass_2[i] = '0;
                    end else begin
                        bad_bypass_2[i] |= '1;
                    end
                end else begin
                    bad_bypass_2[i] |= '1;
                end
            end
            bad_bypass[i] = bad_bypass_1[i] || bad_bypass_2[i];
        end
    end

    // Decode latches same-group hazards alongside the selected FIFO packets.
    assign bad_raw = group_raw;

    // Valid Check
    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            bad_valid[i] = !packets_valid[i];
        end
    end

    // Readiness is a constant position threshold for each producer capability.
    // This replaces the redundant decrementing counter; backend variable-latency
    // completion still controls global advancement. Bypass remains a separate check.
    localparam int unsigned RF_INDEX = EXECUTION_UNROLL + 2;
    localparam int unsigned MUL_READY_INDEX = EXECUTION_UNROLL < 2 ? EXECUTION_UNROLL : 2;
    localparam int unsigned DIV_RESULT_POSITION = (32 + DIVIDER_AUTO_PIPE - 1) / DIVIDER_AUTO_PIPE + 3;
    localparam int unsigned DIV_READY_INDEX = EXECUTION_UNROLL < (DIV_RESULT_POSITION - 1)
        ? EXECUTION_UNROLL : (DIV_RESULT_POSITION - 1);

    function automatic logic producer_ready(
        input logic [UNROLLED_W-1:0] index,
        input DecodeCapability_ capability
    );
        // Reset/RF entries have unspecified capability, but must always be ready.
        if (index >= UNROLLED_W'(RF_INDEX)) return 1'b1;
        case (capability)
            CAP_ALU: return 1'b1;
            CAP_BRU, CAP_MEMORY: return index >= UNROLLED_W'(1);
            CAP_MUL: return index >= UNROLLED_W'(MUL_READY_INDEX);
            CAP_DIV: return index >= UNROLLED_W'(DIV_READY_INDEX);
            CAP_SYSTEM, CAP_CSR: return index >= UNROLLED_W'(EXECUTION_UNROLL + 1);
            default: return index >= UNROLLED_W'(EXECUTION_UNROLL);
        endcase
    endfunction

    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            bad_operand[i] =
                (packets[i].common.rs1_valid && !producer_ready(rs1_index[i], rs1_capability[i])) ||
                (packets[i].common.rs2_valid && !producer_ready(rs2_index[i], rs2_capability[i]));
        end
    end

    // Static resource feasibility is registered with the Decode group.
    assign bad_execution_unit = group_resource_bad;

    // Only live serial occupancy remains in this stage; pair conflicts were
    // computed before Decode's FIFO latch.
    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            bad_serial[i] = group_serial[i] ||
                (serial_active && (packets[i].common.capability inside {CAP_SYSTEM, CAP_CSR}));
        end
    end

    // Final Acceptance Mask Build
    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            issue_good_internal[i] = !(bad_bypass[i] || bad_raw[i] ||
                bad_valid[i] || bad_execution_unit[i] || bad_operand[i] ||
                bad_serial[i]);
        end
    end 

    always_comb begin
        logic prefix_good;
        prefix_good = 1'b1;
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            prefix_good = prefix_good && issue_good_internal[i];
            issue_good[i] = prefix_good;
        end
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
