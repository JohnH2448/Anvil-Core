module FrontendTop
    import DerivedParameters::*;
    import Definitions::*;
    import Enumerations::*;
#(
    parameter unsigned FETCH_WORDS = Parameters::CACHE_LINE_WORDS,
    parameter unsigned FIFO_WORDS = Parameters::FETCH_FIFO_WORDS,
    parameter unsigned ISSUE_WIDTH = Parameters::ISSUE_WIDTH,
    parameter unsigned EXECUTION_UNROLL = Parameters::EXECUTION_UNROLL,
    parameter unsigned BYPASS_ENABLED = Parameters::BYPASS_ENABLED,
    parameter unsigned RESET_VECTOR = Parameters::RESET_VECTOR
)(
    input logic clk,
    input logic reset,

    // Instruction fetch port to the shared RAM (via the system Crossbar).
    // One request per cycle; the response arrives the next cycle. A cycle
    // with fetch_valid low means the request was not served and Fetch
    // re-requests the same address.
    output logic fetch_request,
    output logic [31:0] fetch_address,
    input logic [FETCH_WORDS*32-1:0] fetch_data,
    input logic fetch_valid,
    input logic fetch_error,
    input logic [31:0] redirect_pc,
    input logic redirect_fetch, // Registered recovery launch; pulses with redirect_taken.
    input logic redirect_taken, // Registered recovery pulse.
    input logic [AGE_WIDTH-1:0] redirect_slot,
    input logic redirect_advanced, // Resolving group shifted once before recovery.
    input logic redirect_trap, // Trap recovery: also clears the whole producer table.
    input TrapType_ interrupt_request, // Pending enabled interrupt; Decode tags a valid instruction.
    input logic stall,
    input logic serial_active,

    output DecoderPacket_ decoder_packet [TOTAL_LANE_COUNT-1:0],
    output IssuerPacket_ issuer_packet [TOTAL_LANE_COUNT-1:0],
    output logic accept_vector [TOTAL_LANE_COUNT-1:0],
    // Registered operand-wait bits per producer slot; see Issue.
    output logic watch [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0]
);

    // Shared packet widths come from Parameters; reject inconsistent overrides.
    initial begin
        if (ISSUE_WIDTH != Parameters::ISSUE_WIDTH || EXECUTION_UNROLL != Parameters::EXECUTION_UNROLL)
            $fatal(1, "Configure issue width/unroll through Parameters to match shared packet widths");
        if (ISSUE_WIDTH < 1 || ISSUE_WIDTH > 2 || EXECUTION_UNROLL < 1)
            $fatal(1, "Frontend requires ISSUE_WIDTH 1..2 and EXECUTION_UNROLL >= 1");
        if (count_integer_lanes(0) == 0 || count_integer_lanes(1) == 0 || count_memory_lanes(0) == 0)
            $fatal(1, "Lane configuration must cover ALU, BRU and MEMORY; integer mask bits0/1 are ALU/BRU");
        if ((Parameters::SUPPORT_MUL && count_integer_lanes(2) == 0) ||
            (Parameters::SUPPORT_DIV && count_integer_lanes(3) == 0) ||
            (Parameters::SUPPORT_ATOMIC && count_memory_lanes(1) == 0))
            $fatal(1, "Enabled extension has no execution lane");
        if (Parameters::SUPPORT_FLOAT && (count_floating_lanes(0) == 0 ||
            count_floating_lanes(1) == 0 || count_memory_lanes(2) == 0))
            $fatal(1, "Floating support requires FP, conversion and floating memory capabilities");
        if (!Parameters::SUPPORT_FLOAT && Parameters::FLOATING_LANE_COUNT != 0)
            $fatal(1, "Set FLOATING_LANE_COUNT=0 when floating support is disabled");
    end

    // Raw frontend outputs terminate at representative backend input registers.
    DecoderPacket_ dispatch_packet [TOTAL_LANE_COUNT-1:0];
    IssuerPacket_ dispatch_issuer [TOTAL_LANE_COUNT-1:0];
    logic dispatch_accept [TOTAL_LANE_COUNT-1:0];
    logic dispatch_watch [TOTAL_LANE_COUNT-1:0][EXECUTION_UNROLL:0];

    logic [31:0] serve_data_reg [ISSUE_WIDTH-1:0];
    logic [4:0] serve_rs1 [ISSUE_WIDTH-1:0];
    logic [4:0] serve_rs2 [ISSUE_WIDTH-1:0];
    logic [4:0] serve_rd [ISSUE_WIDTH-1:0];
    logic [4:0] serve_rs3 [ISSUE_WIDTH-1:0];
    logic serve_rs1_float [ISSUE_WIDTH-1:0];
    logic serve_rs2_float [ISSUE_WIDTH-1:0];
    logic serve_rs3_float [ISSUE_WIDTH-1:0];
    logic serve_rd_float [ISSUE_WIDTH-1:0];
    logic serve_rs1_used [ISSUE_WIDTH-1:0];
    logic serve_rs2_used [ISSUE_WIDTH-1:0];
    logic serve_rd_written [ISSUE_WIDTH-1:0];
    logic [$bits(DecodeCapability_)-1:0] serve_capability [ISSUE_WIDTH-1:0];
    logic [6:0] serve_immediate_upper_select [ISSUE_WIDTH-1:0];
    logic serve_fp_consumer [ISSUE_WIDTH-1:0];
    TrapType_ serve_trap [ISSUE_WIDTH-1:0];
    DerivedParameters::fetch_pc_t serve_pc_reg [ISSUE_WIDTH-1:0];
    logic serve_valid_reg [ISSUE_WIDTH-1:0];
    logic serve_c_reg [ISSUE_WIDTH-1:0];
    logic serve_taken_reg [ISSUE_WIDTH-1:0];
    logic serve_branch_reg [ISSUE_WIDTH-1:0];
    logic [$clog2(ISSUE_WIDTH+1)-1:0] serve_normal_count;

    FetchTop #(
        .FETCH_WORDS(FETCH_WORDS),
        .FIFO_WORDS(FIFO_WORDS),
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .RESET_VECTOR(RESET_VECTOR)
    ) fetch (
        .clk(clk),
        .reset(reset),
        .fetch_request, .fetch_address, .fetch_data, .fetch_valid, .fetch_error,
        .redirect_fetch(redirect_fetch),
        .redirect_pc(redirect_pc),
        .redirect_taken(redirect_taken),
        .serve_data_reg(serve_data_reg),
        .serve_rs1(serve_rs1),
        .serve_rs2(serve_rs2),
        .serve_rd(serve_rd),
        .serve_rs3(serve_rs3),
        .serve_rs1_float(serve_rs1_float),
        .serve_rs2_float(serve_rs2_float),
        .serve_rs3_float(serve_rs3_float),
        .serve_rd_float(serve_rd_float),
        .serve_rs1_used(serve_rs1_used),
        .serve_rs2_used(serve_rs2_used),
        .serve_rd_written(serve_rd_written),
        .serve_capability(serve_capability),
        .serve_immediate_upper_select(serve_immediate_upper_select),
        .serve_fp_consumer(serve_fp_consumer),
        .serve_trap(serve_trap),
        .serve_pc_reg(serve_pc_reg),
        .serve_valid_reg(serve_valid_reg),
        .serve_c_reg(serve_c_reg),
        .serve_taken_reg(serve_taken_reg),
        .serve_branch_reg(serve_branch_reg),
        .stall(stall),
        .serve_normal_count(serve_normal_count)
    );

    DispatchTop #(
        .ISSUE_WIDTH(ISSUE_WIDTH),
        .EXECUTION_UNROLL(EXECUTION_UNROLL),
        .BYPASS_ENABLED(BYPASS_ENABLED)
    ) dispatch (
        .clk(clk),
        .reset(reset),
        .redirect_taken(redirect_taken),
        .redirect_slot(redirect_slot),
        .redirect_advanced(redirect_advanced),
        .redirect_trap(redirect_trap),
        .interrupt_request,
        .stall(stall),
        .serial_active(serial_active),
        .serve_data_reg(serve_data_reg),
        .serve_rs1(serve_rs1),
        .serve_rs2(serve_rs2),
        .serve_rd(serve_rd),
        .serve_rs3(serve_rs3),
        .serve_rs1_float(serve_rs1_float),
        .serve_rs2_float(serve_rs2_float),
        .serve_rs3_float(serve_rs3_float),
        .serve_rd_float(serve_rd_float),
        .serve_rs1_used(serve_rs1_used),
        .serve_rs2_used(serve_rs2_used),
        .serve_rd_written(serve_rd_written),
        .serve_capability(serve_capability),
        .serve_immediate_upper_select(serve_immediate_upper_select),
        .serve_fp_consumer(serve_fp_consumer),
        .serve_trap(serve_trap),
        .serve_pc_reg(serve_pc_reg),
        .serve_valid_reg(serve_valid_reg),
        .serve_c_reg(serve_c_reg),
        .serve_taken_reg(serve_taken_reg),
        .serve_branch_reg(serve_branch_reg),
        .serve_normal_count(serve_normal_count),
        .decoder_packet(dispatch_packet),
        .issuer_packet(dispatch_issuer),
        .accept_vector(dispatch_accept),
        .watch(dispatch_watch)
    );

    // Lane order matches Dispatch/actual backend generation: serial, integer,
    // memory, floating. This models consumption only, not execution or readiness.
    for (genvar lane = 0; lane < TOTAL_LANE_COUNT; lane++) begin : lane_inputs
        localparam bit SERIAL = lane == 0;
        localparam bit INTEGER_LANE = lane >= 1 && lane < 1 + Parameters::INTEGER_LANE_COUNT;
        localparam bit MEMORY_LANE = lane >= 1 + Parameters::INTEGER_LANE_COUNT &&
            lane < 1 + Parameters::INTEGER_LANE_COUNT + Parameters::MEMORY_LANE_COUNT;
        localparam bit FLOATING_LANE = lane >= 1 + Parameters::INTEGER_LANE_COUNT + Parameters::MEMORY_LANE_COUNT;
        // Generate-time guards avoid indexing capability arrays for other banks.
        DecoderPacket_ consumed_packet;
        IssuerPacket_ consumed_issuer;
        if (SERIAL) begin : serial_lane
            always_comb begin
                consumed_packet = 'x;
                consumed_packet.common = dispatch_packet[lane].common;
                consumed_packet.common.fp_consumer = 'x;
                consumed_packet.common.next_pc = 'x;
                consumed_packet.system = dispatch_packet[lane].system;
                consumed_packet.csr = dispatch_packet[lane].csr;
            end
        end else if (INTEGER_LANE) begin : integer_lane
            localparam logic [3:0] CAPS = DerivedParameters::EFFECTIVE_INTEGER_CAPS[lane-1];
            always_comb begin
                consumed_packet = 'x;
                consumed_packet.common = dispatch_packet[lane].common;
                consumed_packet.common.fp_consumer = 'x;
                consumed_packet.common.next_pc = 'x;
                consumed_packet.common.rs1_float = 'x;
                consumed_packet.common.rs2_float = 'x;
                consumed_packet.common.rd_float = 'x;
                if (CAPS[0]) consumed_packet.alu = dispatch_packet[lane].alu;
                if (CAPS[1]) consumed_packet.bru = dispatch_packet[lane].bru;
                if (CAPS[2] && Parameters::SUPPORT_MUL)
                    consumed_packet.mul = dispatch_packet[lane].mul;
                if (CAPS[3] && Parameters::SUPPORT_DIV)
                    consumed_packet.div = dispatch_packet[lane].div;
            end
        end else if (MEMORY_LANE) begin : memory_lane
            localparam logic [2:0] CAPS = DerivedParameters::EFFECTIVE_MEMORY_CAPS[
                lane-1-Parameters::INTEGER_LANE_COUNT];
            always_comb begin
                consumed_packet = 'x;
                consumed_packet.common = dispatch_packet[lane].common;
                consumed_packet.common.fp_consumer = 'x;
                consumed_packet.common.next_pc = 'x;
                if (CAPS[0] || (CAPS[2] && Parameters::SUPPORT_FLOAT))
                    consumed_packet.memory = dispatch_packet[lane].memory;
                if (CAPS[1] && Parameters::SUPPORT_ATOMIC) begin
                    consumed_packet.atomic = dispatch_packet[lane].atomic;
                    consumed_packet.memory.size = dispatch_packet[lane].memory.size;
                end
                if (!CAPS[2] || !Parameters::SUPPORT_FLOAT) begin
                    consumed_packet.common.rs1_float = 'x;
                    consumed_packet.common.rs2_float = 'x;
                    consumed_packet.common.rd_float = 'x;
                end
            end
        end else if (FLOATING_LANE) begin : floating_lane
            localparam logic [1:0] CAPS = DerivedParameters::EFFECTIVE_FLOATING_CAPS[
                lane-1-Parameters::INTEGER_LANE_COUNT-Parameters::MEMORY_LANE_COUNT];
            always_comb begin
                consumed_packet = 'x;
                consumed_packet.common = dispatch_packet[lane].common;
                consumed_packet.common.fp_consumer = 'x;
                consumed_packet.common.next_pc = 'x;
                consumed_packet.common.immediate = 'x;
                if (CAPS[0] && Parameters::SUPPORT_FLOAT)
                    consumed_packet.fp = dispatch_packet[lane].fp;
                if (CAPS[1] && Parameters::SUPPORT_FLOAT)
                    consumed_packet.fp_convert = dispatch_packet[lane].fp_convert;
            end
        end
        always_comb begin
            consumed_issuer = dispatch_issuer[lane];
            if (SERIAL) begin
                consumed_issuer = 'x;
                consumed_issuer.input_age = dispatch_issuer[lane].input_age;
            end else if (!BYPASS_ENABLED) begin
                consumed_issuer.use_bypass_1 = 'x;
                consumed_issuer.use_bypass_2 = 'x;
            end
        end
        always_ff @(posedge clk) begin
            if (reset || redirect_taken) begin
                accept_vector[lane] <= 1'b0;
                decoder_packet[lane] <= 'x;
                issuer_packet[lane] <= 'x;
            end else if (!stall) begin
                accept_vector[lane] <= dispatch_accept[lane];
                // Bubble payload is unobservable; late acceptance only sets valid.
                decoder_packet[lane] <= consumed_packet;
                issuer_packet[lane] <= consumed_issuer;
            end
        end
    end

    // Same capture rule as accept_vector: cleared by reset and flush, held by stall.
    always_ff @(posedge clk) begin
        for (int lane = 0; lane < TOTAL_LANE_COUNT; lane++)
            for (int index = 0; index <= EXECUTION_UNROLL; index++)
                if (reset || redirect_taken) watch[lane][index] <= 1'b0;
                else if (!stall) watch[lane][index] <= dispatch_watch[lane][index];
    end

endmodule
