# Usage
```
vivado -mode batch -nolog -nojournal -source Synthesis/Scripts/backend.tcl  [-tclargs [part] [period]]
vivado -mode batch -nolog -nojournal -source Synthesis/Scripts/frontend.tcl [-tclargs [part]]
vivado -mode batch -nolog -nojournal -source Synthesis/Scripts/cpu.tcl      [-tclargs [part]]
vivado -mode batch -nolog -nojournal -source Synthesis/Scripts/worst_path.tcl [-tclargs backend|frontend|cpu|<dcp>]
```