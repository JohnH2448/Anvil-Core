// Register-only UART: the register file and bus interface, with no serial
// hardware behind it yet. Offsets from the UART base (word registers, low
// byte used):
//   0x00  TX_DATA   W   outgoing byte buffer (reads 0)
//   0x04  TX_BUSY   R   transmitter busy (no transmitter yet: tied 0)
//   0x08  RX_DATA   R   received byte buffer (writes ignored)
//   0x0C  RX_READY  R   a received byte is waiting (writes ignored).
//                       Cleared by reading RX_DATA. Nothing sets it yet.
// Other offsets read zero and ignore writes. Writes honor the byte mask.
// One-cycle synchronous access: read data is registered on enable and holds
// until the next enabled access (same contract as the CLINT).
//
// The RX_DATA read is a side effect, so it happens only on an enabled read,
// i.e. a load the LSU actually sends to the bus.
module UART (
    input logic clk, reset,

    input logic enable, write,
    input logic [31:0] address, wdata,
    input logic [3:0] mask,
    output logic [31:0] rdata
);
    logic [7:0] tx_data, rx_data;
    logic tx_busy, rx_ready;

    // TODO (hardware): a transmitter drives tx_busy while shifting tx_data.
    assign tx_busy = 1'b0;

    logic [1:0] offset;
    logic in_window;
    assign offset = address[3:2];
    assign in_window = address[31:4] == '0;
    wire store = enable && write && in_window;
    wire load = enable && !write && in_window;

    logic [31:0] read_value;
    always_comb begin
        read_value = '0;
        if (in_window) begin
            unique case (offset)
                2'd0: ; // TX_DATA is write-only
                2'd1: read_value = {31'd0, tx_busy};
                2'd2: read_value = {24'd0, rx_data};
                2'd3: read_value = {31'd0, rx_ready};
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            tx_data <= '0;
            rx_data <= '0;
            rx_ready <= 1'b0;
        end else begin
            if (store && offset == 2'd0 && mask[0]) tx_data <= wdata[7:0];
            // TODO (hardware): a receiver loads rx_data and sets rx_ready.
            if (load && offset == 2'd2) rx_ready <= 1'b0;
        end
        if (enable) rdata <= read_value;
    end
endmodule
