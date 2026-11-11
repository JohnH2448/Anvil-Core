// Trap handling is implicit in every lane via common.trap_type.
module SerialLane
    import DerivedParameters::*;
#(
    parameter unsigned EXECUTION_UNROLL = 1, // execution stages
    parameter unsigned ISSUE_WIDTH = 2 // for inter slice age bits
)(

);
endmodule
