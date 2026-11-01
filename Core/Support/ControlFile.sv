import Enumerations::*;

module ControlFile #(
    parameter READ_PORTS = 1,
    parameter WRITE_PORTS = 1
)(
    // Standard Inputs
    input logic clk,

    // Read Signals
    input CSR_R read_addr [READ_PORTS-1:0],
    output logic [31:0] read_data [READ_PORTS-1:0],

    // Write Signals
    input CSR_R write_addr [WRITE_PORTS-1:0],
    input logic [31:0] candidate_write_data [WRITE_PORTS-1:0],
    input logic write_en [WRITE_PORTS-1:0]
);

    // Declared CSR File
    logic [31:0] csr_file [CSR_R'(0).num()];

    // Combinational Read Mapping
    genvar i;
    generate
        for (i = 0; i < READ_PORTS; i++) begin : read_ports
            assign read_data[i] = csr_file[read_addr[i]];
        end
    endgenerate

    // Candidate Data Override for Per CSR Rules 
    logic [31:0] write_data;
    always_comb begin
        write_data = candidate_write_data;
        case(write_addr)
            MTVEC_R: write_data = {candidate_write_data[31:2], 2'b00};
        endcase
    end

    // Write Latching
    always_ff @(posedge clk) begin
        for (int i = 0; i < WRITE_PORTS; i++) begin
            if (write_en[i]) begin
                csr_file[write_addr[i]] <= write_data[i];
            end
        end
    end

endmodule

// CSR File does not trap. Traps must be detected
// prior to any write on the CSR file