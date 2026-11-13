module FetchTop #(
    parameter unsigned FETCH_WORDS = 2,
    parameter unsigned SUPPORT_MUL = Parameters::SUPPORT_MUL,
    parameter unsigned SUPPORT_DIV = Parameters::SUPPORT_DIV,
    parameter unsigned SUPPORT_FLOAT = Parameters::SUPPORT_FLOAT,
    parameter unsigned SUPPORT_ATOMIC = Parameters::SUPPORT_ATOMIC,
    parameter unsigned FIFO_WORDS = 8,
    parameter unsigned ISSUE_WIDTH = 2,
    parameter unsigned RESET_VECTOR = 32'h0000_0000,
    parameter unsigned IMEM_DEPTH_WORDS = 512,
    parameter IMEM_HEX_FILE = "Core/Frontend/Fetch/program.hex"
)(

    // Standard Inputs
    input logic clk,
    input logic reset,

    // Redirect Inputs
    input logic [31:0] redirect_pc,
    input logic redirect_taken,

    // Output to Decode Stage
    output logic [31:0] serve_data_reg [ISSUE_WIDTH-1:0],
    output logic [4:0] serve_rs1 [ISSUE_WIDTH-1:0],
    output logic [4:0] serve_rs2 [ISSUE_WIDTH-1:0],
    output logic [31:0] serve_pc_reg [ISSUE_WIDTH-1:0],
    output logic serve_valid_reg [ISSUE_WIDTH-1:0],
    output logic serve_c_reg [ISSUE_WIDTH-1:0],
    output logic serve_taken_reg [ISSUE_WIDTH-1:0],
    output logic serve_branch_reg [ISSUE_WIDTH-1:0],

    // Consumption from Decode Stage
    input logic [$clog2(ISSUE_WIDTH+1)-1:0] serve_consumed
);

    Definitions::BranchInput_ branch_input [FETCH_WORDS*2-1:0];
    Definitions::BranchOutput_ branch_output [FETCH_WORDS*2-1:0];
    logic [31:0] req_address;
    logic req_valid;
    logic req_ready;
    logic [FETCH_WORDS*32-1:0] fetch_data;
    logic fetch_valid;
    logic fetch_error;

    Queue #(
        .FETCH_WORDS(FETCH_WORDS),
        .SUPPORT_MUL(SUPPORT_MUL),
        .SUPPORT_DIV(SUPPORT_DIV),
        .SUPPORT_FLOAT(SUPPORT_FLOAT),
        .SUPPORT_ATOMIC(SUPPORT_ATOMIC),
        .FIFO_WORDS(FIFO_WORDS),
        .SERVE_WORDS(ISSUE_WIDTH),
        .RESET_VECTOR(RESET_VECTOR)
    ) queue (
        .clk(clk),
        .flush(1'b0), // Reserved queue interface; redirects perform the active flush.
        .reset(reset),

        .redirect_pc(redirect_pc),
        .redirect_taken(redirect_taken),

        .req_address(req_address),
        .req_valid(req_valid),
        .req_ready(req_ready),

        .fetch_data(fetch_data),
        .fetch_valid(fetch_valid),
        .fetch_error(fetch_error),

        .serve_data_reg(serve_data_reg),
        .serve_rs1(serve_rs1),
        .serve_rs2(serve_rs2),
        .serve_pc_reg(serve_pc_reg),
        .serve_valid_reg(serve_valid_reg),
        .serve_c_reg(serve_c_reg),
        .serve_taken_reg(serve_taken_reg),
        .serve_branch_reg(serve_branch_reg),

        .branch_input(branch_input),
        .branch_output(branch_output),

        .serve_consumed(serve_consumed)
    );

    for (genvar i = 0; i < FETCH_WORDS*2; i++) begin : predictors
        Predictor predictor (
            .clk(clk),
            .reset(reset),
            .branch_input(branch_input[i]),
            .branch_output(branch_output[i])
        );
    end

    InstructionMemory #(
        .FETCH_WORDS(FETCH_WORDS),
        .DEPTH_WORDS(IMEM_DEPTH_WORDS),
        .HEX_FILE(IMEM_HEX_FILE)
    ) instruction_memory (
        .clk(clk),
        .reset(reset),
        .req_address(req_address),
        .fetch_data(fetch_data),
        .fetch_valid(fetch_valid),
        .fetch_error(fetch_error)
    );

endmodule
