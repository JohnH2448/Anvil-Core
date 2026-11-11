module RegisterSlice #(
    parameter unsigned SUPPORT_MUL = 1,
    parameter unsigned SUPPORT_DIV = 1,
    parameter unsigned SUPPORT_FLOAT = 1,
    parameter unsigned SUPPORT_ATOMIC = 1
)(
    input logic [31:0] instruction,
    input logic is_compressed,
    output logic [4:0] rs1,
    output logic [4:0] rs2
);

    logic [15:0] c;
    assign c = instruction[15:0];

    // Source numbers only: unused sources are zero. Floating sources retain
    // their architectural register number; register-bank selection is external.
    // This is not an encoding-legality decoder. Illegal encodings may produce
    // source numbers, but disabled instruction classes require no sources.
    always_comb begin
        rs1 = '0;
        rs2 = '0;
        if (is_compressed) begin
            case (c[1:0])
                2'b00: begin
                    case (c[15:13])
                        3'b000: rs1 = 5'd2; // C.ADDI4SPN
                        3'b010: rs1 = {2'b01, c[9:7]}; // C.LW
                        3'b011: if (SUPPORT_FLOAT) rs1 = {2'b01, c[9:7]}; // C.FLW
                        3'b110: begin // C.SW
                            rs1 = {2'b01, c[9:7]};
                            rs2 = {2'b01, c[4:2]};
                        end
                        3'b111: if (SUPPORT_FLOAT) begin // C.FSW
                            rs1 = {2'b01, c[9:7]};
                            rs2 = {2'b01, c[4:2]};
                        end
                        default: ; // No source in the remaining encodings.
                    endcase
                end
                2'b01: begin
                    case (c[15:13])
                        3'b000: rs1 = c[11:7]; // C.ADDI
                        3'b011: if (c[11:7] == 5'd2) rs1 = 5'd2; // C.ADDI16SP
                        3'b100: begin // C shifts / ANDI / register arithmetic
                            rs1 = {2'b01, c[9:7]};
                            if (c[11:10] == 2'b11) rs2 = {2'b01, c[4:2]};
                        end
                        3'b110, 3'b111: rs1 = {2'b01, c[9:7]}; // C.BEQZ / C.BNEZ
                        default: ; // No source in the remaining encodings.
                    endcase
                end
                2'b10: begin
                    case (c[15:13])
                        3'b000: rs1 = c[11:7]; // C.SLLI
                        3'b010: rs1 = 5'd2; // C.LWSP
                        3'b011: if (SUPPORT_FLOAT) rs1 = 5'd2; // C.FLWSP
                        3'b100: begin
                            if (c[6:2] == 0) rs1 = c[11:7]; // C.JR / C.JALR
                            else begin // C.MV / C.ADD
                                if (c[12]) rs1 = c[11:7];
                                rs2 = c[6:2];
                            end
                        end
                        3'b110: begin // C.SWSP
                            rs1 = 5'd2;
                            rs2 = c[6:2];
                        end
                        3'b111: if (SUPPORT_FLOAT) begin // C.FSWSP
                            rs1 = 5'd2;
                            rs2 = c[6:2];
                        end
                        default: ; // No source in the remaining encodings.
                    endcase
                end
                default: ; // No source in the remaining encodings.
            endcase
        end else begin
            case (instruction[6:0])
                7'b0110011: begin // Integer register operations
                    if (instruction[31:25] != 7'b0000001 ||
                        (!instruction[14] && SUPPORT_MUL) ||
                        (instruction[14] && SUPPORT_DIV)) begin
                        rs1 = instruction[19:15];
                        rs2 = instruction[24:20];
                    end
                end
                7'b0010011, 7'b0000011, 7'b1100111: rs1 = instruction[19:15];
                7'b0100011, 7'b1100011: begin // Stores / branches
                    rs1 = instruction[19:15];
                    rs2 = instruction[24:20];
                end
                7'b0000111: if (SUPPORT_FLOAT) rs1 = instruction[19:15];
                7'b0100111: if (SUPPORT_FLOAT) begin
                    rs1 = instruction[19:15];
                    rs2 = instruction[24:20];
                end
                7'b0101111: if (SUPPORT_ATOMIC) begin
                    rs1 = instruction[19:15];
                    if (instruction[31:27] != 5'b00010) rs2 = instruction[24:20]; // Not LR
                end
                7'b1000011, 7'b1000111, 7'b1001011, 7'b1001111:
                    if (SUPPORT_FLOAT) begin // Fused FP; rs3 is outside this interface
                        rs1 = instruction[19:15];
                        rs2 = instruction[24:20];
                    end
                7'b1010011: if (SUPPORT_FLOAT) begin
                    rs1 = instruction[19:15];
                    case (instruction[31:27])
                        5'b00000, 5'b00001, 5'b00010, 5'b00011,
                        5'b00100, 5'b00101, 5'b10100: rs2 = instruction[24:20];
                        default: ; // No source in the remaining encodings.
                    endcase
                end
                7'b1110011: begin // Register CSR forms; zimm is not a source
                    case (instruction[14:12])
                        3'b001, 3'b010, 3'b011: rs1 = instruction[19:15];
                        default: ; // No source in the remaining encodings.
                    endcase
                end
                default: ; // No source in the remaining encodings.
            endcase
        end
    end

endmodule
