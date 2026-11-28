// Static BTFNT predictor for one fetch slot (used when ENABLE_GSHARE = 0).
module Predictor
    import Parameters::*;
    import DerivedParameters::*;
(
    // Interface Clock and Reset Are Unused; Queue Registers Prediction Results
    input logic clk,
    input logic reset,

    // Reconstructed Instruction Input and Combinational Prediction Output
    input Definitions::BranchInput_ branch_input,
    output Definitions::BranchOutput_ branch_output
);
    // Predicts Direct Jumps Taken and Conditional Branches Taken for Negative Offsets
    // Requires bp_branch to Identify Only B/JAL or C.B/C.J/C.JAL Instructions
    assign branch_output.bp_taken = branch_input.bp_branch &&
        (branch_input.bp_compressed ?
            (!branch_input.bp_instruction[14] || branch_input.bp_instruction[12]) :
            (branch_input.bp_instruction[3] || branch_input.bp_instruction[31]));
    // Exposes Prediction Validity
    assign branch_output.bp_valid = branch_input.bp_branch;

    // Target Is Used Only for Taken Predictions
    BranchTarget target (
        .branch_input,
        .redirect_pc(branch_output.bp_redirect_pc),
        .target_wrapped(branch_output.bp_target_wrapped)
    );
endmodule
