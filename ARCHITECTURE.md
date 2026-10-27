## Multiplier Design
The current implementation uses a pipelined radix-2 carry-save partial Wallace tree multiplier. Radix-2 refers to the number of operand bits corresponding to a generated partial product. A radix-4 partial product generator would generate a partial product for every two bits, while radix-2 generates a partial product every one bit. Carry-save refers to the method by which partial products are reduced to lower carry propagation. A carry-save multiplier uses the identity ``X + Y + Z`` = ``S + C``, where S is ``X ^ Y ^ X`` and C is the carry vector. Done over every set of three partial products, this method reduces the product list in parallel by a factor of 1.5. This allows carry dependencies otherwise evaluated in rippling fashion to be calculated in smaller, parallel batches. A Wallace tree refers to the reptation of a reduction operation (such as carry-save) until the product is the sum of two remaining vectors. While similar in concept, this design does not use a full Wallace tree, rather opting for reduction until 5 partial products remain. 

The final configuration was arrived at through synthesis of several parameters and architecture variants. Notably, the additional routing and selection logic associated with radix-4 lost on timing compared to every tested radix-2 configuration. Additionally, the reduction to two vectors traditionally used by a Wallace tree lost to a five-vector reduction. This is likely because FPGAs have quite efficient adders in comparison to general logic. The logic from the extra reduction tree nodes created sufficient routing, congestion, and LUT delay to be greater than the time saved by the reduced carry chain. The final configuration best distributed the critical path over the reduction/product generation stage and the addition stage, closing at 242.8MHz. More or less stages distributed critical path less evenly, thus performing worse post synthesis. 

| Partial products | Compression Passes | Fmax | Period | LUTs | FFs |
|---|---:|---:|---:|---:|---:|
| Radix-2 | 2 | 174.9 MHz | 5.719 ns | 1,760 | 246 |
| Radix-2 | 4 | 228.5 MHz | 4.376 ns | 1,374 | 401 |
| **Radix-2** | **5** | **242.8 MHz** | **4.118 ns** | **1,383** | **343** |
| Radix-2 | 6 | 233.8 MHz | 4.277 ns | 1,424 | 311 |
| Radix-4 | 5 | 150.2 MHz | 6.659 ns | 1,530 | 285 |
