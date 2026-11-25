// Crossbar: the core's data bus and fetch port onto the CLINT, the UART and
// the shared instruction/data RAM.
//   [0, UART_BASE)           CLINT (data only; fetches there read zero)
//   [UART_BASE, RAM_BASE)    UART  (data only; fetches there read zero)
//   [RAM_BASE, LIMIT]        RAM (data and fetch)
//   above LIMIT              data: error; fetch: reads zero
//
// Arbitration for the RAM: data first, then fetch. The RAM is banked, so the
// fetch loses only when the data access hits a bank the fetch window needs.
// A denied fetch returns fetch_valid = 0 the next cycle and Fetch re-requests
// the same address.
//
// The core requires the bus to discover every memory trap, so misaligned
// (address/size) and out-of-range data accesses get response_error and
// perform no access.
//
// Both targets have one-cycle synchronous access, so data responses return in
// request order. One response register: a new data request is accepted only
// when it is empty or draining. RAM bank outputs can be overwritten by a
// later fetch, so the response data is captured on its first cycle and held.
module Crossbar
    import Enumerations::*;
#(
    parameter logic [31:0] UART_BASE = 32'h0000_0100,
    parameter logic [31:0] RAM_BASE = Parameters::RAM_BASE,
    parameter logic [31:0] LIMIT = Parameters::MAX_MEMORY_ADDRESS,
    parameter unsigned FETCH_WORDS = Parameters::CACHE_LINE_WORDS
)(
    input logic clk, reset,

    // Core data bus
    input logic request_valid, request_write,
    input logic [31:0] request_address, request_data,
    input logic [3:0] request_mask,
    input logic [1:0] request_size, // MemorySize_
    output logic request_ready,
    output logic response_valid, response_error,
    output logic [31:0] response_data,
    input logic response_ready,

    // Core fetch port (one request per cycle, response next cycle)
    input logic fetch_request,
    input logic [31:0] fetch_address,
    output logic [FETCH_WORDS*32-1:0] fetch_data,
    output logic fetch_valid,
    output logic fetch_error,

    // CLINT
    output logic clint_enable, clint_write,
    output logic [31:0] clint_address, clint_wdata,
    output logic [3:0] clint_mask,
    input logic [31:0] clint_rdata,

    // UART
    output logic uart_enable, uart_write,
    output logic [31:0] uart_address, uart_wdata,
    output logic [3:0] uart_mask,
    input logic [31:0] uart_rdata,

    // RAM
    output logic ram_data_enable, ram_data_write,
    output logic [31:0] ram_data_address, ram_data_wdata,
    output logic [3:0] ram_data_mask,
    input logic [31:0] ram_data_rdata,
    output logic ram_fetch_enable,
    output logic [31:0] ram_fetch_address,
    input logic [FETCH_WORDS*32-1:0] ram_fetch_data
);
    localparam int unsigned BANKS = 2 ** $clog2(FETCH_WORDS + 1);
    localparam int unsigned BANK_W = $clog2(BANKS);
    localparam int unsigned WINDOW = FETCH_WORDS + 1;

    // ------------------------------------------------------------ data decode
    initial begin
        if (UART_BASE + 32'h20 > RAM_BASE) $error("Crossbar: the UART window must end at or below RAM_BASE");
    end

    logic misaligned, out_of_range, to_ram, to_clint, to_uart;
    logic [31:0] last_byte;
    always_comb begin
        misaligned = 1'b1; // Reserved size encoding faults.
        unique case (MemorySize_'(request_size))
            MEM_BYTE: misaligned = 1'b0;
            MEM_HALF: misaligned = request_address[0];
            MEM_WORD: misaligned = request_address[1:0] != 2'b00;
        endcase
        // Only used when aligned, so the access never straddles a boundary.
        last_byte = request_address | 32'(request_size == MEM_WORD ? 3 : request_size == MEM_HALF ? 1 : 0);
        out_of_range = !DerivedParameters::FULL_ADDRESS_SPACE && last_byte > LIMIT;
        to_clint = request_address < UART_BASE;
        to_uart = !to_clint && request_address < RAM_BASE;
        to_ram = !to_clint && !to_uart && !out_of_range;
    end

    wire accept = request_valid && request_ready;
    wire fault = misaligned || out_of_range;

    assign clint_enable = accept && !fault && to_clint;
    assign uart_enable = accept && !fault && to_uart;
    assign uart_write = request_write;
    assign uart_address = request_address - UART_BASE;
    assign uart_wdata = request_data;
    assign uart_mask = request_mask;
    assign ram_data_enable = accept && !fault && to_ram;
    assign clint_write = request_write;
    assign ram_data_write = request_write;
    assign clint_address = request_address;
    assign ram_data_address = request_address;
    assign clint_wdata = request_data;
    assign ram_data_wdata = request_data;
    assign clint_mask = request_mask;
    assign ram_data_mask = request_mask;

    // ------------------------------------------------------------ arbitration
    // Banks are word index mod BANKS; RAM_BASE is BANKS-word aligned, so the
    // bank is address[BANK_W+1:2]. The fetch window covers WINDOW consecutive
    // banks starting at the fetch word.
    logic [BANK_W-1:0] data_bank, fetch_bank, distance;
    logic conflict;
    always_comb begin
        data_bank = request_address[BANK_W+1:2];
        fetch_bank = fetch_address[BANK_W+1:2];
        distance = data_bank - fetch_bank;
        conflict = ram_data_enable && distance < BANK_W'(WINDOW);
    end
    assign ram_fetch_enable = fetch_request && !conflict;
    assign ram_fetch_address = fetch_address;

    always_ff @(posedge clk) begin
        if (reset) fetch_valid <= 1'b0;
        else fetch_valid <= ram_fetch_enable;
    end
    assign fetch_data = ram_fetch_data;
    assign fetch_error = 1'b0; // Out-of-range fetch words read zero (illegal instruction).

    // ------------------------------------------------------------ data response
    logic from_ram, from_uart, fresh;
    logic [31:0] target_data;
    assign target_data = from_ram ? ram_data_rdata : from_uart ? uart_rdata : clint_rdata;
    logic [31:0] held_data;
    assign request_ready = !response_valid || response_ready;
    always_ff @(posedge clk) begin
        if (reset) begin
            response_valid <= 1'b0;
            fresh <= 1'b0;
        end else begin
            fresh <= accept;
            if (accept) begin
                response_valid <= 1'b1;
                response_error <= fault;
                from_ram <= to_ram;
                from_uart <= to_uart;
            end else if (response_ready) begin
                response_valid <= 1'b0;
            end
        end
        if (fresh) held_data <= target_data;
    end
    assign response_data = fresh ? target_data : held_data;
endmodule
