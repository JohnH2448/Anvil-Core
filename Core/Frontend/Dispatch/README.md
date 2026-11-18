# Decoder

See [frontend architecture and timing history](../ARCHITECTURE_HISTORY.md) for the original boundaries and the reasons for stage changes.

## Decode queue

**Current operand eligibility:** Decode registers next-cycle operands_ready for
consume-zero/one/two outcomes, including the new write buffer each outcome implies.
IssueContract uses that bit with structural flags, validity and live serial_active;
its former producer-readiness/bypass checks now reside in Decode. Full producer
correction remains on forwarding payload only. Earlier descriptions of combinational
Issue readiness are superseded by this lookahead experiment.


**Current global-stall behavior:** Decode freezes all packet-related state and
forces serve_consumed to zero. Reset/redirect still flush validity and reset
occupancy while stalled. Candidate metadata always assumes an advancing edge;
unmasked issue count/prefix controls select candidates, and !stall enables their
capture. Buffered writes/table state hold, preserving corrections until resume.
This supersedes the earlier refill-during-stall notes retained below.


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

`RegisterSlice` extracts rs1/rs2 in Fetch alongside prediction, after instruction
reconstruction. Those addresses travel with the instruction through the FIFO
and speculative serve banks and directly address `ProducerTable` in decode.
Each decoded packet carries parallel registered source index, lane,
and capability arrays into issue. Those arrays follow the same FIFO retain/refill
selection as the packet, including an upper entry shifting into slot zero.

A producer index advances toward `EXECUTION_UNROLL + 2` (the register file)
only when global `stall` is clear; waiting in the decode FIFO alone does not freeze them. Fresh table
reads also receive that edge's advancement. Reset/redirect invalidate the packet
FIFO; packet and producer payloads become unspecified during a flush.
Normal FIFO candidates are calculated independently of redirect. Fixed-source
producer updates precede parallel retain/refill selection; only validity and
outward-facing consumption require defined flush values.

Accepted integer writes enter Issuer's one-cycle write buffer. Older duplicate
rd entries are invalidated before capture; buffered source matches are mutually
exclusive. Buffered metadata corrects both readiness and forwarding immediately,
then Decode absorbs it into retained and refill snapshots at the next edge.
The table commits on that same edge at index one.
All buffered writers are older than every current Decode packet. There is no
same-cycle live-write refresh and no instruction-counted history shift register.
The buffer is replaced on every unstalled cycle, even with no accepted writes;
stall holds it, and reset/redirect clears validity. Decode can absorb unaged
corrections while refilling during stall. The buffer uses index zero until commit; all progress remains aligned with backend advancement.

`IssueContract` has no stall or redirect inputs. Readiness and normal lane
allocation are independent of both controls. Issuer directly forces the final
`accept_vector` and `issue_consumed` to zero on stall or redirect. Backend
input registers and producer-table state also retain their local stall enables.
Decode can still refill empty FIFO slots, using unadvanced producer snapshots.

The current issuer supports widths one and two. Its readiness prefix and lane
allocator must agree on the consumed count. Same-group RAW dependencies prevent
a consumer from issuing alongside its producer; the buffered correction supplies the
new producer next cycle, before readiness is evaluated again.

This remains an integer producer table. Floating-register writes do not update
it; floating dependency tracking (including rs3) remains unimplemented. Producer
mapping restoration after backend redirects also remains unimplemented: the table
holds on redirect and needs a backend recovery protocol before full-core use.

`DecoderSlice.sv` accepts one raw RV32 instruction and emits a purely combinational
`Definitions::DecoderPacket_` plus a separate `LaneType_` routing tag. Its inputs
are `instruction`, predecoded rs1/rs2/rs3/rd identities and bank flags, `pc`, `is_branch`, `predicted_taken`, and `is_compressed`; it
has no clock or internal registers. With `is_compressed`
set, the low 16 instruction bits are decoded as RV32C. `is_branch` is fetch
metadata, not a condition for recognizing branches. Dispatch owns validity and
scheduling tags.

