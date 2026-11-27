// Load/store unit: one in-order request queue onto the single data bus.
//
// Memory model: the bus never reports errors. Every memory trap
// (misaligned, out of range) is detected in the AGU; the bus only adds
// latency, which the queue tolerates (responses return in order).
//
//   loads   complete in their lane when the response returns.
//   stores  are posted: they complete in their lane at enqueue; their
//           response is popped silently.
//   faults  an AGU-faulting request is enqueued as a marker. At the send head,
//           once nothing older is outstanding, it completes its lane slot with
//           an error and locks the queue (nothing younger is sent). The trap
//           then flushes the queue: everything left is younger than the fault,
//           and every older request (posted stores included) was sent first.
//   other traps (ECALL, interrupt, MRET, FENCE.I, ...): nothing younger was
//           admitted and older loads hold the trap back (result_pending), so
//           the queue holds only retired stores. It keeps draining.
module LoadStoreUnit
    import DerivedParameters::*;
#(
    parameter int unsigned LANES = 1,
    parameter int unsigned STAGES = 1,
    // Idle-LSU direct send of RAM loads from the AGU (see below).
    parameter bit DIRECT_SEND = 1'b0
)(
    input logic clk, reset, advance,
    // Writeback-time trap from BackendTop.
    input logic trap,
    output logic cancel_checkin,
    input logic pending [LANES], store [LANES],
    // AGU-detected fault (misaligned, out of range): enqueued as a marker.
    input logic fault [LANES],
    // pending before the same-cycle redirect squash. Enqueue uses candidates
    // only; the redirect reaches the LSU solely through the squashed_q flop.
    input logic candidate [LANES],
    // DIRECT_SEND: a valid load sits in the AGU stage, from flops only
    // (pre-allocated before execute; no store-buffer hit, stall or squash).
    input logic early_load [LANES],
    // Entry write enable from flops only: writing the slot at the tail is
    // harmless when the request is not counted (store-buffer hit, squash).
    input logic present [LANES],
    input logic [AGE_WIDTH-1:0] age [LANES],
    input logic [31:0] address [LANES], data [LANES],
    input logic [3:0] mask [LANES],
    input logic [1:0] size [LANES], // MemorySize_
    // Completion to the owning lane: a load response, or a fault marker
    // (return_error set, garbage data).
    output logic returned [LANES],
    // A load response for this lane is arriving (returned without the trap
    // kill or fault markers; flops only): the lane's early word forward.
    output logic load_response [LANES],
    output logic return_error,
    output logic [31:0] return_data,
    output logic request_valid, request_write,
    output logic [31:0] request_address, request_data,
    output logic [3:0] request_mask,
    output logic [1:0] request_size,
    input logic request_ready, response_valid,
    input logic [31:0] response_data,
    output logic response_ready,
    // Registered: the queue may not take another full group. Stalls the backend.
    output logic full,
    // Registered: the queue holds entries (posted stores may not have reached
    // memory yet). FENCE/FENCE.I wait for it to clear.
    output logic busy
);
    // Posted stores free their lane slot at enqueue, so entries outlive the
    // slots; the extra room covers a store in flight plus the full threshold.
    localparam int DEPTH = LANES * (STAGES + 3);
    // Check-ins are cancelled for this many cycles after a trap edge.
    localparam int LOCK_CYCLES = 3;
    typedef logic [(DEPTH > 1 ? $clog2(DEPTH) : 1)-1:0] Pointer;
    typedef logic [$clog2(DEPTH+1)-1:0] Count;
    typedef logic [(LANES > 1 ? $clog2(LANES) : 1)-1:0] Owner;
    typedef struct packed {
        Owner owner;
        logic store;
        logic fault;
        logic [31:0] address, data;
        logic [3:0] mask;
        logic [1:0] size;
    } Request;

    Request queue [DEPTH];
    Pointer tail, send_head, return_head;
    // awaiting_response: real bus requests without a response (includes discard).
    // discard: responses still owed for requests dropped by a flush.
    Count unsent, awaiting_response, discard;
    // locked: a fault marker has completed; nothing more is sent until the
    // trap flushes the queue.
    logic locked;
    logic [1:0] lock_timer;
    logic held_trap;
    wire trap_edge = trap && !held_trap;
    wire kill = trap && locked;      // memory trap: drop everything
    wire flush = kill && !held_trap;
    assign cancel_checkin = trap || lock_timer != 0;
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
    // youngest requests of the group (issue age above the branch), and a
    // store-buffer hit is never pending either (a single lane: it is the
    // youngest). Candidates are enqueued and counted immediately; the number
    // not pending is registered in squashed_q and retracted from tail/unsent
    // one cycle later. Killed entries are always the youngest at the tail, so
    // excluding them from the sendable count (unsent - squashed_q) guarantees
    // none reaches the bus. Nothing is enqueued in a trap cycle or the
    // check-in lock after it.
    wire enqueue = advance && !trap && lock_timer == 0;
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
            if (enqueue && present[i])
                queue[offset_pointer(live_tail, rank[i])] <=
                    '{Owner'(i), store[i], fault[i], address[i], data[i], mask[i], size[i]};
        end
    end

    wire completed = response_valid && response_ready;
    wire head_ready = !reset && !kill && !locked && unsent != squashed_q;
    wire head_fault = queue[send_head].fault;
    // Direct-send settlement state (see the direct block below).
    logic direct_inflight, direct_kept;
    wire direct_keep = direct_inflight && direct_kept;    // settle this cycle
    wire direct_absorb = direct_inflight && !direct_kept; // swallow this response
    // A fault marker at the head completes once every older response is back
    // (then return_head == send_head) and locks.
    wire fault_return = head_ready && head_fault && !direct_keep && awaiting_response == 0;
    // A head that was just sent directly (direct_keep) is not resent.
    wire queue_valid = head_ready && !head_fault && !direct_keep && discard == 0;

    // Direct send (DIRECT_SEND, single lane): an idle LSU puts a RAM load on
    // the bus straight from the AGU in its execute cycle, so the BRAM input
    // register samples it one cycle earlier than the queue path would.
    //   decision: early_load (a valid load in the AGU stage) and an idle LSU:
    //         nothing sendable in the queue, no response owed after this cycle,
    //         no discard, not locked, no check-in lock. All flops, so
    //         request_valid is a flop function; execute only drives the address.
    //   No devices (early_load guarantees it from the base register and offset).
    //         Anything that would have cancelled the send is absorbed after it
    //         instead, so the read must be side-effect free:
    //           squash (older branch, same group)  discard; entry retracted
    //           store-buffer hit                   discard; never enqueued
    //           stall (load not advancing)          discard; enqueued later
    //           AGU fault                           discard; entry is a marker
    //           trap cycle                          discard; never enqueued
    //         Nothing older is outstanding, so the discard can only match
    //         this response.
    //   Stores and device loads keep the queue path.
    // A send that survives (load advances, enqueued, pending, no fault)
    // advances send_head as if sent from the queue.
    logic direct_valid;
    logic direct_select; // address/size select: flops only (idle && early_load)
    if (DIRECT_SEND && LANES == 1) begin : direct
        wire idle = !reset && lock_timer == 0 && unsent - Count'(direct_keep) == squashed_q && discard == 0 && !locked &&
            // With one owed, response_ready is already 1, so response_valid is
            // the completion (avoids a loop through response_ready -> sent).
            (awaiting_response == '0 || (awaiting_response == Count'(1) && response_valid));
        assign direct_select = idle && early_load[0];
        // early_load already excludes device addresses (from flops).
        assign direct_valid = direct_select;
    end else begin : no_direct
        assign direct_valid = 1'b0;
        assign direct_select = 1'b0;
    end

    assign request_valid = direct_valid || queue_valid;
    // When direct_select is set the queue is empty, so a not-in-RAM load just
    // leaves request_valid low; the select never waits for the range compare.
    assign request_address = direct_select ? address[0] : queue[send_head].address;
    // Direct sends are loads: data and mask are only used by writes, so they
    // always come from the queue head. Only address/size (and write) select.
    assign request_data = queue[send_head].data;
    assign request_write = !direct_valid && queue[send_head].store;
    assign request_mask = queue[send_head].mask;
    assign request_size = direct_select ? size[0] : queue[send_head].size;
    wire sent = request_valid && request_ready;
    wire sent_direct = sent && direct_valid;
    wire sent_queue = sent && !direct_valid;
    // A direct send is settled one cycle later (timing: the survival test,
    // which sees the store-buffer hit, squash and fault, only reaches flops).
    // Next cycle, when its response arrives:
    //   kept: it is the queue head; it advances send_head/unsent as if sent
    //        from the queue, and the queue may not send it again that cycle;
    //   dropped: its response is absorbed (nothing older was outstanding, so
    //        it is exactly that response); a pushed entry is retracted by
    //        squashed_q or stays as a fault marker; an unpushed one (stall) is
    //        sent again later.
    always_ff @(posedge clk) begin
        direct_inflight <= !reset && sent_direct;
        direct_kept <= sent_direct && enqueue && pending[0] && !fault[0];
    end
    // Responses are only ever due while something is outstanding (keeps the
    // AGU off this output).
    assign response_ready = !reset && awaiting_response != 0;

    wire real_return = completed && discard == 0 && !kill && !direct_absorb;
    // Posted stores pop silently; loads and fault markers complete their slot.
    for (genvar i = 0; i < LANES; i++)
        assign returned[i] = ((real_return && !queue[return_head].store) || fault_return) &&
            queue[return_head].owner == Owner'(i);
    for (genvar i = 0; i < LANES; i++)
        assign load_response[i] = completed && discard == 0 && !direct_absorb &&
            !queue[return_head].store && queue[return_head].owner == Owner'(i);
    assign return_error = fault_return;
    assign return_data = response_data;
    wire pop = real_return || fault_return;

    // Occupancy (enqueue to return-head pop) for the registered full flag:
    // set when the queue could not take another LANES pushes next cycle.
    Count used, used_next;
    assign used_next = used + pushes - squashed_q - Count'(pop);

    always_ff @(posedge clk) begin
        if (reset) begin
            tail <= '0;
            send_head <= '0;
            return_head <= '0;
            unsent <= '0;
            awaiting_response <= '0;
            discard <= '0;
            squashed_q <= '0;
            locked <= 1'b0;
            held_trap <= 1'b0;
            lock_timer <= '0;
            used <= '0;
            full <= 1'b0;
            busy <= 1'b0;
        end else begin
            awaiting_response <= awaiting_response + Count'(sent) - Count'(completed);
            held_trap <= trap && !advance;
            if (trap_edge) lock_timer <= 2'(LOCK_CYCLES);
            else if (lock_timer != 0) lock_timer <= lock_timer - 2'd1;
            if (flush) begin
                // Memory trap: drop every entry (all younger than the fault).
                // Responses still owed on the bus are absorbed and discarded.
                tail <= '0;
                send_head <= '0;
                return_head <= '0;
                unsent <= '0;
                squashed_q <= '0;
                locked <= 1'b0;
                discard <= awaiting_response - Count'(completed);
                used <= '0;
                full <= 1'b0;
                busy <= 1'b0;
            end else begin
                // A direct send needs discard == 0, so it never coincides with a
                // discard being drained.
                discard <= discard - Count'(completed && discard != 0);
                tail <= offset_pointer(live_tail, pushes);
                if (sent_queue || direct_keep || fault_return) send_head <= offset_pointer(send_head, 1);
                if (pop) return_head <= offset_pointer(return_head, 1);
                unsent <= sendable + pushes - Count'(sent_queue || direct_keep || fault_return);
                squashed_q <= squashed;
                if (fault_return) locked <= 1'b1;
                used <= used_next;
                full <= int'(used_next) > DEPTH - int'(LANES);
                busy <= used_next != '0;
            end
        end
    end
endmodule
