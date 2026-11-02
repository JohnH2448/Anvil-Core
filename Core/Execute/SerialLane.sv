// Trap handling is implicit in every lane via common.trap_type.
module SerialLane
    import DerivedParameters::*;
#(
    parameter UNROLL_CUTOFF = 1, // execution stages
    parameter ISSUE_WIDTH = 2 // for inter slice age bits
)(

);
endmodule
