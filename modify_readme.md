<!-- LOLV_SPI_MILESTONE_START -->
## Proven external SPI milestone

`soc_linux.py` now includes `SpiSlaveExt`:

```text
Jetson /dev/spidev0.0
-> SPI mode 0
-> OrangeCrab ECP5 pins
-> LiteX SPISlave
-> stable Linux mailbox
-> raw edge counters
-> Linux devmem / future Rust MMIO
```

Correct pins:

```text
CS0  -> GPIO:0  / N17
SCK  -> GPIO:16 / N16
MOSI -> GPIO:15 / R17
MISO <- GPIO:14 / N15
```

The original fault was a physical SCK/MOSI crossover. After correction, `ff aa 55 81` produced:

```text
rx_data                        0xFFAA5581
rx_length                      0x00000020
raw_sck_rise_count             0x00000020
raw_sck_fall_count             0x00000020
raw_mosi_high_on_sck_rise      0x00000012
raw_mosi_low_on_sck_rise       0x0000000E
```

MISO full-duplex transfer also passed. See `spi_readme.md`.
<!-- LOLV_SPI_MILESTONE_END -->


# Modify Notes: Custom VHDL IP wired to LiteX/Linux CSRs

This continues after `install_readme.md`.

`install_readme.md` gets the OrangeCrab 85F rev 0.2 to the proven base point:

- LiteX / VexRiscv-SMP bitstream builds.
- Buildroot Linux boots from SD.
- Linux reaches the Buildroot login prompt.
- `ctrl`, `uart`, `timer0`, `i2c0`, `leds`, and `sdcard` CSRs work.
- `/dev/gpiochip0`, `/dev/i2c-0`, and `/dev/ttyLXU0` exist.

This file records the next milestone:

> Add custom VHDL into the LiteX gateware, expose control/status registers to Linux through the LiteX CSR bus, connect the VHDL block to OrangeCrab header GPIO pads, flash the matching FPGA image, and verify the custom VHDL from Linux with `devmem`.

Final proven map:

```
ctrl base         = 0xf0000000
i2c0 base         = 0xf0002000
leds base         = 0xf0003000
sdcard base       = 0xf0003800
header_probe base = 0xf0004800

header_probe_enable  = 0xf0004800
header_probe_oe      = 0xf0004804
header_probe_out     = 0xf0004808
header_probe_pins_in = 0xf000480c
```

Final Linux proof:

```
devmem 0xf0004800 32 1
devmem 0xf0004804 32 0x00000fff
devmem 0xf0004808 32 0x000005a5

devmem 0xf0004800 32
0x00000001

devmem 0xf0004804 32
0x00000FFF

devmem 0xf0004808 32
0x000005A5

devmem 0xf000480c 32
0x000005A5

devmem 0xf0000008 32
0x00000000
```

A physical GPIO LED connected to a header pin also turned on.

---

## 1. Start from the repo root
export PYENVLOC=$HOME/ext"
export WORKROOT="$HOME/vhdl"
export WORKDIR="$WORKROOT/lolv"
cd "$WORKDIR"
source $PYENVLOC/fpga-env.sh
hash -r

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

git switch -c see/001_try_gateware 2>/dev/null || git switch see/001_try_gateware
git status
```

---

## 2. Critical artifact rule

The generated hardware, DTB, CSR map, raw bitstream, and DFU bitstream must all match.

Important files:

```
build/orange_crab/gateware/orange_crab.v
build/orange_crab/gateware/orange_crab.lpf
build/orange_crab/gateware/orange_crab.bit
build/orange_crab/gateware/orange_crab.bit.dfu
build/orange_crab/csr.csv
build/orange_crab/csr.json
build/orange_crab/orange_crab.dts
build/orange_crab/orange_crab.dtb
```

The major false failure was a stale `.bit.dfu`:

```
orange_crab.bit.dfu  old timestamp
orange_crab.bit      new timestamp
orange_crab.v        new timestamp
csr.csv              new timestamp
orange_crab.dtb      new timestamp
```

Symptoms of stale `.bit.dfu`:

```
Linux boots.
ctrl scratch works.
leds works.
header_probe CSRs read back zero.
bus_errors stays zero.
```

Fix: regenerate `.bit.dfu` from the new `.bit` before flashing.

---

## 3. Add the VHDL IP

Create `gateware/header_probe.vhd`.

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

mkdir -p gateware tools

cat > gateware/header_probe.vhd <<'VHDL'
library ieee;
use ieee.std_logic_1164.all;

entity header_probe is
  port (
    clk       : in    std_logic;
    rst       : in    std_logic;

    enable    : in    std_logic;
    oe        : in    std_logic_vector(11 downto 0);
    out_value : in    std_logic_vector(11 downto 0);
    in_value  : out   std_logic_vector(11 downto 0);

    gpio      : inout std_logic_vector(11 downto 0)
  );
end entity header_probe;

architecture rtl of header_probe is
begin
  gen_gpio : for i in 0 to 11 generate
  begin
    gpio(i) <= out_value(i) when enable = '1' and oe(i) = '1' else 'Z';
    in_value(i) <= gpio(i);
  end generate;
end architecture rtl;
VHDL
```

