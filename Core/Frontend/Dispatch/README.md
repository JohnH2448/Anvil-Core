# Decoder

## Decode queue

`Decode.sv` defines `DecodeStage`, an ISSUE_WIDTH-entry queue of decoded
packets. Issue pops a binary count of consecutive valid packets from lane zero.
The queue retains the remaining packets and accepts up to the smaller of the
space available after the pop and the number of valid Fetch inputs. Fetch and
Decode validity must form contiguous prefixes beginning at lane zero.

`serve_consumed` reports exactly the number of Fetch packets accepted on the
next clock edge. Reset and redirect clear Decode validity and suppress Fetch
consumption. The producer must also flush or replace its stale Fetch entries
as part of redirect handling. `DecoderPacket_.bru.predicted_taken` preserves the
Fetch prediction alongside the decoded instruction and PC.

Issue must never consume more packets than Decode holds; its count is used
directly without a hardware clamp. Fetch registers a candidate serve window and
FIFO head/occupancy for every possible consumption count, alongside the actual
consumption selector. Decode counts validity from the selected window directly,
keeping it aligned with the selected payload without another cycle of latency.
Decode maintains a registered empty-slot count from actual pops and accepted inputs. Both counts
use `$clog2(ISSUE_WIDTH+1)` bits. Reset is held through the following registered reset cycle; redirects clear
the queue on the redirect edge. Parallel fixed-source selection retains and appends packets in order at all widths. No register is added to the
Issue pop signal.

### Producer metadata

`RegisterSlice` extracts rs1/rs2 directly from the Fetch instruction, including
compressed mappings. These addresses read `ProducerTable` during decode.
Each decoded packet carries parallel registered source index, countdown, lane,
and capability arrays into issue. Those arrays follow the same FIFO retain/refill
selection as the packet, including an upper entry shifting into slot zero.

A producer index advances toward `EXECUTION_UNROLL + 2` (the register file),
and its countdown decreases toward zero. Both advance only when global `stall`
is clear; waiting in the decode FIFO alone does not freeze them. Fresh table
reads also receive that edge's advancement. Reset/redirect invalidate the packet
FIFO; packet and producer payloads become unspecified during a flush.
Normal FIFO candidates are calculated independently of redirect. Fixed-source
producer updates precede parallel retain/refill selection; only validity and
outward-facing consumption require defined flush values.

Accepted integer writes from issue feed both the table and decode. Matching
older writes replace a packet's source metadata with index zero, the initial
countdown, lane, and capability. Later issue slots win multiple matching writes.
Fresh refills can match any accepted write; retained packets only match writers
older than their original FIFO position. A new allocation is not advanced on
its allocation edge. `Definitions::producer_countdown` supplies the same initial
countdown to decode and the table, including the physical-stage clamp for MUL/DIV.
Issue consumes this registered metadata directly; there is no recent-write buffer.

`IssueContract` has no stall or redirect inputs. Readiness and normal lane
allocation are independent of both controls. Issuer directly forces the final
`accept_vector` and `issue_consumed` to zero on stall or redirect. Backend
input registers and producer-table state also retain their local stall enables.
Decode can still refill empty FIFO slots, using unadvanced producer snapshots.

The current issuer supports widths one and two. Its readiness prefix and lane
allocator must agree on the consumed count. Same-group RAW dependencies prevent
a consumer from issuing alongside its producer; the write refresh supplies the
new producer when that consumer is retained.

This remains an integer producer table. Floating-register writes do not update
it; floating dependency tracking (including rs3) remains unimplemented. Producer
mapping restoration after backend redirects also remains unimplemented: the table
holds on redirect and needs a backend recovery protocol before full-core use.

`DecoderSlice.sv` accepts one raw RV32 instruction and emits a purely combinational
`Definitions::DecoderPacket_` plus a separate `LaneType_` routing tag. Its inputs
are `instruction`, `pc`, `is_branch`, `predicted_taken`, and `is_compressed`; it
has no clock or internal registers. With `is_compressed`
set, the low 16 instruction bits are decoded as RV32C. `is_branch` is fetch
metadata, not a condition for recognizing branches. Dispatch owns validity and
scheduling tags.

