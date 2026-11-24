module BackendTop
    import Parameters::*;
    import DerivedParameters::*;
    import Definitions::*;
(
    input logic clk, reset, external_stall,
    input DecoderPacket_ decoder_packet [TOTAL_LANE_COUNT-1:0],
    input IssuerPacket_ issuer_packet [TOTAL_LANE_COUNT-1:0],
    input logic accept_vector [TOTAL_LANE_COUNT-1:0],
    // Registered by FrontendTop: producer slots the operand-stage packets wait on.
    input logic watch [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0],
    output logic stall,
    output logic redirect_fetch, redirect_taken,
    output logic [AGE_WIDTH-1:0] redirect_slot,
    output logic redirect_advanced, // Branch advanced between detection and recovery.
    output logic [31:0] redirect_pc,
    output logic result_trap [TOTAL_LANE_COUNT-1:0],

    // One aligned 32-bit bus. Every accepted load or store gets one response.
    output logic request_valid, request_write,
    output logic [31:0] request_address, request_data,
    output logic [3:0] request_mask,
    input logic request_ready,
    input logic response_valid, response_error,
    input logic [31:0] response_data,
    output logic response_ready
);
    localparam int N = TOTAL_LANE_COUNT;
    localparam int MEMORY_BASE = 1 + INTEGER_LANE_COUNT;
    logic [31:0] forward_data [N-1:0][EXECUTION_UNROLL:0];
    logic forward_ready [N-1:0][EXECUTION_UNROLL:0];
    logic [31:0] bypass_data [N-1:0], target [N-1:0];
    logic iteration_stall [N-1:0], redirect [N-1:0];
    logic [AGE_WIDTH-1:0] redirect_age [N-1:0];
    logic redirect_fired [N-1:0];
    // Compact RF ports while keeping forwarding and issue tags in physical lane order.
    function automatic int ports_before(int lane);
        int count;
        count = 0;
        for (int k = 0; k < INTEGER_LANE_COUNT; k++)
            if (1+k < lane && |EFFECTIVE_INTEGER_CAPS[k]) count++;
        for (int k = 0; k < MEMORY_LANE_COUNT; k++)
            if (MEMORY_BASE+k < lane && EFFECTIVE_MEMORY_CAPS[k][0]) count++;
        return count;
    endfunction
    localparam int RF_LANES = ports_before(N);
    logic [4:0] read_addr [2*RF_LANES-1:0], write_addr [RF_LANES-1:0];
    logic [31:0] read_data [2*RF_LANES-1:0], write_data [RF_LANES-1:0];
    logic [AGE_WIDTH-1:0] result_age [RF_LANES-1:0];
    logic result_ready [RF_LANES-1:0], write_en [RF_LANES-1:0];
    logic [4:0] next_write_addr [RF_LANES-1:0];
    logic [AGE_WIDTH-1:0] next_result_age [RF_LANES-1:0];

    localparam int M = MEMORY_LANE_COUNT > 0 ? MEMORY_LANE_COUNT : 1;
    logic pending [M], candidate [M], returned [M], store [M];
    logic [AGE_WIDTH-1:0] age [M];
    logic [31:0] address [M], data [M];
    logic [3:0] mask [M];

    IntegerFile #(.READ_PORTS(2*RF_LANES), .WRITE_PORTS(RF_LANES)) integer_file (.*);
    // Lockstep puts all retiring lanes in one group. Youngest writer wins WAW.
    // conflict[i][j]: port j holds a younger instruction with the same rd. It is
    // registered as the group enters the final slots and held under stall, since
    // rd and age never change there. It deliberately ignores validity, rd_valid,
    // traps and the redirect kill (stage_2_flush): those all live in
    // result_ready[j], so a flushed, trapped or not-yet-ready younger writer
    // never suppresses an older one. The write enable is then flops only.
    logic conflict [RF_LANES-1:0][RF_LANES-1:0];
    always_ff @(posedge clk) begin
        if (!stall) begin
            foreach (conflict[i, j])
                conflict[i][j] <= i != j && next_write_addr[j] == next_write_addr[i] &&
                    next_result_age[j] > next_result_age[i];
        end
    end
    for (genvar i = 0; i < RF_LANES; i++) begin : check_in
        always_comb begin
            write_en[i] = result_ready[i] && !reset;
            foreach (result_ready[j])
                if (conflict[i][j] && result_ready[j])
                    write_en[i] = 1'b0;
        end
    end
    for (genvar i = 0; i < N; i++) begin : lanes
        localparam int PORT = ports_before(i);
        localparam bit ACTIVE = ports_before(i+1) != PORT;
        if (ACTIVE && i < MEMORY_BASE) begin : integer_lane
            logic final_ready;
            for (genvar k = 0; k <= EXECUTION_UNROLL; k++)
                assign forward_ready[i][k] = k == EXECUTION_UNROLL ? final_ready : 1'b1;
            IntegerLane #(
                .IS_ALU(EFFECTIVE_INTEGER_CAPS[i-1][0]), .IS_BRU(EFFECTIVE_INTEGER_CAPS[i-1][1]),
                .IS_MUL(EFFECTIVE_INTEGER_CAPS[i-1][2]), .IS_DIV(EFFECTIVE_INTEGER_CAPS[i-1][3]),
                .EXECUTION_UNROLL(EXECUTION_UNROLL), .DIVIDER_AUTO_PIPE(DIVIDER_AUTO_PIPE),
                .ISSUE_WIDTH(ISSUE_WIDTH), .BYPASS_ENABLED(BYPASS_ENABLED), .LANE_ID(i), .REGISTERED_INPUT(1)
            ) lane (
                .clk, .reset, .stall, .iteration_stall_out(iteration_stall[i]),
                .decoder_packet(decoder_packet[i]), .issuer_packet(issuer_packet[i]), .accept(accept_vector[i]), .recovery_flush(redirect_taken),
                .forward_data, .forward_ready, .forward_data_out(forward_data[i]), .forward_ready_out(final_ready),
                .bypass_data, .bypass_data_out(bypass_data[i]),
                .redirect_taken(redirect), .redirect_age, .redirect_taken_out(redirect[i]),
                .redirect_age_out(redirect_age[i]), .redirect_pc_out(target[i]),
                .result_ready(result_ready[PORT]), .result_trap(result_trap[i]), .result_age(result_age[PORT]),
                .result_destination(write_addr[PORT]), .result_data(write_data[PORT]),
                .next_result_destination(next_write_addr[PORT]), .next_result_age(next_result_age[PORT]),
                .reg_address_1(read_addr[2*PORT]), .reg_address_2(read_addr[2*PORT+1]),
                .read_data_1(read_data[2*PORT]), .read_data_2(read_data[2*PORT+1])
            );
        end else if (ACTIVE) begin : memory_lane
            MemoryLane #(
                .IS_MEMORY(EFFECTIVE_MEMORY_CAPS[i-MEMORY_BASE][0]), .IS_ATOMIC(0), .IS_FLOAT(EFFECTIVE_MEMORY_CAPS[i-MEMORY_BASE][2]),
                .EXECUTION_UNROLL(EXECUTION_UNROLL), .ISSUE_WIDTH(ISSUE_WIDTH),
                .BYPASS_ENABLED(BYPASS_ENABLED), .LANE_ID(i), .REGISTERED_INPUT(1)
            ) lane (
                .clk, .reset, .stall, .iteration_stall_out(iteration_stall[i]),
                .decoder_packet(decoder_packet[i]), .issuer_packet(issuer_packet[i]), .accept(accept_vector[i]), .recovery_flush(redirect_taken),
                .forward_data, .forward_ready, .forward_data_out(forward_data[i]), .forward_ready_out(forward_ready[i]),
                .bypass_data, .bypass_data_out(bypass_data[i]),
                .redirect_taken(redirect), .redirect_age, .redirect_taken_out(redirect[i]),
                .redirect_age_out(redirect_age[i]), .redirect_pc_out(target[i]),
                .result_ready(result_ready[PORT]), .result_trap(result_trap[i]), .result_age(result_age[PORT]),
                .result_destination(write_addr[PORT]), .result_data(write_data[PORT]),
                .next_result_destination(next_write_addr[PORT]), .next_result_age(next_result_age[PORT]),
                .reg_address_1(read_addr[2*PORT]), .reg_address_2(read_addr[2*PORT+1]),
                .read_data_1(read_data[2*PORT]), .read_data_2(read_data[2*PORT+1]),
                .request_valid(pending[i-MEMORY_BASE]), .request_candidate(candidate[i-MEMORY_BASE]), .request_age(age[i-MEMORY_BASE]),
                .request_address(address[i-MEMORY_BASE]), .request_data(data[i-MEMORY_BASE]), .request_mask(mask[i-MEMORY_BASE]),
                .request_write(store[i-MEMORY_BASE]), .response_valid(returned[i-MEMORY_BASE]),
                .response_error, .response_data
            );
        end else begin : inactive
            assign iteration_stall[i] = 0;
            if (i >= MEMORY_BASE && i < MEMORY_BASE + MEMORY_LANE_COUNT)
                assign pending[i-MEMORY_BASE] = 0;
                assign candidate[i-MEMORY_BASE] = 0;
            assign result_trap[i] = 0;
            assign redirect[i] = 0;
            for (genvar k = 0; k <= EXECUTION_UNROLL; k++) begin : no_forward
                assign forward_data[i][k] = 'x;
                assign forward_ready[i][k] = 1'b1;
            end
            assign bypass_data[i] = 'x;
        end
    end

    // Resolution cycle: lanes squash younger work combinationally from the raw
    // lane redirects. Raw per-lane requests, ages and PCs are registered on the
    // first edge they appear, held or advancing. A branch held by stall keeps
    // asserting its raw request; redirect_fired suppresses re-capture until it
    // advances. The same stall blocks frontend capture, so lanes need no mask.
    // Recovery cycle: a small selector over the registered requests drives the
    // frontend. redirect_fetch and redirect_taken pulse together from flops.
    always_comb begin
        stall = external_stall;
        // Operand waits: a watched dynamic slot that is not ready. Every input
        // is a flop (frontend watch, lane ready). Static slots generate nothing.
        for (int lane = 1; lane < N; lane++)
            for (int index = 1; index <= EXECUTION_UNROLL; index++)
                if (forward_slot_dynamic(lane, index))
                    stall |= watch[lane][index] && !forward_ready[lane][index];
        // Structural holds: registered busy/pending flops.
        foreach (iteration_stall[i]) stall |= iteration_stall[i];
    end

    logic redirect_q [N-1:0];
    logic [AGE_WIDTH-1:0] redirect_age_q [N-1:0];
    logic [31:0] redirect_pc_q [N-1:0];
    logic any_capture;
    always_comb begin
        any_capture = 1'b0;
        foreach (redirect[i]) any_capture |= redirect[i] && !redirect_fired[i];
    end
    always_ff @(posedge clk) begin
        foreach (redirect_q[i]) begin
            redirect_q[i] <= !reset && redirect[i] && !redirect_fired[i];
            redirect_fired[i] <= !reset && stall && (redirect_fired[i] || redirect[i]);
            redirect_age_q[i] <= redirect_age[i];
            redirect_pc_q[i] <= target[i];
        end
        if (any_capture) redirect_advanced <= !stall;
    end

    always_comb begin
        redirect_taken = 1'b0;
        redirect_slot = '1;
        redirect_pc = 'x;
        foreach (redirect_q[i]) begin
            if (redirect_q[i] && redirect_age_q[i] <= redirect_slot) begin
                redirect_taken = 1'b1;
                redirect_pc = redirect_pc_q[i];
                redirect_slot = redirect_age_q[i];
            end
        end
    end
    assign redirect_fetch = redirect_taken;

    if (MEMORY_LANE_COUNT > 0) begin : memory_bus
        LoadStoreUnit #(.LANES(MEMORY_LANE_COUNT), .STAGES(EXECUTION_UNROLL)) lsu (
            .clk, .reset, .advance(!stall), .pending, .candidate, .age, .address, .data, .mask, .store,
            .returned, .request_valid, .request_ready, .request_address, .request_data,
            .request_mask, .request_write, .response_valid, .response_ready
        );
    end else begin : no_memory_bus
        assign request_valid = 0;
        assign response_ready = 0;
        assign {request_address, request_data, request_mask, request_write} = '0;
    end
endmodule
