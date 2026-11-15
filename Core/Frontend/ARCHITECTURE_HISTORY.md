# Frontend architecture and timing history

This document preserves the intended semantic boundaries and records why timing work crossed them. It is an architectural history, not a claim that every intermediate version was verified. The original description below is reconstructed from the design discussion; it is not a line-by-line reconstruction of a particular commit.

## Original semantic architecture

- **Fetch:** request instruction memory, reconstruct compressed/full-width instructions (including split instructions), predict branches, queue the predicted instruction stream, and serve words with PCs and prediction flags.
- **Decode:** interpret instructions, identify registers and operation-specific controls, and queue decoded packets in program order.
- **Dispatch producer table:** own the mapping from architectural integer register to producing execution lane, pipeline position, capability, and remaining readiness countdown. Issue consults dependency information and publishes accepted producers.
- **Issue:** check readiness and hazards, allocate compatible execution lanes, build forwarding/issue packets, and report how many consecutive decode entries were consumed.
- **Consumption:** propagates backward so each queue retains a suffix and refills its available slots. Redirect flushes validity; stall prevents backend advancement.

Source-register interpretation belonged to decode, not branch prediction. The producer table belonged to Dispatch and remains instantiated there. Timing work moved reads and created copies/corrections of its data across stage boundaries; it did not move ownership of the actual table into Fetch.

## Current information flow

1. Fetch reconstructs complete instruction words. RegisterSlice extracts rs1/rs2/rs3/rd and their register-bank flags alongside branch prediction, using the same extension support parameters as decoding.
2. Source addresses are latched with prediction results, compacted into the instruction FIFO, and carried through speculative serve windows with instruction, PC, validity, and prediction flags.
3. For every possible consumption count, Fetch registers a candidate next serve window and matching FIFO head, occupancy, and free-space state. A registered binary consumption count selects the current window/state combinationally. Dual issue has three outcomes: 0, 1, 2.
4. Decode directly uses the carried source addresses for producer-table reads and DecoderSlice packet source fields. It counts validity from the selected serve window, decodes instructions through independent per-field logic, and latches source metadata with packets. Metadata ages while retained and on the capture edge of a fresh table read, unless globally stalled.
5. Decode refreshes snapshots with same-cycle accepted integer writes: retained packets match older slots, refills match all issued slots, and youngest matching writer wins. Issue uses the registered corrected snapshots directly.
6. Allocation generates per-slot producer acceptance/lane directly alongside backend lane acceptance. Writes update the Dispatch producer table and decode refresh on the same edge.

Source extraction's module file remains under Dispatch even though Fetch instantiates it. The experimental Issuer history buffer has been removed.

## Invariants introduced by timing work

History-specific invariants below describe the reverted experiment, not current RTL.

- Packet validity is a contiguous prefix; issue consumes a consecutive prefix. Current allocator supports widths one and two.
- Candidate serve payload and candidate FIFO state must use the same registered selector. Head advances by actual FIFO pulls, not by consumed serve count. Same-edge FIFO pushes are available on the following cycle.
- Every source address must travel with its instruction through reconstruction, prediction, compaction, retention, and speculative selection.
- Producer index saturates at EXECUTION_UNROLL + 2; countdown saturates at zero. History and table use the same initial countdown helper and stall behavior. New writes start at index zero and are not aged on their allocation edge.
- History depth relies on in-order issue and the decode queue depth: a retained packet has at most ISSUE_WIDTH-1 older queued instructions that can shift history before it issues. Later arrivals read the updated table. Replacing history every clock, allowing younger packets to bypass a waiting packet, or increasing queue depth invalidates this argument.
- History valid is captured from an accepted integer write with nonzero rd. No-destination instructions insert invalid entries with don't-care payload. Invalid payload alone cannot mark an entry invalid.
- Corrected countdown/capability/index must reach readiness, not just the outward issue packet. Lane correction supplies forwarding selection.
- Stall/redirect are absent from IssueContract. Issuer masks final acceptance and consumption; backend/table state retain their local enables. Redirect clears queue/history validity. Producer-table recovery after a backend redirect remains an unresolved full-core requirement.

## Change log

### Earlier frontend work — reconstructed history

