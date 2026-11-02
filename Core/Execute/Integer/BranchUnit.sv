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

    always_comb begin
        taken_target = pc + immediate;
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
                taken_target = (source_1 + immediate) & 32'hfffffffe;
            end
            default: begin end
        endcase
        target = taken_target;
        misaligned = actual_taken && taken_target[0];
        // already gated by misaligned
        redirect = (operation != BR_NONE) && !misaligned &&
            (actual_taken != predicted_taken);
    end

endmodule
