module ProducerTable
    import Parameters::*;
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
(

    // Standard Inputs
    input logic clk,
    input logic reset,
    input logic stall,
    input logic redirect_taken,
    input logic [AGE_WIDTH-1:0] redirect_slot,
    input logic redirect_advanced,
    // Trap recovery (pulses with redirect_taken): every producer is dead.
    input logic redirect_trap,

    // Register Source Read Inputs
    input logic [4:0] rs1 [ISSUE_WIDTH-1:0],
    input logic [4:0] rs2 [ISSUE_WIDTH-1:0],

    // Current producer indices; Decode applies capture-edge aging locally.
    output logic [UNROLLED_W-1:0] rs1_index [ISSUE_WIDTH-1:0],
    output logic [UNROLLED_W-1:0] rs2_index [ISSUE_WIDTH-1:0],
    output logic [LANE_WIDTH-1:0] rs1_lane [ISSUE_WIDTH-1:0],
    output logic [LANE_WIDTH-1:0] rs2_lane [ISSUE_WIDTH-1:0],
    output DecodeCapability_ rs1_capability [ISSUE_WIDTH-1:0],
    output DecodeCapability_ rs2_capability [ISSUE_WIDTH-1:0],

    // Eligibility after an advancing capture, before buffered-write correction.
    output logic rs1_capture_ready [ISSUE_WIDTH-1:0],
    output logic rs2_capture_ready [ISSUE_WIDTH-1:0],

    // Register Destination Writes
    input logic [4:0] op_rd [ISSUE_WIDTH-1:0],
    input logic [LANE_WIDTH-1:0] op_lane [ISSUE_WIDTH-1:0],
    input logic op_write [ISSUE_WIDTH-1:0],
    input logic [AGE_WIDTH-1:0] op_age [ISSUE_WIDTH-1:0],
    input DecodeCapability_ op_type [ISSUE_WIDTH-1:0]

);
    
    // Index zero belongs to the issuer write buffer. A CAM miss is in the RF.
    localparam unsigned STAGES = EXECUTION_UNROLL + 1;
    localparam logic [UNROLLED_W-1:0] RF_INDEX = UNROLLED_W'(STAGES + 1);

    typedef struct packed {
        logic [4:0] rd;
        logic [LANE_WIDTH-1:0] lane;
        DecodeCapability_ capability;
    } owner_t;

    typedef struct packed {
        logic [UNROLLED_W-1:0] index;
        logic [LANE_WIDTH-1:0] lane;
        DecodeCapability_ capability;
        logic ready;
    } result_t;

    owner_t owners [STAGES][ISSUE_WIDTH];
    logic valid [STAGES][ISSUE_WIDTH];
    logic ready [STAGES][ISSUE_WIDTH];
    logic surviving_valid [STAGES][ISSUE_WIDTH];

    for (genvar stage = 0; stage < STAGES; stage++) begin : age_group
        for (genvar slot = 0; slot < ISSUE_WIDTH; slot++) begin : writer
            // The resolving group sits in group 1 if the branch advanced on the
            // detection edge, otherwise still in group 0. Filter current owners
            // before either shifting them or holding them.
            localparam bit TRIM_ADVANCED = stage == 1;
            localparam bit TRIM_HELD = stage == 0;
            logic trim, younger;
            assign trim = redirect_advanced ? TRIM_ADVANCED : TRIM_HELD;
            assign younger = redirect_advanced ? stage < 1 : 1'b0;
            assign surviving_valid[stage][slot] = valid[stage][slot] &&
                (!redirect_taken || !(redirect_trap || younger || (trim && slot > redirect_slot)));
            owner_t incoming;
            logic incoming_valid;
            if (stage == 0) begin
                assign incoming = {op_rd[slot], op_lane[slot], op_type[slot]};
                assign incoming_valid = !redirect_taken && op_write[slot] && op_rd[slot] != 0;
            end else begin
                assign incoming = owners[stage-1][slot];
                assign incoming_valid = surviving_valid[stage-1][slot];
            end

            always_ff @(posedge clk) begin
                if (reset)
                    valid[stage][slot] <= 1'b0;
                else if (!stall)
                    valid[stage][slot] <= incoming_valid;
                else if (redirect_taken)
                    valid[stage][slot] <= surviving_valid[stage][slot];

                if (!stall) begin
                    owners[stage][slot] <= incoming;
                    ready[stage][slot] <= producer_capture_ready(
                        UNROLLED_W'(stage + 1), incoming.capability,
                        EXECUTION_UNROLL, DIVIDER_AUTO_PIPE);
                end
            end
        end
    end

    function automatic result_t lookup(input logic [4:0] source);
        result_t result, group_result;
        logic group_hit, hit;
        result = '0;
        result.index = RF_INDEX;
        result.ready = 1'b1;
        // Compare an entire issue group in parallel (two entries at dual issue).
        // Keep both WAW owners until redirect resolution. Younger surviving slots win.
        for (int stage = int'(STAGES)-1; stage >= 0; stage--) begin
            group_result = '0;
            group_result.index = UNROLLED_W'(stage + 1);
            group_hit = 1'b0;
            for (int slot = 0; slot < ISSUE_WIDTH; slot++) begin
                hit = valid[stage][slot] && owners[stage][slot].rd == source;
                group_hit |= hit;
                if (hit) begin
                    group_result.lane = owners[stage][slot].lane;
                    group_result.capability = owners[stage][slot].capability;
                    group_result.ready = ready[stage][slot];
                end
            end
            if (group_hit) result = group_result;
        end
        return result;
    endfunction

    for (genvar slot = 0; slot < ISSUE_WIDTH; slot++) begin : reads
        assign {rs1_index[slot], rs1_lane[slot], rs1_capability[slot], rs1_capture_ready[slot]} = lookup(rs1[slot]);
        assign {rs2_index[slot], rs2_lane[slot], rs2_capability[slot], rs2_capture_ready[slot]} = lookup(rs2[slot]);
    end
endmodule