- Converted irrelevant decode packet fields to don't-cares according to operation capability and operand-valid controls. Semantic selectors and required common controls remain defined. Unused backend operands are forced to zero where required.
- Introduced parameterized RegisterSlice to extract source addresses independently of full legality/operation decoding.
- Moved producer-table reads to decode and carried index/countdown/lane/capability snapshots with queued packets. Added saturating aging during stalls in the decode queue (distinct from global backend stall), FIFO shifts, and fresh capture alignment.
- Centralized initial producer countdown calculation, including physical MUL/DIV stage bounds for iterative configurations.
- Tried buffered writes, then replaced them with same-cycle accepted-write refresh in decode. Retained packets matched older writers; incoming packets matched all accepted writers. This solved stale snapshots but put late allocation on decode register inputs.
- Replaced variable FIFO payload indexing with parallel fixed-source candidates and selection masks.
- Removed stall/redirect from normal issue-contract decisions; final acceptance/consumption are forced low directly. Flush invalidates payload rather than requiring meaningful data. Acceptance was briefly allowed high on stall, then explicitly changed back to final masking.
- Removed full rs-valid decoding from producer-refresh match guards; unused operand metadata is ignored. Integer/floating bank distinction remained necessary.
- Experimented with invalid serve data deadbeef versus don't-care. Don't-care caused a reported roughly 0.7 ns regression in one run; temporarily restored deadbeef. Later committed RTL again used don't-care. Neither representation guarantees better placement/timing.
- Tried Quick implementation directives for runtime; severe routing regression led back to RuntimeOptimized opt/place/route with Default synthesis. Placed and routed reports/checkpoints are saved separately. Worst-path detail is generated separately and may be stale; compare timestamps.

### 2026-11-12 — speculative serve windows

Baseline checkpoint: 798799b (Prototype 1.5), verified pushed before editing.

Problem: issue decision propagated through consumption, decode admission, serve retention/refill, and FIFO head arithmetic or serve-register control in one cycle.

Change: register all possible next serve windows and matching head/occupancy/free counts alongside actual consumption; select after the edge. Remove the old incoming_serve_valid lookahead interface and decode's separate registered valid count. Count validity from the selected window instead.

Tradeoff: extra candidate storage and a mux before decode. No extra instruction pipeline cycle. The late backward path was broken, but selection now precedes decoding and producer lookup.

Measured next worst path: registered consumption selector -> serve mux -> source decoding -> producer metadata -> decode register. Data 8.372 ns, slack -3.445 ns, routing 7.009 ns. The older deadbeef baseline was data 7.920 ns / slack -3.307 ns, so this was a structural improvement, not a demonstrated overall win against that particular baseline.

### 2026-11-12 — source predecode moved into Fetch

Change: instantiate RegisterSlice on reconstructed packets alongside prediction; carry 10 source-address bits through prediction registers, FIFO, and candidate serve banks. Decode table reads use these addresses directly. At this stage fresh refresh comparisons also used them; floating-bank guards still came from full decode.

Cost: wider stored entries and more early extraction logic. Benefit: source extraction moves ahead of serve-window registers.

An editing error passed SUPPORT_* overrides to InstructionMemory as well as Queue; synthesis rejected the nonexistent parameters. Removed those overrides from InstructionMemory.

Measured new worst path: queued capability -> issue allocation/acceptance -> producer refresh -> decode rs1 lane register. Data 7.862 ns, slack -2.863 ns (0.582 ns improvement). Approximate contributions: launch/distribution 1.283 ns; allocation/shared control 3.859 ns; refresh/FIFO selection 2.720 ns. Synthesized input_age names represent shared slot/allocation selection, not an age counter in the dependency path.

### 2026-11-12 — issued-instruction producer history

Committed baseline before this edit: a959710 (Prototype 1,6). Working tree was clean.

Snapshot: build/frontend_ooc/snapshots/20261112_234049_before_write_history/ contains the available reports and exact baseline commit hash. Snapshot directory is a local build artifact; retain/copy it separately if build outputs are cleaned.

