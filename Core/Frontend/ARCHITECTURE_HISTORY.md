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

InstructionMemory reads and captures halfword alignment every edge without payload
reset; reset clears only response validity. Queue reset/validity gates consumption.

Main implementation uses Default synthesis and RuntimeOptimized opt/place/route,
without physical optimization. Standard routed reports/checkpoint are written directly
after routing. frontend_retry.tcl remains a separate optional checkpoint experiment.



ProducerTable registers one-bit capture-edge eligibility per entry alongside
index/capability, then source addresses select those registered bits. Decode corrects these ready bits independently of full metadata,
then applies prospective new writers for its registered operand lookahead.


Decode computes next-cycle operand eligibility separately for every possible
consumption prefix, including prospective newly issued writers. It registers the
selected operands_ready bit with each packet. IssueContract no longer evaluates
corrected index/capability: it combines this bit with structural flags, validity
and live serial occupancy. Full buffered correction still builds forwarding payload.


Decode precomputes source matches against current issue-candidate destinations and
registers them with the next packets. Issuer qualifies these bits with next-cycle
buffered op_write rather than comparing addresses in its correction path. Decode's
current-buffer absorption reuses these matches for retained packets; fresh
arrivals still compare addresses directly.


Queue owns encoding legality: system/CSR trap results are precomputed alongside
prediction and captured with its payload; InstructionLegality evaluates remaining
checks and selects that result before FIFO insertion. Four trap bits are stored with each FIFO entry and
carried through the same speculative serve selection as the instruction.
DecoderSlice consumes the carried result without repeating legality decoding.


**Current stall policy:** Decode freezes packet payload, producer snapshots,
structural flags, retained-use bits, lane tags, validity and occupancy on global
stall. Fetch consumption is zero. Reset/delayed-reset/redirect override the hold
for validity, structural flags and occupancy. Candidate aging/count/prefix logic
assumes advancement; only register enables and outward consumption depend on stall.
Earlier refill-during-stall descriptions below are superseded by this policy.


1. Fetch reconstructs complete instruction words. RegisterSlice extracts rs1/rs2/rs3/rd, their register-bank flags, encoding-only operand-use bits and capability alongside branch prediction, using the same extension support parameters as decoding.
2. Source addresses are latched with prediction results, compacted into the instruction FIFO, and carried through speculative serve windows with instruction, PC, validity, and prediction flags.
3. For every possible consumption count, Fetch registers a candidate next serve window and matching FIFO head, occupancy, and free-space state. A registered binary consumption count selects the remaining banked payload and FIFO state combinationally. Serve validity instead directly captures the selected next-window valid bits, with explicit flush clearing. rs1/rs2/rd and their bank flags instead select the matching completed candidate before a single output register, directly driving next-cycle producer reads. The instruction word, compressed flag, trap bits, capability and FP-consumer flag likewise select before capture, directly driving next-cycle decoding; all other payload fields remain banked. Dual issue has three outcomes: 0, 1, 2.
4. Decode directly uses the carried source addresses for producer-table reads and DecoderSlice packet source fields. It counts validity from the selected serve window, decodes instructions through independent per-field logic, and latches source metadata with packets. Metadata ages while retained and on the capture edge of a fresh table read, on advancing captures; Decode holds all packet-related state during global stall. Table reads expose raw indices; Decode ages fresh reads, retained snapshots and buffered corrections locally before their correction mux.
5. Issuer registers accepted integer writes in a one-advancing-cycle buffer, suppressing older duplicate destinations before capture. Buffered rd/source matches correct both readiness and forwarding; all buffered writers precede all current Decode packets.
6. Decode absorbs buffered corrections into retained and refill metadata. Candidates are independently aged before correction selection, equivalent to aging the selected producer; the producer table commits the same buffer at index one. Stall holds buffer/table progress and all Decode packet-related state; corrections and refills resume on the first advancing edge. Reset/redirect clears buffer validity. No live Issue write reaches Decode refresh or table inputs combinationally.

Source extraction's module file remains under Dispatch even though Fetch instantiates it. The old instruction-counted history remains removed; the current write buffer is replaced every advancing cycle, including idle cycles.

Current producer metadata contains only index, lane, and capability. Decode lookahead derives readiness from index/capability and configured execution/divider bounds; no countdown state or wiring remains. RF-position entries are ready independently of capability.

FrontendTop's representative lane input payload registers capture every unstalled
cycle; acceptance controls only validity. IntegerLane's actual input payload latch
uses the same rule. Invalid payload is unspecified and must not be observed as
an instruction; global stall still preserves in-flight payload.

Lane allocation preselects distinct compatible lanes from packet capabilities and
validity, independently of issue_good. Packet muxes follow those assignments;
IssueContract only authorizes their acceptance/consumption/write validity. A valid
but blocked younger packet can affect the older packet's lane preference.

Decode precomputes lane-resource feasibility, same-group rs1/rs2 RAW and serial/serial conflicts between
fixed retained/refill packet candidates. Independent constant-consumption outcomes incorporate occupancy, validity and
flush before a direct issue_consumed mux selects bits for registration alongside
the next packet group. IssueContract consumes
those registered flags; producer readiness and live serial occupancy remain local.

Decoder capability/lane type follow encoding independently of trap legality.
Capability is predecoded in Fetch and carried through prediction, FIFO and serve
banks into DecoderSlice. RAW precomputation uses carried encoding-only operand-use
bits, allowing false hazards on illegal instructions. Trapping packets keep their
classified route; trap_type and legality-qualified
operand/write/side-effect controls remain authoritative. All implemented lane
classes must deliver traps; noninteger lane execution remains unfinished.

Issuer supplies Decode with issue_select_count: the unmasked normal contract count. Effective issue_consumed/acceptance still suppress reset and
redirect. Decode uses the internal count for candidate selection; its validity,
occupancy reset and outward serve_consumed independently enforce flush.

Decode producer snapshots now resolve retained/refill metadata separately for each
constant consumption outcome, using registered occupancy. issue_select_count directly
selects the complete snapshot into its register, without post-mux validity/flush gates.

DecoderSlice also consumes carried operand-use bits: actual rs1/rs2/rd validity is
ok AND the corresponding predecoded bit. MUL/DIV/atomic/CSR class predicates use
carried capability; detailed operation and legality decoding remain local.

Decode packet movement now uses unmasked issue prefix bits directly.
issue_select_any resolves zero/one-pop occupancy candidates; issue_select_two
selects the all-fresh pair at the final mux. Only selected packets are registered.
Producer snapshots and structural flags retain binary-count outcome selection.

Decode snapshot indices capture every advancing edge. Lane/capability identity
registers use explicit permissive enables: !stall AND (any consumption OR slot
invalid OR retained-source buffered-write match), independently for rs1 and rs2.
Their data still comes from fully corrected next-source candidates.

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

### Earlier frontend work ï¿½ reconstructed history

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

### 2026-11-12 ï¿½ speculative serve windows

Baseline checkpoint: 798799b (Prototype 1.5), verified pushed before editing.

Problem: issue decision propagated through consumption, decode admission, serve retention/refill, and FIFO head arithmetic or serve-register control in one cycle.

Change: register all possible next serve windows and matching head/occupancy/free counts alongside actual consumption; select after the edge. Remove the old incoming_serve_valid lookahead interface and decode's separate registered valid count. Count validity from the selected window instead.

Tradeoff: extra candidate storage and a mux before decode. No extra instruction pipeline cycle. The late backward path was broken, but selection now precedes decoding and producer lookup.

Measured next worst path: registered consumption selector -> serve mux -> source decoding -> producer metadata -> decode register. Data 8.372 ns, slack -3.445 ns, routing 7.009 ns. The older deadbeef baseline was data 7.920 ns / slack -3.307 ns, so this was a structural improvement, not a demonstrated overall win against that particular baseline.

### 2026-11-12 ï¿½ source predecode moved into Fetch

Change: instantiate RegisterSlice on reconstructed packets alongside prediction; carry 10 source-address bits through prediction registers, FIFO, and candidate serve banks. Decode table reads use these addresses directly. At this stage fresh refresh comparisons also used them; floating-bank guards still came from full decode.

Cost: wider stored entries and more early extraction logic. Benefit: source extraction moves ahead of serve-window registers.

An editing error passed SUPPORT_* overrides to InstructionMemory as well as Queue; synthesis rejected the nonexistent parameters. Removed those overrides from InstructionMemory.

Measured new worst path: queued capability -> issue allocation/acceptance -> producer refresh -> decode rs1 lane register. Data 7.862 ns, slack -2.863 ns (0.582 ns improvement). Approximate contributions: launch/distribution 1.283 ns; allocation/shared control 3.859 ns; refresh/FIFO selection 2.720 ns. Synthesized input_age names represent shared slot/allocation selection, not an age counter in the dependency path.

### 2026-11-12 ï¿½ issued-instruction producer history

Committed baseline before this edit: a959710 (Prototype 1,6). Working tree was clean.

Snapshot: build/frontend_ooc/snapshots/20261112_234049_before_write_history/ contains the available reports and exact baseline commit hash. Snapshot directory is a local build artifact; retain/copy it separately if build outputs are cleaned.

Change: remove same-cycle accepted-write refresh and its ports from Decode. Decode now only ages/moves snapshots. Issuer owns an ISSUE_WIDTH-entry history, oldest first, shifted once per accepted instruction in program order. No-destination instructions insert invalid entries. Age retained history with the table; hold on global stall; clear on reset/redirect. Match source registers against valid integer history entries, youngest first in priority, and feed corrected values to IssueContract and forwarding construction.

Intended timing effect: replace allocation -> decode refresh with registered history -> match/select -> issue readiness/allocation. No permanent absorption of history corrections into decode is required under the queue-depth/in-order invariant above.

Status at implementation: diff formatting checked, with measurement pending. The subsequent user-run routed result failed the timing objective and the experiment was reverted on 2026-11-13; see the detailed postmortem below. No functional failure was established, and no simulation was run by the assistant. Floating producer tracking and redirect recovery remained unresolved.

## Maintenance

Append a dated entry for every subsequent frontend architecture/timing change, including reversions. Record motivation, affected stage boundaries, data alignment/control invariants, costs, validation actually performed, and measured results when available. Distinguish hypotheses from measurements. Update Current information flow when behavior changes; preserve historical entries. Do not infer exact LUT semantics solely from optimized net names.

### 2026-11-13 ï¿½ revert history and apply local optimizations

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


### 2026-11-14 - one-cycle producer write buffer with absorption

Baseline HEAD and local origin/main both 0bec3e9fb4b19caec631515739463fd8e0eb9cb6;
working tree clean before edits. User reported the contract-driven enable helped
slightly; no new numerical result supplied in this task.

Issue.sv now registers qualified integer writes and lane/capability/destination.
Older same-destination slots are invalidated before capture, so correction and
table payload selection use mutually exclusive matches without youngest priority.
No-write advancing cycles clear valids; global stall holds pending writes and
payloads. Reset/redirect discards buffer validity. This is not an instruction-
counted history and does not depend on issuing a full group to expire an entry.

Buffered producers are index zero with the shared initial countdown. They override
Decode snapshots before BOTH IssueContract readiness and issuer forwarding fields.
Decode.sv absorbs these same buffered corrections into every retained/refill source,
including retained slot zero, then ages on an advancing edge. All buffer writers
precede current packets; bank qualification prevents integer/FP aliasing and x0
never enters the buffer. ProducerTable.sv commits at index one and saturating
initial countdown minus one, matching that edge's backend motion and Decode capture.
Top.sv wiring is unchanged apart from documenting the delayed signal semantics.

Correctness review covered single issue, zero issue, FIFO shift/refill, successive
writes to the same rd, duplicate destinations within a group, and stall/refill.
A waiting packet permanently absorbs a correction before its buffer entry expires;
fresh reads bypass the not-yet-committed table write through Decode absorption.
During stall, buffer/table hold while Decode may refill and absorb without aging.
Same-group RAW blocking is unchanged. Redirect flushes pending speculative writes;
full backend producer-map recovery remains unresolved, as before. FP/rs3 producer
tracking remains unimplemented.

Tradeoff: breaks live issue acceptance/allocation -> table/decode-refresh paths,
but adds buffered rd matching and selection before readiness and allocation.
No extra instruction issue latency is intended. Timing improvement is unmeasured;
the previous history experiment regressed, and this distinct absorption-based
buffer also needs user-run timing measurement. Static RTL/diff review only;
no tests, lint compiler, simulation, or synthesis run. Dispatch README updated.

### 2026-11-15 - targeted speculative-selector fanout experiment

User authorized baseline inspection, main synthesis/implementation, and post-run
comparison. Saved original reports and checkpoints under
build/frontend_ooc/snapshots/20261115_before_selector_replication.
The temporary selector_probe_tmp.tcl reads the routed checkpoint, reports overall
and selector-launched paths, and enumerates directly driven selector LUT loads.
Baseline: 7.189 ns data, -2.208 ns slack; selector -> rs2 lookup/correction ->
Decode source-index capture. Six first-level selector LUT outputs have 97 logical
loads each. This records the measured result of the preceding write-buffer change.

frontend_ooc.tcl now discovers LUT drivers connected directly to registered
prev_serve_consumed Q pins after placement. Outputs with more than 24 logical
loads receive FORCE_MAX_FANOUT=16 (a physical fanout limit), followed by
phys_opt_design -fanout_opt. Synthesis Default, opt/place/route RuntimeOptimized,
part, clocks, IO constraints, and RTL remain unchanged for this experiment.
No instruction, metadata, or handshake behavior changes. Cost is replicated LUTs
and additional physical optimization runtime; placement/routing can still regress.
Results and actual validation are recorded below after completion.

The initial property-plus-ordinary-fanout pass completed but Vivado declined to
replicate the critical selector nets (Physopt 32-572); it replicated redirect
logic instead. Actual routed WNS was -2.268 ns versus -2.208 ns baseline.
Saved this intermediate result under snapshots/20261115_selector_ordinary_fanout.
Changed the main flow to explicit phys_opt_design -force_replication_on_nets
for the discovered selector targets, retaining FORCE_MAX_FANOUT=16. The forced
pass replaces the ordinary fanout pass rather than adding a general optimization
sweep. A second full main-flow run validates this command and its routed result.

Forced-run result: main synthesis and implementation completed with zero errors.
Vivado explicitly created 42 additional LUT instances across six targeted nets;
final slice LUT use rose 6652 -> 6694, registers unchanged at 3384. Logical loads
can exceed 16 because FORCE_MAX_FANOUT limits physical site-pin loads.
Overall routed data delay 7.450 ns / WNS -2.527 ns (baseline 7.189 / -2.208).
New overall worst path: buffered op_rd -> correction/readiness -> issue_consumed
-> Decode FIFO metadata selection -> rs2_index register. Thus overall WNS
regressed 0.319 ns. Worst selector-launched path also regressed: 7.310 ns data,
-2.330 ns slack, versus baseline 7.189 / -2.208, to the same endpoint but launching
from selector bit 1 rather than bit 0.

On these worst selector paths, selector decode output routing improved 0.988 ->
0.821 ns, but selector-register distribution worsened 0.354 -> 1.039 ns; launch
net fanout grew from 9 to 51. From launch clock edge (excluding clock insertion)
to the first producer-lookup LUT input, delay increased 2.747 -> 3.148 ns.
Replication moved distribution pressure upstream; this experiment did not improve
the timing objective. These compare worst selector paths, not identical bit arcs.
Hold WNS remains -1.191 ns; this is not a timing-clean/signoff result.

