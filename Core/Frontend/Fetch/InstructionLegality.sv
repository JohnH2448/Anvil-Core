// Queue-owned encoding legality, evaluated from registered prediction payloads.
module InstructionLegality
    import Parameters::*;
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
(
    input logic [31:0] instruction,
    input logic is_compressed,
    input TrapType_ system_trap_in,
    output TrapType_ trap
);
    wire [15:0] c = instruction[15:0];
    logic compressed_illegal;

    always_comb begin
        compressed_illegal = 1'b0;
        case (c[1:0])
            2'b00: begin
                case (c[15:13])
                    3'b000: compressed_illegal = c[12:5] == 0;
                    3'b001, 3'b010, 3'b011, 3'b101, 3'b110, 3'b111: ;
                    default: compressed_illegal = 1'b1;
                endcase
            end
            2'b01: begin
                case (c[15:13])
                    3'b011: compressed_illegal = {c[12], c[6:2]} == 0;
                    3'b100: compressed_illegal = c[11:10] != 2'b10 && c[12];
                    default: ;
                endcase
            end
            2'b10: begin
                case (c[15:13])
                    3'b000: compressed_illegal = c[12];
                    3'b010: compressed_illegal = c[11:7] == 0;
                    3'b100: compressed_illegal = c[6:2] == 0 && c[11:7] == 0 && !c[12];
                    3'b001, 3'b011, 3'b101, 3'b110, 3'b111: ;
                    default: compressed_illegal = 1'b1;
                endcase
            end
            default: compressed_illegal = 1'b1;
        endcase
    end

    // Preserve the project's CSR address/read-only-zero policy.
    function automatic TrapType_ full_trap(input logic [31:0] insn);
        logic [6:0] opcode, funct7;
        logic [2:0] funct3;
        logic [4:0] rs2;
        logic rounding;
        opcode = insn[6:0];
        funct3 = insn[14:12];
        funct7 = insn[31:25];
        rs2 = insn[24:20];
        rounding = 1'b0;
        full_trap = NONE;
        case (opcode)
            7'b0110011: begin
                case ({funct7, funct3})
                    10'b0000000000, 10'b0100000000, 10'b0000000001,
                    10'b0000000010, 10'b0000000011, 10'b0000000100,
                    10'b0000000101, 10'b0100000101, 10'b0000000110,
                    10'b0000000111: ;
                    10'b0000001000, 10'b0000001001, 10'b0000001010,
                    10'b0000001011: if (!SUPPORT_MUL) full_trap = ILLEGAL;
                    10'b0000001100, 10'b0000001101, 10'b0000001110,
                    10'b0000001111: if (!SUPPORT_DIV) full_trap = ILLEGAL;
                    default: full_trap = ILLEGAL;
                endcase
            end
            7'b0010011: begin
                if (funct3 == 1 && funct7 != 0) full_trap = ILLEGAL;
                if (funct3 == 5 && funct7 != 0 && funct7 != 7'b0100000) full_trap = ILLEGAL;
            end
            7'b0110111, 7'b0010111, 7'b1101111: ;
            7'b1100011: if (funct3 == 2 || funct3 == 3) full_trap = ILLEGAL;
            7'b1100111: if (funct3 != 0) full_trap = ILLEGAL;
            7'b0000011, 7'b0100011, 7'b0000111, 7'b0100111: begin
                if (opcode[2]) begin
                    if (!SUPPORT_FLOAT || funct3 != 2) full_trap = ILLEGAL;
                end else if (opcode[5]) begin
                    if (funct3 > 2) full_trap = ILLEGAL;
                end else if (!(funct3 inside {3'd0,3'd1,3'd2,3'd4,3'd5})) full_trap = ILLEGAL;
            end
            7'b0101111: begin
                if (!SUPPORT_ATOMIC || funct3 != 2) full_trap = ILLEGAL;
                case (insn[31:27])
                    5'd2: if (rs2 != 0) full_trap = ILLEGAL;
                    5'd3,5'd1,5'd0,5'd4,5'd12,5'd8,5'd16,5'd20,5'd24,5'd28: ;
                    default: full_trap = ILLEGAL;
                endcase
            end
            7'b1000011,7'b1000111,7'b1001011,7'b1001111: begin
                if (!SUPPORT_FLOAT || insn[26:25] != 0 || funct3 == 5 || funct3 == 6)
                    full_trap = ILLEGAL;
            end
            7'b1010011: begin
                case (insn[31:27])
                    5'd0,5'd1,5'd2,5'd3: rounding = 1'b1;
                    5'd11: begin
                        rounding = 1'b1;
                        if (rs2 != 0) full_trap = ILLEGAL;
                    end
                    5'd4,5'd20: if (funct3 > 2) full_trap = ILLEGAL;
                    5'd5: if (funct3 > 1) full_trap = ILLEGAL;
                    5'd24,5'd26: begin
                        rounding = 1'b1;
                        if (rs2[4:1] != 0) full_trap = ILLEGAL;
                    end
                    5'd28: if (rs2 != 0 || funct3 > 1) full_trap = ILLEGAL;
                    5'd30: if (rs2 != 0 || funct3 != 0) full_trap = ILLEGAL;
                    default: full_trap = ILLEGAL;
                endcase
                if (!SUPPORT_FLOAT || funct7[1:0] != 0) full_trap = ILLEGAL;
                if (rounding && (funct3 == 5 || funct3 == 6)) full_trap = ILLEGAL;
            end
            7'b0001111: if (funct3 > 1) full_trap = ILLEGAL;
            7'b1110011: full_trap = system_trap_in;
            default: full_trap = ILLEGAL;
        endcase
    endfunction

    always_comb begin
        trap = full_trap(instruction);
        if (is_compressed) begin
            trap = NONE;
            if (compressed_illegal) trap = ILLEGAL;
            if ((c[1:0] == 2'b00 || c[1:0] == 2'b10) &&
                (c[15:13] inside {3'b001, 3'b011, 3'b101, 3'b111}) &&
                (!SUPPORT_FLOAT || !c[14])) trap = ILLEGAL;
            if (c[1:0] == 2'b10 && c[15:13] == 3'b100 && c[12] &&
                c[11:7] == 0 && c[6:2] == 0) trap = EBREAK;
        end
    end
endmodule
