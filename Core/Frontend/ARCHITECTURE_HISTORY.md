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

DispatchTop wires Fetch serve_rs1/serve_rs2 registers directly to ProducerTable read addresses. Decode consumes the same served identities and returned producer metadata, with its address pass-through outputs removed. Table ownership, capture-edge aging and correction timing retain their existing alignment. This wiring simplification may affect synthesis locality but has no measured timing result.

The oldest resolving branch drives the fetch PC on its advancing edge. BackendTop registers the redirect pulse and issue slot. During the following recovery cycle, staging may capture the target read. The CAM removes group zero and younger writers in group one, then advances survivors with their lanes unless an independent stall holds execution. Decode and Issue still use the youngest same-group destination for immediate correction. Branch-capable integer lanes compute sequential next_pc for link data and fall-through recovery.

Fetch now selects every serve payload field and FIFO head/occupied/free outcome before one register set. The speculative registered banks and prev_serve_consumed are removed. Combinational retain/refill outcomes remain to prepare values before the late select (since 2026-11-23: serve_normal_count picks the normal outcome, then stall picks between it and the consumed-zero outcome). All fields and bookkeeping select the same outcome. Flush clears validity and queue state, while payload is irrelevant. Stall selects zero and permits vacancy refill. Same-edge FIFO pushes are still unavailable to refill, and admission still gives no pop credit.

Decode relies on elaboration-time lane coverage for individual instructions. The distinct-lane check covers same-group serial conflicts because SYSTEM and CSR share lane zero. IssueContract checks live serial occupancy. The frontend lane model consumes only input age from the serial issuer packet because CSR integer operands require RF readiness and SYSTEM has no integer sources. FP-consumer classification ends at Decode readiness.

InstructionMemory reads and captures halfword alignment every edge without payload
reset; reset clears only response validity. Queue reset/validity gates consumption.

Main implementation (Synthesis/Scripts/frontend.tcl) uses Default synthesis and
RuntimeOptimized opt/place/route, without physical optimization. Checkpoints go to
Synthesis/Build/frontend and the final routed reports to Synthesis/Reports/frontend.
Synthesis/Scripts/frontend_retry.tcl remains a separate optional checkpoint experiment.



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
occupancy reset and Fetch's own flush gating independently enforce flush (serve_consumed was
replaced by the stall-free serve_normal_count on 2026-11-23).

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


## 2026-11-18 - Serial consumers use register-file-only operands

Decode readiness now includes CAP_SYSTEM and CAP_CSR in the existing RF-only consumer classification, alongside FP consumers of integer sources. Integer sources must reach the existing capture-edge RF threshold; current buffered and prospective new writers cannot satisfy them by forwarding or bypass. The existing source-valid checks keep unused and immediate operands from blocking issue. No packet state, stage, or issuer path was added; serial occupancy and pair checks are unchanged. This allows serial consumers to omit incoming forwarding ports at the cost of waiting for RF. Validation: static review of retained/fresh readiness and both writer override paths only; no synthesis or tests run. Timing impact is unmeasured.


## 2026-11-18 - Narrow serial RF-only qualification to CSR

Removed CAP_SYSTEM from Decode RF-only consumer classification; only CAP_CSR and the existing FP integer-source consumers qualify. Current RegisterSlice marks SYSTEM operations as having no integer source operands, so the broader classification was unnecessary. CSR register sources still wait for RF across snapshot, buffered and prospective-writer readiness; immediate/unused sources remain nonblocking. No state or stage changes. Validation: static source-use and classification inspection; no tests or synthesis run. Timing impact unmeasured.


## 2026-11-18 - Two-word cache line frontend timing

Recorded the completed aggressive retry at build/frontend_retry/20261118_143803/09_hold_final for dual-issue RV32IMAFC with FIFO 8, cache line 2 and five lanes. The 2.500 ns clock target produced WNS -2.126 ns, TNS -5896.822 ns and WHS +0.075 ns with zero hold violations. The estimated period is 4.626 ns, with 8,028 LUTs and 3,623 FFs. The main table labels the 2.500 ns late-control model as series B. Timing and utilization were read from the saved reports.


## 2026-11-18 - Remove redundant issue checks and sink fields

Decode relies on elaboration-time lane coverage for individual instructions. The distinct-lane check covers same-group serial conflicts because SYSTEM and CSR share lane zero. IssueContract checks live serial occupancy. The frontend lane model consumes only input age from the serial issuer packet because CSR integer operands require RF readiness and SYSTEM has no integer sources. FP-consumer classification ends at Decode readiness. Decode, Issue, IssueContract and both Top modules were reviewed statically. Area and timing effects are unmeasured.


## 2026-11-18 - Bounded instruction PCs

Parameters.MAX_MEMORY_ADDRESS is the inclusive byte limit (default 0x7ff). Fetch carries the address bits plus one overflow bit, capped at RV32 width, through prediction, FIFO and serve. Full redirect and PC-relative target inputs fold discarded bits into the guard before capture. Queue checks the last byte of each reconstructed instruction and carries instruction access faults through FIFO check-in. Out-of-range targets can lose their original high bits in the reported PC. Decode ties unused architectural PC bits low through lane capture. Static field and selector review only. Area and timing are unmeasured.


## 2026-11-18 - Full direct serve capture

Fetch now selects every serve payload field and FIFO head/occupied/free outcome before one register set. The speculative registered banks and prev_serve_consumed are removed. Combinational retain/refill outcomes remain to prepare values before the late serve_select_count. All fields and bookkeeping select the same outcome. Flush clears validity and queue state, while payload is irrelevant. Stall selects zero and permits vacancy refill. Same-edge FIFO pushes are still unavailable to refill, and admission still gives no pop credit. This removes the post-register head and payload muxes at the cost of wider late-selector loading. Queue.sv was changed. Static packing, selection and flush review performed. Timing is unmeasured.


## 2026-11-18 - Direct serve-register producer addresses

DispatchTop wires Fetch serve_rs1/serve_rs2 registers directly to ProducerTable read addresses. Decode consumes the same served identities and returned producer metadata, with its address pass-through outputs removed. Table ownership, capture-edge aging and correction timing retain their existing alignment. This wiring simplification may affect synthesis locality but has no measured timing result. Affected RTL is Dispatch/Top.sv and Dispatch/Decode.sv. Validation was static port/reference inspection and diff checking. No tests or synthesis run.

## 2026-11-18 - Deferred producer readiness encoding

Revisit once operation completion and forwarding times are settled. The candidate is to encode producers with identical readiness behavior into a compact class at issue and carry it through the write buffer, producer table and Decode FIFO. Three bits cover the current rules. Keep the instruction capability for lane selection and the cached capture_ready bit for fresh table reads.

Before choosing an encoding, verify that producers sharing a class become usable on the same cycle for every supported execution unroll and divider configuration, including index zero in the write buffer and later indices as waiting Decode packets age. Reassess whether a static class is sufficient for variable-latency results. The expected benefit is narrower metadata muxes. Area and routed timing are unmeasured. Proposal only.

## 2026-11-18 - Pipeline-aged producer CAM

Dispatch/ProducerTable.sv now represents committed integer owners with ISSUE_WIDTH slots at each index from one through EXECUTION_UNROLL+1. The issuer buffer covers index zero separately. This bounds storage by in-flight capacity and makes index implicit in position. Every advancing edge shifts one full group, including bubbles. Stall and redirect hold the groups, and reset invalidates them. Direct serve-register rs1 and rs2 reads compare writers within each age group in parallel and select the youngest matching group. Issue deduplicates simultaneous writes to one rd. A miss, including x0, returns the RF index and ready. Lane and capability on misses are immaterial. Per-owner capture readiness is registered at each stage using the existing helper. Decode capture aging and buffered corrections retain their existing interfaces. This exchanges register-indexed muxes and age counters for destination comparisons and group priority. Area and timing are unmeasured. Static interface and control review only.

## 2026-11-18 - Decode low immediate bits after serve

The routed prediction-to-FIFO path ended at fifo_immediate_low_reg[0][2] with -2.403 ns setup slack at a 2.500 ns target. DecoderSlice now evaluates the existing FP-parameterized low-bit equations using the served instruction and its compressed flag. Fetch Queue drops five bits from each FIFO entry and serve candidate. FrontendTop, FetchTop, DispatchTop and DecodeStage drop the corresponding wiring. Upper-immediate selection remains in Fetch. This moves logic onto the serve-to-Decode path and preserves instruction/flag alignment across holds and refills. Static wiring and packed-width review only. Timing after the move is unmeasured.

## 2026-11-18 - Qualify rs2 dependencies at FIFO check-in

The preceding route reached -2.088 ns setup slack from tail_partial to the prediction rs2 use bit. Dispatch/RegisterSlice.sv now classifies whether the encoding reads rs2. Fetch/Queue.sv captures that predicate alongside the decoded source number and bank, then qualifies it at FIFO check-in using the same kept prediction lane. Integer x0 is dependency-free and FP f0 remains a dependency. This moves the zero comparison and final qualification across prediction capture without adding FIFO fields or a cycle. Static port and check-in alignment review only. Timing after the split is unmeasured.

## 2026-11-18 - Direct CAM readiness reductions

The preceding route reached -2.057 ns from served rs2 to Decode operands_ready. Dispatch/ProducerTable.sv now derives RF-after-capture eligibility from the absence of a younger-stage hit, and ordinary readiness from whether the youngest hit blocks. Both a miss and the oldest group are ready after capture. Dispatch/Top.sv carries the RF predicate to fresh-source readiness in Dispatch/Decode.sv. Retained snapshots still use their local indices. This trades one combinational bit per operand for removing the fresh indexed threshold comparison and excluding the oldest stage from the readiness reduction. Reviewed miss, RF boundary and repeated destinations statically. Timing unmeasured.

## 2026-11-18 - Revert direct CAM readiness reductions