The decoder is organized by output field. Shared encoding predicates feed
independent operation/payload case tables and explicit common-field equations.
There is no whole-packet compressed/full selection or capability-driven
`relevant_fields` pass. Unused payloads default to don't-care. Trap legality is
precomputed in Queue and qualifies operand validity and defined
side-effect controls; BR_NONE remains defined to suppress the parallel BRU.
Compressed legality and payload mapping use raw 16-bit fields directly without
canonical expansion. All register identities/banks come from predecode. Constant
extension guards remain in both legality and payload conditions. No stage added.

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

DecoderSlice uses the carried source addresses for packet register fields. Raw
instruction fields remain local inputs to zero-register validity checks, CSR
controls/immediates, and FP/atomic legality checks; unused predecoded operands
may be unspecified and must not replace those encoding fields.

Register predecode now carries rs1, rs2, rs3, rd and their integer/floating bank
flags from reconstructed Fetch packets through prediction/FIFO/serve candidates.
DecoderSlice receives all identities and bank flags directly. Fresh producer
refresh uses carried source-bank flags; full decode still owns legality and
operand-valid controls. Extension support parameters gate predecode cases.

The final immediate payload is generated independently from instruction format,
with unused formats unspecified. It bypasses capability/trap relevance selection;
legality and valid controls remain authoritative for whether it is consumed.

Serial occupancy blocks only CAP_SYSTEM/CAP_CSR. An older serial instruction
blocks younger serial instructions in the group, while independent nonserial
instructions can coissue. Prefix issue still prevents bypassing a blocked older
instruction. Serial integer destinations become issue-ready at index EXECUTION_UNROLL+1
for the next-cycle RF read; the producer starts at index zero, not RF_INDEX.
Floating producer-table tracking remains unimplemented.

ProducerTable receives buffered writes with unique destinations and uses parallel
match/payload selection. Higher issue slot wins duplicate destinations at buffer
capture. The op_age port is retained but does not arbitrate writes.

common.next_pc is reserved and unspecified throughout decode/issue. Issuer clears
it to don't-care before packet lane selection. Integer execution derives its own
fall-through address for link writeback and predicted-taken recovery.

FrontendTop's OOC outputs now expose representative backend input registers,
generated by configured lane counts/capabilities. Dispatch itself still produces
combinational lane packets. The sink retains only each lane's modeled packet
chunks, captures payload on every unstalled edge, and flushes valid on reset
or redirect. This adds one observation cycle at FrontendTop, with no actual
backend execution. OOC timing now includes register capture instead of relying
on the former raw output endpoints. Non-integer lane consumption is provisional
because those execution modules remain stubs.

The resource check uses explicit one-/two-wide lane-mask conditions for supported
issue widths, with generic subset checking retained for wider configurations.
Allocator priority-encodes available/preferred masks in parallel. Lane payloads
are unspecified when acceptance is low; their muxes do not depend on the final
accept mask. Consumers must use acceptance/validity as their capture authority.

Issuer generates live write qualification from contract success and accepted
nonzero integer destination, independently of allocation. Registered op_write
and payload feed table/decode; lane payload comes from allocation before capture.
Correctness requires contract/allocator agreement, also needed by consumption.

The OOC flow uses Default synthesis and RuntimeOptimized opt/place/route.
The 2026-11-15 forced selector-replication experiment was reverted after routed
WNS regressed from -2.208 to -2.527 ns. See ARCHITECTURE_HISTORY.md for results.


Producer-table read outputs expose current raw indices. Decode applies local
capture-edge aging to fresh reads and retained snapshots, unless stall is active.
Buffered corrections age independently before correction selection. Each source
ages exactly once with RF saturation; Issue's buffered override still represents
index zero in the current cycle. Stall no longer controls per-entry read payload
before the table lookup, though local aging now follows source-address selection.


Fetch selects all serve fields, including rs1/rs2 and bank flags, using the
registered binary consumption count. Dedicated one-hot source selectors were
removed after they became the endpoint of the backward consumption timing path.
Speculative candidate banks and their cycle alignment remain unchanged.


