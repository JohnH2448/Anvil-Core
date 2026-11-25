// Sole serial lane (lane 0): CSR and SYSTEM instructions, plus every
// frontend-trapped memory instruction (Decode reroutes those here so the
// memory lane never carries a pre-bus trap). It is lockstep with every other
// lane and has the same stage numbering as IntegerLane (stage 0 operand latch,
// stage 1 first execution stage, final slot EXECUTION_UNROLL+1). It has no
// forwarding in or out, no bypass and no internal forwarding. Its only operand
// is rs1, read from the register file (Decode makes CSR consumers RF-only).
// Consumers of a serial result read the register file.
//
// CSR instructions (CSRRW/CSRRS/CSRRC and the immediate forms) read the old
// value at the final slot and write the new one on the edge the instruction
// retires. Only one serial instruction can be in a group and they stay in
// order, so a final-slot read always sees every older write.
//
// Flushing operations: traps, MRET and FENCE.I raise result_trap at the final
// slot, so BackendTop flushes the whole backend at writeback. MRET, FENCE
// and FENCE.I still retire. FENCE and FENCE.I refetch PC + 4, so every
// younger instruction executes after every older one has completed (Decode
// also stops admitting after them). Memory is already in order through one
// LSU; the drain is what orders CSR reads such as time (device input) and
// writeback-time effects against younger loads and stores. WFI is a no-op,
// which the spec permits.
//
// Trap entry and MRET run one cycle after writeback, from BackendTop's trap
// skid buffers (the trap_entry_* inputs). The trap edge has already flushed
// every lane, so no CSR instruction can commit in that cycle. That cycle
// writes mepc/mcause/mstatus/mip and drives trap_target, the frontend
// redirect PC, from flops only.
module SerialLane
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter bit REGISTERED_INPUT = 1'b0,
    parameter unsigned EXECUTION_UNROLL = 1, // execution stages
    parameter unsigned ISSUE_WIDTH = 2, // for inter slice age bits
    parameter unsigned RETIRE_WIDTH = 2 // width of the per-cycle retire counts
)(
    input logic clk,
    input logic reset,

    // Data From Issuer
    input DecoderPacket_ decoder_packet,
    input IssuerPacket_ issuer_packet,
    input logic accept,
    input logic recovery_flush, // Applies to the frontend-registered input.
    input logic trap_flush, // Writeback trap: clears every valid bit on this edge.

    // Redirect Inputs (kill younger work exactly like the other lanes)
    input logic redirect_taken [TOTAL_LANE_COUNT-1:0],
    input logic [AGE_WIDTH-1:0] redirect_age [TOTAL_LANE_COUNT-1:0],

    // Stall Controls
    output logic iteration_stall_out,
    input logic stall,

    // Register File Read Port (rs1 only)
    output logic [4:0] reg_address_1,
    input logic [31:0] read_data_1,

    // Retirement from BackendTop's writeback logic.
    // retire_edge: the final-slot group retires on this edge ((!stall || trap) && !reset).
    // retire_self: this lane's final-slot instruction retires if the edge fires
    //   (valid, not trapping, not killed by an older trap; MRET retires).
    // retire_count: final-slot instructions that retire if the edge fires.
    // retire_older: those of them older than this lane's instruction.
    input logic retire_edge, retire_self,
    input logic [RETIRE_WIDTH-1:0] retire_count, retire_older,

    // CLINT mtime, mirrored read-only by the Zicntr time/timeh CSRs.
    input logic [63:0] time_value,

    // Interrupt sources (from outside CoreTop).
    // timer_pending/software_pending: CLINT levels, mirrored directly by
    //   mip.MTIP/mip.MSIP as the spec requires (cleared at the source by
    //   writing mtimecmp/msip, never by trap entry).
    // interrupt/interrupt_type: a pulse of type INT_EXTERNAL sets the sticky
    //   mip.MEIP, which trap entry clears. Other pulse types are ignored.
    input logic timer_pending, software_pending,
    input logic interrupt,
    input InterruptType_ interrupt_type,
    // Highest-priority pending and enabled interrupt (NONE if none), from flops.
    // Decode tags a valid instruction with it.
    output TrapType_ interrupt_request,

    // Trap skid stage (one cycle after the writeback trap edge).
    input logic trap_entry, // The skid holds a taken trap or MRET.
    input logic trap_entry_mret,
    input logic trap_entry_fence_i,
    input TrapType_ trap_entry_type,
    input logic [31:0] trap_entry_pc,
    // Frontend redirect PC for the skid cycle: mtvec (trap), mepc (MRET),
    // PC + 4 (FENCE.I), or the instruction's own PC (an interrupt no longer
    // enabled: refetch).
    output logic [31:0] trap_target,

    // Result Broadcast (final slot)
    output logic [31:0] result_data,
    output logic [4:0] result_destination,
    output logic [AGE_WIDTH-1:0] result_age,
    output logic result_ready,
    output logic result_pending,
    output logic result_valid, // Valid final-slot instruction (for retire counting).
    output logic result_trap, // Trap, MRET or FENCE.I: all flush at writeback.
    output logic result_mret, // result_trap is an MRET (it retires).
    output logic result_fence_i, // result_trap is a FENCE or FENCE.I (it retires, refetches PC + 4).
    output TrapType_ result_trap_type,
    output logic [31:0] result_pc
);
    logic reset_reg;
    always_ff @(posedge clk) reset_reg <= reset;
    logic reset_active;
    assign reset_active = reset || reset_reg;

    localparam int unsigned LAST_EXECUTION_STAGE = EXECUTION_UNROLL + 1;

    DecoderPacket_ decoder_payload [LAST_EXECUTION_STAGE:0];
    IssuerPacket_ issuer_payload [LAST_EXECUTION_STAGE:0];
    logic valid_payload [LAST_EXECUTION_STAGE:0];
    logic [31:0] operand [LAST_EXECUTION_STAGE:1];

    logic any_redirect, stage_2_flush;
    always_comb begin
        any_redirect = 1'b0;
        stage_2_flush = 1'b0;
        foreach (redirect_taken[i]) begin
            any_redirect |= redirect_taken[i];
            stage_2_flush |= redirect_taken[i] && redirect_age[i] < issuer_payload[1].input_age;
        end
    end

    if (REGISTERED_INPUT) begin : frontend_capture
        assign decoder_payload[0] = decoder_packet;
        assign issuer_payload[0] = issuer_packet;
        assign valid_payload[0] = accept && !any_redirect && !recovery_flush;
    end else begin : local_capture
        logic captured_valid;
        assign valid_payload[0] = captured_valid && !any_redirect;
        always_ff @(posedge clk) begin
            if (reset_active) captured_valid <= 1'b0;
            else if (!stall) captured_valid <= accept && !any_redirect;
            if (!stall) begin
                decoder_payload[0] <= decoder_packet;
                issuer_payload[0] <= issuer_packet;
            end
        end
    end

    // Sole owner of validity; same kill point as IntegerLane (entry to stage 2).
    always_ff @(posedge clk) begin
        if (reset_active || trap_flush) begin
            for (int i = 1; i <= LAST_EXECUTION_STAGE; i++) valid_payload[i] <= 1'b0;
        end else if (!stall) begin
            valid_payload[1] <= valid_payload[0];
            valid_payload[2] <= valid_payload[1] && !stage_2_flush;
            for (int unsigned i = 3; i <= LAST_EXECUTION_STAGE; i++)
                valid_payload[i] <= valid_payload[i-1];
        end
    end

    // rs1 is always an RF read; an unused rs1 (immediate form, x0) reads zero.
    assign reg_address_1 = decoder_payload[0].common.rs1;
    always_ff @(posedge clk) begin
        if (!stall) begin
            operand[1] <= decoder_payload[0].common.rs1_valid ? read_data_1 : '0;
            for (int unsigned i = 2; i <= LAST_EXECUTION_STAGE; i++) operand[i] <= operand[i-1];
            for (int unsigned i = 1; i <= LAST_EXECUTION_STAGE; i++) begin
                decoder_payload[i] <= decoder_payload[i-1];
                issuer_payload[i] <= issuer_payload[i-1];
            end
        end
    end

    // Final slot.
    DecoderPacket_ last;
    assign last = decoder_payload[LAST_EXECUTION_STAGE];

    // ---------------------------------------------------------------- CSRs
    // Decode raises ILLEGAL for every CSR address outside its whitelist, so
    // only implemented or read-only-zero CSRs reach this lane.
    // mstatus: only MIE (bit 3) and MPIE (bit 7) are stored. MPP (12:11) reads
    // as machine mode (2'b11) and FS (14:13) reads zero. Everything else is zero.
    // mie/mip: only MSI (bit 3), MTI (bit 7) and MEI (bit 11) exist.
    // mip is read-only to CSR instructions. MTIP and MSIP mirror the CLINT
    // levels. MEIP is set by an external pulse and cleared when taken.
    // mtvec: direct mode only (MODE, bits 1:0, reads zero).
    // mepc: bit 0 reads zero (IALIGN = 16 with C).
    // mcause: stored as written (WLRL); trap entry writes the standard codes.
    // misa: read-only constant.
    // mscratch is writable. FS is fixed Off, so FP CSRs have no storage.
    // Whitelisted read-only-zero CSRs map to ROZ_R: zero, writes discarded.
    localparam logic [31:0] MISA_VALUE = 32'h4000_0000 | // MXL = 1 (RV32)
        (32'(Parameters::SUPPORT_ATOMIC != 0) << 0) | // A
        (32'(1) << 2) | // C
        (32'(Parameters::SUPPORT_FLOAT != 0) << 5) | // F
        (32'(1) << 8) | // I
        (32'(Parameters::SUPPORT_MUL != 0 && Parameters::SUPPORT_DIV != 0) << 12); // M
    localparam int unsigned MSI = 3, MTI = 7, MEI = 11;

    logic mstatus_mie, mstatus_mpie;
    logic [2:0] mie_bits, mip_bits; // {MEI, MTI, MSI}
    logic external_pending;
    assign mip_bits = {external_pending, timer_pending, software_pending};
    logic [31:2] mtvec_base;
    logic [31:1] mepc_value;
    logic [31:0] mcause_value, mscratch_value;

    function automatic logic [31:0] spread(input logic [2:0] bits);
        logic [31:0] value;
        value = '0;
        value[MSI] = bits[0];
        value[MTI] = bits[1];
        value[MEI] = bits[2];
        return value;
    endfunction
    function automatic logic [2:0] gather(input logic [31:0] value);
        return {value[MEI], value[MTI], value[MSI]};
    endfunction

    // 64-bit counters. mcycle/mcycleh and minstret/minstreth (and their
    // read-only cycle/cycleh/instret/instreth aliases, mapped by Decode) are
    // the low and high halves.
    logic [63:0] cycle_counter, instret_counter;

    // minstret as seen by this instruction: every older instruction retires
    // before it, including older members of its own group, which retire on
    // the same edge and are not in instret_counter yet.
    logic [63:0] instret_view;
    assign instret_view = instret_counter + 64'(retire_older);

    logic [31:0] csr_read, csr_source, csr_write;
    always_comb begin
        unique case (last.csr.index)
            MSTATUS_R: begin
                csr_read = '0;
                csr_read[3] = mstatus_mie;
                csr_read[7] = mstatus_mpie;
                csr_read[12:11] = 2'b11;
            end
            MTVEC_R: csr_read = {mtvec_base, 2'b00};
            MIP_R: csr_read = spread(mip_bits);
            MIE_R: csr_read = spread(mie_bits);
            MCYCLE_R: csr_read = cycle_counter[31:0];
            MCYCLEH_R: csr_read = cycle_counter[63:32];
            MINSTRET_R: csr_read = instret_view[31:0];
            MINSTRETH_R: csr_read = instret_view[63:32];
            MSCRATCH_R: csr_read = mscratch_value;
            MEPC_R: csr_read = {mepc_value, 1'b0};
            MCAUSE_R: csr_read = mcause_value;
            MISA_R: csr_read = MISA_VALUE;
            ROZ_R: csr_read = '0;
            // FS is fixed Off and Decode traps every FP CSR access.
            FFLAGS_R, FRM_R, FCSR_R: csr_read = '0;
            TIME_R: csr_read = time_value[31:0];
            TIMEH_R: csr_read = time_value[63:32];
        endcase
        csr_source = last.csr.use_immediate ? {27'd0, last.common.immediate[4:0]} : operand[LAST_EXECUTION_STAGE];
        csr_write = 'x;
        unique case (last.csr.operation)
            CSR_RW: csr_write = csr_source;
            CSR_RS: csr_write = csr_read | csr_source;
            CSR_RC: csr_write = csr_read & ~csr_source;
            CSR_NONE: ;
        endcase
    end

    // A CSR write commits on the edge the instruction retires. Decode clears
    // write_enable for trapped packets and for CSRRS/CSRRC with rs1/uimm = 0.
    wire commit = retire_edge && retire_self;
    wire csr_commit = commit && last.csr.write_enable;
    function automatic logic writes(input CSR_R index);
        return csr_commit && last.csr.index == index;
    endfunction

    // Trap entry from the skid. An interrupt is checked again against the
    // live mip/mie/mstatus.MIE (an older CSR write may have disabled it after
    // Decode tagged the instruction). If it is no longer enabled, nothing is
    // written and the instruction is refetched.
    logic [2:0] enabled;
    assign enabled = mstatus_mie ? mip_bits & mie_bits : 3'b000;

    logic entry_interrupt, entry_still_enabled, take_trap, take_mret;
    logic [2:0] entry_bit;
    always_comb begin
        entry_bit = '0;
        unique case (interrupt_request)
            SOFTWARE_INTERRUPT: entry_bit = 3'b001;
            TIMER_INTERRUPT: entry_bit = 3'b010;
            EXTERNAL_INTERRUPT: entry_bit = 3'b100;
            NONE, ILLEGAL, MISALIGNED_STORE, MISALIGNED_LOAD, MISALIGNED_INST, ECALL, EBREAK,
            STORE_ACCESS_FAULT, LOAD_ACCESS_FAULT, INST_ACCESS_FAULT, BUS_FAULT: ;
        endcase
        entry_interrupt = trap_entry_type inside {SOFTWARE_INTERRUPT, TIMER_INTERRUPT, EXTERNAL_INTERRUPT};
        entry_still_enabled = |enabled;
        take_mret = trap_entry && trap_entry_mret;
        take_trap = trap_entry && !trap_entry_mret && !trap_entry_fence_i &&
            (!entry_interrupt || entry_still_enabled);
    end

    // mcause encoding. BUS_FAULT (unused: memory lanes report load/store access
    // faults) keeps custom exception code 24 (24-31 are
    // designated for custom use) until per-cause bus errors exist.
    logic [31:0] entry_cause;
    always_comb begin
        entry_cause = '0;
        unique case (entry_interrupt ? interrupt_request : trap_entry_type)
            MISALIGNED_INST: entry_cause = 32'd0;
            INST_ACCESS_FAULT: entry_cause = 32'd1;
            ILLEGAL: entry_cause = 32'd2;
            EBREAK: entry_cause = 32'd3;
            MISALIGNED_LOAD: entry_cause = 32'd4;
            LOAD_ACCESS_FAULT: entry_cause = 32'd5;
            MISALIGNED_STORE: entry_cause = 32'd6;
            STORE_ACCESS_FAULT: entry_cause = 32'd7;
            ECALL: entry_cause = 32'd11; // environment call from M-mode
            BUS_FAULT: entry_cause = 32'd24;
            SOFTWARE_INTERRUPT: entry_cause = 32'h8000_0003;
            TIMER_INTERRUPT: entry_cause = 32'h8000_0007;
            EXTERNAL_INTERRUPT: entry_cause = 32'h8000_000B;
            NONE: ;
        endcase
    end

    always_comb begin
        if (trap_entry_mret) trap_target = {mepc_value, 1'b0};
        else if (trap_entry_fence_i) trap_target = trap_entry_pc + 32'd4; // FENCE.I is never compressed
        else if (entry_interrupt && !entry_still_enabled) trap_target = trap_entry_pc;
        else trap_target = {mtvec_base, 2'b00};
    end

    // Interrupt request to Decode, from flops. Standard priority: MEI, MSI, MTI.
    always_comb begin
        interrupt_request = NONE;
        if (enabled[1]) interrupt_request = TIMER_INTERRUPT;
        if (enabled[0]) interrupt_request = SOFTWARE_INTERRUPT;
        if (enabled[2]) interrupt_request = EXTERNAL_INTERRUPT;
    end

    wire external_set = interrupt && interrupt_type == INT_EXTERNAL;

    always_ff @(posedge clk) begin
        if (reset_active) begin
            mstatus_mie <= 1'b0;
            mstatus_mpie <= 1'b0;
            mie_bits <= '0;
            external_pending <= 1'b0;
            mtvec_base <= '0;
            mepc_value <= '0;
            mcause_value <= '0;
            mscratch_value <= '0;
        end else begin
            // A new external pulse wins over the clear on entry. MTIP/MSIP
            // are levels and are not touched by trap entry.
            external_pending <= (external_pending && !(take_trap && entry_bit[2])) || external_set;
            if (take_trap) begin
                mepc_value <= trap_entry_pc[31:1];
                mcause_value <= entry_cause;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie <= 1'b0;
            end else if (take_mret) begin
                mstatus_mie <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end else if (writes(MSTATUS_R)) begin
                mstatus_mie <= csr_write[3];
                mstatus_mpie <= csr_write[7];
            end
            if (writes(MIE_R)) mie_bits <= gather(csr_write);
            if (writes(MTVEC_R)) mtvec_base <= csr_write[31:2];
            if (writes(MEPC_R)) mepc_value <= csr_write[31:1];
            if (writes(MCAUSE_R)) mcause_value <= csr_write;
            if (writes(MSCRATCH_R)) mscratch_value <= csr_write;
        end
    end

    // Counters (RISC-V Zicntr/privileged spec, RV32):
    // - mcycle counts every clock cycle (mcountinhibit is not implemented and
    //   reads zero, so counting is never inhibited).
    // - minstret counts retired instructions. A trapping instruction (ECALL,
    //   EBREAK, faults, interrupt-tagged) does not retire; instructions killed
    //   by an older trap or a redirect never reach retirement. MRET and
    //   FENCE.I retire.
    // - A CSR write takes effect after the writing instruction completes: the
    //   written half replaces the counter's value, the other half is kept.
    //   For minstret, writing either half suppresses the writing
    //   instruction's own increment: the next instruction reads exactly the
    //   written value (riscv-tests instret_overflow). Older members of the
    //   group count before the write lands; younger members count after it.
    //   For mcycle the write replaces that cycle's increment.
    logic [63:0] instret_base;
    logic [RETIRE_WIDTH-1:0] retire_after;
    always_comb begin
        // Older retirements, then the write (self not counted), then the
        // younger survivors.
        instret_base = instret_view;
        if (writes(MINSTRET_R)) instret_base[31:0] = csr_write;
        if (writes(MINSTRETH_R)) instret_base[63:32] = csr_write;
        retire_after = retire_count - retire_older - RETIRE_WIDTH'(1);
    end
    always_ff @(posedge clk) begin
        if (reset_active) begin
            cycle_counter <= '0;
            instret_counter <= '0;
        end else begin
            if (writes(MCYCLE_R)) cycle_counter[31:0] <= csr_write;
            else if (writes(MCYCLEH_R)) cycle_counter[63:32] <= csr_write;
            else cycle_counter <= cycle_counter + 64'd1;
            if (writes(MINSTRET_R) || writes(MINSTRETH_R))
                instret_counter <= instret_base + 64'(retire_after);
            else if (retire_edge)
                instret_counter <= instret_counter + 64'(retire_count);
        end
    end

    assign iteration_stall_out = 1'b0;
    assign result_pending = 1'b0;
    assign result_valid = valid_payload[LAST_EXECUTION_STAGE];
    assign result_destination = last.common.rd;
    assign result_age = issuer_payload[LAST_EXECUTION_STAGE].input_age;
    assign result_data = csr_read;
    // read_enable is legality-qualified (trapped packets never write rd).
    assign result_ready = valid_payload[LAST_EXECUTION_STAGE] && last.csr.read_enable && last.common.rd_valid;
    // system.operation is legality-qualified, so a trapped packet is never MRET.
    assign result_mret = valid_payload[LAST_EXECUTION_STAGE] && last.system.operation == SYS_MRET;
    assign result_fence_i = valid_payload[LAST_EXECUTION_STAGE] &&
        last.system.operation inside {SYS_FENCE, SYS_FENCE_I};
    assign result_trap = (valid_payload[LAST_EXECUTION_STAGE] && last.common.trap_type != NONE) ||
        result_mret || result_fence_i;
    assign result_trap_type = last.common.trap_type;
    assign result_pc = last.common.pc;
endmodule
