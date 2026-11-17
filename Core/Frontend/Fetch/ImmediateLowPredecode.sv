module ImmediateLowPredecode #(
    parameter unsigned SUPPORT_FLOAT = 1
)(
    input logic [31:0] instruction,
    input logic is_compressed,
    output logic [4:0] immediate_low
);
    wire [15:0] c = instruction[15:0];
    wire [20:1] c_jump_offset = {{9{c[12]}}, c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3]};
    wire [12:1] c_branch_offset = {{4{c[12]}}, c[12], c[6:5], c[2], c[11:10], c[4:3]};
    wire [4:0] immediate_format_in;
    ImmediateFormatPredecode #(.SUPPORT_FLOAT(SUPPORT_FLOAT)) format_decode (
        .instruction(instruction), .is_compressed(is_compressed), .format_out(immediate_format_in)
    );
    logic [31:0] immediate_direct;
    always_comb begin
        immediate_direct = 'x;
        case (immediate_format_in)
            5'd2: immediate_direct = {22'd0, c[10:7], c[12:11], c[5], c[6], 2'd0};
            5'd3: immediate_direct = {25'd0, c[5], c[12:10], c[6], 2'd0};
            5'd4: immediate_direct = {{26{c[12]}}, c[12], c[6:2]};
            5'd5: immediate_direct = {{11{c_jump_offset[20]}}, c_jump_offset, 1'b0};
            5'd6: immediate_direct = {{22{c[12]}}, c[12], c[4:3], c[5], c[2], c[6], 4'd0};
            5'd7: immediate_direct = {{14{c[12]}}, c[12], c[6:2], 12'd0};
            5'd8: immediate_direct = {21'd0, c[10], 5'd0, c[6:2]};
            5'd9: immediate_direct = {{19{c_branch_offset[12]}}, c_branch_offset, 1'b0};
            5'd10: immediate_direct = {27'd0, c[6:2]};
            5'd11: immediate_direct = {24'd0, c[3:2], c[12], c[6:4], 2'd0};
            5'd12: immediate_direct = '0;
            5'd13: immediate_direct = {24'd0, c[8:7], c[12:9], 2'd0};
            5'd14: immediate_direct = {{20{instruction[31]}}, instruction[31:20]};
            5'd15: immediate_direct = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
            5'd16: immediate_direct = {{19{instruction[31]}}, instruction[31], instruction[7], instruction[30:25], instruction[11:8], 1'b0};
            5'd17: immediate_direct = {instruction[31:12], 12'b0};
            5'd18: immediate_direct = {{11{instruction[31]}}, instruction[31], instruction[19:12], instruction[20], instruction[30:21], 1'b0};
            5'd19: immediate_direct[4:0] = instruction[19:15];
            default: ;
        endcase
    end

    assign immediate_low = immediate_direct[4:0];
endmodule
