module RegisterSlice
    import Parameters::*;
    import DerivedParameters::*;
    import Enumerations::*;
(
    input logic [31:0] instruction,
    input logic is_compressed,
    output logic [4:0] rs1,
    output logic [4:0] rs2,
    output logic [4:0] rd,
    output logic [4:0] rs3,
    output logic rs1_float,
    output logic rs2_float,
    output logic rs3_float,
    output logic rd_float,
    output logic rs1_used,
    output logic reads_rs2,
    output logic rd_written,
    output DecodeCapability_ capability
);

    logic [15:0] c;
    assign c = instruction[15:0];

    // Source numbers only: unused sources are unspecified. Floating sources retain
    // their architectural register number; bank flags are predecoded below.
    // This is not an encoding-legality decoder. Illegal encodings may produce
    // source numbers, but disabled instruction classes require no sources.
    always_comb begin
        rs1 = 'x;
        rs2 = 'x;
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
                    if (SUPPORT_FLOAT) begin // Fused FP
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


    // Register identities and banks only; full decode retains legality/validity.
    always_comb begin
        rd = 'x;
        rs3 = 'x;
        rs1_float = 1'b0;
        rs2_float = 1'b0;
        rs3_float = 1'b0;
        rd_float = 1'b0;
        if (is_compressed) begin
            case (c[1:0])
                2'b00: begin
                    case (c[15:13])
                        3'b000, 3'b010: rd = {2'b01, c[4:2]};
                        3'b011: if (SUPPORT_FLOAT) begin
                            rd = {2'b01, c[4:2]};
                            rd_float = 1'b1;
                        end
                        3'b111: if (SUPPORT_FLOAT) rs2_float = 1'b1;
                        default: ;
                    endcase
                end
                2'b01: begin
                    case (c[15:13])
                        3'b000, 3'b010, 3'b011: rd = c[11:7];
                        3'b001: rd = 5'd1;
                        3'b100: rd = {2'b01, c[9:7]};
                        default: ;
                    endcase
                end
                2'b10: begin
                    case (c[15:13])
                        3'b000, 3'b010: rd = c[11:7];
                        3'b011: if (SUPPORT_FLOAT) begin
                            rd = c[11:7];
                            rd_float = 1'b1;
                        end
                        3'b100: rd = c[6:2] != 0 ? c[11:7] : (c[12] ? 5'd1 : 5'd0);
                        3'b111: if (SUPPORT_FLOAT) rs2_float = 1'b1;
                        default: ;
                    endcase
                end
                default: ;
            endcase
        end else begin
            case (instruction[6:0])
                7'b0110011: begin
                    if (instruction[31:25] != 7'b0000001 ||
                        (!instruction[14] && SUPPORT_MUL) ||
                        (instruction[14] && SUPPORT_DIV)) rd = instruction[11:7];
                end
                7'b0010011, 7'b0000011, 7'b1100111, 7'b1101111,
                7'b0110111, 7'b0010111, 7'b1110011: rd = instruction[11:7];
                7'b0101111: if (SUPPORT_ATOMIC) rd = instruction[11:7];
                7'b0000111: if (SUPPORT_FLOAT) begin
                    rd = instruction[11:7];
                    rd_float = 1'b1;
                end
                7'b0100111: if (SUPPORT_FLOAT) rs2_float = 1'b1;
                7'b1000011, 7'b1000111, 7'b1001011, 7'b1001111:
                    if (SUPPORT_FLOAT) begin
                        rd = instruction[11:7];
                        rs3 = instruction[31:27];
                        rs1_float = 1'b1;
                        rs2_float = 1'b1;
                        rs3_float = 1'b1;
                        rd_float = 1'b1;
                    end
                7'b1010011: if (SUPPORT_FLOAT) begin
                    rd = instruction[11:7];
                    rs1_float = 1'b1;
                    rs2_float = 1'b1;
                    rd_float = 1'b1;
                    case (instruction[31:27])
                        5'b10100, 5'b11000, 5'b11100: rd_float = 1'b0;
                        5'b11010, 5'b11110: rs1_float = 1'b0;
                        default: ;
                    endcase
                end
                default: ;
            endcase
        end
    end

    // Encoding-only scheduling metadata. Deliberately ignores legality: false
    // same-group RAW hazards are allowed, but these bits never authorize writes.
    wire [6:0] op = instruction[6:0];
    wire [2:0] f3 = instruction[14:12];
    wire [6:0] f7 = instruction[31:25];
    wire [4:0] f5 = instruction[31:27];
    // Encoding predicates contain no decoded packet/output dependencies.
    wire r_alu = !is_compressed && op == 7'b0110011 && f7 != 7'b0000001;
    wire i_alu = !is_compressed && op == 7'b0010011;
    wire upper = !is_compressed && (op inside {7'b0110111, 7'b0010111});
    wire mul_op = !is_compressed && SUPPORT_MUL && op == 7'b0110011 && f7 == 1 && !f3[2];
    wire div_op = !is_compressed && SUPPORT_DIV && op == 7'b0110011 && f7 == 1 && f3[2];
    wire branch_op = !is_compressed && op == 7'b1100011;
    wire jal = !is_compressed && op == 7'b1101111;
    wire jalr = !is_compressed && op == 7'b1100111;
    wire load_op = !is_compressed && (op == 7'b0000011 || (SUPPORT_FLOAT && op == 7'b0000111));
    wire store_op = !is_compressed && (op == 7'b0100011 || (SUPPORT_FLOAT && op == 7'b0100111));
    wire atomic_op = !is_compressed && SUPPORT_ATOMIC && op == 7'b0101111;
    wire fused = !is_compressed && SUPPORT_FLOAT && (op inside {7'b1000011,7'b1000111,7'b1001011,7'b1001111});
    wire float_op = !is_compressed && SUPPORT_FLOAT && op == 7'b1010011;
    wire convert_op = float_op && (f5 inside {5'b11000,5'b11010,5'b11100,5'b11110});
    wire csr_op = !is_compressed && op == 7'b1110011 && f3 != 0;
    wire system_op = !is_compressed && (op == 7'b0001111 || (op == 7'b1110011 && f3 == 0));
    wire c_addi4 = is_compressed && c[1:0] == 0 && c[15:13] == 0;
    wire c_ci = is_compressed && c[1:0] == 1 && (c[15:13] inside {3'b000,3'b010,3'b011});
    wire c_math = is_compressed && c[1:0] == 1 && c[15:13] == 4;
    wire c_branch = is_compressed && c[1:0] == 1 && (c[15:13] inside {3'b110,3'b111});
    wire c_jump = is_compressed && c[1:0] == 1 && (c[15:13] inside {3'b001,3'b101});
    wire c_shift = is_compressed && c[1:0] == 2 && c[15:13] == 0;
    wire c_cr = is_compressed && c[1:0] == 2 && c[15:13] == 4;
    wire c_load = is_compressed && (c[1:0] == 0 || c[1:0] == 2) && (c[15:13] == 2 || (SUPPORT_FLOAT && c[15:13] == 3));
    wire c_store = is_compressed && (c[1:0] == 0 || c[1:0] == 2) && (c[15:13] == 6 || (SUPPORT_FLOAT && c[15:13] == 7));
    assign rs1_used = (rs1_float || rs1 != 0) &&
        (r_alu || i_alu || mul_op || div_op || branch_op || jalr ||
         load_op || store_op || atomic_op || fused || float_op ||
         (csr_op && !f3[2]) || c_addi4 || c_load || c_store || c_math ||
         c_branch || c_shift ||
         (c_ci && (c[15:13] == 0 || (c[15:13] == 3 && c[11:7] == 2))) ||
         (c_cr && (c[6:2] == 0 || c[12])));
    assign reads_rs2 =
        (r_alu || mul_op || div_op || branch_op || store_op ||
         (atomic_op && f5 != 2) || fused ||
         (float_op && (f5 inside {5'd0,5'd1,5'd2,5'd3,5'd4,5'd5,5'd20})) ||
         c_store || (c_math && c[11:10] == 3) || (c_cr && c[6:2] != 0));
    assign rd_written = (rd_float || rd != 0) &&
        (r_alu || i_alu || upper || mul_op || div_op || jal || jalr ||
         load_op || atomic_op || fused || float_op || csr_op || c_addi4 ||
         c_ci || c_math || c_shift || c_load || (c_jump && !c[15]) ||
         (c_cr && (c[6:2] != 0 || c[12])));

    // common.capability
    always_comb begin
        capability = CAP_ALU;
        case (1'b1)
            mul_op: capability = CAP_MUL;
            div_op: capability = CAP_DIV;
            branch_op || jal || jalr || c_branch || c_jump || (c_cr && c[6:2] == 0): capability = CAP_BRU;
            load_op || store_op || c_load || c_store: capability = CAP_MEMORY;
            atomic_op: capability = CAP_ATOMIC;
            convert_op: capability = CAP_FP_CONVERT;
            fused || float_op: capability = CAP_FP_F;
            csr_op: capability = CAP_CSR;
            system_op: capability = CAP_SYSTEM;
            default: ;
        endcase
    end

endmodule
