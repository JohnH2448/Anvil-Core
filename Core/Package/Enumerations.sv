package Enumerations;
    
    // MSTATUS, MTVEC, MIP, MIE, MCYCLE/MCYCLEH, MINSTRET/MINSTRETH, MSCRATCH, MEPC, MCAUSE
    // All others are read-only zero
    typedef enum logic [11:0] {
        MVENDORID      = 12'hF11,
        MARCHID        = 12'hF12,
        MIMPID         = 12'hF13,
        MHARTID        = 12'hF14,
        MCONFIGPTR     = 12'hF15,
        MSTATUS        = 12'h300,
        MISA           = 12'h301,
        MEDELEG        = 12'h302,
        MIDELEG        = 12'h303,
        MIE            = 12'h304,
        MTVEC          = 12'h305,
        MCOUNTEREN     = 12'h306,
        MSTATUSH       = 12'h310,
        MSCRATCH       = 12'h340,
        MEPC           = 12'h341,
        MCAUSE         = 12'h342,
        MTVAL          = 12'h343,
        MIP            = 12'h344,
        MCYCLE         = 12'hB00,
        MINSTRET       = 12'hB02,
        MHPMCOUNTER3   = 12'hB03,
        MHPMCOUNTER4   = 12'hB04,
        MHPMCOUNTER5   = 12'hB05,
        MHPMCOUNTER6   = 12'hB06,
        MHPMCOUNTER7   = 12'hB07,
        MHPMCOUNTER8   = 12'hB08,
        MHPMCOUNTER9   = 12'hB09,
        MHPMCOUNTER10  = 12'hB0A,
        MHPMCOUNTER11  = 12'hB0B,
        MHPMCOUNTER12  = 12'hB0C,
        MHPMCOUNTER13  = 12'hB0D,
        MHPMCOUNTER14  = 12'hB0E,
        MHPMCOUNTER15  = 12'hB0F,
        MHPMCOUNTER16  = 12'hB10,
        MHPMCOUNTER17  = 12'hB11,
        MHPMCOUNTER18  = 12'hB12,
        MHPMCOUNTER19  = 12'hB13,
        MHPMCOUNTER20  = 12'hB14,
        MHPMCOUNTER21  = 12'hB15,
        MHPMCOUNTER22  = 12'hB16,
        MHPMCOUNTER23  = 12'hB17,
        MHPMCOUNTER24  = 12'hB18,
        MHPMCOUNTER25  = 12'hB19,
        MHPMCOUNTER26  = 12'hB1A,
        MHPMCOUNTER27  = 12'hB1B,
        MHPMCOUNTER28  = 12'hB1C,
        MHPMCOUNTER29  = 12'hB1D,
        MHPMCOUNTER30  = 12'hB1E,
        MHPMCOUNTER31  = 12'hB1F,
        MCYCLEH        = 12'hB80,
        MINSTRETH      = 12'hB82,
        MHPMCOUNTER3H  = 12'hB83,
        MHPMCOUNTER4H  = 12'hB84,
        MHPMCOUNTER5H  = 12'hB85,
        MHPMCOUNTER6H  = 12'hB86,
        MHPMCOUNTER7H  = 12'hB87,
        MHPMCOUNTER8H  = 12'hB88,
        MHPMCOUNTER9H  = 12'hB89,
        MHPMCOUNTER10H = 12'hB8A,
        MHPMCOUNTER11H = 12'hB8B,
        MHPMCOUNTER12H = 12'hB8C,
        MHPMCOUNTER13H = 12'hB8D,
        MHPMCOUNTER14H = 12'hB8E,
        MHPMCOUNTER15H = 12'hB8F,
        MHPMCOUNTER16H = 12'hB90,
        MHPMCOUNTER17H = 12'hB91,
        MHPMCOUNTER18H = 12'hB92,
        MHPMCOUNTER19H = 12'hB93,
        MHPMCOUNTER20H = 12'hB94,
        MHPMCOUNTER21H = 12'hB95,
        MHPMCOUNTER22H = 12'hB96,
        MHPMCOUNTER23H = 12'hB97,
        MHPMCOUNTER24H = 12'hB98,
        MHPMCOUNTER25H = 12'hB99,
        MHPMCOUNTER26H = 12'hB9A,
        MHPMCOUNTER27H = 12'hB9B,
        MHPMCOUNTER28H = 12'hB9C,
        MHPMCOUNTER29H = 12'hB9D,
        MHPMCOUNTER30H = 12'hB9E,
        MHPMCOUNTER31H = 12'hB9F,
        MHPMEVENT3     = 12'h323,
        MHPMEVENT4     = 12'h324,
        MHPMEVENT5     = 12'h325,
        MHPMEVENT6     = 12'h326,
        MHPMEVENT7     = 12'h327,
        MHPMEVENT8     = 12'h328,
        MHPMEVENT9     = 12'h329,
        MHPMEVENT10    = 12'h32A,
        MHPMEVENT11    = 12'h32B,
        MHPMEVENT12    = 12'h32C,
        MHPMEVENT13    = 12'h32D,
        MHPMEVENT14    = 12'h32E,
        MHPMEVENT15    = 12'h32F,
        MHPMEVENT16    = 12'h330,
        MHPMEVENT17    = 12'h331,
        MHPMEVENT18    = 12'h332,
        MHPMEVENT19    = 12'h333,
        MHPMEVENT20    = 12'h334,
        MHPMEVENT21    = 12'h335,
        MHPMEVENT22    = 12'h336,
        MHPMEVENT23    = 12'h337,
        MHPMEVENT24    = 12'h338,
        MHPMEVENT25    = 12'h339,
        MHPMEVENT26    = 12'h33A,
        MHPMEVENT27    = 12'h33B,
        MHPMEVENT28    = 12'h33C,
        MHPMEVENT29    = 12'h33D,
        MHPMEVENT30    = 12'h33E,
        MHPMEVENT31    = 12'h33F
    } CSR;

    typedef enum logic [3:0] {
        MSTATUS_R = 4'b0000, 
        MTVEC_R = 4'b0001, 
        MIP_R = 4'b0010, 
        MIE_R = 4'b0011, 
        MCYCLE_R = 4'b0100,
        MCYCLEH_R = 4'b0101, 
        MINSTRET_R = 4'b0110,
        MINSTRETH_R = 4'b0111, 
        MSCRATCH_R = 4'b1000, 
        MEPC_R = 4'b1001, 
        MCAUSE_R = 4'b1010,
        MISA_R = 4'b1011,
        ROZ_R = 4'b1100,
        FFLAGS_R = 4'b1101,
        FRM_R = 4'b1110,
        FCSR_R = 4'b1111
    } CSR_R;

    typedef enum logic [1:0] {
        INTEGER = 2'b00,
        FLOATING = 2'b01,
        MEMORY = 2'b10,
        SERIAL = 2'b11
    } LaneType_;

    // A single execution capability is required per decoded instruction.
    // Conversions, bit moves and classification use the independent CAP_FP_CONVERT.
    typedef enum logic [3:0] {
        CAP_ALU, CAP_BRU, CAP_MUL, CAP_DIV, CAP_FP_F,
        CAP_MEMORY, CAP_ATOMIC, CAP_SYSTEM, CAP_CSR, CAP_TRAP, CAP_FP_CONVERT
    } DecodeCapability_;

    typedef enum logic [2:0] {
        FPC_NONE, FPC_FROM_INT, FPC_TO_INT,
        FPC_FROM_BITS, FPC_TO_BITS, FPC_CLASS
    } FloatConvertOperation_;

    typedef enum logic [1:0] {
        MUL_LOW, MUL_HIGH_SS, MUL_HIGH_SU, MUL_HIGH_UU
    } MulOperation_;

    typedef enum logic [1:0] {
        DIV_SIGNED, DIV_UNSIGNED, REM_SIGNED, REM_UNSIGNED
    } DivOperation_;

    // Integer Operations
    typedef enum logic [3:0] {
        ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
        ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR, ALU_AND
    } AluOperation_;

    typedef enum logic [1:0] {
        ALU_RS1_RS2, ALU_RS1_IMM, ALU_PC_IMM, ALU_ZERO_IMM
    } AluSource_;

    typedef enum logic [3:0] {
        BR_NONE, BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU,
        BR_JAL, BR_JALR
    } BranchOperation_;

    // Memory Size Is Log2(Bytes)
    typedef enum logic [1:0] {
        MEM_BYTE, MEM_HALF, MEM_WORD
    } MemorySize_;

    typedef enum logic [1:0] {
        MEM_NONE, MEM_LOAD, MEM_STORE
    } MemoryOperation_;

    typedef enum logic [3:0] {
        ATOM_NONE, ATOM_LR, ATOM_SC, ATOM_SWAP, ATOM_ADD, ATOM_XOR,
        ATOM_AND, ATOM_OR, ATOM_MIN, ATOM_MAX, ATOM_MINU, ATOM_MAXU
    } AtomicOperation_;

    typedef enum logic [4:0] {
        FP_NONE, FP_ADD, FP_SUB, FP_MUL, FP_DIV, FP_SQRT,
        FP_MADD, FP_MSUB, FP_NMSUB, FP_NMADD,
        FP_SGNJ, FP_SGNJN, FP_SGNJX, FP_MIN, FP_MAX,
        FP_EQ, FP_LT, FP_LE, FP_TO_INT, FP_FROM_INT,
        FP_TO_BITS, FP_FROM_BITS, FP_CLASS
    } FloatOperation_;

    typedef enum logic [2:0] {
        SYS_NONE, SYS_FENCE, SYS_FENCE_I, SYS_MRET, SYS_WFI
    } SystemOperation_;

    typedef enum logic [1:0] {
        CSR_NONE, CSR_RW, CSR_RS, CSR_RC
    } CsrOperation_;

    typedef enum logic [3:0] { 
        NONE = 4'b0000,
        ILLEGAL = 4'b0001,
        MISALIGNED_STORE = 4'b0010,
        MISALIGNED_LOAD = 4'b0011,
        MISALIGNED_INST = 4'b0100,
        ECALL = 4'b0101,
        EBREAK = 4'b0110,
        STORE_ACCESS_FAULT = 4'b0111,
        LOAD_ACCESS_FAULT = 4'b1000,
        INST_ACCESS_FAULT = 4'b1001,
        INTERRUPT = 4'b1010
    } TrapType_; 

endpackage
