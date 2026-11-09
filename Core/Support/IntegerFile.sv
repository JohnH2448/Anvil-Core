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

    // Declared Register File
    logic [31:0] register_file [31:0];

    // Combinational Read Mapping
    genvar i;
    generate
        for (i = 0; i < READ_PORTS; i++) begin : read_ports
            assign read_data[i] = register_file[read_addr[i]];
        end
    endgenerate

    // Write Latching
    always_ff @(posedge clk) begin
        for (int unsigned i = 0; i < WRITE_PORTS; i++) begin
            if (write_en[i]) begin
                register_file[write_addr[i]] <= write_data[i];
            end
        end
    end

endmodule