The identical temporary probe was run before and after, producing
build/frontend_ooc/selector_before.rpt and selector_after.rpt; it was then deleted.
The tested forced-replication block remains in frontend_ooc.tcl for user review;
recommend reverting it rather than adopting this particular setting. No RTL edits
in this experiment. No simulation or permanent tests added. Earlier uncommitted
write-buffer RTL changes were preserved. Existing OOC port-routing and synthesis
warnings remain. Diff formatting checked. Main runs took approximately 3m42s
(ordinary) and 3m47s (forced), including synthesis, reports, placement, and routing;
the forced physical optimization itself took about 6 seconds.


### 2026-11-15 - revert forced selector replication

At user request, removed the selector discovery, FORCE_MAX_FANOUT property, and
post-place forced physical optimization block from frontend_ooc.tcl. Restored
Default synthesis with RuntimeOptimized opt/place/route, following the measured
WNS regression from -2.208 to -2.527 ns. Updated Dispatch README. No RTL,
handshake, stage, or metadata behavior changed; existing write-buffer work stays.
Experimental reports/checkpoints and baseline snapshots are preserved. Current
build outputs still describe the experiment until another run overwrites them.
Validation: inspected restored flow and checked diff formatting; no synthesis,
implementation, or tests rerun for this removal.


### 2026-11-15 - age producer candidates before selection

ProducerTable.sv now computes saturating capture_index/capture_countdown per
architectural register before the rs1/rs2 lookup mux. Read outputs are capture-edge
progress, not raw current progress. Decode.sv no longer ages fresh table outputs;
it ages retained snapshots and each buffered write independently, then selects
between the aged alternatives. Issue still sees current-cycle snapshots with
index-zero buffered corrections; actual table register update logic is unchanged.

Invariant: age(select(current, write)) equals select(age(current), age(write)).
Every candidate ages exactly once on an unstalled capture edge. Index saturates
at EXECUTION_UNROLL+2 and countdown at zero. Global stall leaves progress unchanged
but still permits correction absorption and FIFO refill. Reset/redirect invalidates
Decode payload; the actual table continues holding on redirect. Buffered writes
remain integer/nonzero qualified, unique by destination, and youngest-at-capture.

Reason: remove aging/bounds logic from after the late source lookup/correction
mux. No pipeline latency, acceptance, FIFO, or metadata-state ownership change.
Tradeoff: per-entry combinational aging may increase logic/fanout, though table
update arithmetic may share it. Synthesis might already perform the transformation;
timing improvement is unmeasured. This does not remove the serve mux or table-read
chain, so a larger architectural change may still be necessary. Updated current
flow and Dispatch README. Static source/diff review only; no tests or synthesis.


### 2026-11-15 - dedicated one-hot source serve selection

Fetch/Queue.sv now registers separate one-hot consumption choices per served
position and per source (rs1/rs2). Each drives only its six-bit address/bank-flag
masked-OR mux across speculative banks. Other payload, rd/rs3, validity, and FIFO
state retain binary prev_serve_consumed selection. Narrow DONT_TOUCH attributes
on selector registers prevent equivalent source copies being merged together;
no preservation added to candidate banks, mux logic, or the broad payload path.
Dual issue adds twelve selector bits (two positions x two sources x three outcomes).

Both selector encodings capture the same serve_consumed on the same edge as the
candidate banks. Reset/reset_reg/redirect select outcome zero in both encodings;
queue validity still flushes. No extra stall enable: the existing queue can refill
while backend stalls, and both encodings must keep following the same consumption.
Legal counts remain 0..SERVE_WORDS. Source fields and bank flags cannot diverge
from instruction/PC/validity. No producer-table or issue-contract behavior changes.

Goal: move binary selector decoding before the register and isolate source mux
select distribution from the wide payload, unlike the failed combinational LUT
replication experiment. Cost: additional FFs/reset loads and consumption fanout;
the backward consumption-to-selector path may worsen. Physical locality and timing
improvement remain unmeasured; DONT_TOUCH limits optimization of those registers.
Static field-layout/control and diff review only; no synthesis, simulation, or
tests run. Current flow and Dispatch README updated. Prior age-before-selection
changes remain in place; this measurement will include both unless separated.
This very well may need to be reverted. Improved WNS but hurt TNS by ~200ns


### 2026-11-15 - remove redundant producer countdown state

Removed countdown table registers, reset/write/aging logic, read muxes, Decode
snapshot fields, correction payload bits, Issuer/IssueContract ports, and Dispatch
wiring. Deleted the unused producer_countdown helper from Package/Definitions.sv.
Affected Dispatch files: ProducerTable.sv, Decode.sv, Issue.sv, IssueContract.sv,
and Top.sv. Backend packet/interface remains unchanged.

IssueContract now derives readiness using constant index comparisons selected by
producer capability. ALU: always countdown-ready; BRU/MEMORY: index >= 1;
MUL: index >= min(EXECUTION_UNROLL,2); DIV: index >= min(EXECUTION_UNROLL,
ceil(32/DIVIDER_AUTO_PIPE)+2); SYSTEM/CSR: index >= EXECUTION_UNROLL+1;
other existing capability cases: index >= EXECUTION_UNROLL. Issuer explicitly
passes EXECUTION_UNROLL and DIVIDER_AUTO_PIPE to IssueContract. A plain case
uses a default for the prior helper's fallback; no default added to unique case.

Equivalence: before saturation, old countdown=max(initial_countdown-index,0),
and old countdown<=1 equals index>=initial_countdown-1. All thresholds precede
RF_INDEX, so saturation preserves readiness. RF/reset entries bypass capability
classification entirely because capability is unspecified at reset. The separate
index-zero ALU/bypass-enabled check is unchanged, as are same-group RAW checks.
Buffered producers remain index zero; table commit and Decode absorption advance
to index one, unless stalled. Pre-lookup aging now applies only to index.
Serial and iterative-unit completion still rely on existing backend stall rules.

Expected savings are redundant counter flops/decrementers, lookup and correction
mux bits, and their fanout. Tradeoff: readiness now depends on producer capability
and index comparisons in Issue. No instruction latency or queue protocol change;
benefit is unmeasured. One-hot source selectors and earlier index-aging changes
remain. Static interface/reference, formula, and diff review only; no synthesis,
simulation, lint compiler, or tests run. README/current flow updated.

### 2026-11-15 - latest routed report checkpoint

At user request, preserved the routed reports generated 2026-11-15 01:23:59
under build/frontend_ooc/snapshots/20261115_012359_latest_routed.
Use this as the latest reported comparison baseline: data delay 6.905 ns,
WNS -2.167 ns, nine LUT levels, logic 1.380 ns, routing 5.525 ns (80.015%).
Launch: dispatch/issuer/op_rd_reg[0][2]/C.
Endpoint: lane_inputs[2].decoder_packet_reg[2][common][pc][28]/CE.
Clock period 5.000 ns; skew -0.108 ns. This is a buffered destination through
issue control to backend sink capture-enable path, not PC payload computation.
Exact RTL provenance of this user-run build was not verified; do not attribute
these numbers specifically to countdown removal without checking the build inputs.
Report inspection/copy only; no synthesis or RTL changes performed in this task.


### 2026-11-15 - fixed producer ready-index replaces capability

ProducerTable, Decode, Issuer, IssueContract and DispatchTop now carry ready_index
at UNROLLED_W width instead of producer DecodeCapability_. Issuer classifies the
instruction capability once before capturing the accepted-write buffer. The fixed
threshold travels unchanged through commit, reads, absorption, and correction;
only producer index ages. Issue readiness is index >= ready_index. Instruction
packet capability remains intact for lane allocation and execution.

Thresholds preserve prior behavior: ALU 0; BRU/MEMORY 1; MUL min(unroll,2);
DIV min(unroll,ceil(32/divider_auto_pipe)+2); serial unroll+1; fallback unroll.
Non-ALU thresholds are clamped to at least one so zero uniquely means ALU bypass,
including unroll=0 configurations. This folds the prior non-ALU index-zero bypass
prohibition into readiness without changing final issue eligibility. BYPASS_ENABLED
still separately blocks index-zero consumers when disabled. Future non-ALU bypass
requires revisiting this encoding. Variable-latency completion remains backend-owned;
FP dependency/rs3 tracking is not added by this change.

Reset table entries get index=RF_INDEX and ready_index=0, ensuring defined ready
state without reading unspecified metadata. Stall holds advancement; buffered-write
capture/redirect validity and same-group RAW rules are unchanged. No new cycle.
Expected benefit: smaller producer payload for small unroll and simpler Issue
comparators; tradeoff is moving threshold decode to buffer D inputs and possible
wider fields at large unroll. Timing remains unmeasured. Static interfaces,
threshold equivalence, reset/stall, and diff checked; no tests or synthesis run.
README/current architecture updated. Pre-change user report after countdown removal:
6.266 ns data / -1.687 ns slack, eight LUTs, 5.097 ns routing, queued rs1 through
correction/readiness/allocation to backend sink CE.


### 2026-11-15 - revert fixed ready-index experiment

At user request, restored producer capability storage/interfaces in ProducerTable,
Decode, Issuer, DispatchTop, and IssueContract. Restored capability-based position
threshold readiness and explicit CAP_ALU bypass checking in IssueContract; RF
entries bypass unspecified capability. Removed write-side ready-index calculation
and threshold reset state. Countdown removal, index aging before selection,
write buffer, and one-hot source serve selectors remain intact. No new measurement
was supplied for the ready-index experiment; do not label it a measured failure.
Updated README/current description, preserved experiment history. Static reference
and diff review only; no synthesis or tests run.


### 2026-11-15 - parallel source eligibility before correction selection

Issue.sv computes each Decode snapshot's eligibility directly from its uncorrected
index/capability, combining readiness thresholds and the index-zero bypass rule.
Each buffered writer's eligibility simplifies to BYPASS_ENABLED && CAP_ALU because
buffer entries represent index zero. These writer bits are shared by all sources.
Explicit per-source destination matches drive both a parallel one-bit eligibility
selector and the independent forwarding index/lane selector. Issuer no longer muxes
producer capability into corrected metadata because there is no downstream consumer.
The table, Decode snapshots, and write buffer still retain producer capability.

IssueContract.sv now takes rs1_eligible/rs2_eligible instead of producer metadata.
It applies operand-valid masking and retains one copy of RAW, resource, serial,
prefix and validity checks. Removed its now-unused producer timing/bypass parameters.
No state or pipeline latency added, and no allocator/contract duplication. Reset/RF
snapshots remain eligible without depending on unspecified capability. Index-zero
non-ALU producers remain blocked, including unroll zero; disabling bypass makes
all buffer candidates ineligible. Unused operands remain ignored. Integer/FP bank
qualification, nonzero write qualification, unique buffered destinations, stall,
redirect, and correction absorption are unchanged.

Goal: replace match -> metadata mux -> readiness decode with parallel candidate
checks -> match-controlled one-bit selection. Comparisons and a late eligibility
selection remain necessary; the prior 1.023 ns segment is not guaranteed to vanish.
Tradeoff: eligibility checks are duplicated only per snapshot and shared buffered
writer, with possible match fanout effects. Latest supplied baseline is 6.266 ns
data / -1.687 ns slack. No new timing measurement. Static interface/reference,
Boolean eligibility, and diff review only; no synthesis, simulation or tests run.
Updated current flow and Dispatch README.


### 2026-11-15 - fix synthesis identifier errors and compressed decode collision

User synthesis failed because the parallel-eligibility edit used reserved SV
keyword matches as a function argument and generate label in Issue.sv. Renamed
them match_mask and source_matches; the remaining Issue errors in the supplied
log follow those parse failures. No intended logic change to eligibility.

The same log exposed existing duplicate c_jump/c_branch declarations in
DecoderSlice.sv: immediate vectors collided with scalar instruction predicates.
Renamed only the vectors and their immediate-construction uses to c_jump_imm /
c_branch_imm. Scalar classification predicates retain their names. This restores
separate immediate and control nets; Vivado previously ignored the second
declarations, so earlier compressed behavior must not be treated as verified.
No stage/interface change; compressed immediate bit layouts are unchanged.
Static references and diff formatting checked. No synthesis or simulation rerun;
the supplied failing run does not establish validation of these fixes.


### 2026-11-15 - restore Prototype 1.9 RTL

At user request, restored all modified RTL to a0382b8 (Prototype 1.9): Issue.sv,
IssueContract.sv, and DecoderSlice.sv. Other RTL already matched that commit.
Restored Dispatch README; preserved this experiment history and the unrelated
user edit in Package/README.md. Saved the pre-reversion working diff under
build/frontend_ooc/snapshots/20261115_before_restore_prototype_1_9/working_changes.patch.

This commit records the post-countdown-removal design associated with the supplied
6.266 ns / -1.687 ns result. Parallel eligibility is removed: corrected metadata
again feeds the single IssueContract readiness/bypass checks. Countdown removal,
one-hot source selectors, index aging, and producer write buffer remain.
Latest supplied regressed path was 6.843 ns data, eight LUTs, 5.674 ns routing;
0.577 ns slower than the recorded best, entirely in routing. The comparisons
also include the compressed-decoder correction and may include configuration
changes, so do not attribute the entire regression to parallel eligibility.

Exact RTL restoration also reintroduces Prototype 1.9's known c_jump/c_branch
immediate-vector versus predicate naming collisions. The prior corrective change
is preserved in the saved patch/history. This baseline is not a correctness-
validated design. No new timing run; reported best timing has not been reproduced
in this task. Verified RTL diff against a0382b8 is empty and diff formatting passes.


### 2026-11-15 - remove acceptance from lane input payload enables

Frontend/Top.sv modeled lane inputs now capture decoder/issuer payload on every
unstalled, non-flush edge, including bubbles. dispatch_accept updates validity only.
Backend/Execute/Integer/IntegerLane.sv similarly removes accept from its stage-zero
payload enable, retaining !stall. No changes to valid pipelines, issue decisions,
producer writes, or FIFO consumption. Frontend sink reset/redirect invalidation
is unchanged; actual IntegerLane retains its existing reset/redirect valid rules.

Reviewed integer operand stall (masked by stage-zero valid), branch redirect
(stage-one valid), MUL/DIV starts (stage-one valid), result/trap qualification,
and the existing unconditional-on-advance later payload stages. Bubble payload
may toggle or be unknown but cannot represent a valid instruction. Stalls preserve
both operands/metadata and valid state; an older instruction advances using old
register values on the edge that a new bubble payload is captured. Non-integer
lanes remain stubs; frontend sinks model their required valid-qualified interface,
not verified execution behavior. No arithmetic or completion state was changed.

Goal: remove late acceptance from wide payload CE distribution (prior worst final
net had 117 loads / 1.125 ns). It still controls validity and influences selected
payload, so the worst path can move to a data pin. Tradeoff: bubble-cycle switching
increases, and consumers cannot rely on stale payload when invalid. No extra stage.
Static consumer/diff review only; no synthesis, simulation, or tests run. Timing
benefit unmeasured. Updated Dispatch README; baseline remains Prototype 1.9 plus
this change, including its documented compressed-decoder naming collision caveat.


### 2026-11-15 - remove dedicated one-hot source selectors

