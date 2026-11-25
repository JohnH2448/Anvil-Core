// Shared instruction/data RAM: byte addresses [BASE, LIMIT].
//
// Word-interleaved into BANKS single-port banks (bank = word index mod
// BANKS, BANKS = next power of two >= FETCH_WORDS+1). A fetch reads
// FETCH_WORDS+1 consecutive words, which always land in distinct banks, so
// one fetch and one data access can proceed together unless the data word's
// bank is one the fetch needs. The Crossbar arbitrates that conflict (data
// first) and enables each client only when it is granted.
//
// Both clients have one-cycle synchronous access. Each bank's read register
// holds until that bank's next access, so a data response must be captured
// by the Crossbar in the cycle it returns.
//
// Data port: byte-masked writes, read-first. The Crossbar guarantees enabled
// data addresses are word aligned and in range.
// Fetch port: returns FETCH_WORDS words starting at the requested halfword
// (the same window as the former InstructionMemory). Words outside
// [BASE, LIMIT] read as zero, which decodes as an illegal instruction.
module RAM #(
    parameter logic [31:0] BASE = Parameters::RAM_BASE,
    parameter logic [31:0] LIMIT = Parameters::MAX_MEMORY_ADDRESS,
    parameter unsigned FETCH_WORDS = Parameters::CACHE_LINE_WORDS,
    parameter HEX_FILE = "" // Optional $readmemh image, word 0 = BASE.
)(
    input logic clk,

    // Data port
    input logic data_enable, data_write,
    input logic [31:0] data_address, data_wdata,
    input logic [3:0] data_mask,
    output logic [31:0] data_rdata,

    // Fetch port
    input logic fetch_enable,
    input logic [31:0] fetch_address,
    output logic [FETCH_WORDS*32-1:0] fetch_data
);
    localparam int unsigned WORDS = (LIMIT - BASE + 1) / 4;
    localparam int unsigned BANKS = 2 ** $clog2(FETCH_WORDS + 1);
    localparam int unsigned BANK_W = $clog2(BANKS);
    localparam int unsigned ROWS = (WORDS + BANKS - 1) / BANKS;
    localparam int unsigned ROW_W = ROWS > 1 ? $clog2(ROWS) : 1;
    localparam int unsigned WINDOW = FETCH_WORDS + 1;

    initial begin
        if (BASE[1:0] != 2'b00 || LIMIT[1:0] != 2'b11 || LIMIT < BASE)
            $error("RAM: BASE must be word aligned and LIMIT must end a word above it");
        if ((BASE >> 2) % BANKS != 0)
            $error("RAM: BASE must be aligned to BANKS words so the bank is address[BANK_W+1:2]");
    end

    // Word index relative to BASE, split into row and bank.
    function automatic logic [31:0] word_of(input logic [31:0] address);
        return (address - BASE) >> 2;
    endfunction

    logic [31:0] data_word, fetch_word;
    logic [BANK_W-1:0] data_bank;
    assign data_word = word_of(data_address);
    assign fetch_word = word_of({fetch_address[31:2], 2'b00});
    assign data_bank = data_word[BANK_W-1:0];

    // Per-bank address: the data access if it owns the bank, else the fetch
    // word whose index maps to this bank.
    logic [31:0] bank_output [BANKS];
    for (genvar b = 0; b < BANKS; b++) begin : bank
        logic [BANK_W-1:0] offset; // Which window word lands in this bank.
        logic [31:0] fetch_index;
        logic data_here;
        (* ram_style = "block" *) logic [31:0] memory [ROWS];
        initial begin
            logic [31:0] image [ROWS*BANKS];
            for (int unsigned i = 0; i < ROWS*BANKS; i++) image[i] = '0;
            if (HEX_FILE != "") $readmemh(HEX_FILE, image, 0, WORDS-1);
            for (int unsigned r = 0; r < ROWS; r++) memory[r] = image[r*BANKS + b];
        end
        assign offset = BANK_W'(b) - fetch_word[BANK_W-1:0];
        assign fetch_index = fetch_word + 32'(offset);
        assign data_here = data_enable && data_bank == BANK_W'(b);
        always_ff @(posedge clk) begin
            if (data_here) begin
                bank_output[b] <= memory[ROW_W'(data_word >> BANK_W)];
                if (data_write)
                    for (int i = 0; i < 4; i++)
                        if (data_mask[i]) memory[ROW_W'(data_word >> BANK_W)][8*i +: 8] <= data_wdata[8*i +: 8];
            end else if (fetch_enable && offset < BANK_W'(WINDOW)) begin
                bank_output[b] <= memory[ROW_W'(fetch_index >> BANK_W)];
            end
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
            for (int k = 0; k < WINDOW; k++) begin
                logic [31:0] address;
                address = {fetch_address[31:2], 2'b00} + 32'(4 * k);
                fetch_in_range_q[k] <= address >= BASE && address <= LIMIT - 3 &&
                    address >= {fetch_address[31:2], 2'b00}; // No 32-bit wrap.
            end
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
