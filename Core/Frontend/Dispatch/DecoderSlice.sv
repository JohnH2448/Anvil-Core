module DecoderSlice
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned SUPPORT_MUL = 1,
    parameter unsigned SUPPORT_DIV = 1,
    parameter unsigned SUPPORT_FLOAT = 1,
    parameter unsigned SUPPORT_ATOMIC = 1
)(

    // Working Input Data
    input logic [31:0] instruction,
    input logic [4:0] rs1_in,
    input logic [4:0] rs2_in,
    input logic [4:0] rd_in,
    input logic [4:0] rs3_in,
    input logic rs1_float_in,
    input logic rs2_float_in,
    input logic rs3_float_in,
    input logic rd_float_in,
    input logic [31:0] pc,
    input logic is_branch,
    input logic is_compressed,
    input logic predicted_taken,

    // Output Packet
    output DecoderPacket_ packet,
    output LaneType_ lane_type

);

    // Legality is independent of payload field selection.
    logic [15:0] c;
    logic [20:1] c_jump;
    logic [12:1] c_branch;
    logic compressed_illegal;
    assign c = instruction[15:0];
    assign c_jump = {{9{c[12]}}, c[12], c[8], c[10:9], c[6], c[7],
        c[2], c[11], c[5:3]};
    assign c_branch = {{4{c[12]}}, c[12], c[6:5], c[2], c[11:10], c[4:3]};
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
        logic [11:0] address;
        logic csr_legal, csr_read_only, writes_csr, rounding;
        opcode = insn[6:0];
        funct3 = insn[14:12];
        funct7 = insn[31:25];
        rs2 = insn[24:20];
        address = insn[31:20];
        csr_legal = 1'b1;
        csr_read_only = 1'b0;
        writes_csr = funct3[1:0] == 1 || insn[19:15] != 0;
        rounding = 1'b0;
        case (address)
            MSTATUS, MTVEC, MIP, MIE, MCYCLE, MCYCLEH, MINSTRET,
            MINSTRETH, MSCRATCH, MEPC, MCAUSE, MISA: ;
            12'h001, 12'h002, 12'h003: csr_legal = SUPPORT_FLOAT != 0;
            MVENDORID, MARCHID, MIMPID, MHARTID, MCONFIGPTR,
            MEDELEG, MIDELEG, MCOUNTEREN, MSTATUSH, MTVAL: csr_read_only = 1'b1;
            default: begin
                csr_read_only = 1'b1;
                csr_legal = (address >= 12'hB03 && address <= 12'hB1F) ||
                    (address >= 12'hB83 && address <= 12'hB9F) ||
                    (address >= 12'h323 && address <= 12'h33F);
            end
        endcase
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
            7'b1110011: begin
                if (funct3 == 0) begin
                    case (insn)
                        32'h00000073: full_trap = ECALL;
                        32'h00100073: full_trap = EBREAK;
                        32'h30200073,32'h10500073: ;
                        default: full_trap = ILLEGAL;
                    endcase
                end else begin
                    if (funct3 == 4 || !csr_legal || (csr_read_only && writes_csr)) full_trap = ILLEGAL;
                end
            end
            default: full_trap = ILLEGAL;
        endcase
    endfunction

    // Immediate payload depends only on encoding format. Legality/capability
    // are evaluated independently; trapped/unused payload is not consumed.
    logic [31:0] immediate_direct;
    always_comb begin
        immediate_direct = 'x;
        if (is_compressed) begin
            case (c[1:0])
                2'b00: begin
                    case (c[15:13])
                        3'b000: immediate_direct = {22'd0, c[10:7], c[12:11], c[5], c[6], 2'd0};
                        3'b010, 3'b110: immediate_direct = {25'd0, c[5], c[12:10], c[6], 2'd0};
                        3'b011, 3'b111: if (SUPPORT_FLOAT)
                            immediate_direct = {25'd0, c[5], c[12:10], c[6], 2'd0};
                        default: ;
                    endcase
                end
                2'b01: begin
                    case (c[15:13])
                        3'b000, 3'b010: immediate_direct = {{26{c[12]}}, c[12], c[6:2]};
                        3'b001, 3'b101: immediate_direct = {{11{c_jump[20]}}, c_jump, 1'b0};
                        3'b011: begin
                            if (c[11:7] == 5'd2)
                                immediate_direct = {{22{c[12]}}, c[12], c[4:3], c[5], c[2], c[6], 4'd0};
                            else immediate_direct = {{14{c[12]}}, c[12], c[6:2], 12'd0};
                        end
                        3'b100: begin
                            case (c[11:10])
                                2'b00, 2'b01: immediate_direct = {21'd0, c[10], 5'd0, c[6:2]};
                                2'b10: immediate_direct = {{26{c[12]}}, c[12], c[6:2]};
                                default: ;
                            endcase
                        end
                        3'b110, 3'b111: immediate_direct = {{19{c_branch[12]}}, c_branch, 1'b0};
                    endcase
                end
                2'b10: begin
                    case (c[15:13])
                        3'b000: immediate_direct = {27'd0, c[6:2]};
                        3'b010: immediate_direct = {24'd0, c[3:2], c[12], c[6:4], 2'd0};
                        3'b011: if (SUPPORT_FLOAT)
                            immediate_direct = {24'd0, c[3:2], c[12], c[6:4], 2'd0};
                        3'b100: if (c[6:2] == 0) immediate_direct = '0; // JR/JALR offset
                        3'b110: immediate_direct = {24'd0, c[8:7], c[12:9], 2'd0};
                        3'b111: if (SUPPORT_FLOAT)
                            immediate_direct = {24'd0, c[8:7], c[12:9], 2'd0};
                        default: ;
                    endcase
                end
                default: ;
            endcase
        end else begin
            case (instruction[6:0])
                7'b0010011, 7'b0000011, 7'b1100111:
                    immediate_direct = {{20{instruction[31]}}, instruction[31:20]};
                7'b0000111: if (SUPPORT_FLOAT)
                    immediate_direct = {{20{instruction[31]}}, instruction[31:20]};
                7'b0100011:
                    immediate_direct = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
                7'b0100111: if (SUPPORT_FLOAT)
                    immediate_direct = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
                7'b1100011:
                    immediate_direct = {{19{instruction[31]}}, instruction[31], instruction[7],
                        instruction[30:25], instruction[11:8], 1'b0};
                7'b0110111, 7'b0010111: immediate_direct = {instruction[31:12], 12'b0};
                7'b1101111:
                    immediate_direct = {{11{instruction[31]}}, instruction[31], instruction[19:12],
                        instruction[20], instruction[30:21], 1'b0};
                7'b1110011: if (instruction[14])
                    immediate_direct[4:0] = instruction[19:15]; // CSR zimm
                default: ;
            endcase
        end
    end

    logic [6:0] op;
    logic [2:0] f3;
    logic [6:0] f7;
    logic [4:0] f5;
    TrapType_ trap;
    logic ok;
    assign op = instruction[6:0];
    assign f3 = instruction[14:12];
    assign f7 = instruction[31:25];
    assign f5 = instruction[31:27];
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
    assign ok = trap == NONE;

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
    assign packet.common.pc = pc;
    assign packet.common.trap_type = trap;
    assign packet.common.immediate = immediate_direct;
    // Reserved packet field; execution derives fall-through locally.
    assign packet.common.next_pc = 'x;
    assign packet.common.rs1 = rs1_in;
    assign packet.common.rs1_float = rs1_float_in;
    assign packet.common.rs2 = rs2_in;
    assign packet.common.rs2_float = rs2_float_in;
    assign packet.common.rd = rd_in;
    assign packet.common.rd_float = rd_float_in;
    assign packet.fp.rs3 = rs3_in;
    assign packet.fp.rs3_float = rs3_float_in;
    assign packet.fp.rs3_valid = ok && fused;
    // Source presence is independent of operation payload selection. The bank
    // flags preserve f0 as an ordinary operand while suppressing integer x0.
    assign packet.common.rs1_valid = ok && (rs1_float_in || rs1_in != 0) &&
        (r_alu || i_alu || mul_op || div_op || branch_op || jalr ||
         load_op || store_op || atomic_op || fused || float_op ||
         (csr_op && !f3[2]) || c_addi4 || c_load || c_store || c_math ||
         c_branch || c_shift ||
         (c_ci && (c[15:13] == 0 || (c[15:13] == 3 && c[11:7] == 2))) ||
         (c_cr && (c[6:2] == 0 || c[12])));
    assign packet.common.rs2_valid = ok && (rs2_float_in || rs2_in != 0) &&
        (r_alu || mul_op || div_op || branch_op || store_op ||
         (atomic_op && f5 != 2) || fused ||
         (float_op && (f5 inside {5'd0,5'd1,5'd2,5'd3,5'd4,5'd5,5'd20})) ||
         c_store || (c_math && c[11:10] == 3) || (c_cr && c[6:2] != 0));
    assign packet.common.rd_valid = ok && (rd_float_in || rd_in != 0) &&
        (r_alu || i_alu || upper || mul_op || div_op || jal || jalr ||
         load_op || atomic_op || fused || float_op || csr_op || c_addi4 ||
         c_ci || c_math || c_shift || c_load || (c_jump && !c[15]) ||
         (c_cr && (c[6:2] != 0 || c[12])));

    // common.capability
    always_comb begin
        packet.common.capability = CAP_ALU;
        if (ok) begin
            case (1'b1)
                mul_op: packet.common.capability = CAP_MUL;
                div_op: packet.common.capability = CAP_DIV;
                branch_op || jal || jalr || c_branch || c_jump || (c_cr && c[6:2] == 0): packet.common.capability = CAP_BRU;
                load_op || store_op || c_load || c_store: packet.common.capability = CAP_MEMORY;
                atomic_op: packet.common.capability = CAP_ATOMIC;
                convert_op: packet.common.capability = CAP_FP_CONVERT;
                fused || float_op: packet.common.capability = CAP_FP_F;
                csr_op: packet.common.capability = CAP_CSR;
                system_op: packet.common.capability = CAP_SYSTEM;
                default: ;
            endcase
        end
    end
    always_comb begin
        lane_type = INTEGER;
        if (ok) begin
            case (1'b1)
                load_op || store_op || atomic_op || c_load || c_store: lane_type = MEMORY;
                fused || float_op: lane_type = FLOATING;
                csr_op || system_op: lane_type = SERIAL;
                default: ;
            endcase
        end
    end

    // alu.operation
    always_comb begin
        packet.alu.operation = AluOperation_'('x);
        case (1'b1)
            (r_alu || i_alu) && f3 == 3'd0: packet.alu.operation = (r_alu && instruction[30]) ? ALU_SUB : ALU_ADD;
            (r_alu || i_alu) && f3 == 3'd1: packet.alu.operation = ALU_SLL;
            (r_alu || i_alu) && f3 == 3'd2: packet.alu.operation = ALU_SLT;
            (r_alu || i_alu) && f3 == 3'd3: packet.alu.operation = ALU_SLTU;
            (r_alu || i_alu) && f3 == 3'd4: packet.alu.operation = ALU_XOR;
            (r_alu || i_alu) && f3 == 3'd5: packet.alu.operation = instruction[30] ? ALU_SRA : ALU_SRL;
            (r_alu || i_alu) && f3 == 3'd6: packet.alu.operation = ALU_OR;
            (r_alu || i_alu) && f3 == 3'd7: packet.alu.operation = ALU_AND;
            upper || jal || jalr || load_op || store_op || c_addi4 || c_ci || c_load || c_store || c_jump || c_cr: packet.alu.operation = ALU_ADD;
            c_shift: packet.alu.operation = ALU_SLL;
            c_math && c[11:10] == 0: packet.alu.operation = ALU_SRL;
            c_math && c[11:10] == 1: packet.alu.operation = ALU_SRA;
            c_math && c[11:10] == 2: packet.alu.operation = ALU_AND;
            c_math && c[11:10] == 3 && c[6:5] == 2'd0: packet.alu.operation = ALU_SUB;
            c_math && c[11:10] == 3 && c[6:5] == 2'd1: packet.alu.operation = ALU_XOR;
            c_math && c[11:10] == 3 && c[6:5] == 2'd2: packet.alu.operation = ALU_OR;
            c_math && c[11:10] == 3 && c[6:5] == 2'd3: packet.alu.operation = ALU_AND;
            default: ;
        endcase
    end

    // alu.source
    always_comb begin
        packet.alu.source = AluSource_'('x);
        case (1'b1)
            r_alu || (c_math && c[11:10] == 3) || (c_cr && c[6:2] != 0): packet.alu.source = ALU_RS1_RS2;
            (upper && op[5]) || (c_ci && c[15:13] == 3 && c[11:7] != 2): packet.alu.source = ALU_ZERO_IMM;
            upper || jal || c_jump: packet.alu.source = ALU_PC_IMM;
            i_alu || jalr || load_op || store_op || c_addi4 || c_ci || c_math || c_shift || c_load || c_store || c_cr: packet.alu.source = ALU_RS1_IMM;
            default: ;
        endcase
    end

    // bru.operation
    always_comb begin
        packet.bru.operation = BR_NONE;
        if (ok) begin
            case (1'b1)
                jal || c_jump: packet.bru.operation = BR_JAL;
                jalr || (c_cr && c[6:2] == 0): packet.bru.operation = BR_JALR;
                c_branch: packet.bru.operation = c[13] ? BR_NE : BR_EQ;
                branch_op && f3 == 3'd0: packet.bru.operation = BR_EQ;
                branch_op && f3 == 3'd1: packet.bru.operation = BR_NE;
                branch_op && f3 == 3'd4: packet.bru.operation = BR_LT;
                branch_op && f3 == 3'd5: packet.bru.operation = BR_GE;
                branch_op && f3 == 3'd6: packet.bru.operation = BR_LTU;
                branch_op && f3 == 3'd7: packet.bru.operation = BR_GEU;
                default: ;
            endcase
        end
    end
    assign packet.bru.is_branch = is_branch;
    assign packet.bru.is_compressed = is_compressed;
    assign packet.bru.predicted_taken = predicted_taken;

    // mul.operation
    always_comb begin
        packet.mul.operation = MulOperation_'('x);
        case (1'b1)
            mul_op: packet.mul.operation = MulOperation_'(f3[1:0]);
            default: ;
        endcase
    end

    // div.operation
    always_comb begin
        packet.div.operation = DivOperation_'('x);
        case (1'b1)
            div_op: packet.div.operation = DivOperation_'(f3[1:0]);
            default: ;
        endcase
    end

    // memory.operation
    always_comb begin
        packet.memory.operation = MEM_NONE;
        if (ok) begin
            case (1'b1)
                load_op || c_load: packet.memory.operation = MEM_LOAD;
                store_op || c_store: packet.memory.operation = MEM_STORE;
                default: ;
            endcase
        end
    end

    // memory.size
    always_comb begin
        packet.memory.size = MemorySize_'('x);
        case (1'b1)
            atomic_op || c_load || c_store: packet.memory.size = MEM_WORD;
            load_op || store_op: packet.memory.size = MemorySize_'(f3[1:0]);
            default: ;
        endcase
    end

    // memory.sign_extend
    always_comb begin
        packet.memory.sign_extend = 1'bx;
        case (1'b1)
            load_op: packet.memory.sign_extend = !f3[2] && !op[2];
            c_load: packet.memory.sign_extend = !c[13];
            default: ;
        endcase
    end

    // atomic.operation
    always_comb begin
        packet.atomic.operation = ATOM_NONE;
        if (ok) begin
            case (1'b1)
                atomic_op && f5 == 5'd2: packet.atomic.operation = ATOM_LR;
                atomic_op && f5 == 5'd3: packet.atomic.operation = ATOM_SC;
                atomic_op && f5 == 5'd1: packet.atomic.operation = ATOM_SWAP;
                atomic_op && f5 == 5'd0: packet.atomic.operation = ATOM_ADD;
                atomic_op && f5 == 5'd4: packet.atomic.operation = ATOM_XOR;
                atomic_op && f5 == 5'd12: packet.atomic.operation = ATOM_AND;
                atomic_op && f5 == 5'd8: packet.atomic.operation = ATOM_OR;
                atomic_op && f5 == 5'd16: packet.atomic.operation = ATOM_MIN;
                atomic_op && f5 == 5'd20: packet.atomic.operation = ATOM_MAX;
                atomic_op && f5 == 5'd24: packet.atomic.operation = ATOM_MINU;
                atomic_op && f5 == 5'd28: packet.atomic.operation = ATOM_MAXU;
                default: ;
            endcase
        end
    end

    // atomic.acquire
    always_comb begin
        packet.atomic.acquire = 1'bx;
        case (1'b1)
            atomic_op: packet.atomic.acquire = instruction[26];
            default: ;
        endcase
    end

    // atomic.release_order
    always_comb begin
        packet.atomic.release_order = 1'bx;
        case (1'b1)
            atomic_op: packet.atomic.release_order = instruction[25];
            default: ;
        endcase
    end

    // fp.operation
    always_comb begin
        packet.fp.operation = FloatOperation_'('x);
        case (1'b1)
            fused && op[3:2] == 2'd0: packet.fp.operation = FP_MADD;
            fused && op[3:2] == 2'd1: packet.fp.operation = FP_MSUB;
            fused && op[3:2] == 2'd2: packet.fp.operation = FP_NMSUB;
            fused && op[3:2] == 2'd3: packet.fp.operation = FP_NMADD;
            float_op && f5 == 5'd0: packet.fp.operation = FP_ADD;
            float_op && f5 == 5'd1: packet.fp.operation = FP_SUB;
            float_op && f5 == 5'd2: packet.fp.operation = FP_MUL;
            float_op && f5 == 5'd3: packet.fp.operation = FP_DIV;
            float_op && f5 == 5'd11: packet.fp.operation = FP_SQRT;
            float_op && f5 == 5'd4 && f3 == 3'd0: packet.fp.operation = FP_SGNJ;
            float_op && f5 == 5'd4 && f3 == 3'd1: packet.fp.operation = FP_SGNJN;
            float_op && f5 == 5'd4 && f3 == 3'd2: packet.fp.operation = FP_SGNJX;
            float_op && f5 == 5'd5 && f3 == 3'd0: packet.fp.operation = FP_MIN;
            float_op && f5 == 5'd5 && f3 == 3'd1: packet.fp.operation = FP_MAX;
            float_op && f5 == 5'd20 && f3 == 3'd0: packet.fp.operation = FP_LE;
            float_op && f5 == 5'd20 && f3 == 3'd1: packet.fp.operation = FP_LT;
            float_op && f5 == 5'd20 && f3 == 3'd2: packet.fp.operation = FP_EQ;
            default: ;
        endcase
    end

    // fp.rounding_mode
    always_comb begin
        packet.fp.rounding_mode = 3'bxxx;
        case (1'b1)
            fused || (float_op && (f5 inside {5'd0,5'd1,5'd2,5'd3,5'd11})): packet.fp.rounding_mode = f3;
            default: ;
        endcase
    end

    // fp_convert.operation
    always_comb begin
        packet.fp_convert.operation = FloatConvertOperation_'('x);
        case (1'b1)
            float_op && f5 == 24: packet.fp_convert.operation = FPC_TO_INT;
            float_op && f5 == 26: packet.fp_convert.operation = FPC_FROM_INT;
            float_op && f5 == 30: packet.fp_convert.operation = FPC_FROM_BITS;
            float_op && f5 == 28 && f3 == 0: packet.fp_convert.operation = FPC_TO_BITS;
            float_op && f5 == 28 && f3 == 1: packet.fp_convert.operation = FPC_CLASS;
            default: ;
        endcase
    end

    // fp_convert.is_unsigned
    always_comb begin
        packet.fp_convert.is_unsigned = 1'bx;
        case (1'b1)
            float_op && (f5 == 24 || f5 == 26): packet.fp_convert.is_unsigned = instruction[20];
            default: ;
        endcase
    end

    // fp_convert.rounding_mode
    always_comb begin
        packet.fp_convert.rounding_mode = 3'bxxx;
        case (1'b1)
            float_op && (f5 == 24 || f5 == 26): packet.fp_convert.rounding_mode = f3;
            default: ;
        endcase
    end

    // system.operation
    always_comb begin
        packet.system.operation = SYS_NONE;
        if (ok) begin
            case (1'b1)
                !is_compressed && op == 7'b0001111 && f3 == 0: packet.system.operation = SYS_FENCE;
                !is_compressed && op == 7'b0001111 && f3 == 1: packet.system.operation = SYS_FENCE_I;
                !is_compressed && instruction == 32'h30200073: packet.system.operation = SYS_MRET;
                !is_compressed && instruction == 32'h10500073: packet.system.operation = SYS_WFI;
                default: ;
            endcase
        end
    end

    // system.fence_predecessor
    always_comb begin
        packet.system.fence_predecessor = 4'bxxxx;
        case (1'b1)
            !is_compressed && op == 7'b0001111 && f3 == 0: packet.system.fence_predecessor = instruction[27:24];
            default: ;
        endcase
    end

    // system.fence_successor
    always_comb begin
        packet.system.fence_successor = 4'bxxxx;
        case (1'b1)
            !is_compressed && op == 7'b0001111 && f3 == 0: packet.system.fence_successor = instruction[23:20];
            default: ;
        endcase
    end

    // csr.operation
    always_comb begin
        packet.csr.operation = CSR_NONE;
        if (ok) begin
            case (1'b1)
                csr_op && f3[1:0] == 1: packet.csr.operation = CSR_RW;
                csr_op && f3[1:0] == 2: packet.csr.operation = CSR_RS;
                csr_op && f3[1:0] == 3: packet.csr.operation = CSR_RC;
                default: ;
            endcase
        end
    end
    assign packet.csr.read_enable = ok && csr_op && (f3[1:0] != 1 || instruction[11:7] != 0);
    assign packet.csr.write_enable = ok && csr_op && (f3[1:0] == 1 || instruction[19:15] != 0);

    // csr.use_immediate
    always_comb begin
        packet.csr.use_immediate = 1'bx;
        case (1'b1)
            csr_op: packet.csr.use_immediate = f3[2];
            default: ;
        endcase
    end

    always_comb begin
        packet.csr.index = CSR_R'('x);
        if (csr_op) begin
            packet.csr.index = ROZ_R;
            case (instruction[31:20])
                MSTATUS: packet.csr.index = MSTATUS_R;
                MTVEC: packet.csr.index = MTVEC_R;
                MIP: packet.csr.index = MIP_R;
                MIE: packet.csr.index = MIE_R;
                MCYCLE: packet.csr.index = MCYCLE_R;
                MCYCLEH: packet.csr.index = MCYCLEH_R;
                MINSTRET: packet.csr.index = MINSTRET_R;
                MINSTRETH: packet.csr.index = MINSTRETH_R;
                MSCRATCH: packet.csr.index = MSCRATCH_R;
                MEPC: packet.csr.index = MEPC_R;
                MCAUSE: packet.csr.index = MCAUSE_R;
                MISA: packet.csr.index = MISA_R;
                12'd1: if (SUPPORT_FLOAT) packet.csr.index = FFLAGS_R;
                12'd2: if (SUPPORT_FLOAT) packet.csr.index = FRM_R;
                12'd3: if (SUPPORT_FLOAT) packet.csr.index = FCSR_R;
                default: ;
            endcase
        end
    end
endmodule
