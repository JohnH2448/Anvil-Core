// Small CLINT (core-local interruptor) for one hart. Register semantics follow
// the RISC-V ACLINT MTIMER/MSWI devices; the offsets are compacted to fit the
// device window below RAM_BASE:
//   0x00  msip         bit 0 = machine software interrupt pending (R/W)
//   0x08  mtimecmp     low 32 bits  (R/W)
//   0x0C  mtimecmph    high 32 bits (R/W)
//   0x10  mtime        low 32 bits  (R/W)
//   0x14  mtimeh       high 32 bits (R/W)
// Every other offset reads zero and ignores writes. Writes honor the byte mask.
//
// mtime counts every clock (the timebase is the core clock). The timer is
// pending while mtime >= mtimecmp. mtimecmp resets to all ones, so the timer
// cannot fire until software programs it (the spec leaves the reset value
// unspecified). msip resets to zero.
//
// One-cycle synchronous access: the read data is registered on enable and
// holds until the next enabled access.
module CLINT (
    input logic clk, reset,

    input logic enable, write,
    input logic [31:0] address, wdata,
    input logic [3:0] mask,
    output logic [31:0] rdata,

    output logic [63:0] mtime,
    output logic timer_pending, // Registered mtime >= mtimecmp.
    output logic software_pending // msip
);
    logic [63:0] mtimecmp;
    logic msip;

    function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] value,
                                          input logic [3:0] byte_mask);
        logic [31:0] result;
        for (int b = 0; b < 4; b++)
            result[8*b +: 8] = byte_mask[b] ? value[8*b +: 8] : old[8*b +: 8];
        return result;
    endfunction

    // Word offset within the device window.
    logic [2:0] offset;
    logic in_window;
    assign offset = address[4:2];
    assign in_window = address[31:5] == '0;
    wire store = enable && write && in_window;

    logic [31:0] read_value;
    always_comb begin
        read_value = '0;
        if (in_window) begin
            unique case (offset)
                3'd0: read_value = {31'd0, msip};
                3'd2: read_value = mtimecmp[31:0];
                3'd3: read_value = mtimecmp[63:32];
                3'd4: read_value = mtime[31:0];
                3'd5: read_value = mtime[63:32];
                3'd1, 3'd6, 3'd7: ;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            msip <= 1'b0;
            mtimecmp <= '1;
            mtime <= '0;
            timer_pending <= 1'b0;
        end else begin
            // A write to one half of mtime replaces that half for this cycle.
            if (store && offset == 3'd4) mtime[31:0] <= merge(mtime[31:0], wdata, mask);
            else if (store && offset == 3'd5) mtime[63:32] <= merge(mtime[63:32], wdata, mask);
            else mtime <= mtime + 64'd1;
            if (store && offset == 3'd0 && mask[0]) msip <= wdata[0];
            if (store && offset == 3'd2) mtimecmp[31:0] <= merge(mtimecmp[31:0], wdata, mask);
            if (store && offset == 3'd3) mtimecmp[63:32] <= merge(mtimecmp[63:32], wdata, mask);
            // Registered so the 64-bit compare is not on the interrupt path.
            timer_pending <= mtime >= mtimecmp;
        end
        if (enable) rdata <= read_value;
    end
    assign software_pending = msip;
endmodule