Restored youngest-hit selection of cached capture readiness in ProducerTable and the local fresh-source RF index comparison in Decode. DispatchTop again carries one readiness bit per operand. The experimental routed CAM segment went from 0.958 to 0.991 ns. The full matched register path improved from 4.514 to 4.381 ns through routing, while design WNS worsened from -2.057 to -2.213 ns. Reviewed the restored lookup and wiring statically. No implementation rerun.

## 2026-11-18 - Resolve writer priority alongside the CAM read

The routed serve-rs2 to operands_ready path had 2.311 ns following the CAM result. Dispatch/Decode.sv now computes a writer match and ready bit per source and pop outcome before selecting the snapshot as fallback. The youngest prospective writer in the consumed prefix overrides the registered buffer, which overrides the committed snapshot. The snapshot joins once per operand before the existing packet readiness and slot selection. This reshapes combinational work between the same registers and may shift the limiting arrival to buffered rd. Reviewed the no-match, buffered-hit, prospective WAW and RF-only cases statically. No synthesis or measured timing for this change.

## 2026-11-18 - Use registered serial lane type in IssueContract

IssueContract.sv gates live serial occupancy with the registered SERIAL lane type. Issue.sv drops the contract's packet input. Decode maps exactly CAP_SYSTEM and CAP_CSR to SERIAL and carries lane type with the selected packet. This removes capability decoding from this acceptance predicate with no new registers. Checked the mapping and port wiring statically. Routed timing is unmeasured.

## 2026-11-18 - Remove fetch address range trapping

The preceding route ended at the predicted target guard bit with -2.116 ns setup slack. DerivedParameters now sizes fetch PCs to the address bits alone, with a one-bit minimum. Fetch/Predictor and Fetch/Queue truncate targets, redirects and sequential PCs to that width. Queue removes instruction extent checks, fault-based branch suppression and the FIFO trap override. FIFO check-in takes the predecoded trap directly. Addresses wrap modulo the representable width, including split instructions at the boundary. Non-power-of-two ranges have unenforced unused addresses. Reviewed RTL references and diff statically. Timing after removal is unmeasured.

## 2026-11-18 - Predicted successor wrap metadata

Predictor computes the low target and carry together. Whole-window displacement tests run in parallel with that sum. Fetch Queue selects the wrap flag for a taken prediction or compares remaining address space with the 2/4 byte fall-through step at FIFO check-in. Queue, FetchTop, FrontendTop, DispatchTop, Decode and DecoderSlice transport the flag to Definitions.DecodeCommon_.predicted_pc_wrapped with its instruction. For a split instruction the reference is the reconstructed start PC. The flag covers crossing the width-defined window in either direction, even by several windows. It describes the predicted successor only and does not trap or steer fetch. Compared with the old range trap it avoids full target arithmetic and instruction extent fault plumbing, at the cost of one packet bit. Static arithmetic and packing review only. Area and timing unmeasured.

## 2026-11-18 - Prioritize predicted wrap at FIFO trap capture

Fetch/Queue.sv resolves the per-lane wrap flag from registered prediction results before FIFO check-in. A kept lane with a wrapped predicted successor captures INST_ACCESS_FAULT in its own trap entry ahead of all legality and system traps. FIFO trap and wrap metadata share the same predicate, index and write edge. The additional timing cost is the trap select before FIFO capture. Static wiring and diff review only. Timing is unmeasured.

## 2026-11-18 - Select the wrap trap on FIFO pop

The check-in route from prediction instruction bit 14 to fifo_trap[1][2] had -2.658 ns setup slack. Fetch/Queue.sv now stores the decoded trap and wrap flag independently. Each fresh serve candidate selects INST_ACCESS_FAULT on wrap from the same FIFO read index before the late consumption mux. Retained candidates carry their already resolved trap. This shifts the override from FIFO write to FIFO read. Static check of fresh and retained packing and diff only. Routed timing after the move is unmeasured.

## 2026-11-18 - Register FIFO push rank at prediction capture

The routed prediction lane-valid to FIFO instruction data path measured 5.120 ns and -2.651 ns slack. Fetch/Queue.sv now captures each lane's keep flag and relative write offset from the existing stage push-count calculation. The first valid taken lane is kept; younger lanes cannot write or redirect. Check-in adds the captured rank to the current tail. Capturing relative addresses permits an older group to commit on the same edge as prediction replacement. Backpressure holds the captured group and flush clears its keep flags. This adds rank registers and loads the prediction-stage prefix, removing prefix recomputation from FIFO write selection. Reviewed holes, first-taken suppression, simultaneous replacement and stalls statically. New timing unmeasured.

## 2026-11-18 - Decode BRU operation after serve

The 5.012 ns routed prediction-to-check-in path ended at fifo_branch_operation_reg[3][3] with -2.604 ns slack. DecoderSlice now runs the existing BranchOperationPredecode for each served instruction, retaining compressed decoding and BR_NONE trap qualification. Fetch Queue and the Fetch, Dispatch and frontend interfaces drop four bits from each FIFO entry and serve candidate. Prediction still uses its own branch and taken metadata. The operation logic moves onto the Decode capture path. Static wiring and packed-field review performed. New routed timing is unmeasured.

## 2026-11-18 - Halve upper-immediate serve controls

The preceding routed path ran from prediction_offset to a FIFO data bit with -2.452 ns slack. Fetch/ImmediateUpperPredecode.sv now produces seven compressed layout enables directly. Queue and the frontend and dispatch interfaces carry seven bits per entry. DecoderSlice derives the other seven enables from the same served instruction and compressed flag, reusing local opcode and FP-gated predicates. I and S still share their upper layout. This narrows the payload driven by push selection while adding decode-side dependencies; the offset calculation itself is unchanged. Checked the mapping against the prior format table, port widths and fresh/retained packing statically. Timing unmeasured.

## 2026-11-18 - Register physical FIFO write slots at prediction capture

The preceding routed path ran from fifo_tail to fifo_data at -2.246 ns setup slack. Fetch/Queue.sv now adds each compacted lane rank to the post-commit tail at prediction capture. A concurrent outgoing push advances that base. Backpressure holds slots with their payload, and flush clears their keep flags. Check-in uses the registered slots directly. This moves slot arithmetic onto the prediction capture path while leaving FIFO write selection at check-in. Reviewed hold, flush and simultaneous replacement statically. Routed timing is unmeasured.

## 2026-11-18 - Direct allocation for singleton lane classes

Dispatch/Issue.sv uses an elaboration-time mask to route serial and any one-lane integer, memory or floating class around the priority encoders. Capability masks still qualify the claim and the oldest slot reserves the lane first. Multi-lane classes retain the younger-slot preference policy. This removes singleton lane choices from the generic selector without adding state. Static review covered disjoint lane classes and same-lane contention. Timing and area are unmeasured.

## 2026-11-18 - Remove duplicate free-count state and end wrap metadata at pop

Fetch/Queue.sv shares occupancy after committed pushes between admission and pop candidates. Capacity minus that occupancy gives the previous admission budget, preserving conservative no-pop-credit behavior and the registered room decision. This removes the complementary free counter and its candidate updates, with a possible timing cost on admission. FIFO pop still prioritizes the stored wrap flag over the decoded trap. Serve, Fetch/Dispatch wiring and DecodeCommon_ now carry the resulting trap alone. Downstream loses the separate wrap-cause indicator; current backend RTL uses no such indicator. Reviewed reset, simultaneous push/pop and serve packing statically. Area and timing unmeasured.

## 2026-11-18 - Detect traps entirely in DecoderSlice

Fetch no longer computes or transports system traps, legality results or FIFO wrap metadata. Queue FIFO and serve packing lose four trap bits. DecoderSlice invokes the existing system and instruction legality helpers on the served instruction and compressed flag. It recomputes predicted successor wrap from the served PC, instruction displacement and taken flag, giving INST_ACCESS_FAULT priority. This moves legality and wrap arithmetic onto the Decode capture path and removes their FIFO write selection. Predictor target wrap remains an unused helper output subject to synthesis pruning. Static port and packing review only. Timing unmeasured.

## 2026-11-18 - Narrow Decode wrap arithmetic

The first all-Decode trap route had -3.711 ns WNS and a 6.187 ns path through seven carry cells into operands_ready. DecoderSlice had unnecessarily formed a full 33-bit successor. It now adds only the compact PC and low displacement, using carry plus parallel signed whole-window checks to identify wrap. A 33-bit signed displacement extension handles the full-PC-width parameter case without an empty slice. Trap priority is preserved. Static arithmetic and diff review performed. New routed timing is unmeasured.

## 2026-11-18 - Remove Decode wrap detection

DecoderSlice now takes its trap directly from instruction legality and system/CSR checks. Removed successor displacement reconstruction, wrap addition and access-fault override. Compact fetch addresses wrap at their configured width without a Decode-generated address-range trap. Static reference and diff review performed. Timing is unmeasured.

## 2026-11-18 - Restore synced Prototype 3.3

Restored tracked RTL and Dispatch README to origin/main at 011f04f (Prototype 3.3), which matches local HEAD. This reverts the subsequent move of trap detection into DecoderSlice and the Decode wrap arithmetic changes. Preserved the newly added TODO lists in root ARCHITECTURE.md and retained experiment history here. Verified restored RTL matches the checkpoint with git diff. No synthesis or tests run.

## 2026-11-19 - Prepare FP load RF-only policy

Parameters.FP_LOAD_RF_ONLY defaults to zero and is exposed as a FloatingLane parameter. Zero permits memory-lane operand search, while one requires an FP load owner to reach RF. Enforcement is pending the floating operand-search datapath. The present integer CAM excludes FP destinations, so applying this parameter to its CAP_MEMORY readiness would incorrectly affect integer loads. FloatingLane records the intended reuse of the existing index >= EXECUTION_UNROLL+1 RF threshold, youngest-owner selection and rs3 coverage. No frontend scheduling behavior changes. Static interface review and diff check only.

## 2026-11-19 - Restart frontend timing comparison table

