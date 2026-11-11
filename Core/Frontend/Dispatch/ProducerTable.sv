module ProducerTable
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned ISSUE_WIDTH = 2,
    parameter unsigned EXECUTION_UNROLL = 1
)(

    // Standard Inputs
    input logic clk,
    input logic reset,
    input logic stall,
    input logic redirect_taken,

    // Register Source Read Inputs
    input logic [4:0] rs1 [ISSUE_WIDTH-1:0],
    input logic [4:0] rs2 [ISSUE_WIDTH-1:0],

    // Register Source Read Outputs
    output logic [UNROLLED_W-1:0] rs1_index [ISSUE_WIDTH-1:0],
    output logic [UNROLLED_W-1:0] rs2_index [ISSUE_WIDTH-1:0],
    output logic [UNROLLED_W-1:0] rs1_countdown [ISSUE_WIDTH-1:0],
    output logic [UNROLLED_W-1:0] rs2_countdown [ISSUE_WIDTH-1:0],
    output logic [LANE_WIDTH-1:0] rs1_lane [ISSUE_WIDTH-1:0],
    output logic [LANE_WIDTH-1:0] rs2_lane [ISSUE_WIDTH-1:0],
    output DecodeCapability_ rs1_capability [ISSUE_WIDTH-1:0],
    output DecodeCapability_ rs2_capability [ISSUE_WIDTH-1:0],

    // Register Destination Writes
    input logic [4:0] op_rd [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] op_lane [ISSUE_WIDTH-1:0],
    input logic op_accept [ISSUE_WIDTH-1:0],
    input logic [AGE_WIDTH-1:0] op_age [ISSUE_WIDTH-1:0],
    input DecodeCapability_ op_type [ISSUE_WIDTH-1:0],
    input logic op_wb [ISSUE_WIDTH-1:0]

);
    
    // Current producer position: 0 = operand select, 1 = execute,
    // 2..EXECUTION_UNROLL+1 = result registers, EXECUTION_UNROLL+2 = RF.
    localparam int unsigned RF_INDEX = EXECUTION_UNROLL + 2;
    localparam int unsigned DIV_RESULT_POSITION =
        (32 + Parameters::DIVIDER_AUTO_PIPE - 1) / Parameters::DIVIDER_AUTO_PIPE + 3;
    logic [UNROLLED_W-1:0] index_table [31:0];
    logic [LANE_WIDTH-1:0] lane_table [31:0];
    DecodeCapability_ capability_table [31:0];
    // Pipeline advances until the source can reach its forwarding point.
    // A consumer may issue at <= 1; execution checks variable-latency readiness.
    logic [UNROLLED_W-1:0] countdown_table [31:0];

    always_ff @(posedge clk) begin
        if (reset) begin
            foreach (index_table[i]) begin
                index_table[i] <= UNROLLED_W'(RF_INDEX);
                countdown_table[i] <= '0;
            end
        end else if (!stall) begin
            if (redirect_taken) begin
                // TODO: Restore youngest surviving producers before resuming issue.
            end else begin
                foreach (index_table[i]) begin
                    int winner;
                    winner = -1;
                    for (int k = 0; k < ISSUE_WIDTH; k++) begin
                        if (i != 0 && op_accept[k] && op_wb[k] && op_rd[k] == i) begin
                            if (winner == -1) winner = k;
                            else if (op_age[k] >= op_age[winner]) winner = k;
                        end
                    end

                    if (winner != -1) begin
                        index_table[i] <= '0;
                        lane_table[i] <= op_lane[winner];
                        capability_table[i] <= op_type[winner];
                        case (op_type[winner])
                            CAP_ALU: countdown_table[i] <= UNROLLED_W'(1);
                            CAP_BRU: countdown_table[i] <= UNROLLED_W'(2);
                            CAP_MUL: countdown_table[i] <= UNROLLED_W'(
                                EXECUTION_UNROLL < 2 ? EXECUTION_UNROLL + 1 : 3);
                            CAP_DIV: countdown_table[i] <= UNROLLED_W'(
                                EXECUTION_UNROLL + 1 < DIV_RESULT_POSITION ?
                                EXECUTION_UNROLL + 1 : DIV_RESULT_POSITION);
                            // Placeholder until the memory lane defines its first result slot.
                            CAP_MEMORY: countdown_table[i] <= UNROLLED_W'(2);
                            default: countdown_table[i] <= UNROLLED_W'(EXECUTION_UNROLL + 1);
                        endcase
                    end else begin
                        if (index_table[i] < RF_INDEX)
                            index_table[i] <= index_table[i] + UNROLLED_W'(1);
                        if (countdown_table[i] != 0)
                            countdown_table[i] <= countdown_table[i] - UNROLLED_W'(1);
                    end
                end
            end
        end
    end
    
    // Operand Serving
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            rs1_index[s] = index_table[rs1[s]];
            rs2_index[s] = index_table[rs2[s]];
            rs1_countdown[s] = countdown_table[rs1[s]];
            rs2_countdown[s] = countdown_table[rs2[s]];
            rs1_lane[s] = lane_table[rs1[s]];
            rs2_lane[s] = lane_table[rs2[s]];
            rs1_capability[s] = capability_table[rs1[s]];
            rs2_capability[s] = capability_table[rs2[s]];
        end
    end

    // real concern of redirect state restoration
    // perhaps post redirect, nothing may issue until pipeline clears
    // several cycles of mercy to restore and do priority select because
    // the frontend needs several cycles to refill. this is prob best
    // for performance unless i can think of something cleverer
    // maybe keep a state change shift register and restore from it
    // also an option of searching lanes and restoring state from there
    // also an option that issue searches every lane every cycle for
    // data rather than keeping a register file. same as standard
    // cpus but moves that to issue rather than in forward crit path

    // another option, taking advantage of the refill penalty, is to take
    // 1-2 cycles to derive state from present pipeline data. 

    // also consideration that same cycle overwrite entry and reference
    // is contentious. need smart dual condition logic to handle it. 
    // need to block same cycle producer consumer dependencies at issue.

    // probably going with current state, not next state.


endmodule