The module decodes full-width and compressed controls in independent logic
cones, then selects the completed packet. Compressed controls and immediates
come directly from their 16-bit fields; canonical expansion is retained only
for packet register-number compatibility. Full-width legality checks clear
controls within each opcode class instead of broadcasting a combined trap
signal across all execution controls. Constant parameter guards remove
unsupported extensions. Register boundaries are supplied by the caller. The packet is split into typed capability chunks described below.

| Parameter | Enabled decode |
| --- | --- |
| `SUPPORT_MUL` | MUL, MULH, MULHSU, MULHU |
| `SUPPORT_DIV` | DIV, DIVU, REM, REMU (independent of MUL) |
| `SUPPORT_FLOAT` | F, fused operations, floating CSRs, compressed floating memory operations |
| `SUPPORT_ATOMIC` | RV32 word LR/SC and AMOs, including acquire/release bits |

RV32I, RV32C integer operations, the project's machine CSR map, fences, ECALL,
EBREAK, MRET, and WFI are always decoded. Disabled extensions, reserved encodings,
and RV64-only forms produce `ILLEGAL`. Floating DIV/SQRT are controlled by F,
not the integer `SUPPORT_DIV` parameter. Hints decode as operations without an
architectural destination where appropriate.

## Capability chunks

`DecoderPacket_` is the complete decoder/dispatch payload. Execution units compose
smaller packed structs from the named chunk types in `Definitions.sv`:

| Member | Type | Contents / consumers |
| --- | --- | --- |
| `common` | `DecodeCommon_` | PC, fall-through PC, shared 32-bit immediate, capability tag, trap, rs1/rs2/rd indices, dependency/destination enables and register-bank flags; every lane |
| `alu` | `DecodeAlu_` | ALU operation and source selection |
| `bru` | `DecodeBru_` | Branch/jump operation, fetch branch/prediction metadata and compressed link length |
| `mul` | `DecodeMul_` | Two-bit low/high and signedness operation |
| `div` | `DecodeDiv_` | Two-bit quotient/remainder and signedness operation |
| `fp` | `DecodeFloat_` | Floating arithmetic/comparison operation, rounding and rs3 dependency |
| `fp_convert` | `DecodeFloatConvert_` | Numeric conversions, bit moves and classification; integer signedness and rounding |
| `memory` | `DecodeMemory_` | Load/store operation, size and load sign extension; atomic units also use size |
| `atomic` | `DecodeAtomic_` | LR/SC/AMO operation and acquire/release ordering |
| `system` | `DecodeSystem_` | Fence/MRET/WFI operation and fence masks |
| `csr` | `DecodeCsr_` | CSR index, operation, read/write intent and register/immediate selection; zimm uses `common.immediate[4:0]` |

`common.capability` is the authoritative execution selector. For example,
JAL/JALR and compressed jumps require `CAP_BRU` alone, never ALU+BRU;
MUL and DIV use their own compact operation enums. Inactive chunks are
unspecified and must not trigger execution. A zero ALU or MUL opcode is a real
operation, not an enable. Dispatch validity remains external to this payload.
The parallel `lane_type` tag is retained only through issue for lane selection;
it is discarded when issue latches the selected execution packet.

An ALU+BRU+MUL unit can declare and latch exactly these 140 bits:

```systemverilog
import Definitions::*;
import Enumerations::*;

typedef struct packed {
    DecodeCommon_ common;
    DecodeAlu_ alu;
    DecodeBru_ bru;
    DecodeMul_ mul;
} AluBruMulPacket_;
AluBruMulPacket_ execution_packet;
logic execution_valid;

// Issue asserts accept after selecting a compatible lane or routing a trap.
always_ff @(posedge clk) begin
    if (reset || flush) execution_valid <= 1'b0;
    else if (accept) begin
        execution_valid <= decoded_valid;
        if (decoded_valid)
            execution_packet <= '{common: decoded.common, alu: decoded.alu,
                                  bru: decoded.bru, mul: decoded.mul};
    end
end
```

For a parameterized lane, put each optional chunk register inside an
`if (IS_ALU) begin : alu_controls ... end` generate block, and similarly for
BRU/MUL/DIV. There is no zero-width struct-member trick: compose a concrete
local struct as above, or generate individual typed registers. The complete
packet remains available to the issue queue alongside its two-bit lane
tag. `IntegerLane.sv` implements integer execution and forces invalid integer source
operands to zero, allowing unused source register numbers to remain unspecified.