At user request, removed rs1_select/rs2_select registers, their DONT_TOUCH attributes,
source-specific masked-OR muxes, and consumption equality decoding in Fetch/Queue.sv.
All serve fields again select serve_bank[prev_serve_consumed][lane], sharing the
registered binary consumption choice with FIFO state. Speculative candidate banks
remain; this does not restore late consumption into their payload capture logic.

Reason: after removing payload acceptance enables, the supplied worst path moved
from buffered op_write through readiness/issue_consumed/available_slots to a
one-hot source-selector D pin. Data delay inferred from the excerpt is 6.698 ns;
full slack was not supplied. Removing one-hot encoding should reduce backward-path
work and selector-register loads, but can worsen forward source selection. The
new tradeoff is unmeasured. All payload/state fields stay aligned to one selector;
reset/redirect and FIFO/stall behavior remain unchanged. Payloads still capture
through bubbles; countdown removal, producer buffering and index-aging remain.
Updated current flow and README. Static diff/reference review only; no synthesis,
simulation or tests run. Earlier experiment records retained.


### 2026-11-15 - preselect lanes independently of issue eligibility

Issue.sv now computes assigned_lanes, index_array and issue_lane without issue_good,
reset, stall or redirect in the allocation cone. Invalid packet masks are zeroed
so unspecified invalid capabilities cannot affect older lane choices. Every valid
younger packet participates in scarce-lane preference, even if it is not ready.
Fixed assignments drive decoder/issuer payload muxes continuously. Separate final
logic combines assignments with issue_good and reset/stall/redirect masking for
accept_vector. Contract-based consumption and integer write qualification retain
their existing rules; buffered lane identity uses the exact preselected lane.

For supported widths one/two, the allocator still finds a distinct pairing whenever
both masks are nonempty and their union has at least two lanes. The older packet
uses a lane outside the younger mask when possible; otherwise either older choice
leaves a younger option whenever the pair fits. If a pair cannot fit, oldest still
gets its preferred compatible lane and contract suppresses the younger instruction.
A blocked younger packet can change which lane the older uses, but not the number
issued under the existing static compatible-lane model. Serial and RAW/prefix rules
remain contract-owned. Future dynamically busy lanes must enter compatibility.

Goal: remove late readiness from lane preference, priority selection, used-lane
masking and payload mux control. Acceptance and consumption necessarily still
await readiness. No additional contract copy, state, or pipeline latency. Possible
cost is different lane utilization/placement and a new validity fanout dependency.
Static dual-mask reasoning, interface and diff review only; no synthesis or tests.
Updated README/current flow. Timing benefit remains unmeasured. Countdown removal,
binary serve selection and payload capture through bubbles remain unchanged.


### 2026-11-15 - precompute structural pair hazards before Decode capture

Decode.sv compares ordered pairs of fixed retained and newly decoded packets for
same-group rs1/rs2 RAW (including register-bank and operand/destination-valid
qualification) and serial/serial conflicts. Existing keep/refill masks select the
pair results for the next group; the selected bits register alongside packets.
Dispatch/Top.sv and Issue.sv carry group_raw/group_serial to IssueContract.sv,
which no longer compares same-group register addresses or scans older serial ops.
Live serial_active and all producer-dependent readiness/bypass checks stay in Issue.
Updated current flow and Dispatch README.

Correctness: masks already include packet validity and preserve program order;
retained sources precede refill sources. Every shift/refill rebuilds group hazards,
so a consumed producer no longer blocks its former younger consumer. Slot zero has
no same-group predecessor. Empty/partial groups, no-pop refills, and stall refills
use the identical packet selection; flags flush on reset, delayed reset, or redirect.
No new stall enable is added because Decode may refill during global stall.
Integer x0 suppression remains rd_valid/rs_valid-owned; floating bank matching and
f0 behavior are preserved. This moves only existing rs1/rs2 checks; rs3 tracking
and floating producer-table support remain outstanding.

Reason: move payload-only hazard work ahead of Decode capture, leaving late
issue_consumed to select already calculated bits. No extra stage or replicated
producer readiness logic. Cost is extra candidate-pair comparisons and registered
flags (slot-zero constants should prune). Fresh decode-to-hazard and consumption-
to-selection paths may grow; timing benefit is unmeasured. Static interface,
selection/alignment and diff review only; no tests, lint, simulation or synthesis.

### 2026-11-15 - user-reported preemptive lane selection timing

User reports WNS of -1.699 ns for the preemptive lane-selection run, before
structural RAW/serial pair precomputation. Use this as the immediate comparison
baseline for the structural-precomputation run, which the user reports is now
running. No full timing report, path breakdown, or run configuration was supplied
with this result; no attribution of individual path improvements is established.
This records the user's measurement only. No RTL changes or tool runs performed.

### 2026-11-15 - structural precomputation first timing result

User reports regression versus the -1.699 ns WNS preemptive-allocation baseline.
Supplied excerpt launches Decode slot-zero rs1[2] and ends at group_raw_reg[1]/D.
Arrival 8.697 ns minus launch clock 1.389 ns gives 7.308 ns data delay, with ten
LUT levels. Clock-to-Q plus LUT delay is approximately 1.521 ns and routing
approximately 5.787 ns. Capture clock/required time were omitted, so new WNS
cannot be calculated from this excerpt.

The path traverses buffered correction/readiness, acceptance/consumption and FIFO
selection, then three LUTs into the newly registered RAW flag. Final segment from
the empty_slots_reg[1]_0-named net's arrival at 7.418 ns to D takes 1.279 ns;
intermediate synthesized names do not establish exact RTL field dependencies.
This identifies next-group hazard selection as the new endpoint, not proof that
pair comparisons themselves are late. Current implementation combines two packet
selection masks with pair results. A possible follow-up is explicit per-consumption
hazard outcomes followed by final consumption selection, especially for width two.
No further RTL change, synthesis, or simulation performed; outcome-selection
simplification is a proposal, not a measured improvement.


### 2026-11-15 - direct consumption mux into structural flag registers

Decode.sv now builds complete RAW/serial outcomes for each constant consumption
count. Each outcome resolves retained/refill source identities from occupancy,
qualifies source validity, reduces pair hazards, and applies flush independently
of live issue_consumed. The register assignments directly index these outcome
vectors with issue_consumed; no pair-selection mask or reduction follows that mux.
Dispatch README/current flow updated. Packet/producer FIFO selection is unchanged.

For each legal occupancy/pop combination, next slot d names old[d+pop] while
within the retained suffix, otherwise fresh[d-retained_count]. Ordered pair
checks use these same identities; slot zero remains clear. No-pop stall refills
and partial groups retain alignment. Reset/delayed-reset/redirect clear candidate
bits before selection; legal issue consumption remains a required invariant.
No extra stage, producer logic, or issue policy change. This targets the measured
three-LUT tail into group_raw; synthesis may refactor the RTL and a single physical
mux level is not guaranteed. Static mapping/interface/diff review only; no tests,
lint or synthesis. Timing remains unmeasured.


### 2026-11-15 - direct-mux result and Decode lane feasibility

User's direct-mux timing excerpt launches Fetch prev_serve_consumed_reg[0] and
ends at Decode group_raw_reg[1]/D. Data delay is 7.857 - 1.230 = 6.627 ns,
0.681 ns below the previous 7.308 ns excerpt. New WNS was not provided. The worst
path now traverses serve selection, decode and the fresh/fresh RAW candidate;
this does not independently measure issuer payload timing.

Moved static execution-lane feasibility from IssueContract.sv into Decode.sv.
Fixed retained/refill sources get compatible masks from the configured lane
counts/capability arrays, with existing SUPPORT_* disabled-capability don't-cares.
Oldest needs a nonempty mask; the younger slot needs a nonempty mask and at least
two bits in the pair union. Oldest feasibility remains enforced by the final issue
prefix. Each constant-consumption outcome resolves occupancy/validity/flush and
selects its resource result independently of live consumption. Direct indexed
capture into group_resource_bad mirrors RAW/serial flags. Dispatch/Top.sv and
Issue.sv wire the registered result directly to IssueContract's execution-unit
check. Actual lane assignment and payload muxes remain in Issuer.

Retained/refill mapping, prefix validity, shifts, stall refills and flush alignment
follow the existing structural candidates. Supports widths one/two, matching the
existing Issuer limit; Decode now explicitly rejects wider widths rather than
pretending pair checks establish wider feasibility. No new stage or dynamic
readiness prediction. Tradeoff: more fixed-source capability/pair hardware before
Decode capture, potentially worsening the now-critical forward decode path;
expected Issue simplification is unmeasured. Updated current flow/Dispatch README.
Static mask-equivalence, source mapping, interface and diff review only; no tests,
lint, simulation or synthesis performed.


### 2026-11-15 - separate capability routing from legality

At user request, DecoderSlice.sv no longer wraps capability and lane-type
classification in ok. Illegal and other trapping instructions retain the normal
encoding-class route; unknown or disabled classes fall through to ALU/integer.
Existing SUPPORT_* predicates still gate optional classes. trap_type generation,
operand/destination validity and side-effect suppression are unchanged. This also
routes ECALL/EBREAK according to their encoding rather than forcing ALU; compressed
EBREAK follows the existing compressed control-transfer classification.

Reason: remove full legality decoding from serial/resource precomputation inputs.
This does not remove legality from RAW precomputation, whose valid bits still use
ok. No stage change. Invariant: configured classified capabilities need compatible
lanes and every selected lane must propagate trap_type without ordinary effects.
Memory/floating/serial lanes remain stubs, so end-to-end trap delivery there is
not verified or implemented by this change. A class with no compatible lane can
block a trapped encoding; removing the fallback does not solve that configuration.
Updated current description and Dispatch README. Static code/diff inspection only;
no tests, lint or synthesis. Timing benefit unmeasured.


### 2026-11-15 - carry encoding-only scheduling metadata from RegisterSlice

RegisterSlice now produces rs1_used/rs2_used/rd_written and capability from the
existing encoding predicates, bank flags, register identities and SUPPORT_* gates.
No CSR/FP/compressed legality or trap decoding is included. Integer x0 is suppressed;
floating f0 remains a register. Queue carries these fields through prediction,
FIFO writes and every speculative serve candidate, widening packed serve entries
from 92 to 99 bits (3 use bits plus the current 4-bit capability). Empty/reset
candidate construction uses the derived width with validity zero and other bits X.
FetchTop, FrontendTop, DispatchTop and Decode ports carry the same metadata.
DecoderSlice takes capability directly; lane type derives from this carried class.

Decode retains the three use bits alongside packets with identical keep/refill
selection. All old/old, old/fresh and fresh/fresh RAW checks use those bits instead
of legality-qualified packet valid fields. False same-group dependencies on illegal
instructions are explicitly accepted: oldest has no pair RAW blocker, and hazards
are rebuilt after consumption. Live producer readiness, actual rd_valid/write
qualification, trap_type and side-effect controls remain legality-qualified and
unchanged. Early rd_written never authorizes a producer write. Capability remains
encoding-based for traps, with the previously documented lane-support obligations.
No rs3 dependency tracking is added.

This removes full decode legality from structural RAW candidates and moves
capability classification before serve selection. Cost: seven more bits per stored
Fetch entry/candidate, three retained-use bits per Decode slot and early combinational
classification. No additional stage. Legal-op use equations were copied from Decode
without ok; capability classification retains predicate order and extension guards.
Static packing, interface, mapping and diff review only; no tests, lint or synthesis.
Timing improvement is unmeasured. Current description and Dispatch README updated.


### 2026-11-15 - remove flush from internal Decode consumption selection

After early scheduling predecode, user reports worst WNS -2.218 ns on external
redirect_taken to Decode rs2_index_out_reg[0][1]/D. Input delay is 3.750 ns;
internal delay 4.585 ns, six LUTs, arrival 8.335 ns. The excerpt follows redirect
masking through consumption/keep selection (180-load keep net) into producer
metadata. It does not measure the new forward predecode paths. This pre-existing
control dependency can become worst through other-path improvements or placement
changes; exact relative contributions cannot be established from this excerpt.

Issue.sv now exposes issue_select_count, normal issue_good population count masked
only by stall. Effective issue_consumed remains reset/redirect/stall suppressed.
Dispatch/Top.sv passes the internal count to Decode.sv, whose FIFO payload/count
and structural-candidate selects no longer take flush-masked consumption. Decode
still clears validity, resets occupancy and zeroes outward serve_consumed on reset,
delayed reset or redirect; flushed payload is don't-care. Backend acceptance and
producer writes/buffer flush are unchanged. Stall still prevents packet removal,
while permitting existing refill behavior. Structural flags retain their flush
qualification. No added state or stage. Updated current flow and Dispatch README.
Static interface/diff review only, no tests/lint/synthesis. Intended removal of the
reported redirect-through-selection cone is unmeasured; redirect can still time
to legitimate flush endpoints and synthesis may refactor don't-care logic.


### 2026-11-15 - direct consumption mux into producer snapshot registers

Latest user excerpt launches buffered op_rd_reg[0][4] and ends at Decode
rs1_index_out_reg[0][1]/D: data delay 8.048 - 1.244 = 6.804 ns, eight LUTs.
Capture required time/WNS not supplied. Path follows producer match/correction,
readiness/consumption, 180-load keep control and producer snapshot selection.
Approximate final keep generation/distribution plus metadata tail is 2.446 ns.

Decode.sv now constructs producer_outcomes for every constant consumption count.
Generate-time occupancy choices select aged/refreshed retained sources or fresh
sources, then registered empty_slots chooses the complete candidate independently
of live consumption. A direct issue_select_count mux feeds the concatenated rs1/rs2
index/lane/capability registers. Removed producer metadata from keep/refill masked
OR logic and from the packet valid/flush-conditioned assignment block.

Invariant: d < retained_count selects old[d+consumed], otherwise fresh[d-retained].
Generated branches keep all source indices in bounds. Existing per-source aging,
write refresh, fresh-table capture aging, stall masking and buffered-write ordering
are unchanged. Invalid/flushed metadata can capture arbitrary source data; packet
validity still clears, and the first refill replaces that metadata before use.
Stall still selects consume zero and disables aging while allowing corrections
and refills. Payload/validity/structural hazard behavior is otherwise unchanged.
No added pipeline state/stage. Tradeoff: independent occupancy candidate muxes and
possibly greater consumption fanout; synthesis may refactor them. Timing unmeasured.
Updated current flow and Dispatch README. Static mapping, packed-field order,
bounds/interface and diff review only; no tests, lint or synthesis performed.


### 2026-11-15 - reuse served scheduling metadata inside DecoderSlice

Decode.sv now passes served rs1_used/rs2_used/rd_written into DecoderSlice.sv.
Replaced repeated use/zero-register/bank equations with ok AND the carried bit.
MUL, DIV, atomic and CSR predicates now compare carried capability, retaining
SUPPORT_* gates for optional payload hardware. Removed unused conversion/system
class predicates. Detailed suboperation, compressed-format, immediate and legality
checks stay local; broad capabilities cannot distinguish load/store or branch forms.

Invariant: RegisterSlice's legal-op use equations match the removed expressions
without ok and preserve integer x0/floating f0 semantics. capability is aligned with
the same instruction and produced by the existing priority classification; chosen
class substitutions are exact for that interface. Actual destination validity and
producer writes remain legality-qualified. RAW prechecks still independently permit
false dependencies for illegal encodings. No state, stage or issue-policy change.
Goal is less repeated post-serve decode logic; increased capability fanout may alter
placement, so timing benefit is unmeasured. Current flow/README updated. Static
predicate/interface/diff review only; no tests, lint, simulation or synthesis.

