// Crossbar: the core's data bus and fetch port onto the CLINT, the UART and
// the shared instruction/data RAM.
//   [0, UART_BASE)           CLINT (data only; fetches there read zero)
//   [UART_BASE, RAM_BASE)    UART  (data only; fetches there read zero)
//   [RAM_BASE, LIMIT]        RAM (data and fetch)
//   above LIMIT              data: error; fetch: reads zero
//
// Arbitration for the RAM: data first, then fetch. The RAM is banked, so the
// fetch loses only when a data request claims a bank the fetch window needs.
// A denied fetch returns fetch_valid = 0 the next cycle and Fetch re-requests
// the same address.
//
// The bus never reports errors: the core detects every memory trap in the
// AGU. As a safeguard, misaligned (address/size) and out-of-range data
// accesses (which only a discarded direct-send load can present) perform no
// access.
//
// Timing structure:
//   - Fetch arbitration and the RAM bank address select use an early data
//     "claim" (request valid + bank bits), never the region/fault decode. A
//     device or faulting request still claims its bank for that cycle, which
//     only costs a fetch retry.
//   - The region/fault decode (high address bits, arriving last from the AGU)
//     drives only the target enables and the registered response flags.
//   - No response backpressure: every target answers in one cycle, and the
//     LSU accepts a response whenever one is owed (response_ready is high
//     whenever anything is outstanding). So request_ready is constant and the
//     response is the target's output in its single response cycle, with no
//     hold register. A simulation check guards the assumption.
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
    output logic response_valid,
    output logic [31:0] response_data,
    input logic response_ready,

    // Core fetch port (one request per cycle, response next cycle)
    input logic fetch_request,
    input logic [31:0] fetch_address,
    output logic [FETCH_WORDS*32-1:0] fetch_data,
    output logic fetch_valid,

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
    output logic ram_data_claim, ram_data_enable, ram_data_write,
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

    initial begin
        if (UART_BASE + 32'h20 > RAM_BASE) $error("Crossbar: the UART window must end at or below RAM_BASE");
    end

    // ------------------------------------------------------------ data decode
    // Only aligned accesses proceed, so the word address bounds the access:
    // an aligned access never crosses its word, and LIMIT ends a word.
    logic misaligned, out_of_range, to_ram, to_clint, to_uart;
    always_comb begin
        misaligned = 1'b1; // Reserved size encoding faults.
        unique case (MemorySize_'(request_size))
            MEM_BYTE: misaligned = 1'b0;
            MEM_HALF: misaligned = request_address[0];
            MEM_WORD: misaligned = request_address[1:0] != 2'b00;
        endcase
        out_of_range = !DerivedParameters::FULL_ADDRESS_SPACE && request_address[31:2] > LIMIT[31:2];
        to_clint = request_address[31:2] < UART_BASE[31:2];
        to_uart = !to_clint && request_address[31:2] < RAM_BASE[31:2];
        to_ram = !to_clint && !to_uart && !out_of_range;
    end

    wire fault = misaligned || out_of_range;
    assign request_ready = 1'b1;

    assign clint_enable = request_valid && !fault && to_clint;
    assign uart_enable = request_valid && !fault && to_uart;
    assign ram_data_enable = request_valid && !fault && to_ram;
    assign ram_data_claim = request_valid;
    assign clint_write = request_write;
    assign uart_write = request_write;
    assign ram_data_write = request_write;
    assign clint_address = request_address;
    assign uart_address = request_address - UART_BASE;
    assign ram_data_address = request_address;
    assign clint_wdata = request_data;
    assign uart_wdata = request_data;
    assign ram_data_wdata = request_data;
    assign clint_mask = request_mask;
    assign uart_mask = request_mask;
    assign ram_data_mask = request_mask;

    // ------------------------------------------------------------ arbitration
    // Banks are word index mod BANKS = address[BANK_W+1:2]. The fetch window
    // covers WINDOW consecutive banks starting at the fetch word. Uses the
    // early claim only (valid + low address bits).
    logic [BANK_W-1:0] data_bank, fetch_bank, distance;
    logic conflict;
    always_comb begin
        data_bank = request_address[BANK_W+1:2];
        fetch_bank = fetch_address[BANK_W+1:2];
        distance = data_bank - fetch_bank;
        conflict = ram_data_claim && distance < BANK_W'(WINDOW);
    end
    assign ram_fetch_enable = fetch_request && !conflict;
    assign ram_fetch_address = fetch_address;

    always_ff @(posedge clk) begin
        if (reset) fetch_valid <= 1'b0;
        else fetch_valid <= ram_fetch_enable;
    end
    assign fetch_data = ram_fetch_data;
    // Out-of-range fetch words read zero (illegal instruction).

    // ------------------------------------------------------------ data response
    // One response cycle per accepted request; the target outputs are valid in
    // exactly that cycle.
    logic from_ram, from_uart;
    always_ff @(posedge clk) begin
        if (reset) begin
            response_valid <= 1'b0;
        end else begin
            response_valid <= request_valid;
            from_ram <= to_ram;
            from_uart <= to_uart;
        end
    end
    assign response_data = from_ram ? ram_data_rdata : from_uart ? uart_rdata : clint_rdata;

    // synthesis translate_off
    always @(posedge clk)
        if (!reset && response_valid && !response_ready)
            $error("Crossbar: response not accepted in its cycle (no hold register)");
    // synthesis translate_on
endmodule
