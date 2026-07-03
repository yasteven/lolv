================================================================
LOLV README / DOCS
ROOT: /home/seejn/1tb/see/1-c0d3/vhdl/lolv
GENERATED: 2026-07-03T00:51:46-07:00
================================================================


################################################################
# FILE: ./basic_readme.md
################################################################

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


################################################################
# FILE: ./HOWTO.md
################################################################

## Regenerate all the default configurations

Install Java and SBT, then run :

```sh
./generate.py
```


## HOWTO:
This document describes how to configure and use the peripherals of your board from Linux.

**SMP performance notes**:

For multi-core VexRiscv-SMP systems on slower FPGA/memory configurations, keep Linux's tick rate low (`CONFIG_HZ_100=y`, enabled in the default config). A higher tick rate can create a significant interrupt load since each core receives periodic timer interrupts.

When reducing CPU resources to fit a device, avoid going below 4 I/D TLB entries when possible, and keep I/D caches large enough for Linux workloads. More cores are not necessarily faster if the memory path or interconnect is the bottleneck.

**Configure/Use the Leds**:

Find the LiteX GPIO chip matching the LEDs in the generated DTS/DTB:
````
$ for chip in /sys/class/gpio/gpiochip*; do echo "$(basename $chip): label=$(cat $chip/label) base=$(cat $chip/base) ngpio=$(cat $chip/ngpio)"; done
````
Use the `base` value from the LED gpiochip as `BASE`; use `BASE + n` for LED `n`.
Export the first LED GPIO and configure it as an output:
````
$ LED_GPIO=BASE
$ echo $LED_GPIO > /sys/class/gpio/export
$ echo out > /sys/class/gpio/gpio${LED_GPIO}/direction
````
Set the LED value:
````
$ echo 0 > /sys/class/gpio/gpio${LED_GPIO}/value
$ echo 1 > /sys/class/gpio/gpio${LED_GPIO}/value
````

**Configure/Use the PWM RGB Led**:

````
$ cd /sys/class/pwm/pwmchip0
$ echo 0 > export
$ cd pwm0
$ echo 100 > period
$ echo 50 > duty_cycle
$ echo 1 > enable
````

This should configure the LED with 50% PWM that you can adjust by changing the `duty_cycle` value from `0` to the configured `period`.

**Configure/Use Ethernet**:

1. Manual address:

Verify that the `eth0` ethernet device is present:
`$ ifconfig -a`:
````
eth0      Link encap:Ethernet  HWaddr C6:6A:FB:04:6A:B9
          BROADCAST MULTICAST  MTU:1500  Metric:1
          RX packets:0 errors:0 dropped:0 overruns:0 frame:0
          TX packets:0 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:0 (0.0 B)  TX bytes:0 (0.0 B)

lo        Link encap:Local Loopback
          inet addr:127.0.0.1  Mask:255.0.0.0
          inet6 addr: ::1/128 Scope:Host
          UP LOOPBACK RUNNING  MTU:65536  Metric:1
          RX packets:0 errors:0 dropped:0 overruns:0 frame:0
          TX packets:0 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:0 (0.0 B)  TX bytes:0 (0.0 B)

sit0      Link encap:IPv6-in-IPv4
          NOARP  MTU:1480  Metric:1
          RX packets:0 errors:0 dropped:0 overruns:0 frame:0
          TX packets:0 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:0 (0.0 B)  TX bytes:0 (0.0 B)
````
Configure it:
`$ ifconfig eth0 192.168.1.50`

Verify that you can ping another machine on your network:
`$ ping 192.168.1.100`:
````
PING 192.168.1.100 (192.168.1.100): 56 data bytes
64 bytes from 192.168.1.100: seq=0 ttl=64 time=19.839 ms
64 bytes from 192.168.1.100: seq=1 ttl=64 time=4.585 ms
64 bytes from 192.168.1.100: seq=2 ttl=64 time=8.510 ms
64 bytes from 192.168.1.100: seq=3 ttl=64 time=12.522 ms
^C
--- 192.168.1.100 ping statistics ---
4 packets transmitted, 4 packets received, 0% packet loss
round-trip min/avg/max = 4.585/11.364/19.839 ms
````

2. Automatic address through DHCP:

`$ udhcpc -i eth0`

**Configure/Use Ethernet over USB (PPP over USB ACM, OrangeCrab):**

This uses the OrangeCrab USB serial link as a point-to-point network tunnel.

1. Check that PPP support is enabled in the kernel:
```
$ zcat /proc/config.gz | grep -E 'CONFIG_PPP=|CONFIG_PPP_ASYNC='
```

2. On the SoC (Linux target), start PPP on the LiteX UART TTY (for example `/dev/ttyLXU0`):
```
$ pppd /dev/ttyLXU0 115200 local noauth nodetach 192.168.100.2:192.168.100.1
```

3. On the host PC, use the USB ACM port exposed by the board (for example `/dev/ttyACM0`):
```
$ sudo pppd /dev/ttyACM0 115200 local noauth nodetach 192.168.100.1:192.168.100.2
```

4. Verify `ppp0` exists on both sides and test connectivity:
```
$ ifconfig ppp0
$ ping 192.168.100.1   # from SoC
$ ping 192.168.100.2   # from host
```

Notes:
- Replace `115200` with your selected UART baudrate if different.
- On the SoC, the serial device is usually `ttyLXU0` (not `ttyACM0`).
- If PPP is built as modules instead of built-in, load:
```
$ modprobe ppp_generic
$ modprobe ppp_async
```

**Configure/Use the SPI Flash:**

There should be a `/dev/mtd0` that you can read from/write to directly from bash, i.e.,:
```
$ cat /dev/mtd0
```
Or even better, to see the data clearly:

```
$ dd if=/dev/mtd0 count=6 bs=1 status=none | hexdump
```

Before writing you should erase the flash first. This requires `BR2_PACKAGE_MTD` and `BR2_PACKAGE_MTD_JFFS_UTILS` to be enabled in the buildroot config.

```
$ flash_erase /dev/mtd0 0 1
$ echo -ne "\x01\x01" > /dev/mtd0
```

**Configure/Use the SDCard:**

Plug the SDCard, it should be detected with all partitions on it:

`$ ls /dev/mmcblk*`:
````
/dev/mmcblk0    /dev/mmcblk0p1
````

Mount the partition to the directory you want to access it (here /sdcard for example):
```
$ mkdir /sdcard
$ mount /dev/mmcblk0p1 /sdcard/
```

Check that you can read and write on it:
```
$ echo "Hi SDCard" > /sdcard/test
$ cat /sdcard/test
Hi SDCard
```


**Use the Framebuffer**:

When available on the board, the Video Framebuffer will be automatically enabled at startup and will show the tux logo during the boot.
In Linux you can then simply test the Video Framebuffer by filling it with random data with:
```
$ cat /dev/urandom >/dev/fb0
```


################################################################
# FILE: ./i2c_oled_readme.md
################################################################


# I2C OLED branch notes: `ext_i2cs_1p3in_GME12864_70`

This branch is for proving a 1.3 inch 128x64 I2C OLED display on the OrangeCrab Linux-on-LiteX system.

The initial target display is named:

```text
GME12864-70
1.3 inch
128x64
I2C OLED
```

The likely controller family is SH1106 or SSD1306-compatible. Do not assume the controller until the board is probed. Try SH1106 first for the 1.3 inch 128x64 module, then SSD1306 if the first driver does not display correctly.

The goal of this branch is intentionally not a new FPGA I2C controller yet. The current LiteX Linux build already exposes I2C from Linux, so the first proof should use the existing Linux I2C path:

```text
LiteX i2c0 CSR
Linux /dev/i2c-0
userspace OLED library
test image
```

External I2C/OLED library checkouts live outside `lolv/`:

```text
$WORKROOT/i2cs
```

That keeps `lolv/` mergeable and keeps third-party display/library repos out of this repo.

## Working directory variables

```bash
export EXTERNAL="$HOME/1tb/ext"
export WORKROOT="$HOME/1tb/see/1-c0d3/vhdl"
export WORKDIR="$WORKROOT/lolv"
export I2CSDIR="$WORKROOT/i2cs"

cd "$WORKDIR"
source "$EXTERNAL/fpga-env.sh"
hash -r
```

## Branch

This branch should be independent of the spin/SLU branch:

```bash
cd "$WORKDIR"
git switch -c ext_i2cs_1p3in_GME12864_70 2>/dev/null || git switch ext_i2cs_1p3in_GME12864_70
```

## Local source capture

Generate review aggregates before and after patches:

```bash
cd "$WORKDIR"
./cat_src.sh

ls -lh reports/cat_lolv_readmes.txt
ls -lh reports/cat_lolv_modified_scripts.txt
ls -lh reports/cat_lolv_all.txt
```

## Fetch external OLED libraries into `../i2cs`

Run:

```bash
cd "$WORKDIR"
./tools/setup_i2cs_oled_repos.sh
```

This creates:

```text
$WORKROOT/i2cs/luma.core
$WORKROOT/i2cs/luma.oled
$WORKROOT/i2cs/luma.examples
$WORKROOT/i2cs/README.md
```

The first display test uses `luma.oled` because it already supports common SSD1306/SH1106 OLED modules through Linux I2C.

## Create a test image

Run on the host:

```bash
cd "$WORKDIR"
python3 ./tools/make_oled_test_image.py

ls -lh reports/oled_test_128x64.pbm
ls -lh reports/oled_test_128x64.xbm
```

The generated test pattern is intentionally simple:

```text
128x64
border
diagonal lines
filled corner blocks
text-like stripe region
```

The PBM/XBM files are useful even before `Pillow` is available.

## Probe I2C from OrangeCrab Linux

Boot the OrangeCrab Linux image and run on the target:

```bash
ls -l /dev/i2c-* || true
ls -l /sys/class/i2c-dev || true

i2cdetect -y 0
```

Expected OLED addresses are usually:

```text
0x3c
0x3d
```

If `i2cdetect` is missing but `/dev/i2c-0` exists, the kernel path may still be valid. Add `i2c-tools` later for easier interactive debug.

