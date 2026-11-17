module ImmediateFormatPredecode #(
    parameter unsigned SUPPORT_FLOAT = 1
)(
    input logic [31:0] instruction,
    input logic is_compressed,
    output logic [4:0] format_out
);
    wire [15:0] c = instruction[15:0];
    always_comb begin
        format_out = 5'd0;
        if (is_compressed) begin
            case (c[1:0])
                2'b00: begin
                    case (c[15:13])
                        3'b000: format_out = 5'd2;
                        3'b010, 3'b110: format_out = 5'd3;
                        3'b011, 3'b111: if (SUPPORT_FLOAT)
                            format_out = 5'd3;
                        default: ;
                    endcase
                end
                2'b01: begin
                    case (c[15:13])
                        3'b000, 3'b010: format_out = 5'd4;
                        3'b001, 3'b101: format_out = 5'd5;
                        3'b011: begin
                            if (c[11:7] == 5'd2)
                                format_out = 5'd6;
                            else format_out = 5'd7;
                        end
                        3'b100: begin
                            case (c[11:10])
                                2'b00, 2'b01: format_out = 5'd8;
                                2'b10: format_out = 5'd4;
                                default: ;
                            endcase
                        end
                        3'b110, 3'b111: format_out = 5'd9;
                    endcase
                end
                2'b10: begin
                    case (c[15:13])
                        3'b000: format_out = 5'd10;
                        3'b010: format_out = 5'd11;
                        3'b011: if (SUPPORT_FLOAT)
                            format_out = 5'd11;
                        3'b100: if (c[6:2] == 0) format_out = 5'd12; // JR/JALR offset
                        3'b110: format_out = 5'd13;
                        3'b111: if (SUPPORT_FLOAT)
                            format_out = 5'd13;
                        default: ;
                    endcase
                end
                default: ;
            endcase
        end else begin
            case (instruction[6:0])
                7'b0010011, 7'b0000011, 7'b1100111:
                    format_out = 5'd14;
                7'b0000111: if (SUPPORT_FLOAT)
                    format_out = 5'd14;
                7'b0100011:
                    format_out = 5'd15;
                7'b0100111: if (SUPPORT_FLOAT)
                    format_out = 5'd15;
                7'b1100011:
                    format_out = 5'd16;
                7'b0110111, 7'b0010111: format_out = 5'd17;
                7'b1101111:
                    format_out = 5'd18;
                7'b1110011: if (instruction[14])
                    format_out = 5'd19; // CSR zimm
                default: ;
            endcase
        end
    end

endmodule