Replaced the prior rows in root ARCHITECTURE.md at user request. The first new row comes from retry 20261119_135047/03_hold_aggressive, identified by last_saved.txt as the latest completed stage. WNS -1.906 ns at 2.500 ns gives 4.406 ns and 226.96 MHz. Utilization is 5,337 LUTs and 2,276 registers. Progress reports 04_pins running, so the recorded result is intermediate. Parameters and current Tcl were read for configuration and common I/O assumptions. No synthesis or implementation run.

## 2026-11-19 - Record RV32IMC retry

Added the latest completed checkpoint 20261119_140022/06_clock to the existing table format in ARCHITECTURE.md. Target 2.500 ns and WNS -1.829 ns yield 4.329 ns and 231.00 MHz. Reports give 4,721 LUTs, 2,025 registers, TNS -4364.486 ns and WHS +0.119 ns. Current parameters disable F/A and configure four lanes. Progress reports 07_restructure running. Read reports and parameters only.

## 2026-11-19 - Record dual-issue RV32IC retry

Added 20261119_140825/03_hold_aggressive in the existing table format. WNS -1.969 ns at 2.500 ns gives 4.469 ns and 223.76 MHz. Reports give 4,737 LUTs, 2,019 registers, TNS -4137.456 ns and WHS +0.071 ns. Parameters configure dual issue, FIFO 8, cache line 2, two ALU/BRU integer lanes, one memory lane and serial. The next pass is 04_pins. Report and parameter inspection only.

## 2026-11-19 - Record completed single-issue RV32IC retry

Recorded 20261119_164435/09_hold_final in the existing main table format. WNS -1.081 ns at 2.500 ns gives 3.581 ns and 279.25 MHz. TNS -963.305 ns, WHS +0.104 ns, THS zero, 1,821 LUTs and 1,310 registers. Parameters specify issue 1, FIFO 8, cache line 1, unroll 1 and three lanes. Current Tcl sets late-control maximum input delay to 2.500 ns, so this row is labeled comparison series B, distinct from the prior 3.250 ns model. Report inspection only.

## 2026-11-19 - Record single-issue RV32IMC retry

Added completed 20261119_165304/09_hold_final in the current table format. Setup WNS -1.026 ns at 2.500 ns gives 3.526 ns and 283.61 MHz. Reports give 1,831 LUTs, 1,314 registers, TNS -1123.953 ns and hold WNS +0.111 ns. Series B input delays apply. Parameters specify issue 1, FIFO 8, cache line 1, three lanes, integer mask 1111 and memory mask 001. Read reports and parameters only.

## 2026-11-19 - Record single-issue RV32IMAFC retry

Added completed 20261119_170138/09_hold_final to the existing main table. Setup WNS -1.141 ns at 2.500 ns yields 3.641 ns and 274.65 MHz. TNS -1203.129 ns, WHS +0.070 ns, THS zero, 2,045 LUTs and 1,427 registers. Parameters specify issue 1, FIFO 8, cache line 1, four total lanes, integer mask 1111, memory mask 111, floating mask 11, unroll 1 and FP_LOAD_RF_ONLY=1. The 2.500 ns single-issue late-control input model applies. Report and parameter inspection only.

## 2026-11-19 - Connect frontend and backend under CoreTop

Core/Top.sv connects the registered frontend lane packets directly to BackendTop and returns global stall. Fetch takes the backend redirect on the advancing edge so a held branch redirects once. Instruction fetch retains its local memory, leaving the ordered LSU bus as the external data interface. Serial busy is tied low pending serial execution, and precise trap handling remains open. Fetch/Queue.sv declares prediction_payload before its first use for SystemVerilog elaboration. Static elaboration only.

## 2026-11-19 - Align branch recovery with backend advancement

A taken branch reproduced stale integer producer indices at unroll 3 and 13. CoreTop now carries the oldest resolving branch's issue slot from BackendTop through FrontendTop and DispatchTop to ProducerTable. An advancing redirect drops the incoming younger group, masks younger slots of the resolving group, and advances all older owners normally. Issue preserves pre-WAW write valids for the CAM, while the immediate correction buffer retains its existing deduplication. CAM lookup gives priority to the youngest surviving slot. This costs a write-valid bit per issue slot and introduces same-group priority in the read path. The frontend OOC script applies the late-control delay model to the new redirect slot. Timing impact is unmeasured.

IntegerLane generates sequential next_pc only in branch-capable lanes. Jumps write that value to rd and a predicted-taken branch that falls through redirects there. An invalidated operand wait cannot delay a redirect. Temporary whole-core Verilator checks passed at unrolls 1 and 13 with bypass and 3 without bypass. Checks covered physical producer identity after redirects, mixed dependency streams, all six branch conditions, full-width and compressed link writes, wrong-path stores, ALU/M operations and subword memory. No synthesis run.

## 2026-11-19 - Register branch redirects and reserve one recovery cycle

BackendTop latches the oldest redirect's target and issue slot when the resolving group advances. Local lane squashing still occurs on that edge so a younger AGU cannot enqueue a wrong-path store. CoreTop passes the registered event directly to Fetch and Dispatch. During its one-cycle pulse the backend holds lane positions and RF writeback, while accepted LSU requests may still return. Frontend validity and buffered writes clear on the recovery edge. Dispatch/ProducerTable repairs the already-shifted groups in place: invalidate group zero, trim group one at the resolving slot, and preserve all older owners and readiness. A preexisting global stall defers capture until the branch advances. An independent stall may keep execution held after recovery.

This adds one recovery cycle per misprediction and removes the combinational branch decision from frontend flush and target selection. Reviewed stall/flush priority and LSU advancement statically. No synthesis or simulation run for this revision.

## 2026-11-19 - Launch the target read before registered recovery

BackendTop and CoreTop send the oldest advancing redirect and its target directly to the fetch PC. The resolving edge launches the synchronous instruction-memory read. IntegerLane and MemoryLane mask operand-stage validity combinationally on resolution and retain age-selective squashing for the executing group. The registered event suppresses backend input acceptance for the recovery cycle.

FrontendTop and FetchTop route the early signal only to Queue's fetch PC and staging logic. Staging immediately masks old validity and rejects the old memory response. On the following edge the registered flush clears prediction, partial reconstruction, FIFO and dispatch state and repairs the producer CAM. A suppressed stale prediction cannot replace the target PC or prevent staging from capturing a valid target response with its request PC. A missing response keeps the target address pending. Fetched target data can therefore enter staging one cycle earlier, at the cost of a combinational backend-to-instruction-memory address path. The frontend OOC Tcl includes the early event in its late-control input group. Static signal tracing and whole-core elaboration only. No timing measurement.

## 2026-11-19 - Remove redirect from the global stall cone

BackendTop forms global stall from external backpressure and lane stall requests alone. IntegerLane and MemoryLane use packet presence before squash to qualify operand waits, while early redirect and registered recovery independently suppress execution validity. A waiting operand can therefore delay a redirect even if that operand will be squashed. Fetch redirect still fires only on an advancing resolution edge.

Dispatch/ProducerTable invalidates wrong-path owners before selecting advance or hold. In recovery an independent stall repairs validity in place; otherwise the surviving owners advance one stage and the youngest incoming group is a bubble. Older lane results and LSU work can progress through recovery. Reviewed direct and operand-valid stall dependencies, CAM indexing, and elaborated CoreTop. No simulation, synthesis, or routed fanout measurement.

## 2026-11-21 - Match integer memory producer ownership to execution

Definitions.sv shares the integer producer write predicate between Dispatch/Issue.sv and Dispatch/Decode.sv. Ordinary memory operations claim an integer destination only for a load writing nonzero integer rd. Atomics and FP-register destinations are excluded. Capture-edge eligibility for integer loads still permits issue into operand select before the LSU completes. Backend/Execute/Memory/MemoryLane.sv advertises forwarding readiness only for a registered successful load with a valid destination. Stores retain their completion requirement at the final slot. This adds destination and success qualification to the memory ready path. Faulting loads rely on future precise trap recovery to release dependents. Static RTL inspection and diff check only.

## 2026-11-21 - Register per-lane redirects; launch target with the recovery pulse

The routed CoreTop critical path ran from the branch operand through compare, mispredict, oldest-redirect arbitration and the `redirect_pc` mux, into Fetch/Queue advance and prefetch_pc logic, to the instruction BRAM address: 8.665 ns (12 logic levels) at a 10 ns constraint. A backend-only run put the backend half at about 5.5 ns.

Backend/Top.sv now registers each lane's raw redirect, age and PC on an advancing edge. There is no arbitration before the flop. In the following cycle a selector over those flops drives `redirect_pc` and `redirect_slot`, and pulses `redirect_fetch` and `redirect_taken` together. Lanes still squash younger work combinationally from the raw requests during resolution, so no wrong-path AGU or operand-stage packet survives. `recovery_flush` (= `redirect_taken`) kills the wrong-path packet that the frontend capture registers latched on the resolution edge.

Frontend effect: the target read launches at the recovery edge instead of the resolution edge. Queue already gives `redirect_fetch` priority over the flush's commit and transfer gating, so firing both in one cycle needs no Queue change. The target response is captured one cycle after the flush, with recovery already over. ProducerTable alignment is unchanged: the branch has advanced exactly once when `redirect_taken` is seen, so group 1 still holds the resolving issue group. The comments on the `redirect_fetch` ports in Frontend/Top.sv, Fetch/Top.sv and Fetch/Queue.sv now describe the registered launch.

Tradeoff: one extra cycle of fetch penalty per misprediction. All frontend redirect inputs now come from flops plus a lane-count selector. The frontend_ooc.tcl late-control input delays have not been revised to reflect that. Invariants: a lane request is captured only on an advancing edge, so a held branch redirects once. The recovery pulse is one cycle and is not stall-gated. Static review only; no simulation or synthesis.

## 2026-11-21 - Redirect is no longer deferred by global stall

Previously a resolving branch held by an unrelated global stall (operand wait, iteration, memory cutoff) did not redirect until it advanced, so every stall cycle added to the misprediction penalty. Backend/Top.sv now captures a fresh lane request on the first edge it appears, held or not. A per-lane `redirect_fired` flop is set when the capture edge is held and cleared when the branch advances. It blocks re-capture of the still-asserted raw request and gates the operand-stage kill in IntegerLane and MemoryLane (`any_redirect`), so correct-path packets that arrive after recovery are not killed. Execution-group squash (`stage_2_flush`) keeps using the raw request, so younger peers in the resolving group still die on the eventual advance.