---

## 4. Synthesize VHDL to Verilog

Use `yosys-ghdl`, not the system `ghdl --synth --out=verilog`.

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

mkdir -p tools gateware

cat > tools/synth_header_probe_vhdl.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p gateware

if ! command -v yosys-ghdl >/dev/null 2>&1; then
  echo "ERROR: yosys-ghdl wrapper not found in PATH." >&2
  echo "Run:" >&2
  echo "  source $EXTERNAL/fpga-env.sh" >&2
  echo "  hash -r" >&2
  echo "  which yosys-ghdl" >&2
  exit 1
fi

echo "using yosys-ghdl: $(command -v yosys-ghdl)"
yosys-ghdl -p 'help ghdl' >/tmp/header_probe_yosys_ghdl_help.log

echo "synthesizing gateware/header_probe.vhd -> gateware/header_probe.v"
yosys-ghdl -p '
  ghdl --std=08 gateware/header_probe.vhd -e header_probe
  write_verilog -noattr gateware/header_probe.v
'

echo
echo "generated gateware/header_probe.v:"
grep -nE 'module header_probe|inout|out_value|in_value|gpio|assign' gateware/header_probe.v | head -120
SH

chmod +x tools/synth_header_probe_vhdl.sh
```

Run it:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

which yosys-ghdl
yosys-ghdl -p 'help ghdl' | head -40

./tools/synth_header_probe_vhdl.sh
```

Expected generated Verilog shape:

```
module header_probe(clk, rst, enable, oe, out_value, in_value, gpio);
  input clk;
  input rst;
  input enable;
  input [11:0] oe;
  input [11:0] out_value;
  output [11:0] in_value;
  inout [11:0] gpio;

  assign gpio = ...
  assign in_value = gpio;
endmodule
```

---

## 5. Patch `soc_linux.py` to wrap the VHDL IP in LiteX CSRs

This wrapper is the bridge:

```
Linux devmem
  -> LiteX CSR bus
  -> CSRStorage / CSRStatus
  -> HeaderProbe wrapper
  -> synthesized VHDL module
  -> OrangeCrab header pads
```

The final working address allocation keeps the normal LiteX control block at bank 0 and forces `header_probe` to CSR bank 9:

```
ctrl         -> 0xf0000000
header_probe -> 0xf0004800
```

Run this idempotent patch script.

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

python - <<'PY'
from pathlib import Path

p = Path("soc_linux.py")
s = p.read_text()

class_block = r'''
# Header Probe VHDL CSR wrapper --------------------------------------------------------------------

class HeaderProbe(Module, AutoCSR):
    def __init__(self, platform, pads):
        self.enable  = CSRStorage(1,  reset=0,     description="Enable header probe output drivers.")
        self.oe      = CSRStorage(12, reset=0x000, description="Output-enable mask for header probe pins.")
        self.out     = CSRStorage(12, reset=0x000, description="Output value mask for header probe pins.")
        self.pins_in = CSRStatus(12,              description="Live sampled value of header probe pins.")

        pins_in = Signal(12)

        platform.add_source("gateware/header_probe.v")

        self.specials += Instance("header_probe",
            i_clk       = ClockSignal("sys"),
            i_rst       = ResetSignal("sys"),

            i_enable    = self.enable.storage,
            i_oe        = self.oe.storage,
            i_out_value = self.out.storage,
            o_in_value  = pins_in,

            io_gpio     = pads,
        )

        self.comb += self.pins_in.status.eq(pins_in)

'''

