module IntegerLane
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned IS_ALU = 1,
    parameter unsigned IS_BRU = 1,
    parameter unsigned IS_MUL = 1,
    parameter unsigned IS_DIV = 1,
    parameter bit REGISTERED_INPUT = 1'b0,
    parameter unsigned EXECUTION_UNROLL = 1, // execution stages (min 1)
    parameter unsigned BYPASS_ENABLED = 1, // worth considering for only alu, no bru
    parameter unsigned ISSUE_WIDTH = 2, // for inter slice age bits
    parameter unsigned LANE_ID = 0, // 0 is first
    parameter unsigned DIVIDER_AUTO_PIPE = 3
)(
    // Standard Inputs
    input logic clk,
    input logic reset,

    // Data From Issuer
    input DecoderPacket_ decoder_packet,
    input IssuerPacket_ issuer_packet,
    input logic accept,
    input logic recovery_flush, // Applies to the frontend-registered input.
    input logic trap_flush, // Writeback trap: clears every valid bit on this edge.

    // Forwarding Inputs
    input logic [31:0] forward_data [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0], // used by all valid int forward points
    input logic forward_ready [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0], // tie all non iterative/memory points to 1 in top

    // Forwarding Outputs
    output logic [31:0] forward_data_out [EXECUTION_UNROLL:0],
    output logic forward_ready_out, // only used if iteration point exists

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
    output TrapType_ result_trap_type,
    output logic [31:0] result_pc,

    // Register File Read Ports
    output logic [4:0] reg_address_1,
    output logic [4:0] reg_address_2,
    input logic [31:0] read_data_1,
    input logic [31:0] read_data_2

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

    // Stage 0 is decode, stage 1 selects operands, execution starts at 2.
    localparam int unsigned LAST_EXECUTION_STAGE = EXECUTION_UNROLL + 1;
    localparam int unsigned MUL_RESULT_STAGE = LAST_EXECUTION_STAGE < 3 ? LAST_EXECUTION_STAGE : 3;
    // Digit stages plus the magnitude latch and the registered raw result.
    localparam int unsigned DIV_RESULT_LATENCY = (32 + DIVIDER_AUTO_PIPE - 1) / DIVIDER_AUTO_PIPE + 2;
    localparam int unsigned DIV_RESULT_STAGE = LAST_EXECUTION_STAGE < DIV_RESULT_LATENCY + 2 ?
        LAST_EXECUTION_STAGE : DIV_RESULT_LATENCY + 2;
    localparam bit MUL_ITERATES = EXECUTION_UNROLL == 1;
    localparam bit DIV_ITERATES = EXECUTION_UNROLL <= DIV_RESULT_LATENCY;
    logic reset_active;
    assign reset_active = reset || reset_reg;

    // Cannonical Pipeline Registers
    DecoderPacket_ decoder_payload [LAST_EXECUTION_STAGE:0];
    IssuerPacket_ issuer_payload [LAST_EXECUTION_STAGE:0];
    logic [31:0] data_payload [LAST_EXECUTION_STAGE:2];
    logic valid_payload [LAST_EXECUTION_STAGE:0];
    // Forward index 1 is lane stage 2; index EXECUTION_UNROLL is the final slot.
    // Index 0 has no registered execution result; same-cycle data uses bypass.
    assign forward_data_out[0] = 'x;
    for (genvar i = 1; i <= EXECUTION_UNROLL; i++) begin : gen_forward_output
        assign forward_data_out[i] = data_payload[i+1];
    end

    // Stall Causation Declarations
    logic operand_stall;
    logic operand_present; // Registered packet presence, independent of combinational squash.
    logic iteration_stall;
    logic mul_iteration_stall;
    logic div_iteration_stall;
    assign iteration_stall = mul_iteration_stall || div_iteration_stall;
    if (!IS_MUL) begin : gen_mul_stall
        assign mul_iteration_stall = 1'b0;
    end
    if (!IS_DIV) begin : gen_div_stall
        assign div_iteration_stall = 1'b0;
    end
    logic any_redirect;
    // Operand waits are no longer formed here: Issue precomputes per-slot watch
    // bits and BackendTop combines them with forward_ready. The equivalent local
    // condition is operand_present && operand_stall.
    assign iteration_stall_out = iteration_stall;

    // Stage 2 Flush Logic
    logic stage_2_flush;
    always_comb begin
        stage_2_flush = 1'b0;
        any_redirect = 1'b0;
        foreach (redirect_taken[i]) begin
            any_redirect |= redirect_taken[i];
            if (redirect_age[i] < issuer_payload[1].input_age) begin
                stage_2_flush |= redirect_taken[i];
            end
        end
    end

    // Payload advances through bubbles; validity has one owner below.
    // Global stall must still preserve the packet waiting for operands.
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
        // Only ALU-capable integer lanes produce bypass data, so the select
        // covers just those lanes (a 2:1 on one lane bit at two ALU lanes).
        // Any other selection is structurally impossible: don't-care.
        always_comb begin
            bypass_data_1 = 'x;
            bypass_data_2 = 'x;
            for (int lane = 1; lane <= Parameters::INTEGER_LANE_COUNT; lane++) begin
                if (EFFECTIVE_INTEGER_CAPS[lane-1][0]) begin
                    if (issuer_payload[0].forward_lane_1 == LANE_WIDTH'(lane))
                        bypass_data_1 = bypass_data[lane];
                    if (issuer_payload[0].forward_lane_2 == LANE_WIDTH'(lane))
                        bypass_data_2 = bypass_data[lane];
                end
            end
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
    // ALU operand selection (PC, zero, immediate) is done here at latch time, so
    // the ALU sees final operands and its bypass loop carries no source select.
    // Every select below is from registered payload. Late bypass data enters
    // last, through a single 2:1 whose select is also early.
    logic alu_operands;
    logic override_1, override_2, take_bypass_1, take_bypass_2;
    logic [31:0] early_source_1, early_source_2;
    always_comb begin
        alu_operands = IS_ALU && decoder_payload[0].common.capability == CAP_ALU;
        override_1 = alu_operands && (decoder_payload[0].alu.source == ALU_PC_IMM ||
            decoder_payload[0].alu.source == ALU_ZERO_IMM);
        override_2 = alu_operands && decoder_payload[0].alu.source != ALU_RS1_RS2;

        early_source_1 = issuer_payload[0].read_reg_file_1 ? file_data_1 : forward_data_1;
        early_source_2 = issuer_payload[0].read_reg_file_2 ? file_data_2 : forward_data_2;
        // Invalid integer sources represent x0 or an unused operand. Decode
        // leaves their register numbers unspecified; neither may read garbage.
        if (!decoder_payload[0].common.rs1_valid) early_source_1 = '0;
        if (!decoder_payload[0].common.rs2_valid) early_source_2 = '0;
        if (override_1)
            early_source_1 = decoder_payload[0].alu.source == ALU_PC_IMM ? decoder_payload[0].common.pc : '0;
        if (override_2) early_source_2 = decoder_payload[0].common.immediate;

        take_bypass_1 = BYPASS_ENABLED && issuer_payload[0].use_bypass_1 &&
            decoder_payload[0].common.rs1_valid && !override_1;
        take_bypass_2 = BYPASS_ENABLED && issuer_payload[0].use_bypass_2 &&
            decoder_payload[0].common.rs2_valid && !override_2;
        temp_source_1 = take_bypass_1 ? bypass_data_1 : early_source_1;
        temp_source_2 = take_bypass_2 ? bypass_data_2 : early_source_2;
    end

    // Operand Selection Stage
    logic [31:0] source_1;
    logic [31:0] source_2;
    // ALU controls are decoded from the operand-stage payload and registered with
    // the operands, so the ALU result select is a flat AND-OR of flops.
    AluControl_ alu_control_next, alu_control;
    always_comb begin
        unique case (decoder_payload[0].alu.operation)
            ALU_ADD, ALU_SUB: alu_control_next = '{sum: 1'b1, logic_op: LOGIC_NONE, default: 1'b0};
            ALU_SLL: alu_control_next = '{shift_left: 1'b1, logic_op: LOGIC_NONE, default: 1'b0};
            ALU_SLT: alu_control_next = '{set_less: 1'b1, logic_op: LOGIC_NONE, default: 1'b0};
            ALU_SLTU: alu_control_next = '{set_less_unsigned: 1'b1, logic_op: LOGIC_NONE, default: 1'b0};
            ALU_XOR: alu_control_next = '{logic_op: LOGIC_XOR, default: 1'b0};
            ALU_SRL, ALU_SRA: alu_control_next = '{shift_right: 1'b1, logic_op: LOGIC_NONE, default: 1'b0};
            ALU_OR: alu_control_next = '{logic_op: LOGIC_OR, default: 1'b0};
            ALU_AND: alu_control_next = '{logic_op: LOGIC_AND, default: 1'b0};
        endcase
        alu_control_next.subtract = decoder_payload[0].alu.operation == ALU_SUB;
        alu_control_next.arithmetic_shift = decoder_payload[0].alu.operation == ALU_SRA;
    end
    always_ff @(posedge clk) begin
        if (!stall) begin
            source_1 <= temp_source_1;
            source_2 <= temp_source_2;
            alu_control <= alu_control_next;
        end
    end

    // First Execution Stage Combinational Logic
    // Fall-through is local to execution; frontend next_pc is unspecified.
    logic [31:0] next_pc;
    logic [31:0] alu_result;
    logic bru_misaligned;
    if (IS_ALU) begin : gen_alu
        logic [31:0] result, bypass_result;
        assign alu_result = result;
        // Fast subset only; see Definitions::alu_bypassable.
        assign bypass_data_out = bypass_result;
        ArithmaticUnit alu (
            .control(alu_control),
            .lhs(source_1),
            .rhs(source_2),
            .result(result),
            .bypass_result(bypass_result)
        );
    end else begin : no_alu
        assign alu_result = '0;
        assign bypass_data_out = 'x;
    end if (IS_BRU) begin : gen_bru
        assign next_pc = decoder_payload[1].common.pc +
            (decoder_payload[1].bru.is_compressed ? 32'd2 : 32'd4);
        logic redirect;
        logic condition;
        logic [31:0] target;
        logic misaligned;
        assign bru_misaligned = misaligned;
        BranchUnit bru (
            .operation(decoder_payload[1].bru.operation),
            .source_1(source_1),
            .source_2(source_2),
            .immediate(decoder_payload[1].common.immediate),
            .pc(decoder_payload[1].common.pc),
            .predicted_taken(decoder_payload[1].bru.predicted_taken),
            .redirect(redirect),
            .target(target),
            .misaligned(misaligned)
        );
        assign condition = decoder_payload[1].common.capability == CAP_BRU &&
            decoder_payload[1].common.trap_type == NONE && valid_payload[1];
        assign redirect_taken_out = redirect && condition;
        assign redirect_age_out = issuer_payload[1].input_age;
        // A redirect means direction disagreed with prediction. A predicted
        // taken branch therefore recovers to fall-through, otherwise target.
        assign redirect_pc_out = decoder_payload[1].bru.predicted_taken ?
            next_pc : target;
    end else begin : gen_no_bru
        assign next_pc = 'x;
        assign bru_misaligned = 1'b0;
        assign redirect_taken_out = 1'b0;
        assign redirect_age_out = 'x;
        assign redirect_pc_out = 'x;
    end if (IS_MUL) begin : gen_mul
        logic [31:0] result;
        logic valid;
        Multiplier #(.EXECUTION_UNROLL(EXECUTION_UNROLL)) multiplier (
            .clk(clk),
            .reset(reset_active || trap_flush), // Resets only unit valid bits.
            .stall(stall),
            .flush(stage_2_flush),
            .valid_in(valid_payload[1] &&
                decoder_payload[1].common.capability == CAP_MUL),
            .integer_payload('{source_1: source_1, source_2: source_2,
                pc: decoder_payload[1].common.pc,
                rd_valid: decoder_payload[1].common.rd_valid,
                trap_type: decoder_payload[1].common.trap_type}),
            .multiply_payload(decoder_payload[1].mul),
            .iteration_stall(mul_iteration_stall),
            .result(result),
            .valid_out(valid)
        );
    end if (IS_DIV) begin : gen_div
        logic [31:0] result;
        logic valid;
        Divider #(.EXECUTION_UNROLL(EXECUTION_UNROLL), .AUTO_PIPE(DIVIDER_AUTO_PIPE)) divider (
            .clk(clk),
            .reset(reset_active || trap_flush), // Resets only unit valid/busy bits.
            .stall(stall),
            .flush(stage_2_flush), // In-flight redirect squashing remains lane-owned.
            .valid_in(valid_payload[1] &&
                decoder_payload[1].common.capability == CAP_DIV &&
                decoder_payload[1].common.trap_type == NONE),
            .integer_payload('{source_1: source_1, source_2: source_2,
                pc: decoder_payload[1].common.pc,
                rd_valid: decoder_payload[1].common.rd_valid,
                trap_type: decoder_payload[1].common.trap_type}),
            .div_payload(decoder_payload[1].div),
            .iteration_stall(div_iteration_stall),
            .data(result),
            .valid_out(valid)
        );
    end

    // Unit results are independent: their natural completion stages can differ.
    logic mul_result_valid, div_result_valid;
    logic [31:0] mul_result, div_result;
    if (IS_MUL) begin : gen_mul_completion
        assign mul_result_valid = gen_mul.valid;
        assign mul_result = gen_mul.result;
    end else begin : gen_no_mul_completion
        assign mul_result_valid = 1'b0;
        assign mul_result = 'x;
    end
    if (IS_DIV) begin : gen_div_completion
        assign div_result_valid = gen_div.valid;
        assign div_result = gen_div.result;
    end else begin : gen_no_div_completion
        assign div_result_valid = 1'b0;
        assign div_result = 'x;
    end
    logic capture_mul, capture_div, final_completion;
    // Iterating results are captured in place: the owner waits in the final
    // slot (held by its own iteration stall), so capture needs no stall term,
    // and the unit retires its valid after that edge.
    // A non-iterating unit's result belongs to the instruction one stage
    // before the result stage, so capturing it is a pipeline transfer and
    // must hold under stall. Otherwise a held stall would overwrite the older
    // instruction waiting in the result stage (seen at EXECUTION_UNROLL = 2:
    // a MUL in stage 2 overwrote the held stage-3 ALU result).
    assign capture_mul = mul_result_valid && (MUL_ITERATES || !stall);
    assign capture_div = div_result_valid && (DIV_ITERATES || !stall);
    assign final_completion = (capture_mul && MUL_RESULT_STAGE == LAST_EXECUTION_STAGE) ||
        (capture_div && DIV_RESULT_STAGE == LAST_EXECUTION_STAGE);

    // Registered final-slot readiness. Low on the edge an iterating op enters
    // the final slot, high on the edge its result is captured there.
    logic final_ready_q, entering_iterative;
    // A trapped MUL/DIV never needs its result (the divider does not even
    // start one), so it must not wait in the final slot: its trap has to reach
    // writeback.
    assign entering_iterative = decoder_payload[LAST_EXECUTION_STAGE-1].common.trap_type == NONE && (
        (IS_MUL && MUL_ITERATES && decoder_payload[LAST_EXECUTION_STAGE-1].common.capability == CAP_MUL) ||
        (IS_DIV && DIV_ITERATES && decoder_payload[LAST_EXECUTION_STAGE-1].common.capability == CAP_DIV));
    assign forward_ready_out = final_ready_q;

    // Sole owner of all data stages, including the one-execution-stage case.
    always_ff @(posedge clk) begin
        if (reset_active || trap_flush) begin
            final_ready_q <= 1'b1;
        end else begin
            if (final_completion) final_ready_q <= 1'b1;
            else if (!stall) final_ready_q <= !entering_iterative;

            for (int unsigned i = 2; i <= LAST_EXECUTION_STAGE; i++) begin
                if (capture_div && i == DIV_RESULT_STAGE) begin
                    data_payload[i] <= div_result;
                end else if (capture_mul && i == MUL_RESULT_STAGE) begin
                    data_payload[i] <= mul_result;
                end else if (!stall) begin
                    if (i == 2) begin
                        data_payload[i] <= decoder_payload[1].common.capability == CAP_ALU ?
                            alu_result : next_pc;
                    end else begin
                        data_payload[i] <= data_payload[i-1];
                    end
                end
            end
        end
    end

    // Sole owner of validity. Redirects are replayed externally during stalls.
    always_ff @(posedge clk) begin
        if (reset_active || trap_flush) begin
            for (int i = 1; i <= LAST_EXECUTION_STAGE; i++) valid_payload[i] <= 1'b0;
        end else if (!stall) begin
            valid_payload[1] <= valid_payload[0];
            valid_payload[2] <= valid_payload[1] && !stage_2_flush;
            for (int unsigned i = 3; i <= LAST_EXECUTION_STAGE; i++) begin
                valid_payload[i] <= valid_payload[i-1];
            end
        end
    end

    // Standard Pipeline Progression
    always_ff @(posedge clk) begin
        if (!stall) begin
            // Stage 0 is owned by the decode latch.
            for (int unsigned i = 1; i <= LAST_EXECUTION_STAGE; i++) begin
                decoder_payload[i] <= decoder_payload[i-1];
                issuer_payload[i] <= issuer_payload[i-1];
            end
            if (bru_misaligned) begin
                decoder_payload[2].common.trap_type <= MISALIGNED_INST;
            end
        end
    end

    // Result Broadcast
    assign result_data = data_payload[LAST_EXECUTION_STAGE];
    assign result_destination = decoder_payload[LAST_EXECUTION_STAGE].common.rd;
    assign result_age = issuer_payload[LAST_EXECUTION_STAGE].input_age;
    assign result_pending = valid_payload[LAST_EXECUTION_STAGE] && !final_ready_q;
    assign result_valid = valid_payload[LAST_EXECUTION_STAGE];
    assign result_trap_type = decoder_payload[LAST_EXECUTION_STAGE].common.trap_type;
    assign result_pc = decoder_payload[LAST_EXECUTION_STAGE].common.pc;
    // BackendTop qualifies the architectural write with group advance.
    // final_ready_q keeps an unfinished iterating result out of the RF. No reader
    // can depend on it: younger consumers map rd to this slot, not the RF.
    assign result_ready = valid_payload[LAST_EXECUTION_STAGE] && final_ready_q && !result_trap &&
        decoder_payload[LAST_EXECUTION_STAGE].common.rd_valid == 1'b1;
    assign result_trap = decoder_payload[LAST_EXECUTION_STAGE].common.trap_type != NONE && valid_payload[LAST_EXECUTION_STAGE];











    // Probably no need for last register here and can feed reg file straight


    // Results should get latched to data reg, sit at the end of divider/mul,
    // and broadcast ready until stall is released

endmodule 




// Big consideration of redirect speed and registering considerations around redirect.
// need to make sure branches only fire a redirect once, as they will normally try twice
// as they stall the pipeline once on redirects, which causes the still valid pre eval 
// branch to be able to refire. should suppress and continue through pipe after fire.

// as a general principle, pipeline registers can latch whenever so long as there is
// no stall. Valid bits encode if they contain useful info, so no need for other conditions

// issuer is allowed to assume if stall is active, nothing was accepted

// likely need a bypass channel ie ALU result -> os same cycle before alu result latch
// would dramatically improve performance as that dependency is so common.
// fine if it works on ALU produced results only. 

// need to do stuff with flush pipeline wide

// might be useful to only allow floating point lanes to produce integers late
// even if value is available early to reduce forwarding ports. perhaps paramater

// prob need valids going through divider and multiplier to prevent fsm based tracking

// for bypass, if path gets too long, likely limit it to certain ops and give it it's
// own little alu feeding it unconditionally.

// Evaluate checking out combinationally when iteration finishes vs latching a wb type
// stage that simply adds latency. Maybe not for parameterization simplicity
