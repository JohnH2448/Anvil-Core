module MemoryLane
    import Parameters::*;
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned IS_MEMORY = 1,
    parameter unsigned IS_FLOAT = 1,
    parameter unsigned IS_ATOMIC = 1,
    parameter bit REGISTERED_INPUT = 1'b0,
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
    output logic result_ready,
    // Valid final-slot instruction still waiting on its result. Older pending
    // work holds back writeback-time trap assertion for a younger trap.
    output logic result_pending,
    output logic result_valid, // Valid final-slot instruction (for retire counting).
    output logic result_trap,
    // AGU fault, delivered through the LSU and classified here from the
    // slot's own size and offset: misaligned load/store if the access was
    // misaligned, otherwise load/store access fault (out of range).
    output TrapType_ result_trap_type,
    output logic [31:0] result_pc,

    // Register File Read Ports
    output logic [4:0] reg_address_1,
    output logic [4:0] reg_address_2,
    input logic [31:0] read_data_1,
    input logic [31:0] read_data_2,

    // LSU enqueues this AGU result on pipeline advance.
    output logic request_valid,
    output logic request_candidate, // request_valid before redirect squash.
    // A valid load in the AGU stage, from flops only (LSU direct-send decision).
    output logic request_early,
    // A valid memory op in the AGU stage, from flops only (LSU entry write
    // enable; the counted push still uses request_candidate).
    output logic request_present,
    output logic [AGE_WIDTH-1:0] request_age,
    output logic [31:0] request_address, request_data,
    output logic [3:0] request_mask,
    output logic request_write,
    output logic [1:0] request_size, // MemorySize_
    // AGU-detected fault (misaligned or out of range): the request is still
    // enqueued and completes through the LSU with an error, never on the bus.
    output logic request_fault,

    // Completion from the LSU: a load response, or (response_error) the
    // completion of an AGU-faulting request, with garbage data. Posted stores
    // get no completion.
    input logic wb_trap, cancel_checkin,
    input logic response_valid, response_error,
    input logic [31:0] response_data,
    // A load response for this lane is on the bus this cycle (returned
    // without the trap kill, from flops): drives the early word forward.
    input logic response_early
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

    // A writeback trap clears every valid bit on its edge, stall or not.
    always_ff @(posedge clk) begin
        if (reset_active || wb_trap) valid_payload[1] <= 0;
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
        for (int lane = 1; lane <= INTEGER_LANE_COUNT + MEMORY_LANE_COUNT; lane++) begin
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
             !(ENABLE_BYPASS && issuer_payload[0].use_bypass_1) &&
             !forward_ready_1) ||
            (decoder_payload[0].common.rs2_valid &&
             !issuer_payload[0].read_reg_file_2 &&
             !(ENABLE_BYPASS && issuer_payload[0].use_bypass_2) &&
             !forward_ready_2);
    end

    // Bypass Data Selection
    logic [31:0] bypass_data_1;
    logic [31:0] bypass_data_2;
    if (ENABLE_BYPASS) begin : gen_bypass_selection
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
        if (ENABLE_BYPASS) begin
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
    logic base_clear_q; // direct-send device check on the next source_1
    always_ff @(posedge clk) begin
        if (!stall) begin
            source_1 <= temp_source_1;
            source_2 <= temp_source_2;
            base_clear_q <= !temp_source_1[31] &&
                (temp_source_1 >= RAM_BASE + 32'd2048 ||
                 (!decoder_payload[0].common.immediate[31] && temp_source_1 >= RAM_BASE));
        end
    end


    // AGU. Stage 1 operands produce a registered bus request in execution slot 1.
    typedef struct packed {
        logic valid, done, canceled, trap, store, rd_valid, sign_extend;
        logic ready; // Registered forwarding readiness of this slot.
        logic pending; // Registered valid && !done.
        MemorySize_ size;
        logic [4:0] rd;
        logic [AGE_WIDTH-1:0] age;
        logic [1:0] offset;
        logic [31:0] data;
        logic [31:0] pc; // For trap entry (mepc).
    } Slot;
    logic [31:0] effective_address;
    // Store buffer hit for the load in the AGU stage (0 without the buffer).
    // Raw: before the same-cycle redirect squash, like request_candidate.
    logic sb_hit;
    logic [31:0] sb_load_data;
    // AGU fault check, mirroring the bus: misaligned for its size (reserved
    // size encoding included) or a word above MAX_MEMORY_ADDRESS. Every
    // architectural memory trap is known here, so stores can be posted.
    logic agu_fault;
    Slot agu;
    Slot slots [EXECUTION_UNROLL:1];
    Slot updated [EXECUTION_UNROLL:1];
    always_comb begin
        effective_address = source_1 + decoder_payload[1].common.immediate;
        agu.size = decoder_payload[1].memory.size;
        agu.store = decoder_payload[1].memory.operation == MEM_STORE;
        // Memory traps are detected here (agu_fault) but delivered through the
        // LSU as an error completion once every older request is out, so
        // the LSU locks before any younger request reaches the bus. Decode never routes a
        // frontend-trapped instruction to a memory lane.
        agu.trap = 1'b0;
        agu.valid = valid_payload[1] && !stage_2_flush;
        agu.offset = effective_address[1:0];
        // Defensive: a request presented during the LSU check-in lock is
        // canceled (a trap flush clears every older slot on the same edge).
        // A store-buffer hit completes here. A store is posted: it completes
        // once it enters the LSU, without waiting for its bus response (the bus
        // has no errors). A faulting store waits for its error completion.
        agu.done = cancel_checkin || sb_hit || (agu.store && !agu_fault);
        agu.canceled = cancel_checkin;
        agu.ready = 1'b0;
        agu.pending = 1'b0;
        agu.data = sb_hit ? sb_load_data : 'x;
        agu.age = issuer_payload[1].input_age;
        agu.pc = decoder_payload[1].common.pc;
        agu.rd = decoder_payload[1].common.rd;
        agu.rd_valid = decoder_payload[1].common.rd_valid;
        agu.sign_extend = decoder_payload[1].memory.sign_extend;
    end

    always_comb begin
        logic misaligned;
        misaligned = 1'b1;
        unique case (agu.size)
            MEM_BYTE: misaligned = 1'b0;
            MEM_HALF: misaligned = effective_address[0];
            MEM_WORD: misaligned = effective_address[1:0] != 2'b00;
        endcase
        agu_fault = misaligned || (!FULL_ADDRESS_SPACE &&
            effective_address[31:2] > MAX_MEMORY_ADDRESS[31:2]);
    end
    assign request_fault = agu_fault;

    // ------------------------------------------------------------ store buffer
    // Shift register of the last STORE_BUFFER_DEPTH aligned word stores to RAM
    // (entry 0 newest). It is a forwarding copy only: every store still goes to
    // memory through the LSU.
    //   insert      aligned word store to RAM, on the advancing edge
    //   invalidate  any other store to a buffered word (sub-word, so the
    //               buffered word would be stale)
    //   clear       writeback trap (a buffered store may have been dropped)
    //   hit         aligned load whose word is buffered (newest match wins):
    //               completed in the AGU stage, never sent to the LSU, ready
    //               for forwarding from slot 1 on the next cycle.
    // Restricting both sides to aligned in-range RAM keeps device reads
    // (side effects, volatile values) and faulting accesses on the bus.
    // Stores in the AGU stage are past every older branch (branches resolve
    // in this stage; same-group squash is in agu.valid), so no branch
    // speculation reaches the buffer.
    if (ENABLE_STORE_BUFFER && IS_MEMORY) begin : store_buffer
        localparam int unsigned DEPTH = STORE_BUFFER_DEPTH;
        initial begin
            if (MEMORY_LANE_COUNT != 1)
                $fatal(1, "MemoryLane: the store buffer requires MEMORY_LANE_COUNT = 1");
            if (DEPTH < 1)
                $fatal(1, "MemoryLane: STORE_BUFFER_DEPTH must be at least 1");
        end
        logic entry_valid [DEPTH];
        logic [29:0] entry_word [DEPTH];
        logic [31:0] entry_data [DEPTH];

        wire [29:0] word = effective_address[31:2];
        wire aligned = agu.size == MEM_BYTE ||
            (agu.size == MEM_HALF && !agu.offset[0]) ||
            (agu.size == MEM_WORD && agu.offset == 2'b00);
        // The whole word lies in RAM (the bus would reject anything else).
        wire in_ram = effective_address[31:2] >= RAM_BASE[31:2] &&
            (FULL_ADDRESS_SPACE || effective_address[31:2] <= MAX_MEMORY_ADDRESS[31:2]);
        wire usable = aligned && in_ram && !cancel_checkin;

        logic match;
        logic [31:0] match_data;
        // At most one valid entry holds a given word (an insert drops older
        // copies), so the hit data is a parallel AND-OR, not a priority chain.
        // Pending update (timing): a store registers its insert/invalidate on
        // the advancing edge together with the same-cycle branch squash
        // (stage_2_flush), and is applied on the next edge unless squashed. The
        // squash thus only reaches a flop D, not the entry enables. A load in
        // the cycle after the store checks the pending entry too, with priority
        // over the entries (it is newer than any copy there).
        logic pending_insert, pending_invalidate, pending_squashed;
        logic [29:0] pending_word;
        logic [31:0] pending_data;
        wire pending_live = !pending_squashed;
        wire pending_match = (pending_insert || pending_invalidate) && pending_live && pending_word == word;
        logic entry_match;
        logic [31:0] entry_data_or;
        always_comb begin
            entry_match = 1'b0;
            entry_data_or = '0;
            for (int i = 0; i < DEPTH; i++) begin
                logic hit_i;
                hit_i = entry_valid[i] && entry_word[i] == word;
                entry_match |= hit_i;
                entry_data_or |= {32{hit_i}} & entry_data[i];
            end
            // A pending insert wins; a pending invalidate hides the old copy.
            match = pending_match ? pending_insert : entry_match;
            match_data = (pending_match && pending_insert) ? pending_data : entry_data_or;
        end
        // Aligned word loads only (timing): the data is the buffered word as
        // is, with no byte shift or sign extension on the hit path. Sub-word
        // loads take the normal path ("usable" already requires alignment).
        assign sb_hit = valid_payload[1] && !agu.store && usable && agu.size == MEM_WORD && match;
        assign sb_load_data = match_data;

        // Raw (pre-squash) intent, captured on the advancing edge.
        wire insert_raw = valid_payload[1] && agu.store && usable && agu.size == MEM_WORD;
        wire invalidate_raw = valid_payload[1] && agu.store && !insert_raw;
        always_ff @(posedge clk) begin
            if (reset_active || wb_trap) begin
                pending_insert <= 1'b0;
                pending_invalidate <= 1'b0;
            end else if (!stall) begin
                pending_insert <= insert_raw;
                pending_invalidate <= invalidate_raw;
            end else begin
                // Applied on the first edge after capture, stalled or not.
                pending_insert <= 1'b0;
                pending_invalidate <= 1'b0;
            end
            if (!stall) begin
                pending_squashed <= stage_2_flush;
                pending_word <= word;
                pending_data <= source_2; // aligned word: no lane shift
            end
        end
        wire apply_insert = pending_insert && pending_live;
        wire apply_invalidate = pending_invalidate && pending_live;
        // One register set per entry (an insert shifts every entry by one).
        for (genvar i = 0; i < DEPTH; i++) begin : entries
            logic in_valid;
            logic [29:0] in_word;
            logic [31:0] in_data;
            if (i == 0) begin : newest
                assign in_valid = 1'b1;
                assign in_word = pending_word;
                assign in_data = pending_data;
            end else begin : older
                assign in_valid = entry_valid[i-1];
                assign in_word = entry_word[i-1];
                assign in_data = entry_data[i-1];
            end
            always_ff @(posedge clk) begin
                if (reset_active || wb_trap) begin
                    entry_valid[i] <= 1'b0;
                end else if (apply_insert) begin
                    // An insert drops the older copy of the same word (one-hot).
                    entry_valid[i] <= in_valid && (i == 0 || in_word != pending_word);
                    entry_word[i] <= in_word;
                    entry_data[i] <= in_data;
                end else if (apply_invalidate && entry_word[i] == pending_word) begin
                    entry_valid[i] <= 1'b0;
                end
            end
        end
    end else begin : no_store_buffer
        assign sb_hit = 1'b0;
        assign sb_load_data = 'x;
    end

    assign request_valid = agu.valid && !reset_active && !sb_hit;
    // Independent of the same-cycle redirect. Redirect kills only the youngest
    // part of a group, so surviving candidates keep their candidate rank.
    // Pre-squash and pre-hit (flops only). A store-buffer hit is retracted like a
    // same-cycle squash: request_valid (pending) excludes it, so the LSU counts
    // it in squashed and removes it next cycle; it is never sendable meanwhile.
    assign request_candidate = valid_payload[1] && !reset_active;
    // Direct send must never read a device (side effects on a dropped send).
    // Decided from flops only (base register and immediate, no adder): the
    // access cannot fall below RAM_BASE if the base is at least 2 KiB above it
    // (any 12-bit offset) or the offset is non-negative and the base is in
    // RAM. Bit 31 clear rules out wrap-around. Anything else uses the queue;
    // a faulting (misaligned, out-of-range) direct load is discarded and the
    // bus performs no access for it.
    // Computed in the operand stage and registered with source_1 (timing).
    wire base_clear_of_devices = base_clear_q;
    assign request_present = valid_payload[1] && !reset_active;
    assign request_early = valid_payload[1] && !reset_active &&
        decoder_payload[1].memory.operation != MEM_STORE && base_clear_of_devices;
    assign request_age = agu.age;
    // Full byte address plus size, so the bus can check alignment and range.
    assign request_address = effective_address;
    assign request_size = agu.size;
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
                if (response_error) updated[i].trap = 1'b1; // AGU fault
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
            // A faulted load still reads ready (garbage
            // data) so speculative consumers never deadlock before the trap
            // reaches writeback. Only the RF write excludes traps.
            held.ready = held.valid && held.done && !held.store && held.rd_valid;
            shifted_in.ready = shifted_in.valid && shifted_in.done && !shifted_in.store &&
                shifted_in.rd_valid;
            held.pending = held.valid && !held.done;
            shifted_in.pending = shifted_in.valid && !shifted_in.done;
            next_slot = stall ? held : shifted_in;
        end
        always_ff @(posedge clk) begin
            if (reset_active || wb_trap) begin
                slots[i].valid <= 1'b0;
                slots[i].ready <= 1'b0;
                slots[i].pending <= 1'b0;
            end else slots[i] <= next_slot;
        end
        // Early forward (load-to-use): in the cycle an aligned word load's
        // response arrives, consumers take the raw bus word, one cycle before
        // the slot registers it. Word only, so there is no shift or sign
        // extension on this path; sub-word loads forward from the slot. The
        // ready term is flops through a few gates (no trap kill: a trap cycle
        // flushes everything anyway).
        wire early_word = response_early && pending && !older_pending[i] &&
            !slots[i].store && slots[i].rd_valid &&
            slots[i].size == MEM_WORD && slots[i].offset == 2'b00;
        assign forward_data_out[i] = early_word ? response_data : slots[i].data;
        assign forward_ready_out[i] = slots[i].ready || early_word;
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
    assign result_pending = last.pending;
    assign result_valid = last.valid && !last.canceled;
    wire last_misaligned = (last.size == MEM_HALF && last.offset[0]) ||
        (last.size == MEM_WORD && last.offset != 2'b00);
    assign result_trap_type = last_misaligned ? (last.store ? MISALIGNED_STORE : MISALIGNED_LOAD) :
        (last.store ? STORE_ACCESS_FAULT : LOAD_ACCESS_FAULT);
    assign result_pc = last.pc;
    // A trap asserts only once its request has completed through the LSU, so
    // the LSU flush never drops the completion this slot is waiting for.
    assign result_trap = last.valid && last.done && !last.canceled && last.trap;
    // A completed load with rd and no trap.
    assign result_ready = last.ready && !last.canceled && !last.trap;
    assign bypass_data_out = 'x;
    assign redirect_taken_out = 1'b0;
    assign redirect_age_out = 'x;
    assign redirect_pc_out = 'x;
endmodule
