## Lane Model
Anvil-Core opts for a highly parameterizable backend, the crux of which being the concept of heterogenous "lane" instantiation at compile time. Long story short:
FP lanes only forward to other FP lanes, they dynamically search for operands. No integer forwarding goes to them nor integer outputs come from them.
Integer and memory lanes are served static tags to fetch operands from at issue time. Memory lanes broadcast ready bits, integer lanes are guarenteed ready.
Serial lanes back stall all other serial operations and run one at a time. All dependencies generally are also back stalled.

## Memory Lanes
Memory operations, in particular loads, must be handled differently than most other instructions due to their variable latency nature. Given that the pipeline design is strictly in order, an instruction dependent on load data MUST stall itself and everything younger to prevent correctness issues. There is no replay mechanism to otherwise repair an instruction if it were to continue past its operand selection stage missing its dependency data. Additionally, even in the case where a load does not have any immediate dependencies on its result, it still must stall the pipeline to maintain in-order semantics before it commits to the register file. No younger instruction may commit to the register file until the load has completed and commit entirely. Without this, unintentional WAW among other correctness issues are possible, corrupting the register file state and breaking flush recovery. Given these invariants, the memory architecture must satisfy them in a way that preserves correctness while also minimizing backend stall cycles.

The following design was arrived at, meeting the intended goals outlined above. Memory lanes consist of two blocks, the lane itself and the LSU. Memory lanes are unrolled like other lanes by EXECUTION_UNROLL, and stall globally under the same conditions other lanes do. A "lane" serves to maintain pipeline ordering, serve as a forwarding reference to other lanes and itself, pass forward results, and check into the register file. A single LSU sits above all memory lanes, to which they check desired operations into. The LSU arbitrates in the case of multiple memory lanes and maintains age ordering over its single bus. The LSU receives results from the response bus and checks them back into the corresponding memory lane slots that issued the request. Importantly, the LSU maintains a concept of pipeline motion, and thus the pipeline may step forward while memory operations are pending. The LSU maintains the index of the outgoing instruction and checks it into the lane index adjusted for pipeline motion. This serves as a sort of "pass and catch" mechanism, where the instructions "pass" to the LSU, flow forward without causing stalls while waiting, and "catch" the result at a later index, avoiding stalls in the ideal case. However, as painfully obvious in CPU architecture, the ideal case is not the only case. 

Stalls are still possible in several scenarios. Primarily, stalls will occur on load use dependencies. If a younger instruction is dependent on a load, it is still considered valid by the issuer regardless of the status of the load data. However, once in the operand selection stage of the backend, the pipeline will stall if the load data is not ready. This means the memory lane will freeze and the load instruction will maintain its lane and index. Similar to the iterating units present on integer lanes, the operand selection stage looks at a ready bit from its dependency index of the memory lane. This bit is indistinguishable from the one used by iterating units to dictate operand readiness. A useful analogy is that every stage of a memory lane is an iterating unit. The LSU continues to await a response and process instructions while the pipeline is stalled, and continues to check them into lane slots as results appear. 

The other possibility of a stall is a memory operation reaching the iteration point without a valid result. In this case, the pipeline will globally stall until the LSU checks in a result. This maintains ordering, which is a primary correctness concern.


## Integer Lanes
![IntegerLane](Docs/IntegerLane.png)

## Multiplier Design
The current implementation uses a pipelined radix-2 carry-save partial Wallace tree multiplier. Radix-2 refers to the number of operand bits corresponding to a generated partial product. A radix-4 partial product constructor would generate a partial product for every 2 bits, while radix-2 generates a partial product every 1 bit. Carry-save refers to the method by which partial products are reduced to lower carry propagation. A carry-save multiplier uses the identity ``X + Y + Z`` = ``S + C``, where S is ``X ⊕ Y ⊕ X`` and C is the carry vector. Done over every set of 3 partial products, this method reduces the product list in parallel by a factor of 1.5. This allows carry dependencies otherwise evaluated in rippling fashion to be calculated in smaller, parallel batches. A Wallace tree refers to the reptation of a reduction operation (such as carry-save) until the product is the sum of 2 remaining vectors. While similar in concept, this design does not use a full Wallace tree, rather opting for reduction until 4 vectors remain. 

The final configuration was arrived at empirically through evaluating several parameters and architecture variants. Notably, the additional routing and selection logic associated with radix-4 lost on timing compared to every tested radix-2 configuration. Additionally, the reduction to 2 vectors traditionally used by a Wallace tree lost to a 4-vector reduction. This is likely because FPGAs have quite efficient adders in comparison to general logic. The logic from the extra reduction tree nodes created sufficient routing, congestion, and LUT delay to be greater than the time saved by the reduced carry chain. The final configuration best distributed the critical path over the reduction/product generation stage and the addition stage, closing at 231.4MHz. More or less compression stages distributed critical path less evenly, thus performing worse post synthesis. 