### 2026-11-15 - identify 16:37 routed regression report

User-pasted path matches local routed_worst_setup.rpt (16:37:53) and the later
16:44:47 extraction from frontend_routed.dcp: WNS -2.082 ns, data 7.080 ns,
logic 1.478 ns, route 5.602 ns, eight LUTs. Source Decode slot-one rs2[4],
endpoint Decode slot-zero CSR operation[0]/D. The path follows correction/readiness,
consumption and packet FIFO selection; CSR naming here denotes the selected payload,
not evidence of CSR decoding on the path. Final shared selection has 162 loads.
Data delay is 0.276 ns above the preceding supplied 6.804 ns path, with a different
endpoint. Timing summary synthesis timestamp is 16:32:29; DecoderSlice/Decode last
write is 16:35:34, so this run predates the latest served-metadata DecoderSlice
cleanup. Exact inclusion of the producer-outcome change is not established by
these timestamps alone, without an RTL snapshot. No RTL edits or runs performed.


### 2026-11-15 - early oldest-issue selection for Decode packet movement

Started from clean committed b6ea7d9 (Prototype 2.1), verified locally. Issue.sv
exports issue_select_any = issue_good[0] AND !stall, and issue_select_two =
issue_good[1] AND !stall for width two (constant zero for width one). Neither bit
is reset/redirect masked; effective acceptance/writes/consumption remain masked.
Dispatch/Top.sv wires both directly to Decode.sv.

Decode replaces packet/usage/lane/valid keep-refill masked-OR selection with
combinational occupancy choices for zero and one consumed. The oldest prefix bit
selects those alternatives first. For dual issue the younger prefix bit selects
fresh[destination] at the final mux: consuming two necessarily empties a two-entry
queue. No replicated decoders or registered candidate banks; only the final packet
is captured. Packet payload/usage/lane capture is unconditional and validity alone
flushes. Binary count still controls occupancy/refill accounting and existing
producer/structural candidate selection, so their treatment is unchanged.

Correctness invariants: issue_good is a prefix, so two implies any and both slots
valid; count equals the number of asserted stall-qualified bits. Zero/one outcomes
select retained old[d+consumed] or fresh[d-retained] with corresponding validity,
lane and use bits. Generated branches bound indices. On stall both selects are
zero, retaining packets while allowing empty-slot refill; reset/delayed reset and
redirect clear packet validity/occupancy and outward Fetch consumption. Invalid
payload can change but is unobservable. No pipeline stage or added packet state.

Reason: avoid binary count decoding/shared keep control on the measured wide
packet feedback tail; let oldest readiness resolve the first selection before
late younger readiness arrives. Cost: extra prefix-bit fanout and occupancy mux
logic; oldest arrival may not be sufficiently early, and synthesis can refactor
selection. No timing improvement claimed. Static source mapping, width-one/two,
prefix/count consistency, interface and diff review only; no tests/lint/synthesis.
Updated current flow and Dispatch README. Prior timing and experiments retained.

### 2026-11-15 - early-prefix packet selection timing result

User reports TNS magnitude reduced from roughly 1100 to 800 ns after early-prefix
packet selection (approximately 27% reduction). Supplied report WNS is -1.983 ns,
versus preceding reported -2.082 ns, an improvement of 0.099 ns. New worst path
starts at external stall with 3.750 ns input delay and ends at Decode slot-zero
rs2_index[0]/D. Internal data delay 4.386 ns (logic 0.988, routing 3.398), eight
levels including MUXF7/MUXF8. It traverses stall-dependent producer capture aging,
table lookup, buffered correction and snapshot selection. Interpretation of
individual LUT boundaries is approximate without netlist inspection. The previous
queued-rs2-to-wide-packet-selection path is no longer the reported worst path;
its new delay is not supplied. This result supports retaining the experiment,
but does not isolate every affected path. No additional RTL changes or runs.


### 2026-11-15 - restore raw producer reads and local capture aging

ProducerTable.sv removed capture_index's per-entry stall-controlled hold/advance
selection from read outputs. Reads now directly select index_table; registered
entry advancement/writes/reset behavior is unchanged. Decode.sv applies age_source
to each fresh read before buffered correction, just like retained snapshots.
Buffered corrections still age from zero to one when advancing, or remain zero
on stall. Fresh reads must age exactly once; RF saturation remains identical.

Reason: latest worst path enters through stall-dependent per-entry capture aging
then traverses the large table read mux. RTL explicitly selected hold/advance;
physical LUT absorption versus separate mux cells was not established. Local
aging removes this stall-to-read-mux dependency but adds arithmetic after source
address selection and may sacrifice sharing with per-entry state advancement.
No stage or functional timing change. Previous pre-read-aging experiment/history
retained; this reverses its read placement under the newer architecture.
Static equation/interface/diff review only; no tests, lint or synthesis. Benefit
unmeasured. Current description and Dispatch README updated.


### 2026-11-15 - freeze Decode on global stall

Started from clean local 3748638 (Prototype 2.2). Previous local-aging run reported
WNS -2.055 ns and TNS -446.081 ns; pasted worst path was stall to Decode slot-one
rs2_index[0]/D, 4.457 ns internal delay, five LUTs, dominated by routing.

Decode.sv now uses !stall register enables for packets, lane/use metadata, producer
snapshots, structural flags and normal validity/occupancy advancement. Reset,
delayed reset and redirect still clear validity/flags and reset occupancy during
stall. Outward serve_consumed is forced zero on stall, preventing Fetch from
consuming inputs that Decode did not capture. reset_reg continues tracking reset.
Candidate age_source always computes saturated advancement; candidate structural
flush gating moved to register control. Issue.sv exposes unmasked count/any/two
selection controls, while effective consumption/acceptance/writes remain stall-
and flush-masked. No fabric-gated clocks, added pipeline stages or packet banks.

Invariant: table and buffered writes hold during stall, so frozen Decode snapshots
remain cycle-aligned and pending corrections survive until resume. On first advance,
fresh/retained sources and buffered corrections age once and are captured with the
corresponding packet selection. Flush invalidates frozen payload even if it holds.
This deliberately removes refill/correction absorption during stall; the throughput
tradeoff is losing that preparation opportunity. Stall fanout now targets register
enables and outward consumption rather than candidate arithmetic/selection, and
may become a CE or Fetch-side path. No timing improvement guaranteed.
Updated current description/Dispatch README. Static stall/resume/flush-priority,
interface and diff inspection only; no tests, lint or synthesis performed. next_pc
remains unassigned and must be calculated later in execution.

### 2026-11-15 - full Decode freeze timing result

User reports WNS -1.577 ns / TNS -456.201 ns after Decode freeze, compared with
-2.055 / -446.081: WNS improves 0.478 ns while TNS magnitude increases 10.120 ns.
Pasted path launches buffered op_rd_reg[0][4], passes through producer correction,
issue qualification and named issue_select_any, then ends at Decode slot-zero
rs1_capability[0]/CE. Arrival 7.509 minus source clock 1.209 gives 6.300 ns data
path delay, eight LUTs. Final portion after issue_select_any arrival at 5.640 is
1.869 ns. CE setup is -0.150 ns. This is not the direct external-stall path.
RTL's payload enable is !stall, but the routed CE also depends on issue selection;
likely synthesis extracted additional hold enables from self-feedback metadata
selection (capability/lane can remain unchanged while index ages). Exact CE Boolean
function requires netlist inspection; no inference of a new explicit RTL gate.
No RTL change, test, synthesis or implementation run performed for this review.


### 2026-11-15 - explicit permissive producer identity enables

Started from clean local 0cccef8 (Prototype 2.3). Decode.sv separates source index
capture (!stall) from lane/capability capture. For each operand, identity enable is
!stall AND (issue_select_any OR !packets_valid[destination] OR retained_match).
Retained match uses exactly refresh_source's buffered op_write, integer-bank and
rd equality conditions, without operand-valid/legality qualification. Data remains
selected_producers from existing aged/refreshed consumption/occupancy candidates.

Invariant: without consumption a valid packet stays put, so only matching buffered
writes can change lane/capability; index still progresses independently. Any pop
permits all slots to capture shifted/refill metadata even if the outgoing source
has no match. Invalid slots permit refill capture even with no consumption.
Incoming-source matches are resolved before selection and cannot be lost when the
write buffer changes at the edge. Stall holds everything; flush invalidates payload
as before. Allows extra captures into invalid/unchanged slots intentionally.

Goal: express a shallow enable instead of synthesis-derived hold conditions through
wide metadata selection, targeting the reported issue_select_any-to-capability CE
tail. Match logic may share with existing refresh logic or increase loads; Vivado
may refactor enables again. No timing guarantee or new pipeline state. Current
flow/README updated. Static retained/refill/pop/stall/flush reasoning and diff
checks only; no tests, lint, synthesis or implementation run.

### 2026-11-15 - explicit identity enable timing result

User supplied routed path after permissive lane/capability enables: WNS -1.214 ns,
an improvement of 0.363 ns over -1.577 ns. Data delay 7.334 - 1.217 = 6.117 ns,
nine LUT levels. TNS not supplied. Worst path now launches Fetch's registered
serve-consumption selector and traverses serve selection, legality/trap-related
logic and memory-operation output selection into Decode slot-one memory.operation[1]/D.
The previous producer-correction/issue-to-snapshot-CE path is no longer worst;
its specific new delay is unknown. Approximate portions: launch/serve selection
2.695 ns, remaining decode/output/capture 3.422 ns. Synthesized field names alone
do not establish that rs1_valid itself feeds memory operation. No RTL changes or
additional synthesis/testing performed for this report review.


### 2026-11-15 - precompute trap type at speculative serve capture

Moved DecoderSlice's compressed legality, full_trap function (including CSR policy,
FP rounding restrictions and optional-extension checks), and final compressed trap
selection unchanged into Fetch/InstructionLegality.sv. Queue.sv instantiates it
per consumption outcome/serve lane on next_window instruction/compressed fields.
Its four-bit TrapType_ output captures into serve_trap_bank alongside serve_bank.
The same registered prev_serve_consumed selects both outputs. FetchTop,
FrontendTop, DispatchTop and Decode carry serve_trap into DecoderSlice's trap_in.
DecoderSlice now derives ok from the carried result; remaining operation payload
formatting and all existing legality qualification stay local. Capability routing
continues to ignore legality as previously requested. next_pc remains unassigned.

No extra stage or main FIFO/prediction width increase. For dual serve, six trap
candidates add 24 nominal stored bits plus duplicated legality logic; synthesis
may share it. Retained and refilled candidates are both evaluated from their exact
next_window word, including compression status. Empty/flush trap values are X,
qualified by the accompanying valid bit. Trap banks capture on precisely the same
edges as serve banks, including Fetch activity during backend stall; Decode holds
and outward consumption is zero during stall as before. No semantic legality changes.

Targets the measured serve-selector -> full legality -> memory.operation critical
path (-1.214 ns WNS). Full legality is not shallow hardware, but its small result
has broad downstream influence; the computation now precedes the serve latch.
Risk: FIFO/retention selection plus legality may become the new capture path and
increase area/routing. No timing gain assumed. Existing Tcl glob includes the new
Fetch SV file without flow changes. Static extracted-equation, field-offset,
interface/capture alignment and diff review only; no tests/lint/synthesis run.
Current architecture/Dispatch README updated; prior ownership history preserved.


### 2026-11-15 - move legality between prediction capture and FIFO insertion

Serve-candidate legality experiment exposed a new path from registered serve
consumption through FIFO read/candidate selection then legality into serve_trap_bank.
User excerpt arrival 8.183 minus launch clock 1.365 = 6.818 ns data delay; WNS not
provided. This is 0.701 ns above the preceding supplied 6.117 ns path, with different
endpoints. Preserve the prior experiment as unsuccessful at its intended placement.

Queue.sv now instantiates InstructionLegality once per FETCH_SLOTS on registered
prediction_payload.bp_instruction/bp_compressed. fifo_trap captures prediction_trap
using exactly the instruction's packet_commit/packet_keep/compacted write index.
Trap bits are appended to FIFO candidate and retained serve payloads; serve banks
are widened by TrapType_ width (currently 99 -> 103 bits). Removed per-serve-outcome
legality instances and the separate trap bank. Existing serve_trap interface and
DecoderSlice behavior are unchanged. Helper comment and current docs updated.

No work added before prediction capture and no added stage. Prediction stalls
retain the input word until commit; simultaneous prediction replacement uses old
registered payload/trap at FIFO write, aligned by nonblocking edge semantics.
Branch-prefix filtering, wraparound, FIFO occupancy and flush apply identically to
instruction and trap. Invalid entries remain unobservable; no trap-array reset is
needed. Serve retention carries existing trap bits without recomputation.

Tradeoff: four additional bits per main FIFO entry and legality-plus-write-selection
path on prediction-to-FIFO stage. That stage's spare timing is not measured. Expected
relief of serve feedback path is unmeasured. Static equation/source alignment,
packing widths, commit/flush and diff review only; no tests, lint or synthesis.

### 2026-11-15 - post-prediction legality timing result

User supplied WNS -1.042 ns after moving legality to prediction-register -> FIFO
insertion. New data path 7.225 - 1.204 = 6.021 ns, eight LUTs. Compared with the
failed serve-candidate legality placement (6.818 ns), data delay is lower by
0.797 ns; compared with pre-legality-move WNS -1.214 ns, WNS improves 0.172 ns.
TNS not supplied. Worst path now launches Decode slot-zero rs1[3], passes producer
correction/readiness and named issue_select_any, then ends at slot-one rs1
capability[2]/D. After issue_select_any arrives at 5.485 ns, metadata selection tail
is 1.740 ns. Forward legality path is no longer reported worst; its exact new delay
is unknown. No RTL changes or additional tool runs beyond report reading/logging.


### 2026-11-15 - register next-packet matches to next buffered writers

Decode.sv compares each fixed retained/fresh source rs1/rs2 and integer-bank flag
against packets_out[writer].common.rd, the exact issue_rd captured by Issuer's write
buffer on that edge. No live issue_good/write-valid/legality gate enters comparison.
Packed PacketChoice_ carries the match vectors through identical occupancy and
zero/one/two prefix selection as its packet. Two ISSUE_WIDTH-bit vectors per Decode
slot capture under !stall. Dispatch/Top.sv wires them to Issue.sv, whose correction
function now uses source_matches[writer] AND op_write[writer] instead of rd equality.
Nominal state increase: eight bits at dual issue. No extra stage.

Correctness: next-cycle op_write qualifies actual accepted nonzero integer writes
and retains youngest-destination dedup. Matches describe next Decode sources and
next buffer identities, not current buffer destinations. Both hold during stall.
Reset/redirect clear packet/write validity, making stale match payload irrelevant;
first resumed capture realigns packets, matches and buffer identities. Partial pop,
full pop and empty-slot refill use the same source mapping as packets. Self/younger
unaccepted candidates can compare equal but cannot qualify without op_write.
Incoming packet matches do not depend on the outgoing destination slot's source.
Current buffered writes are still absorbed into retained/refill snapshots by the
existing direct-match refresh path, and identity enables are unchanged.

