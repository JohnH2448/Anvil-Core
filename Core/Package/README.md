# Configuration and package visibility

Compile packages in the order listed in `Core/Package/packages.f` (paths are
relative to the repository root): Enumerations, Parameters, DerivedParameters,
Definitions, then modules. Vivado's project source list includes these packages.

- `Parameters`: raw whole-core settings, read explicitly by top/sub-top modules.
- `DerivedParameters`: shared derived constants, computed once using qualified
  references to Parameters. It does not import or re-export the raw settings.
- `Definitions`: shared packet types, sized using DerivedParameters.
- `Enumerations`: operation and architectural enums.

Lanes import shared constants and types in the module header so they are visible
in both the port list and module body, without compilation-unit wildcard imports:

```systemverilog
module ExampleLane
    import DerivedParameters::*;
    import Definitions::*;
#(
    parameter INTEGER_LANE_COUNT = 1 // A local value selected by a sub-top
)(
    input DecoderPacket_ packet_in,
    input IssuerPacket_ issuer_packet,
    input logic [31:0] forwarded [TOTAL_LANE_COUNT-1:0]
);
endmodule
```

`TOTAL_LANE_COUNT`, `AGE_WIDTH`, `LANE_WIDTH`, and `UNROLL_WIDTH` are shared
constants, not lane parameters. A sub-top can read `Parameters::INTEGER_LANE_COUNT`
and derive a smaller local value without importing that raw name. Leaf options
such as capability flags, lane ID, and local pipeline controls remain module
parameters supplied by the sub-top.

SystemVerilog has no private package: qualified access to `Parameters::NAME`
is still possible anywhere. The separation controls namespace visibility and
ownership, not access permissions. Importing one package does not automatically
import its dependencies.

This design has one whole-core configuration per compilation. Package-sized
packet fields describe that global configuration; local stage counts must fit
its stage-index width. `UNROLL_WIDTH` encodes 0 through the global EXECUTION_UNROLL
inclusive, and each index width is at least one bit. Forwarding matrices remain
zero placeholders until the topology is implemented.

`DecoderPacket_` is the canonical packet name; `DecodedPacket_` is retained as
an alias for existing tests. IntegerOperands_ is the shared integer execution
payload used by the lane, multiplier, and divider.