A new registered `redirect_advanced` bit travels through CoreTop, FrontendTop and DispatchTop to ProducerTable. Detection and recovery are separated by exactly one edge, so the resolving group is in CAM group 1 if that edge advanced and still in group 0 if it was held. ProducerTable trims at that group, discards everything younger plus the incoming buffered write, and preserves older groups. This applies to both the shift and the hold paths. Frontend capture registers and the Issue write buffer already clear on `redirect_taken` regardless of stall. Fetch, decode and refill proceed while the backend is still held.

Invariants: one capture per branch instance; at most one edge between detection and recovery; `redirect_advanced` is meaningful only during `redirect_taken`. Tradeoffs: one flop per lane, one extra frontend-bound flop, and a 2:1 trim select in ProducerTable's validity filter. Static review only; no simulation or synthesis.

The frontend and backend OOC Tcl add `redirect_advanced` to the late-control group.

Same day, follow-up: removed the `redirect_fired` mask on the lane operand-stage kill (IntegerLane/MemoryLane `any_redirect`). Frontend capture registers load only when stall is low, and that stall is what holds the branch. The only packet present during the hold is the wrong-path one, which `redirect_taken` clears. On the release edge the branch advances as the new packet latches, so no packet is presented while a held branch is still asserting. `redirect_fired` remains in BackendTop only to prevent re-capture. Static reasoning only.

## 2026-11-21 - Register memory-lane forwarding readiness

Backend run (5 ns, frontend-contract output delay) showed `stall` out at -1.543 ns. The path ran memory slot `valid`, then a LUT deriving `forward_ready`, then consumer operand-wait select, the lane OR, and the port. MemoryLane's Slot now carries a `ready` bit computed from the next slot state (held-and-updated or shifted-in) and registered with the slot. `forward_ready_out` is a direct flop. Semantics are unchanged: valid, done, load, rd_valid and no trap, including a response captured during stall. This costs one flop per memory slot and moves the derivation onto the D side, where the late `response_valid`/`response_error` inputs now also feed `ready`. Expected to remove one LUT plus a route from the stall cone (unmeasured). Static review only.
Late global stall only selects between precomputed held and shifted-in readiness, keeping stall at mux-select depth into the slot flops.

## 2026-11-21 - Register divider iteration stall and integer final-slot readiness

Divider.sv's `iteration_stall` was an OR of every stage valid from the iteration boundary to the output. It is now a single `busy` flop. Busy is set on the advancing edge an instruction latches into the first iteration-region register (the magnitude latch when the boundary is 0) and cleared on the edge the final stage's result is captured. No region at all (boundary beyond the last stage) ties it low. This relies on the existing invariant: an iterating instruction stalls everything upstream, so at most one instruction occupies the region and nothing is pipelined past it.

IntegerLane's `forward_ready_out` was `iterative_done` ORed with a capability decode of the final slot. It is now `final_ready_q`. On an advancing edge it loads the inverse of "the incoming op is an iterating MUL/DIV". It sets on result capture (same priority as before), holds otherwise, and resets high. Semantics are unchanged; both stall and readiness are now direct flops in the global stall cone. Static review only.

## 2026-11-21 - Prune operand forwarding select to real sources

IntegerLane and MemoryLane indexed `forward_data`/`forward_ready` by the full registered lane and index fields. At the current configuration (4 lane IDs including the reserved serial lane 0, unroll 1) that synthesized an 8:1 select per operand, where only 3 entries are ever selected. The select now loops over lanes 1..N-1 and indices 1..EXECUTION_UNROLL. Index 0 is always the bypass path, and with bypass disabled Decode never makes an index-0 producer eligible. Lane 0 (serial) never forwards. At unroll 1 the index field is ignored, so each operand is a 3:1 lane select. Unmatched selections default to ready with don't-care data. BackendTop now drives inactive lanes' forward data as don't-care and their readiness as high, instead of leaving them undriven.

Bypass review: Decode marks a producer bypass-eligible only for a newly issued CAP_ALU writer (`candidate_bypass_ready`), which reaches index 0 when the consumer is captured. Issue maps index 0 to `use_bypass`, and the lane selects the producer lane's combinational ALU result. BRU link writes, loads and iterating MUL/DIV are not bypass-eligible and wait for index 1 (final-slot readiness). A stall freezes producer and consumer together, so a held bypass stays valid. Static review only.
The integer/memory operand select also excludes floating lanes (lane IDs above the integer and memory range). Serial lanes never forward, which is a deliberate routing-congestion choice, and floating lanes forward only internally.
No-match is structurally impossible (every issued operand names a bypass, RF, or a real forward port), so unmatched readiness is now don't-care rather than ready.

## 2026-11-21 - Reorganize the synthesis flow under Synthesis/

Root-level Tcl moved to Synthesis/Scripts: frontend_ooc.tcl became frontend.tcl, cpu_ooc.tcl became cpu.tcl, and backend_ooc.tcl became backend.tcl; frontend_retry.tcl, worst_path.tcl and worst_hold_path.tcl kept their names. The shared common.tcl replaces vivado_clean.tcl. It provides root resolution (scripts locate the repository from their own path and `cd` to the root, so `program.hex` still resolves), per-flow Synthesis/Build/<flow> for checkpoints and the generated XDC, Synthesis/Reports/<flow> for final reports, cleanup, and the shared synth/opt/place/route sequence. Constraints, directives and the RuntimeOptimized implementation are unchanged, so results stay comparable with earlier runs. The part argument is optional on every flow (default xc7a100tcsg324-3), and output-directory arguments were dropped. The worst-path scripts and retry take a flow name or checkpoint path. References to build/frontend_ooc and the old script names in earlier entries are historical.


## 2026-11-21 - Move ALU operand selection to the operand latch

Backend run, 5 ns: the worst path (-1.409 ns) was the ALU bypass loop. Lane 2's registered `alu.source` (fanout 184) drove the lhs/rhs select, then an SLT compare carry chain, then four LUT levels of result mux, then `bypass_data` (fanout 7), then lane 1's operand mux and `source_1`. IntegerLane now resolves PC/zero/immediate operands while latching `source_1`/`source_2` for CAP_ALU ops, and ArithmaticUnit takes final `lhs`/`rhs` with no source port. This also removes the case-with-default the old operand select had. The operand mux was restructured so every select is from registered payload. Forward/RF/zero/override values form an early value, and bypass data enters last through one 2:1. Bypass is suppressed when an override or an invalid source applies. Other units in the lane (BRU, MUL, DIV) are unaffected because overrides apply only to CAP_ALU ops; the result-select depth is unchanged. Expected to remove about one LUT plus the fanout-184 route from the loop (unmeasured). Static review only.

Same day, follow-up: the ALU operation is also decoded at the operand latch. IntegerLane registers an `AluControl_` (Definitions.sv) alongside `source_1`/`source_2`: one-hot result selects plus subtract and arithmetic-shift flags. ArithmaticUnit now has a flat AND-OR result select over those flops instead of a case on the enum, so result bit 0's eight candidates need about two LUT levels instead of four. This adds 10 flops per ALU lane and moves the decode before the operand register. If that side becomes critical, the decode can move back a stage. Static review only.

## 2026-11-21 - Register the divider's final digit step

With radix 4 (DIVIDER_AUTO_PIPE = 2, 16 digit stages), the worst backend path (-1.031 ns at 5 ns) was the combinational final stage. It ran the final trial subtract, the digit choice (fanout 95), the remainder negate, the rem/quotient select and the lane capture mux into `data_payload[2]` with 16 CARRY4 in one cycle. Divider.sv now registers the raw final quotient/remainder and sign flags (`stage_valid[STAGES]`), and sign correction plus selection feed the lane capture in the next cycle. Divide latency rises by one cycle. Updated to match: the iteration-region bound (`ITERATION_INDEX > STAGES+1` means no region), `valid_out`, IntegerLane `DIV_RESULT_LATENCY` (+1, which drives DIV_RESULT_STAGE and DIV_ITERATES), and Definitions `producer_capture_ready` `div_ready` (+1). The `busy` register's entry and exit logic is unchanged, since exit follows `valid_out`. Static review only.

## 2026-11-21 - Memory-lane presence is the accept bit alone

Backend run, 5 ns: the worst path (-0.837 ns) ran from the `decoder_packet[3]` capability input through a LUT3, the lane OR and the global OR to the `stall` output. MemoryLane's `input_valid` re-checked capability, load/store operation and FP register class on top of `accept`. Issue already guarantees lane compatibility (IntegerLane uses `accept` alone), so the check was redundant on the operand-stall path. `input_valid = accept` now. If Issue ever sends an unsupported op to a memory lane, that is an upstream contract violation, not something this lane filters. Static review only.

## 2026-11-21 - Backend OOC: model register-launched inputs from a real clock pin

The backend.tcl issue-packet input delay (1.3 ns) bundled clock-to-output with a boundary-route guess, and Vivado then added its own unplaced port-net estimate on top, so the route was counted twice. It also used the ideal-clock frame, which ignores the clock insertion that the launching frontend flops share with the backend's. Issue packets, accept, memory response data and bus handshake inputs are now constrained after synthesis (a `backend_post_synth` hook called by common.tcl's anvil_implement) with `-reference_pin` on a backend register clock pin. The values are only the launching cell's clock-to-output: issue/flags 0.40 max / 0.30 min, RAMB36 DO 1.80 / 0.60. The port net stands in for the boundary route. Reset and external_stall delays and all output delays are unchanged. This starts a new backend comparison series. Unmeasured.

## 2026-11-21 - Split lane stall into operand and iteration outputs

