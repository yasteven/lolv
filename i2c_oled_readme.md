<!-- LOLV_RUST_PATHS_START -->
## Rust sibling projects

From `lolv/`:

```text
$WORKDIR/../../rust/oled/
    OLED-specific project

$WORKDIR/../../rust/spis/
    parent directory containing independent SPI projects
```

`rust/spis/` is not itself a Cargo project.
<!-- LOLV_RUST_PATHS_END -->


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
export RUSTROOT="$WORKDIR/../../rust"
export OLED_DIR="$RUSTROOT/oled"
export SPIS_DIR="$RUSTROOT/spis"

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
export RUSTROOT="$WORKDIR/../../rust"
export OLED_DIR="$RUSTROOT/oled"
export SPIS_DIR="$RUSTROOT/spis"
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
