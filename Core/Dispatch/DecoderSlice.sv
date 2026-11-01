import Enumerations::*;
import Definitions::*;

module DecoderSlice #(
    parameter SUPPORT_MUL = 1,
    parameter SUPPORT_DIV = 1,
    parameter SUPPORT_FLOAT = 1,
    parameter SUPPORT_ATOMIC = 1
)(

    // Working Input Data
    input logic [31:0] instruction,
    input logic [31:0] pc,
    input logic is_branch,
    input logic is_compressed,
    input logic predicted_taken,

    // Output Packet
    output DecodedPacket_ packet,
    output LaneType_ lane_type

);

    // Compressed Register Mapping And Encoding Legality
    // Only Register Fields Are Consumed; Opcode/Function Bits Are Discarded
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] expanded_instruction;
    /* verilator lint_on UNUSEDSIGNAL */
    logic compressed_illegal;
    logic [15:0] c;
    logic [4:0] c_rd;
    logic [4:0] c_rs1;
    logic [4:0] c_rs2;
    logic [11:0] c_immediate;
    logic [20:1] c_jump;
    logic [12:1] c_branch;
    assign c = instruction[15:0];
    assign c_rd = c[11:7];
    assign c_rs1 = {2'b01, c[9:7]};
    assign c_rs2 = {2'b01, c[4:2]};
    assign c_jump = {{9{c[12]}}, c[12], c[8], c[10:9], c[6], c[7],
        c[2], c[11], c[5:3]};
    assign c_branch = {{4{c[12]}}, c[12], c[6:5], c[2], c[11:10], c[4:3]};

    // Reserved Compressed Encodings Never Reach Execution
    always_comb begin
        expanded_instruction = 32'h00000013;
        compressed_illegal = 1'b0;
        c_immediate = '0;
        begin
            case (c[1:0])
                2'b00: begin
                    case (c[15:13])
                        3'b000: begin // C.ADDI4SPN
                            c_immediate = {2'b00, c[10:7], c[12:11], c[5], c[6], 2'b00};
                            expanded_instruction = {c_immediate, 5'd2, 3'b000, c_rs2, 7'b0010011};
                            compressed_illegal = (c_immediate == 0);
                        end
                        3'b001, 3'b010, 3'b011: begin // C.FLD / C.LW / C.FLW
                            if (c[15:13] == 3'b001)
                                c_immediate = {4'b0000, c[6:5], c[12:10], 3'b000};
                            else
                                c_immediate = {5'b00000, c[5], c[12:10], c[6], 2'b00};
                            expanded_instruction = {c_immediate, c_rs1,
                                (c[15:13] == 3'b001 ? 3'b011 : 3'b010), c_rs2,
                                (c[15:13] == 3'b010 ? 7'b0000011 : 7'b0000111)};
                        end
                        3'b101, 3'b110, 3'b111: begin // C.FSD / C.SW / C.FSW
                            if (c[15:13] == 3'b101)
                                c_immediate = {4'b0000, c[6:5], c[12:10], 3'b000};
                            else
                                c_immediate = {5'b00000, c[5], c[12:10], c[6], 2'b00};
                            expanded_instruction = {c_immediate[11:5], c_rs2, c_rs1,
                                (c[15:13] == 3'b101 ? 3'b011 : 3'b010), c_immediate[4:0],
                                (c[15:13] == 3'b110 ? 7'b0100011 : 7'b0100111)};
                        end
                        default: compressed_illegal = 1'b1;
                    endcase
                end
                2'b01: begin
                    c_immediate = {{6{c[12]}}, c[12], c[6:2]};
                    case (c[15:13])
                        3'b000: expanded_instruction = {c_immediate, c_rd, 3'b000, c_rd, 7'b0010011};
                        3'b001, 3'b101: begin // C.JAL / C.J
                            expanded_instruction = {c_jump[20], c_jump[10:1], c_jump[11],
                                c_jump[19:12], (c[15:13] == 3'b001 ? 5'd1 : 5'd0), 7'b1101111};
                        end
                        3'b010: expanded_instruction = {c_immediate, 5'd0, 3'b000, c_rd, 7'b0010011};
                        3'b011: begin
                            if (c_rd == 5'd2) begin // C.ADDI16SP
                                c_immediate = {{2{c[12]}}, c[12], c[4:3], c[5], c[2], c[6], 4'b0000};
                                expanded_instruction = {c_immediate, 5'd2, 3'b000, 5'd2, 7'b0010011};
                            end else begin // C.LUI (rd = 0 is a hint)
                                expanded_instruction = {{14{c[12]}}, c[12], c[6:2], c_rd, 7'b0110111};
                            end
                            compressed_illegal = (c_immediate == 0);
                        end
                        3'b100: begin
                            case (c[11:10])
                                2'b00, 2'b01: begin // C.SRLI / C.SRAI
                                    expanded_instruction = {1'b0, c[10], 5'b00000, c[6:2],
                                        c_rs1, 3'b101, c_rs1, 7'b0010011};
                                    compressed_illegal = c[12];
                                end
                                2'b10: expanded_instruction = {c_immediate, c_rs1, 3'b111, c_rs1, 7'b0010011};
                                2'b11: begin
                                    case (c[6:5])
                                        2'b00: expanded_instruction = {7'b0100000, c_rs2, c_rs1, 3'b000, c_rs1, 7'b0110011};
                                        2'b01: expanded_instruction = {7'b0000000, c_rs2, c_rs1, 3'b100, c_rs1, 7'b0110011};
                                        2'b10: expanded_instruction = {7'b0000000, c_rs2, c_rs1, 3'b110, c_rs1, 7'b0110011};
                                        2'b11: expanded_instruction = {7'b0000000, c_rs2, c_rs1, 3'b111, c_rs1, 7'b0110011};
                                    endcase
                                    compressed_illegal = c[12]; // RV64 arithmetic
                                end
                            endcase
                        end
                        3'b110, 3'b111: begin // C.BEQZ / C.BNEZ
                            expanded_instruction = {c_branch[12], c_branch[10:5], 5'd0, c_rs1,
                                2'b00, c[13], c_branch[4:1], c_branch[11], 7'b1100011};
                        end
                    endcase
                end
                2'b10: begin
                    case (c[15:13])
                        3'b000: begin // C.SLLI
                            expanded_instruction = {7'b0000000, c[6:2], c_rd, 3'b001, c_rd, 7'b0010011};
                            compressed_illegal = c[12];
                        end
                        3'b001, 3'b010, 3'b011: begin // C.FLDSP / C.LWSP / C.FLWSP
                            if (c[15:13] == 3'b001)
                                c_immediate = {3'b000, c[4:2], c[12], c[6:5], 3'b000};
                            else
                                c_immediate = {4'b0000, c[3:2], c[12], c[6:4], 2'b00};
                            expanded_instruction = {c_immediate, 5'd2,
                                (c[15:13] == 3'b001 ? 3'b011 : 3'b010), c_rd,
                                (c[15:13] == 3'b010 ? 7'b0000011 : 7'b0000111)};
                            compressed_illegal = (c[15:13] == 3'b010) && (c_rd == 0);
                        end
                        3'b100: begin
                            if (c[6:2] == 0) begin
                                if (c[12] && c_rd == 0)
                                    expanded_instruction = 32'h00100073; // C.EBREAK
                                else begin
                                    expanded_instruction = {12'd0, c_rd, 3'b000,
                                        (c[12] ? 5'd1 : 5'd0), 7'b1100111};
                                    compressed_illegal = (c_rd == 0);
                                end
                            end else begin // C.MV / C.ADD
                                expanded_instruction = {7'b0000000, c[6:2],
                                    (c[12] ? c_rd : 5'd0), 3'b000, c_rd, 7'b0110011};
                            end
                        end
                        3'b101, 3'b110, 3'b111: begin // C.FSDSP / C.SWSP / C.FSWSP
                            if (c[15:13] == 3'b101)
                                c_immediate = {3'b000, c[9:7], c[12:10], 3'b000};
                            else
                                c_immediate = {4'b0000, c[8:7], c[12:9], 2'b00};
                            expanded_instruction = {c_immediate[11:5], c[6:2], 5'd2,
                                (c[15:13] == 3'b101 ? 3'b011 : 3'b010), c_immediate[4:0],
                                (c[15:13] == 3'b110 ? 7'b0100011 : 7'b0100111)};
                        end
                        default: compressed_illegal = 1'b1;
                    endcase
                end
                default: compressed_illegal = 1'b1;
            endcase
        end
    end

    // Independent Cones Avoid A Shared Expansion Mux Before Opcode Decode
    function automatic Definitions::DecodedPacket_ decode_packet(
        input logic [31:0] decode_instruction,
        input logic decode_illegal,
        output LaneType_ decoded_lane_type
    );
        logic [6:0] opcode;
        logic [2:0] funct3;
        logic [6:0] funct7;
        logic [4:0] rs1;
        logic [4:0] rs2;
        logic [4:0] rd;
        logic [31:0] immediate_i;
        logic [31:0] immediate_s;
        logic [31:0] immediate_b;
        logic [31:0] immediate_u;
        logic [31:0] immediate_j;
        logic [11:0] csr_address;
        CSR_R csr_index;
        logic csr_legal;
        logic csr_read_only;
        logic uses_rounding;
        // Shared Instruction Fields And Immediate Wiring
        opcode = decode_instruction[6:0];
        funct3 = decode_instruction[14:12];
        funct7 = decode_instruction[31:25];
        rs1 = decode_instruction[19:15];
        rs2 = decode_instruction[24:20];
        rd = decode_instruction[11:7];
        immediate_i = {{20{decode_instruction[31]}}, decode_instruction[31:20]};
        immediate_s = {{20{decode_instruction[31]}}, decode_instruction[31:25], decode_instruction[11:7]};
        immediate_b = {{19{decode_instruction[31]}}, decode_instruction[31], decode_instruction[7],
            decode_instruction[30:25], decode_instruction[11:8], 1'b0};
        immediate_u = {decode_instruction[31:12], 12'd0};
        immediate_j = {{11{decode_instruction[31]}}, decode_instruction[31], decode_instruction[19:12],
            decode_instruction[20], decode_instruction[30:21], 1'b0};

        // CSR Address Mapping Runs In Parallel With Operation Decode
        csr_address = decode_instruction[31:20];
        csr_index = ROZ_R;
        csr_legal = 1'b1;
        csr_read_only = 1'b0;
        case (csr_address)
            MSTATUS: csr_index = MSTATUS_R; 
            MTVEC: csr_index = MTVEC_R;
            MIP: csr_index = MIP_R;
            MIE: csr_index = MIE_R;
            MCYCLE: csr_index = MCYCLE_R;
            MCYCLEH: csr_index = MCYCLEH_R;
            MINSTRET: csr_index = MINSTRET_R;
            MINSTRETH: csr_index = MINSTRETH_R;
            MSCRATCH: csr_index = MSCRATCH_R;
            MEPC: csr_index = MEPC_R;
            MCAUSE: csr_index = MCAUSE_R;
            MISA: csr_index = MISA_R;
            12'h001: begin csr_index = FFLAGS_R; csr_legal = (SUPPORT_FLOAT != 0); end
            12'h002: begin csr_index = FRM_R; csr_legal = (SUPPORT_FLOAT != 0); end
            12'h003: begin csr_index = FCSR_R; csr_legal = (SUPPORT_FLOAT != 0); end
            MVENDORID, MARCHID, MIMPID, MHARTID, MCONFIGPTR,
            MEDELEG, MIDELEG, MCOUNTEREN, MSTATUSH, MTVAL: csr_read_only = 1'b1;
            default: begin
                // Preserve The Project's Read-Only-Zero CSR Policy
                csr_read_only = 1'b1;
                csr_legal = ((csr_address >= 12'hB03) && (csr_address <= 12'hB1F)) ||
                    ((csr_address >= 12'hB83) && (csr_address <= 12'hB9F)) ||
                    ((csr_address >= 12'h323) && (csr_address <= 12'h33F));
            end
        endcase

        // Full Decode
        decode_packet = '0;
        decoded_lane_type = INTEGER;
        decode_packet.common.pc = pc;
        decode_packet.bru.is_branch = is_branch;
        decode_packet.bru.is_compressed = is_compressed;
        decode_packet.bru.predicted_taken = predicted_taken;
        decode_packet.csr.index = ROZ_R;
        decode_packet.common.rs1 = rs1;
        decode_packet.common.rs2 = rs2;
        decode_packet.fp.rs3 = decode_instruction[31:27];
        decode_packet.common.rd = rd;
        uses_rounding = 1'b0;

        case (opcode)
            7'b0110011: begin // Integer Register Operations
                TrapType_ operation_trap;
                operation_trap = NONE;
                decode_packet.common.rs1_valid = 1'b1;
                decode_packet.common.rs2_valid = 1'b1;
                decode_packet.common.rd_valid = 1'b1;
                case ({funct7, funct3})
                    10'b0000000000: decode_packet.alu.operation = ALU_ADD;
                    10'b0100000000: decode_packet.alu.operation = ALU_SUB;
                    10'b0000000001: decode_packet.alu.operation = ALU_SLL;
                    10'b0000000010: decode_packet.alu.operation = ALU_SLT;
                    10'b0000000011: decode_packet.alu.operation = ALU_SLTU;
                    10'b0000000100: decode_packet.alu.operation = ALU_XOR;
                    10'b0000000101: decode_packet.alu.operation = ALU_SRL;
                    10'b0100000101: decode_packet.alu.operation = ALU_SRA;
                    10'b0000000110: decode_packet.alu.operation = ALU_OR;
                    10'b0000000111: decode_packet.alu.operation = ALU_AND;
                    10'b0000001000: begin decode_packet.mul.operation = MUL_LOW; decode_packet.common.capability = CAP_MUL; if (!SUPPORT_MUL) operation_trap = ILLEGAL; end
                    10'b0000001001: begin decode_packet.mul.operation = MUL_HIGH_SS; decode_packet.common.capability = CAP_MUL; if (!SUPPORT_MUL) operation_trap = ILLEGAL; end
                    10'b0000001010: begin decode_packet.mul.operation = MUL_HIGH_SU; decode_packet.common.capability = CAP_MUL; if (!SUPPORT_MUL) operation_trap = ILLEGAL; end
                    10'b0000001011: begin decode_packet.mul.operation = MUL_HIGH_UU; decode_packet.common.capability = CAP_MUL; if (!SUPPORT_MUL) operation_trap = ILLEGAL; end
                    10'b0000001100: begin decode_packet.div.operation = DIV_SIGNED; decode_packet.common.capability = CAP_DIV; if (!SUPPORT_DIV) operation_trap = ILLEGAL; end
                    10'b0000001101: begin decode_packet.div.operation = DIV_UNSIGNED; decode_packet.common.capability = CAP_DIV; if (!SUPPORT_DIV) operation_trap = ILLEGAL; end
                    10'b0000001110: begin decode_packet.div.operation = REM_SIGNED; decode_packet.common.capability = CAP_DIV; if (!SUPPORT_DIV) operation_trap = ILLEGAL; end
                    10'b0000001111: begin decode_packet.div.operation = REM_UNSIGNED; decode_packet.common.capability = CAP_DIV; if (!SUPPORT_DIV) operation_trap = ILLEGAL; end
                    default: operation_trap = ILLEGAL;
                endcase
                // Suppress Only This Instruction Class On A Local Trap
                decode_packet.common.trap_type = operation_trap;
                if (operation_trap != NONE) begin
                    decode_packet.common.rs1_valid = 1'b0;
                    decode_packet.common.rs2_valid = 1'b0;
                    decode_packet.common.rd_valid = 1'b0;
                    decoded_lane_type = SERIAL;
                end
            end
            7'b0010011: begin // Integer Immediate Operations
                TrapType_ operation_trap;
                operation_trap = NONE;
                decode_packet.common.rs1_valid = 1'b1;
                decode_packet.common.rd_valid = 1'b1;
                decode_packet.alu.source = ALU_RS1_IMM;
                case (funct3)
                    3'b000: decode_packet.alu.operation = ALU_ADD;
                    3'b010: decode_packet.alu.operation = ALU_SLT;
                    3'b011: decode_packet.alu.operation = ALU_SLTU;
                    3'b100: decode_packet.alu.operation = ALU_XOR;
                    3'b110: decode_packet.alu.operation = ALU_OR;
                    3'b111: decode_packet.alu.operation = ALU_AND;
                    3'b001: begin
                        decode_packet.alu.operation = ALU_SLL;
                        if (funct7 != 7'b0000000) operation_trap = ILLEGAL;
                    end
                    3'b101: begin
                        decode_packet.alu.operation = decode_instruction[30] ? ALU_SRA : ALU_SRL;
                        if (funct7 != 7'b0000000 && funct7 != 7'b0100000) operation_trap = ILLEGAL;
                    end
                endcase
                // Suppress Only This Instruction Class On A Local Trap
                decode_packet.common.trap_type = operation_trap;
                if (operation_trap != NONE) begin
                    decode_packet.common.rs1_valid = 1'b0;
                    decode_packet.common.rd_valid = 1'b0;
                    decoded_lane_type = SERIAL;
                end else decode_packet.alu.immediate = immediate_i;
            end
            7'b0110111, 7'b0010111: begin // LUI / AUIPC
                decode_packet.common.rd_valid = 1'b1;
                decode_packet.alu.immediate = immediate_u;
                decode_packet.alu.source = opcode[5] ? ALU_ZERO_IMM : ALU_PC_IMM;
            end
            7'b1100011: begin // Conditional Branches
                TrapType_ operation_trap;
                operation_trap = NONE;
                decode_packet.common.rs1_valid = 1'b1;
                decode_packet.common.rs2_valid = 1'b1;
                case (funct3)
                    3'b000: decode_packet.bru.operation = BR_EQ;
                    3'b001: decode_packet.bru.operation = BR_NE;
                    3'b100: decode_packet.bru.operation = BR_LT;
                    3'b101: decode_packet.bru.operation = BR_GE;
                    3'b110: decode_packet.bru.operation = BR_LTU;
                    3'b111: decode_packet.bru.operation = BR_GEU;
                    default: operation_trap = ILLEGAL;
                endcase
                // Suppress Only This Instruction Class On A Local Trap
                decode_packet.common.trap_type = operation_trap;
                if (operation_trap != NONE) begin
                    decode_packet.common.rs1_valid = 1'b0;
                    decode_packet.common.rs2_valid = 1'b0;
                    decode_packet.bru.operation = BR_NONE;
                    decoded_lane_type = SERIAL;
                end else decode_packet.bru.immediate = immediate_b;
            end
            7'b1101111: begin // JAL
                decode_packet.common.rd_valid = 1'b1;
                decode_packet.alu.source = ALU_PC_IMM;
                decode_packet.bru.operation = BR_JAL;
                decode_packet.bru.immediate = immediate_j;
            end
            7'b1100111: begin // JALR
                TrapType_ operation_trap;
                operation_trap = NONE;
                decode_packet.common.rs1_valid = 1'b1;
                decode_packet.common.rd_valid = 1'b1;
                decode_packet.alu.source = ALU_RS1_IMM;
                decode_packet.bru.operation = BR_JALR;
                if (funct3 != 0) operation_trap = ILLEGAL;
                // Suppress Only This Instruction Class On A Local Trap
                decode_packet.common.trap_type = operation_trap;
                if (operation_trap != NONE) begin
                    decode_packet.common.rs1_valid = 1'b0;
                    decode_packet.common.rd_valid = 1'b0;
                    decode_packet.bru.operation = BR_NONE;
                    decoded_lane_type = SERIAL;
                end else decode_packet.bru.immediate = immediate_i;
            end
            7'b0000011, 7'b0100011, 7'b0000111, 7'b0100111: begin
                TrapType_ operation_trap;
                operation_trap = NONE;
                // Integer And Floating Memory Operations
                decoded_lane_type = MEMORY;
                decode_packet.common.rs1_valid = 1'b1;
                decode_packet.alu.source = ALU_RS1_IMM;
                decode_packet.memory.size = MemorySize_'(funct3[1:0]);
                if (opcode[5]) begin
                    decode_packet.common.rs2_valid = 1'b1;
                    decode_packet.common.rs2_float = opcode[2];
                    decode_packet.memory.operation = MEM_STORE;
                end else begin
                    decode_packet.common.rd_valid = 1'b1;
                    decode_packet.common.rd_float = opcode[2];
                    decode_packet.memory.operation = MEM_LOAD;
                    decode_packet.memory.sign_extend = !funct3[2] && !opcode[2];
                end
                if (opcode[2]) begin
                    if (!SUPPORT_FLOAT || (funct3 != 3'b010)) operation_trap = ILLEGAL;
                end else if (opcode[5]) begin
                    if (funct3 > 3'b010) operation_trap = ILLEGAL;
                end else begin
                    case (funct3)
                        3'b000, 3'b001, 3'b010, 3'b100, 3'b101: ;
                        default: operation_trap = ILLEGAL;
                    endcase
                end
                // Suppress Only This Instruction Class On A Local Trap
                decode_packet.common.trap_type = operation_trap;
                if (operation_trap != NONE) begin
                    decode_packet.common.rs1_valid = 1'b0;
                    decode_packet.common.rs2_valid = 1'b0;
                    decode_packet.common.rd_valid = 1'b0;
                    decode_packet.memory.operation = MEM_NONE;
                    decode_packet.atomic.operation = ATOM_NONE;
                    decoded_lane_type = SERIAL;
                end else decode_packet.memory.immediate = opcode[5] ? immediate_s : immediate_i;
            end
            7'b0101111: begin // RV32 Word Atomics
                TrapType_ operation_trap;
                operation_trap = NONE;
                decoded_lane_type = MEMORY;
                decode_packet.common.rs1_valid = 1'b1;
                decode_packet.common.rs2_valid = 1'b1;
                decode_packet.common.rd_valid = 1'b1;
                decode_packet.alu.source = ALU_RS1_IMM;
                decode_packet.memory.size = MEM_WORD;
                decode_packet.atomic.acquire = decode_instruction[26];
                decode_packet.atomic.release_order = decode_instruction[25];
                case (decode_instruction[31:27])
                    5'b00010: begin
                        decode_packet.atomic.operation = ATOM_LR;
                        decode_packet.common.rs2_valid = 1'b0;
                        if (rs2 != 0) operation_trap = ILLEGAL;
                    end
                    5'b00011: decode_packet.atomic.operation = ATOM_SC;
                    5'b00001: decode_packet.atomic.operation = ATOM_SWAP;
                    5'b00000: decode_packet.atomic.operation = ATOM_ADD;
                    5'b00100: decode_packet.atomic.operation = ATOM_XOR;
                    5'b01100: decode_packet.atomic.operation = ATOM_AND;
                    5'b01000: decode_packet.atomic.operation = ATOM_OR;
                    5'b10000: decode_packet.atomic.operation = ATOM_MIN;
                    5'b10100: decode_packet.atomic.operation = ATOM_MAX;
                    5'b11000: decode_packet.atomic.operation = ATOM_MINU;
                    5'b11100: decode_packet.atomic.operation = ATOM_MAXU;
                    default: operation_trap = ILLEGAL;
                endcase
                if (!SUPPORT_ATOMIC || funct3 != 3'b010) operation_trap = ILLEGAL;
                // Suppress Only This Instruction Class On A Local Trap
                decode_packet.common.trap_type = operation_trap;
                if (operation_trap != NONE) begin
                    decode_packet.common.rs1_valid = 1'b0;
                    decode_packet.common.rs2_valid = 1'b0;
                    decode_packet.common.rd_valid = 1'b0;
                    decode_packet.memory.operation = MEM_NONE;
                    decode_packet.atomic.operation = ATOM_NONE;
                    decoded_lane_type = SERIAL;
                end
            end
            7'b1000011, 7'b1000111, 7'b1001011, 7'b1001111: begin
                TrapType_ operation_trap;
                operation_trap = NONE;
                // Fused Floating Operations
                decoded_lane_type = FLOATING;
                decode_packet.common.rs1_valid = 1'b1;
                decode_packet.common.rs2_valid = 1'b1;
                decode_packet.fp.rs3_valid = 1'b1;
                decode_packet.common.rd_valid = 1'b1;
                decode_packet.common.rs1_float = 1'b1;
                decode_packet.common.rs2_float = 1'b1;
                decode_packet.fp.rs3_float = 1'b1;
                decode_packet.common.rd_float = 1'b1;
                decode_packet.fp.rounding_mode = funct3;
                uses_rounding = 1'b1;
                case (opcode[3:2])
                    2'b00: decode_packet.fp.operation = FP_MADD;
                    2'b01: decode_packet.fp.operation = FP_MSUB;
                    2'b10: decode_packet.fp.operation = FP_NMSUB;
                    2'b11: decode_packet.fp.operation = FP_NMADD;
                endcase
                if (!SUPPORT_FLOAT || decode_instruction[26] ||
                    decode_instruction[25]) operation_trap = ILLEGAL;
                if (uses_rounding && (funct3 == 3'b101 || funct3 == 3'b110)) operation_trap = ILLEGAL;
                // Suppress Only This Instruction Class On A Local Trap
                decode_packet.common.trap_type = operation_trap;
                if (operation_trap != NONE) begin
                    decode_packet.common.rs1_valid = 1'b0;
                    decode_packet.common.rs2_valid = 1'b0;
                    decode_packet.fp.rs3_valid = 1'b0;
                    decode_packet.common.rd_valid = 1'b0;
                    decode_packet.fp.operation = FP_NONE;
                    decoded_lane_type = SERIAL;
                end
            end
            7'b1010011: begin // Floating Operations
                TrapType_ operation_trap;
                operation_trap = NONE;
                decoded_lane_type = FLOATING;
                decode_packet.common.rs1_valid = 1'b1;
                decode_packet.common.rs2_valid = 1'b1;
                decode_packet.common.rd_valid = 1'b1;
                decode_packet.common.rs1_float = 1'b1;
                decode_packet.common.rs2_float = 1'b1;
                decode_packet.common.rd_float = 1'b1;
                decode_packet.fp.rounding_mode = funct3;
                case (funct7[6:2])
                    5'b00000: begin decode_packet.fp.operation = FP_ADD; uses_rounding = 1'b1; end
                    5'b00001: begin decode_packet.fp.operation = FP_SUB; uses_rounding = 1'b1; end
                    5'b00010: begin decode_packet.fp.operation = FP_MUL; uses_rounding = 1'b1; end
                    5'b00011: begin decode_packet.fp.operation = FP_DIV; uses_rounding = 1'b1; end
                    5'b01011: begin
                        decode_packet.fp.operation = FP_SQRT;
                        decode_packet.common.rs2_valid = 1'b0;
                        uses_rounding = 1'b1;
                        if (rs2 != 0) operation_trap = ILLEGAL;
                    end
                    5'b00100: begin
                        case (funct3)
                            3'b000: decode_packet.fp.operation = FP_SGNJ;
                            3'b001: decode_packet.fp.operation = FP_SGNJN;
                            3'b010: decode_packet.fp.operation = FP_SGNJX;
                            default: operation_trap = ILLEGAL;
                        endcase
                    end
                    5'b00101: begin
                        case (funct3)
                            3'b000: decode_packet.fp.operation = FP_MIN;
                            3'b001: decode_packet.fp.operation = FP_MAX;
                            default: operation_trap = ILLEGAL;
                        endcase
                    end
                    5'b10100: begin
                        decode_packet.common.rd_float = 1'b0;
                        case (funct3)
                            3'b000: decode_packet.fp.operation = FP_LE;
                            3'b001: decode_packet.fp.operation = FP_LT;
                            3'b010: decode_packet.fp.operation = FP_EQ;
                            default: operation_trap = ILLEGAL;
                        endcase
                    end
                    5'b11000, 5'b11010: begin // Word Conversions Only On RV32
                        decode_packet.fp.operation = funct7[3] ? FP_FROM_INT : FP_TO_INT;
                        decode_packet.common.rs1_float = !funct7[3];
                        decode_packet.common.rd_float = funct7[3];
                        decode_packet.common.rs2_valid = 1'b0;
                        decode_packet.fp_convert.is_unsigned = rs2[0];
                        uses_rounding = 1'b1;
                        if (rs2[4:1] != 0) operation_trap = ILLEGAL;
                    end
                    5'b11100: begin
                        decode_packet.common.rd_float = 1'b0;
                        decode_packet.common.rs2_valid = 1'b0;
                        if (funct3 == 3'b001) decode_packet.fp.operation = FP_CLASS;
                        else if (funct3 == 0 && !funct7[0]) decode_packet.fp.operation = FP_TO_BITS;
                        else operation_trap = ILLEGAL;
                        if (rs2 != 0) operation_trap = ILLEGAL;
                    end
                    5'b11110: begin
                        decode_packet.fp.operation = FP_FROM_BITS;
                        decode_packet.common.rs1_float = 1'b0;
                        decode_packet.common.rs2_valid = 1'b0;
                        if (rs2 != 0 || funct3 != 0 || funct7[0]) operation_trap = ILLEGAL;
                    end
                    default: operation_trap = ILLEGAL;
                endcase
                if (!SUPPORT_FLOAT || funct7[1] || funct7[0]) operation_trap = ILLEGAL;
                if (uses_rounding && (funct3 == 3'b101 || funct3 == 3'b110)) operation_trap = ILLEGAL;
                // Suppress Only This Instruction Class On A Local Trap
                decode_packet.common.trap_type = operation_trap;
                if (operation_trap != NONE) begin
                    decode_packet.common.rs1_valid = 1'b0;
                    decode_packet.common.rs2_valid = 1'b0;
                    decode_packet.common.rd_valid = 1'b0;
                    decode_packet.fp.operation = FP_NONE;
                    decoded_lane_type = SERIAL;
                end
            end
            7'b0001111: begin // Fences Must Reach The Serial Lane
                TrapType_ operation_trap;
                operation_trap = NONE;
                decoded_lane_type = SERIAL;
                case (funct3)
                    3'b000: begin
                        decode_packet.system.operation = SYS_FENCE;
                        decode_packet.system.fence_predecessor = decode_instruction[27:24];
                        decode_packet.system.fence_successor = decode_instruction[23:20];
                    end
                    3'b001: decode_packet.system.operation = SYS_FENCE_I;
                    default: operation_trap = ILLEGAL;
                endcase
                // Suppress Only This Instruction Class On A Local Trap
                decode_packet.common.trap_type = operation_trap;
                if (operation_trap != NONE) begin
                    decode_packet.system.operation = SYS_NONE;
                    decode_packet.csr.operation = CSR_NONE;
                    decoded_lane_type = SERIAL;
                end
            end
            7'b1110011: begin
                TrapType_ operation_trap;
                operation_trap = NONE;
                decoded_lane_type = SERIAL;
                if (funct3 == 0) begin
                    case (decode_instruction)
                        32'h00000073: operation_trap = ECALL;
                        32'h00100073: operation_trap = EBREAK;
                        32'h30200073: decode_packet.system.operation = SYS_MRET; // Implicit MEPC read
                        32'h10500073: decode_packet.system.operation = SYS_WFI;
                        default: operation_trap = ILLEGAL;
                    endcase
                end else begin
                    decode_packet.csr.index = csr_index;
                    decode_packet.common.rd_valid = 1'b1;
                    decode_packet.common.rs1_valid = !funct3[2];
                    decode_packet.csr.use_immediate = funct3[2];
                    decode_packet.csr.read_enable = 1'b1;
                    decode_packet.csr.write_enable = (rs1 != 0);
                    case (funct3)
                        3'b001, 3'b101: begin
                            decode_packet.csr.operation = CSR_RW;
                            decode_packet.csr.read_enable = (rd != 0);
                            decode_packet.csr.write_enable = 1'b1;
                        end
                        3'b010, 3'b110: decode_packet.csr.operation = CSR_RS;
                        3'b011, 3'b111: decode_packet.csr.operation = CSR_RC;
                        default: operation_trap = ILLEGAL;
                    endcase
                    if (!csr_legal || (csr_read_only && decode_packet.csr.write_enable)) operation_trap = ILLEGAL;
                end
                // Suppress Only This Instruction Class On A Local Trap
                decode_packet.common.trap_type = operation_trap;
                if (operation_trap != NONE) begin
                    decode_packet.common.rs1_valid = 1'b0;
                    decode_packet.common.rd_valid = 1'b0;
                    decode_packet.system.operation = SYS_NONE;
                    decode_packet.csr.operation = CSR_NONE;
                    decode_packet.csr.read_enable = 1'b0;
                    decode_packet.csr.write_enable = 1'b0;
                    decoded_lane_type = SERIAL;
                end else if (funct3 != 0) decode_packet.csr.immediate = rs1;
            end
            default: begin
                decode_packet.common.trap_type = ILLEGAL;
                decoded_lane_type = SERIAL;
            end
        endcase

        if (decode_illegal) decode_packet.common.trap_type = ILLEGAL;

        // Integer Zero Has No Dependency; Floating Register Zero Is Ordinary
        decode_packet.common.rs1_valid = decode_packet.common.rs1_valid && (decode_packet.common.rs1_float || rs1 != 0);
        decode_packet.common.rs2_valid = decode_packet.common.rs2_valid && (decode_packet.common.rs2_float || rs2 != 0);
        decode_packet.common.rd_valid = decode_packet.common.rd_valid && (decode_packet.common.rd_float || rd != 0);

        // Optional Caller-Supplied Legality Override
        if (decode_illegal) begin
            decode_packet.common.rs1_valid = 1'b0;
            decode_packet.common.rs2_valid = 1'b0;
            decode_packet.fp.rs3_valid = 1'b0;
            decode_packet.common.rd_valid = 1'b0;
            decode_packet.memory.operation = MEM_NONE;
            decode_packet.atomic.operation = ATOM_NONE;
            decode_packet.bru.operation = BR_NONE;
            decode_packet.fp.operation = FP_NONE;
            decode_packet.system.operation = SYS_NONE;
            decode_packet.csr.operation = CSR_NONE;
            decode_packet.csr.read_enable = 1'b0;
            decode_packet.csr.write_enable = 1'b0;
            decoded_lane_type = SERIAL;
        end

        // Route by execution capability, independently of fetch branch metadata.
        if (decode_packet.common.trap_type != NONE) decode_packet.common.capability = CAP_TRAP;
        else case (decoded_lane_type)
            INTEGER: if (decode_packet.bru.operation != BR_NONE) decode_packet.common.capability = CAP_BRU;
            FLOATING: begin
                // All conversions remain on floating lanes, independently of F/D arithmetic.
                case (decode_packet.fp.operation)
                    FP_FROM_INT:  decode_packet.fp_convert.operation = FPC_FROM_INT;
                    FP_TO_INT:    decode_packet.fp_convert.operation = FPC_TO_INT;
                    FP_FROM_BITS: decode_packet.fp_convert.operation = FPC_FROM_BITS;
                    FP_TO_BITS:   decode_packet.fp_convert.operation = FPC_TO_BITS;
                    FP_CLASS:     decode_packet.fp_convert.operation = FPC_CLASS;
                    default: ;
                endcase
                if (decode_packet.fp_convert.operation != FPC_NONE) begin
                    decode_packet.common.capability = CAP_FP_CONVERT;
                    decode_packet.fp_convert.rounding_mode = decode_packet.fp.rounding_mode;
                    decode_packet.fp = '0;
                end else decode_packet.common.capability = CAP_FP_F;
            end
            MEMORY: decode_packet.common.capability = decode_packet.atomic.operation != ATOM_NONE ? CAP_ATOMIC : CAP_MEMORY;
            SERIAL: decode_packet.common.capability = decode_packet.csr.operation != CSR_NONE ? CAP_CSR : CAP_SYSTEM;
            default: ;
        endcase
    endfunction

    // Compressed Controls Are Decoded Directly From The 16-Bit Encoding
    logic [31:0] compressed_immediate;
    DecodedPacket_ packet_full;
    DecodedPacket_ packet_compressed;
    LaneType_ lane_type_full;
    LaneType_ lane_type_compressed;
    always_comb begin
        packet_compressed = '0;
        lane_type_compressed = INTEGER;
        compressed_immediate = '0;
        packet_compressed.common.pc = pc;
        packet_compressed.bru.is_branch = is_branch;
        packet_compressed.bru.is_compressed = is_compressed;
        packet_compressed.bru.predicted_taken = predicted_taken;
        packet_compressed.csr.index = ROZ_R;
        // Expansion Is Used Only For Architectural Register Numbers
        packet_compressed.common.rs1 = expanded_instruction[19:15];
        packet_compressed.common.rs2 = expanded_instruction[24:20];
        packet_compressed.fp.rs3 = expanded_instruction[31:27];
        packet_compressed.common.rd = expanded_instruction[11:7];
        packet_compressed.alu.source = ALU_RS1_IMM;

        case (c[1:0])
            2'b00: begin
                case (c[15:13])
                    3'b000: begin // C.ADDI4SPN
                        packet_compressed.common.rs1_valid = 1'b1;
                        packet_compressed.common.rd_valid = 1'b1;
                        compressed_immediate = {22'd0, c[10:7], c[12:11], c[5], c[6], 2'd0};
                    end
                    3'b001, 3'b010, 3'b011, 3'b101, 3'b110, 3'b111: begin
                        lane_type_compressed = MEMORY;
                        packet_compressed.common.rs1_valid = 1'b1;
                        compressed_immediate = c[14:13] == 2'b01 ?
                            {24'd0, c[6:5], c[12:10], 3'd0} :
                            {25'd0, c[5], c[12:10], c[6], 2'd0};
                        packet_compressed.memory.size = MemorySize_'(c[14:13] == 2'b01 ? 2'b11 : 2'b10);
                        if (c[15]) begin
                            packet_compressed.memory.operation = MEM_STORE;
                            packet_compressed.common.rs2_valid = 1'b1;
                            packet_compressed.common.rs2_float = c[13];
                        end else begin
                            packet_compressed.memory.operation = MEM_LOAD;
                            packet_compressed.memory.sign_extend = !c[13];
                            packet_compressed.common.rd_valid = 1'b1;
                            packet_compressed.common.rd_float = c[13];
                        end
                        if (c[13] && (!SUPPORT_FLOAT || !c[14]))
                            packet_compressed.common.trap_type = ILLEGAL;
                    end
                    default: ;
                endcase
            end
            2'b01: begin
                case (c[15:13])
                    3'b000, 3'b010: begin // C.ADDI / C.LI
                        packet_compressed.common.rs1_valid = !c[14] && (c_rd != 0);
                        packet_compressed.common.rd_valid = (c_rd != 0);
                        compressed_immediate = {{26{c[12]}}, c[12], c[6:2]};
                    end
                    3'b001, 3'b101: begin // C.JAL / C.J
                        packet_compressed.common.rd_valid = !c[15];
                        packet_compressed.alu.source = ALU_PC_IMM;
                        packet_compressed.bru.operation = BR_JAL;
                        compressed_immediate = {{11{c_jump[20]}}, c_jump, 1'b0};
                    end
                    3'b011: begin // C.ADDI16SP / C.LUI
                        packet_compressed.common.rd_valid = (c_rd != 0);
                        if (c_rd == 5'd2) begin
                            packet_compressed.common.rs1_valid = 1'b1;
                            compressed_immediate = {{22{c[12]}}, c[12], c[4:3], c[5], c[2], c[6], 4'd0};
                        end else begin
                            packet_compressed.alu.source = ALU_ZERO_IMM;
                            compressed_immediate = {{14{c[12]}}, c[12], c[6:2], 12'd0};
                        end
                    end
                    3'b100: begin
                        packet_compressed.common.rs1_valid = 1'b1;
                        packet_compressed.common.rd_valid = 1'b1;
                        case (c[11:10])
                            2'b00, 2'b01: begin // C.SRLI / C.SRAI
                                packet_compressed.alu.operation = c[10] ? ALU_SRA : ALU_SRL;
                                compressed_immediate = {21'd0, c[10], 5'd0, c[6:2]};
                            end
                            2'b10: begin // C.ANDI
                                packet_compressed.alu.operation = ALU_AND;
                                compressed_immediate = {{26{c[12]}}, c[12], c[6:2]};
                            end
                            2'b11: begin
                                packet_compressed.alu.source = ALU_RS1_RS2;
                                packet_compressed.common.rs2_valid = 1'b1;
                                case (c[6:5])
                                    2'b00: packet_compressed.alu.operation = ALU_SUB;
                                    2'b01: packet_compressed.alu.operation = ALU_XOR;
                                    2'b10: packet_compressed.alu.operation = ALU_OR;
                                    2'b11: packet_compressed.alu.operation = ALU_AND;
                                endcase
                            end
                        endcase
                    end
                    3'b110, 3'b111: begin // C.BEQZ / C.BNEZ
                        packet_compressed.common.rs1_valid = 1'b1;
                        packet_compressed.alu.source = ALU_RS1_RS2;
                        packet_compressed.bru.operation = c[13] ? BR_NE : BR_EQ;
                        compressed_immediate = {{19{c_branch[12]}}, c_branch, 1'b0};
                    end
                endcase
            end
            2'b10: begin
                case (c[15:13])
                    3'b000: begin // C.SLLI
                        packet_compressed.common.rs1_valid = (c_rd != 0);
                        packet_compressed.common.rd_valid = (c_rd != 0);
                        packet_compressed.alu.operation = ALU_SLL;
                        compressed_immediate = {27'd0, c[6:2]};
                    end
                    3'b001, 3'b010, 3'b011, 3'b101, 3'b110, 3'b111: begin
                        lane_type_compressed = MEMORY;
                        packet_compressed.common.rs1_valid = 1'b1;
                        packet_compressed.memory.size = MemorySize_'(c[14:13] == 2'b01 ? 2'b11 : 2'b10);
                        if (c[15]) begin
                            compressed_immediate = c[14:13] == 2'b01 ?
                                {23'd0, c[9:7], c[12:10], 3'd0} :
                                {24'd0, c[8:7], c[12:9], 2'd0};
                            packet_compressed.memory.operation = MEM_STORE;
                            packet_compressed.common.rs2_valid = c[13] || (c[6:2] != 0);
                            packet_compressed.common.rs2_float = c[13];
                        end else begin
                            compressed_immediate = c[14:13] == 2'b01 ?
                                {23'd0, c[4:2], c[12], c[6:5], 3'd0} :
                                {24'd0, c[3:2], c[12], c[6:4], 2'd0};
                            packet_compressed.memory.operation = MEM_LOAD;
                            packet_compressed.memory.sign_extend = !c[13];
                            packet_compressed.common.rd_valid = c[13] || (c_rd != 0);
                            packet_compressed.common.rd_float = c[13];
                        end
                        if (c[13] && (!SUPPORT_FLOAT || !c[14]))
                            packet_compressed.common.trap_type = ILLEGAL;
                    end
                    3'b100: begin
                        if (c[6:2] != 0) begin // C.MV / C.ADD
                            packet_compressed.alu.source = ALU_RS1_RS2;
                            packet_compressed.common.rs1_valid = c[12] && (c_rd != 0);
                            packet_compressed.common.rs2_valid = 1'b1;
                            packet_compressed.common.rd_valid = (c_rd != 0);
                        end else if (c[12] && c_rd == 0) begin
                            packet_compressed.alu.source = ALU_RS1_RS2;
                            packet_compressed.common.trap_type = EBREAK;
                        end else begin // C.JR / C.JALR
                            packet_compressed.common.rs1_valid = (c_rd != 0);
                            packet_compressed.common.rd_valid = c[12];
                            packet_compressed.bru.operation = BR_JALR;
                        end
                    end
                    default: ;
                endcase
            end
            default: ;
        endcase

        if (compressed_illegal) packet_compressed.common.trap_type = ILLEGAL;
        if (packet_compressed.common.trap_type != NONE) begin
            packet_compressed.common.rs1_valid = 1'b0;
            packet_compressed.common.rs2_valid = 1'b0;
            packet_compressed.common.rd_valid = 1'b0;
            packet_compressed.memory.operation = MEM_NONE;
            packet_compressed.atomic.operation = ATOM_NONE;
            packet_compressed.bru.operation = BR_NONE;
            lane_type_compressed = SERIAL;
        end

        if (packet_compressed.common.trap_type != NONE) packet_compressed.common.capability = CAP_TRAP;
        else case (lane_type_compressed)
            INTEGER: if (packet_compressed.bru.operation != BR_NONE) packet_compressed.common.capability = CAP_BRU;
            FLOATING: packet_compressed.common.capability = CAP_FP_F;
            MEMORY: packet_compressed.common.capability = packet_compressed.atomic.operation != ATOM_NONE ? CAP_ATOMIC : CAP_MEMORY;
            SERIAL: packet_compressed.common.capability = packet_compressed.csr.operation != CSR_NONE ? CAP_CSR : CAP_SYSTEM;
            default: ;
        endcase
        case (packet_compressed.common.capability)
            CAP_ALU: packet_compressed.alu.immediate = compressed_immediate;
            CAP_BRU: packet_compressed.bru.immediate = compressed_immediate;
            CAP_MEMORY: packet_compressed.memory.immediate = compressed_immediate;
            CAP_CSR: packet_compressed.csr.immediate = compressed_immediate[4:0];
            default: ;
        endcase
    end

    // Select Completed Packets Instead Of High-Fanout Instruction Fields
    always_comb begin
        packet_full = decode_packet(instruction, 1'b0, lane_type_full);
        packet = is_compressed ? packet_compressed : packet_full;
        lane_type = is_compressed ? lane_type_compressed : lane_type_full;
    end

endmodule
