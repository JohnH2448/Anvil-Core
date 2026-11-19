package Parameters;

    parameter unsigned EXECUTION_UNROLL = 1;
    parameter unsigned BYPASS_ENABLED = 1;
    parameter unsigned ISSUE_WIDTH = 1;

    parameter unsigned SUPPORT_MUL = 1;
    parameter unsigned SUPPORT_DIV = 1;
    parameter unsigned SUPPORT_FLOAT = 1;
    parameter unsigned SUPPORT_ATOMIC = 1;

    parameter bit FP_LOAD_RF_ONLY = 1; // need to use this when designing memory/float lanes and their ports

    parameter unsigned CACHE_LINE_WORDS = 1;
    parameter unsigned FETCH_FIFO_WORDS = 8;

    parameter logic [31:0] MAX_MEMORY_ADDRESS = 32'h0000_07ff;
    parameter unsigned RESET_VECTOR = 32'h0000_0000;

    parameter unsigned DIVIDER_AUTO_PIPE = 3;

    // Integer mask [3:0] = {DIV, MUL, BRU, ALU}.
    parameter unsigned INTEGER_LANE_COUNT = 1;
    parameter logic [3:0] INTEGER_LANE_CAPABILITIES [(INTEGER_LANE_COUNT > 0 ? INTEGER_LANE_COUNT : 1)] = '{
        4'b1111
        //4'b0011
    };

    // Memory mask [2:0] = {FLOAT, ATOMIC, MEMORY}.
    parameter unsigned MEMORY_LANE_COUNT = 1; 
    parameter logic [2:0] MEMORY_LANE_CAPABILITIES [(MEMORY_LANE_COUNT > 0 ? MEMORY_LANE_COUNT : 1)] = '{
        3'b111
    };

    // Floating mask [1:0] = {CONVERSION, FLOAT}.
    parameter unsigned FLOATING_LANE_COUNT = 1;
    parameter logic [1:0] FLOATING_LANE_CAPABILITIES [(FLOATING_LANE_COUNT > 0 ? FLOATING_LANE_COUNT : 1)] = '{
        2'b11
    };
  
endpackage

// very real possibility for same cycle RAW legality here

// also ai needs to do a run and better hardware param everything