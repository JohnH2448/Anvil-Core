module SerialLane #(
    parameter IS_TRAP = 1, // for ai, trap cabability is global in every pipeline lane, needs to be removed and factored into decoder
    parameter IS_CSR = 1,
    parameter IS_SYSTEM = 1,
    parameter UNROLL_CUTOFF = 4, // 5 stages total. should never be <= 0
    parameter ISSUE_WIDTH = 2, // for inter slice age bits
    parameter AGE_WIDTH = (ISSUE_WIDTH > 1) ? $clog2(ISSUE_WIDTH) : 1
)(

);
endmodule