Targets register equality ahead of Issue correction/readiness, avoiding a live
acceptance -> comparison chain. Comparisons add fanout to current rd/source fields
and a new consumption-selected match-register endpoint; synthesis sharing/placement
can offset gains. Timing unmeasured. Current flow/README updated. Static buffer
capture identity, packet-choice field ordering, stall/flush/dedup/interface and diff
review only; no tests, lint or synthesis. No permanent test artifacts generated.

### 2026-11-15 - registered match timing result

User supplied WNS -0.967 ns after registered source/write-candidate matches,
improving 0.075 ns over the retained -1.042 ns baseline. Data delay 7.183 - 1.246
= 5.937 ns versus 6.021 ns previously. Seven LUTs versus eight. New launch is
buffered op_write[0] (81 loads), not rd/source-address bits. Path traverses issue
qualification/count, then producer snapshot selection to slot-zero rs1_index[1]/D.
Named issue_select_count[1] arrives at 5.365 ns; remaining selection tail 1.818 ns,
including a 1.125 ns route. This is consistent with removal of live equality from
Issue correction, but specific before/after cones differ and TNS was not supplied.
No additional RTL changes or synthesis/testing performed for this review.


### 2026-11-16 - speculative next-cycle operand eligibility

Started from clean local 6d481d1 (Prototype 2.5), baseline reported WNS -0.967 ns.
Decode.sv evaluates eligibility per fixed retained/fresh source and consumption
outcome. Base eligibility uses the existing aged/current-buffer-refreshed snapshot.
For each writer below the constant assumed consumed count, valid nonzero integer rd
and precomputed next-source match override eligibility with that producer's index-zero
rule (BYPASS_ENABLED AND CAP_ALU). Ascending writer priority matches youngest-writer
buffer dedup. Current issue_good/op_write for prospective writers never gates this
calculation; actual consumption only selects completed outcome bits for capture.

Each slot's registered operands_ready is selected with the same constant-pop and
occupancy source mapping as its packet. Decode gains BYPASS_ENABLED/DIVIDER_AUTO_PIPE
parameters, wired from Dispatch. Source usability preserves prior readiness thresholds,
RF behavior and bypass rules; actual rs1/rs2_valid still masks unused operands.
Issue.sv/Top.sv carry readiness to IssueContract.sv. Contract no longer has producer
metadata inputs or readiness/bypass calculation; it combines registered operand
eligibility, existing structural flags, validity and live serial_active. Removed
unused contract parameter overrides; readiness configuration is now Decode-owned.
Full corrected metadata and registered matches remain for forwarding and Decode
absorption; acceptance no longer waits for that Issue correction output.

Invariant: at each advancing edge, consumed prefix identifies precisely which
current candidates become new buffered writers. The selected eligibility therefore
includes new buffer index-zero overrides, while its base snapshot includes old
buffer absorption at index one and exactly one advancement. Nonwriting/illegal/x0/
FP destinations never override. Younger accepted same-rd writers win, unaccepted
younger writers do not. Same-group RAW remains separate. No-pop waiting packets
re-evaluate progressed old producers; incoming packets evaluate their own sources.
Stall freezes eligibility, packets, buffer and backend; flush clears eligibility
and validity even while stalled. No extra stage, two additional state bits for dual
issue. Existing variable-latency/global-stall and incomplete FP tracking assumptions
are unchanged; this is not a new dynamic completion mechanism.

Goal: replace correction/readiness -> issue -> wide snapshot selection feedback
with registered eligibility -> small issue decision -> candidate capture. Cost:
prospective-writer priority logic and eligibility computation before Decode capture;
base table-read/refresh -> eligibility can become critical. No measured gain claimed.
Current flow/README updated. Static threshold/bypass equivalence, prefix writer/dedup,
source mapping, stall/flush and interface/diff review only. No tests, lint, synthesis
or implementation run, as requested. No permanent test artifacts.

### 2026-11-16 - operand-lookahead first timing result

User supplied WNS -1.163 ns versus baseline -0.967 ns (0.196 ns regression).
Data delay 7.310 - 1.205 = 6.105 ns versus 5.937 ns (+0.168), nine LUTs.
Launch is Fetch prev_serve_consumed[0], endpoint Decode operands_ready_reg[1]/D.
The path crosses serve selection then fresh-source producer/readiness candidate
calculation; previous live Issue feedback is no longer the reported worst path.
Approximate portions: launch/serve selection 2.247 ns, intermediate producer
lookup/correction cone 2.524 ns, remaining readiness/outcome logic 1.334 ns.
Exact intermediate LUT functions require netlist inspection. No TNS supplied;
no proof of timing improvement for the complete design. Potential follow-up is
compute fresh-table capture-edge eligibility before address selection, selecting
one-bit eligibility in parallel with metadata instead of evaluating it afterward.
Not implemented or measured. No RTL edits or additional tests/synthesis for review.


### 2026-11-16 - calculate capture eligibility before producer lookup

User believes TNS improved with operand lookahead; no numeric TNS supplied.
To shorten the newly exposed fresh-source candidate path, ProducerTable.sv now
computes capture_ready per entry and reads one bit per source in parallel with raw
index/lane/capability. No new stored table state. Decode.sv computes retained-source
eligibility from raw snapshots independently, and refresh_ready selects old buffered
writer eligibility bits instead of interpreting corrected metadata. New prospective
writer priority/index-zero bypass logic and final operands_ready capture stay intact.
Dispatch/Top.sv wires the new read outputs and divider configuration.

Definitions.sv provides a shared producer_capture_ready helper: evaluate readiness
after one saturated advancement using index >= ready_threshold-1 (threshold <=1
always ready), with RF-after-capture handled independently of unknown capability.
This avoids increment/saturation followed by capability evaluation. It assumes an
advancing capture; no stall enters this computation because Decode holds on stall.
Old buffered writers use current index zero -> capture position one. Prospective
new writers still use index zero NEXT cycle with BYPASS_ENABLED && CAP_ALU.
Integer-bank/write-valid matching is identical to metadata refresh, and buffer
unique destinations permit parallel ready selection. False/true readiness overrides
both remain possible; no OR-only shortcut loses a newer unready writer.

Correctness invariant: helper equals source_usable(age_source(raw)) for supported
producer positions/configurations, including RF, serial, multiply/divide thresholds.
Full metadata/producer-table writes and issue policy are unchanged. Tradeoff:
per-entry eligibility decode and a separate one-bit table-read mux add logic and
fanout, but remove capability/position interpretation after late address selection.
Expected timing benefit unmeasured. Current flow/Dispatch README updated. Static
threshold algebra, parameter/wiring and diff inspection only; no tests/lint/synthesis.


### 2026-11-16 - remove capability-selected threshold arithmetic

User reports regression across metrics after per-entry capture eligibility; supplied
report shows WNS -1.268 ns versus -1.163 ns, data delay 6.176 ns versus 6.105 ns.
Numeric TNS was not supplied. Worst path now launches producer capability entry 23
and ends at Decode operands_ready[1], with 13 levels including four CARRY4s before
the capture-ready table read. Logic delay is 2.085 ns and routing 4.091 ns.

Definitions.sv previously selected an int unsigned threshold by live capability,
then subtracted one and compared. That expression is a likely source of the wide
carry chain; this is an avoidable RTL arithmetic dependency, not merely routing
variation. Replaced it with per-capability direct index comparisons against
configuration-only constants. Divide/minimum/threshold subtraction now depend only
on constant call-site configuration, never live capability. Preserves RF override,
threshold <= 1 behavior, MUL/DIV limits and serial readiness; no state, interfaces,
stall behavior or stage boundaries change. The speculative eligibility experiment
and per-entry read remain in place. Expected carry-chain removal/timing benefit is
unmeasured, and exact synthesized arithmetic identification needs netlist inspection.
Validation: static threshold equivalence and diff review only; no tests, lint,
synthesis or implementation run. Dispatch README updated to describe this form.


### 2026-11-16 - capture selected serve source identities before the edge

User reports WNS -0.784 ns and TNS -28.817 ns after constant-threshold readiness
comparisons, versus prior WNS -1.268 ns. New worst path is prev_serve_consumed ->
serve source selection -> producer lookup/correction -> Decode rs1_index snapshot.
Data delay is 6.940 - 1.251 = 5.689 ns; launch through source selection is about
2.381 ns, including a decoded selector with 157 loads. Readiness is no longer the
reported worst endpoint.

With a clean user Git snapshot, Fetch/Queue.sv now extracts a 12-bit source tuple
(rs1, rs2, integer/FP bank flags) from every existing completed next_window candidate.
Current serve_consumed selects this tuple directly into one register per serve lane.
Wide payload and FIFO state keep speculative banks selected by prev_serve_consumed.
Unused source fields in those packed banks have no consumers and may be pruned.
No new decode work or FIFO head arithmetic follows the late consumption selector.

Invariant: at each nonflush edge, source registers capture next_window[count] while
prev_serve_consumed captures that same count and wide banks capture all next_window
values. Retention/refill mapping, partial occupancy, FIFO wrap, and no same-edge
push bypass are shared rather than reimplemented. Source registers update on every
nonflush queue edge, including zero consumption: empty serve positions can refill
while Decode stalls. Flush makes source payload don't-care while bank validity
clears. No extra stage or change to accepted instruction ordering.

Tradeoff: removes post-register source bank selection from producer-read launch,
but restores late consumption -> narrow source mux -> register timing. Benefit is
unmeasured; next implementation must check that new endpoint as well as table reads.
Validation: static packed-field offsets, selection/flush/refill alignment and diff
review only. No tests, lint, synthesis or implementation run. Current flow and
Dispatch README updated; no unrelated RTL changes.


### 2026-11-16 - direct serve source capture timing result

User reports WNS -0.453 ns and TNS -13.164 ns, versus -0.784/-28.817
after direct source-register capture: WNS improves 0.331 ns, TNS magnitude
falls about 54.3%. Worst reported path has moved to redirect_taken ->
stage_transfer -> admission count selection/comparison -> fifo_packet_room/D.
Input delay is 3.750 ns, internal data delay 2.863 ns (0.388 logic, 2.475
routing), four LUTs. stage_transfer has 497 loads and 0.909 ns routing.
The single report does not establish the remaining register-to-register slack.
Queue already overrides fifo_packet_room to one on redirect. A possible next
experiment is a redirect-independent admission decision with redirect applied
only at final state capture; stage_transfer must remain flush-qualified for
actual transfers. No such RTL change made here. Report and RTL inspection only;
no tests or synthesis run. Existing correctness invariants unchanged.


### 2026-11-16 - keep redirect out of normal admission calculation

Following the -0.453 ns WNS / -13.164 ns TNS report, Fetch/Queue.sv splits
stage_transfer_candidate (normal staging-to-prediction decision) from stage_transfer
(candidate AND !redirect_taken). fifo_packet_room uses the candidate to select
stage_push_count versus packet_push_count. Its existing reset/delayed-reset/redirect
priority still forces room to one. All actual transfer consumers retain the masked
stage_transfer signal; fetch acceptance and prediction capture are unchanged.

Invariant: without redirect the candidate equals the old transfer signal. With
redirect, the admission calculation is ignored by the existing register override.
Taken-packet handling, FIFO capacity accounting, and no-pop-credit admission remain
unchanged. No new state or latency. Intended benefit is removing redirect ->
497-load stage_transfer -> count selection/comparison from admission capture;
physical timing improvement is unmeasured. Static equation/priority review and
diff check only; no tests, lint, synthesis or implementation run. README updated.


### 2026-11-16 - register packet-level branch summary with prediction

After admission-control separation, user reports WNS -0.561 ns (0.108 ns worse);
TNS was not supplied. Worst path launches prediction_lane_valid[1] and ends at
instruction-memory BRAM address. Data delay 5.144 ns includes 4.415 ns routing,
four LUTs and a 1.633 ns final address route. This does not measure the remaining
admission path independently.

Fetch/Queue.sv now computes stage_taken and first-taken stage_redirect_pc alongside
stage_push_count from reconstructed packet validity, branch classification and
branch_output. Both capture with the prediction packet on stage_transfer and hold
while it waits. Prefetch uses the registered summary/target instead of qualifying
lanes and selecting their target after prediction capture. Removed unused old
combinational target/selected-lane intermediates. FIFO keep/taken calculations still
use registered per-lane predictions, preserving truncation and stored branch flags.

Invariant: only the first valid classified branch with valid taken prediction wins.
The summary shares payload capture and flush priority. Reset/delayed reset/external
redirect/committed taken prediction clear summary validity; target is don't-care.
On drain without refill prediction_stage_valid clears and masks the held summary;
on ordinary drain/refill the new packet and summary replace the old together.
No extra pipeline stage; redirect/reset prefetch priority unchanged. Cost is up to
33 summary bits and first-target selection before prediction capture, with possible
pruning of now-unused target fields. New prediction-stage timing must be measured.
Static priority, hold/flush, count equivalence and diff review only; no tests, lint,
synthesis or implementation run. Current flow and Dispatch README updated.


### 2026-11-16 - revert later experiments to best direct-source-capture version

At user request, restored the first RTL experiment after 11ae379 (Prototype 2.6):
direct registered serve rs1/rs2 and bank flags, with wide speculative payload banks.
This is the version measured at WNS -0.453 ns and TNS -13.164 ns. Removed the later
redirect-independent admission candidate and registered first-taken summary/target.
Queue admission again uses redirect-qualified stage_transfer, and packet taken/target
selection again derives combinationally from registered per-lane predictions.
Source candidate mapping, source capture, flush and zero-pop refill remain intact.

The admission experiment measured WNS -0.561 ns; adding the branch summary produced
-0.499 ns and user-reported notably worse TNS (no numeric TNS supplied). Its worst
path was redirect -> staging capture CE, with 399/198-load intermediate control
nets. Both experiments remain documented above as reverted, not established wins.
No proposed staging payload-enable change was implemented.

Validation: restored affected sections from HEAD, inspected remaining RTL diff to
confirm only the original source-capture experiment remains; git diff --check.
No tests, lint, synthesis or implementation run. Historical best timing is not a
new measurement. Current description/README no longer claim the reverted behavior.


### 2026-11-16 - aggressive pre-route and post-route physical optimization

User requested stronger phys_opt to attempt closure from restored best RTL
(previously measured WNS -0.453 ns / TNS -13.164 ns). frontend_ooc.tcl previously
had no phys_opt_design calls. Added AggressiveExplore after placement and after
routing. Default synthesis, RuntimeOptimized opt/place/route and all constraints
remain unchanged. Original placed outputs remain pre-physopt; placed_physopt and
routed_pre_physopt outputs preserve intermediate results. Existing frontend_routed
checkpoint and routed reports now describe the final post-route physopt result.

Tradeoff: more implementation time and potentially different placement/replication;
closure or improvement is not guaranteed. No RTL/stage/interface changes. No false
paths or relaxed constraints added. This is a new implementation-flow baseline;
pre/post-route-pass comparison is available without discarding the earlier result.
Reviewed AMD physical optimization directive documentation, script ordering and
diff formatting only. No synthesis/implementation/tests run. README updated.


### 2026-11-16 - standalone routed-checkpoint retry flow

Added frontend_retry.tcl at user request. Defaults to opening
build/frontend_ooc/frontend_routed.dcp, or accepts an explicit DCP and output directory.
Runs post-route AggressiveExplore phys_opt, AggressiveExplore route_design, then
another AggressiveExplore phys_opt. Does not rerun synthesis or placement and uses
the checkpoint netlist/device/constraints, not any newer working-tree RTL.

