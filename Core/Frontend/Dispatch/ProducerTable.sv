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
    localparam logic [UNROLLED_W-1:0] RF_INDEX = UNROLLED_W'(EXECUTION_UNROLL + 2);

    // Registered producer identity and progress, indexed by architectural register.
    logic [UNROLLED_W-1:0] index_table [31:0];
    logic [LANE_WIDTH-1:0] lane_table [31:0];
    DecodeCapability_ capability_table [31:0];
    // Pipeline advances until the source can reach its forwarding point.
    // A consumer may issue at <= 1; execution checks variable-latency readiness.
    logic [UNROLLED_W-1:0] countdown_table [31:0];

    // Select the youngest accepted writer to each register. Equal ages retain
    // the previous priority rule: the higher issue slot wins. x0 never allocates.
    int selected_writer [31:0];
    logic [UNROLLED_W-1:0] issue_countdown [ISSUE_WIDTH-1:0];
    always_comb begin
        for (int k = 0; k < ISSUE_WIDTH; k++)
            issue_countdown[k] = producer_countdown(op_type[k], EXECUTION_UNROLL, Parameters::DIVIDER_AUTO_PIPE);
        foreach (selected_writer[i]) begin
            selected_writer[i] = -1;
            for (int k = 0; k < ISSUE_WIDTH; k++) begin
                if (i != 0 && op_accept[k] && op_wb[k] && op_rd[k] == 5'(i)) begin
                    if (selected_writer[i] == -1) selected_writer[i] = k;
                    else if (op_age[k] >= op_age[selected_writer[i]]) selected_writer[i] = k;
                end
            end
        end
    end

    // New writers replace old mappings; otherwise progress saturates at the RF.
    // Both position and countdown freeze during iteration/global stalls.
    // TODO: Redirect currently holds state; restore surviving producers before issue resumes.
    always_ff @(posedge clk) begin
        if (reset) begin
            foreach (index_table[i]) begin
                index_table[i] <= UNROLLED_W'(RF_INDEX);
                countdown_table[i] <= '0;
            end
        end else if (!stall && !redirect_taken) begin
            foreach (index_table[i]) begin
                if (selected_writer[i] != -1) begin
                    index_table[i] <= '0;
                    lane_table[i] <= op_lane[selected_writer[i]];
                    capability_table[i] <= op_type[selected_writer[i]];
                    countdown_table[i] <= issue_countdown[selected_writer[i]];
                end else begin
                    if (index_table[i] < RF_INDEX)
                        index_table[i] <= index_table[i] + UNROLLED_W'(1);
                    if (countdown_table[i] != 0)
                        countdown_table[i] <= countdown_table[i] - UNROLLED_W'(1);
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
