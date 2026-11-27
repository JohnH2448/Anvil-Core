// Return address stack (instantiated by FetchTop when USE_RAS = 1).
//
// Read (prediction stage, combinational): per fetch slot, flags whether the
// slot is a JALR-class instruction and whether it is a return, and offers the
// registered top of stack. FetchTop overrides the direction predictor for
// JALR-class slots: a return predicts taken to the top when the stack is not
// empty; every other JALR predicts not taken (target unknown, the BRU
// redirects).
//
// Update (Queue commit): at the edge a prediction window commits to the FIFO,
// the first RAS event among its kept slots is applied. Kept slots stop at the
// first taken prediction, so a call (JAL/JALR with rd = x1/x5, C.JAL, C.JALR)
// or a predicted return ends the window unless it is an unpredicted JALR.
//   call                  push PC + length
//   predicted return      pop
//   unpredicted JALR      freeze (after its push, if it is a call)
// Freeze holds the stack until the next redirect. An unpredicted JALR always
// redirects in the BRU (predicted not taken, actually taken), so everything
// fetched behind it is wrong path and must not touch the stack.
//
// No repair on conditional mispredicts: wrong-path calls/returns behind a
// mispredicted branch can corrupt the stack. That costs only predictions,
// since the BRU checks every predicted return.
module RAS
    import DerivedParameters::*;
