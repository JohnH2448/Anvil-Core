module DecodeStage
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned ISSUE_WIDTH = 2,
    parameter unsigned SUPPORT_MUL = 1,
    parameter unsigned SUPPORT_DIV = 1,
    parameter unsigned SUPPORT_FLOAT = 1,
    parameter unsigned SUPPORT_ATOMIC = 1
)(

    // Standard Inputs
    input logic clk,
    input logic reset,
    input logic redirect_taken,

    // Served Data from Fetch
    input logic [31:0] serve_data_reg [ISSUE_WIDTH-1:0],
    input logic serve_valid_reg [ISSUE_WIDTH-1:0],
    input logic [31:0] serve_pc_reg [ISSUE_WIDTH-1:0],
    input logic serve_c_reg [ISSUE_WIDTH-1:0],
    input logic serve_taken_reg [ISSUE_WIDTH-1:0],
    input logic serve_branch_reg [ISSUE_WIDTH-1:0],

    // Metadata from Fetch
    input logic incoming_serve_valid [ISSUE_WIDTH-1:0],

    // Output to Issue Stage
    output DecoderPacket_ packets_out [ISSUE_WIDTH-1:0],
    output LaneType_ lane_types_out [ISSUE_WIDTH-1:0],
    output logic packets_valid [ISSUE_WIDTH-1:0],

    // Consumption From Issue
    input logic [$clog2(ISSUE_WIDTH+1)-1:0] issue_consumed,

    // Acceptance Signals to Fetch
    output logic [$clog2(ISSUE_WIDTH+1)-1:0] serve_consumed

);

    // RegisterResets
    logic reset_reg;
    always_ff @(posedge clk) begin
        if (reset_reg) begin
            reset_reg <= 1'b0;
        end else begin
            reset_reg <= reset;
        end
    end

    // Generate Decoders and Produce Packets
    DecoderPacket_ packets [ISSUE_WIDTH-1:0];
    LaneType_ lane_types [ISSUE_WIDTH-1:0];
    for (genvar i = 0; i < ISSUE_WIDTH; i++) begin : decoders
        DecoderSlice #(
            .SUPPORT_MUL(SUPPORT_MUL),
            .SUPPORT_DIV(SUPPORT_DIV),
            .SUPPORT_FLOAT(SUPPORT_FLOAT),
            .SUPPORT_ATOMIC(SUPPORT_ATOMIC)
        ) decoder (
            .instruction(serve_data_reg[i]),
            .pc(serve_pc_reg[i]),
            .is_branch(serve_branch_reg[i]),
            .is_compressed(serve_c_reg[i]),
            .predicted_taken(serve_taken_reg[i]),
            .packet(packets[i]),
            .lane_type(lane_types[i])
        );
    end

    // Registered Input Metadata
    logic [$clog2(ISSUE_WIDTH+1)-1:0] invalid_inputs;
    logic [$clog2(ISSUE_WIDTH+1)-1:0] valid_inputs;
    logic [$clog2(ISSUE_WIDTH+1)-1:0] next_valid_inputs;
    always_comb begin
        next_valid_inputs = '0;
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++)
            next_valid_inputs += $clog2(ISSUE_WIDTH+1)'(incoming_serve_valid[i]);
    end
    always_ff @(posedge clk) begin
        if (reset_reg || redirect_taken) begin
            invalid_inputs <= ISSUE_WIDTH;
            valid_inputs <= 0;
        end else begin
            valid_inputs <= next_valid_inputs;
            invalid_inputs <= $clog2(ISSUE_WIDTH+1)'(ISSUE_WIDTH) - next_valid_inputs;
        end
    end

    // Registered Empty Slot Metadata
    logic [$clog2(ISSUE_WIDTH+1)-1:0] empty_slots;
    logic [$clog2(ISSUE_WIDTH+1)-1:0] next_empty_slots;
    always_comb begin
        next_empty_slots = (empty_slots + issue_consumed /* guarenteed 0-ISSUE_WIDTH clamp */);
        next_empty_slots = (next_empty_slots < valid_inputs) ? 0 :
            next_empty_slots - valid_inputs;
    end
    always_ff @(posedge clk) begin
        if (reset_reg || redirect_taken) begin
            empty_slots <= ISSUE_WIDTH;
        end else begin
            empty_slots <= next_empty_slots;
        end
    end

    // Pop and Pull Counts from Registered Metadata
    localparam int unsigned COUNT_W = $unsigned($clog2(ISSUE_WIDTH+1));
    logic [COUNT_W-1:0] available_slots;
    logic [COUNT_W-1:0] retained_count;
    always_comb begin
        available_slots = empty_slots + issue_consumed;
        retained_count = COUNT_W'(ISSUE_WIDTH) - available_slots;
        serve_consumed = (valid_inputs < available_slots) ? valid_inputs : available_slots;
        if (reset_reg || redirect_taken) serve_consumed = '0;
    end

    // Single-Lane Load or Ordered Multi-Lane Retain and Refill
    if (ISSUE_WIDTH == 1) begin : single_lane
        always_ff @(posedge clk) begin
            if (reset_reg || redirect_taken) packets_valid[0] <= 1'b0;
            else begin
                packets_valid[0] <= !next_empty_slots[0];
                if (serve_consumed[0]) begin
                    packets_out[0] <= packets[0];
                    lane_types_out[0] <= lane_types[0];
                end
            end
        end
    end else begin : multiple_lanes
        always_ff @(posedge clk) begin
            if (reset_reg || redirect_taken) begin
                for (int unsigned i = 0; i < ISSUE_WIDTH; i++) packets_valid[i] <= 1'b0;
            end else begin
                for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
                    packets_valid[i] <= i < (ISSUE_WIDTH - $unsigned(int'(next_empty_slots)));
                    if (i < $unsigned(int'(retained_count))) begin
                        packets_out[i] <= packets_out[i + $unsigned(int'(issue_consumed))];
                        lane_types_out[i] <= lane_types_out[i + $unsigned(int'(issue_consumed))];
                    end else if (i < (ISSUE_WIDTH - $unsigned(int'(next_empty_slots)))) begin
                        packets_out[i] <= packets[i - $unsigned(int'(retained_count))];
                        lane_types_out[i] <= lane_types[i - $unsigned(int'(retained_count))];
                    end
                end
            end
        end
    end

endmodule
