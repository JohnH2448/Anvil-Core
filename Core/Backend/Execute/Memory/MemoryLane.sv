module MemoryLane
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned IS_MEMORY = 1,
    parameter unsigned IS_FLOAT = 1,
    parameter unsigned IS_ATOMIC = 1,
    parameter bit REGISTERED_INPUT = 1'b0,
    parameter unsigned EXECUTION_UNROLL = 1, // execution stages
    parameter unsigned BYPASS_ENABLED = 1, // worth considering for only alu, no bru
    parameter unsigned ISSUE_WIDTH = 2, // for inter slice age bits
    parameter unsigned LANE_ID = 0, // 0 is first
    parameter logic FLOAT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0] = '{default: '0},
    parameter logic INT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0] = '{default: '0}
)(

    // Standard Inputs
    input logic clk,
    input logic reset,

    // Data From Issuer
    input DecoderPacket_ decoder_packet,
    input IssuerPacket_ issuer_packet,
    input logic accept,
    input logic recovery_flush, // Applies to the frontend-registered input.

    // Integer Forwarding Inputs
    input logic [31:0] forward_data [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0], // used by all valid int forward points
    input logic forward_ready [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0], // tie all non iterative/memory points to 1 in top

    // Forwarding Outputs
    output logic [31:0] forward_data_out [EXECUTION_UNROLL:0],
    output logic forward_ready_out [EXECUTION_UNROLL:0],

    // Bypass Inputs
    input logic [31:0] bypass_data [TOTAL_LANE_COUNT-1:0],

    // Bypass Outputs
    output logic [31:0] bypass_data_out,

    // Redirect Inputs
    input logic redirect_taken [TOTAL_LANE_COUNT-1:0],
    input logic [AGE_WIDTH-1:0] redirect_age [TOTAL_LANE_COUNT-1:0],

    // Redirect Outputs
    output logic redirect_taken_out,
    output logic [AGE_WIDTH-1:0] redirect_age_out,
    output logic [31:0] redirect_pc_out,

    // Stall Controls
    // Kept separate so BackendTop's single stall OR takes every term directly.
    output logic iteration_stall_out, // Registered structural hold.
    input logic stall, // top needs to or all outs and pass an in

    // Result Broadcast
    output logic [31:0] result_data,
    output logic [4:0] result_destination,
    output logic [AGE_WIDTH-1:0] result_age, 
    // Destination and age of the instruction that enters the final slot on the
    // next advancing edge. BackendTop registers same-cycle WAW conflicts from
    // these, so no address/age compare sits on the RF write enable.
    output logic [4:0] next_result_destination,
    output logic [AGE_WIDTH-1:0] next_result_age,
    output logic result_ready, 
    output logic result_trap,

    // Register File Read Ports
    output logic [4:0] reg_address_1,
    output logic [4:0] reg_address_2,
    input logic [31:0] read_data_1,
    input logic [31:0] read_data_2,

    // LSU enqueues this AGU result on pipeline advance.
    output logic request_valid,
    output logic request_candidate, // request_valid before redirect squash.
    output logic [AGE_WIDTH-1:0] request_age,
    output logic [31:0] request_address, request_data,
    output logic [3:0] request_mask,
    output logic request_write,
    input logic response_valid, response_error,
    input logic [31:0] response_data
);
    // Reset Register
    logic reset_reg;
    always_ff @(posedge clk) begin
        if (reset) begin
            reset_reg <= 1'b1;
        end else begin
            reset_reg <= 1'b0;
        end
    end


    logic reset_active;
    assign reset_active = reset || reset_reg;
    DecoderPacket_ decoder_payload [1:0];
    IssuerPacket_ issuer_payload [1:0];
    logic valid_payload [1:0];
    logic operand_present;
    logic operand_stall, any_redirect, stage_2_flush;

    always_comb begin
        any_redirect = 1'b0;
        stage_2_flush = 1'b0;
        foreach (redirect_taken[i]) begin
            any_redirect |= redirect_taken[i];
            stage_2_flush |= redirect_taken[i] && redirect_age[i] < issuer_payload[1].input_age;
        end
    end

    // Issue only accepts operations this lane supports, so presence is the accept
    // flop alone. This keeps the packet decode out of operand_present and stall.
    wire input_valid = accept;
    if (REGISTERED_INPUT) begin : frontend_capture
        assign decoder_payload[0] = decoder_packet;
        assign issuer_payload[0] = issuer_packet;
        assign operand_present = input_valid;
        assign valid_payload[0] = operand_present && !any_redirect && !recovery_flush;
    end else begin : local_capture
        logic captured_valid;
        assign operand_present = captured_valid;
        assign valid_payload[0] = operand_present && !any_redirect;
        always_ff @(posedge clk) begin
            if (reset_active) captured_valid <= 1'b0;
            else if (!stall) captured_valid <= input_valid && !any_redirect;
            if (!stall) begin
                decoder_payload[0] <= decoder_packet;
                issuer_payload[0] <= issuer_packet;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset_active) valid_payload[1] <= 0;
        else if (!stall) valid_payload[1] <= valid_payload[0];
        if (!stall) begin
            decoder_payload[1] <= decoder_payload[0];
            issuer_payload[1] <= issuer_payload[0];
        end
    end

    // Forwarding Decision and Stall Logic
    // Registered forwarding comes only from integer and memory lanes at indices
    // 1..EXECUTION_UNROLL. Index 0 is bypass. Serial lane 0 never forwards, by
    // design, to limit routing. Floating lanes forward only among themselves.
    // At unroll 1 the index field is ignored, so each source is a lane-select only.
    logic [31:0] forward_data_1;
    logic [31:0] forward_data_2;
    logic forward_ready_1, forward_ready_2;
    always_comb begin
        forward_data_1 = 'x;
        forward_data_2 = 'x;
        forward_ready_1 = 1'bx; // Unmatched is structurally impossible.
        forward_ready_2 = 1'bx;
        for (int lane = 1; lane <= Parameters::INTEGER_LANE_COUNT + Parameters::MEMORY_LANE_COUNT; lane++) begin
            for (int index = 1; index <= EXECUTION_UNROLL; index++) begin
                if (issuer_payload[0].forward_lane_1 == LANE_WIDTH'(lane) &&
                    (EXECUTION_UNROLL == 1 || issuer_payload[0].forward_index_1 == UNROLL_WIDTH'(index))) begin
                    forward_data_1 = forward_data[lane][index];
                    forward_ready_1 = forward_ready[lane][index];
                end
                if (issuer_payload[0].forward_lane_2 == LANE_WIDTH'(lane) &&
                    (EXECUTION_UNROLL == 1 || issuer_payload[0].forward_index_2 == UNROLL_WIDTH'(index))) begin
                    forward_data_2 = forward_data[lane][index];
                    forward_ready_2 = forward_ready[lane][index];
                end
            end
        end
    end
    always_comb begin
        operand_stall =
            (decoder_payload[0].common.rs1_valid &&
             !issuer_payload[0].read_reg_file_1 &&
             !(BYPASS_ENABLED && issuer_payload[0].use_bypass_1) &&
             !forward_ready_1) ||
            (decoder_payload[0].common.rs2_valid &&
             !issuer_payload[0].read_reg_file_2 &&
             !(BYPASS_ENABLED && issuer_payload[0].use_bypass_2) &&
             !forward_ready_2);
    end

    // Bypass Data Selection
    logic [31:0] bypass_data_1;
    logic [31:0] bypass_data_2;
    if (BYPASS_ENABLED) begin : gen_bypass_selection
        always_comb begin
            bypass_data_1 = bypass_data[issuer_payload[0].forward_lane_1];
            bypass_data_2 = bypass_data[issuer_payload[0].forward_lane_2];
        end
    end else begin : gen_no_bypass_selection
        assign bypass_data_1 = 'x;
        assign bypass_data_2 = 'x;
    end

    // Register File Read Stage
    logic [31:0] file_data_1;
    logic [31:0] file_data_2;
    always_comb begin
        reg_address_1 = decoder_payload[0].common.rs1;
        reg_address_2 = decoder_payload[0].common.rs2;
        file_data_1 = read_data_1;
        file_data_2 = read_data_2;
    end

    // Source Muxing
    logic [31:0] temp_source_1;
    logic [31:0] temp_source_2;
    always_comb begin
        temp_source_1 = forward_data_1;
        temp_source_2 = forward_data_2;
        if (issuer_payload[0].read_reg_file_1) begin
            temp_source_1 = file_data_1;
        end
        if (issuer_payload[0].read_reg_file_2) begin
            temp_source_2 = file_data_2;
        end
        if (BYPASS_ENABLED) begin
            if (issuer_payload[0].use_bypass_1 != '0) begin
                temp_source_1 = bypass_data_1;
            end
            if (issuer_payload[0].use_bypass_2 != '0) begin
                temp_source_2 = bypass_data_2;
            end
        end
        // Invalid integer sources represent x0 or an unused operand. Decode
        // leaves their register numbers unspecified; neither may read garbage.
        if (!decoder_payload[0].common.rs1_valid) temp_source_1 = '0;
        if (!decoder_payload[0].common.rs2_valid) temp_source_2 = '0;
    end

    // Operand Selection Stage
    logic [31:0] source_1;
    logic [31:0] source_2;
    always_ff @(posedge clk) begin
        if (!stall) begin
            source_1 <= temp_source_1;
            source_2 <= temp_source_2;
        end
    end


    // AGU. Stage 1 operands produce a registered bus request in execution slot 1.
    typedef struct packed {
        logic valid, done, trap, store, rd_valid, sign_extend;
        logic ready; // Registered forwarding readiness of this slot.
        logic pending; // Registered valid && !done.
        MemorySize_ size;
        logic [4:0] rd;
        logic [AGE_WIDTH-1:0] age;
        logic [1:0] offset;
        logic [31:0] data;
    } Slot;
    logic [31:0] effective_address;
    Slot agu;
    Slot slots [EXECUTION_UNROLL:1];
    Slot updated [EXECUTION_UNROLL:1];
    always_comb begin
        effective_address = source_1 + decoder_payload[1].common.immediate;
        agu.size = decoder_payload[1].memory.size;
        agu.trap = decoder_payload[1].common.trap_type != NONE ||
            (agu.size == MEM_HALF && effective_address[0]) ||
            (agu.size == MEM_WORD && |effective_address[1:0]);
        agu.valid = valid_payload[1] && !stage_2_flush;
        agu.offset = effective_address[1:0];
        agu.done = agu.trap;
        agu.ready = 1'b0;
        agu.pending = 1'b0;
        agu.data = 'x;
        agu.age = issuer_payload[1].input_age;
        agu.rd = decoder_payload[1].common.rd;
        agu.rd_valid = decoder_payload[1].common.rd_valid;
        agu.store = decoder_payload[1].memory.operation == MEM_STORE;
        agu.sign_extend = decoder_payload[1].memory.sign_extend;
    end

    assign request_valid = agu.valid && !agu.trap && !reset_active;
    // Independent of the same-cycle redirect. Redirect kills only the youngest
    // part of a group, so surviving candidates keep their candidate rank.
    assign request_candidate = valid_payload[1] && !agu.trap && !reset_active;
    assign request_age = agu.age;
    assign request_address = {effective_address[31:2], 2'b00};
    assign request_data = source_2 << {agu.offset, 3'b000};
    assign request_write = agu.store;
    always_comb begin
        case (agu.size)
            MEM_BYTE: request_mask = 4'b0001 << agu.offset;
            MEM_HALF: request_mask = 4'b0011 << agu.offset;
            MEM_WORD: request_mask = 4'b1111;
            default: request_mask = 'x;
        endcase
    end

    // Responses are ordered. The oldest unfinished slot in this lane owns its next response.
    logic [EXECUTION_UNROLL:0] older_pending;
    assign older_pending[EXECUTION_UNROLL] = 1'b0;
    // Complete the current owner before shifting it, including under global stall.
    assign forward_data_out[0] = 'x;
    assign forward_ready_out[0] = 1'b0;
    for (genvar i = 1; i <= EXECUTION_UNROLL; i++) begin : execution
        logic [31:0] shifted;
        assign shifted = response_data >> {slots[i].offset, 3'b000};
        wire pending = slots[i].valid && !slots[i].done;
        assign older_pending[i-1] = older_pending[i] || pending;
        always_comb begin
            updated[i] = slots[i];
            if (response_valid && pending && !older_pending[i]) begin
                updated[i].done = 1'b1;
                updated[i].trap = response_error;
                case (slots[i].size)
                    MEM_BYTE: updated[i].data = {{24{slots[i].sign_extend && shifted[7]}}, shifted[7:0]};
                    MEM_HALF: updated[i].data = {{16{slots[i].sign_extend && shifted[15]}}, shifted[15:0]};
                    MEM_WORD: updated[i].data = shifted;
                    default: updated[i].data = 'x;
                endcase
            end
        end
        Slot incoming, next_slot;
        if (i == 1) assign incoming = agu;
        else assign incoming = updated[i-1];
        // Readiness is computed from the next slot state so consumers see a flop.
        // Both candidates are evaluated first; late global stall only selects.
        always_comb begin
            Slot held, shifted_in;
            held = updated[i];
            shifted_in = incoming;
            held.ready = held.valid && held.done && !held.store && held.rd_valid && !held.trap;
            shifted_in.ready = shifted_in.valid && shifted_in.done && !shifted_in.store &&
                shifted_in.rd_valid && !shifted_in.trap;
            held.pending = held.valid && !held.done;
            shifted_in.pending = shifted_in.valid && !shifted_in.done;
            next_slot = stall ? held : shifted_in;
        end
        always_ff @(posedge clk) begin
            if (reset_active) begin
                slots[i].valid <= 1'b0;
                slots[i].ready <= 1'b0;
                slots[i].pending <= 1'b0;
            end else slots[i] <= next_slot;
        end
        assign forward_data_out[i] = slots[i].data;
        assign forward_ready_out[i] = slots[i].ready;
    end

    Slot last;
    assign last = slots[EXECUTION_UNROLL];
    // Operand waits are no longer formed here: Issue precomputes per-slot watch
    // bits and BackendTop combines them with forward_ready. The equivalent local
    // condition is operand_present && operand_stall.
    // Unfinished memory operation at the final slot, as a direct flop.
    assign iteration_stall_out = last.pending;
    assign result_data = last.data;
    assign result_destination = last.rd;
    assign result_age = last.age;
    // The final slot loads its predecessor on an advancing edge; rd and age never
    // change while held. At unroll 1 the predecessor is the AGU stage.
    if (EXECUTION_UNROLL == 1) begin : next_from_agu
        assign next_result_destination = agu.rd;
        assign next_result_age = agu.age;
    end else begin : next_from_slot
        assign next_result_destination = slots[EXECUTION_UNROLL-1].rd;
        assign next_result_age = slots[EXECUTION_UNROLL-1].age;
    end
    assign result_trap = last.valid && last.trap;
    // The registered ready bit is exactly a successful, completed load with rd.
    // RF writes are idempotent while held, so no stall term.
    assign result_ready = last.ready;
    assign bypass_data_out = 'x;
    assign redirect_taken_out = 1'b0;
    assign redirect_age_out = 'x;
    assign redirect_pc_out = 'x;
endmodule
