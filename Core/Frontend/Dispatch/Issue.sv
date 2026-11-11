module Issuer 
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
    import Parameters::*;
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

    // Consumption To Frontend
    output logic [$clog2(ISSUE_WIDTH+1)-1:0] issue_consumed,

    // Packets To Backend
    output DecoderPacket_ decoder_packet [TOTAL_LANE_COUNT-1:0],
    output IssuerPacket_ issuer_packet [TOTAL_LANE_COUNT-1:0],
    output logic accept_vector [TOTAL_LANE_COUNT-1:0],

    // Producer Table Reads
    output logic [4:0] rs1 [ISSUE_WIDTH-1:0],
    output logic [4:0] rs2 [ISSUE_WIDTH-1:0],

    // Producer Table Recipient Data
    input logic [UNROLLED_W-1:0] rs1_index [ISSUE_WIDTH-1:0],
    input logic [UNROLLED_W-1:0] rs2_index [ISSUE_WIDTH-1:0],
    input logic [UNROLLED_W-1:0] rs1_countdown [ISSUE_WIDTH-1:0],
    input logic [UNROLLED_W-1:0] rs2_countdown [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] rs1_lane [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] rs2_lane [ISSUE_WIDTH-1:0],
    input DecodeCapability_ rs1_capability [ISSUE_WIDTH-1:0],
    input DecodeCapability_ rs2_capability [ISSUE_WIDTH-1:0],

    // Producer Table Writes
    output logic [4:0] op_rd [ISSUE_WIDTH-1:0],
    output logic [LANE_WIDTH-1:0] op_lane [ISSUE_WIDTH-1:0],
    output logic op_accept [ISSUE_WIDTH-1:0], // gate on if wb or not
    output logic [AGE_WIDTH-1:0] op_age [ISSUE_WIDTH-1:0],
    output DecodeCapability_ op_type [ISSUE_WIDTH-1:0],
    output logic op_wb [ISSUE_WIDTH-1:0],

    // Serial Lane Status Bit
    input logic serial_active
);

    // Producer Table Reads
    for (genvar i = 0; i < ISSUE_WIDTH; i++) begin : gen_prod_table_addr
        assign rs1[i] = packets_out[i].common.rs1;
        assign rs2[i] = packets_out[i].common.rs2;
    end

    // Instructions Valid to Issue
    logic issue_good [ISSUE_WIDTH-1:0];

    IssueContract #(
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .BYPASS_ENABLED(BYPASS_ENABLED),
        .INTEGER_LANE_COUNT(Parameters::INTEGER_LANE_COUNT),
        .MEMORY_LANE_COUNT(Parameters::MEMORY_LANE_COUNT),
        .FLOATING_LANE_COUNT(Parameters::FLOATING_LANE_COUNT),
        .SUPPORT_MUL(Parameters::SUPPORT_MUL),
        .SUPPORT_DIV(Parameters::SUPPORT_DIV),
        .SUPPORT_FLOAT(Parameters::SUPPORT_FLOAT),
        .SUPPORT_ATOMIC(Parameters::SUPPORT_ATOMIC)
    ) issue_contract (
        .redirect_taken(redirect_taken),
        .stall(stall),
        .packets(packets_out),
        .lane_types(lane_types_out),
        .packets_valid(packets_valid),
        .serial_active(serial_active),
        .rs1_index(rs1_index),
        .rs2_index(rs2_index),
        .rs1_countdown(rs1_countdown),
        .rs2_countdown(rs2_countdown),
        .rs1_lane(rs1_lane),
        .rs2_lane(rs2_lane),
        .rs1_capability(rs1_capability),
        .rs2_capability(rs2_capability),
        .issue_good(issue_good)
    );

    // Issue Packet Construction
    IssuerPacket_ issuer_packet_internal [ISSUE_WIDTH-1:0];
    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            issuer_packet_internal[i].input_age = i;

            issuer_packet_internal[i].forward_lane_1 = rs1_lane[i];
            issuer_packet_internal[i].forward_index_1 = UNROLL_WIDTH'(rs1_index[i]);
            issuer_packet_internal[i].read_reg_file_1 = rs1_index[i] >= (EXECUTION_UNROLL+1); // in reg file next cycle
            issuer_packet_internal[i].use_bypass_1 = (rs1_index[i] == 0); // already gated by issue contract on bad cases

            issuer_packet_internal[i].forward_lane_2 = rs2_lane[i];
            issuer_packet_internal[i].forward_index_2 = UNROLL_WIDTH'(rs2_index[i]);
            issuer_packet_internal[i].read_reg_file_2 = rs2_index[i] >= (EXECUTION_UNROLL+1); // in reg file next cycle
            issuer_packet_internal[i].use_bypass_2 = (rs2_index[i] == 0); // already gated by issue contract on bad cases

        end
    end

    // Lane Selection
    logic [AGE_WIDTH-1:0] index_array [TOTAL_LANE_COUNT-1:0];
    localparam int unsigned INT_LANE_MAX = 1 + INTEGER_LANE_COUNT;
    localparam int unsigned MEM_LANE_MAX = INT_LANE_MAX + MEMORY_LANE_COUNT;
    always_comb begin
        logic [TOTAL_LANE_COUNT-1:0] compatible [ISSUE_WIDTH-1:0];
        logic [TOTAL_LANE_COUNT-1:0] used_lanes;
        logic stop_issue;

        used_lanes = '0;
        stop_issue = reset || stall || redirect_taken;
        index_array = '{default: 'x};
        accept_vector = '{default: 1'b0};

        for (int unsigned slot = 0; slot < ISSUE_WIDTH; slot++) begin
            compatible[slot] = '0;
            case (packets_out[slot].common.capability)
                CAP_SYSTEM, CAP_CSR: compatible[slot][0] = 1'b1;
                CAP_ALU, CAP_BRU, CAP_MUL, CAP_DIV: begin
                    for (int lane = 0; lane < INTEGER_LANE_COUNT; lane++) begin
                        case (packets_out[slot].common.capability)
                            CAP_ALU: compatible[slot][lane+1] = INTEGER_LANE_CAPABILITIES[lane][0];
                            CAP_BRU: compatible[slot][lane+1] = INTEGER_LANE_CAPABILITIES[lane][1];
                            CAP_MUL: compatible[slot][lane+1] = INTEGER_LANE_CAPABILITIES[lane][2];
                            CAP_DIV: compatible[slot][lane+1] = INTEGER_LANE_CAPABILITIES[lane][3];
                            default: ;
                        endcase
                    end
                end
                CAP_MEMORY, CAP_ATOMIC: begin
                    for (int lane = 0; lane < MEMORY_LANE_COUNT; lane++) begin
                        compatible[slot][INT_LANE_MAX+lane] = MEMORY_LANE_CAPABILITIES[lane]
                            [packets_out[slot].common.capability == CAP_ATOMIC];
                    end
                end
                CAP_FP_F, CAP_FP_CONVERT: begin
                    for (int lane = 0; lane < FLOATING_LANE_COUNT; lane++) begin
                        compatible[slot][MEM_LANE_MAX+lane] = FLOATING_LANE_CAPABILITIES[lane]
                            [packets_out[slot].common.capability == CAP_FP_CONVERT];
                    end
                end
                default: ;
            endcase
        end

        for (int unsigned slot = 0; slot < ISSUE_WIDTH; slot++) begin
            logic [TOTAL_LANE_COUNT-1:0] available, younger_lanes, preferred;
            int selected_lane;

            available = compatible[slot] & ~used_lanes;
            younger_lanes = '0;
            for (int unsigned younger = 0; younger < ISSUE_WIDTH; younger++) begin
                if (younger > slot && issue_good[younger])
                    younger_lanes |= compatible[younger];
            end
            preferred = available & ~younger_lanes;
            if (preferred == '0) preferred = available;

            selected_lane = -1;
            for (int lane = 0; lane < TOTAL_LANE_COUNT; lane++) begin
                if (selected_lane == -1 && preferred[lane]) selected_lane = lane;
            end

            if (!stop_issue && issue_good[slot] && selected_lane != -1) begin
                index_array[selected_lane] = AGE_WIDTH'(slot);
                accept_vector[selected_lane] = 1'b1;
                used_lanes[selected_lane] = 1'b1;
                if (packets_out[slot].common.capability inside {CAP_SYSTEM, CAP_CSR})
                    stop_issue = 1'b1;
            end else begin
                stop_issue = 1'b1;
            end
        end
    end
    for (genvar i = 0; i < TOTAL_LANE_COUNT; i++) begin : gen_lane_mux
        assign decoder_packet[i] = accept_vector[i] ? packets_out[index_array[i]] : 'x;
        assign issuer_packet[i] = accept_vector[i] ? issuer_packet_internal[index_array[i]] : 'x;
    end

    // Count actual accepts and record each accepted instruction's producer.
    always_comb begin
        issue_consumed = '0;
        for (int unsigned slot = 0; slot < ISSUE_WIDTH; slot++) begin
            op_rd[slot] = packets_out[slot].common.rd;
            op_lane[slot] = '0;
            op_accept[slot] = 1'b0;
            op_age[slot] = AGE_WIDTH'(slot);
            op_type[slot] = packets_out[slot].common.capability;
            op_wb[slot] = packets_out[slot].common.rd_valid;
        end
        for (int unsigned lane = 0; lane < TOTAL_LANE_COUNT; lane++) begin
            if (accept_vector[lane]) begin
                issue_consumed++;
                op_lane[index_array[lane]] = LANE_WIDTH'(lane);
                op_accept[index_array[lane]] = 1'b1;
            end
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
