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
    // Registered writeback trap (the trap skid cycle), pulsing with
    // redirect_taken: full frontend flush (including the whole producer table)
    // to redirect_pc = mtvec, mepc (MRET) or the refetch PC.
    output logic redirect_trap,
    // CLINT mtime for the time/timeh CSRs.
    input logic [63:0] time_value,
    // CLINT levels for mip.MTIP/mip.MSIP; an INT_EXTERNAL pulse sets mip.MEIP.
    input logic timer_pending, software_pending,
    input logic interrupt,
    input Enumerations::InterruptType_ interrupt_type,
    // Pending and enabled interrupt for Decode to tag onto a valid instruction.
    output Enumerations::TrapType_ interrupt_request,
    output logic [31:0] redirect_pc,
    output logic result_trap [TOTAL_LANE_COUNT-1:0],
    // Writeback-time trap: some final-slot instruction traps and every older
    // final-slot instruction has its result. Not stall gated.
    output logic trap,

    // GShare training, one per BRU lane in lane order. Registered; valid fires
    // once per resolved conditional branch even while a stall holds it in the
    // resolution stage (same fire-once rule as the branch redirect). Tied low
    // when ENABLE_GSHARE = 0.
    output logic train_valid [BRU_LANE_COUNT-1:0],
    output logic train_taken [BRU_LANE_COUNT-1:0],
    output logic [AGE_WIDTH-1:0] train_age [BRU_LANE_COUNT-1:0],
    output logic [PHT_INDEX_W-1:0] train_pht [BRU_LANE_COUNT-1:0],
    // RAS repair: {enable, pop, snapshot} of the selected branch redirect,
    // from the same registers and selector as redirect_pc. 0 on a trap.
    output logic [RAS_RESTORE_W-1:0] redirect_ras,

    // One 32-bit bus. Every accepted load or store gets one response, in order,
    // after any latency. The bus never reports errors: memory traps are
    // detected in the AGU. request_address is the full byte address;
    // request_data/request_mask are lane-shifted within the aligned word.
    output logic request_valid, request_write,
    output logic [31:0] request_address, request_data,
    output logic [3:0] request_mask,
    output logic [1:0] request_size, // MemorySize_
    input logic request_ready,
    input logic response_valid,
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
    logic [RAS_RESTORE_W-1:0] redirect_ras_lane [N-1:0];
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
    // BRU lanes before a physical lane, for the compact training outputs.
    function automatic int brus_before(int lane);
        int count;
        count = 0;
        for (int k = 0; k < INTEGER_LANE_COUNT; k++)
            if (1+k < lane && EFFECTIVE_INTEGER_CAPS[k][1]) count++;
        return count;
    endfunction
    localparam int RF_LANES = ports_before(N);
    // Writers: every RF-reading integer/memory lane, then the serial lane.
    localparam int SERIAL_WRITER = RF_LANES;
    localparam int WRITERS = RF_LANES + 1;
    // Two read ports per RF lane, then the serial lane's rs1 port.
    localparam int SERIAL_READ = 2*RF_LANES;
    localparam int RETIRE_WIDTH = $clog2(WRITERS + 1);
    logic [4:0] read_addr [2*RF_LANES:0];
    logic [31:0] read_data [2*RF_LANES:0];
    logic [4:0] result_destination [WRITERS];
    logic [31:0] result_data [WRITERS];
    logic [AGE_WIDTH-1:0] result_age [WRITERS];
    logic result_ready [WRITERS], result_pending [WRITERS], writer_trap [WRITERS];
    logic result_valid [WRITERS];
    Enumerations::TrapType_ writer_trap_type [WRITERS];
    logic [31:0] writer_pc [WRITERS];
    logic serial_mret, serial_fence_i; // The serial writer's flush is an MRET/FENCE.I (it retires).
    logic write_request [WRITERS];
    // ISSUE_WIDTH physical write ports. A lockstep group holds at most
    // ISSUE_WIDTH instructions, so at most ISSUE_WIDTH writers request at once.
    logic [4:0] write_addr [ISSUE_WIDTH];
    logic [31:0] write_data [ISSUE_WIDTH];
    logic write_en [ISSUE_WIDTH];

    localparam int M = MEMORY_LANE_COUNT > 0 ? MEMORY_LANE_COUNT : 1;
    logic pending [M], candidate [M], early_load [M], present [M], returned [M], store [M], fault [M];
    logic load_response [M]; // early word forward strobe per memory lane
    logic lsu_full; // registered LSU queue-full flag (posted stores)
    logic lsu_busy; // registered: LSU still holds entries
    // FENCE/FENCE.I at writeback waits (stall, no trap) until every posted
    // store has left the LSU, so the refetch and later accesses see them.
    wire fence_drain = writer_trap[SERIAL_WRITER] && serial_fence_i && lsu_busy;
    logic return_error, cancel_checkin;
    logic [31:0] return_data;
    logic [AGE_WIDTH-1:0] age [M];
    logic [31:0] address [M], data [M];
    logic [3:0] mask [M];
    logic [1:0] size [M];

    IntegerFile #(.READ_PORTS(2*RF_LANES+1), .WRITE_PORTS(ISSUE_WIDTH)) integer_file (.*);

    // Writeback. Lockstep puts every retiring lane in one group and writeback
    // commits it on an advancing edge only (suppressed under stall).
    // - Trap kill: a writer younger than any trapping final-slot instruction
    //   never writes. Raw writer_trap is used, so a younger instruction is
    //   killed even while the trap itself waits on older pending work.
    // - WAW: the youngest surviving writer of an rd wins.
    // - Each issue position owns its correspondingly numbered RF port.
    // The trap bit asserts when a final-slot instruction traps and no older
    // final-slot instruction is pending (unfinished iterating or memory
    // result), so an older unfinished result is never treated as done. It is
    // not stall gated.
    logic killed [WRITERS];
    always_comb begin
        foreach (killed[i]) begin
            killed[i] = 1'b0;
            foreach (writer_trap[j])
                if (writer_trap[j] && result_age[j] < result_age[i]) killed[i] = 1'b1;
        end
        trap = 1'b0;
        foreach (write_request[i]) begin
            logic older_pending;
            older_pending = 1'b0;
            write_request[i] = result_ready[i] && !killed[i];
            foreach (result_ready[j]) begin
                if (j != i && result_ready[j] && !killed[j] &&
                    result_destination[j] == result_destination[i] && result_age[j] > result_age[i])
                    write_request[i] = 1'b0;
                if (j != i && result_pending[j] && result_age[j] < result_age[i])
                    older_pending = 1'b1;
            end
            trap |= writer_trap[i] && !older_pending && !(i == SERIAL_WRITER && fence_drain);
        end
        if (reset) trap = 1'b0;
    end

    // Retirement, for minstret. A final-slot instruction retires on the edge
    // its group leaves writeback ((!stall || trap), same as write_en) when it
    // is valid, does not trap itself and is not killed by an older trap.
    // Counts are formed without the edge so the serial lane's minstret read
    // does not depend on stall; the edge only qualifies the update.
    logic retire_edge;
    logic retiring [WRITERS];
    logic [RETIRE_WIDTH-1:0] retire_count;
    logic [RETIRE_WIDTH-1:0] retire_older; // older valid group members of the serial instruction
    // The same count formed at issue from the registered issue packets
    // (every non-serial lane is a writer), carried down the serial lane.
    logic [RETIRE_WIDTH-1:0] issue_older;
    always_comb begin
        issue_older = '0;
        for (int j = 1; j < N; j++)
            issue_older += RETIRE_WIDTH'(accept_vector[j] && issuer_packet[j].input_age < issuer_packet[0].input_age);
    end
    always_comb begin
        retire_edge = (!stall || trap) && !reset;
        retire_count = '0;
        retire_older = '0;
        foreach (retiring[i]) begin
            retiring[i] = result_valid[i] && !killed[i] &&
                (!writer_trap[i] || (i == SERIAL_WRITER && (serial_mret || serial_fence_i)));
            retire_count += RETIRE_WIDTH'(retiring[i]);
            // Only used by a serial instruction that itself retires, and then
            // every older valid group member retires too (an older trap would
            // have killed it). So validity alone suffices: no trap/kill logic
            // on the minstret read path.
            if (i != SERIAL_WRITER && result_age[i] < result_age[SERIAL_WRITER])
                retire_older += RETIRE_WIDTH'(result_valid[i]);
        end
    end
    // Ages are the original issue slots. Select the payload independently
    // of stall, trap and WAW arbitration; those only qualify the port enable.
    for (genvar k = 0; k < ISSUE_WIDTH; k++) begin : wb_port
        always_comb begin
            write_en[k] = 1'b0;
            write_addr[k] = '0;
            write_data[k] = '0;
            foreach (result_ready[i]) begin
                if (result_age[i] == AGE_WIDTH'(k) && result_ready[i]) begin
                    write_addr[k] |= result_destination[i];
                    write_data[k] |= result_data[i];
                    write_en[k] |= write_request[i];
                end
            end
            // On a trap edge the group retires even under stall: the flush
            // clears it, so older survivors must commit now.
            write_en[k] &= (!stall || trap) && !reset;
        end
    end
    if (!ENABLE_GSHARE) begin : no_training
        for (genvar b = 0; b < BRU_LANE_COUNT; b++) begin : tie
            assign train_valid[b] = 1'b0;
            assign train_taken[b] = 1'b0;
            assign train_age[b] = '0;
            assign train_pht[b] = '0;
        end
    end
    for (genvar i = 0; i < N; i++) begin : lanes
        localparam int PORT = ports_before(i);
        localparam bit ACTIVE = ports_before(i+1) != PORT;
        if (i == 0) begin : serial_lane
            // No forwarding in or out of the serial lane.
            for (genvar k = 0; k <= EXECUTION_UNROLL; k++) begin : no_forward
                assign forward_data[i][k] = 'x;
                assign forward_ready[i][k] = 1'b1;
            end
            assign bypass_data[i] = 'x;
            assign redirect[i] = 1'b0;
            assign redirect_ras_lane[i] = '0;
            assign redirect_age[i] = 'x;
            assign target[i] = 'x;
            assign writer_trap[SERIAL_WRITER] = result_trap[i];
            SerialLane #(
                .REGISTERED_INPUT(1)
            ) lane (
                .clk, .reset, .stall, .iteration_stall_out(iteration_stall[i]),
                .decoder_packet(decoder_packet[i]), .issuer_packet(issuer_packet[i]), .accept(accept_vector[i]), .recovery_flush(redirect_taken),
                .trap_flush(trap),
                .interrupt, .interrupt_type, .interrupt_request, .time_value, .timer_pending, .software_pending,
                .trap_entry(redirect_trap), .trap_entry_mret(entry_mret), .trap_entry_fence_i(entry_fence_i), .trap_entry_type(entry_type),
                .trap_entry_pc(entry_pc), .trap_target,
                .result_mret(serial_mret), .result_fence_i(serial_fence_i), .result_trap_type(writer_trap_type[SERIAL_WRITER]),
                .result_pc(writer_pc[SERIAL_WRITER]),
                .redirect_taken(redirect), .redirect_age,
                .reg_address_1(read_addr[SERIAL_READ]), .read_data_1(read_data[SERIAL_READ]),
                .retire_edge, .retire_self(retiring[SERIAL_WRITER]), .retire_count, .retire_older, .issue_older,
                .result_valid(result_valid[SERIAL_WRITER]),
                .result_data(result_data[SERIAL_WRITER]), .result_destination(result_destination[SERIAL_WRITER]),
                .result_age(result_age[SERIAL_WRITER]), .result_ready(result_ready[SERIAL_WRITER]),
                .result_pending(result_pending[SERIAL_WRITER]), .result_trap(result_trap[i])
            );
        end else if (ACTIVE && i < MEMORY_BASE) begin : integer_lane
            logic final_ready;
            logic raw_train_valid, raw_train_taken;
            logic [PHT_INDEX_W-1:0] raw_train_pht;
            for (genvar k = 0; k <= EXECUTION_UNROLL; k++)
                assign forward_ready[i][k] = k == EXECUTION_UNROLL ? final_ready : 1'b1;
            IntegerLane #(
                .IS_ALU(EFFECTIVE_INTEGER_CAPS[i-1][0]),
                .IS_BRU(EFFECTIVE_INTEGER_CAPS[i-1][1]),
                .IS_MUL(EFFECTIVE_INTEGER_CAPS[i-1][2]),
                .IS_DIV(EFFECTIVE_INTEGER_CAPS[i-1][3]),
                .LANE_ID(i),
                .REGISTERED_INPUT(1)
            ) lane (
                .clk, .reset, .stall, .iteration_stall_out(iteration_stall[i]),
                .decoder_packet(decoder_packet[i]), .issuer_packet(issuer_packet[i]), .accept(accept_vector[i]), .recovery_flush(redirect_taken), .trap_flush(trap),
                .forward_data, .forward_ready, .forward_data_out(forward_data[i]), .forward_ready_out(final_ready),
                .bypass_data, .bypass_data_out(bypass_data[i]),
                .redirect_taken(redirect), .redirect_age, .redirect_taken_out(redirect[i]),
                .redirect_age_out(redirect_age[i]), .redirect_pc_out(target[i]),
                .train_valid_out(raw_train_valid), .train_taken_out(raw_train_taken), .train_pht_out(raw_train_pht),
                .redirect_ras_out(redirect_ras_lane[i]),
                .result_ready(result_ready[PORT]), .result_pending(result_pending[PORT]), .result_valid(result_valid[PORT]),
                .result_trap(result_trap[i]), .result_trap_type(writer_trap_type[PORT]), .result_pc(writer_pc[PORT]),
                .result_age(result_age[PORT]),
                .result_destination(result_destination[PORT]), .result_data(result_data[PORT]),
                .reg_address_1(read_addr[2*PORT]), .reg_address_2(read_addr[2*PORT+1]),
                .read_data_1(read_data[2*PORT]), .read_data_2(read_data[2*PORT+1])
            );
            assign writer_trap[PORT] = result_trap[i];

            // GShare training register: fire-once, like redirect_q/redirect_fired.
            // A branch held in the resolution stage by stall keeps raw valid
            // high; fired suppresses re-capture until it advances. A trap edge
            // drops it. Everything here is a flop, so the frontend sees no
            // backend logic.
            if (ENABLE_GSHARE && EFFECTIVE_INTEGER_CAPS[i-1][1]) begin : train_register
                localparam int BRU = brus_before(i);
                logic fired;
                always_ff @(posedge clk) begin
                    train_valid[BRU] <= !reset && !trap && raw_train_valid && !fired;
                    fired <= !reset && !trap && stall && (fired || raw_train_valid);
                    train_taken[BRU] <= raw_train_taken;
                    train_age[BRU] <= redirect_age[i];
                    train_pht[BRU] <= raw_train_pht;
                end
            end
        end else if (ACTIVE) begin : memory_lane
            assign redirect_ras_lane[i] = '0; // no BRU
            MemoryLane #(
                .IS_MEMORY(EFFECTIVE_MEMORY_CAPS[i-MEMORY_BASE][0]),
                .IS_ATOMIC(0),
                .IS_FLOAT(EFFECTIVE_MEMORY_CAPS[i-MEMORY_BASE][2]),
                .LANE_ID(i),
                .REGISTERED_INPUT(1)
            ) lane (
                .clk, .reset, .stall, .iteration_stall_out(iteration_stall[i]),
                .decoder_packet(decoder_packet[i]), .issuer_packet(issuer_packet[i]), .accept(accept_vector[i]), .recovery_flush(redirect_taken),
                .forward_data, .forward_ready, .forward_data_out(forward_data[i]), .forward_ready_out(forward_ready[i]),
                .bypass_data, .bypass_data_out(bypass_data[i]),
                .redirect_taken(redirect), .redirect_age, .redirect_taken_out(redirect[i]),
                .redirect_age_out(redirect_age[i]), .redirect_pc_out(target[i]),
                .result_ready(result_ready[PORT]), .result_pending(result_pending[PORT]), .result_valid(result_valid[PORT]),
                .result_trap(result_trap[i]), .result_trap_type(writer_trap_type[PORT]), .result_pc(writer_pc[PORT]),
                .result_age(result_age[PORT]),
                .result_destination(result_destination[PORT]), .result_data(result_data[PORT]),
                .reg_address_1(read_addr[2*PORT]), .reg_address_2(read_addr[2*PORT+1]),
                .read_data_1(read_data[2*PORT]), .read_data_2(read_data[2*PORT+1]),
                .request_valid(pending[i-MEMORY_BASE]), .request_candidate(candidate[i-MEMORY_BASE]), .request_early(early_load[i-MEMORY_BASE]), .request_present(present[i-MEMORY_BASE]), .request_age(age[i-MEMORY_BASE]),
                .request_address(address[i-MEMORY_BASE]), .request_data(data[i-MEMORY_BASE]), .request_mask(mask[i-MEMORY_BASE]), .request_size(size[i-MEMORY_BASE]), .request_fault(fault[i-MEMORY_BASE]),
                .wb_trap(trap), .cancel_checkin,
                .request_write(store[i-MEMORY_BASE]),
                .response_valid(returned[i-MEMORY_BASE]), .response_error(return_error), .response_data(return_data),
                .response_early(load_response[i-MEMORY_BASE])
            );
            assign writer_trap[PORT] = result_trap[i];
        end else begin : inactive
            assign redirect_ras_lane[i] = '0;
            assign iteration_stall[i] = 0;
            if (i >= MEMORY_BASE && i < MEMORY_BASE + MEMORY_LANE_COUNT) begin : no_requests
                assign pending[i-MEMORY_BASE] = 0;
                assign candidate[i-MEMORY_BASE] = 0;
                assign early_load[i-MEMORY_BASE] = 0;
                assign present[i-MEMORY_BASE] = 0;
                assign fault[i-MEMORY_BASE] = 0;
            end
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
        stall |= lsu_full || fence_drain;
    end

    // Trap skid buffers: one per writer, at the end of each lane. They absorb
    // the writeback point every cycle with no enable, so the cycle after the
    // trap edge (redirect_trap) has flops to work from. take marks the one
    // writer whose trap fired: the oldest trapping writer (no older raw trap).
    logic skid_take [WRITERS];
    logic skid_mret, skid_fence_i;
    Enumerations::TrapType_ skid_type [WRITERS];
    logic [31:0] skid_pc [WRITERS];
    always_ff @(posedge clk) begin
        foreach (skid_take[i]) begin
            skid_take[i] <= trap && writer_trap[i] && !killed[i];
            skid_type[i] <= writer_trap_type[i];
            skid_pc[i] <= writer_pc[i];
        end
        skid_mret <= serial_mret;
        skid_fence_i <= serial_fence_i;
    end
    // One-hot select in the skid cycle.
    logic entry_mret, entry_fence_i;
    Enumerations::TrapType_ entry_type;
    logic [31:0] entry_pc, trap_target;
    always_comb begin
        entry_mret = skid_take[SERIAL_WRITER] && skid_mret;
        entry_fence_i = skid_take[SERIAL_WRITER] && skid_fence_i;
        entry_type = Enumerations::TrapType_'('0);
        entry_pc = '0;
        foreach (skid_take[i]) begin
            entry_type = Enumerations::TrapType_'(entry_type | ({$bits(entry_type){skid_take[i]}} & skid_type[i]));
            entry_pc |= {32{skid_take[i]}} & skid_pc[i];
        end
    end
    logic redirect_q [N-1:0];
    logic [AGE_WIDTH-1:0] redirect_age_q [N-1:0];
    logic [31:0] redirect_pc_q [N-1:0];
    logic [RAS_RESTORE_W-1:0] redirect_ras_q [N-1:0];
    logic any_capture;
    always_comb begin
        any_capture = 1'b0;
        foreach (redirect[i]) any_capture |= redirect[i] && !redirect_fired[i];
    end
    always_ff @(posedge clk) begin
        foreach (redirect_q[i]) begin
            // A trap edge drops every branch request; the trap recovery wins.
            redirect_q[i] <= !reset && !trap && redirect[i] && !redirect_fired[i];
            redirect_fired[i] <= !reset && !trap && stall && (redirect_fired[i] || redirect[i]);
            redirect_age_q[i] <= redirect_age[i];
            redirect_pc_q[i] <= target[i];
            redirect_ras_q[i] <= redirect_ras_lane[i];
        end
        if (any_capture) redirect_advanced <= !stall;
        redirect_trap <= !reset && trap;
    end

    always_comb begin
        redirect_taken = 1'b0;
        redirect_slot = '1;
        redirect_pc = 'x;
        redirect_ras = '0;
        foreach (redirect_q[i]) begin
            if (redirect_q[i] && redirect_age_q[i] <= redirect_slot) begin
                redirect_taken = 1'b1;
                redirect_pc = redirect_pc_q[i];
                redirect_ras = redirect_ras_q[i];
                redirect_slot = redirect_age_q[i];
            end
        end
        // The trap is the oldest event in flight; slot/advanced are unused.
        if (redirect_trap) begin
            redirect_taken = 1'b1;
            redirect_pc = trap_target;
            redirect_ras = '0; // traps do not restore the RAS
        end
    end
    assign redirect_fetch = redirect_taken;

    if (MEMORY_LANE_COUNT > 0) begin : memory_bus
        LoadStoreUnit lsu (
            .clk, .reset, .advance(!stall), .trap, .cancel_checkin, .pending, .candidate, .early_load, .present, .fault, .age, .address, .data, .mask, .size, .store,
            .returned, .load_response, .return_error, .return_data, .request_valid, .request_ready, .request_address, .request_data,
            .request_mask, .request_size, .request_write, .response_valid, .response_data, .response_ready,
            .full(lsu_full), .busy(lsu_busy)
        );
    end else begin : no_memory_bus
        assign request_valid = 0;
        assign response_ready = 0;
        assign lsu_full = 0;
        assign lsu_busy = 0;
        assign {request_address, request_data, request_mask, request_size, request_write} = '0;
    end
endmodule
