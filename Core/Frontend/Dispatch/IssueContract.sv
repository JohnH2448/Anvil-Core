module IssueContract
    import Parameters::*;
    import DerivedParameters::*;
    import Enumerations::*;
    import Definitions::*;
(
    // Input Metadata
    input LaneType_ lane_types [ISSUE_WIDTH-1:0],
    input logic packets_valid [ISSUE_WIDTH-1:0],
    input logic group_raw [ISSUE_WIDTH-1:0],
    input logic group_resource_bad [ISSUE_WIDTH-1:0],
    input logic operands_ready [ISSUE_WIDTH-1:0],
    input logic serial_active,

    // Valid to Issue
    output logic issue_good [ISSUE_WIDTH-1:0]
);

    // Combined + Masked Authoritative Goods
    logic issue_good_internal [ISSUE_WIDTH-1:0];

    // Cause Specific Per Index
    logic bad_raw [ISSUE_WIDTH-1:0];
    logic bad_valid [ISSUE_WIDTH-1:0];
    logic bad_execution_unit [ISSUE_WIDTH-1:0];
    logic bad_serial [ISSUE_WIDTH-1:0];

    // Decode latches same-group hazards alongside the selected FIFO packets.
    assign bad_raw = group_raw;

    // Valid Check
    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            bad_valid[i] = !packets_valid[i];
        end
    end

    // Operand readiness/bypass already includes the newly captured write buffer,
    // evaluated by Decode for the actual accepted-prefix outcome.

    // Static resource feasibility is registered with the Decode group.
    assign bad_execution_unit = group_resource_bad;

    // Only live serial occupancy remains in this stage; pair conflicts were
    // covered by the distinct-lane check.
    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            bad_serial[i] = serial_active && (lane_types[i] == SERIAL);
        end
    end

    // Final Acceptance Mask Build
    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH; i++) begin
            issue_good_internal[i] = !(!operands_ready[i] || bad_raw[i] ||
                bad_valid[i] || bad_execution_unit[i] ||
                bad_serial[i]);
        end
    end 

    always_comb begin
        logic prefix_good;
        prefix_good = 1'b1;
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            prefix_good = prefix_good && issue_good_internal[i];
            issue_good[i] = prefix_good;
        end
    end


endmodule

// Live serial occupancy remains dynamic. All other eligibility inputs are
// registered with the packet; acceptance remains an oldest-first prefix.
