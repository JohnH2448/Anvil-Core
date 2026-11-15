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

    // Capture-edge progress outputs for Decode (already aged unless stalled)
    output logic [UNROLLED_W-1:0] rs1_index [ISSUE_WIDTH-1:0],
    output logic [UNROLLED_W-1:0] rs2_index [ISSUE_WIDTH-1:0],
    output logic [LANE_WIDTH-1:0] rs1_lane [ISSUE_WIDTH-1:0],
    output logic [LANE_WIDTH-1:0] rs2_lane [ISSUE_WIDTH-1:0],
    output DecodeCapability_ rs1_capability [ISSUE_WIDTH-1:0],
    output DecodeCapability_ rs2_capability [ISSUE_WIDTH-1:0],

    // Register Destination Writes
    input logic [4:0] op_rd [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] op_lane [ISSUE_WIDTH-1:0],
    input logic op_write [ISSUE_WIDTH-1:0],
    input logic [AGE_WIDTH-1:0] op_age [ISSUE_WIDTH-1:0],
    input DecodeCapability_ op_type [ISSUE_WIDTH-1:0]

);
    
    // Current producer position: 0 = operand select, 1 = execute,
    // 2..EXECUTION_UNROLL+1 = result registers, EXECUTION_UNROLL+2 = RF.
    localparam logic [UNROLLED_W-1:0] RF_INDEX = UNROLLED_W'(EXECUTION_UNROLL + 2);

    // Registered producer identity and progress, indexed by architectural register.
    logic [UNROLLED_W-1:0] index_table [31:0];
    logic [LANE_WIDTH-1:0] lane_table [31:0];
    DecodeCapability_ capability_table [31:0];
    // Compute progress per entry before the source-address read mux.
    // Decode must not age these outputs again. Buffered writes bypass in Decode.
    logic [UNROLLED_W-1:0] capture_index [31:0];
    for (genvar regno = 0; regno < 32; regno++) begin : read_progress
        assign capture_index[regno] = (!stall && index_table[regno] < RF_INDEX)
            ? index_table[regno] + UNROLLED_W'(1) : index_table[regno];
    end

    // Issuer buffers writes and suppresses older duplicate destinations before capture.
    // Commit advances the buffered producer from index zero to index one.
    // op_age remains an interface tag, not a dynamic arbitration input.
    for (genvar regno = 0; regno < 32; regno++) begin : entries
        logic candidate [ISSUE_WIDTH];
        logic hit [ISSUE_WIDTH];
        logic write_valid;
        logic [LANE_WIDTH-1:0] write_lane;
        DecodeCapability_ write_capability;

        for (genvar slot = 0; slot < ISSUE_WIDTH; slot++) begin : writers
            if (regno == 0) begin : zero_register
                assign candidate[slot] = 1'b0;
            end else begin : destination_match
                // Registered destinations and valid bits arrive together.
                assign candidate[slot] = op_rd[slot] == 5'(regno);
            end
            assign hit[slot] = candidate[slot] && op_write[slot];
        end
        always_comb begin
            write_valid = 1'b0;
            write_lane = '0;
            write_capability = DecodeCapability_'('0);
            // Destinations were deduplicated before buffer capture: parallel mux.
            for (int slot = 0; slot < ISSUE_WIDTH; slot++) begin
                write_valid |= hit[slot];
                write_lane |= {LANE_WIDTH{hit[slot]}} & op_lane[slot];
                write_capability = DecodeCapability_'(write_capability |
                    ({$bits(DecodeCapability_){hit[slot]}} & op_type[slot]));
            end
        end

        // Redirect recovery remains backend-owned; mappings hold on redirect.
        always_ff @(posedge clk) begin
            if (reset) begin
                index_table[regno] <= RF_INDEX;
            end else if (!stall && !redirect_taken) begin
                if (write_valid) begin
                    index_table[regno] <= UNROLLED_W'(1);
                    lane_table[regno] <= write_lane;
                    capability_table[regno] <= write_capability;
                end else begin
                    if (index_table[regno] < RF_INDEX)
                        index_table[regno] <= index_table[regno] + UNROLLED_W'(1);
                end
            end
        end
    end

    // Operand Serving
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            rs1_index[s] = capture_index[rs1[s]];
            rs2_index[s] = capture_index[rs2[s]];
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

    // Reads expose aged current mappings, with buffered-write bypass in Decode.


endmodule
