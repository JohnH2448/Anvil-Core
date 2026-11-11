import Enumerations::*;
import Definitions::*;

module OldIntegerLane #(
    parameter unsigned IS_ALU = 1,
    parameter unsigned IS_BRU = 1,
    parameter unsigned IS_MUL = 1,
    parameter unsigned IS_DIV = 1,
    parameter unsigned EXECUTION_UNROLL = 1, // execution stages
    parameter unsigned BYPASS_ENABLED = 1, // worth considering for only alu, no bru
    parameter unsigned ISSUE_WIDTH = 2, // for inter slice age bits
    parameter unsigned LANE_ID = 0, // 0 is first
    parameter unsigned INTEGER_LANE_COUNT = 1, // 1 lane
    parameter unsigned MEMORY_LANE_COUNT = 1, 
    parameter unsigned FLOATING_LANE_COUNT = 1,
    parameter unsigned TOTAL_LANE_COUNT = INTEGER_LANE_COUNT + MEMORY_LANE_COUNT + FLOATING_LANE_COUNT + 1,
    parameter logic INT_FORWARD_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0] = '0,
    parameter logic READY_POINT_MATRIX [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0] = '0, // memory and iteration points
    parameter unsigned AGE_WIDTH = (ISSUE_WIDTH > 1) ? $clog2(ISSUE_WIDTH) : 1,
    parameter unsigned UNROLL_WIDTH = (EXECUTION_UNROLL > 1) ? $clog2(EXECUTION_UNROLL) : 1,
    parameter unsigned LANE_WIDTH = (TOTAL_LANE_COUNT > 1) ? $clog2(TOTAL_LANE_COUNT) : 1
)(
    // Standard Inputs
    input logic clk,
    input logic reset,
    input logic flush,

    // Data From Issuer
    input DecodedPacket_ packet_in,
    input logic [LANE_WIDTH:0] forward_lane_1,
    input logic [UNROLL_WIDTH:0] forward_index_1,
    input logic read_reg_file_1,
    input logic use_bypass_1, // mutually exclusive with read_reg_file_1
    input logic bypass_lane_1 [LANE_WIDTH:0],
    input logic [LANE_WIDTH:0] forward_lane_2,
    input logic [UNROLL_WIDTH:0] forward_index_2,
    input logic read_reg_file_2,
    input logic use_bypass_2, // mutually exclusive with read_reg_file_2
    input logic bypass_lane_2 [LANE_WIDTH:0],
    input logic accept,
    input logic [AGE_WIDTH-1:0] input_age,

    // Forwarding Inputs
    input logic [31:0] forward_data [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0], // used by all valid int forward points
    input logic forward_ready [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0], // tie all non iterative/memory points to 1 in top

    // Bypass Inputs
    input logic [31:0] bypass_data [TOTAL_LANE_COUNT-1:0],

    // Forwarding Outputs
    output logic [31:0] forward_data_out [EXECUTION_UNROLL:0],
    output logic forward_ready_out, // only used if iteration point exists

    // Redirect Inputs
    input logic redirect_taken_in [TOTAL_LANE_COUNT-1:0],
    input logic [AGE_WIDTH-1:0] redirect_age_in [TOTAL_LANE_COUNT-1:0],

    // Redirect Outputs
    output logic redirect_taken_out,
    output logic [AGE_WIDTH-1:0] redirect_age_out,
    output logic [31:0] redirect_pc_out,

    // Stall Controls
    output logic stall_out,
    input logic stall_in, // top needs to or all outs and pass an in

    // Result Broadcast
    output logic [31:0] result_data,
    output logic [4:0] result_destination,
    output logic [AGE_WIDTH-1:0] result_age, // inter slice age bits for reg file, redirects, and 2+ load lane config forwards
    output logic result_ready, // used for reg file acceptance and some consumer forward decisions

    // Register File Read Port
    output logic [4:0] reg_address_1,
    output logic [4:0] reg_address_2,
    input logic [31:0] read_data_1,
    input logic [31:0] read_data_2

);

    // Cannonical Data Pipeline Registers
    logic [31:0] pipeline_data [EXECUTION_UNROLL:0];
    logic [AGE_WIDTH-1:0] pipeline_age [EXECUTION_UNROLL:0];
    logic [4:0] pipeline_rd [EXECUTION_UNROLL:0];
    logic [31:0] pipeline_pc [EXECUTION_UNROLL:0];
    DecodeCapability_ pipeline_capability [EXECUTION_UNROLL:0];
    logic pipeline_valid [EXECUTION_UNROLL:0];
    assign forward_data_out = pipeline_data;

    // Generic Pipeline Metadata Propagation
    always_ff @(posedge clk) begin
        if (!stall_in) begin
            if (accept) begin
                pipeline_age[0] <= input_age;
                pipeline_rd[0] <= packet_in.common.rd;
                pipeline_capability[0] <= packet_in.common.capability;
            end
            for (int unsigned i = 1; i <= EXECUTION_UNROLL; i++) begin
                pipeline_age[i] <= pipeline_age[i-1];
                pipeline_rd[i] <= pipeline_rd[i-1];
                pipeline_capability[i] <= pipeline_capability[i-1];
            end
        end
    end
    assign result_age = pipeline_age[EXECUTION_UNROLL];
    assign result_destination = pipeline_rd[EXECUTION_UNROLL];

    // Select Oldest Redirect
    logic [AGE_WIDTH-1:0] temp_redirect_age;
    logic any_redirect;
    always_comb begin
        temp_redirect_age = '0;
        any_redirect = 1'b0;
        for (int signed i = int'(TOTAL_LANE_COUNT - 1); i >= 0; i--) begin
            if (redirect_taken_in[i]) begin
                if (!any_redirect || redirect_age_in[i] < temp_redirect_age) begin
                    temp_redirect_age = redirect_age_in[i];
                end
                any_redirect = 1'b1;
            end
        end
    end

    // Regitered Redirects and Resets
    logic redirect_taken_reg;
    logic [AGE_WIDTH-1:0] redirect_age_reg;
    logic reset_reg;
    always_ff @(posedge clk) begin
        if (reset_reg || redirect_taken_reg) begin
            redirect_taken_reg <= 1'b0;
            redirect_age_reg <= '0;
            reset_reg <= 1'b0;
        end else begin
            redirect_taken_reg <= any_redirect;
            redirect_age_reg <= temp_redirect_age;
            reset_reg <= reset;
        end
    end

    // Validity Shift Register and Flusher
    logic next_pipeline_valid [EXECUTION_UNROLL:0];
    always_comb begin // assumes a stall on redirect and a flush next cycle (matches frontend timing)
        if (!stall_in) begin
            if (redirect_taken_reg) begin
                next_pipeline_valid[0] = '0;
                next_pipeline_valid[1] = '0;
                // flush if redirect is older than current same slice instruction
                next_pipeline_valid[2] = pipeline_valid[1] && !(redirect_age_reg < pipeline_age[1]);
                for (int unsigned i = 3; i <= EXECUTION_UNROLL; i++) begin
                    next_pipeline_valid[i] = pipeline_valid[i-1];
                end
            end else begin
                next_pipeline_valid[0] = accept;
                for (int unsigned i = 1; i <= EXECUTION_UNROLL; i++) begin
                    next_pipeline_valid[i] = pipeline_valid[i-1];
                end
            end
        end else begin
            if (redirect_taken_reg) begin
                next_pipeline_valid[0] = '0;
                next_pipeline_valid[1] = pipeline_valid[1] && !(redirect_age_reg < pipeline_age[1]);
                // flush if redirect is older than current same slice instruction
                for (int unsigned i = 2; i <= EXECUTION_UNROLL; i++) begin
                    next_pipeline_valid[i] = pipeline_valid[i];
                end
            end else begin
                for (int unsigned i = 0; i <= EXECUTION_UNROLL; i++) begin
                    next_pipeline_valid[i] = pipeline_valid[i];
                end
            end
        end
    end always_ff @(posedge clk) begin
        if (reset_reg) begin
            pipeline_valid <= '{default: 1'b0};
        end else begin
            pipeline_valid <= next_pipeline_valid;
        end
    end

    // Latch Step 1 Packet
    typedef struct packed {
        logic [31:0] pc;
        logic [4:0] rs1;
        logic [4:0] rs2;
        logic rd_valid;
        TrapType_ trap_type;
    } IntegerInput_;
    IntegerInput_ common_reg;
    always_ff @(posedge clk) begin
        if (accept && !stall_in) begin
            common_reg.pc <= packet_in.common.pc;
            common_reg.rs1 <= packet_in.common.rs1;
            common_reg.rs2 <= packet_in.common.rs2;
            common_reg.rd_valid <= packet_in.common.rd_valid;
            common_reg.trap_type <= packet_in.common.trap_type;
        end
    end
    if (IS_ALU) begin : gen_alu
        DecodeAlu_ alu_reg;
        always_ff @(posedge clk) begin
            if (accept && !stall_in) begin
                alu_reg <= packet_in.alu;
            end
        end
    end
    if (IS_BRU) begin : gen_bru
        DecodeBru_ bru_reg;
        always_ff @(posedge clk) begin
            if (accept && !stall_in) begin
                bru_reg <= packet_in.bru;
            end
        end
    end
    if (IS_MUL) begin : gen_mul
        DecodeMul_ mul_reg;
        always_ff @(posedge clk) begin
            if (accept && !stall_in) begin
                mul_reg <= packet_in.mul;
            end
        end
    end
    if (IS_DIV) begin : gen_div
        DecodeDiv_ div_reg;
        always_ff @(posedge clk) begin
            if (accept && !stall_in) begin
                div_reg <= packet_in.div;
            end
        end
    end

    // Register File Read
    assign reg_address_1 = common_reg.rs1;
    assign reg_address_2 = common_reg.rs2;

    // Stall Causation Declarations
    logic operand_stall;
    logic iteration_stall;
    assign stall_out = operand_stall || iteration_stall || any_redirect; // may need to refactor redirects for timing

    // Forwarding Decision and Stall Logic
    logic [31:0] temp_forward_data_1;
    logic [31:0] temp_forward_data_2;
    always_comb begin
        temp_forward_data_1 = forward_data[forward_lane_1][forward_index_1];
        temp_forward_data_2 = forward_data[forward_lane_2][forward_index_2];
        if (!forward_ready[forward_lane_1][forward_index_1]) begin
            operand_stall = 1'b1;
        end else if (!forward_ready[forward_lane_2][forward_index_2]) begin
            operand_stall = 1'b1;
        end else begin
            operand_stall = 1'b0;
        end
    end // need to ensure synth knows many paths are impossible, prob in top

    // Final Source Selection Logic
    logic [31:0] source_1;
    logic [31:0] source_2;
    always_comb begin
        if (read_reg_file_1) begin
            source_1 = read_data_1;
        end else begin
            source_1 = temp_forward_data_1;
        end
        if (read_reg_file_2) begin
            source_2 = read_data_2;
        end else begin
            source_2 = temp_forward_data_2;
        end
    end

    // Latch Step 2 Payload
    IntegerOperands_ operands_reg; 
    logic latch_step_2;
    assign latch_step_2 = !stall_in;
    always_ff @(posedge clk) begin
        if (latch_step_2) begin
            operands_reg.source_1 <= source_1;
            operands_reg.source_2 <= source_2;
            operands_reg.pc <= common_reg.pc;
            operands_reg.rd_valid <= common_reg.rd_valid;
            operands_reg.trap_type <= common_reg.trap_type;
        end
    end
    if (IS_ALU) begin : gen_alu_step_2
        DecodeAlu_ alu_reg;
        always_ff @(posedge clk) begin
            if (latch_step_2) begin
                alu_reg <= gen_alu.alu_reg;
            end
        end
    end
    if (IS_BRU) begin : gen_bru_step_2
        DecodeBru_ bru_reg;
        always_ff @(posedge clk) begin
            if (latch_step_2) begin
                bru_reg <= gen_bru.bru_reg;
            end
        end
    end
    if (IS_MUL) begin : gen_mul_step_2
        DecodeMul_ mul_reg;
        always_ff @(posedge clk) begin
            if (latch_step_2) begin
                mul_reg <= gen_mul.mul_reg;
            end
        end
    end
    if (IS_DIV) begin : gen_div_step_2
        DecodeDiv_ div_reg;
        always_ff @(posedge clk) begin
            if (latch_step_2) begin
                div_reg <= gen_div.div_reg;
            end
        end
    end

    // Step 2+ Arithmatic Logic
    logic [31:0] alu_result;
    logic [31:0] bru_result;
    logic [31:0] step_2_result;
    if (IS_ALU) begin : step_2_alu
        logic [31:0] lhs;
        logic [31:0] rhs;
        logic subtract;
        logic [31:0] sum;
        // ADD/SUB share one adder.
        assign subtract = gen_alu_step_2.alu_reg.operation == ALU_SUB;
        assign sum = lhs + (rhs ^ {32{subtract}}) + {31'b0, subtract};
        always_comb begin
            lhs = operands_reg.source_1;
            rhs = gen_alu_step_2.alu_reg.source == ALU_RS1_RS2 ?
                operands_reg.source_2 : gen_alu_step_2.alu_reg.immediate;
            case (gen_alu_step_2.alu_reg.source)
                ALU_PC_IMM: lhs = operands_reg.pc;
                ALU_ZERO_IMM: lhs = '0;
                default: begin end
            endcase
        end
        always_comb begin
            alu_result = 'x;
            unique case (gen_alu_step_2.alu_reg.operation)
                ALU_ADD, ALU_SUB: alu_result = sum;
                ALU_SLL: alu_result = lhs << rhs[4:0];
                ALU_SLT: alu_result = {31'b0, $signed(lhs) < $signed(rhs)};
                ALU_SLTU: alu_result = {31'b0, lhs < rhs};
                ALU_XOR: alu_result = lhs ^ rhs;
                ALU_SRL: alu_result = lhs >> rhs[4:0];
                ALU_SRA: alu_result = $signed(lhs) >>> rhs[4:0];
                ALU_OR: alu_result = lhs | rhs;
                ALU_AND: alu_result = lhs & rhs;
                default: begin end
            endcase
        end
    end else begin : no_alu
        assign alu_result = 'x;
    end

    if (IS_BRU) begin : step_2_bru
        logic generated_redirect_signal;
        logic [31:0] generated_redirect_target;
        logic actual_taken;
        logic [31:0] fallthrough_pc;
        logic [31:0] taken_target;
        logic redirect_fired;
        assign redirect_age_out = pipeline_age[1];
        assign redirect_taken_out = generated_redirect_signal;
        assign redirect_pc_out = generated_redirect_target;
        assign bru_result = fallthrough_pc;
        always_ff @(posedge clk) begin
            if (reset_reg || latch_step_2) begin
                redirect_fired <= 1'b0;
            end else if (generated_redirect_signal) begin
                redirect_fired <= 1'b1;
            end
        end
        always_comb begin
            fallthrough_pc = operands_reg.pc +
                (gen_bru_step_2.bru_reg.is_compressed ? 32'd2 : 32'd4);
            taken_target = operands_reg.pc + gen_bru_step_2.bru_reg.immediate;
            actual_taken = 1'b0;
            unique case (gen_bru_step_2.bru_reg.operation)
                BR_EQ:  actual_taken = operands_reg.source_1 == operands_reg.source_2;
                BR_NE:  actual_taken = operands_reg.source_1 != operands_reg.source_2;
                BR_LT:  actual_taken = $signed(operands_reg.source_1) < $signed(operands_reg.source_2);
                BR_GE:  actual_taken = $signed(operands_reg.source_1) >= $signed(operands_reg.source_2);
                BR_LTU: actual_taken = operands_reg.source_1 < operands_reg.source_2;
                BR_GEU: actual_taken = operands_reg.source_1 >= operands_reg.source_2;
                BR_JAL: actual_taken = 1'b1;
                BR_JALR: begin
                    actual_taken = 1'b1;
                    taken_target = (operands_reg.source_1 + gen_bru_step_2.bru_reg.immediate) & 32'hfffffffe;
                end
            endcase
            generated_redirect_signal = 1'b0;
            generated_redirect_target = actual_taken ? taken_target : fallthrough_pc;
            if (pipeline_valid[1] && pipeline_capability[1] == CAP_BRU &&
                operands_reg.trap_type == NONE &&
                !reset_reg && !redirect_taken_reg && !redirect_fired) begin
                generated_redirect_signal =
                    gen_bru_step_2.bru_reg.operation == BR_JALR ||
                    actual_taken != gen_bru_step_2.bru_reg.predicted_taken;
            end
        end
    end

    if (!IS_BRU) begin : no_bru
        assign bru_result = 'x;
        assign redirect_age_out = 'x;
        assign redirect_taken_out = 1'b0;
        assign redirect_pc_out = 'x;
    end

    if (IS_MUL) begin : step_2_mul
        // Fully Pipelined Multiply Structure
    end

    if (IS_DIV) begin : step_2_iv
        // Fully Pipelined Division Structure
    end

    // Pipeline Data / Ready Assignment
    assign step_2_result = pipeline_capability[1] == CAP_BRU ? bru_result : alu_result;
    // If no stall (not iterating), shift, else update only iterative points.
    always_ff @(posedge clk) begin
        if (!stall_in) begin
            pipeline_data[2] <= step_2_result;
            for (int unsigned i = 3; i <= EXECUTION_UNROLL; i++) begin
                pipeline_data[i] <= pipeline_data[i-1];
            end
        end else begin
            forward_ready_out <= mul_ready_reg || div_ready_reg; // could also do is cap_mul/div and !stall, but this is faster
            if (pipeline_capability[EXECUTION_UNROLL] == CAP_MUL) begin
                pipeline_data[EXECUTION_UNROLL] <= mul_result;
            end else if (pipeline_capability[EXECUTION_UNROLL] == CAP_DIV) begin
                pipeline_data[EXECUTION_UNROLL] <= div_result;
            end
        end
    end

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