The capability arrays in `Parameters.sv` configure **per-lane execution
support**. The decoder's **core-wide ISA legality** parameters control decode.
All 15 nonempty integer subsets are usable; an empty subset accepts no integer
instruction. Unsupported lanes reject an operation without changing it into a
trap: issue must find a compatible lane. The core configuration must provide
coverage for every enabled instruction class. Decode routes trap packets as `CAP_ALU` on the integer lane type, with operand
and destination enables cleared. The configuration therefore needs an ALU-capable
integer lane to deliver traps. `system` and `csr` select ordinary instruction support.

Single-precision arithmetic/comparison operations use `fp`. Per-lane `fp_f`
selects `CAP_FP_F`. Conversions are an independently advertised floating-lane
option: conversion support accepts **only `CAP_FP_CONVERT`**, with
controls in `fp_convert`. F arithmetic support does not implicitly accept
conversions, and integer lanes never do.

**D is not supported.** There is no double-precision lane option, decode gate,
precision selector, or 64-bit floating register file. D arithmetic, fused
operations, comparisons, classification, conversions, FLD/FSD, and compressed
C.FLD/C.FSD/C.FLDSP/C.FSDSP all decode with `common.trap_type = ILLEGAL`.
FLW/FSW and compressed single-precision loads/stores remain supported under F.

### Floating conversion capability and ports

| Instructions | `fp_convert.operation` | Read bank | Write bank |
| --- | --- | --- | --- |
| FCVT.S.W/WU | FPC_FROM_INT | Integer | FP |
| FCVT.W/WU.S | FPC_TO_INT | FP | Integer |
| FMV.W.X | FPC_FROM_BITS | Integer | FP |
| FMV.X.W | FPC_TO_BITS | FP | Integer |
| FCLASS.S | FPC_CLASS | FP | Integer |

Every floating lane is allocated **one 32-bit integer-file read port and one
32-bit integer-file write port**, in addition to its existing FP ports.
The conversion capability determines which instructions that lane may execute;
port availability alone does not advertise conversion support. Each conversion
uses at most one source register. `common.rs1_float` selects its source bank;
`common.rd_float` selects the destination bank. Register indices and dependency/
write enables remain in `common`. Integer x0 is supplied as zero and never
written; floating f0 remains an ordinary register.

FEQ/FLT/FLE remain F comparison operations in `fp`: they need two FP read
operands and use the floating lane's integer write port. A conversion-only lane
cannot accept these comparisons. Integer-result conversion operations also
produce FP exception flags where required; numeric conversions consume static
rounding or dynamic FRM. FMV and FCLASS do not round or update FP exception flags.

`fp_convert` promises support for the listed RV32 single-precision conversions,
bit moves and classification when F is enabled core-wide. This promise is
independent of `fp_f` arithmetic support. For example:

```systemverilog
typedef struct packed {
    DecodeCommon_ common;
    DecodeFloat_ fp;
    DecodeFloatConvert_ fp_convert;
} FloatingExecutionPacket_;
```

A conversion-only lane may retain just `common` and `fp_convert`. Its selected
conversion controls include the operation, W/WU signedness, and
rounding mode. All FP data is 32 bits. Rounding
and signedness are ignored for moves/classification. A conversion packet does
not require the arithmetic `fp` chunk. Core-wide legality gates still reject
unsupported formats, reserved rounding modes, and RV64-only conversions/moves.

Floating loads/stores route to MEMORY and
floating CSRs to SERIAL. Floating DIV/SQRT never depend on the integer DIV
capability. The register-file modules already expose parameterized port counts;
when integrating N floating lanes, reserve N additional integer read ports and
N integer write ports and connect the per-lane enables and writeback arbitration.
There is no floating execution module or core register-file wiring yet: this
change defines and tests the decode/routing and port contract, not a datapath.

