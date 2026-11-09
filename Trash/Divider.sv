import Enumerations::*;
import Definitions::*;

module Divider #(
    parameter unsigned UNROLL_CUTOFF = 4,
    parameter unsigned AUTO_PIPE = 2
)(

    // Standard Inputs
    input logic clk,
    input logic reset,
    input logic stall,
    input logic flush,

    // Working Set
    input IntegerOperands_ integer_payload, 
    input DecodeDiv_ div_payload,

    // Outputs
    output logic [31:0] data

);

    // Division Step Function
    function automatic void div_step3(
        input logic [32:0] remainder,
        input logic [31:0] divisor,
        input logic dividend_bit,
        output logic [32:0] new_remainder,
        output logic quotient_bit
    );
        logic [32:0] shifted;
        shifted = {remainder[31:0], dividend_bit};
        new_remainder = remainder[32] ? (shifted + {1'b0, divisor})
            : (shifted - {1'b0, divisor});
        quotient_bit = ~new_remainder[32];
    endfunction

    // Division Step Function
    function automatic void div_step2(
        input logic [32:0] remainder,
        input logic [31:0] divisor,
        input logic dividend_bit,
        output logic [32:0] new_remainder,
        output logic quotient_bit
    );
        logic [32:0] shifted;
        logic [32:0] sum;
        logic [32:0] difference;

        shifted = {remainder[31:0], dividend_bit};
        sum = shifted + {1'b0, divisor};
        difference = shifted - {1'b0, divisor};

        new_remainder = remainder[32] ? sum : difference;
        quotient_bit = ~new_remainder[32];
    endfunction

    function automatic void div_step(
        input logic [32:0] remainder,
        input logic [31:0] divisor,
        input logic dividend_bit,
        output logic [32:0] new_remainder,
        output logic quotient_bit
    );
        logic [32:0] shifted;
        logic [32:0] operand;
        logic subtract;

        shifted = {remainder[31:0], dividend_bit};
        subtract = ~remainder[32];
        operand = {1'b0, divisor} ^ {33{subtract}};

        new_remainder = shifted + operand + {32'b0, subtract};
        quotient_bit = ~new_remainder[32];
    endfunction

    // Magnitude Conversion
    logic [31:0] dividend_abs;
    logic [31:0] divisor_abs;
    logic signed_op;
    logic dividend_neg;
    logic divisor_neg;
    assign signed_op = (div_payload.operation == DIV_SIGNED) ||
        (div_payload.operation == REM_SIGNED);
    assign dividend_neg = signed_op & integer_payload.source_1[31];
    assign divisor_neg = signed_op & integer_payload.source_2[31];
    assign dividend_abs = dividend_neg
        ? -integer_payload.source_1
        : integer_payload.source_1;
    assign divisor_abs = divisor_neg
        ? -integer_payload.source_2
        : integer_payload.source_2;

    // Stage Pipeline Unroll
    localparam unsigned STAGES = (32 / AUTO_PIPE);
    localparam unsigned REMAINDER_STAGES = 32 % AUTO_PIPE;
    localparam unsigned STAGE_REG_W = STAGES-1;
    logic [32:0] new_remainder_pipeline_reg [0:STAGE_REG_W];
    logic [31:0] divisor_pipeline_reg [0:STAGE_REG_W];
    logic [31:0] dividend_pipeline_reg [0:STAGE_REG_W];
    logic [31:0] quotient_pipeline_reg [0:STAGE_REG_W];
    DivOperation_ op_pipeline_reg [0:STAGE_REG_W];
    logic dividend_neg_pipeline_reg [0:STAGE_REG_W];
    logic divisor_neg_pipeline_reg [0:STAGE_REG_W];
    for (genvar i = 0; i < STAGES; i++) begin : stages
        logic [32:0] remainder_comb;
        logic [31:0] divisor_comb;
        logic [31:0] dividend_comb;
        logic [32:0] new_remainder_comb [0:AUTO_PIPE-1];
        logic [31:0] quotient_comb;
        logic [31:0] next_quotient_comb;
        logic [AUTO_PIPE-1:0] next_quotient_slice;
        assign next_quotient_comb = quotient_comb |
            (32'(next_quotient_slice) << (32 - (i+1)*AUTO_PIPE));
        if (i == 0) begin : gen_input_grab
            assign dividend_comb = dividend_abs;
            assign divisor_comb = divisor_abs;
            assign quotient_comb = '0;
            assign remainder_comb = '0;
        end else begin : gen_last_stage_grab
            assign dividend_comb = dividend_pipeline_reg[i-1];
            assign divisor_comb = divisor_pipeline_reg[i-1];
            assign quotient_comb = quotient_pipeline_reg[i-1];
            assign remainder_comb = new_remainder_pipeline_reg[i-1];
        end
        for (genvar j = 0; j < AUTO_PIPE; j++) begin : dividers
            logic dividend_bit;
            always_comb begin
                dividend_bit = dividend_comb[31 - (i*AUTO_PIPE + j)];
                div_step( 
                    (j == 0) ? remainder_comb : new_remainder_comb[j-1], 
                    divisor_comb, 
                    dividend_bit,
                    new_remainder_comb[j],
                    next_quotient_slice[AUTO_PIPE-1-j]
                );
            end
        end
    end

    // Remainder Unroll
    if (REMAINDER_STAGES != 0) begin : remainder_stages
        logic [32:0] remainder_comb;
        logic [31:0] divisor_comb;
        logic [31:0] dividend_comb;
        logic [32:0] new_remainder_comb [0:REMAINDER_STAGES-1];
        logic [31:0] quotient_comb;
        logic [31:0] next_quotient_comb;
        logic [REMAINDER_STAGES-1:0] next_quotient_slice;
        assign next_quotient_comb = quotient_comb | 32'(next_quotient_slice);
        assign dividend_comb = dividend_pipeline_reg[STAGES-1];
        assign divisor_comb = divisor_pipeline_reg[STAGES-1];
        assign quotient_comb = quotient_pipeline_reg[STAGES-1];
        assign remainder_comb = new_remainder_pipeline_reg[STAGES-1];
        for (genvar j = 0; j < REMAINDER_STAGES; j++) begin : remainder_dividers
            logic dividend_bit;
            always_comb begin
                dividend_bit = dividend_comb[31 - (STAGES*AUTO_PIPE + j)];
                div_step( 
                    (j == 0) ? remainder_comb : new_remainder_comb[j-1], 
                    divisor_comb, 
                    dividend_bit,
                    new_remainder_comb[j],
                    next_quotient_slice[REMAINDER_STAGES-1-j]
                );
            end
        end
    end

    // Result Selection
    logic [31:0] raw_quotient;
    logic [32:0] raw_remainder;
    logic [31:0] final_divisor;
    logic [32:0] restored_remainder;
    logic [31:0] corrected_quotient;
    logic [31:0] corrected_remainder;
    if (REMAINDER_STAGES == 0) begin : gen_full_result
        assign raw_quotient = quotient_pipeline_reg[STAGE_REG_W];
        assign raw_remainder = new_remainder_pipeline_reg[STAGE_REG_W];
        assign final_divisor = divisor_pipeline_reg[STAGE_REG_W];
    end else begin : gen_partial_result
        assign raw_quotient = remainder_stages.next_quotient_comb;
        assign raw_remainder = remainder_stages.new_remainder_comb[REMAINDER_STAGES-1];
        assign final_divisor = remainder_stages.divisor_comb;
    end
    always_comb begin
        logic q_or_r;
        restored_remainder = raw_remainder[32]
            ? raw_remainder + {1'b0, final_divisor}
            : raw_remainder;
        corrected_quotient = (dividend_neg_pipeline_reg[STAGE_REG_W] ^
            divisor_neg_pipeline_reg[STAGE_REG_W]) && (final_divisor != 0)
            ? -raw_quotient
            : raw_quotient;
        corrected_remainder = dividend_neg_pipeline_reg[STAGE_REG_W]
            ? -restored_remainder[31:0]
            : restored_remainder[31:0];
        q_or_r = (op_pipeline_reg[STAGE_REG_W] == DIV_SIGNED) ||
            (op_pipeline_reg[STAGE_REG_W] == DIV_UNSIGNED);
        data = q_or_r ? corrected_quotient : corrected_remainder;
    end

    // Pipeline Registering
    for (genvar k = 0; k < STAGES; k++) begin : registering
        always_ff @(posedge clk) begin
            if (!stall || k > UNROLL_CUTOFF-2)
            new_remainder_pipeline_reg[k] <= stages[k].new_remainder_comb[AUTO_PIPE-1];
            divisor_pipeline_reg[k] <= stages[k].divisor_comb;
            dividend_pipeline_reg[k] <= stages[k].dividend_comb;
            quotient_pipeline_reg[k] <= stages[k].next_quotient_comb;
            if (k == 0) begin
                dividend_neg_pipeline_reg[k] <= dividend_neg;
                divisor_neg_pipeline_reg[k] <= divisor_neg;
                op_pipeline_reg[k] <= div_payload.operation;
            end else begin
                dividend_neg_pipeline_reg[k] <= dividend_neg_pipeline_reg[k-1];
                divisor_neg_pipeline_reg[k] <= divisor_neg_pipeline_reg[k-1];
                op_pipeline_reg[k] <= op_pipeline_reg[k-1];
            end
        end
    end

endmodule


  