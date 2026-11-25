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
    input DecodeCapability_ capability_in,
    input logic [6:0] immediate_upper_select_in,
    input logic fp_consumer_in,
    input TrapType_ trap_in,
    input logic rs1_used_in,
    input logic rs2_used_in,
    input logic rd_written_in,
    input DerivedParameters::fetch_pc_t pc,
    input logic is_branch,
    input logic is_compressed,
    input logic predicted_taken,

    // Output Packet
    output DecoderPacket_ packet,
    output LaneType_ lane_type

);

    // Queue supplies registered legality; payload formatting remains local.
    logic [15:0] c;
    logic [20:1] c_jump_offset;
    logic [12:1] c_branch_offset;
    assign c = instruction[15:0];
    assign c_jump_offset = {{9{c[12]}}, c[12], c[8], c[10:9], c[6], c[7],
        c[2], c[11], c[5:3]};
    assign c_branch_offset = {{4{c[12]}}, c[12], c[6:5], c[2], c[11:10], c[4:3]};
    // Immediate payload depends only on encoding format. Legality/capability
    // are evaluated independently; trapped/unused payload is not consumed.
    // Direct layout enables avoid decoding a format number after serve selection.
    logic [13:0] upper_select;
    logic [31:0] upper_layout [14];
    assign upper_layout[0] = {22'd0, c[10:7], c[12:11], c[5], c[6], 2'd0};
    assign upper_layout[1] = {25'd0, c[5], c[12:10], c[6], 2'd0};
    assign upper_layout[2] = {{26{c[12]}}, c[12], c[6:2]};
    assign upper_layout[3] = {{11{c_jump_offset[20]}}, c_jump_offset, 1'b0};
    assign upper_layout[4] = {{22{c[12]}}, c[12], c[4:3], c[5], c[2], c[6], 4'd0};
    assign upper_layout[5] = {{14{c[12]}}, c[12], c[6:2], 12'd0};
    assign upper_layout[6] = {21'd0, c[10], 5'd0, c[6:2]};
    assign upper_layout[7] = {{19{c_branch_offset[12]}}, c_branch_offset, 1'b0};
    assign upper_layout[8] = {24'd0, c[3:2], c[12], c[6:4], 2'd0};
    assign upper_layout[9] = {24'd0, c[8:7], c[12:9], 2'd0};
    assign upper_layout[10] = {{20{instruction[31]}}, instruction[31:20]};
    assign upper_layout[11] = {{19{instruction[31]}}, instruction[31], instruction[7], instruction[30:25], instruction[11:8], 1'b0};
    assign upper_layout[12] = {instruction[31:12], 12'b0};
    assign upper_layout[13] = {{11{instruction[31]}}, instruction[31], instruction[19:12], instruction[20], instruction[30:21], 1'b0};
    logic [31:0] immediate_direct;
    always_comb begin
        immediate_direct = '0;
        for (int layout = 0; layout < 14; layout++)
            immediate_direct[31:5] |= {27{upper_select[layout]}} & upper_layout[layout][31:5];
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
    // CSR legality (whitelist, read-only writes) is predecoded in Fetch
    // (SystemTrapPredecode) and arrives in trap_in.
    // FS is hardwired Off: every FP instruction and FP load/store traps.
    wire fp_state_access = SUPPORT_FLOAT && (capability_in inside {CAP_FP_F, CAP_FP_CONVERT} ||
        (capability_in == CAP_MEMORY && (rd_float_in || rs2_float_in)));
    assign trap = trap_in == NONE && fp_state_access ? ILLEGAL : trap_in;
    assign ok = trap == NONE;

    // Detailed encoding predicates remain local. Exact class predicates reuse
    // Fetch capability; SUPPORT_* constants still prune disabled payload logic.
    wire r_alu = !is_compressed && op == 7'b0110011 && f7 != 7'b0000001;
    wire i_alu = !is_compressed && op == 7'b0010011;
    wire upper = !is_compressed && (op inside {7'b0110111, 7'b0010111});
    wire mul_op = SUPPORT_MUL && capability_in == CAP_MUL;
    wire div_op = SUPPORT_DIV && capability_in == CAP_DIV;
    wire branch_op = !is_compressed && op == 7'b1100011;
    wire jal = !is_compressed && op == 7'b1101111;
    wire jalr = !is_compressed && op == 7'b1100111;
    wire load_op = !is_compressed && (op == 7'b0000011 || (SUPPORT_FLOAT && op == 7'b0000111));
    wire store_op = !is_compressed && (op == 7'b0100011 || (SUPPORT_FLOAT && op == 7'b0100111));
    wire atomic_op = SUPPORT_ATOMIC && capability_in == CAP_ATOMIC;
    wire fused = !is_compressed && SUPPORT_FLOAT && (op inside {7'b1000011,7'b1000111,7'b1001011,7'b1001111});
    wire float_op = !is_compressed && SUPPORT_FLOAT && op == 7'b1010011;
    wire csr_op = capability_in == CAP_CSR;
    wire c_addi4 = is_compressed && c[1:0] == 0 && c[15:13] == 0;
    wire c_ci = is_compressed && c[1:0] == 1 && (c[15:13] inside {3'b000,3'b010,3'b011});
    wire c_math = is_compressed && c[1:0] == 1 && c[15:13] == 4;
    wire c_branch = is_compressed && c[1:0] == 1 && (c[15:13] inside {3'b110,3'b111});
    wire c_jump = is_compressed && c[1:0] == 1 && (c[15:13] inside {3'b001,3'b101});
    wire c_shift = is_compressed && c[1:0] == 2 && c[15:13] == 0;
    wire c_cr = is_compressed && c[1:0] == 2 && c[15:13] == 4;
    wire c_load = is_compressed && (c[1:0] == 0 || c[1:0] == 2) && (c[15:13] == 2 || (SUPPORT_FLOAT && c[15:13] == 3));
    wire c_store = is_compressed && (c[1:0] == 0 || c[1:0] == 2) && (c[15:13] == 6 || (SUPPORT_FLOAT && c[15:13] == 7));
    assign upper_select[6:0] = immediate_upper_select_in;
    assign upper_select[7] = c_branch;
    assign upper_select[8] = c_load && c[1:0] == 2;
    assign upper_select[9] = c_store && c[1:0] == 2;
    assign upper_select[10] = i_alu || jalr || load_op || store_op;
    assign upper_select[11] = branch_op;
    assign upper_select[12] = upper;
    assign upper_select[13] = jal;

    assign packet.common.pc = 32'(pc); // Upper bits are constant through Decode, Issue and lane capture.
    assign packet.common.trap_type = trap;
    ImmediateLowPredecode #(.SUPPORT_FLOAT(SUPPORT_FLOAT)) low_decode (
        .instruction(instruction),
        .is_compressed(is_compressed),
        .immediate_low(packet.common.immediate[4:0])
    );
    assign packet.common.immediate[31:5] = immediate_direct[31:5];
    // Reserved packet field; execution derives fall-through locally.
    assign packet.common.next_pc = 'x;
    assign packet.common.rs1 = rs1_in;
    assign packet.common.fp_consumer = SUPPORT_FLOAT && fp_consumer_in;
    assign packet.common.rs1_float = rs1_float_in;
    assign packet.common.rs2 = rs2_in;
    assign packet.common.rs2_float = rs2_float_in;
    assign packet.common.rd = rd_in;
    assign packet.common.rd_float = rd_float_in;
    assign packet.fp.rs3 = rs3_in;
    assign packet.fp.rs3_float = rs3_float_in;
    assign packet.fp.rs3_valid = ok && fused;
    // Fetch already classified operand use, bank and integer-zero suppression.
    // Legality still gates real dependencies and destination write authorization.
    assign packet.common.rs1_valid = ok && rs1_used_in;
    assign packet.common.rs2_valid = ok && rs2_used_in;
    assign packet.common.rd_valid = ok && rd_written_in;

    // Encoding-only capability is carried from Fetch with the instruction.
    // Every frontend-trapped instruction is rerouted to the serial lane, so
    // memory lanes never carry a trap that exists before the bus. Trapped
    // packets have no operands, destination or side effects, so the serial
    // lane only has to raise the trap at writeback.
    assign packet.common.capability = trap != NONE ?
        CAP_SYSTEM : capability_in;
    always_comb begin
        lane_type = INTEGER;
        case (packet.common.capability)
            CAP_MEMORY, CAP_ATOMIC: lane_type = MEMORY;
            CAP_FP_F, CAP_FP_CONVERT: lane_type = FLOATING;
            CAP_SYSTEM, CAP_CSR: lane_type = SERIAL;
            default: ;
        endcase
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

    BranchOperation_ branch_operation;
    BranchOperationPredecode operation_decode (
        .instruction(instruction),
        .is_compressed(is_compressed),
        .operation(branch_operation)
    );
    assign packet.bru.operation = ok ? branch_operation : BR_NONE;
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
                // Zicntr read-only aliases (writes are ILLEGAL above).
                // time/timeh mirror the CLINT's mtime.
                12'hC00: packet.csr.index = MCYCLE_R; // cycle
                12'hC80: packet.csr.index = MCYCLEH_R; // cycleh
                12'hC01: packet.csr.index = TIME_R; // time
                12'hC81: packet.csr.index = TIMEH_R; // timeh
                12'hC02: packet.csr.index = MINSTRET_R; // instret
                12'hC82: packet.csr.index = MINSTRETH_R; // instreth
                MSCRATCH: packet.csr.index = MSCRATCH_R;
                MEPC: packet.csr.index = MEPC_R;
                MCAUSE: packet.csr.index = MCAUSE_R;
                MISA: packet.csr.index = MISA_R;
                default: ;
            endcase
        end
    end
endmodule
