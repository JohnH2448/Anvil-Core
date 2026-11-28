// Direct branch/jump target for one fetch slot, shared by the static Predictor
// and GShare. Decodes the B/JAL or C.B/C.J/C.JAL immediate and adds it to the
// slot PC. The target is meaningful only for taken predictions.
module BranchTarget
    import Parameters::*;
    import DerivedParameters::*;
(
    input Definitions::BranchInput_ branch_input,
    output fetch_pc_t redirect_pc,
    output logic target_wrapped
);
    logic [31:0] displacement;

    // Reconstructs Signed Displacement Independently of Direction and Validity
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

    // Split the signed displacement into whole windows and a low offset.
    // Only the low sum carries. The high tests depend solely on the displacement.
    logic carry;
    wire signed [31:0] window_offset = $signed(displacement) >>> FETCH_PC_WIDTH;
    assign {carry, redirect_pc} = {1'b0, branch_input.bp_pc}
        + {1'b0, fetch_pc_t'(displacement)};
    assign target_wrapped = carry ? window_offset != -1 : window_offset != 0;
endmodule