if "class HeaderProbe(Module, AutoCSR):" not in s:
    marker = "# SoCLinux -----------------------------------------------------------------------------------------"
    if marker not in s:
        raise SystemExit("could not find SoCLinux marker")
    s = s.replace(marker, class_block + "\n" + marker)
    print("inserted HeaderProbe class")
else:
    print("HeaderProbe class already present")

insert = r'''
            # Header Probe -------------------------------------------------------------------------
            #
            # Real CSR-backed VHDL IP block for probing the OrangeCrab 0.1 inch GPIO holes from Linux.
            #
            # Keep LiteX ctrl at CSR bank 0. Put header_probe at CSR bank 9:
            #   0xf0000000 + 9 * 0x800 = 0xf0004800
            #
            # Bit mapping:
            #   bit 0  -> GPIO:1
            #   bit 1  -> GPIO:5
            #   bit 2  -> GPIO:6
            #   bit 3  -> GPIO:9
            #   bit 4  -> GPIO:10
            #   bit 5  -> GPIO:11
            #   bit 6  -> GPIO:12
            #   bit 7  -> GPIO:13
            #   bit 8  -> GPIO:18
            #   bit 9  -> GPIO:19
            #   bit 10 -> GPIO:20
            #   bit 11 -> GPIO:21
            #
            # GPIO:2/GPIO:3 are left alone because this SoC already has i2c0.
            self.platform.add_extension([
                ("header_probe_pads", 0,
                    Pins("GPIO:1 GPIO:5 GPIO:6 GPIO:9 GPIO:10 GPIO:11 GPIO:12 GPIO:13 GPIO:18 GPIO:19 GPIO:20 GPIO:21"),
                    IOStandard("LVCMOS33"),
                    Misc("PULLMODE=DOWN")
                )
            ])
            self.submodules.header_probe = HeaderProbe(
                platform = self.platform,
                pads     = self.platform.request("header_probe_pads", 0),
            )
            self.csr.add("header_probe", n=9)
'''

if "self.submodules.header_probe = HeaderProbe" not in s:
    anchor = '            soc_cls.__init__(self, cpu_type="vexriscv_smp", cpu_variant="linux", **kwargs)\n'
    if anchor not in s:
        raise SystemExit("could not find soc_cls.__init__ anchor")
    s = s.replace(anchor, anchor + insert)
    print("inserted HeaderProbe instance")
else:
    s = s.replace('self.csr.add("header_probe")', 'self.csr.add("header_probe", n=9)')
    print("HeaderProbe instance already present; ensured n=9")

p.write_text(s)
print("patched", p)
PY
```

Verify:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

grep -nE 'class HeaderProbe|self.submodules.header_probe|header_probe_pads|self.csr.add\("header_probe"|platform.add_source\("gateware/header_probe.v"\)' soc_linux.py

ls -lh gateware/header_probe.vhd gateware/header_probe.v tools/synth_header_probe_vhdl.sh
```

---

## 6. Build the modified gateware

Run the VHDL synthesis step first, then the normal LiteX build.

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

./tools/synth_header_probe_vhdl.sh

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

Expected ending:

```
Info: Program finished normally.
Buildroot defconfig: build/orange_crab/buildroot_defconfig
Buildroot base defconfig: litex_vexriscv_defconfig
```

---

## 7. Verify generated CSR map before flashing

Run:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

echo "=== CSR sanity ==="
grep -nE 'header_probe|ctrl|uart|timer0|i2c0|leds|sdcard' \
  build/orange_crab/csr.csv \
  | head -140

echo
echo "=== header_probe exact addresses ==="
python - <<'PY'
import json
from pathlib import Path

j = json.loads(Path("build/orange_crab/csr.json").read_text())

for name in ["ctrl", "header_probe", "i2c0", "leds", "sdcard"]:
    print(f'{name} base = {hex(j["csr_bases"][name])}')