IntegerLane and MemoryLane no longer combine their stall terms. Each exports `operand_stall_out` and `iteration_stall_out`, and BackendTop's single OR takes all of them plus `external_stall`, so placement can centre one stall tree instead of chaining per-lane ORs.
- `operand_stall_out` = operand present && some source needs forwarding from an unready slot && the packet has no trap. A trapped packet needs no operands.
- `iteration_stall_out` is a direct flop. IntegerLane: MUL step / DIV busy. MemoryLane: a new registered `pending` slot bit (valid && !done), computed from the next slot state like `ready`.
MemoryLane's stall no longer ANDs `reset_active`: slot pending clears on reset, and frontend accept is reset. Static review only.

## 2026-11-21 - Remove global stall from idempotent backend enables

Three classes of enable used `stall` without needing it for correctness:
- **RF write enables.** IntegerLane `result_ready` was `valid && !stall && !trap && rd_valid`. It is now `valid && final_ready_q && !trap && rd_valid`. A held final slot rewrites the same register with the same value each cycle. `final_ready_q` keeps an unfinished iterating MUL/DIV result out of the RF, and no reader can see the interim state: younger consumers of rd map to this slot (forward/wait), and older ones already hold their operands. MemoryLane `result_ready` is now the registered `last.ready` flop (completed, successful load with rd).
- **Unit result capture.** `capture_mul`/`capture_div` were gated by `!stall` when not iterating. Unit pipelines hold under stall, so recapture writes the same value and the gate is dropped.

This removes `stall` from every RF register write enable (per destination, per port) and from the result-stage capture selects. Stall still drives pipeline payload/valid/operand enables, the MemoryLane slot hold select, LSU enqueue, unit stage enables and redirect capture, all of which need it. Precise traps later must revisit idempotent RF writes if a held final-slot instruction can be cancelled. Static review only.

## 2026-11-21 - Align cpu.tcl with the backend run

cpu.tcl now defaults to a 5 ns period (an optional second argument sets it), down from 10 ns. Its data-bus model is shared with backend.tcl through common.tcl `anvil_bus_constraints`: inputs use `-reference_pin`, RAMB36 DO is 1.80/0.60, handshake flags 0.40/0.30, request payload output delay 1.00 and handshake 1.30. The previous model applied 1.0 ns ideal-frame inputs and a 0 ns output delay on every output. Reset is unchanged. Frontend/backend boundary paths are internal in CoreTop, so comparing this run with backend.tcl separates real dependency from modeled port budgets. This starts a new CoreTop comparison series. Not run.

Same day, follow-up: dropped the trap qualification from `operand_stall_out` in both lanes. The `trap_type` compare pushed each operand term past one LUT6, giving 4 levels in the stall tree. A trapped packet waiting on an operand costs only a few cycles in a rare case.

## 2026-11-21 - First CoreTop run at 5 ns; take redirect off LSU payload enables

The first cpu.tcl run at 5 ns had WNS -0.482 ns (about 182 MHz). The worst path went from lane 1's `source_2` (fanout 153, 1.36 ns route) through the BRU compare, `actual_taken`, `redirect`, the memory lane's `stage_2_flush`, `request_valid` and the LSU enqueue enable, to the R pin of `queue[0].data` (0.31 ns R setup).
- IntegerLane: dedicated `bru_source_1/2` registers were added and then reverted the same day. They would load the operand mux, which is likely critical, and the LSU change alone targets this path.
- LoadStoreUnit takes `candidate` (MemoryLane `request_candidate` = `request_valid` before redirect squash) for payload write enables and enqueue rank, and keeps `pending` for occupancy (`pushes`, `tail`, `unsent`). Invariant: redirect kills only the youngest requests of a group (age > redirect age), and misaligned traps are already excluded from candidates, so a survivor's candidate rank equals its pending rank. A squashed candidate writes a slot at or past the new tail; that slot is free because a full batch always fits, and it is overwritten before it can be sent. The payload write also drops its `!reset` term (pointers reset; payload is don't-care).

Redirect now reaches only the LSU counters. Static review only.

## 2026-11-22 - LSU enqueue-then-retract for redirect-squashed requests

The second CoreTop run at 5 ns had WNS -0.413 ns. The path was `source_2` (fanout 183), the BRU compare, `redirect`, the memory lane's same-group kill, `pending`, the LSU `pushes` count and the `unsent` counter D. The earlier candidate split had removed the redirect from payload writes, but occupancy still counted only surviving requests.

LoadStoreUnit now counts candidates into `tail`/`unsent` at enqueue. The redirect reaches the LSU only through `squashed = candidates - pending`, registered as `squashed_q`. The next cycle uses `live_tail = tail - squashed_q` for enqueue position and the new tail, `sendable = unsent - squashed_q` for `request_valid`, and folds the retraction into the counter update.

Invariants:
- Redirect kills only requests younger than the branch within its group, so squashed entries are always the youngest at the tail.
- `request_valid` uses `sendable`, so a squashed entry is never presented, even if every older entry has already been sent.
- Squashed slots are free again from `live_tail` before the next batch writes. Capacity is unchanged, since a full batch always fits.
- `awaiting_response`, `return_head` and response routing are untouched; squashed entries are never sent, so they never expect a response.

The redirect now ends at one small register, at roughly the same depth as the slot valid bits it already feeds. The cost is a 2-bit register plus two small subtracts from flops: on `request_valid`, a bus output, and on the enqueue position. No latency change. STALL_AND_REDIRECT.md and ARCHITECTURE.md now describe the retraction. Static review only; not simulated or synthesized.

## 2026-11-22 - Restrict index-zero bypass to fast ALU operations

Third CoreTop run, 5 ns: WNS -0.525 ns. The worst path was the ALU bypass loop: `source_1` (fanout 93, 1.35 ns), the SLT/SLTU compare carry chain, a three-level AND-OR select on result bit 0 (eight candidates), `bypass_data` (fanout 7) and the consumer's 2:1 into `source_2`.

Bypass eligibility now excludes compares and shifts. `Definitions::alu_bypassable` (add, sub, xor, or, and) is checked by Decode's `candidate_bypass_ready`, the only place index-zero eligibility is granted: retained snapshots, buffered writers and CAM entries all describe producers at index one or later at capture. A consumer of an SLT/SLTU/shift result issued in the next group is therefore held by the existing readiness logic until the registered forward at index one, not given a bad bypass. ArithmaticUnit adds `bypass_result`, a four-term AND-OR over the adder and bitwise logic, which IntegerLane exports as `bypass_data_out`. The full `result` still feeds `data_payload[2]`.

Invariant: the eligibility set and the bypass output set must match; both reference the same function and comment. Tradeoff: one extra cycle when an SLT/SLTU/SLL/SRL/SRA result feeds the very next issue group. The comparator and barrel shifter leave the bypass loop. Static review only; not simulated or synthesized.

## 2026-11-22 - One-LUT bypass result and pruned consumer bypass select

Two changes to the ALU bypass loop, following an RTL audit of its exact fan-in:
- **Producer (ArithmaticUnit).** The three one-hot bitwise selects in `AluControl_` became a 2-bit `AluLogic_` code (`logic_op`: none/xor/or/and). Each `bypass_result` bit is now `control.sum & sum[i] | f(logic_op, lhs[i], rhs[i])`: six inputs, so one LUT6 straight after the carry chain. Before, it had seven inputs and needed two levels. The full `result` reuses `bypass_result` plus the shift and compare terms. The fan-in of `bypass_result` is exactly `lhs`, `rhs`, `subtract`, `sum` and `logic_op`.
- **Consumer (IntegerLane).** `bypass_data_1/2` were indexed by the full lane field over every lane ID. The select now loops only over ALU-capable integer lanes (`EFFECTIVE_INTEGER_CAPS[lane-1][0]`) with a don't-care default, matching the operand-source invariant. At two ALU lanes it is a 2:1 on one lane bit, which can merge with the final 2:1 into the operand register.

Expected (unmeasured): about one LUT level fewer on each side of the bypass loop. Static review only.

## 2026-11-22 - Post-place fanout optimization in all flows

Fourth CoreTop run, 5 ns: WNS -0.199 ns. The worst path was the multiplier's first stage: `source_1` (fanout 88, 1.38 ns route), partial-product generation and three carry-save levels into `product_vector`, with 78% of it routing. The four most recent worst paths all began at lane `source_1`/`source_2` (fanout 88-183, 1.2-1.4 ns first net).

common.tcl `anvil_implement` now runs `phys_opt_design -directive AggressiveFanoutOpt` between `place_design` and `route_design`, which covers backend.tcl, frontend.tcl and cpu.tcl. It replicates high-fanout drivers near their placed loads without RTL changes, so the operand mux's own load is unchanged. frontend_retry.tcl is post-route only and keeps its own explicit pass list. This is an implementation-setting change, so it starts a new comparison series for every flow; ARCHITECTURE.md notes it above the frontend table. Unmeasured.

## 2026-11-22 - Multiplier: move compression pass 6 into the adder stage

Fifth CoreTop run (5 ns, with the AggressiveFanoutOpt pass): WNS -0.284 ns. The worst path was again multiplier step 1: `source_2` (fanout 85, 1.42 ns; phys_opt did not replicate it), partial-product generation and five compression LUT levels into `product_vector`. Logic was 1.14 ns and routing 4.0 ns.

Multiplier.sv step 1 now registers the six rows after compression pass 5 (`product_vector[0:5]`). Step 2 runs pass 6 (6 rows to 4) ahead of the existing four-input 64-bit addition and the low/high select. There is no latency change. The cost is 128 more flops, plus one 3:2 level ahead of the final adder in step 2, whose slack has not yet been observed. This departs from the standalone-tuned split in ARCHITECTURE.md (6 compressions in step 1, 4 vectors), which was measured out of context at 4.321 ns. Static review only.

## 2026-11-23 - Precompute the normal serve pop; stall only as the final select

Sixth CoreTop run, 5 ns: WNS -0.305 ns. The worst path was the full stall round trip. It ran from a frontend capture flop (`issuer_packet[3].forward_lane_2`) through the memory lane's ready select and operand combine and the global stall OR (four LUTs). `stall` then fanned out to 1129 loads (0.94 ns), into Decode's `serve_select_count = stall ? 0 : normal` and from there into Queue's outcome selection and `fifo_head`, four more LUTs.

