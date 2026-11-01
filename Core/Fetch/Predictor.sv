module Predictor (
    // Interface Clock and Reset Are Unused; Queue Registers Prediction Results
    input logic clk,
    input logic reset,

    // Reconstructed Instruction Input and Combinational Prediction Output
    input Definitions::BranchInput_ branch_input,
    output Definitions::BranchOutput_ branch_output
);
    // Combinational Direction and Signed Target Displacement
    logic predict_taken;
    logic [31:0] displacement;

    // Predicts Direct Jumps Taken and Conditional Branches Taken for Negative Offsets
    // Requires bp_branch to Identify Only B/JAL or C.B/C.J/C.JAL Instructions
    assign predict_taken = branch_input.bp_branch &&
        (branch_input.bp_compressed ?
            (!branch_input.bp_instruction[14] || branch_input.bp_instruction[12]) :
            (branch_input.bp_instruction[3] || branch_input.bp_instruction[31]));
    // Exposes Direction and Prediction Validity
    assign branch_output.bp_taken = predict_taken;
    assign branch_output.bp_valid = branch_input.bp_branch;

    // Reconstructs Signed Displacement Independently of Direction and Validity
    // Target Is Used Only for Taken Predictions
    always_comb begin
        if (branch_input.bp_compressed) begin
            // Selects Compressed Conditional Branch or Direct Jump Immediate
            if (branch_input.bp_instruction[14])
                displacement = {{23{branch_input.bp_instruction[12]}}, branch_input.bp_instruction[12],
                    branch_input.bp_instruction[6:5], branch_input.bp_instruction[2],
                    branch_input.bp_instruction[11:10], branch_input.bp_instruction[4:3], 1'b0};
            else
                displacement = {{20{branch_input.bp_instruction[12]}}, branch_input.bp_instruction[12],
                    branch_input.bp_instruction[8], branch_input.bp_instruction[10:9],
                    branch_input.bp_instruction[6], branch_input.bp_instruction[7],
                    branch_input.bp_instruction[2], branch_input.bp_instruction[11],
                    branch_input.bp_instruction[5:3], 1'b0};
        end else if (branch_input.bp_instruction[3]) begin
            // Reconstructs JAL Immediate
            displacement = {{11{branch_input.bp_instruction[31]}}, branch_input.bp_instruction[31],
                branch_input.bp_instruction[19:12], branch_input.bp_instruction[20],
                branch_input.bp_instruction[30:21], 1'b0};
        end else begin
            // Reconstructs Conditional Branch Immediate
            displacement = {{19{branch_input.bp_instruction[31]}}, branch_input.bp_instruction[31],
                branch_input.bp_instruction[7], branch_input.bp_instruction[30:25],
                branch_input.bp_instruction[11:8], 1'b0};
        end
    end

    // Calculates PC-Relative Branch Target
    assign branch_output.bp_redirect_pc = branch_input.bp_pc + displacement;
endmodule