The branch provides a helper script:

```bash
cd "$WORKDIR"
./tools/probe_i2c0_oled.sh
```

On the target, copy the script over or paste its commands.

## Run the luma OLED test

The intended route is to use the existing Linux I2C device and a userspace OLED library.

On a target/rootfs that has Python, Pillow, and luma installed or vendored:

```bash
cd "$WORKDIR"

python3 ./tools/run_luma_oled_test.py \
  --port 0 \
  --address 0x3c \
  --device sh1106
```

If the screen does not look right, try SSD1306:

```bash
python3 ./tools/run_luma_oled_test.py \
  --port 0 \
  --address 0x3c \
  --device ssd1306
```

If the address is `0x3d`, switch `--address 0x3d`.

## Host-side library path option

When running from a normal Linux environment with the external repos checked out, this script tries to add these paths automatically:

```text
$WORKROOT/i2cs/luma.core
$WORKROOT/i2cs/luma.oled
```

For manual testing:

```bash
export I2CSDIR="$WORKROOT/i2cs"
export PYTHONPATH="$I2CSDIR/luma.core:$I2CSDIR/luma.oled:$PYTHONPATH"
python3 ./tools/run_luma_oled_test.py --port 0 --address 0x3c --device sh1106
```

## Buildroot/rootfs follow-up

If the target Linux rootfs lacks the needed userspace packages, add them in a later patch after the raw I2C probe is confirmed.

Likely package needs:

```text
i2c-tools
python3
python3-pillow or a lightweight framebuffer/image path
luma.core / luma.oled vendored or installed
```

Do not rebuild Buildroot until the board-level I2C wiring and OLED address are known.

## Hardware wiring notes

Use the OrangeCrab header pins that are already wired to LiteX `i2c0`. Do not reassign those pads in this branch unless the existing I2C path is proven broken.

Typical OLED pins:

```text
VCC
GND
SCL
SDA
```

Confirm the display module voltage. Many modules accept 3.3V logic, but do not assume 5V tolerance on FPGA pins.

## Success definition

This branch is successful when:

```text
1. OrangeCrab Linux boots.
2. /dev/i2c-0 exists.
3. OLED address appears on i2cdetect, usually 0x3c or 0x3d.
4. luma.oled can initialize the controller.
5. the test image appears on the 128x64 OLED.
6. cat_src.sh captures the branch docs and scripts into reports/.
```

After this passes, a later branch can decide whether a custom FPGA I2C/OLED controller belongs under `$WORKROOT/i2cs`, `lolv/gateware`, or a dedicated firmware tree.


################################################################
# FILE: ./install_readme.md
################################################################

# Install Notes

<!-- ORANGECRAB_REQUIREMENTS_START -->
## OrangeCrab Linux install notes

This section records the working bring-up path for Linux-on-LiteX-VexRiscv on OrangeCrab.

Tested result:

- Board: OrangeCrab 85F revision 0.2
- SDRAM: MT41K256M16
- SoC: LiteX / VexRiscv-SMP
- CPU ISA visible from Linux: `rv32ima`
- Kernel: Linux 6.9.0
- Root filesystem: Buildroot 2023.02.5
- Boot path: LiteX BIOS -> SDCard FAT boot partition -> OpenSBI -> Linux -> ext4 rootfs on `mmcblk0p2`
- Host used for this bring-up: Jetson Orin Nano

The proven build shape is:

```
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

The `--` separator is required because `--sdram-device=...` is a board/SoC kwarg, not a top-level `make.py` option.

### 1. Directory layout

Keep large source trees, toolchains, generated CPU sources, Buildroot sources, caches, and wrapper scripts outside this repository.

Use `LOEXSO` as the external local source/tool directory:

```
export LOEXSO="$EXTERNAL"
mkdir -p "$LOEXSO"
```

The working repo path used here is:

```
cd $WORKDIR
```

The intended layout is:

```
$WORKDIR/      this repository
$LOEXSO/litex-venv/              Python virtual environment
$LOEXSO/litex-src/               editable LiteX Python sources
$LOEXSO/litex-pythondata/        recursive pythondata checkouts
$LOEXSO/buildroot/               real Buildroot source tree
$LOEXSO/oss-cad-suite/           ECP5 FPGA toolchain, if using OSS CAD Suite
$LOEXSO/fpga-env.sh              reusable environment hook
```

### 2. Base host packages

Install base packages first:

```
sudo apt update

sudo apt install -y \
  build-essential \
  git \
  curl \
  wget \
  ca-certificates \
  gnupg \
  python3 \
  python3-venv \
  python3-pip \
  python3-setuptools \
  python3-wheel \
  device-tree-compiler \
  dfu-util \
  openocd \
  pkg-config \
  rsync \
  bc \
  file \
  cpio \
  unzip \
  bzip2 \
  gzip \
  xz-utils \
  patch \
  perl \
  sed \
  make \
  gcc \
  g++ \
  libncurses-dev \
  libssl-dev \
  dosfstools \
  e2fsprogs \
  gdisk \
  parted
```

### 3. Java and SBT for VexRiscv-SMP generation

Some VexRiscv-SMP configurations are pregenerated, but this OrangeCrab Linux build can request a CPU configuration that triggers local VexRiscv/SpinalHDL netlist generation.

Install Java:

```
sudo apt update
sudo apt install -y openjdk-17-jdk
```

Install SBT:

```
sudo rm -f /etc/apt/sources.list.d/sbt.list
sudo rm -f /usr/share/keyrings/sbt.gpg
sudo rm -f /etc/apt/trusted.gpg.d/sbt.gpg

curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x2EE0EA64E40A89B84B2DF73499E82A75642AC823" \
  | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/sbt.gpg

echo "deb https://repo.scala-sbt.org/scalasbt/debian all main" \
  | sudo tee /etc/apt/sources.list.d/sbt.list

sudo apt update
sudo apt install -y sbt
```

Verify:

```
java -version
javac -version
sbt --version
```

### 4. ECP5 FPGA toolchain

OrangeCrab uses a Lattice ECP5 FPGA. The bitstream build needs:

```
yosys
nextpnr-ecp5
ecppack
dfu-util
```

These can come from OSS CAD Suite or another working ECP5 open-source FPGA toolchain. If using OSS CAD Suite, install/extract it under:

```
$LOEXSO/oss-cad-suite
```

The environment script below assumes:

```
$LOEXSO/oss-cad-suite/bin
```

Verify the tools:

```
yosys -V
nextpnr-ecp5 --version
ecppack --help | head
dfu-util --version
```

### 5. Python virtual environment

Create and enter the LiteX virtual environment:

```
export LOEXSO="${LOEXSO:-$EXTERNAL}"
mkdir -p "$LOEXSO"

python3 -m venv "$LOEXSO/litex-venv"
source "$LOEXSO/litex-venv/bin/activate"

python -m pip install -U pip setuptools wheel
python -m pip install -U pyserial requests pyyaml
```

### 6. Editable LiteX Python stack

Keep editable LiteX sources outside this repo:

```
export LOEXSO="${LOEXSO:-$EXTERNAL}"
mkdir -p "$LOEXSO/litex-src"
cd "$LOEXSO/litex-src"

for repo in \
  migen \
  litex \
  litex-boards \
  litedram \
  liteeth \
  litescope \
  liteiclink \
  litesdcard
do
  if [ ! -d "$repo" ]; then
    git clone "https://github.com/enjoy-digital/$repo.git"
  fi
  python -m pip install -e "$repo"
done
```

Verify:

```
python - <<'VERIFY_LITEX_STACK'
import migen
import litex
import litex_boards
import litedram
import liteeth
import litescope
import liteiclink
import litesdcard

print("LiteX Python stack imports OK")
VERIFY_LITEX_STACK
```

### 7. OrangeCrab USB CDC ACM UART Python dependencies

The OrangeCrab LiteX target uses a USB CDC ACM UART path. That path imports Amaranth and LUNA.

Install:

```
python -m pip install -U amaranth
python -m pip install -U git+https://github.com/greatscottgadgets/luna.git
```

Verify:

```
python - <<'VERIFY_AMARANTH_LUNA'
import amaranth
import luna
import luna.full_devices

print("amaranth:", amaranth.__version__)
print("luna import OK")
VERIFY_AMARANTH_LUNA
```

### 8. LiteX software data packages

Install the LiteX software data packages needed by BIOS/software generation:

```
python -m pip install -U git+https://github.com/litex-hub/pythondata-software-picolibc.git
python -m pip install -U git+https://github.com/litex-hub/pythondata-software-compiler_rt.git
```

Verify:

```
python - <<'VERIFY_LITEX_SOFTWARE_DATA'
import pythondata_software_picolibc
import pythondata_software_compiler_rt

print("pythondata_software_picolibc OK")
print("picolibc:", pythondata_software_picolibc.data_location)

print("pythondata_software_compiler_rt OK")
print("compiler_rt:", pythondata_software_compiler_rt.data_location)
VERIFY_LITEX_SOFTWARE_DATA
```

### 9. VexRiscv-SMP pythondata recursive editable checkout

The Linux CPU is `vexriscv_smp`. Do not rely on a flattened plain pip install for this target. The local VexRiscv-SMP generation path needs the recursive Git checkout with submodule metadata intact.

Install it this way:

```
export LOEXSO="${LOEXSO:-$EXTERNAL}"
export SITE_PKGS="$(python -c 'import site; print(site.getsitepackages()[0])')"

python -m pip uninstall -y \
  pythondata-cpu-vexriscv-smp \
  pythondata-cpu-vexriscv_smp \
  pythondata_cpu_vexriscv_smp || true

rm -rf "$SITE_PKGS/pythondata_cpu_vexriscv_smp"
rm -rf "$SITE_PKGS/pythondata_cpu_vexriscv_smp-"*
rm -rf "$SITE_PKGS/pythondata_cpu_vexriscv_smp."*
rm -rf "$SITE_PKGS/pythondata_cpu_vexriscv_smp.egg-link"

mkdir -p "$LOEXSO/litex-pythondata"
cd "$LOEXSO/litex-pythondata"