Change: remove same-cycle accepted-write refresh and its ports from Decode. Decode now only ages/moves snapshots. Issuer owns an ISSUE_WIDTH-entry history, oldest first, shifted once per accepted instruction in program order. No-destination instructions insert invalid entries. Age retained history with the table; hold on global stall; clear on reset/redirect. Match source registers against valid integer history entries, youngest first in priority, and feed corrected values to IssueContract and forwarding construction.

Intended timing effect: replace allocation -> decode refresh with registered history -> match/select -> issue readiness/allocation. No permanent absorption of history corrections into decode is required under the queue-depth/in-order invariant above.

Status at implementation: diff formatting checked, with measurement pending. The subsequent user-run routed result failed the timing objective and the experiment was reverted on 2026-11-13; see the detailed postmortem below. No functional failure was established, and no simulation was run by the assistant. Floating producer tracking and redirect recovery remained unresolved.

## Maintenance

Append a dated entry for every subsequent frontend architecture/timing change, including reversions. Record motivation, affected stage boundaries, data alignment/control invariants, costs, validation actually performed, and measured results when available. Distinguish hypotheses from measurements. Update Current information flow when behavior changes; preserve historical entries. Do not infer exact LUT semantics solely from optimized net names.

### 2026-11-13 — revert history and apply local optimizations

The history experiment regressed routed data delay from 7.862 ns to 8.454 ns and slack from -2.863 ns to -3.910 ns. New path: source register -> history match/selection -> readiness/allocation -> producer-table capability synchronous-clear input. Endpoint setup differences account for part of the slack regression.

Removed history storage/matching and restored Decode's same-cycle write refresh and ports from a959710. Kept speculative serve windows and Fetch source predecode. Saved the available regressed reports under build/frontend_ooc/snapshots/*_write_history_regression.

Local changes: Issue allocation now emits op_accept/op_lane per slot directly instead of reconstructing them by scanning lane outputs. Unaccepted op_lane defaults to don't-care; reset blocks allocation and stall/redirect mask both acceptance views. RegisterSlice unused source addresses default to don't-care (semantic rs-valid still gates operand use). Prediction and partial-instruction payload resets become don't-care with their validity controls still cleared. Invalid serve candidates retain valid=0 with all payload fields unspecified.

These preserve pipeline latency and instruction order. No generic resource-check rewrite, capability compression, or new metadata mechanism was added. Readiness/forwarding precomputation proposals tied to history are moot after reversion. Diff review only; no tests or synthesis run. Timing effects pending measurement.


## Failed experiment: issued-instruction producer history (2026-11-12 to 2026-11-13)

### Motivation and hypothesis

The pre-experiment critical path started at a queued operation capability, traversed issue lane allocation/acceptance, then entered decode's same-cycle producer refresh and FIFO selection. Its endpoint was slot 1's rs1 producer-lane register. The proposal was to register accepted writes independently, letting decode capture and age table snapshots without waiting for current-cycle allocation. Issue would correct those snapshots from a small recent-write history. This avoided extra producer-table read ports and added no instruction pipeline stage.

The initial expectation was that the correction would mostly affect outgoing forwarding fields. Inspection showed an important additional consumer: IssueContract needs corrected countdown, index, and capability before deciding readiness and bypass eligibility. That requirement placed the correction mux ahead of issue control as well as packet construction.

### Implemented representation and transitions

Issuer contained an ISSUE_WIDTH-entry array of packed records: valid, rd, producer index, countdown, allocated lane, and capability. Entry zero was oldest. Decode's write-feedback ports and refresh comparisons were removed; its saturating snapshot aging and FIFO motion remained.

On each unstalled cycle, retained history records aged exactly once: index incremented up to EXECUTION_UNROLL + 2 and countdown decremented to zero. Accepted instructions were then processed in program order. Each shifted history one position and appended a record. A valid integer destination other than x0 inserted a producer with index zero and the same producer_countdown helper result as the actual table. A non-writing instruction still shifted history and inserted valid=0 with unspecified payload. Two issues replaced both entries; one issue retained the younger old entry after aging; zero issues retained both entries after aging. Global stall held all history state. Reset/redirect invalidated history.

