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
        logic [DerivedParameters::LANE_WIDTH-1:0] bypass_lane_1;
        logic [DerivedParameters::LANE_WIDTH-1:0] forward_lane_2;
        logic [DerivedParameters::UNROLL_WIDTH-1:0] forward_index_2;
        logic read_reg_file_2;
        logic use_bypass_2; // mutually exclusive with read_reg_file_2
        logic [DerivedParameters::LANE_WIDTH-1:0] bypass_lane_2;
        logic [DerivedParameters::AGE_WIDTH-1:0] input_age;
    } IssuerPacket_;


endpackage
