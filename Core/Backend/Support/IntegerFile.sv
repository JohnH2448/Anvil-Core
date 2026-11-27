// Integer register file: 31 x 32-bit (x0 reads zero), WRITE_PORTS write ports,
// READ_PORTS asynchronous read ports.
//
// Built for distributed (LUT) RAM instead of flops plus 32:1 read muxes. A LUT
// RAM has one write port, so each write port owns a bank holding a full copy
// of the registers it writes, and a live-value table (LVT, one small flop per
// register) records which bank wrote each register last. A read reads every
// bank and selects by the LVT. Synthesis replicates each bank per read port
// (one write, many asynchronous reads), which LUT RAM supports directly.
//
// Semantics are unchanged: writes land on the clock edge, reads are
// combinational, x0 is never written and reads zero, and two ports writing
// the same register on one edge leave the higher port's value (as before,
// the later loop iteration won).
module IntegerFile #(
    parameter unsigned READ_PORTS = 2,
    parameter unsigned WRITE_PORTS = 1
)(
    // Standard Inputs
    input logic clk,

    // Read Signals
    input logic [4:0] read_addr [READ_PORTS-1:0],
    output logic [31:0] read_data [READ_PORTS-1:0],

    // Write Signals
    input logic [4:0] write_addr [WRITE_PORTS-1:0],
    input logic [31:0] write_data [WRITE_PORTS-1:0],
    input logic write_en [WRITE_PORTS-1:0]
);
    localparam int unsigned LVT_W = WRITE_PORTS > 1 ? $clog2(WRITE_PORTS) : 1;

    // One bank per write port (LUT RAM: one write port, asynchronous reads).
    logic [31:0] bank_data [WRITE_PORTS][READ_PORTS];
    for (genvar w = 0; w < WRITE_PORTS; w++) begin : banks
        (* ram_style = "distributed" *) logic [31:0] bank [32];
        always_ff @(posedge clk)
            if (write_en[w] && write_addr[w] != 0) bank[write_addr[w]] <= write_data[w];
        for (genvar r = 0; r < READ_PORTS; r++) begin : reads
            assign bank_data[w][r] = bank[read_addr[r]];
        end
    end

    // Live-value table: the bank holding each register's latest value.
    if (WRITE_PORTS > 1) begin : live_value_table
        logic [LVT_W-1:0] live [32];
        always_ff @(posedge clk)
            for (int unsigned w = 0; w < WRITE_PORTS; w++)
                if (write_en[w] && write_addr[w] != 0) live[write_addr[w]] <= LVT_W'(w);
        for (genvar r = 0; r < READ_PORTS; r++) begin : read_ports
            assign read_data[r] = read_addr[r] == 0 ? 32'b0 : bank_data[live[read_addr[r]]][r];
        end
    end else begin : single_bank
        for (genvar r = 0; r < READ_PORTS; r++) begin : read_ports
            assign read_data[r] = read_addr[r] == 0 ? 32'b0 : bank_data[0][r];
        end
    end
endmodule