Countdown state and interfaces have been removed. IssueContract derives operand
readiness from producer index/capability using fixed configuration thresholds:
ALU 0, BRU/MEMORY 1, MUL min(EXECUTION_UNROLL,2), DIV
min(EXECUTION_UNROLL,ceil(32/DIVIDER_AUTO_PIPE)+2), SYSTEM/CSR
EXECUTION_UNROLL+1, and other existing cases EXECUTION_UNROLL. RF-position entries
are always ready regardless of unspecified capability. Index-zero bypass checks
remain separate and unchanged. Producer metadata is now index/lane/capability
throughout table reads, Decode retention/refill, and buffered correction.
The fixed ready-index experiment was reverted; its history remains documented.


Lane input payloads now advance through bubbles: FrontendTop's representative
sinks and IntegerLane's actual stage-zero decoder/issuer registers capture whenever
the pipeline advances, without an acceptance enable. Acceptance sets validity;
invalid payload is unobservable. Global stall still holds payload. This removes
acceptance fanout to wide payload clock enables but increases bubble switching.


Issuer preselects lanes from packet capabilities and validity before issue_good.
A valid younger packet reserves its compatible choices even when it ultimately
waits. This can change the older packet's chosen lane, but the supported dual-issue
allocator still finds a pair whenever one exists and preserves oldest-first issue.
Payload muxes and buffered producer lane identity use these same assignments.
issue_good gates only acceptance/consumption/write validity, with normal reset,
stall and redirect suppression; it no longer steers allocation or payload muxes.


Decode precomputes same-group rs1/rs2 RAW and serial/serial hazards for ordered
pairs of retained and fresh packet candidates. Each constant-consumption outcome
resolves occupancy, source validity and flush independently. issue_consumed directly
selects the final hazard bits into registers alongside the next group's packets. Shifting out
an older packet therefore removes that pair's hazard; refills recompute the new
pair even during global stall. Slot zero has no pair hazard. Reset/redirect clear
the flags with validity. IssueContract consumes these registered flags while live
serial_active and producer-dependent readiness/bypass remain combinational in Issue.
Register-bank and operand/destination-valid qualification preserve the existing
RAW semantics; this does not add rs3 or floating producer-table tracking.


Static lane feasibility is also precomputed in Decode for supported issue widths
one/two. It uses configured lane capability masks: oldest requires a compatible
lane; the pair requires both masks nonempty and their union to contain at least
two lanes. group_resource_bad is selected directly by issue_consumed into its
register alongside RAW/serial flags, then wired to IssueContract. Occupancy,
validity and flush are resolved within each candidate before the final mux.
Issuer still independently selects actual lanes and drives payload muxes; producer
readiness and live serial occupancy remain IssueContract decisions. Wider issue
is explicitly unsupported, as it already was by Issuer.


Capability and lane type now follow encoding independently of legality. A trapped
instruction keeps its normal class rather than being forced to ALU/integer;
unknown/disabled classes retain the default route. trap_type, legality-qualified
operand/destination validity and existing side-effect suppression are unchanged.
Every routed lane must deliver traps without ordinary effects, and configured
classes require compatible lanes. Noninteger execution lanes remain stubs, so
end-to-end trap handling there is still outstanding. RAW precomputation now uses carried encoding-only use bits; serial/resource checks
use carried capability. Neither waits on full legality decoding.


RegisterSlice now also predecodes capability and encoding-only rs1_used/rs2_used/
rd_written alongside branch prediction. These seven bits (current capability width
four) travel through prediction, FIFO and speculative serve banks. DecoderSlice
accepts capability directly and derives lane type from it; full legality remains
local. Decode retains operand-use bits beside its packets and uses them exclusively
for structural RAW checks, tolerating false dependencies on illegal encodings.
Actual packet operand/destination validity and producer writes remain legality-
qualified; predecoded rd_written is never write authorization. Structural serial/
resource checks use the carried capability. Final consumption-selected structural
registers and all FIFO/stall/flush protocols are unchanged. No rs3 tracking added.


Issuer now supplies a separate issue_select_count to Decode: normal contract
consumption masked by stall only. Reset/redirect do not steer payload/FIFO candidate
selection. Effective issue_consumed and backend acceptance remain flush-masked;
Decode independently clears packet validity, resets occupancy and suppresses
outward serve_consumed. Flushed payload selection is unobservable. This removes
redirect from the normal consumption-to-keep/refill selection cone without changing
stall retention or refilling semantics.


