// System top: CoreTop plus the data-side peripherals.
//   [0, 0x100)               CLINT
//   [0x100, RAM_BASE)        UART (registers only)
//   [RAM_BASE, MAX_MEMORY]   RAM
// Instructions and data share the RAM: the Crossbar arbitrates the core's
// fetch port and data bus onto it (data first). Execution starts at
// RESET_VECTOR = RAM_BASE, which is word 0 of HEX_FILE.
//
// Interrupts: the CLINT's timer and software levels drive mip.MTIP/mip.MSIP
// directly (spec level semantics: software clears them at the CLINT by
// writing mtimecmp or msip). A rising edge of external_interrupt becomes one
// INT_EXTERNAL pulse, which sets the sticky mip.MEIP; trap entry clears it.
module SystemTop
    import Parameters::*;
    import DerivedParameters::*;
    import Enumerations::*;
#(
    parameter HEX_FILE = "Core/Frontend/Fetch/program.hex" // Word 0 = RAM_BASE.
)(
    input logic clk, reset,
    input logic external_interrupt // Level or pulse; its rising edge requests MEI.
);
    logic request_valid, request_write, request_ready;
    logic [31:0] request_address, request_data;
    logic [3:0] request_mask;
    logic [1:0] request_size;
    logic response_valid, response_ready;
    logic [31:0] response_data;

    logic interrupt, timer_pending, software_pending;
    InterruptType_ interrupt_type;
    logic [63:0] mtime;

    logic fetch_request, fetch_valid, ram_fetch_enable;
    logic [31:0] fetch_address, ram_fetch_address;
    logic [FETCH_WORDS*32-1:0] fetch_data, ram_fetch_data;

    CoreTop core (
        .clk, .reset,
        .fetch_request, .fetch_address, .fetch_data, .fetch_valid, .interrupt, .interrupt_type, .time_value(mtime),
        .timer_pending, .software_pending,
        .request_valid, .request_write, .request_address, .request_data,
        .request_mask, .request_size, .request_ready, .response_valid,
        .response_data, .response_ready
    );

    logic clint_enable, clint_write, ram_data_claim, ram_data_enable, ram_data_write;
    logic [31:0] clint_address, clint_wdata, clint_rdata, ram_data_address, ram_data_wdata, ram_data_rdata;
    logic [3:0] clint_mask, ram_data_mask;
    logic uart_enable, uart_write;
    logic [31:0] uart_address, uart_wdata, uart_rdata;
    logic [3:0] uart_mask;

    Crossbar crossbar (
        .clk, .reset,
        .request_valid, .request_write, .request_address, .request_data,
        .request_mask, .request_size, .request_ready, .response_valid,
        .response_data, .response_ready,
        .fetch_request, .fetch_address, .fetch_data, .fetch_valid,
        .clint_enable, .clint_write, .clint_address, .clint_wdata, .clint_mask, .clint_rdata,
        .uart_enable, .uart_write, .uart_address, .uart_wdata, .uart_mask, .uart_rdata,
        .ram_data_claim, .ram_data_enable, .ram_data_write, .ram_data_address, .ram_data_wdata, .ram_data_mask, .ram_data_rdata,
        .ram_fetch_enable, .ram_fetch_address, .ram_fetch_data
    );

    CLINT clint (
        .clk, .reset,
        .enable(clint_enable), .write(clint_write), .address(clint_address),
        .wdata(clint_wdata), .mask(clint_mask), .rdata(clint_rdata),
        .mtime, .timer_pending, .software_pending
    );

    UART uart (
        .clk, .reset,
        .enable(uart_enable), .write(uart_write), .address(uart_address),
        .wdata(uart_wdata), .mask(uart_mask), .rdata(uart_rdata)
    );

    RAM #(.HEX_FILE(HEX_FILE)) ram (
        .clk,
        .data_claim(ram_data_claim), .data_enable(ram_data_enable), .data_write(ram_data_write), .data_address(ram_data_address),
        .data_wdata(ram_data_wdata), .data_mask(ram_data_mask), .data_rdata(ram_data_rdata),
        .fetch_enable(ram_fetch_enable), .fetch_address(ram_fetch_address), .fetch_data(ram_fetch_data)
    );

    // External interrupt: one pulse per rising edge.
    logic external_q;
    always_ff @(posedge clk) begin
        if (reset) begin
            external_q <= 1'b0;
            interrupt <= 1'b0;
        end else begin
            external_q <= external_interrupt;
            interrupt <= external_interrupt && !external_q;
        end
    end
    assign interrupt_type = INT_EXTERNAL;
endmodule
