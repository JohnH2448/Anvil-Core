package Parameters;

    // ------------------------------------------------------------ Pipeline

    // How many instructions may issue per cycle (Max: 2)
    parameter unsigned ISSUE_WIDTH = 2;
    // How many pipeline stages the backend unrolls to (Min: 1)
    parameter unsigned EXECUTION_UNROLL = 3;
    // Enables ALU direct bypass to operand selection (add, sub, xor, or, and)
    parameter bit ENABLE_BYPASS = 1;
    // Enables shift bypass to operand selection (needs ENABLE_BYPASS)
    parameter bit ENABLE_SHIFT_BYPASS = 1;
    // Enables compare bypass to operand selection (needs ENABLE_BYPASS)
    parameter bit ENABLE_COMPARE_BYPASS = 0;

    // ------------------------------------------------------------ ISA support

    // Enables the core to support RISCV multiply instructions
    parameter bit SUPPORT_MUL = 1;
    // Enables the core to support RISCV divide instructions
    parameter bit SUPPORT_DIV = 1;
    // Enables the core to support RISCV floating point instructions
    parameter bit SUPPORT_FLOAT = 0;
    // Enables the core to support RISCV atomic instructions
    parameter bit SUPPORT_ATOMIC = 0;

    // ------------------------------------------------------------ Execution lanes
    // Physical lane order: serial (lane 0), integer, memory, floating.

    // How many integer lanes the backend instantiates
    parameter unsigned INTEGER_LANE_COUNT = 2;
    // Per integer lane capability mask [3:0] = {DIV, MUL, BRU, ALU}
    parameter logic [3:0] INTEGER_LANE_CAPABILITIES [(INTEGER_LANE_COUNT > 0 ? INTEGER_LANE_COUNT : 1)] = '{
        4'b1111,
        4'b0011
    };
    // How many memory lanes the backend instantiates (Max: 1)
    parameter unsigned MEMORY_LANE_COUNT = 1;
    // Per memory lane capability mask [2:0] = {FLOAT, ATOMIC, MEMORY}
    parameter logic [2:0] MEMORY_LANE_CAPABILITIES [(MEMORY_LANE_COUNT > 0 ? MEMORY_LANE_COUNT : 1)] = '{
        3'b001
    };
    // How many floating point lanes the backend instantiates
    parameter unsigned FLOATING_LANE_COUNT = 0;
    // Per floating lane capability mask [1:0] = {CONVERSION, FLOAT}
    parameter logic [1:0] FLOATING_LANE_CAPABILITIES [(FLOATING_LANE_COUNT > 0 ? FLOATING_LANE_COUNT : 1)] = '{
        2'b11
    };
    // Quotient bits the divider resolves per stage (radix 2^N, range 1..4)
    parameter unsigned DIVIDER_AUTO_PIPE = 3;
    // FP loads forward to FP consumers only from the register file
    parameter bit FP_LOAD_RF_ONLY = 0; // need to use this when designing memory/float lanes and their ports

    // ------------------------------------------------------------ Fetch

    // The number of words the prefetcher may receive per cycle
    parameter unsigned FETCH_WORDS = 2; // prev cache_line_words
    // The number of words the prefetcher may store in its FIFO
    parameter unsigned FETCH_FIFO_WORDS = 8;

    // ------------------------------------------------------------ Branch prediction

    // Enables the GShare conditional branch predictor
    parameter bit ENABLE_GSHARE = 1;
    // GShare global history length in branches
    parameter unsigned GSHARE_GHR_DEPTH = 8;
    // GShare pattern history table entry count (power of two)
    parameter unsigned GSHARE_PHT_DEPTH = 256;
    // Enables GShare training on branches squashed by an older redirect
    parameter bit ENABLE_SQUASHED_TRAINING = 1; // 1 is better here trust

    // Enables the return address stack: predicts JALR/C.JR returns at fetch
    parameter bit ENABLE_RAS = 1;
    // RAS entry count (power of two >= 2)
    parameter unsigned RAS_DEPTH = 4;
    // Enables RAS repair: a backend redirect restores the RAS pointer/count each
    // window carried from before its update (needs ENABLE_RAS)
    parameter bit ENABLE_RAS_REPAIR = 1;

    // Enables the branch target buffer: steers fetch to a taken branch's target
    // from the window address; the prediction stage verifies it
    parameter bit ENABLE_BTB = 1;
    // BTB entry count (power of two >= 2)
    parameter unsigned BTB_ENTRIES = 64;

    // ------------------------------------------------------------ Memory system

    // Enables the store buffer: the last STORE_BUFFER_DEPTH aligned word stores
    // to RAM, newest first. A load whose word hits completes in the AGU stage
    // and skips the LSU; stores still go to memory (needs MEMORY_LANE_COUNT = 1)
    parameter bit ENABLE_STORE_BUFFER = 1;
    // Store buffer entry count (Min: 1)
    parameter unsigned STORE_BUFFER_DEPTH = 5; // 10 works, 5 doesnt, 20 doesnt imrove it much. Try 6-12 range
    // Enables LSU direct send: an idle LSU sends a load straight from the AGU in
    // its execute cycle instead of from the queue a cycle later
    parameter bit ENABLE_LSU_DIRECT_SEND = 1; // Single memory lane only (off automatically on 2+)

    // ------------------------------------------------------------ Address map
    // Devices (CLINT, UART) in [0, RAM_BASE), RAM in [RAM_BASE, MAX_MEMORY_ADDRESS].

    // First RAM address
    parameter logic [31:0] RAM_BASE = 32'h0000_0200;
    // PC fetched out of reset
    parameter logic [31:0] RESET_VECTOR = 32'h0000_0200;
    // Last valid memory address; anything above it faults in the AGU
    parameter logic [31:0] MAX_MEMORY_ADDRESS = 32'h0000_FFFF;

endpackage

