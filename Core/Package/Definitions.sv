import Enumerations::*;

package Definitions;

    // Branch Predictor Inputs
    typedef struct packed {
        logic [31:0] bp_pc;
        logic [31:0] bp_instruction;
        logic bp_compressed;
        logic bp_branch;
    } BranchInput_;

    // Branch Predictor Outputs
    typedef struct packed {
        logic [31:0] bp_redirect_pc;
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
        Enumerations::DecodeCapability_ capability;
        // need to do pc + 4 somewhere before bru
    } DecodeCommon_;

    typedef struct packed {
        Enumerations::AluOperation_ operation;
        Enumerations::AluSource_ source;
        logic [31:0] immediate;
    } DecodeAlu_;

    typedef struct packed {
        Enumerations::BranchOperation_ operation;
        logic is_branch;
        logic predicted_taken;
        logic is_compressed;
        logic [31:0] immediate;
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
        logic [31:0] immediate;
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
        logic [4:0] immediate;
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
    } DecodedPacket_;

    // Per-lane execution support, distinct from DecoderSlice's core ISA gates.
    // Memory lanes always support ordinary loads/stores; atomics are optional.
    typedef struct packed {
        Enumerations::LaneType_ lane_type;
        logic alu;
        logic bru;
        logic mul;
        logic div;
        logic fp_f;
        logic fp_convert; // All core-enabled conversions; independent of F/D arithmetic
        logic atomic;
        logic system;
        logic csr;
    } LaneCapabilities_;

    // Integer Step 2 Payload
    typedef struct packed {
        logic [31:0] source_1;
        logic [31:0] source_2;
        logic [31:0] pc;
        logic rd_valid;
        Enumerations::TrapType_ trap_type;
    } IntegerOperands_;

    function automatic logic lane_supports(
        /* verilator lint_off UNUSEDSIGNAL */
        input DecodeCommon_ decoded,
        /* verilator lint_on UNUSEDSIGNAL */
        input Enumerations::LaneType_ decoded_lane_type,
        input LaneCapabilities_ supported
    );
        lane_supports = 1'b0;
        if (decoded_lane_type == supported.lane_type) begin
            case (decoded.capability)
                Enumerations::CAP_ALU: lane_supports = supported.lane_type == Enumerations::INTEGER && supported.alu;
                Enumerations::CAP_BRU: lane_supports = supported.lane_type == Enumerations::INTEGER && supported.bru;
                Enumerations::CAP_MUL: lane_supports = supported.lane_type == Enumerations::INTEGER && supported.mul;
                Enumerations::CAP_DIV: lane_supports = supported.lane_type == Enumerations::INTEGER && supported.div;
                Enumerations::CAP_FP_F: lane_supports = supported.lane_type == Enumerations::FLOATING && supported.fp_f;
                Enumerations::CAP_FP_CONVERT: lane_supports = supported.lane_type == Enumerations::FLOATING && supported.fp_convert;
                Enumerations::CAP_MEMORY: lane_supports = supported.lane_type == Enumerations::MEMORY;
                Enumerations::CAP_ATOMIC: lane_supports = supported.lane_type == Enumerations::MEMORY && supported.atomic;
                Enumerations::CAP_SYSTEM: lane_supports = supported.lane_type == Enumerations::SERIAL && supported.system;
                Enumerations::CAP_CSR: lane_supports = supported.lane_type == Enumerations::SERIAL && supported.csr;
                Enumerations::CAP_TRAP: lane_supports = supported.lane_type == Enumerations::SERIAL;
                default: ;
            endcase
        end
    endfunction

endpackage