rm -rf pythondata-cpu-vexriscv_smp
git clone --recursive https://github.com/litex-hub/pythondata-cpu-vexriscv_smp.git
cd pythondata-cpu-vexriscv_smp
git submodule update --init --recursive

python -m pip install -e .
```

Verify that Python points at the recursive checkout and that both VexRiscv and SpinalHDL have their SBT files and Git metadata:

```
python - <<'VERIFY_VEXRISCV_DATA'
import pythondata_cpu_vexriscv_smp
from pathlib import Path

print("module:", pythondata_cpu_vexriscv_smp)
print("__file__:", getattr(pythondata_cpu_vexriscv_smp, "__file__", None))
print("__path__:", list(getattr(pythondata_cpu_vexriscv_smp, "__path__", [])))
print("data_location:", getattr(pythondata_cpu_vexriscv_smp, "data_location", None))

p = Path(pythondata_cpu_vexriscv_smp.data_location)
print("data path:", p)
print("VexRiscv build.sbt:", (p / "ext/VexRiscv/build.sbt").exists())
print("SpinalHDL build.sbt:", (p / "ext/SpinalHDL/build.sbt").exists())
print("VexRiscv .git:", (p / "ext/VexRiscv/.git").exists())
print("SpinalHDL .git:", (p / "ext/SpinalHDL/.git").exists())
VERIFY_VEXRISCV_DATA
```

Good verification shape:

```
VexRiscv build.sbt: True
SpinalHDL build.sbt: True
VexRiscv .git: True
SpinalHDL .git: True
```

### 10. Reusable FPGA environment script

Create a reusable environment hook:

```
export LOEXSO="${LOEXSO:-$EXTERNAL}"
mkdir -p "$LOEXSO/bin"

cat > "$LOEXSO/fpga-env.sh" <<'ENV'
export LOEXSO="${LOEXSO:-$EXTERNAL}"

if [ -d "$LOEXSO/litex-venv" ]; then
  source "$LOEXSO/litex-venv/bin/activate"
fi

export PATH="$LOEXSO/bin:$PATH"

if [ -d "$LOEXSO/oss-cad-suite/bin" ]; then
  export PATH="$LOEXSO/oss-cad-suite/bin:$PATH"
fi
ENV
```

Use it before all build and flash commands:

```
source "$LOEXSO/fpga-env.sh"
```

### 11. Build the OrangeCrab bitstream

From this repository:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh

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

Successful progress checkpoints before synthesis:

```
FPGA device : LFE5U-85F-8MG285C
System clock: 64.000MHz
CPU vexriscv_smp added
main_ram Region added at Origin: 0x40000000, Size: 0x20000000
CSR locations include ddrphy, uart, timer0, i2c0, leds, sdcard, sdram
IRQ locations include uart, timer0, sdcard
VexRiscv cluster : VexRiscvLitexSmpCluster...
Generating cluster netlist
```

Successful output artifacts include:

```
build/orange_crab/gateware/orange_crab.bit
build/orange_crab/gateware/orange_crab.bit.dfu
build/orange_crab/gateware/orange_crab.config
build/orange_crab/gateware/orange_crab.json
build/orange_crab/orange_crab.dtb
build/orange_crab/orange_crab.dts
build/orange_crab/software/bios/bios.bin
build/orange_crab/software/bios/bios.elf
build/orange_crab/csr.csv
build/orange_crab/csr.json
```

Successful resource use from nextpnr:

```
TRELLIS_COMB:   17,814 / 83,640   = 21%
TRELLIS_FF:      8,186 / 83,640   = 9%
DP16KD:             29 / 208      = 13%
MULT18X18D:          4 / 156      = 2%
EHXPLLL:             2 / 4        = 50%
TRELLIS_IO:         73 / 365      = 20%
TRELLIS_RAMW:      388 / 10,455   = 3%
IOLOGIC:            53 / 224      = 23%
DQSBUFM:             2 / 14       = 14%
DDRDLL:              1 / 4        = 25%
CLKDIVF:             1 / 4        = 25%
```

Successful timing:

```
sys_clk target:        64.00 MHz
sys_clk achieved max:  65.83 MHz
result:                PASS
```

There is substantial LUT/FF/BRAM headroom for small custom CSR/IP blocks, but the 64 MHz system clock margin is tight. Keep first custom IP simple and synchronous.

### 12. Buildroot source checkout

The repository `buildroot/` directory is a Buildroot `BR2_EXTERNAL` overlay, not the Buildroot source tree.

The real Buildroot source tree must be checked out separately under `LOEXSO`:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh

export LOEXSO="${LOEXSO:-$EXTERNAL}"
mkdir -p "$LOEXSO"

cd "$LOEXSO"

if [ ! -d buildroot ]; then
  git clone https://github.com/buildroot/buildroot.git
fi

cd buildroot
git fetch --tags --all
git checkout 2023.02.5
```

### 13. Build Linux, OpenSBI, and rootfs payloads

Clean `LD_LIBRARY_PATH` before running Buildroot. Buildroot refuses to run if the current directory is present in `LD_LIBRARY_PATH`, including an empty path element:

```
export LD_LIBRARY_PATH="$(python3 - <<'PY'
import os

parts = os.environ.get("LD_LIBRARY_PATH", "").split(":")
clean = []
for p in parts:
    if p in ("", "."):
        continue
    clean.append(p)

print(":".join(clean))
PY
)"
```

Generate the Buildroot config from the `make.py` generated board defconfig:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh

export LOEXSO="${LOEXSO:-$EXTERNAL}"
export BR_OUT="$PWD/build/orange_crab/buildroot"

mkdir -p "$BR_OUT"

make -C "$LOEXSO/buildroot" \
  O="$BR_OUT" \
  BR2_EXTERNAL="$PWD/buildroot" \
  BR2_DEFCONFIG="$PWD/build/orange_crab/buildroot_defconfig" \
  defconfig
```

Build:

```
make -C "$LOEXSO/buildroot" \
  O="$BR_OUT"
```

The final `post-image.sh` / `genimage` step may fail after the useful payloads have already been created. For manual SD preparation, the required outputs are:

```
build/orange_crab/buildroot/images/Image
build/orange_crab/buildroot/images/fw_jump.bin
build/orange_crab/buildroot/images/rootfs.ext4
build/orange_crab/buildroot/images/rootfs.cpio.gz
```

Link/copy them into repo `images/`:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh

export BR_OUT="$PWD/build/orange_crab/buildroot"

ln -snf "$BR_OUT/images/Image" images/Image
ln -snf "$BR_OUT/images/fw_jump.bin" images/opensbi.bin
ln -snf "$BR_OUT/images/rootfs.cpio" images/rootfs.cpio
ln -snf "$BR_OUT/images/rootfs.cpio.gz" images/rootfs.cpio.gz
ln -snf "$BR_OUT/images/rootfs.ext4" images/rootfs.ext4
cp -v build/orange_crab/orange_crab.dtb images/rv32.dtb

ls -lh \
  images/Image \
  images/opensbi.bin \
  images/rootfs.ext4 \
  images/rootfs.cpio.gz \
  images/boot.json \
  images/rv32.dtb
```

Expected successful payload sizes from the tested build:

```
Image:         about 8.0 MiB
opensbi.bin:   about 258 KiB
rootfs.cpio:   about 6.3 MiB
rootfs.cpio.gz about 3.1 MiB
rootfs.ext4:   about 60 MiB
rv32.dtb:      about 3.0 KiB
```

### 14. SD card layout

The OrangeCrab SD card does not appear as a host block device while it is inserted in the OrangeCrab. Remove it and place it in a USB SD reader to partition/copy files.

The tested Linux build uses:

```
--rootfs=mmcblk0p2
```

So the SD card layout is:

```
/dev/sdX1  FAT32  LITEXBOOT  boot partition
/dev/sdX2  ext4   rootfs      Linux root filesystem
```

Be careful not to overwrite the Jetson boot SD. On the tested Jetson, `/dev/mmcblk0` was the Jetson boot SD. The OrangeCrab SD reader appeared as `/dev/sdb`.

Destructive format flow when the OrangeCrab SD is definitely `/dev/sdb`:

```
export SD=/dev/sdb

lsblk -o NAME,SIZE,MODEL,TRAN,RM,MOUNTPOINTS "$SD"

sudo umount ${SD}?* 2>/dev/null || true

sudo wipefs -a "$SD"
sudo sgdisk --zap-all "$SD"

sudo parted -s "$SD" mklabel msdos
sudo parted -s "$SD" mkpart primary fat32 1MiB 256MiB
sudo parted -s "$SD" set 1 boot on
sudo parted -s "$SD" mkpart primary ext4 256MiB 100%

sudo partprobe "$SD"
sleep 2

sudo mkfs.vfat -F 32 -n LITEXBOOT ${SD}1
sudo mkfs.ext4 -F -L LITEXROOT ${SD}2

sync
lsblk -f "$SD"
```

Initial formatted shape:

```
sdb
├─sdb1 vfat FAT32 LITEXBOOT
└─sdb2 ext4 1.0   LITEXROOT
```

After writing `rootfs.ext4` to partition 2, the partition 2 label becomes `rootfs`. That is expected.

### 15. Linux payloads are separate from the FPGA bitstream

The FPGA bitstream contains:

- VexRiscv CPU
- LiteX SoC
- DDR/SDRAM controller
- SDCard controller
- USB CDC UART / LiteX BIOS console
- BIOS ROM
- CSR/peripheral map

Linux is not embedded in the RISC-V core or in the generated CPU netlist.

The FAT boot partition must contain:

```
boot.json
Image
rv32.dtb
opensbi.bin
```

The `boot.json` shape for `mmcblk0p2` rootfs is:

```
{
    "Image"       : "0x40000000",
    "rv32.dtb"    : "0x40ef0000",
    "opensbi.bin" : "0x40f00000"
}
```

With `--rootfs=mmcblk0p2`, the Linux root filesystem lives on the second SD partition.

### 16. Write the SD card

With the OrangeCrab SD card in a USB reader and identified as `/dev/sdb`:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh

export SD=/dev/sdb