print()
for name in [
    "header_probe_enable",
    "header_probe_oe",
    "header_probe_out",
    "header_probe_pins_in",
]:
    r = j["csr_registers"][name]
    print(f'{name} = {hex(r["addr"])} {r["type"]}')
PY

echo
echo "=== DTS sanity ==="
grep -nEi 'soc-controller|soc_controller|gpio@|i2c@|mmc@|f0000000|f0002000|f0003000|f0003800|f0004800' \
  build/orange_crab/orange_crab.dts \
  | head -140
```

Expected CSR map:

```
csr_base,ctrl,0xf0000000
csr_base,i2c0,0xf0002000
csr_base,leds,0xf0003000
csr_base,sdcard,0xf0003800
csr_base,header_probe,0xf0004800

csr_register,header_probe_enable,0xf0004800,1,rw
csr_register,header_probe_oe,0xf0004804,1,rw
csr_register,header_probe_out,0xf0004808,1,rw
csr_register,header_probe_pins_in,0xf000480c,1,ro
```

Expected DTS map:

```
soc_controller@f0000000
mmc@f0003800
gpio@f0003000
i2c@f0002000
```

There is no required Linux DT node for `header_probe` in this stage. It is accessed directly through raw CSR addresses with `devmem`.

---

## 8. Verify generated Verilog and LPF constraints

Run:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

echo "=== generated Verilog header_probe references ==="
grep -nE 'header_probe|csrbank2|csr_bankarray_csrbank2|enable_storage|oe_storage|out_storage|pins_in_status|out_value|in_value' \
  build/orange_crab/gateware/orange_crab.v \
  | head -500

echo
echo "=== header_probe top-level ports / LPF constraints ==="
grep -nE 'header_probe_pads0|LOCATE COMP "header_probe|IOBUF PORT "header_probe' \
  build/orange_crab/gateware/orange_crab.v \
  build/orange_crab/gateware/orange_crab.lpf \
  | head -200
```

Working pin mapping:

```
bit 0  -> GPIO:1  -> site M18
bit 1  -> GPIO:5  -> site B10
bit 2  -> GPIO:6  -> site B9
bit 3  -> GPIO:9  -> site C8
bit 4  -> GPIO:10 -> site B8
bit 5  -> GPIO:11 -> site A8
bit 6  -> GPIO:12 -> site H2
bit 7  -> GPIO:13 -> site J2
bit 8  -> GPIO:18 -> site L4
bit 9  -> GPIO:19 -> site N3
bit 10 -> GPIO:20 -> site N4
bit 11 -> GPIO:21 -> site H4
```

---

## 9. Copy the regenerated DTB to the SD boot partition

Adjust `SD` as needed. In this session the SD reader was `/dev/sdc`.

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

export SD=/dev/sdc

sudo umount /media/seejn/LITEXBOOT 2>/dev/null || true
sudo umount /media/seejn/rootfs 2>/dev/null || true
sudo umount /tmp/litexboot 2>/dev/null || true

sudo mkdir -p /tmp/litexboot
sudo mount ${SD}1 /tmp/litexboot

sudo cp -v build/orange_crab/orange_crab.dtb /tmp/litexboot/rv32.dtb

sync
sudo umount /tmp/litexboot
sync
```

---

## 10. Critical: regenerate `orange_crab.bit.dfu` from the new `.bit`

Check timestamps before flashing:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

find build/orange_crab/gateware -maxdepth 1 -type f \
  \( -name '*.bit' -o -name '*.dfu' -o -name '*.config' -o -name '*.json' -o -name '*.svf' -o -name '*.v' -o -name '*.lpf' -o -name '*.log' \) \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %9s %p\n' \
  | sort
```

If `.bit.dfu` is older than `.bit`, regenerate:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

echo "=== check dfu-suffix exists ==="
which dfu-suffix
dfu-suffix --help | head -40 || true

echo
echo "=== backup stale dfu if present ==="
if [ -f build/orange_crab/gateware/orange_crab.bit.dfu ]; then
  cp -v build/orange_crab/gateware/orange_crab.bit.dfu \
        build/orange_crab/gateware/orange_crab.bit.dfu.stale_$(date +%Y%m%d_%H%M%S)
fi

