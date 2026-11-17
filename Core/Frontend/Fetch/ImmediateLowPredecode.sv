module ImmediateLowPredecode #(
    parameter unsigned SUPPORT_FLOAT = 1
)(
    input logic [31:0] instruction,
    input logic is_compressed,
    output logic [4:0] immediate_low
);
    wire [15:0] c = instruction[15:0];
    wire [6:0] op = instruction[6:0];
    // Direct, mutually exclusive encoding predicates. No intermediate format
    // number is encoded and decoded again before selecting these five bits.
    wire q0 = is_compressed && c[1:0] == 2'b00;
    wire q1 = is_compressed && c[1:0] == 2'b01;
    wire q2 = is_compressed && c[1:0] == 2'b10;
    wire c_add4spn = q0 && c[15:13] == 3'b000;
    wire c_mem = q0 && ((c[15:13] inside {3'b010,3'b110}) ||
        (SUPPORT_FLOAT && (c[15:13] inside {3'b011,3'b111})));
    // ADDI/LI/ANDI and compressed shifts share the same low-bit wiring.
    wire c_low = (q1 && ((c[15:13] inside {3'b000,3'b010}) ||
        (c[15:13] == 3'b100 && c[11:10] != 2'b11))) ||
        (q2 && c[15:13] == 3'b000);
    wire c_jump = q1 && (c[15:13] inside {3'b001,3'b101});
    wire c_add16sp = q1 && c[15:13] == 3'b011 && c[11:7] == 5'd2;
    wire c_lui = q1 && c[15:13] == 3'b011 && c[11:7] != 5'd2;
    wire c_branch = q1 && (c[15:13] inside {3'b110,3'b111});
    wire c_loadsp = q2 && (c[15:13] == 3'b010 || (SUPPORT_FLOAT && c[15:13] == 3'b011));
    wire c_storesp = q2 && (c[15:13] == 3'b110 || (SUPPORT_FLOAT && c[15:13] == 3'b111));
    wire c_jr = q2 && c[15:13] == 3'b100 && c[6:2] == 0;
    wire full_i = !is_compressed && ((op inside {7'b0010011,7'b0000011,7'b1100111}) ||
        (SUPPORT_FLOAT && op == 7'b0000111));
    wire full_s = !is_compressed && (op == 7'b0100011 || (SUPPORT_FLOAT && op == 7'b0100111));
    wire full_b = !is_compressed && op == 7'b1100011;
    wire full_u = !is_compressed && (op inside {7'b0110111,7'b0010111});
    wire full_j = !is_compressed && op == 7'b1101111;
    wire full_zimm = !is_compressed && op == 7'b1110011 && instruction[14];

    // Spell out each produced bit; unused encodings remain don't-care.
    wire [4:0] add4_bits = {c[11],c[5],c[6],2'b00};
    wire [4:0] mem_bits = {c[11:10],c[6],2'b00};
    wire [4:0] jump_bits = {c[11],c[5:3],1'b0};
    wire [4:0] branch_bits = {c[11:10],c[4:3],1'b0};
    wire [4:0] add16_bits = {c[6],4'b0000};
    wire [4:0] loadsp_bits = {c[6:4],2'b00};
    wire [4:0] storesp_bits = {c[11:9],2'b00};
    wire [4:0] branch_full_bits = {instruction[11:8],1'b0};
    wire [4:0] jump_full_bits = {instruction[24:21],1'b0};
    for (genvar bit_id = 0; bit_id < 5; bit_id++) begin : bits_out
        always_comb begin
            immediate_low[bit_id] = 1'bx;
            unique case (1'b1)
                c_add4spn: immediate_low[bit_id] = add4_bits[bit_id];
                c_mem: immediate_low[bit_id] = mem_bits[bit_id];
                c_low: immediate_low[bit_id] = c[bit_id+2];
                c_jump: immediate_low[bit_id] = jump_bits[bit_id];
                c_add16sp: immediate_low[bit_id] = add16_bits[bit_id];
                c_lui, c_jr, full_u: immediate_low[bit_id] = 1'b0;
                c_branch: immediate_low[bit_id] = branch_bits[bit_id];
                c_loadsp: immediate_low[bit_id] = loadsp_bits[bit_id];
                c_storesp: immediate_low[bit_id] = storesp_bits[bit_id];
                full_i: immediate_low[bit_id] = instruction[bit_id+20];
                full_s: immediate_low[bit_id] = instruction[bit_id+7];
                full_b: immediate_low[bit_id] = branch_full_bits[bit_id];
                full_j: immediate_low[bit_id] = jump_full_bits[bit_id];
                full_zimm: immediate_low[bit_id] = instruction[bit_id+15];
            endcase
        end
    end
endmodule
