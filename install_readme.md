# Install Notes

<!-- ORANGECRAB_REQUIREMENTS_START -->
## OrangeCrab Linux requirements

This section records the extra requirements discovered while building Linux-on-LiteX-VexRiscv for OrangeCrab.

The tested build shape is:

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

The `--` separator is required because `--sdram-device=...` is a board/SOC kwarg, not a top-level `make.py` option.

### External source/build directory

Keep large source trees, local tool installs, caches, generated CPU sources, and wrapper scripts outside this repository.

Use `LOEXSO` for the external local source directory:

```
export LOEXSO="$HOME/example"
mkdir -p "$LOEXSO"
```

`LOEXSO` means external source local.

A useful environment hook is:

```
export LOEXSO="${LOEXSO:-$HOME/example}"
export PATH="$LOEXSO/bin:$PATH"
```

If using a local FPGA environment script:

```
source "$LOEXSO/fpga-env.sh"
```

### Base system packages

```
sudo apt update

sudo apt install -y \
  build-essential \
  device-tree-compiler \
  wget \
  git \
  curl \
  gnupg \
  ca-certificates \
  python3-setuptools \
  dfu-util
```

### ECP5 FPGA toolchain

OrangeCrab uses a Lattice ECP5 FPGA. The bitstream build needs:

```
yosys
nextpnr-ecp5
ecppack / prjtrellis
dfu-util
```

These can come from OSS CAD Suite or another working ECP5 open-source FPGA toolchain install. Make sure the toolchain binaries are in `PATH` before running `make.py`.

### LiteX Python stack

Install the normal LiteX stack into the active Python environment:

```
migen
litex
litex-boards
litedram
liteeth
litescope
liteiclink
litesdcard
```

### OrangeCrab USB CDC ACM UART requirements

The OrangeCrab LiteX target uses the USB CDC ACM UART path. That path imports Amaranth and LUNA.

If the build fails with:

```
ModuleNotFoundError: No module named 'amaranth'
```

install:

```
python -m pip install -U amaranth
```

If the build fails with:

```
ModuleNotFoundError: No module named 'luna'
```

install:

```
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

### VexRiscv-SMP CPU data requirement

The Linux CPU is `vexriscv_smp`. If the build fails with:

```
pythondata-cpu-vexriscv_smp module not installed
No module named 'pythondata_cpu_vexriscv_smp'
```

do not rely on a flattened plain pip install. For OrangeCrab local VexRiscv-SMP generation, install `pythondata-cpu-vexriscv_smp` from a complete recursive editable checkout.

### Java / SBT requirement for VexRiscv-SMP netlist generation

Some VexRiscv-SMP configurations are pregenerated, but the OrangeCrab Linux build can request a CPU configuration that triggers local VexRiscv/SpinalHDL netlist generation.

If the build reaches:

```
Generating cluster netlist
/bin/sh: 1: sbt: not found
```

install Java and SBT.

Java:

```
sudo apt update
sudo apt install -y openjdk-17-jdk
```

SBT apt repository setup:

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

### VexRiscv-SMP pythondata recursive editable install

The `pythondata-cpu-vexriscv_smp` package must preserve its Git submodule metadata. A flattened install can import but still fail when SBT tries to use SpinalHDL/VexRiscv.

Broken symptoms include:

```
fatal: not a git repository: .../.git/modules/pythondata_cpu_vexriscv_smp/verilog/ext/SpinalHDL
```

or:

```
Neither build.sbt nor a 'project' directory in the current directory:
.../pythondata_cpu_vexriscv_smp/verilog/ext/VexRiscv
```

Fix by uninstalling any stale package, deleting the stale `site-packages` copy, cloning recursively, and installing editable:

```
source "$LOEXSO/fpga-env.sh"

export LOEXSO="${LOEXSO:-$HOME/example}"
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

The good verification shape is:

```
VexRiscv build.sbt: True
SpinalHDL build.sbt: True
VexRiscv .git: True
SpinalHDL .git: True
```

### Full discovered Python install set

From the active LiteX virtual environment:

```
python -m pip install -U amaranth
python -m pip install -U git+https://github.com/greatscottgadgets/luna.git
python -m pip install -U git+https://github.com/litex-hub/pythondata-software-picolibc.git
python -m pip install -U git+https://github.com/litex-hub/pythondata-software-compiler_rt.git
```

Install `pythondata-cpu-vexriscv_smp` with the recursive editable checkout method above, not the simple one-line pip install, because VexRiscv-SMP local generation needs the recursive Git submodule metadata.


### LiteX software data requirements

LiteX also needs packaged software data when generating BIOS/software include files.

If the build fails with:

```
ImportError: pythondata-software-picolibc module not installed! Unable to use picolibc software.
No module named 'pythondata_software_picolibc'
```

install:

```
python -m pip install -U git+https://github.com/litex-hub/pythondata-software-picolibc.git
```

If the build then fails with:

```
ImportError: pythondata-software-compiler_rt module not installed! Unable to use compiler_rt software.
No module named 'pythondata_software_compiler_rt'
```

install:

```
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

### Build command

From this repository:

```
export LOEXSO="${LOEXSO:-$HOME/example}"

if [ -f "$LOEXSO/fpga-env.sh" ]; then
  source "$LOEXSO/fpga-env.sh"
fi

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

### Known successful progress checkpoints

The OrangeCrab build should reach these checkpoints before gateware synthesis:

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

After the recursive editable `pythondata-cpu-vexriscv_smp` install and Java/SBT install, the build should enter SBT and compile SpinalHDL/VexRiscv sources. Scala/Java deprecation and exhaustiveness warnings are noisy but not necessarily fatal.
<!-- ORANGECRAB_REQUIREMENTS_END -->\n