| Radix | Compressions | Final Vectors | Fmax | Period | LUTs | FFs |
|---|---|---|---|---|---|---|
| Radix-2 | 8 | 2 | 169.5 MHz | 5.900 ns | 1,639 | 219 |
| Radix-2 | 7 | 3 | 182.0 MHz | 5.496 ns | 1,637 | 252 |
| **Radix-2** | **6** | **4** | **231.4 MHz** | **4.321 ns** | **1,552** | **285** |
| Radix-2 | 5 | 6 | 188.4 MHz | 5.308 ns | 1,549 | 348 |

To handle signedness and RISC-V specific writeback needs, 3 compensation vectors are injected into the initial partial product pool. They are compressed by the partial Wallace tree like other vectors and are not treated differently. The compensation vectors are either 0 or a bitwise inversion of the 2 initial input operands. The third vector consists of the remaining ones that need to be added to the inverted compensation vectors to form a 2's compliment result. In total, the full pool of vectors consists of 32 shift-derived partial products and 3 signedness compensation vectors. 

## Divider Design
The divider implementation, kindly one-shotted by GPT-6 Astra, uses an "auto-pipelined" radix-2^x restorative division algorithm with parallel trial subtraction. Radix, similar to the multiplier, specifies the number of operand bits corresponding to a generated division step. Restorative refers to a section of the algorithm where the new remainder (the main chaining dependency) is calculated. A restoring implementation discards a subtraction result if it is negative, retaining the previous shifted remainder, while a non-restoring implementation retains the negative result and compensates for it by adding the divisor during the next iteration instead of subtracting it. 

The design is "auto-pipelined", referring to its parameterizable pipeline distribution. A top-level parameter at compile time decides where in the overall combinational cycle to inject registers. This serves three purposes: First, it helps in development by allowing for less manual rewriting of RTL while arriving at an optimally timed result. Second, it can be used during compile time depending on the desired configuration to insert more or less stages based on how aggressive the frequency requirements are. For example, a divider in a dual-issue configuration may only need to meet 200 MHz, thus allowing for total pipeline register count and cycle latency to be reduced in comparison to, say, a 260 MHz single-issue configuration. Third, it allows for advanced users to manually adjust the pipelining requirements at compile time to accomplish individual goals, custom requirements, or hardware specific optimizations. Together, these factors make a strong case for auto-pipelining implementations of any module when possible in highly configurable designs. Stage Formula: ``STAGES = ((32 + AUTO_PIPE - 1) / AUTO_PIPE) + 2`` Radix Formula: ``RADIX = 2^AUTO_PIPE``

There is no clear winner for which configuration is optimal for Anvil-Core. This would depend on target frequency as well as division instruction frequency. The radix-4 implementation achieves a higher fmax, albeit at the cost of additional divider latency and thus pipeline stalling. The radix-8 implementation, while slower, is typically still above target frequency for Anvil-Core. Thus, the relatively slower frequency does not become part of the overall critical path. This takes frequency out of the equation of most optimal implementation, and thus only the quantity of stages and utilization needs to be considered. The default configuration uses Radix-8 on the premise that it provides strictly better IPC. However, it may be easily swapped for radix-8 on more constrained systems. 

Below are synthesis numbers for several selected configurations:

| Radix | Stages | Fmax | Period | LUTs | FFs |
|---|---|---|---|---|---|
| Radix-4 | 18 | 246.9 MHz | 4.050 ns | 1,863 | 1,477 |
| Radix-8 | 13 | 220.3 MHz | 4.540 ns | 2,826 | 2,090 |
| Radix-16 | 10 | 201.4 MHz | 4.966 ns | 4,627 | 3,526 |


## Frontend timing across parameter sets

Results use the I/O delay model below. Clock targets may vary to push frequency;
record each target in the run notes. Frequency/period columns are slack-derived
estimates, not necessarily the clock target met by that run. Delays are relative to the rising edge of frontend_clk;
minimum delays model earliest external arrival, not inserted hardware delay.

```tcl
create_clock -name frontend_clk -period 2.500 [get_ports clk]
set late_controls [get_ports {stall redirect_taken redirect_pc[*]}]
set_input_delay -clock frontend_clk -max 3.250 $late_controls
set_input_delay -clock frontend_clk -min 2.000 $late_controls
set_input_delay -clock frontend_clk -max 1.000 [get_ports {reset serial_active}]
set_input_delay -clock frontend_clk -min 1.000 [get_ports reset]
set_input_delay -clock frontend_clk -min 0.500 [get_ports serial_active]
set_output_delay -clock frontend_clk -max 0.000 [all_outputs]
set_output_delay -clock frontend_clk -min 0.000 [all_outputs]
```

| ISA | Issue Width | FIFO Words | Cache Line Words | Lanes | Frequency (MHz) | Period (ns) | LUTs | FFs |
|---|---|---|---|---|---|---|---|---|
| RV32IMAFC | 2 | 8 | 1 | 5 | 218.10 | 4.585 | 4,989 | 3,268 |
| RV32IMC | 2 | 8 | 1 | 4 | 205.80 | 4.859 | 4,524 | 2,946 |

Note: These are representative, not theoretical limits.. They could be higher with more aggressive routing passes. They are also pre-fp.
