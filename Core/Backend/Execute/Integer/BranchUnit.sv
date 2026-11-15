module BranchUnit
    import Enumerations::*;
(
    input BranchOperation_ operation,
    input logic [31:0] source_1,
    input logic [31:0] source_2,
    input logic [31:0] immediate,
    input logic [31:0] pc,
    input logic predicted_taken,
    output logic redirect,
    output logic [31:0] target,
    output logic misaligned
);

    logic actual_taken;
    logic [31:0] taken_target;
    logic [31:0] target_base, target_sum;
    assign target_base = operation == BR_JALR ? source_1 : pc;
    assign target_sum = target_base + immediate;

    always_comb begin
        taken_target = target_sum;
        if (operation == BR_JALR) taken_target[0] = 1'b0;
        actual_taken = 1'b0;
        unique case (operation)
            BR_EQ: actual_taken = source_1 == source_2;
            BR_NE: actual_taken = source_1 != source_2;
            BR_LT: actual_taken = $signed(source_1) < $signed(source_2);
            BR_GE: actual_taken = $signed(source_1) >= $signed(source_2);
            BR_LTU: actual_taken = source_1 < source_2;
            BR_GEU: actual_taken = source_1 >= source_2;
            BR_JAL: actual_taken = 1'b1;
            BR_JALR: begin
                actual_taken = 1'b1;

            end
        endcase
        target = taken_target;
        misaligned = actual_taken && taken_target[0];
        // already gated by misaligned
        redirect = (operation != BR_NONE) && !misaligned &&
            (actual_taken != predicted_taken);
    end

endmodule
