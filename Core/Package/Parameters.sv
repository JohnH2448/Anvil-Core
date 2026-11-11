package Parameters;

    parameter unsigned EXECUTION_UNROLL = 1;
    parameter unsigned BYPASS_ENABLED = 1;
    parameter unsigned ISSUE_WIDTH = 2;

    parameter unsigned SUPPORT_MUL = 1;
    parameter unsigned SUPPORT_DIV = 1;
    parameter unsigned SUPPORT_FLOAT = 1;
    parameter unsigned SUPPORT_ATOMIC = 1;

    parameter unsigned CACHE_LINE_WORDS = 2;
    parameter unsigned FETCH_FIFO_WORDS = 8;
    parameter unsigned RESET_VECTOR = 32'h0000_0000;

    parameter unsigned DIVIDER_AUTO_PIPE = 3;

    // TODO: Add a compile-time check that the configured lanes cover all RV32I instructions.
    parameter unsigned INTEGER_LANE_COUNT = 2;
    parameter logic [3:0] INTEGER_LANE_CAPABILITIES [INTEGER_LANE_COUNT] = '{
        4'b1111, // Lane 0: ALU, BRU, MUL, DIV
        4'b0011 // Lane 1: ALU, BRU
    };

    parameter unsigned MEMORY_LANE_COUNT = 1; 
    parameter logic [2:0] MEMORY_LANE_CAPABILITIES [MEMORY_LANE_COUNT] = '{
        3'b111 // Lane 0: MEMORY, ATOMIC, FLOAT
    };

    parameter unsigned FLOATING_LANE_COUNT = 1;
    parameter logic [1:0] FLOATING_LANE_CAPABILITIES [FLOATING_LANE_COUNT] = '{
        2'b11 // Lane 0: FLOAT, CONVERSION
    };

endpackage
