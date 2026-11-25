module LoadStoreUnit
    import DerivedParameters::*;
#(
    parameter int unsigned LANES = 1,
    parameter int unsigned STAGES = 1,
    // Precise bus faults: a store is not sent while any older response is
    // outstanding, so it can never escape an older bus error. Imprecise: the
    // store gate is always open (higher load-to-store throughput); a store may
    // reach the bus ahead of an older load's error.
    parameter bit PRECISE_BUS_FAULTS = 1'b1
)(
    input logic clk, reset, advance,
    // Writeback-time trap from BackendTop: flush and lock.
    input logic trap,
    output logic cancel_checkin,
    input logic pending [LANES], store [LANES],
    // pending before the same-cycle redirect squash. Enqueue uses candidates
    // only; the redirect reaches the LSU solely through the squashed_q flop.
    input logic candidate [LANES],
    input logic [AGE_WIDTH-1:0] age [LANES],
    input logic [31:0] address [LANES], data [LANES],
    input logic [3:0] mask [LANES],
    input logic [1:0] size [LANES], // MemorySize_: lets the bus detect misalignment.
    // Completion to the owning lane. Phantom completions carry no error and
    // garbage data.
    output logic returned [LANES],
    output logic return_error,
    output logic [31:0] return_data,
    output logic request_valid, request_write,
    output logic [31:0] request_address, request_data,
    output logic [3:0] request_mask,
    output logic [1:0] request_size,
    input logic request_ready, response_valid, response_error,
    input logic [31:0] response_data,
    output logic response_ready
);
    localparam int DEPTH = LANES * STAGES;
    // Writeback trap to first legitimate check-in is longer than this; any
    // request presented inside the window is a flush candidate.
    localparam int LOCK_CYCLES = 3;
    typedef logic [(DEPTH > 1 ? $clog2(DEPTH) : 1)-1:0] Pointer;
    typedef logic [$clog2(DEPTH+1)-1:0] Count;
    typedef logic [(LANES > 1 ? $clog2(LANES) : 1)-1:0] Owner;
    typedef struct packed {
        Owner owner;
        logic store;
        logic [31:0] address, data;
        logic [3:0] mask;
        logic [1:0] size;
    } Request;

    Request queue [DEPTH];
    Pointer tail, send_head, return_head;
    // awaiting_response: real bus requests without a response (includes discard).
    // phantom: entries passed without the bus, awaiting their local completion.
    // discard: real responses still owed for requests dropped by a flush.
    Count unsent, awaiting_response, phantom, discard;
    // Every trap is discovered by the bus (error response); none arrives with
    // a request. Lockdown: set when a bus error returns.
    // From then on every entry is passed without the bus and completed locally,
    // so lanes keep moving as if the bus were instant until the trap asserts.
    logic locked;
    logic [1:0] lock_timer;
    logic held_trap;
    wire flush = trap && !held_trap;
    wire blocked = trap || lock_timer != 0;
    assign cancel_checkin = blocked;
    function automatic Pointer offset_pointer(Pointer base, Count offset);
        int unsigned sum;
        sum = int'(base) + int'(offset);
        return Pointer'(sum >= DEPTH ? sum - DEPTH : sum);
    endfunction
    function automatic Pointer retreat_pointer(Pointer base, Count offset);
        int unsigned sum;
        sum = int'(base) + DEPTH - int'(offset);
        return Pointer'(sum >= DEPTH ? sum - DEPTH : sum);
    endfunction

    // Enqueue-then-retract. A redirect in the enqueuing cycle kills only the
    // youngest requests of the group (issue age above the branch). Candidates
    // are enqueued and counted immediately; the number killed is registered in
    // squashed_q and retracted from tail/unsent one cycle later. Killed entries
    // are always the youngest at the tail, so excluding them from the sendable
    // count (unsent - squashed_q) guarantees none reaches the bus. Nothing is
    // enqueued while blocked.
    wire enqueue = advance && !blocked;
    Count pushes, squashed, squashed_q;
    always_comb begin
        pushes = '0;
        squashed = '0;
        foreach (candidate[i]) begin
            pushes += Count'(enqueue && candidate[i]);
            squashed += Count'(enqueue && candidate[i] && !pending[i]);
        end
    end
    Pointer live_tail;
    Count sendable;
    assign live_tail = retreat_pointer(tail, squashed_q);
    assign sendable = unsent - squashed_q;

    Count rank [LANES];
    for (genvar i = 0; i < LANES; i++) begin : enqueue_order
        always_comb begin
            rank[i] = '0;
            foreach (candidate[j])
                rank[i] += Count'(candidate[j] && age[j] < age[i]);
        end
    end
    always_ff @(posedge clk) begin
        foreach (candidate[i]) begin
            if (enqueue && candidate[i])
                queue[offset_pointer(live_tail, rank[i])] <=
                    '{Owner'(i), store[i], address[i], data[i], mask[i], size[i]};
        end
    end

    // Real completions are always older than phantom ones: nothing is sent
    // for real after lockdown, and nothing is passed before it.
    wire completed = response_valid && response_ready;
    // An older response can cancel the head before send. A zero-latency
    // response to this head can only lock subsequent requests.
    wire outstanding = awaiting_response != 0;
    wire older_error = outstanding && response_valid && response_error && discard == 0;
    wire head_ready = !reset && !blocked && unsent != squashed_q;
    wire bypass_bus = locked || older_error;
    wire pass = head_ready && bypass_bus;
    // Precise: non-posted stores cannot escape an older fault. Loads may overlap.
    assign request_valid = head_ready && !bypass_bus && discard == 0 &&
        (!PRECISE_BUS_FAULTS || !queue[send_head].store || !outstanding);
    assign request_address = queue[send_head].address;
    assign request_data = queue[send_head].data;
    assign request_write = queue[send_head].store;
    assign request_mask = queue[send_head].mask;
    assign request_size = queue[send_head].size;
    wire sent = request_valid && request_ready;
    assign response_ready = !reset && (awaiting_response != 0 || sent);

    wire real_return = completed && discard == 0 && !blocked;
    wire phantom_return = !reset && !blocked && awaiting_response == 0 && phantom != 0;
    for (genvar i = 0; i < LANES; i++)
        assign returned[i] = (real_return || phantom_return) && queue[return_head].owner == Owner'(i);
    assign return_error = real_return && response_error;
    assign return_data = response_data;

    always_ff @(posedge clk) begin
        if (reset) begin
            tail <= '0;
            send_head <= '0;
            return_head <= '0;
            unsent <= '0;
            awaiting_response <= '0;
            phantom <= '0;
            discard <= '0;
            squashed_q <= '0;
            locked <= 1'b0;
            held_trap <= 1'b0;
            lock_timer <= '0;
        end else begin
            awaiting_response <= awaiting_response + Count'(sent) - Count'(completed);
            held_trap <= trap && !advance;
            if (flush) begin
                // Flush: drop every entry. Responses still owed on the bus are
                // absorbed and discarded. Hold off check-ins for LOCK_CYCLES.
                tail <= '0;
                send_head <= '0;
                return_head <= '0;
                unsent <= '0;
                phantom <= '0;
                squashed_q <= '0;
                locked <= 1'b0;
                lock_timer <= 2'(LOCK_CYCLES);
                discard <= awaiting_response - Count'(completed);
            end else begin
                if (lock_timer != 0) lock_timer <= lock_timer - 2'd1;
                if (completed && discard != 0) discard <= discard - Count'(1);
                tail <= offset_pointer(live_tail, pushes);
                if (sent || pass) send_head <= offset_pointer(send_head, 1);
                if (real_return || phantom_return) return_head <= offset_pointer(return_head, 1);
                unsent <= sendable + pushes - Count'(sent || pass);
                phantom <= phantom + Count'(pass) - Count'(phantom_return);
                squashed_q <= squashed;
                if (return_error) locked <= 1'b1;
            end
        end
    end
endmodule
