module Multiplier
    import Enumerations::*;
    import Definitions::*;
#(
    parameter unsigned UNROLL_CUTOFF = 4
)(

    // Standard Inputs
    input logic clk,
    input logic reset,
    input logic stall,
    input logic flush,
    input logic valid_in,

    // Working Set
    input IntegerOperands_ integer_payload, 
    input DecodeMul_ multiply_payload,

    // Outputs
    output logic [31:0] result,
    output logic valid_out,
    output logic iteration_stall

);

    // Step 1: Generate Partial Products
    logic [31:0] a;
    logic [31:0] b;
    logic signed_a;
    logic signed_b;
    logic [63:0] correction_a;
    logic [63:0] correction_b;
    logic [63:0] correction_constant;
    assign a = integer_payload.source_1;
    assign b = integer_payload.source_2;
    assign correction_a = {({32{signed_a && a[31]}} & ~b), 32'b0};
    assign correction_b = {({32{signed_b && b[31]}} & ~a), 32'b0};
    assign signed_a = multiply_payload.operation == MUL_HIGH_SS || multiply_payload.operation == MUL_HIGH_SU;
    assign signed_b = multiply_payload.operation == MUL_HIGH_SS;
    assign correction_constant = ({63'b0, signed_a && a[31]} << 32) +
        ({63'b0, signed_b && b[31]} << 32);
    logic [63:0] partial_products [0:34];
    for (genvar i = 0; i < 32; i++) begin : gen_pp
        assign partial_products[i] = b[i]
            ? {{32-i{1'b0}}, a, {i{1'b0}}}
            : 64'b0;
    end
    assign partial_products[32] = correction_a;
    assign partial_products[33] = correction_b;
    assign partial_products[34] = correction_constant;
    
    // Compression pass 1: 35 rows to 24 rows.
    logic [63:0] compressed_products_1 [0:23];
    for (genvar i = 0; i < 11; i++) begin : gen_comp_1
        logic [63:0] x, y, z;
        assign x = partial_products[i*3];
        assign y = partial_products[i*3+1];
        assign z = partial_products[i*3+2];
        assign compressed_products_1[i*2] = x ^ y ^ z;
        assign compressed_products_1[i*2+1] = ((x & y) | (y & z) | (x & z)) << 1;
    end
    assign compressed_products_1[22] = partial_products[33];
    assign compressed_products_1[23] = partial_products[34];

    // Compression pass 2: 24 rows to 16 rows.
    logic [63:0] compressed_products_2 [0:15];
    for (genvar i = 0; i < 8; i++) begin : gen_comp_2
        logic [63:0] x, y, z;
        assign x = compressed_products_1[i*3];
        assign y = compressed_products_1[i*3+1];
        assign z = compressed_products_1[i*3+2];
        assign compressed_products_2[i*2] = x ^ y ^ z;
        assign compressed_products_2[i*2+1] = ((x & y) | (y & z) | (x & z)) << 1;
    end

    // Compression pass 3: 16 rows to 11 rows.
    logic [63:0] compressed_products_3 [0:10];
    for (genvar i = 0; i < 5; i++) begin : gen_comp_3
        logic [63:0] x, y, z;
        assign x = compressed_products_2[i*3];
        assign y = compressed_products_2[i*3+1];
        assign z = compressed_products_2[i*3+2];
        assign compressed_products_3[i*2] = x ^ y ^ z;
        assign compressed_products_3[i*2+1] = ((x & y) | (y & z) | (x & z)) << 1;
    end
    assign compressed_products_3[10] = compressed_products_2[15];

    // Compression pass 4: 11 rows to 8 rows.
    logic [63:0] compressed_products_4 [0:7];
    for (genvar i = 0; i < 3; i++) begin : gen_comp_4
        logic [63:0] x, y, z;
        assign x = compressed_products_3[i*3];
        assign y = compressed_products_3[i*3+1];
        assign z = compressed_products_3[i*3+2];
        assign compressed_products_4[i*2] = x ^ y ^ z;
        assign compressed_products_4[i*2+1] = ((x & y) | (y & z) | (x & z)) << 1;
    end
    assign compressed_products_4[6] = compressed_products_3[9];
    assign compressed_products_4[7] = compressed_products_3[10];

    // Compression pass 5: 8 rows to 6 rows.
    logic [63:0] compressed_products_5 [0:5];
    for (genvar i = 0; i < 2; i++) begin : gen_comp_5
        logic [63:0] x, y, z;
        assign x = compressed_products_4[i*3];
        assign y = compressed_products_4[i*3+1];
        assign z = compressed_products_4[i*3+2];
        assign compressed_products_5[i*2] = x ^ y ^ z;
        assign compressed_products_5[i*2+1] = ((x & y) | (y & z) | (x & z)) << 1;
    end
    assign compressed_products_5[4] = compressed_products_4[6];
    assign compressed_products_5[5] = compressed_products_4[7];

    // Compression pass 6: 6 rows to 4 rows.
    logic [63:0] compressed_products_6 [0:3];
    for (genvar i = 0; i < 2; i++) begin : gen_comp_6
        logic [63:0] x, y, z;
        assign x = compressed_products_5[i*3];
        assign y = compressed_products_5[i*3+1];
        assign z = compressed_products_5[i*3+2];
        assign compressed_products_6[i*2] = x ^ y ^ z;
        assign compressed_products_6[i*2+1] = ((x & y) | (y & z) | (x & z)) << 1;
    end

    // Step 8: Calculate Final Addition
    logic [63:0] product_vector [0:3];
    logic [63:0] sum;
    always_comb begin
        sum = 64'b0;
        for (int unsigned i = 0; i < 4; i++) begin
            sum = sum + product_vector[i];
        end
    end

    // One internal register; the lane registers the combinational result.
    MulOperation_ multiply_payload_step_2;
    logic valid_step_2;
    assign result = multiply_payload_step_2 == MUL_LOW ? sum[31:0] : sum[63:32];
    assign valid_out = valid_step_2;
    // Feed this request back through the lane's shared stall. The result is
    // consumed on the next edge, which also clears valid_step_2 while stalled.
    assign iteration_stall = (UNROLL_CUTOFF == 1) && valid_step_2;

    always_ff @(posedge clk) begin
        if (reset) valid_step_2 <= 1'b0;
        else if (!stall) valid_step_2 <= valid_in && !flush;
        // The lane consumes this result while iterating. Retire its valid
        // after that edge so held operands cannot produce duplicate results.
        else if (UNROLL_CUTOFF == 1) valid_step_2 <= 1'b0;

        if (!stall) begin
            multiply_payload_step_2 <= multiply_payload.operation;
            product_vector <= compressed_products_6;
        end
    end

endmodule

// inputs, raw pipeline, outputs for all modules like this.
// outputs should be fixed latency for now
// outputs can be random latency, but they need to carry a
// tag corresponding to the instruction and the lane needs
// to maintain ordering. 
