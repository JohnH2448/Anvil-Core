module ArithmaticUnit
    import Definitions::*;
(
    // Registered one-hot result select plus subtract/arithmetic-shift flags.
    input AluControl_ control,
    // Final operands. PC, zero and immediate selection happens at the lane's
    // operand latch, keeping it out of the ALU-to-bypass loop.
    input logic [31:0] lhs,
    input logic [31:0] rhs,
    output logic [31:0] result,
    // Same-cycle bypass value. Valid only for alu_bypassable operations
    // (add, sub, xor, or, and); Decode never bypasses anything else, so the
    // compares and the shifter stay out of the bypass loop.
    output logic [31:0] bypass_result
);

    logic [31:0] sum;
    logic signed [32:0] right_operand;
    logic [32:0] right_result;
    assign right_operand = {control.arithmetic_shift && lhs[31], lhs};
    assign right_result = right_operand >>> rhs[4:0];

    // ADD/SUB share one adder.
    assign sum = lhs + (rhs ^ {32{control.subtract}}) + {31'b0, control.subtract};

    // Bitwise result from the 2-bit code: per bit a function of lhs[i], rhs[i]
    // and logic_op, so it merges with the sum term into one LUT6 per bit.
    logic [31:0] logic_value;
    always_comb begin
        unique case (control.logic_op)
            LOGIC_NONE: logic_value = '0;
            LOGIC_XOR: logic_value = lhs ^ rhs;
            LOGIC_OR: logic_value = lhs | rhs;
            LOGIC_AND: logic_value = lhs & rhs;
        endcase
    end

    // Exact fan-in: lhs, rhs, control.subtract (inside sum), control.sum and
    // control.logic_op. No shifter, comparator or shift/compare control.
    assign bypass_result = ({32{control.sum}} & sum) | logic_value;

    // Full result into the lane's data_payload[2] register; flat AND-OR over
    // mutually exclusive registered controls.
    assign result =
        bypass_result |
        ({32{control.shift_left}} & (lhs << rhs[4:0])) |
        {31'b0, control.set_less && ($signed(lhs) < $signed(rhs))} |
        {31'b0, control.set_less_unsigned && (lhs < rhs)} |
        ({32{control.shift_right}} & right_result[31:0]);

endmodule
