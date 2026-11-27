// Branch target buffer (instantiated by Queue when USE_BTB = 1).
//
// Keyed by fetch-window start address (windows start at any halfword after a
// redirect). A hit means "the window at this address ends in a taken branch;
// fetch target next". The lookup runs from the registered prefetch_pc (the
// window whose data is arriving), so it is a flop -> compare -> select into
// the next request, parallel to the existing prefetch inputs.
//
// The BTB is only a fetch-steering hint: Queue verifies every window in the
// prediction stage by comparing the next fetch address the BTB chose with the
// one the real predictor computes, and corrects a mismatch. Entries are
// written at commit, once the target is known:
//   taken direct branch/jump      write (key, target)
//   taken return (RAS-predicted)  write (key, return kind, no target)
//   hit but not taken             invalidate
// A return-kind hit steers fetch to the RAS top: the BTB marks where a
// return is, the RAS supplies its target. Other JALRs are never written.
module BTB
    import DerivedParameters::*;
#(
    parameter unsigned BTB_ENTRIES = Parameters::BTB_ENTRIES
)(
    input logic clk,
    input logic reset,

    // Lookup
    input fetch_pc_t lookup_pc,
    output logic hit,
    output fetch_pc_t target,
    output logic hit_return, // the entry is a return: target comes from the RAS

    // Update at commit
    input logic write,
    input logic invalidate,
    input fetch_pc_t update_pc,
    input fetch_pc_t update_target,
    input logic update_return
);
    if (BTB_ENTRIES < 2 || (BTB_ENTRIES & (BTB_ENTRIES - 1)) != 0) begin : bad_btb_entries
        $fatal(1, "BTB: BTB_ENTRIES (%0d) must be a power of two >= 2", BTB_ENTRIES);
    end
    localparam int unsigned IDX_W = $clog2(BTB_ENTRIES);

    logic valid [BTB_ENTRIES];
    fetch_pc_t key [BTB_ENTRIES];
    fetch_pc_t destination [BTB_ENTRIES];
    logic is_return [BTB_ENTRIES];

    // Halfword-granular index (bit 0 of a fetch PC is always 0).
    function automatic logic [IDX_W-1:0] index_of(input fetch_pc_t pc);
        return IDX_W'(32'(pc) >> 1);
    endfunction

    // Full-key compare: no aliasing, so a hit is wrong only when the path into
    // the window changed its contents' meaning (verification catches that).
    logic [IDX_W-1:0] lookup_index;
    assign lookup_index = index_of(lookup_pc);
    assign hit = valid[lookup_index] && key[lookup_index] == lookup_pc;
    assign target = destination[lookup_index];
    assign hit_return = is_return[lookup_index];

    logic [IDX_W-1:0] update_index;
    assign update_index = index_of(update_pc);
    always_ff @(posedge clk) begin
        if (reset) begin
            valid <= '{default: 1'b0};
        end else if (write) begin
            valid[update_index] <= 1'b1;
            key[update_index] <= update_pc;
            destination[update_index] <= update_target;
            is_return[update_index] <= update_return;
        end else if (invalidate && key[update_index] == update_pc) begin
            valid[update_index] <= 1'b0;
        end
    end
endmodule