Saves baseline, physopt, rerouted and final checkpoints plus setup/hold, utilization
and route-status reports. Timestamped default output directory is separate from
main flow; existing output directories are rejected. Input checkpoint is never
written. All stages are preserved because later passes can regress timing or hold.
No automatic claim that the final stage is best. Tradeoff is longer routing effort;
benefit remains unmeasured. No RTL/functional/constraint changes. Reviewed AMD routing
and physical optimization docs and script text; no Vivado, synthesis or tests run.


### 2026-11-16 - restore main flow without physical optimization

At user request removed both added AggressiveExplore phys_opt passes and their
intermediate output stages from frontend_ooc.tcl. Main flow again writes
frontend_routed.dcp and routed_* reports directly after RuntimeOptimized routing.
Default synthesis, RuntimeOptimized opt/place, constraints and RTL are unchanged.
Standalone frontend_retry.tcl remains untouched; existing output files are retained.

The user's standalone retry crashed during its first post-route AggressiveExplore
pass. Log showed original setup WNS/TNS -0.453/-13.164 and transient WNS -0.311,
but no optimized checkpoint was saved. Hold WHS/THS were -1.126/-100.429.
Crash cause was not established. This reversion restores the lighter main flow;
no new timing result claimed. Static script/output-path checks and diff check only;
no Vivado, synthesis or tests run. Current description and README updated.


### 2026-11-16 - predecode CSR and FP legality alongside prediction

User supplied worst path from prediction instruction bit 27 to fifo_trap[5][0],
5.165 ns data delay, eight LUTs (1.271 ns cell, 3.894 ns route). Exact mapped
operation was not established. At user request, split two encoding checks ahead
of prediction capture rather than moving the entire trap decoder.

New Fetch/LegalityPredecode.sv computes CSR address legal/read-only classification
and the OP-FP suboperation illegal predicate. Queue.sv captures these three bits
per lane with prediction payload on stage_transfer, holds them with waiting packets,
and makes them don't-care on the same flush branch as payload. InstructionLegality.sv
consumes the summaries; opcode selection, CSR write qualification, compressed checks,
other extension checks and final ECALL/EBREAK/ILLEGAL encoding stay after capture.
FP check hardware is generate-disabled with SUPPORT_FLOAT=0; FP CSR address support
uses the same parameter. MUL/DIV/atomic checks remain unchanged in the final stage.

Invariant: the extracted predicates preserve the prior address whitelist/read-only
policy, first-level FP operation cases, rs2 restrictions, format and rounding checks.
Summaries travel with the same instruction across hold, flush and drain/refill;
invalid payload cannot commit. No extra stage or FIFO fields: summaries are consumed
before FIFO insertion. Cost is up to three prediction bits per lane and added
combinational work beside the predictor. Benefit and prediction-stage margin are
unmeasured. Main Tcl glob includes the new Fetch source automatically.
Validation: static extracted-condition comparison, single instantiation wiring,
capture/flush review and diff check only. No tests, lint or synthesis run.


### 2026-11-16 - fix legality-summary elaboration name collision

User synthesis failed with Synth 8-8891: new prediction_legality array collided
with the existing prediction_legality generate-block name in Fetch/Queue.sv.
Renamed only the array and all its references to prediction_legality_bits.
No logic, timing structure or behavior change. Static reference inspection and
diff check only; no synthesis/tests run. Prior static review missed this collision.


### 2026-11-16 - split retry passes after native phys-opt crash

User reports recurring retry crashes without saved optimization progress. Earlier
log identified native failure inside first AggressiveExplore post-route critical
path optimization; current vivado.log is a newer normal implementation, so it does
not establish an additional crash cause. frontend_retry.tcl now uses one thread,
runs AggressiveExplore routing first, then explicit placement_opt, fanout_opt and
routing_opt physical passes separately. Removes both combined AggressiveExplore
physical passes. Each completed pass saves its own checkpoint before reports.
last_saved.txt records the completed checkpoint, progress.txt identifies the running
pass. Ordinary Tcl command errors stop without saving uncertain modified state;
native access violations cannot be caught or saved mid-command. These changes are
a workaround attempt, not a confirmed vendor-crash fix. Input and older checkpoints
remain untouched; all reports retain setup, hold and route status. Main Tcl and RTL
unchanged. Resume by passing a saved DCP and fresh output directory. Static script
review and AMD supported-pass documentation check only; no Vivado/tests run.


### 2026-11-16 - complete requested reversion of extra legality predecode

User clarified target is RTL immediately before the CSR/FP predecode experiment,
recalling roughly -0.2 ns WNS. That exact timing report has not been verified.
Latest supplied report is -0.535 ns, 5.475 ns data, capability -> issue_select_any
-> serve_rs2 capture; working tree still contained predecode because the earlier
reversion turn was interrupted before edits. Completed that pending reversion now.

Restored InstructionLegality.sv to its original post-prediction checks, removed
Queue's three summary bits/capture/wiring and deleted LegalityPredecode.sv. Kept
direct serve source-register capture and all Tcl changes. This restores the RTL
immediately preceding extra predecode, without claiming reproducible -0.2 timing.
Historical experiments remain documented. Static diff/reference checks only;
no synthesis/tests run. Existing routed DCP/reports are not rebuilt by this edit.


### 2026-11-16 - retry achieves setup closure; remove unsupported fanout pass

User log shows AggressiveExplore routing completed with WNS +0.034 ns / TNS 0,
WHS -1.127 ns / THS -102.561 ns, no failed/unrouted/overlapping nets. Setup
closure only: hold remains failing. Saved 01_rerouted.dcp and 02_placement.dcp
in build/frontend_retry/20261116_152348. Placement optimization skipped because
setup slack was nonnegative. Then explicit fanout_opt failed with Vivado_Tcl 4-265:
not supported for post-route physical synthesis in this flow. This was a Tcl error,
not the earlier native crash, and completed checkpoints survived. Removed fanout
step from frontend_retry.tcl and renumbered routing pass to 03. Main flow/RTL and
constraints unchanged. Previous documentation-based assumption of support was
incorrect for this tool/device flow. Static script/diff review only; not rerun.


### 2026-11-16 - bounded setup and hold retry sweep

User requested hold optimization and broader efforts. frontend_retry.tcl now runs
aggressive routing, explicit hold_fix and aggressive_hold_fix, critical-pin, routing,
clock, and restructure optimization, then NoTimingRelaxation routing and final
aggressive hold repair. Removed placement-only pass: AMD 2025.2 post-route table
limits it to UltraScale families, and on this Artix run it had merely skipped with
setup closed. Fanout and combined crashing AggressiveExplore phys-opt remain absent.
Checked AMD UG904 Available Physical Optimizations for post-route applicability.

Each completed command is checkpointed before reporting. Ordinary Tcl failures log
to failures.txt, reload last_saved checkpoint and continue; native crashes cannot
be caught. Restructure is late to preserve earlier progress if its algorithms crash.
All stages keep setup/hold and route-status reports; no assumption final is best.
Hold insertion may consume LUTs and reduce setup slack. Input checkpoint, main flow,
RTL and constraints unchanged; no relaxation of min delays to hide violations.
Static script review/diff check only; this extended sweep has not been executed.


### 2026-11-16 - standalone worst hold path report

Added worst_hold_path.tcl: opens main routed DCP by default or a supplied checkpoint,
queries delay_type min, and writes/prints one worst hold path with expanded clock
paths and input pins. Report defaults beside the selected DCP; optional report path
overrides it. Includes checkpoint provenance and timestamp, avoids deprecated -nets
and the incompatible -of_objects formatting combination. No optimization, RTL or
constraint changes. Static script review only; no Vivado run.


### 2026-11-16 - model reset earliest arrival at 1 ns

User requested 1 ns reset input delay after observing reset-dominated hold paths.
frontend_ooc.tcl already had reset max=1.000 ns; changed reset min from 0.000 to
1.000 ns. serial_active remains min=0/max=1; existing late-control constraints
(including current user max=3.250 ns) are untouched. This changes the assumed
external reset arrival, not hardware delay: valid only if the reset source meets
that minimum arrival. Existing DCPs retain their embedded old constraints until
updated/rebuilt. No RTL change, synthesis or timing run; static edit review only.


### 2026-11-16 - remove instruction-memory response payload reset

User reported reset -> RAMB18E1 RSTRAMARSTRAM as worst hold path and requested
removing payload reset. Fetch/InstructionMemory.sv now reads read_words and captures
request_halfword on every edge; only fetch_valid depends on reset (<= !reset).
This removes reset from inferred BRAM read-data reset and payload capture enables.
ROM initialization, address wrapping, read latency and valid-response data unchanged.

Invariant: read words, alignment and fetch_valid describe the same sampled request.
On reset edges validity is zero; Queue's reset/delayed-reset branch also clears
staging validity and ignores payload. First nonreset read supplies matching data
and alignment when validity rises; Queue accepts it at a later edge under its
existing fetch_valid gate. Invalid reset-cycle payload is no longer zero and must
not be consumed. No pipeline stage added. Tradeoff: reads toggle during reset;
expected reset hold-path removal requires synthesis confirmation. Static consumer,
startup alignment and diff review only; no tests/lint/synthesis run. README updated.


### 2026-11-16 - establish parameter-set timing table in main architecture doc

Added root ARCHITECTURE.md frontend comparison series, prefaced by exact current
Tcl clock/min/max I/O constraints and OOC clock/implementation assumptions. F01
records current parameter set (issue2, unroll1, bypass1, all extensions, fetch2/FIFO8,
divider3, integer masks1111/0011, memory111, FP11). Verified final retry report
20261116_163543/09_hold_final matches user: WNS +0.060/TNS0, WHS +0.084/THS0,
WPWS2/TPWS0, setup and hold 0/7097, pulse width0/3422. No functional or full-chip
closure claim. Added AGENTS instruction to maintain comparison tables with fixed
constraints, parameter snapshots and report provenance. Documentation only; read
parameters/current generated XDC/report and checked diff. No implementation run.


### 2026-11-16 - simplify main frontend comparison table

At user request replaced separate configuration/timing tables with one row per run
and ISA, issue width, FIFO/cache-line words, total lanes, tested frequency/period,
LUTs and FFs. Common Tcl constraints remain before it. Matching final utilization
report gives 6784 Slice LUTs and 3417 FFs; tested clock is 200 MHz/5 ns. Detailed
configuration, provenance and passing slack stay in prose. AGENTS updated to the
single-table format. Documentation only; static report/diff inspection, no runs.


### 2026-11-16 - append 500 MHz target frequency experiment

Main architecture single table gains same-parameter run with user-reported 2 ns
target, WNS -2.580/TNS -7877.691, estimated period4.580 ns/frequency218.34 MHz.
LUT/FF absent from supplied summary and not inferred from earlier run. Existing
row preserved. Clock targets now explicitly vary per row notes while I/O model
remains common. Current script reads2.5 ns; user specifies2 ns for this run, so
that provenance distinction is recorded. No RTL/Tcl change or implementation run.


### 2026-11-16 - verify utilization and correct measured clock target

Matched routed report dated17:01:08 to WNS-2.580/TNS-7877.691. Utilization6780
LUTs/3417FFs filled in main table. Report clock summary and generated XDC both
confirm2.500ns/400MHz, contrary to earlier user-described500MHz. Corrected estimate
to5.080ns/196.85MHz; earlier218.34 estimate depended on incorrect2ns assumption.
Read reports only; no implementation run.


### 2026-11-16 - record no-F/no-A frontend run

Matched current routed timing/utilization reports:2.500ns target, WNS-2.779,
TNS-6805.158, WHS+0.069/THS0;6005LUTs/3093FFs. Appended RV32IMC row with
estimated5.279ns/189.43MHz, issue2/FIFO8/cacheline2. User requested3 lanes
(two integer plus memory); RTL additionally has fixed serial lane, so physical
total including serial is4. Table retains user-specified3 for this run. No RTL
or flow changes, report read and documentation update only.


### 2026-11-16 - record single-issue one-word frontend run

User supplies issue1/cacheline1, RV32IMC, FIFO8, unroll1/bypass1/divider3,
two integer and one memory lanes, no FP lane. Current routed reports give
2.500ns target/WNS-1.698/TNS-2937.586, WHS+0.114/THS0,2487LUTs/1957FFs.
Appended main table estimate4.198ns/238.21MHz using same lane-count convention
as previous no-F/no-A row (3 excluding fixed serial lane). Report inspection
and documentation only; no implementation or RTL changes.


### 2026-11-16 - corrected parameter series, minimal frontend

User invalidated previous no-F/no-A and single-issue rows due to bad parameter
sets and removed them from main table; only original196.85MHz dual-issue row
remains valid. Preserve older history as superseded measurements, not valid
configuration comparisons. Fresh supplied configuration: issue1/cacheline1/FIFO8,
unroll1/bypass1, MUL/DIV/FP/atomic disabled, integer count1 mask1100, memory
count1 mask111, FP count0. Total3 includes fixed serial lane. Added RV32IC row
from current reports: target2.5ns, WNS-1.908/TNS-2919.949, WHS+0.040/THS0,
2435LUTs/1911FFs; estimated4.408ns/226.86MHz. No hardware parameterization
changes or implementation run performed; this task records supplied run only.


### 2026-11-16 - static parameter/pruning audit

Added PARAMETER_AUDIT.md with source-level findings across decode/fetch/issuer,
OOC lane sinks, derived widths and backend generation. Found current mask1100
selects MUL/DIV, not ALU/BRU; both extensions disabled leaves no ALU/BRU coverage.
Thus latest2435LUT/226.86MHz RV32IC row is not a valid functioning configuration
comparison. No table or user parameter edits made pending corrected run.
No synthesis/elaboration tests; mapped pruning remains unverified.


### 2026-11-16 - fix lane-mask and feature parameter boundaries

Corrected current integer mask1100 to0011 (ALU/BRU). Parameters capability arrays
now use at least one placeholder element for count0; loops still honor actual count.
DerivedParameters builds constant effective masks combining raw masks with global
MUL/DIV/FP/atomic support. Lane counters, Decode resource checks, Issue allocation
and FrontendTop payload sinks all consume these effective masks. Top rejects
missing base/extension lane coverage, disabled FP with nonzero FP lane count,
unsupported issue/unroll values and local overrides inconsistent with global packet
widths. This prevents silently benchmarking an unusable lane set. Counts and lane
IDs are preserved; no automatic renumbering. Common/issuer payload pruning remains
conservative pending implemented backend consumer contracts. Backend IntegerLane
continues to gate execution units with IS_*; no integrated backend generator exists
to change. No guessed field removals or narrowed producer sentinels introduced.
Static edits/reference/diff review only, no elaboration/synthesis/tests. New mapped
area/timing must be measured; previous minimal row remains historical invalid data.


### 2026-11-16 - corrected mask/effective capability run result

Routed reports18:26:54 show WNS-1.709/TNS-3069.483 at2.5ns, WHS+0.083/THS0,
2491LUTs/1953FFs. Estimated4.209ns/237.59MHz. Current parameters confirm0011
integer mask with M/D/F/A off, issue1/cacheline1/FIFO8/3total lanes. Replaced
invalid1100-mask minimal row in main comparison table, preserving original
measurement here. Change from invalid run:+56LUT/+42FF, WNS improves0.199ns;
TNS worsens149.534ns. Worst path is producer capability -> operands_ready,
4.178ns data/seven logic levels. Vivado completes; existing duplicate c_branch
and c_jump declarations still generate critical warnings and were not changed
in this report task. Report review only, no synthesis or RTL edits.


