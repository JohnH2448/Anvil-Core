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
    parameter unsigned RAS_DEPTH = Parameters::RAS_DEPTH
)(
    input logic clk,
    input logic reset,
    input logic redirect_taken,

    // Prediction-stage slots (bp_branch doubles as slot valid).
    input Definitions::BranchInput_ branch_input [FETCH_SLOTS-1:0],
    output logic slot_jalr [FETCH_SLOTS-1:0],
    output logic slot_return [FETCH_SLOTS-1:0],
    output logic top_valid,
    output fetch_pc_t top,

    // Commit of the prediction register into the FIFO.
    input logic commit,
    input Definitions::BranchInput_ commit_payload [FETCH_SLOTS-1:0],
    input logic commit_keep [FETCH_SLOTS-1:0],
    input logic commit_taken [FETCH_SLOTS-1:0]
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
    assign top_valid = count != '0;

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
        if (!commit || frozen) begin
            push = 1'b0;
            pop = 1'b0;
            freeze = 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            pointer <= '0;
            count <= '0;
            frozen <= 1'b0;
        end else if (redirect_taken) begin
            frozen <= 1'b0;
        end else begin
            if (freeze) frozen <= 1'b1;
            if (push) begin
                // A call never pops in the same event (C.JALR ra is treated as a call).
                stack[pointer] <= push_value;
                top <= push_value;
                pointer <= pointer + 1'b1;
                if (count != (PTR_W+1)'(RAS_DEPTH)) count <= count + 1'b1;
            end else if (pop && count != '0) begin
                top <= stack[pointer - PTR_W'(2)];
                pointer <= pointer - 1'b1;
                count <= count - 1'b1;
            end
        end
    end
endmodule
