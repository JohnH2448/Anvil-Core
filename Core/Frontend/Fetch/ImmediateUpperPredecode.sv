module ImmediateUpperPredecode #(
    parameter unsigned SUPPORT_FLOAT = 1
)(
    input logic [31:0] instruction,
    input logic is_compressed,
    output logic [13:0] upper_select
);
    wire [4:0] format_code;
    ImmediateFormatPredecode #(.SUPPORT_FLOAT(SUPPORT_FLOAT)) format_decode (
        .instruction(instruction), .is_compressed(is_compressed), .format_out(format_code)
    );
    assign upper_select[0] = format_code == 5'd2;
    assign upper_select[1] = format_code == 5'd3;
    assign upper_select[2] = format_code == 5'd4;
    assign upper_select[3] = format_code == 5'd5;
    assign upper_select[4] = format_code == 5'd6;
    assign upper_select[5] = format_code == 5'd7;
    assign upper_select[6] = format_code == 5'd8;
    assign upper_select[7] = format_code == 5'd9;
    assign upper_select[8] = format_code == 5'd11;
    assign upper_select[9] = format_code == 5'd13;
    assign upper_select[10] = format_code == 5'd14 || format_code == 5'd15;
    assign upper_select[11] = format_code == 5'd16;
    assign upper_select[12] = format_code == 5'd17;
    assign upper_select[13] = format_code == 5'd18;
endmodule