Decode now exports only the stall-free `serve_normal_count` (its existing `serve_consumed_normal`). The `serve_consumed` and `serve_select_count` outputs are gone from Decode, DispatchTop, FrontendTop and FetchTop. FetchTop and Queue take `stall` directly.
- **Queue serve window, `fifo_head`, `fifo_occipied_slots`:** the outcome indexed by `serve_normal_count` is selected first, from stall-free logic. `stall` then picks between it and the consumed-zero outcome (`serve_selected`, `head_selected`, `occupied_selected`). A stalled cycle still takes the consumed-zero outcome, which can refill empty serve slots, so this is a late 2:1 between outcomes rather than a clock enable.
- **`real_pc`:** the consumed PC step comes from `serve_normal_count`, gated by reset, `reset_reg` and `redirect_taken` (all early). `stall` is the register's hold (`else if (!stall)`), and `redirect_fetch` keeps priority.

Invariants: on a stalled cycle every structure selects the same outcome as before (consumed zero), and on a non-stalled cycle the same as before (the normal count). Flush still clears validity and queue state, and redirect still has priority for `real_pc`. Expected (unmeasured): `stall` reaches these registers through one 2:1 level or a hold instead of four LUTs. Static review only; not simulated or synthesized.

## 2026-11-23 - Precompute operand waits in Issue as per-slot watch bits

Seventh CoreTop run, 5 ns: WNS -0.291 ns. The worst path was the stall round trip again: memory slot `ready`, four LUTs of stall generation (per-operand ready select, operand combine, two-level OR), `stall` (fanout 1223, 1.17 ns), then a shared select decode Vivado re-extracted in the Queue serve window.

Issue now computes `watch[lane][index]`. A bit is set when any accepted integer- or memory-lane packet in the group has an operand that is valid, not read from the RF, not bypassed, and forwarded from that producer slot. These are the same terms the lanes used for `operand_stall`. It uses ungated acceptance (`accept_raw`), so stall stays out of the cone. Only dynamic-ready slots get a bit, from the new `Definitions::forward_slot_dynamic`: the integer final slot of a lane whose MUL or DIV iterates (matching IntegerLane MUL_ITERATES/DIV_ITERATES), and memory slots 1..EXECUTION_UNROLL. Statically ready integer slots, FP lanes and serial lanes contribute nothing. With the current configuration that is two bits: lane 1's final slot and memory slot 1.

DispatchTop passes `watch` out, and FrontendTop registers it with the lane packets under the same rule as `accept_vector` (clear on reset/redirect_taken, hold on stall). CoreTop wires it to BackendTop, where `stall = external_stall | OR(watch & !forward_ready over dynamic slots) | OR(iteration_stall)`. Every input is a flop: about two LUT levels instead of four. IntegerLane and MemoryLane no longer export `operand_stall_out`. backend.tcl adds `watch[*]` to the register-launched issue inputs.

Invariants: `operand_present` is `accept` alone, so the precompute is exact. The operand-source invariant guarantees every forwarded operand names a real slot, and a statically ready slot never needs a wait. `forward_slot_dynamic` must stay in step with the lanes' iteration rules. Scaling: watch width grows with dynamic producer slots, not consumer lanes; consumer growth lands in Issue's OR in front of a capture register. FP lanes' own dynamic operand search is out of scope. Static review only; not simulated or synthesized.

## 2026-11-23 - Multiplier: move compression pass 5 into the adder stage as well

Eighth CoreTop run, 5 ns: WNS -0.038 ns. The stall round trip and the ALU bypass loop no longer appear at the top. The worst path was multiplier step 1 at its post-pass-6 depth: `source_2` (fanout 91, 1.53 ns), a partial-product LUT merged with a pass-2 term, then passes 3-5 into `product_vector`, with 0.23 ns of adverse clock skew from operand-register placement.

Multiplier.sv step 1 now registers the eight rows after compression pass 4 (`product_vector[0:7]`). Step 2 runs passes 5 (8 to 6) and 6 (6 to 4) ahead of the four-input 64-bit addition and the low/high select. No latency change. Cost: 128 more flops (8x64 instead of 6x64) and two 3:2 levels in front of the final adder in step 2, whose slack has still not appeared in any report. ARCHITECTURE.md's in-core note is updated. Static review only.

## 2026-11-23 - Registered WAW conflict mask for RF write enables

Ninth CoreTop run, 5 ns: WNS -0.175 ns. The worst path was the RF write enable. It ran from lane 2's final-slot `trap_type`, through `result_ready` (fanout 35) and the memory port's same-cycle WAW dedup (5-bit `write_addr` compare plus age compare against every other ready port), then the per-register decode (fanout 32) and a 1.65 ns net, to `register_file[1][16]`.

IntegerLane and MemoryLane export `next_result_destination`/`next_result_age`: the rd and issue age that enter the final slot on the next advancing edge. That is stage LAST-1 for integer lanes, and the AGU stage (unroll 1) or `slots[UNROLL-1]` for memory lanes. BackendTop registers `conflict[i][j]` (port j younger, same rd) under `!stall` and holds it otherwise, since final-slot rd and age never change while held. `write_en[i] = result_ready[i] && !reset && !OR_j(conflict[i][j] && result_ready[j])`: flops only, with no address or age compare.

Invariant: the mask ignores validity, rd_valid, traps and the redirect kill (`stage_2_flush`), all of which are in `result_ready[j]`. A flushed, trapped or not-yet-ready younger writer therefore never suppresses an older one, which matches the previous behaviour, and the redirect stays out of the mask's cone. Cost: RF_LANES^2 flops (9 at three ports) and two small exports per lane. Static review only.

## 2026-11-24 - Writeback trap bit, serial lane, ISSUE_WIDTH write ports, LSU lockdown

Frontend part: Queue.sv gates `prediction_pc_wrapped` (sequential and predicted-target wraps, which become `INST_ACCESS_FAULT`) with `!DerivedParameters::FULL_ADDRESS_SPACE`. The new constant is `MAX_MEMORY_ADDRESS == 32'hFFFF_FFFF`; wraps are legal there and the wrap hardware compiles out. Enumerations adds `BUS_FAULT`.

Backend part:
- SerialLane is a lockstep lane-0 pipeline with the same stage numbering and redirect kill as IntegerLane, and no forwarding. It has named blank CSRs (`ControlRegisters_`; all others ROZ), no CSR behaviour and no RF write. Trapped packets raise `result_trap` at the final slot.
- BackendTop reverts the registered WAW conflict mask (2026-11-23). Writeback now age-compares the final-slot writers each cycle:
  - Writes are denied to anything younger than any raw trap.
  - Youngest wins WAW, among surviving ready writers.
  - Writes are suppressed under stall.
  - The k-th requesting writer drives port k of ISSUE_WIDTH IntegerFile write ports (previously one per lane).
- New output `trap`: a final-slot trap with no older pending final-slot result. It is not stall gated. Lanes export `result_pending`; `next_result_*` is removed.
- IntegerLane: a trapped MUL/DIV no longer lowers `final_ready_q`. Before, a trapped DIV could wait forever, because the divider never starts trapped operations.
- MemoryLane and LoadStoreUnit lockdown:
  - The AGU detects frontend traps, misalignment and the access range (`last_byte > MAX_MEMORY_ADDRESS`, compiled out at full address space).
  - Trapped requests are enqueued, are pending until the LSU completes them, and lock the LSU at the send head. Bus errors set `BUS_FAULT` and lock it too.
  - While locked, entries pass without the bus and complete locally, with no error and garbage data. Slot readiness no longer excludes traps, so consumers never deadlock; `result_ready` still does.
  - Memory `result_trap` requires completion. On `trap` the LSU drops all entries, discards responses still owed, and blocks check-ins for 3 cycles.
- The inactive-lane `pending`/`candidate` ties were fixed: the second assign sat outside the `if`.
- SerialLane is added to cpu.tcl and backend.tcl; backend.tcl constrains `trap`.

Invariants: there are no redirect overrides at writeback. A redirect kills younger group members on entry to stage 2 (or at the AGU/LSU squash), so writeback instructions are always older than any in-flight redirect, at unroll 1 too. Trap kill uses the raw lane trap bits, so younger writes are denied even while an older pending result holds `trap` low. Flush is not implemented: after a trap, dropped LSU entries leave their lane slots pending until flush exists.

Tradeoffs: the address/age compare and the stall term are back on the RF write enable, with port compaction behind them (timing deferred by request). Static review only; not simulated or synthesized.

## 2026-11-24 - Writeback trap flushes the pipeline

Changes since the previous entry also include ChatGPT review fixes, already in the tree:
- The LSU flushes once per held trap.
- Memory AGUs arriving during the check-in lock are canceled.
- An outstanding-only error cancels a send, which removes the combinational handshake loop.
- Stores wait until no response is outstanding, making bus faults precise. This is a throughput cost on load-to-store sequences and still awaits a decision.
- Write port k is now selected by issue age k instead of the k-th-writer compaction.

Backend flush on the `trap` edge, stall or not. The trap fans out to valid bits only:
- integer, memory and serial `valid_payload`
- memory slot valid/ready/pending
- MUL/DIV valid and busy bits, through the unit `reset`
- IntegerLane `final_ready_q`, set back to 1

Older survivors in the trapping group commit on that edge even under stall (`write_en` uses `!stall || trap`). The slot-wide `wb_trap` cancel added by the review is removed, because the valid clear supersedes it. Pending branch captures (`redirect_q`, `redirect_fired`) are dropped on the trap edge.

Frontend: BackendTop registers the trap as `redirect_trap` and ORs it into `redirect_taken`/`redirect_fetch`, with `redirect_pc` = SerialLane `trap_vector` (blank mtvec, zero). This is the full branch-recovery flush. FrontendTop and DispatchTop pass `redirect_trap` to ProducerTable, which then drops every entry instead of trimming by slot. Producers between group 1 and writeback are flushed too, so a positional trim would leave stale forwarding owners.

