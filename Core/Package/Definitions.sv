package Definitions;

    // Bitwise operation as a 2-bit code, so each bypass bit is one LUT6:
    // sum[i], control.sum, lhs[i], rhs[i] and this code.
    typedef enum logic [1:0] {
        LOGIC_NONE, LOGIC_XOR, LOGIC_OR, LOGIC_AND
    } AluLogic_;

    // ALU controls decoded at the operand latch. sum, shift_left, set_less,
    // set_less_unsigned, shift_right and a non-NONE logic code are mutually exclusive.
    typedef struct packed {
        logic sum, shift_left, set_less, set_less_unsigned, shift_right;
        AluLogic_ logic_op;
        logic subtract, arithmetic_shift;
    } AluControl_;

    // Branch Predictor Inputs
    typedef struct packed {
        DerivedParameters::fetch_pc_t bp_pc;
        logic [31:0] bp_instruction;
        logic bp_compressed;
        logic bp_branch;
    } BranchInput_;

    // Branch Predictor Outputs
    typedef struct packed {
        DerivedParameters::fetch_pc_t bp_redirect_pc;
        logic bp_target_wrapped;
        logic bp_taken;
        logic bp_valid;
    } BranchOutput_;

    // Architectural controls only; dispatch owns validity and scheduling tags.
    typedef struct packed {
        logic [31:0] pc;
        Enumerations::TrapType_ trap_type;
        logic [4:0] rs1;
        logic [4:0] rs2;
        logic [4:0] rd;
        logic rs1_valid;
        logic rs2_valid;
        logic rd_valid;
        logic rs1_float;
        logic rs2_float;
        logic rd_float;
        logic fp_consumer; // Predecoded FP execution consumer; integer sources require RF.
        Enumerations::DecodeCapability_ capability;
        logic [31:0] next_pc; // pc + 4, or pc + 2 for compressed instructions
        logic [31:0] immediate; // Shared ALU/BRU/memory immediate; CSR zimm in bits [4:0]
    } DecodeCommon_;

    typedef struct packed {
        Enumerations::AluOperation_ operation;
        Enumerations::AluSource_ source;
    } DecodeAlu_;

    typedef struct packed {
        Enumerations::BranchOperation_ operation;
        logic is_branch;
        logic predicted_taken;
        logic [DerivedParameters::PHT_INDEX_W-1:0] pht_index; // GShare index (0 when off)
        logic is_compressed;
    } DecodeBru_;

    typedef struct packed {
        Enumerations::MulOperation_ operation;
    } DecodeMul_;

    typedef struct packed {
        Enumerations::DivOperation_ operation;
    } DecodeDiv_;

    typedef struct packed {
        Enumerations::FloatOperation_ operation;
        logic [2:0] rounding_mode;
        logic [4:0] rs3;
        logic rs3_valid;
        logic rs3_float;
    } DecodeFloat_;

    // FLOATING lane conversion option; uses at most one source register.
    typedef struct packed {
        Enumerations::FloatConvertOperation_ operation;
        logic is_unsigned; // Integer WU rather than W, for numeric integer conversions
        logic [2:0] rounding_mode; // Used by numeric conversions only
    } DecodeFloatConvert_;

    typedef struct packed {
        Enumerations::MemoryOperation_ operation;
        Enumerations::MemorySize_ size;
        logic sign_extend;
    } DecodeMemory_;

    typedef struct packed {
        logic acquire;
        logic release_order;
        Enumerations::AtomicOperation_ operation;
    } DecodeAtomic_;

    typedef struct packed {
        Enumerations::SystemOperation_ operation;
        logic [3:0] fence_predecessor;
        logic [3:0] fence_successor;
    } DecodeSystem_;

    typedef struct packed {
        Enumerations::CSR_R index;
        logic read_enable;
        logic write_enable;
        logic use_immediate;
        Enumerations::CsrOperation_ operation;
    } DecodeCsr_;

    typedef struct packed {
        DecodeCommon_ common;
        DecodeAlu_ alu;
        DecodeBru_ bru;
        DecodeMul_ mul;
        DecodeDiv_ div;
        DecodeFloat_ fp;
        DecodeFloatConvert_ fp_convert;
        DecodeMemory_ memory;
        DecodeAtomic_ atomic;
        DecodeSystem_ system;
        DecodeCsr_ csr;
    } DecoderPacket_;



    // Integer execution payload shared with multiplier and divider.
    typedef struct packed {
        logic [31:0] source_1;
        logic [31:0] source_2;
        logic [31:0] pc;
        logic rd_valid;
        Enumerations::TrapType_ trap_type;
    } IntegerOperands_; // need to change its name

    typedef struct packed {
        logic [DerivedParameters::LANE_WIDTH-1:0] forward_lane_1;
        logic [DerivedParameters::UNROLL_WIDTH-1:0] forward_index_1;
        logic read_reg_file_1;
        logic use_bypass_1; // mutually exclusive with read_reg_file_1
        logic [DerivedParameters::LANE_WIDTH-1:0] forward_lane_2;
        logic [DerivedParameters::UNROLL_WIDTH-1:0] forward_index_2;
        logic read_reg_file_2;
        logic use_bypass_2; // mutually exclusive with read_reg_file_2
        logic [DerivedParameters::AGE_WIDTH-1:0] input_age;
    } IssuerPacket_;


    function automatic logic writes_integer_producer(input DecoderPacket_ packet);
        return packet.common.rd_valid && !packet.common.rd_float && packet.common.rd != 0 &&
            packet.common.capability != Enumerations::CAP_ATOMIC &&
            (packet.common.capability != Enumerations::CAP_MEMORY ||
             packet.memory.operation == Enumerations::MEM_LOAD);
    endfunction

    // Producer slots whose forwarding readiness can be low. Integer slots are
    // statically ready except the final slot of a lane whose MUL or DIV
    // iterates; memory slots 1..EXECUTION_UNROLL wait on the LSU. Only integer
    // and memory lanes forward to integer/memory consumers (serial lanes never
    // forward; FP lanes search their own operands). Issue's watch bits and
    // BackendTop's stall OR are both generated from this function, and it must
    // match IntegerLane's MUL_ITERATES/DIV_ITERATES.
    function automatic logic forward_slot_dynamic(input int lane, input int index);
        int div_latency;
        div_latency = (32 + Parameters::DIVIDER_AUTO_PIPE - 1) / Parameters::DIVIDER_AUTO_PIPE + 2;
        if (lane >= 1 && lane <= Parameters::INTEGER_LANE_COUNT) begin
            return index == Parameters::EXECUTION_UNROLL &&
                ((DerivedParameters::EFFECTIVE_INTEGER_CAPS[lane-1][2] && Parameters::EXECUTION_UNROLL == 1) ||
                 (DerivedParameters::EFFECTIVE_INTEGER_CAPS[lane-1][3] && Parameters::EXECUTION_UNROLL <= div_latency));
        end
        if (lane > Parameters::INTEGER_LANE_COUNT &&
            lane <= Parameters::INTEGER_LANE_COUNT + Parameters::MEMORY_LANE_COUNT) begin
            return DerivedParameters::EFFECTIVE_MEMORY_CAPS[lane-1-Parameters::INTEGER_LANE_COUNT][0] &&
                index >= 1 && index <= Parameters::EXECUTION_UNROLL;
        end
        return 1'b0;
    endfunction

    // Index-zero bypass eligibility for an ALU producer. Only operations whose
    // result is a short AND-OR over the adder and bitwise logic are bypassed;
    // compares and shifts reach consumers through the registered forward at
    // index one. Decode's candidate_bypass_ready and the lane's bypass output
    // (ArithmaticUnit bypass_result) must agree on this set.
    function automatic logic alu_bypassable(input Enumerations::AluOperation_ operation);
        return operation inside {Enumerations::ALU_ADD, Enumerations::ALU_SUB,
            Enumerations::ALU_XOR, Enumerations::ALU_OR, Enumerations::ALU_AND};
    endfunction

    // Eligibility after one advancing edge. Thresholds are shifted back by one
    // so no incrementer or stall-controlled mux precedes the one-bit table read.
    // This is not index-zero bypass eligibility for newly issued producers.
    function automatic logic producer_capture_ready(
        input logic [DerivedParameters::UNROLLED_W-1:0] index,
        input Enumerations::DecodeCapability_ capability,
        input int unsigned execution_unroll,
        input int unsigned divider_auto_pipe
    );
        int unsigned div_ready;
        // Configuration-only arithmetic folds to constants at each call site.
        // Compare before capability selection: never subtract from a threshold
        // selected by capability, which can infer a wide carry chain.
        // Includes the divider's registered raw-result stage ahead of sign correction.
        div_ready = (32 + divider_auto_pipe - 1) / divider_auto_pipe + 3;
        if (index >= execution_unroll + 1) return 1'b1; // RF after capture
        // FP-produced integer results are usable only once captured into RF.
        if (Parameters::SUPPORT_FLOAT &&
            capability inside {Enumerations::CAP_FP_F, Enumerations::CAP_FP_CONVERT})
            return 1'b0;
        case (capability)
            Enumerations::CAP_ALU, Enumerations::CAP_BRU: return 1'b1;
            // The load has a forwarding slot after capture. Operand selection
            // waits for that slot's registered LSU completion when necessary.
            Enumerations::CAP_MEMORY: return 1'b1;
            Enumerations::CAP_MUL: begin
                if (execution_unroll <= 1) return 1'b1;
                return index >= 1;
            end
            Enumerations::CAP_DIV: begin
                if (execution_unroll <= 1) return 1'b1;
                if (execution_unroll < div_ready)
                    return index >= execution_unroll - 1;
                return index >= div_ready - 1;
            end
            Enumerations::CAP_SYSTEM, Enumerations::CAP_CSR:
                return index >= execution_unroll;
            default: begin
                if (execution_unroll <= 1) return 1'b1;
                return index >= execution_unroll - 1;
            end
        endcase
    endfunction

endpackage
