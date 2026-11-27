package Parameters;

    parameter unsigned EXECUTION_UNROLL = 1;
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

    // Return address stack: predicts JALR/C.JR returns at fetch. USE_RAS = 0
    // removes all of its hardware. RAS_DEPTH is an entry count (power of two >= 2).
    parameter unsigned USE_RAS = 1;
    parameter unsigned RAS_DEPTH = 4;
    // RAS mispredict repair: each window carries the RAS pointer/count from
    // before its update; a backend redirect restores it (with the rest of the
    // frontend flush). Needs USE_RAS. 0 removes the repair hardware.
    parameter unsigned RAS_REPAIR = 1;

    // Branch target buffer: steers fetch to a taken branch's target from the
    // window address, before the instruction bytes arrive; the prediction stage
    // verifies it. USE_BTB = 0 removes all of its hardware. BTB_ENTRIES is an
    // entry count (power of two >= 2).
    parameter unsigned USE_BTB = 1;
    parameter unsigned BTB_ENTRIES = 64;


    // Store buffer: the last STORE_BUFFER_DEPTH aligned word stores to RAM, as a
    // shift register (newest first, oldest dropped). A load whose word hits is
    // completed from it in the AGU stage and skips the LSU. Stores still go to
    // memory through the LSU; the buffer only forwards. USE_STORE_BUFFER = 0
    // removes it. Requires MEMORY_LANE_COUNT = 1.
    parameter unsigned USE_STORE_BUFFER = 1;
    parameter unsigned STORE_BUFFER_DEPTH = 5; // 10 works, 5 doesnt, 20 doesnt imrove it much. Try 6-12 range
    // LSU direct send: an idle LSU sends a RAM load straight from the AGU in its
    // execute cycle (the BRAM input register samples it), instead of from the
    // queue a cycle later. 0 keeps every request on the queue path.
    parameter unsigned LSU_DIRECT_SEND = 1; // Single memory lane only (off automatically on 2+)
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