For each source operand of each issue slot, selection started from decode's snapshot and visited history oldest to youngest. A valid matching integer-bank entry replaced all four producer fields. Thus youngest matching rd won, including WAW cases. Both readiness and outgoing forwarding used the corrected result. The actual producer table remained in Dispatch and continued receiving accepted writes normally.

### Why the finite history could cover stale snapshots

This was a history of issued instructions, not a buffer overwritten every clock and not a history containing only dependent writes. That distinction is essential.

With a two-entry in-order decode queue, a consumer retained after its producer issues can have at most one older queued instruction ahead of it. If the consumer is in slot zero, no other instruction can issue ahead of it. If it is in slot one, at most slot zero can issue first, shifting the producer entry only once. Waiting cycles cause no shift. Later decode arrivals read the already updated table. Therefore a two-entry history covers the missing-write window under these assumptions without permanently absorbing corrections into retained decode snapshots.

The assistant initially claimed waiting packets could outlive the entry and require correction absorption. The user correctly identified that this objection assumed cycle-based replacement. It does not apply to this instruction-driven history with in-order issue and queue depth equal to history depth. A deeper decode queue, out-of-order bypass, or shifting without actual issue would require a new proof. No-destination instructions must count toward movement even though their inserted records are invalid.

### Measured outcome

The user ran implementation. The reported design state was Routed, with a 5.000 ns clock requirement.

| Metric | Before history | With history |
| --- | ---: | ---: |
| Worst data-path delay | 7.862 ns | 8.454 ns |
| Worst slack | -2.863 ns | -3.910 ns |
| LUT levels on reported path | 10 | 11 |

The history path had 1.408 ns of cell delay and 7.046 ns of routing (83.344%). It launched from decode slot zero common.rs2 bit 2 and ended at ProducerTable capability_table[25][3]/R. Semantically: source address -> history matching/metadata selection -> readiness -> allocation/acceptance -> producer-write selection/control -> table capability update.

The first three LUTs through the node named forward_index_2 consumed approximately 2.666 ns including register launch and routing. The remaining 5.788 ns reached through issue/write control to the table. These are report-based boundaries, not an exact attribution of each synthesized LUT to an RTL expression. Names mentioning input_age, history, and forwarding fields reflected shared combinational logic, not extra pipeline registers. A late shared write-control net had fanout 127.

The data path worsened by 0.592 ns; slack worsened by 1.047 ns. The remaining difference includes endpoint/clock timing: the new synchronous-clear endpoint had a -0.373 ns setup arc in the report, versus +0.072 ns at the old D endpoint. The /R endpoint did not mean external reset caused the path; synthesis used a synchronous-clear pin to implement capability update behavior.

### Failure assessment and decision

The experiment removed the targeted allocation-to-decode-refresh connection, but added history matching and metadata selection before readiness. The new longest path continued through allocation and the actual producer-table update. It relocated work onto another already significant chain and increased state, wiring, and correctness obligations. The measured implementation therefore failed its timing objective and was reverted rather than extended with more speculative fixes.

This is a measured failure of this implementation, not proof that all recent-write buffering must fail. Possible follow-ups discussed but not implemented were evaluating readiness separately for each candidate before selecting a single readiness bit, precomputing forwarding-control bits before selection, and flattening the history shift into explicit zero/one/two-issue outcomes. Do not reintroduce the same wide-metadata-mux-before-readiness design without addressing this recorded result.

### Reversion and evidence

Decode, Issue, and Dispatch wiring were restored from baseline a959710 for the history-related changes. Source predecode and speculative serve windows were retained. Subsequent direct per-slot allocation feedback and don't-care changes are separate experiments; their results must not be attributed to history removal alone.

