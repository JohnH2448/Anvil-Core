// Shared instruction/data RAM: byte addresses [BASE, LIMIT].
//
// Word-interleaved into BANKS single-port banks (bank = word index mod
// BANKS, BANKS = next power of two >= FETCH_WORDS+1). A fetch reads
// FETCH_WORDS+1 consecutive words, which always land in distinct banks, so
// one fetch and one data access can proceed together unless the data word's
// bank is one the fetch needs. The Crossbar arbitrates that conflict (data
// first).
//
// Rows are indexed by the absolute word address (no BASE subtraction on the
// address paths). Rows below BASE exist but are never written, so they read
// zero; that costs BASE bytes of storage.
//
// Data port, split for timing:
//   data_claim   early: a data request is present (address mux, fetch
//                exclusion). Needs only the request valid and bank bits.
//   data_enable  late: the request is an in-range, aligned RAM access
//                (bank enable / write enable only).
// A claimed but not enabled bank (device or faulting access) is simply idle;
// the Crossbar already denied the conflicting fetch.
//
// Both clients have one-cycle synchronous access. Each bank's read register
// holds until that bank's next access.
// Fetch port: returns FETCH_WORDS words starting at the requested halfword.
// Words above LIMIT read as zero, which decodes as an illegal instruction.
module RAM #(
    parameter logic [31:0] BASE = Parameters::RAM_BASE,
    parameter logic [31:0] LIMIT = Parameters::MAX_MEMORY_ADDRESS,
    parameter unsigned FETCH_WORDS = Parameters::CACHE_LINE_WORDS,
    parameter HEX_FILE = "" // Optional $readmemh image, word 0 = BASE.
)(
    input logic clk,

    // Data port
    input logic data_claim, data_enable, data_write,
    input logic [31:0] data_address, data_wdata,
    input logic [3:0] data_mask,
    output logic [31:0] data_rdata,

    // Fetch port
    input logic fetch_enable,
    input logic [31:0] fetch_address,
    output logic [FETCH_WORDS*32-1:0] fetch_data
);
    localparam int unsigned TOTAL_WORDS = (LIMIT + 1) / 4; // from address 0
    localparam int unsigned BANKS = 2 ** $clog2(FETCH_WORDS + 1);
    localparam int unsigned BANK_W = $clog2(BANKS);
    localparam int unsigned ROWS = (TOTAL_WORDS + BANKS - 1) / BANKS;
    localparam int unsigned ROW_W = ROWS > 1 ? $clog2(ROWS) : 1;
    localparam int unsigned WINDOW = FETCH_WORDS + 1;

    initial begin
        if (BASE[1:0] != 2'b00 || LIMIT[1:0] != 2'b11 || LIMIT < BASE)
            $error("RAM: BASE must be word aligned and LIMIT must end a word above it");
    end

    logic [29:0] data_word, fetch_word;
    logic [BANK_W-1:0] data_bank;
    logic [ROW_W-1:0] data_row;
    assign data_word = data_address[31:2];
    assign fetch_word = fetch_address[31:2];
    assign data_bank = data_word[BANK_W-1:0];
    assign data_row = ROW_W'(data_word >> BANK_W);

    logic [31:0] bank_output [BANKS];
    for (genvar b = 0; b < BANKS; b++) begin : bank
        logic [BANK_W-1:0] offset; // Which window word lands in this bank.
        logic [29:0] fetch_index;
        logic claim_here, data_here, fetch_here;
        logic [ROW_W-1:0] row;
        (* ram_style = "block" *) logic [31:0] memory [ROWS];
        initial begin
            logic [31:0] image [ROWS*BANKS];
            for (int unsigned i = 0; i < ROWS*BANKS; i++) image[i] = '0;
            if (HEX_FILE != "") $readmemh(HEX_FILE, image, BASE / 4, LIMIT / 4);
            for (int unsigned r = 0; r < ROWS; r++) memory[r] = image[r*BANKS + b];
        end
        assign offset = BANK_W'(b) - fetch_word[BANK_W-1:0];
        assign fetch_index = fetch_word + 30'(offset);
        assign claim_here = data_claim && data_bank == BANK_W'(b);
        assign data_here = data_enable && data_bank == BANK_W'(b);
        assign fetch_here = fetch_enable && !claim_here && offset < BANK_W'(WINDOW);
        // The address select uses the early claim; only the enables are late.
        assign row = claim_here ? data_row : ROW_W'(fetch_index >> BANK_W);
        always_ff @(posedge clk) begin
            if (data_here || fetch_here) bank_output[b] <= memory[row];
            if (data_here && data_write)
                for (int i = 0; i < 4; i++)
                    if (data_mask[i]) memory[row][8*i +: 8] <= data_wdata[8*i +: 8];
        end
    end

    // Registered selects for the response cycle.
    logic [BANK_W-1:0] data_bank_q, fetch_bank_q;
    logic fetch_halfword_q;
    logic fetch_in_range_q [WINDOW];
    always_ff @(posedge clk) begin
        if (data_enable) data_bank_q <= data_bank;
        if (fetch_enable) begin
            fetch_bank_q <= fetch_word[BANK_W-1:0];
            fetch_halfword_q <= fetch_address[1];
            // Only the upper bound matters: rows below BASE read zero.
            for (int k = 0; k < WINDOW; k++)
                fetch_in_range_q[k] <= 32'(fetch_word) + 32'(k) < TOTAL_WORDS;
        end
    end
    assign data_rdata = bank_output[data_bank_q];

    logic [WINDOW*32-1:0] window;
    always_comb begin
        for (int k = 0; k < WINDOW; k++)
            window[k*32 +: 32] = fetch_in_range_q[k] ? bank_output[BANK_W'(fetch_bank_q + BANK_W'(k))] : '0;
        fetch_data = fetch_halfword_q ? window[16 +: FETCH_WORDS*32] : window[0 +: FETCH_WORDS*32];
    end
endmodule