Producer snapshots use a separate direct consumption mux: fixed aged/refreshed
sources are assembled into one complete metadata outcome per possible pop count,
with occupancy resolved before issue_select_count selects the register input.
The snapshot registers capture unconditionally, with no post-mux validity/flush
qualification; their contents are unobservable when the corresponding packet is
invalid. Existing stall-aware aging, buffered corrections and FIFO alignment remain.


DecoderSlice consumes the carried operand-use bits directly, qualifying each with
ok for actual rs1/rs2/rd validity. It reuses capability for exact MUL/DIV/atomic/CSR
class predicates; optional payload logic retains SUPPORT_* guards. Detailed
suboperation/format/immediate decoding and legality checks remain local. This
removes duplicated operand-use and zero-register checks after serve selection
without changing producer write qualification.


Decode packet movement now receives two stall-qualified issue prefix bits.
issue_select_any chooses the zero/one-consumed occupancy outcome early;
issue_select_two selects the all-fresh outcome at the final dual-issue packet mux.
This bypasses binary count and shared keep/refill control for packet/lane/use-bit
selection. Only selected payload is registered; no speculative packet bank is
stored. Packet validity flushes independently, with arbitrary invalid payload.
Producer snapshots, structural flags and FIFO accounting retain the equivalent
binary-count path. Width one uses only the oldest bit. The two-bit selection relies
on the contract's oldest-first prefix and retains stall refill behavior.


Producer snapshot index registers advance on !stall. Lane/capability registers
instead use explicit permissive per-source enables: !stall AND (any consumption
OR slot invalid OR retained buffered-write match). Any replacement can therefore
capture incoming corrected metadata independently of the outgoing source match;
waiting valid packets absorb matching writes, and empty slots can refill. The
selected data path is unchanged. Extra captures are allowed to simplify control.


Queue computes instruction trap_type from registered prediction payloads before
FIFO insertion, using Fetch/InstructionLegality.sv. The result is stored with each
FIFO entry under the identical commit/keep/index controls and carried through all
serve candidates. No legality computation remains on serve-candidate construction.
DecoderSlice consumes trap_in directly. This supersedes the initial per-serve-bank
legality experiment; the main FIFO is now four bits wider, with no extra stage.
All remaining instruction payload decoding stays in DecoderSlice.
Earlier local-legality descriptions are superseded by this ownership change.


Decode now registers rs1/rs2 match vectors against the destinations that Issuer
will capture in its next write buffer. Comparisons occur per fixed source before
packet selection; the bits travel through PacketChoice_ with that source. Issuer
qualifies each registered bit with buffered op_write, preserving acceptance,
integer/x0 and youngest-writer rules without live address comparisons in correction.
Packet/match/write-buffer capture holds on stall; flush clears packet/write validity.
Decode's own current-buffer refresh matching remains unchanged. Dual issue adds
eight match bits, with no pipeline stage or live-write qualification before comparison.


Operand lookahead starts from aged/refreshed retained or fresh producer snapshots.
It applies prospective accepted integer writers at index zero using precomputed
source matches and youngest-writer priority, without live acceptance qualification
before the comparisons. Actual consumption selects the final eligibility bit into
its packet-aligned register. Stalls hold it; flush clears it. BYPASS_ENABLED and
execution/divider thresholds are applied in Decode. Snapshot/forwarding payload
protocols and the registered write buffer remain unchanged; no added issue stage.


For operand lookahead, ProducerTable now supplies one-bit capture-edge eligibility
computed per entry before source-address selection, alongside unchanged raw metadata.
Decode uses the same threshold helper on retained snapshots and corrects eligibility
with precomputed buffered-writer ready bits independently of metadata correction.
Prospective newly issued writers retain the separate index-zero bypass rule. These
are combinational summaries, not new table state; stall remains a register enable.

Capture eligibility compares the index against constant per-capability thresholds
before selecting the result. Threshold arithmetic depends only on configuration;
no live capability-selected integer threshold is decremented before comparison.

