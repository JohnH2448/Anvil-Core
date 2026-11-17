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
        case (address)
            MSTATUS, MTVEC, MIP, MIE, MCYCLE, MCYCLEH, MINSTRET,
            MINSTRETH, MSCRATCH, MEPC, MCAUSE, MISA: ;
            12'h001, 12'h002, 12'h003: csr_legal = SUPPORT_FLOAT != 0;
            MVENDORID, MARCHID, MIMPID, MHARTID, MCONFIGPTR,
            MEDELEG, MIDELEG, MCOUNTEREN, MSTATUSH, MTVAL: csr_read_only = 1'b1;
            default: begin
                csr_read_only = 1'b1;
                csr_legal = (address >= 12'hB03 && address <= 12'hB1F) ||
                    (address >= 12'hB83 && address <= 12'hB9F) ||
                    (address >= 12'h323 && address <= 12'h33F);
            end
        endcase
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
