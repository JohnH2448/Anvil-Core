// Parallel to branch prediction: system encoding/CSR policy only.
// Opcode and compressed qualification remain in InstructionLegality.
module SystemTrapPredecode
    import Enumerations::*;
#(parameter unsigned SUPPORT_FLOAT = 1)(
    input logic [31:0] instruction,
    output TrapType_ trap
);
    logic [2:0] funct3;
    logic [11:0] address;
    logic csr_legal, csr_read_only, writes_csr;
    always_comb begin
        funct3 = instruction[14:12];
        address = instruction[31:20];
        csr_legal = 1'b1;
        csr_read_only = 1'b0;
        writes_csr = funct3[1:0] == 1 || instruction[19:15] != 0;
        // CSR whitelist for this M-mode-only core; every other address is
        // ILLEGAL (S/U-mode CSRs such as medeleg/mideleg/mcounteren/menvcfg,
        // PMP, Zihpm user counters, debug/trigger CSRs). The FP
        // CSRs are ILLEGAL too: mstatus.FS is hardwired Off. Read-only means
        // the address is in a read-only space (csr[11:10] == 2'b11); a write
        // attempt is ILLEGAL. Read-only-zero CSRs in writable space (mstatush,
        // mtval, mcountinhibit, mhpmevent3-31, mhpmcounter3-31(h)) ignore
        // writes in the serial lane.
        csr_read_only = address[11:10] == 2'b11;
        csr_legal = address inside {
            MVENDORID, MARCHID, MIMPID, MHARTID, MCONFIGPTR,
            MSTATUS, MISA, MIE, MTVEC, MSTATUSH,
            12'h320, [12'h323:12'h33F], // mcountinhibit, mhpmevent3-31
            MSCRATCH, MEPC, MCAUSE, MTVAL, MIP,
            MCYCLE, MINSTRET, [12'hB03:12'hB1F], // mhpmcounter3-31
            MCYCLEH, MINSTRETH, [12'hB83:12'hB9F], // mhpmcounter3h-31h
            12'hC00, 12'hC01, 12'hC02, // cycle, time, instret
            12'hC80, 12'hC81, 12'hC82 // cycleh, timeh, instreth
        };
        trap = NONE;
        if (funct3 == 0) begin
            case (instruction)
                32'h00000073: trap = ECALL;
                32'h00100073: trap = EBREAK;
                32'h30200073,32'h10500073: ;
                default: trap = ILLEGAL;
            endcase
        end else begin
            if (funct3 == 4 || !csr_legal || (csr_read_only && writes_csr)) trap = ILLEGAL;
        end
    end
endmodule
