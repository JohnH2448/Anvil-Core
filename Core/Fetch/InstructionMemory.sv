module InstructionMemory #(
    parameter FETCH_WORDS = 2,
    parameter DEPTH_WORDS = 512,
    parameter HEX_FILE = "Core/Fetch/program.hex"
)(
    // Standard Inputs
    input logic clk,
    input logic reset,

    // Byte-Addressed Memory Request
    input logic [31:0] req_address,

    // Fetch Response Data and Status
    output logic [FETCH_WORDS*32-1:0] fetch_data,
    output logic fetch_valid,
    output logic fetch_error
);
    // Derived Word Address Width
    localparam ADDR_W = $clog2(DEPTH_WORDS);

    // Block RAM ROM; Additional Read Ports May Replicate Initialized Storage
    (* ram_style = "block" *) logic [31:0] memory [0:DEPTH_WORDS-1];
    // Registered Read Data and Halfword Alignment
    logic [31:0] read_words [0:FETCH_WORDS];
    logic request_halfword;
    // Combinational Window for Response Alignment
    logic [(FETCH_WORDS+1)*32-1:0] read_window;

    // Initializes ROM With NOPs and Loads Optional 32-Bit-Word Hex File
    initial begin
        for (int i = 0; i < DEPTH_WORDS; i++) memory[i] = 32'h0000_0013;
        if (HEX_FILE != "") $readmemh(HEX_FILE, memory);
    end

    // Performs Synchronous Reads and Registers Request Alignment
    always_ff @(posedge clk) begin
        logic [ADDR_W-1:0] word_address;
        word_address = req_address[ADDR_W+1:2];
        if (reset) begin
            fetch_valid <= 1'b0;
            request_halfword <= 1'b0;
            for (int i = 0; i <= FETCH_WORDS; i++) read_words[i] <= '0;
        end else begin
            // Reads One Extra Word for Halfword-Aligned Fetches
            // Truncated Addresses Intentionally Wrap Within ROM Depth
            for (int i = 0; i <= FETCH_WORDS; i++)
                read_words[i] <= memory[ADDR_W'(word_address + ADDR_W'(i))];
            request_halfword <= req_address[1];
            fetch_valid <= 1'b1;
        end
    end

    // Packs Registered Words and Selects the Requested Halfword Boundary
    always_comb begin
        for (int i = 0; i <= FETCH_WORDS; i++)
            read_window[i*32 +: 32] = read_words[i];
        if (request_halfword)
            fetch_data = read_window[16 +: FETCH_WORDS*32];
        else
            fetch_data = read_window[0 +: FETCH_WORDS*32];
    end

    // ROM Model Does Not Generate Access Errors
    assign fetch_error = 1'b0;

    // Checks Power-of-Two Depth and Capacity for the Full Read Window
    if (DEPTH_WORDS < FETCH_WORDS + 1 ||
        (DEPTH_WORDS & (DEPTH_WORDS-1)) != 0) begin : invalid_depth
        initial $error("DEPTH_WORDS must be a power of two and exceed FETCH_WORDS");
    end
endmodule
