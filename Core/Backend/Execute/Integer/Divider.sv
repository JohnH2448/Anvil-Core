module Divider
    import Enumerations::*;
    import Definitions::*;
#(
    parameter logic [31:0] EXECUTION_UNROLL = 4,
    parameter logic [31:0] AUTO_PIPE = 3
)(
    input logic clk, 
    input logic reset, 
    input logic stall,
    input logic flush,
    input logic valid_in,

    input IntegerOperands_ integer_payload,
    input DecodeDiv_ div_payload,
    
    output logic [31:0] data,
    output logic valid_out,
    output logic iteration_stall
);
    localparam integer unsigned STAGES=(32+AUTO_PIPE-1)/AUTO_PIPE;
    // Register 0 is the magnitude latch at lane index 2. The lane's last
    // execution slot is index EXECUTION_UNROLL+1, hence this internal boundary.
    localparam integer unsigned ITERATION_INDEX=EXECUTION_UNROLL-1;
    localparam integer unsigned CHOICES=1<<AUTO_PIPE;
    localparam integer unsigned MW=32+AUTO_PIPE;
    if (AUTO_PIPE<1 || AUTO_PIPE>4) begin : invalid_configuration
        initial $fatal(1,"DividerParallel AUTO_PIPE must be in 1..4");
    end

    logic signed_op, neg_a, neg_b;
    logic [31:0] a_magnitude, b_magnitude;
    logic negative_q, negative_r, remainder_op;
    logic magnitude_valid;
    always_ff @(posedge clk) begin
        if (reset) magnitude_valid <= 1'b0;
        // Match the lane's first execution latch; flush is replayed on stall.
        else if (!stall) magnitude_valid <= valid_in && !flush;
        // The free-running tail may consume a held stage once, then bubbles.
        else if (1>ITERATION_INDEX) magnitude_valid <= 1'b0;
    end
    assign signed_op = div_payload.operation==DIV_SIGNED || div_payload.operation==REM_SIGNED;
    assign neg_a = signed_op && integer_payload.source_1[31];
    assign neg_b = signed_op && integer_payload.source_2[31];
    always_ff @(posedge clk) begin
        if (!stall) begin
            a_magnitude <= neg_a ? -integer_payload.source_1 : integer_payload.source_1;
            b_magnitude <= neg_b ? -integer_payload.source_2 : integer_payload.source_2;
            negative_q <= (neg_a ^ neg_b) && integer_payload.source_2!=0;
            negative_r <= neg_a;
            remainder_op <= div_payload.operation==REM_SIGNED || div_payload.operation==REM_UNSIGNED;
        end
    end

    logic [MW-1:0] multiple [0:STAGES-1][0:CHOICES-1];
    logic [31:0] dividend [0:STAGES-1], quotient [0:STAGES-1], remainder_value [0:STAGES-1];
    logic q_neg [0:STAGES-1], r_neg [0:STAGES-1], rem_op [0:STAGES-1];
    logic stage_valid [0:STAGES-1];
    // Occupancy from the iteration boundary through the output. Feed this
    // request back through the lane stall to hold all upstream instructions.
    // Including the last valid keeps stall asserted through result capture.
    always_comb begin
        iteration_stall = 1'b0;
        if (ITERATION_INDEX == 0) iteration_stall |= magnitude_valid;
        for (int unsigned i = 0; i<STAGES; i++) begin
            if (i+1 >= ITERATION_INDEX) iteration_stall |= stage_valid[i];
        end
    end
    assign valid_out = stage_valid[STAGES-1];
    logic [31:0] final_quotient, final_remainder;
    always_ff @(posedge clk) begin
        if (reset) stage_valid[0] <= 1'b0;
        else if (!stall || 1>ITERATION_INDEX) stage_valid[0] <= magnitude_valid;
        else if (2>ITERATION_INDEX) stage_valid[0] <= 1'b0;
    end
    // Carry-save construction of k*D avoids cascading adders for 7D/11D/13D/15D.
    for (genvar k=0;k<CHOICES;k++) begin : prepare_multiple
        wire [MW-1:0] p0 = ((k & 1) != 0) ? MW'(b_magnitude) : '0;
        wire [MW-1:0] p1 = ((k & 2) != 0) ? MW'(b_magnitude)<<1 : '0;
        wire [MW-1:0] p2 = ((k & 4) != 0) ? MW'(b_magnitude)<<2 : '0;
        wire [MW-1:0] p3 = ((k & 8) != 0) ? MW'(b_magnitude)<<3 : '0;
        wire [MW-1:0] sum0=p0 ^ p1 ^ p2;
        wire [MW-1:0] carry0=((p0&p1) | (p0&p2) | (p1&p2))<<1;
        wire [MW-1:0] sum1=sum0 ^ carry0 ^ p3;
        wire [MW-1:0] carry1=((sum0&carry0) | (sum0&p3) | (carry0&p3))<<1;
        always_ff @(posedge clk) begin
            if (!stall || 1>ITERATION_INDEX)
                multiple[0][k] <= sum1+carry1;
        end
    end
    always_ff @(posedge clk) begin
        if (!stall || 1>ITERATION_INDEX) begin
            dividend[0]<=a_magnitude;
            quotient[0]<='0;
            remainder_value[0]<='0;
            q_neg[0]<=negative_q;
            r_neg[0]<=negative_r;
            rem_op[0]<=remainder_op;
        end
    end

    for (genvar s=0;s<STAGES;s++) begin : stage
        localparam integer unsigned BITS=(32-s*AUTO_PIPE<AUTO_PIPE) ? 32-s*AUTO_PIPE : AUTO_PIPE;
        localparam integer unsigned N=s*AUTO_PIPE+BITS;
        localparam integer unsigned DIGITS=1<<BITS;
        logic [N-1:0] shifted;
        logic [N:0] trial [0:DIGITS-1];
        logic [DIGITS:0] ge;
        logic [DIGITS-1:0] choose;
        logic [N-1:0] rem_next;
        logic [BITS-1:0] digit_next;
        assign shifted=(N'(remainder_value[s])<<BITS) |
                       N'(dividend[s][31-s*AUTO_PIPE -: BITS]);
        assign trial[0]={1'b0,shifted};
        assign ge[0]=1'b1;
        assign ge[DIGITS]=1'b0;
        for (genvar k=1;k<DIGITS;k++) begin : subtract
            assign trial[k]={1'b0,shifted}-{1'b0,multiple[s][k][N-1:0]};
            assign ge[k]=~trial[k][N] && !(|multiple[s][k][MW-1:N]);
        end
        for (genvar k=0;k<DIGITS;k++) begin : select_digit
            assign choose[k]=ge[k] && !ge[k+1];
        end
        // Adjacent comparison flags produce a one-hot select, avoiding a
        // priority mux chain across all candidate quotient digits.
        always_comb begin
            rem_next='0;
            digit_next='0;
            for (int unsigned k = 0;k<DIGITS;k++) begin
                rem_next |= trial[k][N-1:0] & {N{choose[k]}};
                digit_next |= BITS'(k) & {BITS{choose[k]}};
            end
        end
        if (s == STAGES-1) begin : final_combinational
            // Final quotient digit, sign correction and selection feed the
            // lane's output register directly, with no final register here.
            assign final_quotient = (quotient[s]<<BITS) | 32'(digit_next);
            assign final_remainder = 32'(rem_next);
        end else begin : registered_stage
            always_ff @(posedge clk) begin
                if (reset) stage_valid[s+1] <= 1'b0;
                else if (!stall || s+2>ITERATION_INDEX) stage_valid[s+1] <= stage_valid[s];
                // Clear the held boundary after its downstream stage consumes it.
                else if (s+3>ITERATION_INDEX) stage_valid[s+1] <= 1'b0;
            end
            always_ff @(posedge clk) begin
                if (!stall || s+2>ITERATION_INDEX) begin
                    for (int unsigned k = 0;k<CHOICES;k++) multiple[s+1][k]<=multiple[s][k];
                    dividend[s+1]<=dividend[s];
                    quotient[s+1]<=(quotient[s]<<BITS) | 32'(digit_next);
                    remainder_value[s+1]<=32'(rem_next);
                    q_neg[s+1]<=q_neg[s];
                    r_neg[s+1]<=r_neg[s];
                    rem_op[s+1]<=rem_op[s];
                end
            end
        end
    end
    wire [31:0] corrected_q=q_neg[STAGES-1] ? -final_quotient : final_quotient;
    wire [31:0] corrected_r=r_neg[STAGES-1] ? -final_remainder : final_remainder;
    assign data=rem_op[STAGES-1] ? corrected_r : corrected_q;
endmodule