Invariants: the trap is the oldest event in flight, so it overrides any same-cycle branch recovery. A stage-0 packet captured on the trap edge is killed by `recovery_flush` in the recovery cycle. A spurious one-cycle operand stall from that packet's registered watch bits is harmless, because recovery runs under stall. frontend.tcl and backend.tcl add `redirect_trap` to the late controls. Static review only.

## 2026-11-24 - Bus-discovered memory traps, CSR read/write, counters

Reason: a frontend-trapped instruction in a memory lane needed barrier and phantom machinery in the LSU. Removing the case is simpler.

Decode (frontend): DecoderSlice rewrites a trapped CAP_MEMORY/CAP_ATOMIC packet to CAP_SYSTEM, and lane type follows, so it issues to the serial lane. This adds a trap compare in front of the capability and lane-type outputs, an unmeasured timing cost. A CSR write to a read-only address (csr[11:10] == 2'b11) now decodes as ILLEGAL. cycle/cycleh/instret/instreth map to the counter indices.

Memory: every memory trap is now discovered by the bus. The AGU misaligned and range checks, the request trap, the LSU barrier entries and barrier lock are removed. The bus gets the full byte address and a new `request_size` (CoreTop/BackendTop port), and must return `response_error` for misaligned, out-of-range and failed accesses. All three are BUS_FAULT for now, so the precise cause is lost until cause mapping exists. Bus-error lockdown, phantom completions, the flush and the 3-cycle lock are unchanged. `Parameters::PRECISE_BUS_FAULTS` (default 1) keeps the store gate; 0 opens it (imprecise). FULL_ADDRESS_SPACE now only gates the fetch PC wrap logic.

Serial lane: it has its own rs1 RF read port (IntegerFile READ_PORTS = 2*RF_LANES+1). The CSRs are a generic register file: the final slot reads the old value into rd, and CSRRW/RS/RC write on the retiring edge. mcycle and minstret are 64-bit counters. A CSR write replaces the written half after the instruction completes. A minstret write lands after older and self retirements, and younger same-group retirements count after it. Lane outputs `result_valid`, and BackendTop forms per-writer retirement (valid, not trapping, not killed), `retire_count`, `retire_older` and `retire_edge` ((!stall || trap) && !reset). trap_vector is the stored mtvec.

Invariants: one serial instruction per group (Issue's serial hazard) and in-order serial issue make a final-slot CSR read see every older write. Static review only; nothing linted, simulated or synthesized.

## 2026-11-24 - Interrupts, trap entry CSRs, trap skid buffers, MRET

Frontend: DecodeStage gets `interrupt_request` (TrapType_, from serial-lane flops through BackendTop, CoreTop, FrontendTop and DispatchTop). If slot 0 is valid and no tag is in flight, slot 0's `trap_in` becomes the interrupt type. This puts a 2:1 mux on slot 0's trap input, ahead of the existing trap logic (legality `ok`, the memory reroute and the RO-CSR check); the timing cost is unmeasured. `interrupt_in_flight` sets when slot 0 is consumed (`!stall && serve_consumed_normal != 0`) and clears on any `redirect_taken`. Interrupt tags take priority over fetch traps. The frontend.tcl easy controls now include `interrupt_request`.

Backend: CoreTop/BackendTop take `interrupt` and `interrupt_type` (InterruptType_: software, timer, external). Each pulse sets an mip bit (sticky). The request is `mip & mie & mstatus.MIE`, with priority MEI, MSI, MTI.

Lanes export final-slot `result_trap_type` and `result_pc`; the memory slot gains a pc field and always reports BUS_FAULT. BackendTop adds a per-writer trap skid with no enable: type, PC, and take = `trap && writer_trap && !killed`. In the skid cycle (`redirect_trap`) a one-hot select feeds the serial lane's trap entry. Trap entry writes mepc and mcause, sets MPIE = MIE and MIE = 0, and clears the taken mip bit. MRET sets MIE = MPIE and MPIE = 1. An interrupt is checked again against the live enables; if it is no longer enabled, nothing is written and the redirect goes to its own PC. `redirect_pc` = `trap_target` replaces `trap_vector_q`. MRET raises `result_trap` (flush at writeback) and `result_mret`, so it still retires.

CSRs: mstatus (MIE/MPIE only; MPP = M, FS = 0), mie/mip (3 bits each), mtvec (direct only), mepc (bit 0 zero), mcause (BUS_FAULT = 24, custom), and misa (read-only constant).

Invariants: the skid cycle follows a trap flush, so no CSR instruction can commit in it. An interrupt-tagged packet has no side effects, and its PC is the correct mepc. Static review only; nothing linted, simulated or synthesized.

## 2026-11-24 - Order decode admission around interrupt boundaries

DecodeStage now admits a prefix ending at the first decoded trap, MRET or write to mie/mstatus. A trap or MRET holds younger packets in Fetch until redirect. This prevents a younger store from reaching the bus while the trap travels to WB. A mask write releases admission on a registered serial-lane commit indication so the next instruction sees the new enables. Older redirects clear both holds. Fetch consumption, decode validity and occupancy use the same prefix under stall and partial refill. DecoderSlice sends all frontend traps to the serial lane and enforces the fixed-Off FS policy on FP instructions and FP CSR accesses. SerialLane arbitrates live interrupt priority at entry and clears only the serviced source.

CoreTop, both backend/frontend tops and DispatchTop carry the commit pulse. The existing relaxed frontend Tcl input group and backend output group include it. These boundaries cost refill bandwidth around mask writes and add combinational work to Decode admission. Timing is unmeasured. Validation was static inspection of slot consumption, squash, CSR commit, priority and port wiring, plus a diff whitespace check.

## 2026-11-24 - Decode admission boundary off the pop path, mask-write hold removed

Review of the previous entry. Its window boundary `ends_group` used DecoderSlice outputs: final trap_type (behind the interrupt mux, RO-CSR and FP-state checks), system.operation and csr.index/write_enable. That boundary feeds `valid_inputs`, then `serve_consumed_normal`, then `serve_normal_count`, the select on Fetch Queue's head/occupied/serve muxes, so it put full decode on a known critical path.

Change (Decode.sv): `ends_group` is now a conservative superset formed only from registered serve fields. It covers a fetch trap, CAP_SYSTEM/CAP_CSR, FP state access when SUPPORT_FLOAT, and the slot-0 interrupt tag. A false positive only splits a window; CSR/SYSTEM already issue one per group. `wait_recovery` is set from the exact decoded packet (trap_type != NONE or MRET) as a flop D input.

Removed the mie/mstatus write hold (`wait_irq_csr`) and the SerialLane `irq_csr_committed` output, plus its BackendTop, CoreTop, FrontendTop and DispatchTop plumbing and tcl constraints. The disable case was already safe through trap-entry re-check and refetch. The hold only advanced an enabled interrupt by a few cycles, which the spec does not require, at the cost of a refill per mie/mstatus write.

Kept from the review: the post-trap admission stop, trap-entry priority re-selection, and FP state ILLEGAL while FS is Off.

Expected effect, unmeasured: the pop count depends on registered serve fields plus `interrupt_request` (serial-lane flops) and `wait_recovery`. Static review only.

## 2026-11-24 - CSR whitelist in Fetch, FENCE.I refetch, serial lane cleanup

Fetch (SystemTrapPredecode): the CSR case is now a whitelist for an M-mode-only core. Fixes:
- cycle/cycleh/instret/instreth were ILLEGAL, which left Decode's alias mapping dead. They are now legal.
- medeleg/mideleg/mcounteren were legal read-only. They are now ILLEGAL (no S/U mode).
- mcountinhibit was ILLEGAL. It is now legal read-only zero.
- mtval, mstatush and mhpmcounter/mhpmevent were read-only, so writes trapped. They now live in writable space as zero, and writes are ignored.
- FP CSRs are ILLEGAL (FS Off).
- time/timeh stay ILLEGAL.
- Read-only is now the architectural `csr[11:10] == 2'b11`.

DecoderSlice drops its duplicate RO-write and FP-CSR checks, leaving only the FS-Off FP instruction trap behind trap_in. That shortens the decode trap path.

Serial lane: FENCE.I raises result_trap (a writeback flush) plus result_fence_i. It retires, and the skid cycle redirects to PC + 4 with no CSR change. Decode's `recovers` includes FENCE.I, so younger instructions are not admitted before the refetch. FENCE and WFI remain no-ops: memory goes in order through one LSU, and WFI may complete immediately. The FP index mapping in Decode is removed. Static review only.

## 2026-11-24 - Reset vector at RAM base, time/timeh CSRs, system peripherals

Frontend-visible changes:
- `Parameters::RESET_VECTOR` = `RAM_BASE` = 0x200. Fetch starts at word 0x80 of the instruction memory, and program.hex now begins with `@80`.
- The SystemTrapPredecode whitelist adds time/timeh (0xC01/0xC81). DecoderSlice maps them to the new TIME_R/TIMEH_R; CSR_R is widened to 5 bits.

Backend: CoreTop/BackendTop take a `time_value` input (CLINT mtime), which the serial lane reads for time/timeh.

New system files: Core/SystemTop.sv, Core/Peripherals/CLINT.sv, RAM.sv and Crossbar.sv.
- The crossbar performs bus fault discovery: misaligned and out-of-range accesses get `response_error`.
- Both targets take one cycle, so responses stay in order.
- Interrupts reach the core as rising-edge pulses. This deviates from the spec's level MTIP when software leaves mtime >= mtimecmp.

Static review only.

## 2026-11-24 - Level-sensitive MTIP/MSIP

This fixes the spec deviation recorded in the previous entry. CoreTop/BackendTop/SerialLane take CLINT `timer_pending` and `software_pending`, which mip.MTIP/MSIP mirror directly. Software clears them at the source by writing mtimecmp or msip, and trap entry no longer clears them. A timer left at mtime >= mtimecmp re-interrupts after MRET, as the spec requires. The pulse interface now sets only mip.MEIP (type INT_EXTERNAL, sticky, cleared on entry); other pulse types are ignored. SystemTop's edge arbiter is reduced to an external rising-edge pulse. No frontend change. Static review only.

## 2026-11-24 - Instruction fetch moved to the shared system RAM

Reason: separate instruction and data memories at the same addresses broke ordinary C images, for example `.rodata` loads.

Frontend:
- FetchTop no longer instantiates InstructionMemory. Queue's memory interface (req_address = prefetch_pc_next, one-cycle response, fetch_valid low = retry the same address) is exported through FrontendTop and CoreTop as `fetch_request`, `fetch_address`, `fetch_data`, `fetch_valid` and `fetch_error`.
- The IMEM_DEPTH_WORDS/IMEM_HEX_FILE parameters are removed. program.hex loses its `@80`, so word 0 = RAM_BASE.
- Queue is unchanged. It already tolerated fetch_valid gaps by re-requesting prefetch_pc.

System:
- RAM.sv is 4 word-interleaved single-port banks with a data port and a 3-word fetch port. A bank serves the data access if the data word is in that bank, otherwise its fetch word.
- Crossbar arbitrates data first: the fetch is denied only on a bank conflict.
- Crossbar registers fetch_valid and captures data responses on their first cycle, because a later fetch can overwrite a bank output.
- Out-of-RAM fetch words read zero (ILLEGAL).

Timing, unmeasured:
- fetch_address (combinational prefetch_pc_next) now feeds the Crossbar conflict check and a per-bank address mux before the BRAM.
- fetch_data adds a bank rotate ahead of the halfword select.
- frontend.tcl and cpu.tcl add anvil_fetch_constraints (assumed fetch_data arrival 2.0 ns, address output delay 1.0 ns). Frontend runs from here on are a new comparison series, because the instruction BRAM is no longer inside FrontendTop.

Static review only.

## 2026-11-24 - First full simulation: riscv-tests, directed tests, configuration sweep

First simulation since 0acff01. The run used Verilator 5.020 on SystemTop with a scratch testbench; the shipped Parameters were unchanged, and only MAX_MEMORY_ADDRESS was raised to 0xFFFF for test images. Suites:
- rv32ui, rv32um, rv32uc, and rv32mi minus Sdtrig and PMP.
- Directed tests: timer level re-pend, msip with mie/mstatus masking, CLINT never firing before it is programmed, time vs mtime, out-of-range access faults, ecall, RO and nonexistent CSRs, misa, mstatus.MPP, an external interrupt, and 3000-iteration load/store/mul/div loops under hundreds of timer interrupts at varied offsets (no lost or duplicated stores).

Bugs found and fixed:
1. IntegerLane: at EXECUTION_UNROLL >= 2, a non-iterating MUL/DIV result capture was not stall gated, so it overwrote the older instruction held in the result stage. Capture is now `valid && (ITERATES || !stall)`.
2. SerialLane: a write to minstret/minstreth counted the writing instruction. The spec and riscv-tests require that the next read returns the written value.
3. MemoryLane: bus errors reported custom mcause 24. They now report misaligned load/store when the slot's size and offset are misaligned, otherwise load/store access fault. The trap is still discovered by the bus.
4. FENCE was a no-op, so an older `csrr time` could be ordered after a younger device load at unroll >= 3. FENCE now drains like FENCE.I (writeback flush, PC + 4); Decode's `recovers` includes SYS_FENCE.

Results after the fixes:
- Default configuration: 70/70.
- EXECUTION_UNROLL 2, 3, 4 and 20 (the divider stops iterating at 20), ISSUE_WIDTH 1, PRECISE_BUS_FAULTS 0 and BYPASS_ENABLED 0 were swept with the same suite.

Expected failures, not run in the sweep:
- rv32ui-ma_data needs hardware misaligned access.
- rv32mi-breakpoint needs Sdtrig.
- rv32mi-pmpaddr needs PMP.

No synthesis was run.


## 2026-11-25 - GShare direction predictor (parameter-gated) and PHT-index carry

Reason: replace static BTFNT direction with a trained gshare when Parameters::USE_GSHARE = 1. With USE_GSHARE = 0 the hardware is the previous design: the static Predictor per slot, no training logic, and a one-bit constant-zero PHT field that synthesis removes.

Structure:
- Fetch/BranchTarget.sv (new): direct-target immediate decode and window-wrap check, split out of Predictor unchanged. Predictor (static BTFNT) and GShare each instantiate it; GShare contains no static direction logic.
- Fetch/Top.sv: generate selects GShare (USE_GSHARE) or the per-slot static Predictors. Without GShare, branch_pht_index is tied to zero.
- GShare: index = pc[PHT_W:1] XOR the GHR folded to PHT_W bits. The fold depends only on the GHR flop, so each slot adds one XOR level and the PHT read mux to the prediction path. JAL/C.J/C.JAL predict taken; conditional branches use the PHT counter MSB. train_age widened to AGE_WIDTH.
- PHT index carry: captured with prediction_result in Queue (prediction_pht), written to the FIFO with the entry (fifo_pht), carried in the serve entry (serve_pht_reg, SERVE_ENTRY_W + PHT_INDEX_W), through Decode/DecoderSlice into DecoderPacket_.bru.pht_index.
- Training: IntegerLane emits raw train_valid/taken/pht for a valid, untrapped conditional branch (BEQ..BGEU) at the resolution stage, with BranchUnit's resolved direction. BackendTop registers them per BRU lane using the redirect fire-once rule: valid fires once even while a stall holds the branch, and a trap edge drops it. The frontend therefore sees only flops (train_valid/taken/age/pht).

Invariants:
- Every branch carries the PHT index it was predicted with. Training writes the same entry it read.
- At most one training pulse per resolved conditional branch.
- USE_GSHARE = 0 elaborates no GShare, no training flops, and constant-zero PHT fields.

Tradeoffs and known limits:
- The GHR updates at training (resolution), not speculatively at fetch, so predictions use stale history and same-window branches share one history value.
- Wrong-path branches in the same group as an older mispredict train unless TRAIN_SQUASHED_BRANCHES = 0 (oldest-only). A branch younger than a later writeback trap has already trained.
- JAL/JALR do not train or shift the GHR.

Validation: none. Not linted, simulated or synthesized. Timing impact unmeasured.

## 2026-11-25 - GHR shifts every trained branch (TRAIN_SQUASHED_BRANCHES = 1)

GShare's GHR update now depends on the parameter. With TRAIN_SQUASHED_BRANCHES = 1, every branch trained in a cycle shifts in, oldest first, so history follows program order regardless of how branches paired at resolution. With 0, the oldest-only shift is unchanged. The default is now 1.

Measured (Verilator, SystemTop, 2000 Dhrystone runs):
- Oldest-only training: 670 cycles/run.
- Train all, oldest-only GHR: 545 cycles/run.
- Train all, all-branch GHR: 535 cycles/run (1.063 DMIPS/MHz).
- Static BTFNT: 577 cycles/run.
- CoreMark (10 iterations): 2.318 -> 2.323 CoreMark/MHz.

Root cause of the earlier gshare regression: with two BRU lanes, oldest-only training dropped the younger of every same-cycle branch pair, so its PHT entry never trained.

## 2026-11-25 - Return address stack (USE_RAS, RAS_DEPTH)

Reason: returns (JALR/C.JR through x1/x5) were never predicted, so every return redirected from the BRU. USE_RAS = 0 removes all of the RAS hardware below. Constant one-bit fields remain in the FIFO, serve and packet entries; synthesis removes them.

Structure:
- Fetch/RAS.sv (new):
  - Circular stack of fetch_pc_t entries, RAS_DEPTH entries (power of two >= 2, checked at elaboration).
  - A registered top, so the prediction read is a flop.
  - A saturating count, where overflow overwrites the oldest entry.
  - Per-slot decode of JALR-class instructions and returns.
- Fetch/Top.sv: after the direction predictor (GShare or static), JALR-class slots are overridden:
  - A return predicts taken to the top when the stack is not empty, with target_wrapped = 0.
  - Any other JALR predicts not taken.
  - The cost is one 2:1 select after the predictor; the slot decode runs in parallel from the staging data.
- Queue:
  - With USE_RAS, the predecode branch flag also marks JALR, C.JR and C.JALR, so those slots reach the prediction stage.
  - The committing window (packet_commit, prediction_payload, packet_keep, packet_lane_taken) is exported for the RAS update.
  - The predicted target is carried with each entry (fifo_ras, serve_ras_reg).
- Update at Queue commit: the first RAS event among the kept slots of the committing window is applied.
  - A call (JAL/JALR with rd x1/x5, C.JAL, C.JALR) pushes PC + length.
  - A return that committed taken pops.
  - Any other JALR (unpredicted) freezes the stack until the next redirect. Such a JALR always redirects in the BRU, so everything fetched behind it is wrong path.
- Check:
  - DecoderSlice computes ras_rs1 = target - imm, off the execute path.
  - BranchUnit (CHECK_RETURN) adds `JALR && predicted_taken && rs1 != ras_rs1` to its redirect condition. This is an equality on the forwarded operand, with no adder on the redirect path.
  - IntegerLane recovers to `taken ? target : next_pc` when USE_RAS, because a predicted-taken JALR can mispredict while actually taken.

Invariants:
- Every predicted return is verified by the BRU. A wrong RAS costs a redirect, never correctness.
- No RAS update from a window fetched behind an unpredicted JALR.
- Between a window's prediction read and its commit, no other window updates the RAS. A window that changes the RAS either ends in a taken prediction, which discards the next window, or freezes the stack.

Tradeoffs and known limits:
- There is no repair on conditional mispredicts or traps. Wrong-path calls or returns behind a mispredicted branch can corrupt the stack, and that costs only predictions.
- C.JALR or JALR that both links and reads x1/x5 is treated as a call only (push, no pop).
- A return that could only be predicted from a call in the same, not yet committed, window is not predicted. This needs an unpredicted JALR call followed by a return in one window, and is rare.
- Queue.real_pc (unused) does not model taken JALR.

Validation: none. Not linted, simulated or synthesized. Timing impact unmeasured.