#(
    parameter unsigned FETCH_SLOTS = 4,
    parameter unsigned RAS_DEPTH = Parameters::RAS_DEPTH,
    // With the BTB, a correctly steered call keeps its target window behind it,
    // so that window is predicted before the call commits its push. Forward
    // the pending push from the prediction register to the read.
    parameter bit FORWARD_PUSH = 1'b0
)(
    input logic clk,
    input logic reset,
    input logic redirect_taken,

    // Prediction-stage slots (bp_branch doubles as slot valid).
    input Definitions::BranchInput_ branch_input [FETCH_SLOTS-1:0],
    output logic slot_jalr [FETCH_SLOTS-1:0],
    output logic slot_return [FETCH_SLOTS-1:0],
    output logic top_valid,
    output fetch_pc_t top, // registered top, or the forwarded pending push

    // Commit of the prediction register into the FIFO.
    input logic commit,
    input Definitions::BranchInput_ commit_payload [FETCH_SLOTS-1:0],
    input logic commit_keep [FETCH_SLOTS-1:0],
    input logic commit_taken [FETCH_SLOTS-1:0],

    // FORWARD_PUSH: the staging window as it transfers into the prediction
    // register (its kept slots), and whether that register holds a window.
    input logic stage_transfer,
    input logic stage_keep [FETCH_SLOTS-1:0],
    input logic prediction_valid,

    // Repair (RAS_REPAIR_ON). snapshot = {pointer, count} before the committing
    // window's update; Queue stores it with the window's instructions. restore
    // arrives with the registered branch redirect ({enable, pop, snapshot}) and
    // is applied on redirect_taken, with the rest of the frontend flush.
    output logic [RAS_SNAP_W-1:0] snapshot,
    input logic [RAS_RESTORE_W-1:0] restore
);
    if (RAS_DEPTH < 2 || (RAS_DEPTH & (RAS_DEPTH - 1)) != 0) begin : bad_ras_depth
        $fatal(1, "RAS: RAS_DEPTH (%0d) must be a power of two >= 2", RAS_DEPTH);
    end
    localparam int unsigned PTR_W = $clog2(RAS_DEPTH);

    // ---------------------------------------------------------------- decode
    function automatic logic is_link(input logic [4:0] r);
        return r == 5'd1 || r == 5'd5;
    endfunction

    typedef struct packed {
        logic call, ret, jalr;
    } Kind_;

    function automatic Kind_ classify(input logic [31:0] ins, input logic compressed);
        Kind_ k;
        logic [15:0] c;
        logic jal32, jalr32, cj_r;
        c = ins[15:0];
        jal32 = !compressed && ins[6:0] == 7'b1101111;
        jalr32 = !compressed && ins[6:0] == 7'b1100111;
        // C.JR (c[12]=0) and C.JALR (c[12]=1): rs2 = 0, rs1 != 0.
        cj_r = compressed && c[1:0] == 2'b10 && c[15:13] == 3'b100 && c[6:2] == 5'd0 && c[11:7] != 5'd0;
        k.jalr = jalr32 || cj_r;
        k.call = ((jal32 || jalr32) && is_link(ins[11:7])) ||
            (compressed && c[1:0] == 2'b01 && c[15:13] == 3'b001) || // C.JAL (RV32, links x1)
            (cj_r && c[12]);                                         // C.JALR (links x1)
        k.ret = (jalr32 && ins[11:7] == 5'd0 && is_link(ins[19:15])) ||
            (cj_r && !c[12] && is_link(c[11:7]));
        return k;
    endfunction

    for (genvar i = 0; i < FETCH_SLOTS; i++) begin : read_slots
        Kind_ kind;
        assign kind = classify(branch_input[i].bp_instruction, branch_input[i].bp_compressed);
        assign slot_jalr[i] = kind.jalr;
        assign slot_return[i] = kind.ret;
    end

    // ---------------------------------------------------------------- state
    fetch_pc_t stack [RAS_DEPTH];
    logic [PTR_W-1:0] pointer; // next free entry; top is pointer - 1
    logic [PTR_W:0] count;     // saturates at RAS_DEPTH (overflow overwrites the oldest)
    logic frozen;
    // The top is kept in its own register, so the prediction read is a flop.
    fetch_pc_t top_reg;
    logic pending_push; // the window in the prediction register will push

    // First RAS event in the committing window.
    logic push, pop, freeze;
    fetch_pc_t push_value;
    always_comb begin
        logic done;
        Kind_ k;
        push = 1'b0;
        pop = 1'b0;
        freeze = 1'b0;
        push_value = 'x;
        done = 1'b0;
        for (int unsigned i = 0; i < FETCH_SLOTS; i++) begin
            k = classify(commit_payload[i].bp_instruction, commit_payload[i].bp_compressed);
            if (!done && commit_keep[i] && commit_payload[i].bp_branch && (k.call || k.ret || k.jalr)) begin
                done = 1'b1;
                if (k.call) begin
                    push = 1'b1;
                    push_value = fetch_pc_t'(32'(commit_payload[i].bp_pc) +
                        (commit_payload[i].bp_compressed ? 32'd2 : 32'd4));
                end
                // A return that committed taken was predicted from the top.
                if (k.ret && commit_taken[i]) pop = 1'b1;
                else if (k.jalr) freeze = 1'b1;
            end
        end
        // (pending push is registered at transfer; see below)
        if (!commit || frozen) begin
            push = 1'b0;
            pop = 1'b0;
            freeze = 1'b0;
        end
    end
    // Pending push (FORWARD_PUSH), registered when the window enters the
    // prediction register (timing: the read sees two flops and a mux, not the
    // commit-payload decode and PC + length adder). Same first-event rule as
    // the commit update, applied to the staging window and its kept slots.
    logic staged_call;
    fetch_pc_t staged_value;
    always_comb begin
        logic done;
        Kind_ k;
        staged_call = 1'b0;
        staged_value = 'x;
        done = 1'b0;
        for (int unsigned i = 0; i < FETCH_SLOTS; i++) begin
            k = classify(branch_input[i].bp_instruction, branch_input[i].bp_compressed);
            if (!done && stage_keep[i] && branch_input[i].bp_branch && (k.call || k.ret || k.jalr)) begin
                done = 1'b1;
                staged_call = k.call;
                staged_value = fetch_pc_t'(32'(branch_input[i].bp_pc) +
                    (branch_input[i].bp_compressed ? 32'd2 : 32'd4));
            end
        end
    end
    logic pending_q;
    fetch_pc_t pending_value;
    always_ff @(posedge clk) begin
        if (stage_transfer) begin
            pending_q <= staged_call;
            pending_value <= staged_value;
        end
    end
    assign pending_push = pending_q && prediction_valid && !frozen;
    assign top_valid = count != '0 || (FORWARD_PUSH && pending_push);
    assign top = (FORWARD_PUSH && pending_push) ? pending_value : top_reg;

    // Repair. The restore is a pointer/count load from registered redirect
    // state. top_reg is reloaded from the stack one cycle later (reload), so
    // the stack-index mux is not behind the redirect selector; nothing can read
    // the top in that cycle because the flush just emptied staging/prediction.
    // Entries survive pops, so only wrong-path pushes can leave stale values.
    logic restore_now, restore_pop, reload;
    logic [PTR_W-1:0] restore_pointer;
    logic [PTR_W:0] restore_count;
    if (RAS_REPAIR_ON) begin : repair
        assign snapshot = {pointer, count};
        assign restore_now = redirect_taken && restore[RAS_RESTORE_W-1];
        assign restore_pop = restore[RAS_RESTORE_W-2];
        assign {restore_pointer, restore_count} = restore[RAS_SNAP_W-1:0];
        always_ff @(posedge clk) begin
            reload <= !reset && restore_now;
        end
    end else begin : no_repair
        assign snapshot = '0;
        assign restore_now = 1'b0;
        assign restore_pop = 1'b0;
        assign restore_pointer = '0;
        assign restore_count = '0;
        assign reload = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            pointer <= '0;
            count <= '0;
            frozen <= 1'b0;
        end else if (redirect_taken) begin
            frozen <= 1'b0;
            if (restore_now) begin
                // A mispredicted RAS return keeps its own pop.
                if (restore_pop && restore_count != '0) begin
                    pointer <= restore_pointer - 1'b1;
                    count <= restore_count - 1'b1;
                end else begin
                    pointer <= restore_pointer;
                    count <= restore_count;
                end
            end
        end else begin
            if (reload) top_reg <= stack[pointer - 1'b1]; // repair: one cycle after the restore
            if (freeze) frozen <= 1'b1;
            if (push) begin
                // A call never pops in the same event (C.JALR ra is treated as a call).
                stack[pointer] <= push_value;
                top_reg <= push_value;
                pointer <= pointer + 1'b1;
                if (count != (PTR_W+1)'(RAS_DEPTH)) count <= count + 1'b1;
            end else if (pop && count != '0) begin
                top_reg <= stack[pointer - PTR_W'(2)];
                pointer <= pointer - 1'b1;
                count <= count - 1'b1;
            end
        end
    end
endmodule