lsblk -f "$SD"

sudo umount ${SD}?* 2>/dev/null || true

sudo dd if=images/rootfs.ext4 of=${SD}2 bs=4M status=progress conv=fsync

sudo mkdir -p /tmp/litexboot
sudo mount ${SD}1 /tmp/litexboot

sudo rm -f /tmp/litexboot/*

sudo cp -v images/boot_mmcblk0p2.json /tmp/litexboot/boot.json
sudo cp -Lv images/Image /tmp/litexboot/Image
sudo cp -Lv images/opensbi.bin /tmp/litexboot/opensbi.bin
sudo cp -v build/orange_crab/orange_crab.dtb /tmp/litexboot/rv32.dtb

find /tmp/litexboot -maxdepth 1 -type f -printf '%f %s bytes\n' | sort

sync
sudo umount /tmp/litexboot
sync

lsblk -f "$SD"
```

Expected boot partition files:

```
boot.json     96 bytes
Image         about 8.0 MiB
opensbi.bin   about 258 KiB
rv32.dtb      about 3.0 KiB
```

Expected final SD shape:

```
sdb
├─sdb1 vfat FAT32 LITEXBOOT
└─sdb2 ext4 1.0   rootfs
```

### 17. Flash the OrangeCrab bitstream

Put the OrangeCrab into DFU mode. A data-capable USB-C cable is required.

Check DFU visibility:

```
sudo dfu-util -l
```

Expected DFU layout:

```
Found DFU: [1209:5af0] ... alt=1, name="0x00100000 RISC-V Firmware"
Found DFU: [1209:5af0] ... alt=0, name="0x00080000 Bitstream"
```

Flash the generated FPGA bitstream to alt `0`:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh

sudo dfu-util -a 0 -D build/orange_crab/gateware/orange_crab.bit.dfu
```

Do not write `orange_crab.bit.dfu` to alt `1`.

Successful flash shape:

```
Setting Alternate Setting #0 ...
Download [=========================] 100%
Download done.
state(7) = dfuMANIFEST, status(0) = No error condition is present
```

The final `unable to read DFU status after completion` message can appear after the board disconnects/re-enumerates and is not necessarily a failure when the new design comes up.

### 18. Open the LiteX BIOS console

After flashing, the board should re-enumerate as LiteX USB CDC ACM:

```
sudo dmesg | tail -120
lsusb
ls -lah /dev/ttyACM* /dev/ttyUSB* 2>/dev/null || true
```

Expected:

```
1209:0001
/dev/ttyACM0
```

If `/dev/ttyACM0` is owned by `root:dialout`, either use `sudo` or add the user to `dialout`.

Temporary console command:

```
sudo env "PATH=$PATH" litex_term /dev/ttyACM0
```

Permanent serial permission fix:

```
sudo usermod -aG dialout "$USER"
```

Log out/in or reboot before non-sudo serial access works.

### 19. LiteX BIOS checks and SD boot

Successful BIOS boot shape:

```
BIOS CRC passed

CPU:        VexRiscv SMP-LINUX @ 64MHz
BUS:        wishbone 32-bit data/32-bit addr
CSR:        32-bit data big ordering
ROM:        64.0KiB
SRAM:       6.0KiB
SDRAM:      64.0MiB 16-bit @ 256MT/s (CL-6 CWL-5)
MAIN RAM:   512.0MiB

Memtest OK
```

BIOS validation commands:

```
help
sdram_test
sdcard_detect
sdcard_init
sdcardboot
```

The BIOS command `boot` is not the SD boot command by itself. It expects an address:

```
boot <address> [r1] [r2] [r3]
```

For SD boot, use:

```
sdcardboot
```

Expected SD boot flow:

```
BIOS reads boot.json from FAT32 partition 1
BIOS loads Image to 0x40000000
BIOS loads rv32.dtb to 0x40ef0000
BIOS loads opensbi.bin to 0x40f00000
OpenSBI starts
Linux starts
Linux waits for /dev/mmcblk0p2
Linux mounts ext4 rootfs
Buildroot login prompt appears
```

### 20. Proven Linux boot result

The successful boot reached:

```
Welcome to Buildroot
buildroot login:
```

Login:

```
root
```

Successful Linux checks:

```
uname -a
cat /proc/cmdline
cat /proc/cpuinfo
cat /proc/meminfo | head -30
mount
df -h
ls /dev
ls /sys/class/i2c-dev 2>/dev/null || true
ls /dev/i2c* 2>/dev/null || true
dmesg | grep -iE 'litex|vex|riscv|mmc|sd|uart|i2c|csr|root' | head -200
```

Confirmed Linux facts from the successful boot:

```
Linux buildroot 6.9.0 riscv32 GNU/Linux
console=liteuart earlycon=liteuart,0xf0001000 rootwait root=/dev/mmcblk0p2
processor: 0
hart: 0
isa: rv32ima
mmu: sv32
MemTotal: about 510568 kB
/dev/root mounted rw as ext4
/dev/mmcblk0 detected as SD16G 14.5 GiB
/dev/mmcblk0p1 and /dev/mmcblk0p2 detected
/dev/i2c-0 exists
/dev/gpiochip0 exists
/dev/ttyLXU0 exists
```

Important successful kernel log lines:

```
LiteX SoC Controller driver initialized
f0001000.serial: ttyLXU0 ... is a liteuart
litex-mmc f0003800.mmc: LiteX MMC controller initialized.
mmc0: new SDHC card at address 0001
mmcblk0: mmc0:0001 SD16G 14.5 GiB
mmcblk0: p1 p2
EXT4-fs (mmcblk0p2): mounted filesystem
VFS: Mounted root (ext4 filesystem)
EXT4-fs (mmcblk0p2): re-mounted ... r/w
```

Known non-fatal boot messages:

```
mount: mounting devpts on /dev/pts failed: No such device
i2c i2c-0: Not I2C compliant: can't read SCL
i2c i2c-0: Bus may be unreliable
```

The `devpts` message does not block login. The I2C warning does not block Linux boot; it likely means the default I2C pins are floating, missing pullups, not connected to a compliant target, or need board-level validation before use.

### 21. Known fixes discovered during bring-up

This section records the specific failures hit during bring-up and the fix. These are listed after the normal install path so they do not interrupt the ordered flow.

#### Missing Amaranth

Failure:

```
ModuleNotFoundError: No module named 'amaranth'
```

Fix:

```
python -m pip install -U amaranth
```

#### Missing LUNA

Failure:

```
ModuleNotFoundError: No module named 'luna'
```

Fix:

```
python -m pip install -U git+https://github.com/greatscottgadgets/luna.git
```

#### Missing LiteX software data

Failure:

```
ImportError: pythondata-software-picolibc module not installed!
No module named 'pythondata_software_picolibc'
```

Fix:

```
python -m pip install -U git+https://github.com/litex-hub/pythondata-software-picolibc.git
```

Failure:

```
ImportError: pythondata-software-compiler_rt module not installed!
No module named 'pythondata_software_compiler_rt'
```

Fix:

```
python -m pip install -U git+https://github.com/litex-hub/pythondata-software-compiler_rt.git
```

#### Missing SBT

Failure:

```
Generating cluster netlist
/bin/sh: 1: sbt: not found
```

Fix: install Java and SBT before the bitstream build.

#### Broken flattened VexRiscv-SMP pythondata install

Broken symptoms:

```
fatal: not a git repository: .../.git/modules/pythondata_cpu_vexriscv_smp/verilog/ext/SpinalHDL
```

or:

```
Neither build.sbt nor a 'project' directory in the current directory:
.../pythondata_cpu_vexriscv_smp/verilog/ext/VexRiscv
```

Fix: remove stale `site-packages` copies and install `pythondata-cpu-vexriscv_smp` from a recursive editable checkout.

#### Buildroot source tree confusion

Failure:

```
make -C buildroot ... defconfig
make: *** No rule to make target 'defconfig'. Stop.
```

Cause:

```
repo/buildroot/ is BR2_EXTERNAL overlay
$LOEXSO/buildroot/ is the real Buildroot source tree
```

Fix: use:

```
make -C "$LOEXSO/buildroot" \
  O="$BR_OUT" \
  BR2_EXTERNAL="$PWD/buildroot" \
  BR2_DEFCONFIG="$PWD/build/orange_crab/buildroot_defconfig" \
  defconfig
```

#### Buildroot refuses current directory in LD_LIBRARY_PATH

Failure:

```
You seem to have the current working directory in your
LD_LIBRARY_PATH environment variable. This doesn't work.
```

Fix:

```
export LD_LIBRARY_PATH="$(python3 - <<'PY'
import os

parts = os.environ.get("LD_LIBRARY_PATH", "").split(":")
clean = []
for p in parts:
    if p in ("", "."):
        continue
    clean.append(p)

print(":".join(clean))
PY
)"
```

#### BusyBox `tc` failure

Failure:

```
networking/tc.c: error: 'TCA_CBQ_MAX' undeclared
make[3]: *** [scripts/Makefile.build:197: networking/tc.o] Error 1
```

The first LiteX Linux bring-up does not need BusyBox traffic-control support.

Fix:

```
cd $WORKDIR
source $EXTERNAL/fpga-env.sh

export LOEXSO="${LOEXSO:-$EXTERNAL}"
export BR_OUT="$PWD/build/orange_crab/buildroot"

BUSYBOX_DIR="$(find "$BR_OUT/build" -maxdepth 1 -type d -name 'busybox-*' | sort | tail -1)"

sed -i \
  -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
  -e 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' \
  "$BUSYBOX_DIR/.config"

make -C "$BUSYBOX_DIR" \
  ARCH=riscv \
  CROSS_COMPILE="$BR_OUT/host/bin/riscv32-buildroot-linux-gnu-" \
  oldconfig

make -C "$LOEXSO/buildroot" \
  O="$BR_OUT" \
  busybox-rebuild

make -C "$LOEXSO/buildroot" \
  O="$BR_OUT"
```

#### Final Buildroot post-image/genimage failure

Failure after Linux/OpenSBI/rootfs payloads were already generated:

```
FATAL ERROR: Couldn't open output file .../build/genimage.tmp/rv32.dts: No such file or directory
make[1]: *** [Makefile:815: target-post-image] Error 1
```

For manual SD preparation, this failure is not blocking if these files exist:

```
build/orange_crab/buildroot/images/Image
build/orange_crab/buildroot/images/fw_jump.bin
build/orange_crab/buildroot/images/rootfs.ext4
build/orange_crab/buildroot/images/rootfs.cpio.gz
```

Optional patch to make the post-image script create the temp directory before writing `rv32.dts`:

```
cd $WORKDIR

python - <<'PY'
from pathlib import Path

p = Path("buildroot/board/litex_vexriscv/post-image.sh")
s = p.read_text()

needle = 'DTB_DTS=${GENIMAGE_TMP}/rv32.dts'
replacement = 'mkdir -p "${GENIMAGE_TMP}"\n\tDTB_DTS=${GENIMAGE_TMP}/rv32.dts'

if replacement in s:
    print("already patched")
elif needle in s:
    s = s.replace(needle, replacement)
    p.write_text(s)
    print("patched", p)
else:
    raise SystemExit("needle not found; inspect post-image.sh")
PY
```

### 22. Root filesystem choices

Use the repository Buildroot image first. It is the known-good path for this RV32 LiteX/VexRiscv SoC and includes the matching kernel configuration, OpenSBI platform, LiteX patches, DTB assumptions, and root filesystem shape.

Other distributions such as Alpine are possible later, but they are not the first bring-up target. A distro rootfs still needs to match this RV32 userspace ABI and the LiteX/VexRiscv kernel/OpenSBI/device-tree boot contract.
<!-- ORANGECRAB_REQUIREMENTS_END -->\n

################################################################
# FILE: ./modify_readme.md
################################################################


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


################################################################
# FILE: ./README.md
################################################################

```
                                   __   _
                                  / /  (_)__  __ ____ __
                                 / /__/ / _ \/ // /\ \ /
                                /____/_/_//_/\_,_//_\_\
                                      / _ \/ _ \
                      __   _ __      _\___/_//_/ __             _
                     / /  (_) /____ | |/_/__| | / /____ __ ____(_)__ _____  __
                    / /__/ / __/ -_)>  </___/ |/ / -_) \ // __/ (_-</ __/ |/ /
                   /____/_/\__/\__/_/|_|    |___/\__/_\_\/_/ /_/___/\__/|___/

                   Copyright (c) 2019-2024, Linux-on-LiteX-VexRiscv Developers
```
[![](https://github.com/litex-hub/linux-on-litex-vexriscv/workflows/ci/badge.svg)](https://github.com/litex-hub/linux-on-litex-vexriscv/actions) ![License](https://img.shields.io/badge/License-BSD%202--Clause-orange.svg)
> **Note:** Tested on Ubuntu 22.04 LTS.


[> Intro
--------

This project is an experiment to run Linux with [VexRiscv-SMP](https://github.com/SpinalHDL/VexRiscv) CPU, a 32-bit Linux-capable RISC-V CPU written in [Spinal HDL](https://github.com/SpinalHDL/SpinalHDL).  [LiteX](https://github.com/enjoy-digital/litex) is used to create the SoC around the VexRiscv-SMP CPU and provides the infrastructure and peripherals (LiteDRAM, LiteEth, LiteSDCard, etc.). All the components used to create the SoC are open-source and the flexibility of Spinal HDL/LiteX allows easily targeting a very wide range of FPGA devices/boards: Xilinx, Intel, Lattice, Microsemi, Efinix FPGAs are tested with very diverse configurations: SDRAM/DDR/DDR2/DDR3/DDR4 or HyperRAM RAMs, RMII/MII/RGMII/1000BASE-X Ethernet PHYs, SDCard (in SPI or SD mode), SATA, PCIe, etc.

On Lattice ECP5 FPGAs, the [open source toolchain](https://github.com/SymbiFlow/prjtrellis) even allows creating a fully open-source SoC with open-source cores **and** toolchain!

This project demonstrates **how high-level HDL frameworks like Spinal HDL and LiteX can enable new possibilities and complement each other**. Results shown here are the outcome of a productive collaboration between various open-source communities.

[> Demo
----------

<p align="center"><img src="https://user-images.githubusercontent.com/1450143/156186177-ea06bddc-87b2-4d27-af60-d6d7f3f2929b.png" width="800"></p>

https://user-images.githubusercontent.com/1450143/156186677-87c40a39-2cf5-4ae0-9138-9d2aa0693ab6.mp4

[> Supported boards
-------------------
All boards supported in [LiteX-Boards](https://github.com/litex-hub/litex-boards) with...:

 - Enough FPGA logic to fit VexRiscv-SMP + LiteX SoC.
 - 32MB of RAM (reduced to 8MB when rootfs can be put on an SDCard or NFS).
 - A UART.

... could run this project.

The board support is directly imported from LiteX-Boards and the configuration is just adapted for the project in `make.py`.

The current list of boards that have been tested and are supported can be obtained by running `./make.py --help`:

    ├── acorn
    ├── acorn_baseboard_mini
    ├── acorn_pcie
    ├── aesku40
    ├── alveo_u250
    ├── alveo_u280
    ├── arty
    ├── arty_a7
    ├── arty_s7
    ├── atum_a3_nano
    ├── ax7020
    ├── butter_stick
    ├── cam_link4k
    ├── colorlight_5a_75x
    ├── colognechip_gatemate_evb
    ├── colorlight_i5
    ├── colorlight_i9plus
    ├── de0nano
    ├── de10nano
    ├── de1so_c
    ├── decklink_quad_hdmirecorder
    ├── ecpix5
    ├── embedfire_rise_pro
    ├── genesys2
    ├── hadbadge
    ├── hseda_xc7a35t
    ├── icepi_zero
    ├── icesugar_pro
    ├── kc705
    ├── kcu105
    ├── kolsch
    ├── konfekt
    ├── mini_spartan6
    ├── mnt_rkx7
    ├── ne_tv2
    ├── nexys4ddr
    ├── nexys_video
    ├── noir
    ├── orange_crab
    ├── pipistrello
    ├── qmtech_5cefa2
    ├── qmtech_ep4ce15
    ├── qmtech_ep4ce55
    ├── qmtech_wu_kong
    ├── schoko
    ├── sds1104xe
    ├── sipeed_tang_nano_20k
    ├── sipeed_tang_primer_20k
    ├── stlv7325
    ├── stlv7325_v2
    ├── titanium_ti60f225dev_kit
    ├── trellis_board
    ├── trion_t120bga576dev_kit
    ├── ulx3s
    ├── ulx4m_ld_v2
    ├── vc707
    ├── versa_ecp5
    ├── xcu1525
    ├── zcu104


Adding support for another board from LiteX-Boards satisfying the requirements should only be a matter of adding a few lines to `make.py`.

> **Note:** Avalanche support can be found in [RISC-V - Getting Started Guide](https://risc-v-getting-started-guide.readthedocs.io/en/latest/linux-avalanche.html) thanks to [Antmicro](https://antmicro.com).

> **Note:** On FPGA without distributed ram (as Cyclone IV), consider using the --without-out-of-order-decoder option to reduce area.

[> Prerequisites
----------------
```sh
$ sudo apt install build-essential device-tree-compiler wget git python3-setuptools
$ git clone https://github.com/litex-hub/linux-on-litex-vexriscv
$ cd linux-on-litex-vexriscv
```

[> Pre-built Bitstreams and Linux/OpenSBI images
------------------------------------------------

Pre-built bitstreams for the common boards and pre-built Linux images can be found [here](https://github.com/litex-hub/linux-on-litex-vexriscv/issues/164) and will get you started quickly and easily without the need to compile anything.

When using a pre-built board bitstream archive, also use the matching `.dtb` from this board archive: copy/rename it to `images/rv32.dtb` and to the SDCard as `rv32.dtb`. The DTB must match the bitstream's CSR map and memory size; a stale or board-generic `rv32.dtb` can make Linux see the wrong RAM size or miss peripherals. The DTB can also be regenerated with `./make.py --board=XXYY`.

[> Installing LiteX
-------------------
```sh
$ wget https://raw.githubusercontent.com/enjoy-digital/litex/master/litex_setup.py
$ chmod +x litex_setup.py
$ ./litex_setup.py --init --install --user (--user to install to user directory)
```
For more information, please visit: https://github.com/enjoy-digital/litex/wiki/Installation

[> Installing a RISC-V toolchain
--------------------------------
Install a recent bare-metal RISC-V GCC toolchain and make sure its `bin`
directory is in your `PATH`.

The LiteX setup script can install one directly through the host package
manager:
```sh
$ ./litex_setup.py --gcc=riscv
```
Depending on the system package manager, this command may need to be run with
sudo/root privileges.

LiteX auto-detects common RISC-V GCC triples such as `riscv64-unknown-elf`,
`riscv64-none-elf`, `riscv32-unknown-elf`, `riscv32-none-elf` and
`riscv-none-elf`. If multiple RISC-V toolchains are installed, select the
one to use with `LITEX_ENV_CC_TRIPLE`, for example:
```sh
$ export PATH=$PATH:/path/to/riscv-toolchain/bin
$ riscv64-unknown-elf-gcc --version
$ export LITEX_ENV_CC_TRIPLE=riscv64-unknown-elf
```

Pre-built toolchains are available from projects such as:
- xPack GNU RISC-V Embedded GCC: https://xpack-dev-tools.github.io/riscv-none-elf-gcc-xpack/docs/install/
- RISC-V GNU Toolchain releases: https://github.com/riscv-collab/riscv-gnu-toolchain/releases

[> Installing SBT (Only required for custom CPU configs)
--------------------------------
Some regular VexRiscv-SMP configurations are already pregenerated,
but for others, it needs to run some SpinalHDL hardware generation, which requires sbt.

Please visit: https://www.scala-sbt.org/1.x/docs/Installing-sbt-on-Linux.html#Installing+sbt+on+Linux

[> Installing Verilator (only needed for simulation)
----------------------------------------------------
```sh
$ sudo apt install verilator
$ sudo apt install libevent-dev libjson-c-dev
```

Check that the installed verilator version is >= 4.2xx. If not, you will have to compile it from sources.

[> Installing OpenOCD (only needed for hardware test)
-----------------------------------------------------
```sh
$ sudo apt install libtool automake pkg-config libusb-1.0-0-dev
$ git clone https://github.com/ntfreak/openocd.git
$ cd openocd
$ ./bootstrap
$ ./configure --enable-ftdi
$ make
$ sudo make install
```

[> VexRiscv-SMP JTAG/GDB debugging
----------------------------------
For VexRiscv-SMP CPU debugging with OpenOCD/GDB, see the LiteX wiki guide:
https://github.com/enjoy-digital/litex/wiki/JTAG-GDB-Debugging-with-VexRiscv-SMP-NaxRiscv-VexiiRiscv-CPUs

In this project, `--with-privileged-debug` enables the VexRiscv-SMP official
RISC-V debug logic and `--hardware-breakpoints=N` selects the number of
hardware breakpoints. The JTAG connection itself remains target/board
specific: for Xilinx BSCANE/internal JTAG, keep the default tunneled JTAG
interface and connect it as shown in the LiteX wiki; use `--jtag-tap` only
when exposing a full JTAG TAP through simulation or external pins.

The older custom VexRiscv debug plugin requires the SpinalHDL OpenOCD fork:
https://github.com/SpinalHDL/openocd_riscv
For the official RISC-V debug path, a recent RISC-V capable OpenOCD should be
suitable.

To load an arbitrary bare-metal ELF while the BIOS is running, reset the SoC,
let the BIOS reach its prompt, halt the CPU from OpenOCD/GDB, load the ELF at
an address matching the SoC memory map, set the PC/entry point, then resume.

[> Running the LiteX simulation
-------------------------------
You need to extract linux_???.zip from https://github.com/litex-hub/linux-on-litex-vexriscv/issues/164 into the images folder first, then :
```sh
$ ./sim.py
```
You should see Linux booting and be able to interact with it:
```
        __   _ __      _  __
       / /  (_) /____ | |/_/
      / /__/ / __/ -_)>  <
     /____/_/\__/\__/_/|_|

 (c) Copyright 2012-2019 Enjoy-Digital
 (c) Copyright 2012-2015 M-Labs Ltd

 BIOS built on May  2 2019 18:58:54
 BIOS CRC passed (97ea247b)

--============ SoC info ================--
CPU:       VexRiscv @ 1MHz
ROM:       32KB
SRAM:      4KB
MAIN-RAM:  131072KB

--========= Peripherals init ===========--

--========== Boot sequence =============--
Booting from serial...
Press Q or ESC to abort boot completely.
sL5DdSMmkekro
Timeout
Executing booted program at 0x20000000
--============= Liftoff! ===============--
VexRiscv Machine Mode software built May  3 2019 19:33:43
--========== Booting Linux =============--
[    0.000000] No DTB passed to the kernel
[    0.000000] Linux version 5.0.9 (florent@lab) (gcc version 8.3.0 (Buildroot 2019.05-git-00938-g75f9fcd0c9)) #1 Thu May 2 17:43:30 CEST 2019
[    0.000000] Initial ramdisk at: 0x(ptrval) (8388608 bytes)
[    0.000000] Zone ranges:
[    0.000000]   Normal   [mem 0x00000000c0000000-0x00000000c7ffffff]
[    0.000000] Movable zone start for each node
[    0.000000] Early memory node ranges
[    0.000000]   node   0: [mem 0x00000000c0000000-0x00000000c7ffffff]
[    0.000000] Initmem setup node 0 [mem 0x00000000c0000000-0x00000000c7ffffff]
[    0.000000] elf_hwcap is 0x1100
[    0.000000] Built 1 zonelists, mobility grouping on.  Total pages: 32512
[    0.000000] Kernel command line: mem=128M@0x40000000 rootwait console=hvc0 root=/dev/ram0 init=/sbin/init swiotlb=32
[    0.000000] Dentry cache hash table entries: 16384 (order: 4, 65536 bytes)
[    0.000000] Inode-cache hash table entries: 8192 (order: 3, 32768 bytes)
[    0.000000] Sorting __ex_table...
[    0.000000] Memory: 119052K/131072K available (1957K kernel code, 92K rwdata, 317K rodata, 104K init, 184K bss, 12020K reserved, 0K cma-reserved)
[    0.000000] SLUB: HWalign=64, Order=0-3, MinObjects=0, CPUs=1, Nodes=1
[    0.000000] NR_IRQS: 0, nr_irqs: 0, preallocated irqs: 0
[    0.000000] clocksource: riscv_clocksource: mask: 0xffffffffffffffff max_cycles: 0x114c1bade8, max_idle_ns: 440795203839 ns
[    0.000155] sched_clock: 64 bits at 75MHz, resolution 13ns, wraps every 2199023255546ns
[    0.001515] Console: colour dummy device 80x25
[    0.008297] printk: console [hvc0] enabled
[    0.009219] Calibrating delay loop (skipped), value calculated using timer frequency.. 150.00 BogoMIPS (lpj=300000)
[    0.009919] pid_max: default: 32768 minimum: 301
[    0.016255] Mount-cache hash table entries: 1024 (order: 0, 4096 bytes)
[    0.016802] Mountpoint-cache hash table entries: 1024 (order: 0, 4096 bytes)
[    0.044297] devtmpfs: initialized
[    0.061343] clocksource: jiffies: mask: 0xffffffff max_cycles: 0xffffffff, max_idle_ns: 7645041785100000 ns
[    0.061981] futex hash table entries: 256 (order: -1, 3072 bytes)
[    0.117611] clocksource: Switched to clocksource riscv_clocksource
[    0.251970] Unpacking initramfs...
[    2.005474] workingset: timestamp_bits=30 max_order=15 bucket_order=0
[    2.178440] Block layer SCSI generic (bsg) driver version 0.4 loaded (major 254)
[    2.178909] io scheduler mq-deadline registered
[    2.179271] io scheduler kyber registered
[    3.031140] random: get_random_bytes called from init_oops_id+0x4c/0x60 with crng_init=0
[    3.043743] Freeing unused kernel memory: 104K
[    3.044070] This architecture does not have kernel memory protection.
[    3.044472] Run /init as init process
mount: mounting tmpfs on /dev/shm failed: Invalid argument
mount: mounting tmpfs on /tmp failed: Invalid argument
mount: mounting tmpfs on /run failed: Invalid argument
Starting syslogd: OK
Starting klogd: OK
Initializing random number generator... [    4.374589] random: dd: uninitialized urandom read (512 bytes read)
done.
Starting network: ip: socket: Function not implemented
ip: socket: Function not implemented
FAIL


Welcome to Buildroot
buildroot login: root
login[48]: root login on 'hvc0'
# help
Built-in commands:
------------------
  . : [ [[ alias bg break cd chdir command continue echo eval exec
  exit export false fg getopts hash help history jobs kill let
  local printf pwd read readonly return set shift source test times
  trap true type ulimit umask unalias unset wait
#
```

[> Running with Renode
----------------------
Renode also provides a ready-to-run Linux-on-LiteX-VexRiscv script:
https://github.com/renode/renode/blob/master/scripts/single-node/litex_vexriscv_linux.resc

Use Renode's documentation for installation and launch instructions. The
Renode script is useful for quick functional emulation, while `./sim.py`
remains the LiteX/Verilator simulation flow used by this repository.

[> Running on hardware
----------------------
### Build the FPGA bitstream (optional)
**The prebuilt bitstreams for the supported boards are provided**, so you can just use them for quick testing, if you want to rebuild the bitstreams you will need to install the toolchain for your FPGA:

| FPGA family       |      Toolchain        |
|-------------------|-----------------------|
| Xilinx Ultrascale |      Vivado           |
| Xilinx 7-Series   |   Vivado/SymbiFlow*   |
| Xilinx Spartan6   |        ISE            |
| Lattice ECP5      | Yosys+Trellis+Nextpnr |
| Altera Cyclone4   |    Quartus Prime      |

Once installed, build the bitstream with:
```sh
$ ./make.py --board=XXYY --cpu-count=X --build
```

> **Note:** \*=to select a different toolchain use the `--toolchain` option, i.e.:
> ```
> ./make.py --board=arty --toolchain=symbiflow --build
> ```

### Load the FPGA bitstream
To load the bitstream to your board, run:
```sh
$ ./make.py --board=XXYY --cpu-count=X --load
```
> **Note**: If you are using a Versa board, you will need to change J50 to bypass the iSPclock. Re-arrange the jumpers to connect pins 1-2 and 3-5 (leaving one jumper spare). See p19 of the Versa Board user guide.

### Load the Linux images over Serial
All the boards support Serial loading of the Linux images and this is the only way to load them when the board does not have other communication interfaces or storage capability.

To load the Linux images over Serial, use the [litex_term](https://github.com/enjoy-digital/litex/blob/master/litex/tools/litex_term.py) terminal/tool provided by LiteX and run:
```sh
$ litex_term --images=images/boot.json /dev/ttyUSBX (--safe : In case of CRC Error, slower but should always work)
```
The images should load and you should see Linux booting :)

> **Note**: litex_term is automatically installed with LiteX.

> **Note**: By default baudrate is set to 115200 bauds. You can use `--uart-baudrate` argument of `make.py` to increase it on the board and use `--speed` argument of `litex_term` to reflect the change. This is useful to increase upload speed when binaries can only be uploaded over Serial.

> **Note:** Since on some boards JTAG/Serial is shared, when you run litex_term after loading the board, the BIOS serialboot will already have timed out. You will need to press Enter, see if you have the BIOS prompt and type *reboot*.

Since loading over Serial works for all boards, **this is the recommended way to do initial tests** even if your board has more capabilities.

### Load the Linux images over Ethernet
For boards with Ethernet support, the Linux images can be loaded over TFTP. You need to copy the files from *images* directory to your TFTP root directory. The default Local IP/Remote IP are 192.168.1.50/192.168.1.100 but you can change it with the *--local-ip* and *--remote-ip* arguments.

Once the bitstream is loaded, the board will try to retrieve the files from the TFTP server. If not successful or if the boot already timed out when you see the BIOS prompt, you can retry with the *netboot* command.

The images will be loaded to RAM and you should see Linux booting :)

### Boot with an NFS RootFS
For boards with Ethernet support, Linux can mount the RootFS over NFS. Generate
the SoC files with `--rootfs=nfs`, setting `--remote-ip` to the NFS server IP
and `--nfs-root` to the exported directory:

```sh
$ ./make.py --board=XXYY --rootfs=nfs \
            --local-ip=192.168.1.50 \
            --remote-ip=192.168.1.100 \
            --nfs-root=/srv/nfs/litex-vexriscv
```

This generates a matching `boot.json` without `rootfs.cpio` and adds the
`root=/dev/nfs`/`nfsroot=` kernel boot arguments to the DTB. The default NFS
mount options are `vers=3,tcp,nolock` and can be changed with
`--nfs-options`.

### Load the Linux images to SDCard
For boards with SDCard support, the Linux images can be loaded from it. You need to copy the files from *images* directory to your SDCard root directory (with a FAT partition).

The images will be loaded to RAM and you should see Linux booting :)

> **Note**: For more information about the possible ways to load application code to the CPU with LiteX, please have a look at the LiteX's [wiki](https://github.com/enjoy-digital/litex/wiki/Load-Application-Code-To-CPU).

### Configure/Use the peripherals
Please visit the [HOWTO](https://github.com/litex-hub/linux-on-litex-vexriscv/blob/master/HOWTO.md) document to learn how to configure and use the peripherals from Linux.

[> Generating the Linux binaries (optional)
-------------------------------------------
```sh
$ git clone http://github.com/buildroot/buildroot
$ cd buildroot
$ make BR2_EXTERNAL=../linux-on-litex-vexriscv/buildroot/ litex_vexriscv_defconfig
$ make
```
The binaries are located in *output/images/* and *images/*.

For bitstreams built with board-specific Buildroot options, such as USB-host
support, optional VexRiscv-SMP AES/FPU CPU features or NFS RootFS support,
use the matching Buildroot configuration so the generated toolchain, kernel
and software agree with the hardware. Run `make.py` from the
`linux-on-litex-vexriscv` checkout, then run the Buildroot command from the
Buildroot checkout:

```sh
$ ./make.py --board=XXYY --aes-instruction=True --with-fpu --cpu-per-fpu=1 --rootfs=nfs
$ make BR2_EXTERNAL=../linux-on-litex-vexriscv/buildroot/ \
       BR2_DEFCONFIG=../linux-on-litex-vexriscv/build/XXYY/buildroot_defconfig \
       defconfig
$ make
```

The generated `build/XXYY/buildroot_defconfig` starts from
`litex_vexriscv_defconfig` and applies the USB-host, AES, FPU and NFS RootFS
options selected by the board and on the `make.py` command line. With
`--rootfs=nfs`, Buildroot also generates `rootfs.tar`, which can be extracted
into the exported NFS directory.

[> Generating the Linux binaries with USB host support (optional)
-----------------------------------------------------------------
Run `make.py` for a USB-host capable board so it generates the matching
Buildroot defconfig, then use this defconfig from the Buildroot checkout:

```sh
$ git clone http://github.com/buildroot/buildroot
$ cd linux-on-litex-vexriscv
$ ./make.py --board=XXYY
$ cd ../buildroot
$ make BR2_EXTERNAL=../linux-on-litex-vexriscv/buildroot/ \
       BR2_DEFCONFIG=../linux-on-litex-vexriscv/build/XXYY/buildroot_defconfig \
       defconfig
$ make
```
The binaries are located in *output/images/* and *images/*.

[> Generating the OpenSBI binary (optional / part of the buildroot build sequence)
-------------------------------------------
```sh
$ git clone https://github.com/litex-hub/opensbi --branch 1.3.1-linux-on-litex-vexriscv
$ cd opensbi
$ make CROSS_COMPILE=riscv-none-embed- PLATFORM=litex/vexriscv
```

The binary will be located at *build/platform/litex/vexriscv/firmware/fw_jump.bin*.

[> Generating the VexRiscv Linux variant (optional)
---------------------------------------------------

If the VexRiscv configuration you request isn't already generated, you will need to install Java and SBT on your machine to enable local on-demand generation.

To install Java and SBT, see Install VexRiscv requirements: https://github.com/enjoy-digital/VexRiscv-verilog#requirements

[> Udev rules (optional)
----------------------------
Not needed but can make loading/flashing bitstreams easier:
```sh
$ git clone https://github.com/litex-hub/litex-buildenv-udev
$ cd litex-buildenv-udev
$ make install
$ make reload
```


## I2C OLED branch

The `ext_i2cs_1p3in_GME12864_70` branch proves a 1.3 inch 128x64 I2C OLED from Linux first, using the existing LiteX `i2c0` / `/dev/i2c-0` path.

External display libraries and experiments live outside this repo:

```text
$WORKROOT/i2cs
```

Branch-local notes:

```text
i2c_oled_readme.md
```

Branch-local scripts:

```text
cat_src.sh
tools/setup_i2cs_oled_repos.sh
tools/probe_i2c0_oled.sh
tools/make_oled_test_image.py
tools/run_luma_oled_test.py
```



################################################################
# FILE: ./reports/orangecrab_linux_baseline.md
################################################################

# OrangeCrab Linux baseline build report

Generated: 2026-06-23T16:35:37-04:00

## Git

Branch: see/orangecrab-linux-gpio-ip
Commit: 922cea3963ac78428889a065b64730a4c69fdd43

Status:
A  install_readme.md
?? images/boot.json
?? images/rv32.dtb
?? reports/

## Build command

./make.py \
  --board=orange_crab \
  --device=85F \
  --revision=0.2 \
  --cpu-count=1 \
  --rootfs=mmcblk0p2 \
  --build \
  -- \
  --sdram-device=MT41K256M16

## Key artifacts

-rw-rw-r-- 1 seejn seejn 5.7K Jun 23 06:06 build/orange_crab/csr.csv
-rw-rw-r-- 1 seejn seejn  12K Jun 23 05:48 build/orange_crab/csr.json
-rw-rw-r-- 1 seejn seejn 618K Jun 23 06:01 build/orange_crab/gateware/orange_crab.bit
-rw-rw-r-- 1 seejn seejn 618K Jun 23 06:06 build/orange_crab/gateware/orange_crab.bit.dfu
-rw-rw-r-- 1 seejn seejn 8.6M Jun 23 06:01 build/orange_crab/gateware/orange_crab.config
-rw-rw-r-- 1 seejn seejn  32M Jun 23 05:54 build/orange_crab/gateware/orange_crab.json
-rw-rw-r-- 1 seejn seejn 6.4M Jun 23 05:54 build/orange_crab/gateware/orange_crab.rpt
-rw-rw-r-- 1 seejn seejn 1.3M Jun 23 06:01 build/orange_crab/gateware/orange_crab.svf
-rw-rw-r-- 1 seejn seejn 3.0K Jun 23 06:06 build/orange_crab/orange_crab.dtb
-rw-rw-r-- 1 seejn seejn 4.8K Jun 23 06:06 build/orange_crab/orange_crab.dts
-rw-rw-r-- 1 seejn seejn  44K Jun 23 06:06 build/orange_crab/software/bios/bios.bin
-rw-rw-r-- 1 seejn seejn 465K Jun 23 06:06 build/orange_crab/software/bios/bios.elf
-rw-rw-r-- 1 seejn seejn  34K Jun 23 06:06 build/orange_crab/software/include/generated/csr.h
-rw-rw-r-- 1 seejn seejn 1.8K Jun 23 06:06 build/orange_crab/software/include/generated/mem.h
-rw-rw-r-- 1 seejn seejn  360 Jun 23 05:48 build/orange_crab/software/include/generated/regions.ld
-rw-rw-r-- 1 seejn seejn 2.4K Jun 23 05:48 build/orange_crab/software/include/generated/variables.mak

## CSR map

#--------------------------------------------------------------------------------
# Auto-generated by LiteX (97ed83b6d) on 2026-06-23 06:06:53
#--------------------------------------------------------------------------------
csr_base,ctrl,0xf0000000,,
csr_base,ddrphy,0xf0000800,,
csr_base,uart,0xf0001000,,
csr_base,timer0,0xf0001800,,
csr_base,i2c0,0xf0002000,,
csr_base,identifier_mem,0xf0002800,,
csr_base,leds,0xf0003000,,
csr_base,sdcard,0xf0003800,,
csr_base,sdram,0xf0004000,,
csr_register,ctrl_reset,0xf0000000,1,rw
csr_register,ctrl_scratch,0xf0000004,1,rw
csr_register,ctrl_bus_errors,0xf0000008,1,ro
csr_register,ddrphy_dly_sel,0xf0000800,1,rw
csr_register,ddrphy_rdly_dq_rst,0xf0000804,1,rw
csr_register,ddrphy_rdly_dq_inc,0xf0000808,1,rw
csr_register,ddrphy_rdly_dq_bitslip_rst,0xf000080c,1,rw
csr_register,ddrphy_rdly_dq_bitslip,0xf0000810,1,rw
csr_register,ddrphy_burstdet_clr,0xf0000814,1,rw
csr_register,ddrphy_burstdet_seen,0xf0000818,1,ro
csr_register,uart_rxtx,0xf0001000,1,rw
csr_register,uart_txfull,0xf0001004,1,ro
csr_register,uart_rxempty,0xf0001008,1,ro
csr_register,uart_ev_status,0xf000100c,1,ro
csr_register,uart_ev_pending,0xf0001010,1,rw
csr_register,uart_ev_enable,0xf0001014,1,rw
csr_register,uart_txempty,0xf0001018,1,ro
csr_register,uart_rxfull,0xf000101c,1,ro
csr_register,timer0_load,0xf0001800,1,rw
csr_register,timer0_reload,0xf0001804,1,rw
csr_register,timer0_en,0xf0001808,1,rw
csr_register,timer0_update_value,0xf000180c,1,rw
csr_register,timer0_value,0xf0001810,1,ro
csr_register,timer0_ev_status,0xf0001814,1,ro
csr_register,timer0_ev_pending,0xf0001818,1,rw
csr_register,timer0_ev_enable,0xf000181c,1,rw
csr_register,i2c0_w,0xf0002000,1,rw
csr_register,i2c0_r,0xf0002004,1,ro
csr_register,leds_out,0xf0003000,1,rw
csr_register,sdcard_phy_card_detect,0xf0003800,1,ro
csr_register,sdcard_phy_clocker_divider,0xf0003804,1,rw
csr_register,sdcard_phy_init_initialize,0xf0003808,1,rw
csr_register,sdcard_phy_cmdr_timeout,0xf000380c,1,rw
csr_register,sdcard_phy_dataw_status,0xf0003810,1,ro
csr_register,sdcard_phy_datar_timeout,0xf0003814,1,rw
csr_register,sdcard_phy_settings,0xf0003818,1,rw
csr_register,sdcard_core_cmd_argument,0xf000381c,1,rw
csr_register,sdcard_core_cmd_command,0xf0003820,1,rw
csr_register,sdcard_core_cmd_send,0xf0003824,1,rw
csr_register,sdcard_core_cmd_response,0xf0003828,4,ro
csr_register,sdcard_core_cmd_event,0xf0003838,1,ro
csr_register,sdcard_core_data_event,0xf000383c,1,ro
csr_register,sdcard_core_block_length,0xf0003840,1,rw
csr_register,sdcard_core_block_count,0xf0003844,1,rw
csr_register,sdcard_block2mem_dma_base,0xf0003848,2,rw
csr_register,sdcard_block2mem_dma_length,0xf0003850,1,rw
csr_register,sdcard_block2mem_dma_enable,0xf0003854,1,rw
csr_register,sdcard_block2mem_dma_done,0xf0003858,1,ro
csr_register,sdcard_block2mem_dma_loop,0xf000385c,1,rw
csr_register,sdcard_block2mem_dma_offset,0xf0003860,1,ro
csr_register,sdcard_mem2block_dma_base,0xf0003864,2,rw
csr_register,sdcard_mem2block_dma_length,0xf000386c,1,rw
csr_register,sdcard_mem2block_dma_enable,0xf0003870,1,rw
csr_register,sdcard_mem2block_dma_done,0xf0003874,1,ro
csr_register,sdcard_mem2block_dma_loop,0xf0003878,1,rw
csr_register,sdcard_mem2block_dma_offset,0xf000387c,1,ro
csr_register,sdcard_ev_status,0xf0003880,1,ro
csr_register,sdcard_ev_pending,0xf0003884,1,rw
csr_register,sdcard_ev_enable,0xf0003888,1,rw
csr_register,sdram_dfii_control,0xf0004000,1,rw
csr_register,sdram_dfii_pi0_command,0xf0004004,1,rw
csr_register,sdram_dfii_pi0_command_issue,0xf0004008,1,rw
csr_register,sdram_dfii_pi0_address,0xf000400c,1,rw
csr_register,sdram_dfii_pi0_baddress,0xf0004010,1,rw
csr_register,sdram_dfii_pi0_wrdata,0xf0004014,2,rw
csr_register,sdram_dfii_pi0_rddata,0xf000401c,2,ro
csr_register,sdram_dfii_pi1_command,0xf0004024,1,rw
csr_register,sdram_dfii_pi1_command_issue,0xf0004028,1,rw
csr_register,sdram_dfii_pi1_address,0xf000402c,1,rw
csr_register,sdram_dfii_pi1_baddress,0xf0004030,1,rw
csr_register,sdram_dfii_pi1_wrdata,0xf0004034,2,rw
csr_register,sdram_dfii_pi1_rddata,0xf000403c,2,ro
constant,config_platform_name,gsd_orangecrab,,
constant,config_clock_frequency,64000000,,
constant,config_cpu_has_interrupt,None,,
constant,config_cpu_reset_addr,0,,
constant,config_cpu_count,1,,
constant,config_cpu_isa,rv32i2p0_ma,,
constant,config_cpu_mmu,sv32,,
constant,config_cpu_dcache_size,4096,,
constant,config_cpu_dcache_ways,1,,
constant,config_cpu_dcache_block_size,64,,
constant,config_cpu_icache_size,4096,,
constant,config_cpu_icache_ways,1,,
constant,config_cpu_icache_block_size,64,,
constant,config_cpu_dtlb_size,4,,
constant,config_cpu_dtlb_ways,4,,
constant,config_cpu_itlb_size,4,,
constant,config_cpu_itlb_ways,4,,
constant,config_cpu_type_vexriscv_smp,None,,
constant,config_cpu_variant_linux,None,,
constant,config_cpu_family,riscv,,
constant,config_cpu_name,vexriscv,,
constant,config_cpu_human_name,VexRiscv SMP-LINUX,,
constant,config_cpu_nop,nop,,
constant,config_bios_no_build_time,None,,
constant,config_identifier,LiteX SoC on OrangeCrab,,
constant,config_csr_data_width,32,,
constant,config_csr_alignment,32,,
constant,config_csr_ordering_big,None,,
constant,config_bus_standard,wishbone,,
constant,config_bus_data_width,32,,
constant,config_bus_address_width,32,,
constant,config_bus_bursting,0,,
constant,config_cpu_interrupts,4,,
constant,sdcard_interrupt,3,,
constant,timer0_interrupt,2,,
constant,uart_interrupt,1,,

## Generated memory map

//--------------------------------------------------------------------------------
// Auto-generated by LiteX (97ed83b6d) on 2026-06-23 06:06:53
//--------------------------------------------------------------------------------
#ifndef __GENERATED_MEM_H
#define __GENERATED_MEM_H

#ifndef OPENSBI_BASE
#define OPENSBI_BASE 0x40f00000L
#define OPENSBI_BASE_VA 0x40f00000L
#define OPENSBI_SIZE 0x00080000
#endif

#ifndef PLIC_BASE
#define PLIC_BASE 0xf0c00000L
#define PLIC_BASE_VA 0xf0c00000L
#define PLIC_SIZE 0x00400000
#endif

#ifndef CLINT_BASE
#define CLINT_BASE 0xf0010000L
#define CLINT_BASE_VA 0xf0010000L
#define CLINT_SIZE 0x00010000
#endif

#ifndef ROM_BASE
#define ROM_BASE 0x00000000L
#define ROM_BASE_VA 0x00000000L
#define ROM_SIZE 0x00010000
#endif

#ifndef SRAM_BASE
#define SRAM_BASE 0x10000000L
#define SRAM_BASE_VA 0x10000000L
#define SRAM_SIZE 0x00001800
#endif

#ifndef MAIN_RAM_BASE
#define MAIN_RAM_BASE 0x40000000L
#define MAIN_RAM_BASE_VA 0x40000000L
#define MAIN_RAM_SIZE 0x20000000
#endif

#ifndef CSR_BASE
#define CSR_BASE 0xf0000000L
#define CSR_BASE_VA 0xf0000000L
#define CSR_SIZE 0x00010000
#endif

#ifndef MEM_REGIONS
#define MEM_REGIONS "OPENSBI   0x40f00000 0x80000 \nPLIC      0xf0c00000 0x400000 \nCLINT     0xf0010000 0x10000 \nROM       0x00000000 0x10000 \nSRAM      0x10000000 0x1800 \nMAIN_RAM  0x40000000 0x20000000 \nCSR       0xf0000000 0x10000 "
#endif

#ifndef MEM_REGIONS_DETAILS
#define MEM_REGIONS_DETAILS "Region   Origin     End        Size \nOPENSBI  0x40f00000 0x40f7ffff 0x80000 \nPLIC     0xf0c00000 0xf0ffffff 0x400000 \nCLINT    0xf0010000 0xf001ffff 0x10000 \nROM      0x00000000 0x0000ffff 0x10000 \nSRAM     0x10000000 0x100017ff 0x1800 \nMAIN_RAM 0x40000000 0x5fffffff 0x20000000 \nCSR      0xf0000000 0xf000ffff 0x10000 "
#endif
#endif

## Generated variables

TRIPLE=riscv64-linux-gnu
CPU=vexriscv
CPUFAMILY=riscv
CPUFLAGS= -march=rv32i2p0_ma -mabi=ilp32 -D__vexriscv_smp__ -D__riscv_plic__
CPUENDIANNESS=little
CLANG=0
CPU_DIRECTORY=/mnt/storage/ext/litex-src/litex/litex/soc/cores/cpu/vexriscv_smp
SOC_DIRECTORY=/mnt/storage/ext/litex-src/litex/litex/soc
export BUILDINC_DIRECTORY
BUILDINC_DIRECTORY=/mnt/storage/see/1-c0d3/vhdl/lolv/build/orange_crab/software/include
BIOS_DIRECTORY=/mnt/storage/ext/litex-src/litex/litex/soc/software/bios
BIOS_CONSOLE_LITE=1

## Gateware summary

Baseline stock OrangeCrab Linux gateware built successfully.

Key observed utilization from nextpnr:

- TRELLIS_COMB: 17814 / 83640, about 21%
- TRELLIS_FF: 8186 / 83640, about 9%
- DP16KD: 29 / 208, about 13%
- MULT18X18D: 4 / 156, about 2%
- EHXPLLL: 2 / 4, about 50%
- TRELLIS_IO: 73 / 365, about 20%

Timing observed from nextpnr:

- sys_clk target: 64.00 MHz
- sys_clk achieved max frequency: about 65.83 MHz
- sys_clk timing: PASS at 64.00 MHz

Bitstream packaging:

- ecppack used --compress
- orange_crab.bit generated
- orange_crab.bit.dfu generated
- orange_crab.svf generated

## ecppack command

5:ecppack  --bootaddr 0    --compress  orange_crab.config --svf orange_crab.svf --bit orange_crab.bit

