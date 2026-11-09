module ArithmaticUnit
    import Enumerations::*;
(
    input AluOperation_ operation,
    input AluSource_ source,
    input logic [31:0] source_1,
    input logic [31:0] source_2,
    input logic [31:0] immediate,
    input logic [31:0] pc,
    output logic [31:0] result
);

    logic [31:0] lhs;
    logic [31:0] rhs;
    logic subtract;
    logic [31:0] sum;

    // ADD/SUB share one adder.
    assign subtract = operation == ALU_SUB;
    assign sum = lhs + (rhs ^ {32{subtract}}) + {31'b0, subtract};

    always_comb begin
        lhs = source_1;
        rhs = source == ALU_RS1_RS2 ? source_2 : immediate;
        case (source)
            ALU_PC_IMM: lhs = pc;
            ALU_ZERO_IMM: lhs = '0;
            default: begin end
        endcase
    end

    always_comb begin
        result = 'x;
        unique case (operation)
            ALU_ADD, ALU_SUB: result = sum;
            ALU_SLL: result = lhs << rhs[4:0];
            ALU_SLT: result = {31'b0, $signed(lhs) < $signed(rhs)};
            ALU_SLTU: result = {31'b0, lhs < rhs};
            ALU_XOR: result = lhs ^ rhs;
            ALU_SRL: result = lhs >> rhs[4:0];
            ALU_SRA: result = $signed(lhs) >>> rhs[4:0];
            ALU_OR: result = lhs | rhs;
            ALU_AND: result = lhs & rhs;
        endcase
    end

endmodule
