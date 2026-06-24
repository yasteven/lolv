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