### 2026-11-16 - record corrected single-issue RV32IMC run

Current parameters M/D on,F/A off,issue1,cacheline1,FIFO8,unroll1,bypass1,
divider3,integer mask1111,one integer/one memory/no FP plus serial=3lanes.
Latest routed summary target2.5ns,WNS-1.813/TNS-3059.157,WHS+0.018/THS0;
utilization2484LUTs/1955FFs. Appended single table row estimated4.313ns/231.86MHz.
Preserved user prose/table edits; report inspection only, no implementation run.


### 2026-11-16 - predecode compact immediate format before FIFO check-in

Added ImmediateFormatPredecode from registered prediction payload, parallel to
legality. Five format bits capture with FIFO instruction under identical keep,
commit and write index, then travel with retained/fresh speculative serve payload.
Queue/FetchTop/FrontendTop/DispatchTop/Decode carry the selector to DecoderSlice.
Immediate assembly is now a flat selector case over original bit layouts; nested
opcode/compressed format recognition moved before FIFO insertion. FP memory
formats retain SUPPORT_FLOAT guards. No extra stage or32-bit immediate storage.
Added metadata above existing low fields so direct-source packed offsets remain
unchanged. Flush validity and existing queue movement govern metadata lifetime.
Also renamed compressed jump/branch offset vectors to avoid their preexisting
collision with scalar predicates, preserving intended layouts and predicate names.
Tradeoff:5bits per FIFO/serve entry and added pre-check-in work; synthesis must
measure benefit and new bottlenecks. Static layout/wiring/diff review only; no
tests, elaboration or synthesis run.


### 2026-11-16 - predecode branch operation before FIFO check-in

User report after immediate-format change ends at BRU operation,4.996ns data,
seven levels, WNS-2.539 at2.5ns; instruction bank selection feeds branch encoding
interpretation. Added BranchOperationPredecode from registered prediction payload
parallel to legality/immediate format. Four-bit BranchOperation selector captures
under FIFO commit/keep/index, travels with payload through all interfaces and
speculative serve outcomes. DecoderSlice now only applies ok ? operation : BR_NONE.
Original JAL/JALR, compressed CR/jump/conditional and funct3 branch priority copied
verbatim. Trap gate preserved; no extension-specific hardware required for base
branch operations. New bits inserted above existing metadata to preserve source
packed offsets. Adds4bits/entry, no stage. Static condition/wiring/packed-layout and
diff review only; no tests/elaboration/synthesis. New stage timing unmeasured.


### 2026-11-16 - precompute five low immediate payload bits

New report WNS-2.407/data4.814ns returns to immediate[4], launching registered
serve selector through immediate format mux. Added ImmediateLowPredecode alongside
format predecode before FIFO check-in. It reuses the same encoding-format selection
and original bit-layout expressions, exposing only low5bits so upper combinational
outputs prune. Queue captures5bits under identical instruction commit/keep/index
and carries them through retained/refill serve candidates and module interfaces.
Decoder common.immediate concatenates locally assembled upper27bits with carried
low5bits. Added fields above prior low metadata preserve source extraction offsets.
CSR upper bits remain unspecified as before, compressed/FP guards preserved. No
stage added;5additional FIFO/serve bits trade area for removal of late low-bit
assembly. Prediction-to-FIFO path may become limiting; benefit unmeasured. Static
expression/wiring/diff review only; no tests/elaboration/synthesis.


### 2026-11-16 - replace encoded upper-immediate format with layout enables

User report data4.877ns/seven levels returns to immediate[8] through served format
bit4. Replaced carried5bit format number with14 direct upper-layout enables.
ImmediateUpperPredecode evaluates these before FIFO check-in from prediction
payload. I/S formats share one upper layout; zero-upper shift/JR formats and
CSR require no upper enable. Other compressed/full layouts retain original
source wiring. Decoder masked-ORs upper27bits from enables, no downstream format
comparison. Low5bit predecode remains. Bundle grows9bits, not32bit immediate.
Unconsumed CSR/unused upper bits become zero, a permitted refinement of previous
don't-care. Enables are mutually exclusive for defined encodings, captured and
moved under existing instruction protocol. Original lower packed metadata offsets
unchanged. FP format guards remain in shared predecode. Tradeoff is more stored
control/fanout and possible OR-tree depth; mapped timing gain unmeasured.
Static I/S upper equivalence, zero-upper exclusions, wiring and diff check only;
no tests/elaboration/synthesis.


### 2026-11-16 - directly capture serve instruction and compressed flag

Latest user report: WNS -2.437ns at 2.5ns, data delay 4.846ns, seven LUT
levels, from prev_serve_consumed to decoded system.operation. Selection through
instruction bit23 takes 2.146ns including launch; remaining logic takes 2.700ns.
Queue.sv now selects only the instruction word and compressed flag from the same
completed next_window candidates as rs1/rs2 before capture. Existing direct source
registers are unchanged; PC, validity, predecoded controls and all other fields
remain speculative/banked. Unused banked instruction/c copies have no consumers
and can prune. Retained candidates use the new direct outputs. No stage added.
Correctness relies on identical consumption selection and candidate refill mapping;
zero-consumption refill remains enabled, same-edge pushes remain unavailable, and
reset/delayed-reset/redirect invalidate the banked window while direct payload is
don't-care. Tradeoff: 33 more selected bits per serve lane load late consumption,
with potential issue-to-serve timing cost in exchange for removing the next-cycle
instruction bank mux. Benefit unmeasured. Validation: static packed-offset,
retained/refill and driver review plus git diff --check; no tests or synthesis.


### 2026-11-16 - consolidate registered issue structural eligibility

Decode now combines candidate validity, same-group RAW, serial-pair conflict and
lane-resource feasibility into structural_ok before the late consumption mux.
A separate is_serial bit classifies the matching candidate capability before
capture. These two registers replace the three exposed structural hazard flags.
Dispatch/Top.sv and Issue.sv carry the new interface; IssueContract.sv now only
combines structural_ok, operands_ready and !(serial_active && is_serial), then
applies oldest-first prefix acceptance. Packet/capability/lane/valid inputs are
removed from the contract. Packet validity remains separately available elsewhere.
Each candidate uses the same retained-suffix/refill source mapping as packet
selection, including the full-pop result. Both bits hold on stall and clear on
reset/delayed-reset/redirect, matching packet validity. Existing RAW/resource/
serial-pair predicates and producer readiness logic are unchanged. No stage added.
Tradeoff: added pre-capture combination/serial classification in Decode removes
post-capture capability interpretation and structural reduction; timing impact
is unmeasured. Static interface, source-index, flush/hold and diff review only;
no tests, elaboration or synthesis run.


### 2026-11-16 - revert consolidated issue structural eligibility

Reverted only the structural_ok/is_serial experiment in Decode, Dispatch Top,
Issuer and IssueContract. Restored separate registered RAW, serial-pair and
resource flags, explicit packet validity and live capability classification in
the contract. Direct serve instruction/compressed capture remains unchanged.
User report after consolidation: WNS -2.552ns at 2.5ns, data 4.921ns, eight
levels, producer capability entry30 to Decode operands_ready. Prior direct-pop
run: WNS -2.272ns, data 4.687ns, six levels, serve selector to direct rs1 capture.
Worst slack regressed 0.280ns; different paths mean this does not establish a
longer contract cone. Reversion preserves original prefix acceptance and packet
flush/hold alignment; removes the experimental pre-capture reduction and serial
classification. Static reverse-edit/interface and diff review only; no tests or
synthesis. Post-reversion timing has not been measured.


### 2026-11-16 - first current comparison row from post-route retry

Recorded latest completed 03_hold_aggressive checkpoint in main architecture
comparison table: RV32IMAFC, issue2, FIFO8, cacheline1, five total lanes;
2.5ns target, WNS -2.085ns, TNS -6910.226ns, WHS +0.147ns. Slack-derived
estimated period 4.585ns / 218.10MHz; 4989 slice LUTs and 3268 FFs. Source:
build/frontend_retry/20261116_202929/03_hold_aggressive reports. Later retry
passes were still in progress when recorded; this row describes that checkpoint
only. Documentation update; no RTL change, tests or synthesis.


### 2026-11-16 - record second current post-route configuration

Added RV32IMC issue2/FIFO8/cacheline1/four total lanes (two integer, one
memory, one serial) to main table from retry 20261116_204001 checkpoint
09_hold_final. At 2.5ns target, WNS -2.359ns, TNS -6878.249ns, WHS
+0.071ns; estimated period 4.859ns / 205.80MHz. Utilization 4524 slice
LUTs and 2946 FFs. Compared with preceding RV32IMAFC row, F/A and floating
lane are disabled. Documentation only; no RTL, tests or synthesis.


### 2026-11-16 - FP register-file-only operand scheduling

User confirmed FP follows lockstep progress/stall semantics. Definitions now
requires RF-after-capture index for FP-produced integer destinations, covering
CAP_FP_F and CAP_FP_CONVERT. Decode selects RF-only integer readiness for FP
consumers, including retained/fresh reads, old-buffer refresh and prospective
writers (no new ALU bypass). FP sources bypass integer readiness altogether.
Issuer uses a generated 32-bit FP busy scoreboard, checking used rs1/rs2/rs3
and FP destinations directly. Same-group FP RAW and WAW are checked without
acceptance feedback. FP loads set bits and stores check FP source data; f0 is
ordinary. At most one writer per FP register; actual RF writeback clears and
new accepted writes set, with set priority. Clears work during stalls/redirect;
sets require actual advancing acceptance. Reset initializes empty scoreboard.
No data forwarding for FP operands or integer sources going to FP units.

Parameters adds FP_WB_PORTS (default floating+memory lane counts, override for
retirement aggregation) and FP_WB_ISSUE_BYPASS=0. Frontend/Dispatch/Issuer expose
fp_wb_valid and fp_wb_rd. Optional bypass releases issue on actual same-cycle
RF writeback only, adding a completion-control path but no data bypass. Default
waits for registered clear, intentionally losing a cycle. All scoreboard logic
generates out when F disabled. frontend_ooc.tcl constrains notifications to
3.000ns maximum / 1.500ns minimum input arrival. Existing recorded table runs
predate these new ports and RTL.

IMPORTANT integration limitation: redirect alone does not identify canceled
FP writers. Backend recovery must reconcile canceled outstanding writes before
resuming dependent FP issue; otherwise a canceled writer leaves a stuck bit.
This task does not implement backend retirement/cancellation or real RF units.
Never assert a false RF writeback notification to cancel an operation.

Static interface/priority/candidate readiness review and git diff --check only;
no tests, elaboration or synthesis. Timing impact and functionality unmeasured.


### 2026-11-16 - correct enabled-FP lane configuration

User synthesis stopped at FrontendTop's FP coverage assertion: SUPPORT_FLOAT=1
but FLOATING_LANE_COUNT=0. Set count to one, using the existing 2'b11 FP/conversion
capability entry. Memory FP support was already enabled. FP_WB_PORTS consequently
defaults to two. Kept the coverage assertion. Later unresolved-parameter errors
appear secondary to the fatal elaboration error. Static configuration review
and diff check only; synthesis not rerun.


### 2026-11-16 - derive FP writeback port count from lane capabilities

Removed raw FP_WB_PORTS setting from Parameters. DerivedParameters counts
effective memory capability bit2 and each floating lane with any effective
capability once. Disabled F therefore yields zero logical ports; declaration
width stays at least one to avoid invalid arrays, with unused logic pruned.
Issuer loops/checks use the derived logical count. Interface port order is
FP-capable memory lanes then active floating lanes. This removes unnecessary
writeback inputs for integer-only memory lanes. Current configuration still
has two ports. README updated; static reference and diff checks only, no synth
or tests. Earlier configurable-port descriptions are superseded.


### 2026-11-16 - local FP busy entry updates

User routed report: WNS -3.028ns at 2.5ns, data 5.498ns, seven LUTs,
81.449% routing; busy31 through acceptance to busy20. Replaced dynamic bit
assignment for scoreboard sets/clears in Issue.sv with generated per-register
constant destination comparisons and parallel hit reductions. Destination
qualification precedes acceptance; issue_good only gates a predecoded hit.
Each busy register owns its local hold/clear/set expression. No added stage,
no speculation and no delayed busy set. Reset wins, accepted new set wins
over clear, stall/redirect block sets only, actual writebacks still clear.
Read logic, same-group hazards and optional writeback release are unchanged.
Expectation is less shared write-selection logic on late acceptance; physical
benefit is unmeasured and synthesis may still share equivalent gates. Static
priority/interface review and diff check only; no tests or synthesis.


### 2026-11-16 - revert local FP busy update experiment

Latest user report regressed WNS from -3.028 to -3.465ns, data delay from
5.498 to 5.913ns. New path starts at busy31, crosses FP readiness/acceptance
and serve consumption, and ends at direct serve rs2[4] capture. Seven levels,
81.870% routing. Endpoint changed, so this does not prove busy-write logic
itself slowed down; the read/acceptance cone and routing remain limiting.
Reverted only per-entry update experiment to prior vector set/clear masks in
Issue.sv. Derived capability-based port count and all FP semantics preserved.
README updated. Static reverse-edit/diff review only; no tests or synthesis.


### 2026-11-16 - register FP eligibility in Decode

Moved default FP scoreboard reads from Issue acceptance into Decode candidate
lookahead. Issuer exports busy with actual same-edge RF clears applied, without
live accepted-write feedback. Decode reads used rs1/rs2/rs3 and destination
busy, adds hypothetical prefix writers per consumption outcome, and checks
same-group RAW/WAW for each resulting packet pair. Only one ready bit per slot
is captured with the matching packet. IssueContract consumes this bit directly.
No producer index/lane/capability copies or extra instruction stage added.

New accepted writers override clears logically through prospective conflicts;
retained and refill packets both get matching updates. Stall refreshes held
packet readiness from actual clears without moving packets or inventing writes.
Flush clears readiness; scoreboard recovery requirements remain unchanged.
FP_WB_ISSUE_BYPASS=1 retains the original live read/actual-writeback release
path, and default lookahead generates out in that mode or with F disabled.
Affected Decode.sv, Issue.sv, Dispatch/Top.sv. Tradeoff: extra candidate conflict
logic and writeback-to-Decode capture paths; removes busy lookup from default
issue/consumption chain. Timing benefit unmeasured. Static source mapping,
set/clear priority, hold/flush and interface review plus diff check only; no
tests, elaboration or synthesis.


### 2026-11-16 - remove entire FP scoreboard experiment

User chose to pursue dynamic operand search among FP lanes instead. Removed
FP busy scoreboard, live/Decode readiness modes, prospective FP hazards,
RF-only cross-domain restrictions, writeback inputs and derived port counts,
FP_WB_ISSUE_BYPASS parameter, and associated Tcl input constraints. Restored
pre-experiment Decode/Issuer readiness and forwarding behavior. Updated README
and current information flow; all experiment history and measured regressions
remain above. Earlier predecode/direct serve capture and current user ISA/lane
configuration are preserved. Dynamic FP lane search is not implemented by this
reversion. Static reverse-edit/reference and diff review only; no tests/synthesis.


