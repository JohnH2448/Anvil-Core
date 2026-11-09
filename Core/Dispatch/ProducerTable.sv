module ProducerTable
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned ISSUE_WIDTH = 2,
    parameter unsigned UNROLL_CUTOFF = 1
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
    
    // Table Declaration
    logic [UNROLLED_W-1:0] index_table [31:0]; // 0 == first stage
    logic [LANE_WIDTH-1:0] lane_table [31:0]; // by lane id
    DecodeCapability_ capability_table [31:0];
    logic [UNROLLED_W-1:0] countdown_table [31:0]; // 0 == result produced

    // Index Value Latching
    always_ff @(posedge clk) begin
        if (reset) begin
            foreach (index_table[i]) begin
                index_table[i] <= '0;
            end
        end else begin
            if (!stall) begin
                if (redirect_taken) begin
                    // fill
                end else begin
                    for (int unsigned k = 0; k < ISSUE_WIDTH; k++) begin
                        logic youngest;
                        youngest = 1'b1;
                        for (int unsigned j = 0; j < ISSUE_WIDTH; j++) begin
                            if ((op_rd[j] == op_rd[k]) && op_accept[j] && op_wb[j]) begin
                                if (op_age[j] > op_age[k]) begin
                                    youngest = 1'b0;
                                end
                            end
                        end
                        foreach (index_table[i]) begin
                            if (youngest && ($unsigned(i) == $unsigned(32'(op_rd[k]))) && op_accept[k] && op_wb[k]) begin
                                index_table[i] <= '0;
                            end else if (index_table[i] < (UNROLL_CUTOFF+2)+1) begin // (UNROLL_CUTOFF+2)+1 == register file
                                index_table[i] <= index_table[i] + $unsigned(LANE_WIDTH'(2));
                            end
                        end
                    end
                end
            end
        end
    end

    // Countdown Value Latching
    always_ff @(posedge clk) begin
        if (reset) begin
            foreach (countdown_table[i]) begin
                countdown_table[i] <= '0;
            end
        end else begin
            if (!stall) begin
                if (redirect_taken) begin
                    // fill
                end else begin
                    for (int unsigned k = 0; k < ISSUE_WIDTH; k++) begin
                        logic youngest;
                        youngest = 1'b1;
                        for (int unsigned j = 0; j < ISSUE_WIDTH; j++) begin
                            if ((op_rd[j] == op_rd[k]) && op_accept[j] && op_wb[j]) begin
                                if (op_age[j] > op_age[k]) begin
                                    youngest = 1'b0;
                                end
                            end
                        end
                        foreach (countdown_table[i]) begin
                            if (youngest && ($unsigned(i) == $unsigned(32'(op_rd[k]))) && op_accept[k] && op_wb[k]) begin
                                // Issue legal at source countdown == 1
                                unique case (op_type[k])
                                    CAP_ALU, CAP_BRU: countdown_table[i] <= UNROLLED_W'(1'b1);
                                    CAP_MUL: countdown_table[i] <= UNROLLED_W'(2'd2);
                                    CAP_DIV: countdown_table[i] <= UNROLLED_W'(UNROLL_CUTOFF+2'd2);
                                    CAP_MEMORY: countdown_table[i] <= UNROLLED_W'(2'd2); // TEMP: fill w/ index of first possible registered load back

                                endcase
                            end else if (countdown_table[i] > 0) begin
                                countdown_table[i] <= countdown_table[i] - UNROLLED_W'(1'b1);
                            end
                        end
                    end
                end
            end
        end
    end // consider memory index carefully. doesnt need to trigger stall until operand is needed or iteration
    // also consider cycle + 1 perspective and validity

    // Lane and Capability Latching
    always_ff @(posedge clk) begin
        if (!stall) begin
            if (redirect_taken) begin
                // fill
            end else begin
                for (int unsigned k = 0; k < ISSUE_WIDTH; k++) begin
                    logic youngest;
                    youngest = 1'b1;
                    for (int unsigned j = 0; j < ISSUE_WIDTH; j++) begin
                        if ((op_rd[j] == op_rd[k]) && op_accept[j] && op_wb[j]) begin
                            if (op_age[j] > op_age[k]) begin
                                youngest = 1'b0;
                            end
                        end
                    end
                    foreach (lane_table[i]) begin
                        if (youngest && ($unsigned(i) == $unsigned(32'(op_rd[k]))) && op_accept[k] && op_wb[k]) begin
                            lane_table[i] <= op_lane[k];
                            capability_table[i] <= op_type[k];
                        end
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

    // make ais play 20 questions with eachother

endmodule
