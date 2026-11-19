module ImmediateUpperPredecode #(
    parameter unsigned SUPPORT_FLOAT = 1
)(
    input logic [31:0] instruction,
    input logic is_compressed,
    output logic [6:0] upper_select
);
    wire [15:0] c = instruction[15:0];
    wire q0 = is_compressed && c[1:0] == 0;
    wire q1 = is_compressed && c[1:0] == 1;
    wire q1_math = q1 && c[15:13] == 4;

    assign upper_select[0] = q0 && c[15:13] == 0;
    assign upper_select[1] = q0 && ((c[15:13] inside {3'd2, 3'd6}) ||
        (SUPPORT_FLOAT && (c[15:13] inside {3'd3, 3'd7})));
    assign upper_select[2] = (q1 && (c[15:13] inside {3'd0, 3'd2})) ||
        (q1_math && c[11:10] == 2);
    assign upper_select[3] = q1 && (c[15:13] inside {3'd1, 3'd5});
    assign upper_select[4] = q1 && c[15:13] == 3 && c[11:7] == 2;
    assign upper_select[5] = q1 && c[15:13] == 3 && c[11:7] != 2;
    assign upper_select[6] = q1_math && !c[11];
endmodule