### 2026-11-16 - restore only FP/integer RF readiness restrictions

User requests only cross-domain readiness rules. Definitions producer_capture_ready
now permits FP-produced integer destinations (CAP_FP_F or CAP_FP_CONVERT) only
at RF-after-capture position. Existing integer producer write already preserves
those capabilities. Decode requires RF-after-capture indices for integer sources
of FP consumers, covering retained and fresh snapshots. Buffered new writers and
prospective ALU writers cannot grant bypass eligibility to these sources.
The threshold is EXECUTION_UNROLL+1 before capture, becoming RF index unroll+2
after the advancing edge. Assumes confirmed lockstep FP pipeline/stall semantics.
Checks are guarded by FP support and integer source bank. No FP busy table,
writeback ports, extra state, or live Issue comparisons added. Static readiness
case/diff review only; no tests or synthesis. Timing impact unmeasured.


### 2026-11-17 - predecode FP consumer classification before FIFO capture

Latest path selects served metadata then classifies rf_only before readiness
capture (4.841ns data). Queue now computes one FP-consumer bit from registered
prediction capability before FIFO insertion, gated by SUPPORT_FLOAT. Carries
through existing FIFO/serve motion, Fetch/Dispatch interfaces and DecoderSlice
into common.fp_consumer. Decode consumes this bit instead of comparing
capabilities late, retaining separate integer-source qualification and existing
producer corrections. Stored bit is above lower source metadata; instruction
remains at the same MSB-relative position. No stage change. Classification
matches prior CAP_FP_F/CAP_FP_CONVERT test, including illegal encodings; disabled
F ties it low. Adds one payload bit but removes downstream classification;
benefit unmeasured. Static packed layout/interface and diff checks only, no synth
or tests.


### 2026-11-17 - directly capture serve trap bits

Latest path is bank selection -> served trap -> rs1_valid -> registered operand
readiness, 4.788ns data / WNS -2.374ns. Queue.sv now selects trap_candidate
from each completed next_window before capture, exactly like instruction/c
and sources. Existing low TRAP_W layout and every other field stay unchanged.
Retained candidates consume the direct trap register; unconsumed banked trap
copies can prune. Reset/delayed-reset/redirect make trap payload don't-care
while bank validity clears. Zero-consumption refill stays enabled. No new stage.
Tradeoff: TRAP_W additional direct-pop selector loads per lane, removing the
post-register trap bank mux. Timing benefit unmeasured. Static packed-offset,
sole-driver and retained/refill review plus diff check; no tests or synthesis.


### 2026-11-17 - directly capture upper-immediate layout enables

User report shows 4.827ns data from registered consumption through banked
upper-immediate select[2] to Decode immediate[29]. Queue now selects all14
upper-layout enables from completed next_window candidates before capture,
aligned with instruction/c, trap and sources. Retained windows use the direct
register; unused speculative copies can prune. Low immediate bits and other
metadata keep existing selection. No stage or packed-layout change. Extract
offset is SOURCE_FLAGS_LSB+24 (four bank flags plus four5-bit identities).
Reset/redirect invalidation and zero-consumption refill behavior match other
direct fields. Tradeoff:14more late-consumption selector loads per serve lane;
benefit unmeasured. Static packed-offset, sole-driver and movement review plus
diff check only; no tests or synthesis.


### 2026-11-17 - directly capture FP consumer flag

Latest report: WNS -2.683ns, data5.089ns, bank selection through rf_only to
operands_ready[1]. Queue now directly selects the one-bit FP-consumer flag
from the same completed next-window outcome before capture. Retained candidates
use that direct register; banked copies are unused. Offset UPPER_SELECT_LSB+19
is above fourteen upper-layout bits and five immediate-low bits. F-disabled
generate ties output low without a register. Flush payload is don't-care while
validity clears; zero-consumption refill and packet alignment are preserved.
Adds one late-pop selector load per lane, removes post-capture bank mux for
this control. Timing benefit unmeasured. README/current flow updated; static
packed-offset/driver review and diff check only, no tests or synthesis.


### 2026-11-17 - directly capture serve capability

Latest report WNS -2.503ns/data4.998ns launches serve selection through
capability bit0 to group_resource_bad[1]. Queue now captures capability from
the completed next-window candidate selected by current consumption, alongside
other direct fields. Extraction is TRAP_W +: $bits(DecodeCapability_); packed
layout is unchanged. Retained windows use direct output; unused banked copies
can prune. Flush payload is don't-care with validity cleared; zero-consumption
refill and all existing parameterized capability encoding are preserved.
Tradeoff is capability-width extra late selector loads per lane in exchange
for removing the post-capture capability mux. No stage added; timing unmeasured.
README updated; static driver/offset/movement review and diff check only, no
tests or synthesis.


### 2026-11-17 - reuse registered matches for retained producer refresh

Latest report: WNS -2.509ns/data5.002ns, buffered op_write0 through refresh
to Decode rs2 lane capture. Decode already registers source matches against
prospective writer destinations alongside packet motion; those destinations
become the current Issuer buffer on the same edge. Reuse these rs1/rs2_buffer_match
bits for retained producer refresh and identity capture enables instead of
repeating address/bank comparisons. Fresh arrivals retain live comparisons.
refresh_source now accepts a match vector qualified by current op_write.
No additional state/stage or acceptance dependency. Matches and buffer payload
freeze together on stall; invalid/flush state is protected by write validity and
packet validity. Existing youngest-writer dedup makes masked OR unambiguous.
Expected reduction in retained correction-control depth is unmeasured. Static
match lifecycle/interface review and diff check only; no tests or synthesis.


### 2026-11-17 - register producer-table capture readiness

Latest report WNS -2.461ns/data4.927ns starts at capability27 through entry
readiness and table read mux to Decode operands_ready. ProducerTable.sv now
registers capture_ready per entry instead of deriving it on the read path.
Invariant after reset and every update: capture_ready equals the existing helper
evaluated on the current registered index/capability. Reset sets ready with RF
index; no-write advancement uses the same saturated aged_index for index and
ready evaluation; buffered writes use index1 and incoming capability. Write
readiness is computed per buffered writer before destination selection, using
existing deduplicated hit masks. Stall/redirect hold ready with the table.
x0 cannot be written, remains RF/ready despite unspecified capability. Helper's
existing subsequent-Decode-capture lookahead is preserved without extra aging.
Decode retained readiness, corrections and prospective writers are unchanged.
Tradeoff: up to32 redundant state bits and update logic, shorter table-read
launch path; timing unmeasured. Static reset/write/age/hold invariant review
and diff check only; no tests, elaboration or synthesis.


### 2026-11-17 - remove flush masking from direct serve payload selection

Latest path redirect input -> masked consumption -> direct source-bank register
has WNS -2.699ns, 3.095ns internal delay after3.250ns input delay. Decode now
exports serve_select_count = stall ? 0 : serve_consumed_normal independently
of flush-masked serve_consumed. Dispatch/Frontend/Fetch interfaces carry this
internal selector to all direct payload captures. Queue direct registers capture
unconditionally; reset/delayed-reset/redirect still clear bank validity and queue
state, making their payload immaterial. External consumption remains zero on
flush/stall. Normal cycles selectors agree; stalled cycles select zero preserving
retained/refill mapping. Flush discards arbitrary captured payload; subsequent
refill uses cleared validity. FIFO bookkeeping continues using masked consumption.
No stage change. Timing benefit unmeasured; static interface/flush/refill review
and diff check only, no synthesis/tests.


### 2026-11-17 - precompute system/CSR trap result alongside prediction

Latest report WNS -2.125ns/data4.585ns, prediction instruction17 through legality
to FIFO trap. Moved system instruction exact encoding and CSR address/write
policy into SystemTrapPredecode, parallel to prediction. Queue captures its
TrapType result with prediction_payload under identical reset/transfer enables.
InstructionLegality selects the captured result only for full SYSTEM opcode;
compressed legality/traps and all other opcode checks remain after prediction.
Original CSR policy, FP CSR gating, ECALL/EBREAK and legal MRET/WFI preserved.
Four-bit enum has constant top bit (only NONE/ILLEGAL/ECALL/EBREAK), so three
varying bits per prediction slot, with no FIFO payload expansion or new stage.
Tradeoff is earlier CSR decode work; may move bottleneck into prediction stage.
Static extracted-case/metadata-lifetime review and diff check only; no tests
or synthesis. Timing impact unmeasured.


### 2026-11-17 - direct low-immediate equations

Latest prediction-to-FIFO immediate-low path WNS -2.251ns/data4.747ns crosses
encoded format then payload selection. ImmediateLowPredecode now uses disjoint
raw encoding predicates and explicit per-bit cases, removing its format-number
encoder/decoder and unused32-bit assembly. Compressed ADDI/LI/ANDI/shifts share
low wiring; remaining layouts copy original low5bits, including ADDI4SPN,
ADDI16SP, branch/jump and stack loads/stores. FP predicates remain parameter
gated; unsupported encodings remain don't-care. No extra prediction registers
or stage move in this change; first measure the flattened function before
adding pressure alongside the just-moved system/CSR predecode. Static original
format-to-low-bit mapping review and diff check only; no tests or synthesis.
Timing impact unmeasured.


### 2026-11-17 - trim direct capture selector load

Latest WNS -2.153ns/data4.602ns is banked validity through high-fanout controls
to direct upper-layout capture. Returned fourteen upper-immediate layout enables
per lane to speculative bank storage/post-edge selection. This removes28 direct
payload bits in dual issue from late consumption capture. Kept instruction/c,
sources/bank flags, trap, capability and FP-consumer direct because they feed
multiple deep readiness/structural calculations. Immediate decode may become
critical again; this is a measured tradeoff experiment, not proven improvement.
No mapping, flush or latency changes; retained data uses selected bank output.
Discussed targeted routing options without changing Tcl implementation settings.
Static sole-driver/movement and diff check only; no synthesis/tests.


### 2026-11-17 - directly capture serve validity

Latest WNS -2.229ns/data4.640ns starts at previous consumption through banked
validity to direct instruction capture. Queue now selects next_window MSB
(valid) before capture using serve_select_count, aligned with direct payload.
Reset/delayed-reset/redirect explicitly clear valid independent of selector.
Retained candidates and keep_count read direct validity; unused banked valid
outputs can prune. Normal-cycle internal selector equals protocol consumption;
stall selects zero, retaining valid entries while allowing vacant-slot refill.
During flush all serve banks/state reset and direct validity clears, so arbitrary
payload capture cannot escape. FIFO head/occupancy/free banks retain existing
selection and stay aligned. No stage or occupancy-policy change. Expected to
remove bank-selection delay ahead of validity-driven feedback, at cost of one
late capture load per lane. Timing unmeasured. Static state/flush/hold/refill
review and diff check only; no tests or synthesis.


### 2026-11-17 - directly capture destination identity

Latest WNS -2.176ns/data4.631ns starts at bank selector through served rd[2]
to registered group_raw[1]. Queue now directly captures rd plus rd_float
(six bits per lane) from completed next_window selected by serve_select_count.
Extraction uses SOURCE_FLAGS_LSB+9 +:5 for rd and SOURCE_FLAGS_LSB for bank.
Packed layout unchanged; retained windows use direct outputs and unused banked
copies prune. Capture is unconditional like other payload; validity explicitly
clears on flush, stall selects zero and vacant slots may refill. No stage change.
Adds six late-selector loads per lane while removing bank mux from destination
side of RAW compares. Benefit unmeasured. README updated; static packed-offset,
sole-driver and candidate-alignment review plus diff check only, no synth/tests.


## 2026-11-17 â€” Latest aggressive implementation result recorded

Added one run to the main architecture timing table from build/frontend_retry/20261117_133514/09_hold_final. Current configuration: RV32IMAFC, issue width 2, FIFO 8 words, cache line 1 word, five total lanes. Target period 2.500 ns; final WNS -1.901 ns, TNS -6407.891 ns, WHS +0.101 ns, THS zero. Slack-derived period 4.401 ns / estimated 227.22 MHz; utilization 5,273 Slice LUTs and 3,262 Slice Registers. This records the completed final aggressive rerun, not a new implementation setting or RTL change. Validation: read final timing/utilization reports and current Parameters.sv; no synthesis or tests run.


## 2026-11-17 — Correct memory-lane configuration and mask labels

Changed Core/Package/Parameters.sv memory mask from 110 to 001 for the current M/D-enabled, F/A-disabled dual-issue configuration. Bit zero must remain set to cover baseline memory operations; disabled extensions mask off bits one and two. Added explicit bit-order labels and accurate enabled-capability comments for integer, memory and floating masks; marked the zero-count FP entry as a placeholder and replaced the obsolete coverage-check TODO. No stage or timing structure changed. Validation: static comparison with DerivedParameters mask interpretation; no synthesis or tests run.


## 2026-11-17 - RV32IMC aggressive retry intermediate result

Recorded latest completed stage build/frontend_retry/20261117_135542/06_clock in the main timing table: issue 2, FIFO 8, cache line 1, four total lanes. Target 2.500 ns; WNS -1.734 ns, TNS -5154.756 ns, WHS +0.117 ns, THS zero; estimated period 4.234 ns / 236.18 MHz; 4,579 LUTs and 2,902 FFs. Retry progress reports 07_restructure, so this is an intermediate completed checkpoint, not final retry output. Validation: read saved stage reports and current parameters; no synthesis/tests run.


## 2026-11-17 - RV32IC completed aggressive retry recorded

Added the final build/frontend_retry/20261117_140558/09_hold_final result to the main timing table. RV32IC, issue width 2, FIFO 8, cache line 1, two integer lanes plus memory and serial (four total); all optional M/D/F/A disabled. Target 2.500 ns; WNS -1.838 ns, TNS -5250.970 ns, WHS +0.088 ns, THS zero. Estimated period 4.338 ns / 230.52 MHz; 4,482 LUTs and 2,890 FFs. Validation: final saved timing/utilization reports, completed retry progress and current parameters inspected. No RTL changes, tests or synthesis run.


## 2026-11-17 - Single-issue RV32IC retry result recorded

Recorded latest completed build/frontend_retry/20261117_144222/03_hold_aggressive stage: RV32IC, issue 1, FIFO 8, cache line 1, three total lanes (integer, memory, serial). Target 2.500 ns; WNS -1.612 ns, TNS -3460.126 ns, WHS +0.102 ns, THS zero. Slack-derived period 4.112 ns / estimated 243.19 MHz; 2,790 LUTs and 2,141 FFs. Retry is at 04_pins, so this row is intermediate rather than final. Validation: saved reports and current parameters read; no synthesis or tests run.


## 2026-11-17 - Single-issue adjusted I/O model completed retry

Recorded build/frontend_retry/20261117_151642/09_hold_final: RV32IC issue 1, FIFO 8, cache line 1, three lanes, 2,828 LUTs and 2,141 FFs. Target 2.500 ns; WNS -0.992 ns, TNS -1032.770 ns, WHS +0.098 ns, THS zero; estimated 3.492 ns / 286.37 MHz. Stages 08 and 09 tie for best setup and TNS. Late-control maximum input delay is now 2.500 ns instead of 3.250 ns, minimum remains 2.000 ns; main table preface distinguishes the models. Worst setup is instruction BRAM output to fetch branch staging, not redirect. Validation: completed retry reports, parameters and Tcl inspected; no implementation or tests launched.