Fetch serve source identities (rs1/rs2 and bank flags) now select a completed
consumption candidate before their output registers. Producer reads therefore use
direct registered addresses. Wide instruction payload remains speculatively banked;
both paths select the same consumption outcome and share retention/refill mapping.

The main frontend OOC flow uses Default synthesis and RuntimeOptimized
opt/place/route without physical optimization. Standard routed reports and
frontend_routed.dcp are written directly after routing.

frontend_retry.tcl retries an existing routed DCP single-threaded with aggressive
routing followed by explicit hold repair and separate pin, routing, clock and
restructure passes, another routing pass, and final aggressive hold repair.
It saves each completed pass before reports, with last_saved.txt/progress.txt for
crash recovery. Uses the checkpoint's RTL/constraints; native crashes cannot save
partial progress within a pass. The main flow is unchanged.

Retry Tcl-command failures reload the last saved checkpoint and continue to the
next pass, recording failures.txt. Native crashes still require restarting Vivado.
Compare all saved setup/hold reports; the last result is not necessarily best.

Main OOC constraints model reset input arrival as min=max=1.000 ns. This is an
external timing assumption, not inserted delay; serial_active retains min=0/max=1.

InstructionMemory response words and halfword alignment capture without reset;
reset clears only fetch_valid. Queue reset/validity prevents consuming invalid
response payload. Valid reads retain their existing latency and alignment.

Lane masks use integer bits0/1/2/3 = ALU/BRU/MUL/DIV. Shared effective masks
combine these with global extension support before resource checks, allocation and
OOC payload capture. Zero-count capability arrays retain one unused placeholder.
FrontendTop checks base and enabled-extension coverage and global packet-width
consistency; disable FP lanes by setting FLOATING_LANE_COUNT=0 with SUPPORT_FLOAT=0.

Immediate encoding format is predecoded from prediction registers before FIFO
check-in. Five selector bits travel with each instruction through FIFO/serve banks;
DecoderSlice assembles immediate bits using that selector. FP formats honor support
flags. Existing direct source identities keep their packed offsets.

Branch operation is also predecoded before FIFO check-in as a four-bit enum and
carried with serve payload. DecoderSlice applies final trap qualification to BR_NONE;
branch prediction flags and immediate assembly remain independent.

Immediate bits[4:0] are computed before FIFO check-in and carried as five payload
bits. Decode assembles only bits[31:5] locally. Both paths use the same encoding
layouts; unused values remain unspecified and metadata follows instruction motion.

Upper immediate selection now carries14 direct layout enables rather than a5bit
format code. I/S upper layouts share one enable and zero-upper formats need none.
Decode uses masked wiring/OR for bits31:5; low5bits remain precomputed payload.
This supersedes earlier descriptions of a carried encoded immediate format.


Serve instruction words and compressed flags now select the completed next-window
candidate before capture, like rs1/rs2, rather than passing through the registered
consumption selector after capture. Other served metadata, PC and validity remain
banked. Retained/refill mapping and pipeline latency are unchanged.


FP/integer crossings require register-file readiness: FP-produced integer results
are eligible only at RF position, and FP consumers wait for integer sources to
reach RF. Decode applies this to fresh/retained and corrected producer readiness;
new ALU bypass cannot release an FP consumer. These rules assume lockstep FP
progress and generate out with FP disabled. No FP busy scoreboard is present.


FP-consumer classification is computed before FIFO capture and carried as
common.fp_consumer. Decode uses this bit with integer source-bank flags to
select RF-only readiness, avoiding late capability decoding. F-disabled ties it low.


Serve trap bits now also use direct capture from the completed next-window
candidate, aligned with instruction/c and source identities. Other banked
metadata and validity retain their existing selection. No pipeline stage added.


The14 upper-immediate layout enables also select before serve capture, aligned
with the direct instruction/trap registers. Low immediate bits remain banked.


The FP-consumer flag also selects before serve capture. It is tied low with no
output register when SUPPORT_FLOAT=0; retained/refill alignment matches the
other directly captured fields.


