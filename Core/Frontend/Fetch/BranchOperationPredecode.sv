module BranchOperationPredecode
    import Parameters::*;
    import DerivedParameters::*;
    import Enumerations::*;
(
    input logic [31:0] instruction,
    input logic is_compressed,
    output BranchOperation_ operation
);
    wire [15:0] c = instruction[15:0];
    wire [6:0] op = instruction[6:0];
    wire [2:0] f3 = instruction[14:12];
    wire jal = !is_compressed && op == 7'b1101111;
    wire jalr = !is_compressed && op == 7'b1100111;
    wire branch_op = !is_compressed && op == 7'b1100011;
    wire c_jump = is_compressed && c[1:0] == 1 && (c[15:13] inside {3'b001,3'b101});
    wire c_branch = is_compressed && c[1:0] == 1 && (c[15:13] inside {3'b110,3'b111});
    wire c_cr = is_compressed && c[1:0] == 2 && c[15:13] == 4;
    always_comb begin
        operation = BR_NONE;
            case (1'b1)
                jal || c_jump: operation = BR_JAL;
                jalr || (c_cr && c[6:2] == 0): operation = BR_JALR;
                c_branch: operation = c[13] ? BR_NE : BR_EQ;
                branch_op && f3 == 3'd0: operation = BR_EQ;
                branch_op && f3 == 3'd1: operation = BR_NE;
                branch_op && f3 == 3'd4: operation = BR_LT;
                branch_op && f3 == 3'd5: operation = BR_GE;
                branch_op && f3 == 3'd6: operation = BR_LTU;
                branch_op && f3 == 3'd7: operation = BR_GEU;
                default: ;
            endcase
    end
endmodule
