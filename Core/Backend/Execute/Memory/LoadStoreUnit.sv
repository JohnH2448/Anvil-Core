module LoadStoreUnit
    import DerivedParameters::*;
#(
    parameter int unsigned LANES = 1,
    parameter int unsigned STAGES = 1
)(
    input logic clk, reset, advance,
    input logic pending [LANES], store [LANES],
    // pending before the same-cycle redirect squash. Enqueue uses candidates
    // only; the redirect reaches the LSU solely through the squashed_q flop.
    input logic candidate [LANES],
    input logic [AGE_WIDTH-1:0] age [LANES],
    input logic [31:0] address [LANES], data [LANES],
    input logic [3:0] mask [LANES],
    output logic returned [LANES],
    output logic request_valid, request_write,
    output logic [31:0] request_address, request_data,
    output logic [3:0] request_mask,
    input logic request_ready, response_valid,
    output logic response_ready
);
    localparam int DEPTH = LANES * STAGES;
    typedef logic [(DEPTH > 1 ? $clog2(DEPTH) : 1)-1:0] Pointer;
    typedef logic [$clog2(DEPTH+1)-1:0] Count;
    typedef logic [(LANES > 1 ? $clog2(LANES) : 1)-1:0] Owner;
    typedef struct packed {
        Owner owner;
        logic store;
        logic [31:0] address, data;
        logic [3:0] mask;
    } Request;

    Request queue [DEPTH];
    Pointer tail, send_head, return_head;
    Count unsent, awaiting_response;
    // Offset never exceeds DEPTH, including a full batch wrapping to the same pointer.
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
    // count (unsent - squashed_q) guarantees none reaches the bus.
    Count pushes, squashed, squashed_q;
    always_comb begin
        pushes = '0;
        squashed = '0;
        foreach (candidate[i]) begin
            pushes += Count'(advance && candidate[i]);
            squashed += Count'(advance && candidate[i] && !pending[i]);
        end
    end
    Pointer live_tail;
    Count sendable;
    assign live_tail = retreat_pointer(tail, squashed_q);
    assign sendable = unsent - squashed_q;

    // Each enqueued request owns a physical lane slot until its response.
    // An incomplete final slot prevents advance, so a new batch always fits;
    // last cycle's squashed slots are free again from live_tail onward.
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
            if (advance && candidate[i])
                queue[offset_pointer(live_tail, rank[i])] <=
                    '{Owner'(i), store[i], address[i], data[i], mask[i]};
        end
    end

    assign request_valid = !reset && sendable != 0;
    assign request_address = queue[send_head].address;
    assign request_data = queue[send_head].data;
    assign request_write = queue[send_head].store;
    assign request_mask = queue[send_head].mask;
    wire sent = request_valid && request_ready;
    assign response_ready = !reset && (awaiting_response != 0 || sent);
    wire completed = response_valid && response_ready;
    for (genvar i = 0; i < LANES; i++)
        assign returned[i] = completed && queue[return_head].owner == Owner'(i);

    always_ff @(posedge clk) begin
        if (reset) begin
            tail <= '0;
            send_head <= '0;
            return_head <= '0;
            unsent <= '0;
            awaiting_response <= '0;
            squashed_q <= '0;
        end else begin
            tail <= offset_pointer(live_tail, pushes);
            if (sent) send_head <= offset_pointer(send_head, 1);
            if (completed) return_head <= offset_pointer(return_head, 1);
            unsent <= sendable + pushes - Count'(sent);
            squashed_q <= squashed;
            awaiting_response <= awaiting_response + Count'(sent) - Count'(completed);
        end
    end
endmodule