Serve capability now also uses direct capture from the selected completed
next-window candidate, removing bank selection ahead of resource feasibility.
Its encoding, instruction alignment and pipeline latency are unchanged.


Retained producer refresh and identity capture enables reuse the registered
rs1/rs2 buffer-match vectors already carried for Issuer correction. Fresh refill
operands still compare against current buffered destinations. No new state added.


ProducerTable capture readiness is registered alongside each entry. Reset,
buffered writes and saturated aging keep it equal to producer_capture_ready
of the current index/capability; stall and redirect hold both. Reads select the
stored ready bit directly, with Decode correction/lookahead semantics unchanged.


Direct serve payload registers use serve_select_count, masked only by stall.
Flush clears queue validity/state independently; outward serve_consumed remains
zero on reset/redirect/stall. Direct payload captures during flush are invalid.


System/CSR trap decoding now runs alongside branch prediction and captures with
the prediction payload. Final InstructionLegality selects this result for SYSTEM
opcode; compressed and other instruction legality remain before FIFO insertion.


Low-immediate predecode now directly selects each of five bits from raw encoding
predicates, without an intermediate format-number encoder/decoder. Its capture
stage and FIFO/serve interface are unchanged.


Upper-immediate layout enables have returned to speculative bank capture to
reduce late-pop fanout. Earlier direct-upper-layout descriptions are superseded;
instruction/c, sources, trap, FP-consumer and capability remain directly captured.


Serve validity now directly captures the selected next-window valid bit alongside
direct payload, with explicit reset/delayed-reset/redirect clearing. Zero-pop
stall behavior still retains entries and permits filling vacant serve slots.
FIFO head/occupancy/free state remain speculatively banked.


Destination rd and rd_float now use direct serve capture alongside rs1/rs2.
Destination write-use qualification remains banked. Packet alignment and flush
validity follow the existing direct-payload protocol.


## 2026-11-18 - Serial consumers use register-file-only operands

Decode readiness now includes CAP_SYSTEM and CAP_CSR in the existing RF-only consumer classification, alongside FP consumers of integer sources. Integer sources must reach the existing capture-edge RF threshold; current buffered and prospective new writers cannot satisfy them by forwarding or bypass. The existing source-valid checks keep unused and immediate operands from blocking issue. No packet state, stage, or issuer path was added; serial occupancy and pair checks are unchanged. This allows serial consumers to omit incoming forwarding ports at the cost of waiting for RF. Validation: static review of retained/fresh readiness and both writer override paths only; no synthesis or tests run. Timing impact is unmeasured.


## 2026-11-18 - Narrow serial RF-only qualification to CSR

Removed CAP_SYSTEM from Decode RF-only consumer classification; only CAP_CSR and the existing FP integer-source consumers qualify. Current RegisterSlice marks SYSTEM operations as having no integer source operands, so the broader classification was unnecessary. CSR register sources still wait for RF across snapshot, buffered and prospective-writer readiness; immediate/unused sources remain nonblocking. No state or stage changes. Validation: static source-use and classification inspection; no tests or synthesis run. Timing impact unmeasured.


## 2026-11-18 - Remove redundant issue checks and sink fields

Decode relies on elaboration-time lane coverage for individual instructions. The distinct-lane check covers same-group serial conflicts because SYSTEM and CSR share lane zero. IssueContract checks live serial occupancy. The frontend lane model consumes only input age from the serial issuer packet because CSR integer operands require RF readiness and SYSTEM has no integer sources. FP-consumer classification ends at Decode readiness. Decode, Issue, IssueContract and both Top modules were reviewed statically. Area and timing effects are unmeasured.


## 2026-11-18 - Bounded instruction PCs

Parameters.MAX_MEMORY_ADDRESS is the inclusive byte limit (default 0x7ff). Fetch carries the address bits plus one overflow bit, capped at RV32 width, through prediction, FIFO and serve. Full redirect and PC-relative target inputs fold discarded bits into the guard before capture. Queue checks the last byte of each reconstructed instruction and carries instruction access faults through FIFO check-in. Out-of-range targets can lose their original high bits in the reported PC. Decode ties unused architectural PC bits low through lane capture. Static field and selector review only. Area and timing are unmeasured.