Baseline reports: build/frontend_ooc/snapshots/20261112_234049_before_write_history/. Regressed reports: build/frontend_ooc/snapshots/*_write_history_regression/. User-provided detailed report: C:/Users/johnc/.codex/attachments/8134ed55-d080-4225-81c4-293f0f2bf43c/Pasted text.txt. These are local artifacts and may not survive build cleanup or repository transfer; the numerical comparison and design description above are intentionally preserved here.

Validation limits: routed timing was measured by the user's run. No dedicated functional simulation or formal proof of the history implementation was performed. Reversion was driven by timing and complexity, not an observed functional bug.


### 2026-11-14 - pass predecoded sources into DecoderSlice

Added rs1_in/rs2_in ports to DecoderSlice, wired to the matching serve addresses
in DecodeStage. Both full-width and compressed packet construction use these
inputs instead of rederiving packet source addresses. Raw instruction fields
remain for x0 validity checks, CSR immediate/write controls, and FP/atomic
encoding legality. Unused predecoded addresses can be don't-care; they cannot
replace raw encoding bits in those decisions. No pipeline/register changes.
Updated Dispatch README. Diff formatting checked; no tests or synthesis run.

Latest preceding user-routed result after history reversion/local fixes: data
7.977 ns, slack -3.108 ns, nine LUT levels. Path starts at registered serve
selection and passes through full rs2_float decoding to decode producer-lane
capture. This port change does not predecode register-bank classification;
that remains a separate possible optimization. Timing benefit unmeasured.


### 2026-11-14 - complete register identity predecode

Extended RegisterSlice alongside prediction with rd, rs3, and all four bank flags.
Carried the 14 added bits through prediction, FIFO compaction, speculative serve
banks, Fetch/Dispatch wiring, and DecoderSlice inputs. Serve entries are now 92
bits. Fresh producer refresh uses carried rs1/rs2 bank flags directly, removing
its dependency on full decoder bank classification. Packet output identities and
banks use predecode; legality, operand validity, raw CSR fields and x0 checks
remain in full decode. FP, MUL, DIV and atomic cases retain constant support
parameter guards. Invalid payload remains unspecified, validity remains defined.
No added stage. Static diff review only; no tests or synthesis run. Timing pending.


### 2026-11-14 - measured complete-register predecode result

User routed report at 16:05:43: slack -2.570 ns, data delay 7.526 ns,
10 LUT levels, logic 1.622 ns and routing 5.904 ns (78.449%). Compared with
the preceding -3.108 ns / 7.977 ns run, slack improved 0.538 ns and data delay
improved 0.451 ns. Also better than the pre-history -2.863 ns baseline.
New worst path: prev_serve_consumed[1] -> selected instruction bit 29 -> shared
operation/legality/capability decode -> immediate bit 20 selection -> decode
slot 1 packet register. Source-bank producer refresh is no longer the reported
worst path. Approximate split: serve selection/distribution 2.375 ns, shared
decode through capability-named node 4.459 ns, final immediate/FIFO selection
0.692 ns. Names do not establish exact logic equations. relevant_fields gates
immediate relevance by trap/capability and is a candidate for further inspection;
no change made or causal proof established. Measurement supplied by user;
assistant only inspected report and RTL.


### 2026-11-14 - independent immediate format decoding

DecoderSlice now generates final immediate payload in a separate opcode/format
case tree with a don't-care default, assigned after relevant_fields. Includes
RV32 I/S/B/U/J, CSR zimm, supported compressed arithmetic/memory/branch/jump
formats, and explicit zero offset for C.JR/C.JALR. Floating memory cases are
parameter-gated. Unsupported compressed double-width memory remains don't-care
because existing legality traps it. Raw encoding controls legality independently.
Existing internal immediate calculations no longer drive the final output;
synthesis can prune them. No new stage, and no changes to trap/valid controls.
Goal: remove legality/capability serialization from immediate[20]'s reported
critical path. Diff reviewed; no tests or synthesis run. Benefit unmeasured.


### 2026-11-14 - field-oriented DecoderSlice rewrite

Replaced instruction-by-instruction packet assembly, operation-derived capability
selection, whole-packet compressed/full muxing, and relevant_fields with explicit
per-output case tables/equations. Encoding predicates feed ALU, BRU, MUL/DIV,
FP arithmetic/conversion, memory, atomic, system, CSR, capability and lane
selection independently. Register identities/banks wire directly from predecode.
Immediate format decoding remains independent. Removed canonical compressed
expansion; compressed legality now checks the encoding fields directly.

Legality is a separate cone retaining the prior instruction/CSR policy, including
read-only-zero CSR ranges, unsupported extensions, rounding encodings, LR rs2,
FP conversion constraints, compressed reserved encodings, ECALL and EBREAK.
Trap output qualifies operand validity, routing to CAP_ALU/INTEGER, and defined
BR_NONE/MEM_NONE/ATOM_NONE/SYS_NONE/CSR_NONE suppression controls. Payload defaults
are don't-care. No produced payload field is used to classify another payload
or capability. The constant SUPPORT_* guards remain on predicates and legality.

Correctness obligations: f0 remains a valid FP operand; x0 has no dependency;
CSR zimm/legality use raw bits, not unused-source predecode values; C.JR/JALR
retain zero offset; FP conversions keep their separate capability; BR_NONE stays
defined for the integer lane's parallel branch unit. No pipeline latency change.

Tradeoff: independent truth tables can duplicate encoding terms or increase
instruction fanout, and required trap qualification still creates control paths.
The goal is removing payload serialization through operation/capability decoding,
not a guaranteed timing gain. Static field/encoding and diff review performed;
no test suite, simulator, lint compiler, or synthesis run. Baseline before the
unmeasured immediate experiment/rewrite: 7.526 ns data, -2.570 ns routed slack.
The immediate-only intermediate edit was not measured separately.


### 2026-11-14 - serial-only occupancy and RF readiness

IssueContract now applies serial_active and earlier-serial blocking only to
CAP_SYSTEM/CAP_CSR. Issuer no longer stops allocation after a serial instruction;
a younger independent nonserial can coissue. The single serial lane and contract
still prevent two serial instructions issuing together. In-order prefix remains:
a blocked serial at the head blocks younger instructions of any type.

Shared producer_countdown initializes serial writes to EXECUTION_UNROLL + 2.
Producer index still starts at zero and advances normally. Countdown becomes
one at index EXECUTION_UNROLL+1, permitting issue whose next-cycle operand read
uses the RF, matching Issuer's existing read_reg_file threshold. Both actual
table writes and decode fresh-write overrides use this helper. This does not
mark an unfinished serial result ready immediately or add FP table support.
Floating destinations remain excluded from the integer table; FP bank/rs3
tracking is still a separate unimplemented requirement. Static diff review only;
no simulation or synthesis run. Serial completion must prevent pipeline motion
past writeback until its result is available, as with other variable-latency units.


### 2026-11-14 - explicit producer-table writer selection

Replaced ProducerTable's integer selected_writer sentinel, variable payload
indexing, and dynamic op_age comparisons with per-entry constant-index write
candidates (op_wb and destination match), late acceptance hits, and explicit
slot-priority payload selection. Highest matching slot wins, relying on Issuer's
program-order slot numbering (op_age equals slot). op_age port retained for
interface compatibility but no longer controls table priority. Works at parameter
widths by elaborating the same fixed-slot selection; current issue supports 1/2.

x0 never accepts a write. No added buffer or cycle; reset, stall, redirect hold,
new-write index/countdown, and saturating aging semantics unchanged. Intended
benefit is shallower/clearer write control after acceptance; synthesis may have
already simplified the prior implementation. Diff review only, no tests or
synthesis. Latest user baseline: 7.022 ns data, -2.546 ns slack, packet validity
through issue allocation to actual capability_table[29][1]/R. This entry also
records that the preceding field-oriented decoder rewrite moved the reported
worst path out of decode; endpoint setup/skew absorbed most of its data gain.


### 2026-11-14 - prune next_pc from frontend payload

DecoderSlice drives the reserved common.next_pc field only as don't-care; no
fall-through adder remains there. Issuer replaces that field with don't-care in
its packet candidates before lane muxing. The field remains in Definitions for
interface compatibility. IntegerLane computes PC + compressed/full instruction
length locally for link results and predicted-taken recovery, preserving its two
existing consumers. No new stage. Diff review only; no tests or synthesis run.
Latest preceding output worst path: capability -> allocation -> PC output mux,
7.020 ns data / -3.263 ns slack; output capture constraints differ from the prior
register endpoint. Pruning next_pc is an area/fanout hypothesis, not a measured
fix for the PC[14] path itself.


### 2026-11-14 - representative lane input sinks in FrontendTop

FrontendTop now routes raw Dispatch outputs into generated per-lane input
registers and exposes those registered packets/valids at its existing outputs.
Serial/integer/memory/floating lane ordering and capability-array indices match
Dispatch. Common state is retained conservatively (next_pc always unspecified);
integer lanes retain only configured ALU/BRU/MUL/DIV chunks, memory lanes retain
memory/atomic chunks according to masks, floating lanes retain FP/conversion
chunks, and serial retains CSR/system. Global extension guards and bypass
parameter prune unavailable consumers. Integer bank flags and floating immediate
are unspecified. Payload captures only on acceptance and !stall; reset/redirect
clears valid, stall holds. This is a synthesis sink model, not a backend.

External FrontendTop observation now includes one backend-input register cycle.
OOC issue paths terminate at real capture registers instead of ideal-clock output
ports. Results are therefore not directly comparable to earlier raw-output slack.
Serial/memory/floating implementations are stubs, so their field consumption is
an intended conservative model, not validated actual downstream usage. No actual
execution/result/ready/LSU state is instantiated. No tests or synthesis run;
static diff reviewed. Existing raw frontend interface users must account for
registered outputs. README updated.


### 2026-11-14 - local issue/backend optimization pass

Baseline reports copied to build/frontend_ooc/snapshots/*_before_local_cleanup.
Latest user baseline: capability -> issue allocation -> actual x16 capability
CE, 7.152 ns data, -2.461 ns slack, 9 LUT levels, 82.299% routing. Lane input
sink registers remain the timing model; no constraints or stage boundaries changed.

IssueContract: compatibility generation is now separate from resource evaluation.
For supported widths 1/2, replace subset enumeration/popcounts with nonempty-mask
and two-distinct-lanes checks. Slot 1's simplified resource result is meaningful
when slot 0 can issue; prefix acceptance masks all other cases. Generic wider
fallback retained. No changes to accepted prefix, RAW, serial rules or lane policy.

Issuer: parallel first-set-bit encoders for available and preferred lane masks,
then select their one-hot outputs. Same lowest-lane preference and scarce-lane
lookahead, without the late preference mux feeding an integer priority encoder.
Unaccepted packet payload is now unconstrained by acceptance: packet muxes use
index_array directly, with valid/capture guards authoritative. This removes an
unnecessary accept dependence from wide payload muxes; unaccepted payload must
not be observed as valid. next_pc remains don't-care.

Backend: BranchUnit selects PC versus JALR source before one target adder instead
of forming two target additions and selecting their results; JALR bit-zero
clearing is preserved. ArithmaticUnit shares a 33-bit signed right shifter, using
a zero or sign extension bit for logical/arithmetic shift. Disabled MUL/DIV
completion payloads are don't-care, with completion-valid held false. No unit
latency, register, arithmetic result, or scheduling behavior intentionally changed.

Review also covered register files, prediction, MUL/DIV interfaces and integer
operand/control consumers; avoided speculative changes to tuned MUL/DIV datapaths
and architecturally defined zeros. Plain case defaults only; no default inserted
into unique case. Updated README. Static RTL/diff inspection only; no tests,
lint compiler or synthesis run. Benefits remain unmeasured and resource sharing
may already have been inferred by Vivado; placement can regress despite simpler RTL.


### 2026-11-14 - contract-driven producer write enable

Issuer now computes one op_write qualifier per slot from issue_good, reset/stall/
redirect masking, integer rd-valid/bank and nonzero rd. Removed separate op_accept
and op_wb ports from table/decode wiring. ProducerTable only combines op_write
with destination match; Decode uses the same qualifier for fresh-write overrides.
Lane payload still comes from allocation, but capability/countdown write-enable
no longer waits for that allocation. Correctness relies on exact agreement of
IssueContract and allocator at supported widths 1/2, already required by direct
issue_consumed. No buffers, pipeline changes or acceptance-policy changes.

Preceding cleanup user result regressed from 7.152/-2.461 ns to 7.359/-2.740 ns,
9 LUT levels, 83.504% routing; launch changed to rs2 producer index and endpoint
remained actual capability CE. This enable change is unmeasured. Static diff
review only; no tests, lint or synthesis run. README updated.
