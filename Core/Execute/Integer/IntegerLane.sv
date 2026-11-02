module IntegerLane
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter IS_ALU = 1,
    parameter IS_BRU = 1,
    parameter IS_MUL = 1,
    parameter IS_DIV = 1,
    parameter UNROLL_CUTOFF = 1, // execution stages (min 1)
    parameter BYPASS_ENABLED = 1, // worth considering for only alu, no bru
    parameter ISSUE_WIDTH = 2, // for inter slice age bits
    parameter LANE_ID = 0, // 0 is first
    parameter DIVIDER_AUTO_PIPE = 3
)(
    // Standard Inputs
    input logic clk,
    input logic reset,

    // Data From Issuer
    input DecoderPacket_ decoder_packet,
    input IssuerPacket_ issuer_packet,
    input logic accept,

    // Forwarding Inputs
    input logic [31:0] forward_data [TOTAL_LANE_COUNT-1:0][UNROLL_CUTOFF:0], // used by all valid int forward points
    input logic forward_ready [TOTAL_LANE_COUNT-1:0][UNROLL_CUTOFF:0], // tie all non iterative/memory points to 1 in top

    // Forwarding Outputs
    output logic [31:0] forward_data_out [UNROLL_CUTOFF:0],
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
    output logic stall_out,
    input logic stall, // top needs to or all outs and pass an in

    // Result Broadcast
    output logic [31:0] result_data,
    output logic [4:0] result_destination,
    output logic [AGE_WIDTH-1:0] result_age, 
    output logic result_ready, 
    output logic result_trap,

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
    localparam int LAST_EXECUTION_STAGE = UNROLL_CUTOFF + 1;
    localparam int MUL_RESULT_STAGE = LAST_EXECUTION_STAGE < 3 ? LAST_EXECUTION_STAGE : 3;
    localparam int DIV_RESULT_LATENCY = (32 + DIVIDER_AUTO_PIPE - 1) / DIVIDER_AUTO_PIPE + 1;
    localparam int DIV_RESULT_STAGE = LAST_EXECUTION_STAGE < DIV_RESULT_LATENCY + 2 ?
        LAST_EXECUTION_STAGE : DIV_RESULT_LATENCY + 2;
    localparam bit MUL_ITERATES = UNROLL_CUTOFF == 1;
    localparam bit DIV_ITERATES = UNROLL_CUTOFF <= DIV_RESULT_LATENCY;
    logic reset_active;
    assign reset_active = reset || reset_reg;

    // Cannonical Pipeline Registers
    DecoderPacket_ decoder_payload [LAST_EXECUTION_STAGE:0];
    IssuerPacket_ issuer_payload [LAST_EXECUTION_STAGE:0];
    logic [31:0] data_payload [LAST_EXECUTION_STAGE:2];
    logic valid_payload [LAST_EXECUTION_STAGE:0];
    // Forward index 1 is lane stage 2; index UNROLL_CUTOFF is the final slot.
    // Index 0 has no registered execution result; same-cycle data uses bypass.
    assign forward_data_out[0] = 'x;
    for (genvar i = 1; i <= UNROLL_CUTOFF; i++) begin : gen_forward_output
        assign forward_data_out[i] = data_payload[i+1];
    end

    // Stall Causation Declarations
    logic operand_stall;
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
    assign stall_out = (operand_stall && valid_payload[0]) || iteration_stall;

    // Stage 2 Flush Logic
    logic stage_2_flush;
    logic any_redirect;
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

    // Decode Payload Latch (validity has one owner below).
    always_ff @(posedge clk) begin
        if (!stall && accept && !any_redirect) begin
            decoder_payload[0] <= decoder_packet;
            issuer_payload[0] <= issuer_packet;
        end
    end

    // Forwarding Decision and Stall Logic
    logic [31:0] forward_data_1;
    logic [31:0] forward_data_2;
    always_comb begin
        forward_data_1 = forward_data[issuer_payload[0].forward_lane_1][issuer_payload[0].forward_index_1];
        forward_data_2 = forward_data[issuer_payload[0].forward_lane_2][issuer_payload[0].forward_index_2];
        operand_stall =
            (decoder_payload[0].common.rs1_valid &&
             !issuer_payload[0].read_reg_file_1 &&
             !(BYPASS_ENABLED && issuer_payload[0].use_bypass_1) &&
             !forward_ready[issuer_payload[0].forward_lane_1][issuer_payload[0].forward_index_1]) ||
            (decoder_payload[0].common.rs2_valid &&
             !issuer_payload[0].read_reg_file_2 &&
             !(BYPASS_ENABLED && issuer_payload[0].use_bypass_2) &&
             !forward_ready[issuer_payload[0].forward_lane_2][issuer_payload[0].forward_index_2]);
    end

    // Bypass Data Selection
    logic [31:0] bypass_data_1;
    logic [31:0] bypass_data_2;
    if (BYPASS_ENABLED) begin : gen_bypass_selection
        always_comb begin
            bypass_data_1 = bypass_data[issuer_payload[0].bypass_lane_1];
            bypass_data_2 = bypass_data[issuer_payload[0].bypass_lane_2];
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

    // First Execution Stage Combinational Logic
    logic [31:0] alu_result;
    logic bru_misaligned;
    if (IS_ALU) begin : gen_alu
        logic [31:0] result;
        assign alu_result = result;
        assign bypass_data_out = result;
        ArithmaticUnit alu (
            .operation(decoder_payload[1].alu.operation),
            .source(decoder_payload[1].alu.source),
            .source_1(source_1),
            .source_2(source_2),
            .immediate(decoder_payload[1].common.immediate),
            .pc(decoder_payload[1].common.pc),
            .result(result)
        );
    end else begin : no_alu
        assign alu_result = '0;
        assign bypass_data_out = 'x;
    end if (IS_BRU) begin : gen_bru
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
        assign condition = decoder_payload[1].common.trap_type == NONE && valid_payload[1];
        assign redirect_taken_out = redirect && condition;
        assign redirect_age_out = issuer_payload[1].input_age;
        // A redirect means direction disagreed with prediction. A predicted
        // taken branch therefore recovers to fall-through, otherwise target.
        assign redirect_pc_out = decoder_payload[1].bru.predicted_taken ?
            decoder_payload[1].common.next_pc : target;
    end else begin : gen_no_bru
        assign bru_misaligned = 1'b0;
        assign redirect_taken_out = 1'b0;
        assign redirect_age_out = 'x;
        assign redirect_pc_out = 'x;
    end if (IS_MUL) begin : gen_mul
        logic [31:0] result;
        logic valid;
        Multiplier #(.UNROLL_CUTOFF(UNROLL_CUTOFF)) multiplier (
            .clk(clk),
            .reset(reset_active),
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
        Divider #(.UNROLL_CUTOFF(UNROLL_CUTOFF), .AUTO_PIPE(DIVIDER_AUTO_PIPE)) divider (
            .clk(clk),
            .reset(reset_active),
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
        assign mul_result = '0;
    end
    if (IS_DIV) begin : gen_div_completion
        assign div_result_valid = gen_div.valid;
        assign div_result = gen_div.result;
    end else begin : gen_no_div_completion
        assign div_result_valid = 1'b0;
        assign div_result = '0;
    end
    logic capture_mul, capture_div, final_completion;
    // Early results advance with metadata. Iterating results must be captured
    // while the final lane slot and its metadata are held by global stall.
    assign capture_mul = mul_result_valid && (!stall || MUL_ITERATES);
    assign capture_div = div_result_valid && (!stall || DIV_ITERATES);
    assign final_completion = (capture_mul && MUL_RESULT_STAGE == LAST_EXECUTION_STAGE) ||
        (capture_div && DIV_RESULT_STAGE == LAST_EXECUTION_STAGE);

    // Sole owner of all data stages, including the one-execution-stage case.
    always_ff @(posedge clk) begin
        if (reset_active) begin
            forward_ready_out <= 1'b0;
        end else begin
            if (final_completion) forward_ready_out <= 1'b1;
            else if (!stall) forward_ready_out <= 1'b0;

            for (int i = 2; i <= LAST_EXECUTION_STAGE; i++) begin
                if (capture_div && i == DIV_RESULT_STAGE) begin
                    data_payload[i] <= div_result;
                end else if (capture_mul && i == MUL_RESULT_STAGE) begin
                    data_payload[i] <= mul_result;
                end else if (!stall) begin
                    if (i == 2) begin
                        data_payload[i] <= decoder_payload[1].common.capability == CAP_ALU ?
                            alu_result : decoder_payload[1].common.next_pc;
                    end else begin
                        data_payload[i] <= data_payload[i-1];
                    end
                end
            end
        end
    end

    // Sole owner of validity. Redirects are replayed externally during stalls.
    always_ff @(posedge clk) begin
        if (reset_active) begin
            valid_payload <= '{default: 1'b0};
        end else if (!stall) begin
            valid_payload[0] <= accept && !any_redirect;
            valid_payload[1] <= valid_payload[0] && !any_redirect;
            valid_payload[2] <= valid_payload[1] && !stage_2_flush;
            for (int i = 3; i <= LAST_EXECUTION_STAGE; i++) begin
                valid_payload[i] <= valid_payload[i-1];
            end
        end
    end

    // Standard Pipeline Progression
    always_ff @(posedge clk) begin
        if (!stall) begin
            // Stage 0 is owned by the decode latch.
            for (int i = 1; i <= LAST_EXECUTION_STAGE; i++) begin
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
    assign result_ready = valid_payload[LAST_EXECUTION_STAGE] && !stall && !result_trap && decoder_payload[LAST_EXECUTION_STAGE].common.rd_valid == 1'b1;
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