Memory lanes support ordinary integer and floating loads/stores. An atomic
lane additionally retains `atomic` and accepts `CAP_ATOMIC`; it uses `memory.size`
and the common register fields, with rs1 as the address and no displacement.
LR establishes a reservation; SC attempts a conditional store and returns a
success/failure result. AMOs atomically read, modify and write memory, returning
the old value. Acquire/release bits impose ordering. These require memory-system
support beyond an ALU calculation, and cannot be implemented as an unprotected
load followed by a store. `SUPPORT_ATOMIC` remains the core-wide legality gate;
per-lane `atomic` controls routing. See the
[A specification](https://docs.riscv.org/reference/isa/unpriv/a-st-ext.html).

## Operand and side-effect contract

- `common.rs1/rs2/rd` name architectural registers. A `*_valid` bit denotes a
  real dependency or destination; inactive register numbers are unspecified.
  Integer x0 has no dependency/destination; execution supplies zero when needed.
  Floating f0 is ordinary. Fused floating operations additionally use `fp.rs3`.
- `common.immediate` holds the shared 32-bit ALU, branch, or memory immediate.
  CSR zimm occupies bits [4:0]; the remaining bits are unspecified.
  Branch/jump displacements are byte offsets. JALR uses rs1 and clears target
  bit zero; `common.next_pc` carries pc + 4 (pc + 2 for compressed instructions)
  for BRU link results and fall-through recovery.
  No branch operation needs the ALU chunk to select its operands.
- `memory.size` is log2(bytes). Loads to x0 still execute and can fault.
  For atomics, `memory.operation` is MEM_NONE; select `atomic.operation` using
  CAP_ATOMIC. LR has no rs2 dependency.
- `rounding_mode == 7`
  selects dynamic FRM at execution. Modes 5/6 trap for rounding operations.
- `csr.read_enable` and `write_enable` describe intent independently of rd.
  CSRRS/CSRRC write intent depends on the encoded rs1 number, not its value.
  Unknown CSR addresses and writes to read-only-zero CSRs trap. Floating CSR
  aliases and runtime privilege/FS/dynamic rounding checks belong in execution.
- SYS_MRET implies a read of MEPC by system execution; it does not require
  retaining the CSR chunk. Fences retain predecessor/successor masks;
  FENCE.TSO is conservatively treated as an ordinary fence.
- Trap packets carry their cause in `common.trap_type`, with register dependency/write enables and
  ordinary operation payloads unspecified. `BR_NONE` remains defined to suppress
  the integer lane's parallel branch logic. The selected lane must deliver the
  trap even without a destination register.

The floating register file has fixed 32-bit data paths; execution
still must implement floating CSR aliases, fence ordering and fetch synchronization.
This packet refactor does not implement those execution mechanisms.

## Verification

`TrapType_` uses the project's four-bit internal encoding: `NONE`, `ILLEGAL`,
`MIS_STORE`, `MIS_LOAD`, `MIS_INST`, `ECALL`, `EBREAK`, `ACCESS_STORE`,
`ACCESS_LOAD`, `ACCESS_INST`, and `INTERRUPT`. These are not raw `mcause` values.
Decode produces `NONE`, `ILLEGAL`, `ECALL`, or `EBREAK`; fetch/execution/memory
fault detection and interrupt control supply the other causes. Adding enum
members does not make instruction decode detect runtime access or alignment faults.
Trap entry must resolve ECALL privilege and interrupt cause separately.
Zero-initialized packets remain non-trapping because `NONE` is zero.

No permanent test suite is checked into this workspace. A frontend lint check is:

```sh
verilator --lint-only --timing -Wall -Wno-fatal --top-module FrontendTop \
  -f Core/Package/packages.f Core/Frontend/Fetch/*.sv \
  Core/Frontend/Dispatch/*.sv Core/Frontend/Top.sv
```

On Windows, run it through WSL. Remaining lint categories include filename/module
naming, unused placeholder interfaces, and incomplete `unique case` statements
whose legal capability values are selected upstream. These cases intentionally
have no default arm.

The refactor was checked with temporary, uncommitted simulations: fetch/issue PC
ordering, partial consumption, global stalls, long resets, redirect flushing,
decode metadata versus the live integer table, and source extraction versus full
decode. These are frontend checks, not execution-result or ISA compliance tests;
redirect checks do not validate restoration of killed backend producers.

Encoding references: [RISC-V ISA manuals](https://docs.riscv.org/reference/isa/)
and the [C extension specification](https://docs.riscv.org/reference/isa/v20260120/unpriv/c-st-ext.html).