echo
echo "=== create fresh DFU wrapper from new .bit ==="
cp -v build/orange_crab/gateware/orange_crab.bit \
      build/orange_crab/gateware/orange_crab.bit.dfu

dfu-suffix -v 1209 -p 5af0 -a build/orange_crab/gateware/orange_crab.bit.dfu

echo
echo "=== verify timestamps / sizes ==="
ls -lh --time-style=long-iso \
  build/orange_crab/gateware/orange_crab.bit \
  build/orange_crab/gateware/orange_crab.bit.dfu \
  build/orange_crab/gateware/orange_crab.v \
  build/orange_crab/csr.csv \
  build/orange_crab/orange_crab.dtb
```

Working fresh DFU wrapper shape:

```
orange_crab.bit      627K 2026-06-24 04:01
orange_crab.bit.dfu  627K 2026-06-24 04:45
```

Do not flash a stale `.bit.dfu`.

---

## 11. Flash the fresh DFU bitstream

Put the OrangeCrab in DFU mode.

Flash alt `0`:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

sudo dfu-util -a 0 -D build/orange_crab/gateware/orange_crab.bit.dfu
```

Successful flash shape:

```
Opening DFU capable USB device...
ID 1209:5af0
Setting Alternate Setting #0 ...
Copying data from PC to DFU device
Download [=========================] 100%
Download done.
state(7) = dfuMANIFEST, status(0) = No error condition is present
dfu-util: unable to read DFU status after completion
```

The final `unable to read DFU status after completion` can happen when the board disconnects/re-enumerates and is not necessarily a failure.

---

## 12. Boot Linux

Open the LiteX console:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh
hash -r

ls -lah /dev/ttyACM* /dev/ttyUSB* 2>/dev/null || true

sudo env "PATH=$PATH" litex_term /dev/ttyACM0
```

Expected flow:

```
BIOS CRC passed
Memtest OK
Booting from SDCard in SD-Mode...
Copying Image to 0x40000000
Copying rv32.dtb to 0x40ef0000
Copying opensbi.bin to 0x40f00000
OpenSBI v1.3
Linux version 6.9.0
Welcome to Buildroot
buildroot login:
```

Login:

```
root
```

---

## 13. Verify booted DTB and normal CSR devices

Inside OrangeCrab Linux:

```
echo "=== booted FDT strings ==="
strings /sys/firmware/fdt 2>/dev/null | grep -Ei 'soc_controller|soc-controller|gpio@|i2c@|mmc@|f0000000|f0002000|f0003000|f0003800|f0004800' || true

echo
echo "=== iomem ==="
cat /proc/iomem | grep -Ei 'f0000000|f0001000|f0001800|f0002000|f0003000|f0003800|f0004800|gpio|i2c|mmc|serial|timer|soc' || true
```

Expected shape:

```
soc_controller@f0000000
litex,soc-controller
mmc@f0003800
gpio@f0003000
i2c@f0002000

f0000000-f000000b : f0000000.soc_controller soc_controller@f0000000
f0001000-f00010ff : f0001000.serial serial@f0001000
f0002000-f0002004 : f0002000.i2c i2c@f0002000
f0003000-f0003003 : f0003000.gpio gpio@f0003000
f0003800-f000381b : f0003800.mmc phy
f000381c-f0003847 : f0003800.mmc core
f0003848-f0003863 : f0003800.mmc reader
f0003864-f000387f : f0003800.mmc writer
f0003880-f000397f : f0003800.mmc irq
```

It is okay that `header_probe` does not appear in `/proc/iomem`; there is no Linux driver/DT node for it yet.

---

## 14. Verify `ctrl`, stock `leds`, and custom `header_probe`

Inside OrangeCrab Linux:

```
CTRL_SCRATCH=0xf0000004
LEDS=0xf0003000
HEADER_ENABLE=0xf0004800
HEADER_OE=0xf0004804
HEADER_OUT=0xf0004808
HEADER_IN=0xf000480c
BUS_ERRORS=0xf0000008

echo "=== ctrl sanity ==="
devmem $CTRL_SCRATCH 32 0xa5a55a5a
devmem $CTRL_SCRATCH 32

