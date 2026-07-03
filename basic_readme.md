# Basic process for adding a new deterministic quotient FPGA IP core

This is the short process checklist for starting a new hardware/software path like `spin`.

The intended split is:

- `spin/` is the pure VHDL source tree.
- `lolv/` is the LiteX/Linux integration tree.
- `dq_include` is the `lolv` branch where the deterministic quotient IP becomes visible to the SoC, Linux, bincode/API layers, and frontend API surface.
- `soce/` remains reference material and proven standalone VHDL examples.

## Working directory variables

```bash
export EXTERNAL="$HOME/1tb/ext"
export WORKROOT="$HOME/1tb/see/1-c0d3/vhdl"
export WORKDIR="$WORKROOT/lolv"
export SPINDIR="$WORKROOT/spin"

cd "$SPINDIR"
source "$EXTERNAL/fpga-env.sh"
hash -r
```

## 10-20 step process

1. Create the new pure VHDL source tree under `$WORKROOT/spin`.

2. Keep the hardware source clean:
   - VHDL files in `spin/rtl/`
   - testbenches in `spin/tb/`
   - scripts in `spin/tools/`
   - docs in `spin/docs/`
   - generated output in `spin/reports/`, `spin/sim/`, or ignored build directories

3. Create or switch the `lolv` integration branch:

```bash
cd "$WORKDIR"
git switch -c dq_include 2>/dev/null || git switch dq_include
```

4. Define the IP boundary before wiring it into LiteX:
   - clock/reset
   - CSR-visible control inputs
   - CSR-visible status outputs
   - streaming or memory-mapped data inputs
   - deterministic quotient outputs
   - error/valid/busy flags

5. Write the first VHDL entity in `spin/rtl/`.

6. Write a tiny VHDL testbench in `spin/tb/`.

7. Run local VHDL syntax/elaboration checks before touching LiteX:

```bash
cd "$SPINDIR"
./tools/check_spin_vhdl.sh
```

8. Keep the first IP version boring:
   - synchronous
   - one clock domain
   - no inferred latches
   - no vendor primitives
   - no async tricks
   - fixed-width unsigned arithmetic first

9. Once VHDL checks pass, synthesize the VHDL into Verilog using the same working path proven by `soce/vhdl/readme.md`:

```bash
source "$EXTERNAL/fpga-env.sh"
which yosys-ghdl
yosys-ghdl -p 'help ghdl' | head -40
```

10. Add a LiteX wrapper in `lolv/soc_linux.py`:
    - `CSRStorage` for inputs/control
    - `CSRStatus` for outputs/status
    - `platform.add_source(...)` for generated Verilog
    - `Instance(...)` to connect the synthesized module
    - explicit CSR bank assignment so `ctrl` stays at `0xf0000000`

11. Never move LiteX `ctrl` away from CSR bank 0. If `ctrl` moves, Linux can panic during `litex_soc_ctrl_probe`.

12. Build the modified OrangeCrab bitstream from `lolv`:

```bash
cd "$WORKDIR"
source "$EXTERNAL/fpga-env.sh"
hash -r

./make.py \
  --board=orange_crab \
  --device=85F \
  --revision=0.2 \
  --cpu-count=1 \
  --rootfs=mmcblk0p2 \
  --build \
  -- \
  --sdram-device=MT41K256M16
```

13. Verify the CSR map before flashing:

```bash
cd "$WORKDIR"

grep -nE 'ctrl|dq|quotient|spin' build/orange_crab/csr.csv || true

python - <<'CHECKCSR'
import json
from pathlib import Path

j = json.loads(Path("build/orange_crab/csr.json").read_text())
print("ctrl base:", hex(j["csr_bases"]["ctrl"]))
for k, v in sorted(j["csr_bases"].items()):
    if "dq" in k or "quotient" in k or "spin" in k:
        print(k, hex(v))
CHECKCSR
```

14. Verify generated gateware contains the new module and CSR wiring:

```bash
cd "$WORKDIR"

grep -nEi 'dq|quotient|spin' \
  build/orange_crab/gateware/orange_crab.v \
  build/orange_crab/gateware/orange_crab.lpf \
  | head -200 || true
```

15. Regenerate `orange_crab.bit.dfu` from the fresh `.bit` before flashing. Do not flash a stale `.bit.dfu`.

```bash
cd "$WORKDIR"
source "$EXTERNAL/fpga-env.sh"
hash -r

cp -v build/orange_crab/gateware/orange_crab.bit \
      build/orange_crab/gateware/orange_crab.bit.dfu

dfu-suffix -v 1209 -p 5af0 -a build/orange_crab/gateware/orange_crab.bit.dfu
```

16. Copy any regenerated DTB to the SD boot partition when the hardware map changes.

17. Flash the bitstream to OrangeCrab DFU alt `0` only:

```bash
cd "$WORKDIR"
source "$EXTERNAL/fpga-env.sh"
hash -r

sudo dfu-util -a 0 -D build/orange_crab/gateware/orange_crab.bit.dfu
```

18. Boot Linux and validate stock LiteX CSRs first:
    - `ctrl` scratch register
    - `leds`
    - `bus_errors`

19. Validate the new deterministic quotient CSRs with `devmem` before writing a Linux driver or frontend API wrapper.

20. Only after raw CSR proof works, add the higher layers:
    - Linux kernel driver or UIO/devmem bridge
    - bincode protocol shape
    - OS/service wrapper
    - C/Rust API
    - frontend API surface
    - tests that prove deterministic input/output vectors end-to-end

## Current target

The `spin` project starts as a pure VHDL deterministic quotient IP core.

The `dq_include` branch in `lolv` is where that IP becomes part of the Linux-on-LiteX system instead of only being a C/Rust wrapper outside the real hardware/software boundary.
