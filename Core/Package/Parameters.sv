package Parameters;

    parameter unsigned EXECUTION_UNROLL = 3;
    parameter unsigned BYPASS_ENABLED = 1;
    // 3+ not yet supported
    parameter unsigned ISSUE_WIDTH = 2;

    parameter unsigned SUPPORT_MUL = 1;
    parameter unsigned SUPPORT_DIV = 1;
    // A and F not yet supported
    parameter unsigned SUPPORT_FLOAT = 0;
    parameter unsigned SUPPORT_ATOMIC = 0;

    parameter bit FP_LOAD_RF_ONLY = 0; // need to use this when designing memory/float lanes and their ports

    parameter unsigned CACHE_LINE_WORDS = 2;
    parameter unsigned FETCH_FIFO_WORDS = 8;

    parameter unsigned USE_GSHARE = 1;
    parameter unsigned GSHARE_GHR_DEPTH = 8;
    parameter unsigned GSHARE_PHT_DEPTH = 256;
    parameter unsigned TRAIN_SQUASHED_BRANCHES = 1; // 1 is better here trust

    // 1: a store waits for every older bus response, so bus errors are
    // precise. 0: stores may overtake an older load's error (imprecise).
    parameter bit PRECISE_BUS_FAULTS = 0;
    // Address map: devices (CLINT) in [0, RAM_BASE), RAM in
    // [RAM_BASE, MAX_MEMORY_ADDRESS]. Execution starts at the RAM base.
    parameter logic [31:0] RAM_BASE = 32'h0000_0200;
    parameter unsigned RESET_VECTOR = 32'h0000_0200;
    parameter logic [31:0] MAX_MEMORY_ADDRESS = 32'h0000_FFFF;

    parameter unsigned DIVIDER_AUTO_PIPE = 2;

    // Integer mask [3:0] = {DIV, MUL, BRU, ALU}.
    parameter unsigned INTEGER_LANE_COUNT = 2;
    parameter logic [3:0] INTEGER_LANE_CAPABILITIES [(INTEGER_LANE_COUNT > 0 ? INTEGER_LANE_COUNT : 1)] = '{
        4'b1111,
        4'b0011
    };

    // Memory mask [2:0] = {FLOAT, ATOMIC, MEMORY}.
    // More than 1 lane not yet supported
    parameter unsigned MEMORY_LANE_COUNT = 1; 
    parameter logic [2:0] MEMORY_LANE_CAPABILITIES [(MEMORY_LANE_COUNT > 0 ? MEMORY_LANE_COUNT : 1)] = '{
        3'b001
    };

    // Floating mask [1:0] = {CONVERSION, FLOAT}.
    parameter unsigned FLOATING_LANE_COUNT = 0;
    parameter logic [1:0] FLOATING_LANE_CAPABILITIES [(FLOATING_LANE_COUNT > 0 ? FLOATING_LANE_COUNT : 1)] = '{
        2'b11
    };
  
endpackage

// very real possibility for same cycle RAW legality here

// also ai needs to do a run and better hardware param everything