echo
echo "=== leds sanity ==="
devmem $LEDS 32 1
devmem $LEDS 32
devmem $LEDS 32 0
devmem $LEDS 32

echo
echo "=== header_probe sanity ==="
devmem $HEADER_ENABLE 32 1
devmem $HEADER_OE 32 0x00000fff
devmem $HEADER_OUT 32 0x000005a5

devmem $HEADER_ENABLE 32
devmem $HEADER_OE 32
devmem $HEADER_OUT 32
devmem $HEADER_IN 32

echo
echo "=== bus errors ==="
devmem $BUS_ERRORS 32
```

Expected:

```
0xA5A55A5A
0x00000001
0x00000000
0x00000001
0x00000FFF
0x000005A5
0x000005A5
0x00000000
```

If `HEADER_IN` follows `HEADER_OUT` while `enable=1` and `oe=0xfff`, the VHDL IP is driving the header pads and sampling them back.

---

## 15. Walking GPIO pattern

Inside OrangeCrab Linux:

```
HEADER_ENABLE=0xf0004800
HEADER_OE=0xf0004804
HEADER_OUT=0xf0004808

devmem $HEADER_ENABLE 32 1
devmem $HEADER_OE 32 0x00000fff

while true; do
  for v in 0x001 0x002 0x004 0x008 0x010 0x020 0x040 0x080 0x100 0x200 0x400 0x800; do
    echo "HEADER_OUT=$v"
    devmem $HEADER_OUT 32 $v
    sleep 0.25
  done
done
```

Stop with `Ctrl+C`.

Release the pins:

```
HEADER_ENABLE=0xf0004800
HEADER_OE=0xf0004804
HEADER_OUT=0xf0004808

devmem $HEADER_OUT 32 0x00000000
devmem $HEADER_OE 32 0x00000000
devmem $HEADER_ENABLE 32 0
```

---

## 16. Troubleshooting notes

### DTB-only GPIO node is fake hardware

A manual DTB node can make Linux expose a `gpiochip`, but it does not create FPGA hardware.

`csr.csv` and the generated gateware are the truth. If the peripheral is not in both, the DTB node is fake.

### Do not move `ctrl` away from bank 0

When `header_probe` was accidentally allocated at `0xf0000000`, `ctrl` moved to `0xf0000800`.

Linux then panicked:

```
Kernel panic - not syncing: Scratch register read error - the system is probably broken!
Expected: 0x12345678 but got: 0x0
litex_soc_ctrl_probe
```

Fix:

```
Keep ctrl at 0xf0000000.
Put header_probe somewhere else.
The working location was CSR bank 9: 0xf0004800.
```

### Stale `.bit.dfu` causes false custom-CSR failures

Bad timestamp shape:

```
orange_crab.bit.dfu  old
orange_crab.bit      new
orange_crab.v        new
csr.csv              new
orange_crab.dtb      new
```

Symptoms:

```
Linux boots.
ctrl scratch works.
leds works.
header_probe reads all zero.
bus_errors stays zero.
```

Fix:

```
cp -v build/orange_crab/gateware/orange_crab.bit \
      build/orange_crab/gateware/orange_crab.bit.dfu

dfu-suffix -v 1209 -p 5af0 -a build/orange_crab/gateware/orange_crab.bit.dfu
```

Then flash the regenerated `.bit.dfu`.

### `bus_errors == 0` is not enough

The real proof is:

```
write header_probe CSR
read same CSR back
value sticks
pins_in follows out when oe/enabled
bus_errors remains 0
```

### Linux did not own the header GPIOs

The booted DTB only listed:

```
soc_controller@f0000000
mmc@f0003800
gpio@f0003000
i2c@f0002000
```

There was no Linux driver bound to `header_probe`. The custom VHDL block was accessed directly with raw CSR addresses.

---

## 17. Current milestone achieved

This milestone proves:

```
VHDL source
  -> yosys-ghdl synthesis
  -> Verilog module added to LiteX gateware
  -> LiteX CSRStorage/CSRStatus wrapper
  -> ECP5 physical header pads
  -> Linux raw devmem access
  -> successful register readback
  -> successful pin-drive/sample loopback
```

This is the minimal working bridge needed before replacing `header_probe` with a real custom VHDL I2C/peripheral core.
