# OrangeCrab–Jetson SPI link

## Working directories

All project work starts from `lolv/`.

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

`rust/spis/` is a parent directory containing independent SPI-related projects. It is not itself a Cargo project or workspace.

Current/future locations:

```text
$WORKDIR/../../rust/oled/
    OLED-specific project

$WORKDIR/../../rust/spis/async_spi_interface/
    canonical async-message SPI bootstrap transport

$WORKDIR/../../rust/spis/<future-layer2-project>/
    future project-specific SPI control/data service
```

## Proven hardware

```text
OrangeCrab: 85F rev 0.2
Jetson:     Orin Nano
SPI mode:   0
Jetson:     master, /dev/spidev0.0
OrangeCrab: slave, LiteX SPISlave
sys_clk:    64 MHz
```

Correct wiring:

```text
Jetson pin 24 CS0  -> OrangeCrab GPIO:0  / N17 / cs_n
Jetson pin 23 SCK  -> OrangeCrab GPIO:16 / N16 / clk
Jetson pin 19 MOSI -> OrangeCrab GPIO:15 / R17 / mosi
Jetson pin 21 MISO <- OrangeCrab GPIO:14 / N15 / miso
Jetson pin 25 GND  -> OrangeCrab GND
```

The original receive failure was caused by SCK and MOSI being physically crossed.

## Gateware interface

`soc_linux.py` contains `SpiSlaveExt`, which wraps LiteX `SPISlave` with:

- a 4096-word EBR-backed completed-RX FIFO;
- one-word pop and whole-FIFO clear controls;
- transaction count;
- stable RX data and bit length;
- direct raw state;
- independent CS/SCK/MOSI counters.

The current hardware word is 32 bits. Larger software messages are fragmented above this layer.

```text
spi_ext base = 0xf0005000

0xf0005000  rx_data                         RO
0xf0005004  tx_data                         RW
0xf0005008  rx_length                       RO
0xf000500c  status                          RO
0xf0005010  transaction_count               RO
0xf0005014  control                         RW
0xf0005018  raw_mosi                        RO
0xf000501c  raw_length                      RO
0xf0005020  raw_done                        RO
0xf0005024  raw_pins                        RO
0xf0005028  raw_cs_assert_count             RO
0xf000502c  raw_cs_deassert_count           RO
0xf0005030  raw_sck_rise_count              RO
0xf0005034  raw_sck_fall_count              RO
0xf0005038  raw_mosi_high_on_sck_rise       RO
0xf000503c  raw_mosi_low_on_sck_rise        RO
0xf0005040  rx_fifo_level                   RO
0xf0005044  rx_fifo_capacity                RO
0xf0005048  rx_dropped_count                RO
```

Control:

```text
bit 0: pop exactly one word from the RX FIFO
bit 1: clear the FIFO, faults, transaction count, and raw counters
```

Status:

```text
bit 0: RX FIFO readable
bit 1: SPI busy
bit 2: RX FIFO overflow
bit 3: invalid transaction length
```

## Proven transactions

Jetson sent:

```text
ff aa 55 81
```

OrangeCrab observed:

```text
rx_data                        0xFFAA5581
rx_length                      0x00000020
transaction_count              0x00000001
raw_cs_assert_count            0x00000001
raw_cs_deassert_count          0x00000001
raw_sck_rise_count             0x00000020
raw_sck_fall_count             0x00000020
raw_mosi_high_on_sck_rise      0x00000012
raw_mosi_low_on_sck_rise       0x0000000E
```

That pattern contains exactly 18 one-bits and 14 zero-bits. MISO full-duplex transfer also passed with a known 32-bit `tx_data` pattern.

## Retained diagnostics

```text
tools/spi_diag_master.c
tools/read_spi_mailbox.sh
tools/spi_miso_jetson.sh
tools/spi_miso_orangecrab.sh
```

Build the reproducible Jetson diagnostic binary when needed:

```bash
cd "$WORKDIR"

cc -O2 -Wall -Wextra -Werror \
  tools/spi_diag_master.c \
  -o tools/spi_diag_master
```

Remove the compiled binary after testing:

```bash
rm -f "$WORKDIR/tools/spi_diag_master"
```

## Build and flash

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

A placement timing estimate can fail before the final routed timing passes. Use the final routed timing report.

Create a fresh DFU image:

```bash
cp -f \
  build/orange_crab/gateware/orange_crab.bit \
  build/orange_crab/gateware/orange_crab.bit.dfu

dfu-suffix \
  -v 1209 \
  -p 5af0 \
  -a \
  build/orange_crab/gateware/orange_crab.bit.dfu
```

Flash FPGA slot `alt 0`:

```bash
sudo dfu-util \
  -a 0 \
  -D build/orange_crab/gateware/orange_crab.bit.dfu
```

Do not flash the FPGA bitstream into `alt 1`.

## Linux and storage

Linux boots before login. The UART login prompt appears only after the kernel, `/sbin/init`, mounts, swap, syslog, and networking are running.

```text
/dev/mmcblk0p1   255 MiB   FAT boot partition
/dev/mmcblk0p2   1.5 GiB   root filesystem mounted at /
/dev/mmcblk0p3   4.0 GiB   swap
/dev/mmcblk0p4   8.5 GiB   data filesystem mounted at /root/8gb
```

Observed free space:

```text
/           about 1.3 GiB free
/root/8gb   about 8.0 GiB free
```

Check:

```sh
df -h / /root/8gb
mount | grep mmcblk0
cat /proc/partitions
```

Use `/root/8gb` for transferred binaries, staging files, logs, and application data.

## File-transfer protocol (ASI)

`rust/spis/async_spi_interface/` is the canonical bootstrap transport. Its public Rust API
is asynchronous typed message passing over bounded Tokio channels, while one dedicated
hardware-owner thread serializes SPI and MMIO access.

Jetson-to-OrangeCrab payload words use the gateware RX FIFO. The Jetson submits up to 64
four-byte SPI descriptors per kernel ioctl, with chip select toggled between descriptors so
the proven LiteX 32-bit slave completes one FIFO write per word. The normal defaults are
4 MHz, 8192-byte chunks, and a 1 ms control polling gap.

Reliability remains end-to-end: confirmed HELLO, sequence-numbered chunks, CRC16 per chunk,
ACK/NACK and retry, then whole-file SHA-256 verification, fsync, and atomic rename. A bulk
CRC rejection retries through the older paced word path. BSI is retired and is not part of
the ASI build, source reports, deployment, or acceptance tests.

Acceptance order is a short file, deterministic 256 KiB file, the cross-built ASI binary,
then a 20 MiB payload. Clock qualification proceeds at 1 MHz, 4 MHz, and 8 MHz; the final
default is the fastest setting that completes the repeated SHA-256 soak with zero retries.

## Next milestone

Synthesize the 4096-word RX FIFO image, verify the legacy and new CSR addresses, record EBR
and timing use, then flash FPGA slot `alt 0`. After reboot, cross-build ASI, deploy it once
through the SD card, and run the speed/volume acceptance ladder. Do not flash FPGA slot
`alt 1`.

## ASI 0.3 continuous-CS physical transport

Tegra accepted sixteen four-byte transfers in one ioctl but produced CS-high pulses too
short for the synchronized FPGA input. The measured result was a correct FIFO capacity,
no backlog, sticky status `0x8`, and a partial-word drop. Retrying through separate ioctls
worked but restored roughly one userspace round trip per word and was not acceptable for
binary deployment.

ASI 0.3 makes CS a block envelope. Gateware samples SPI mode 0 in the 64 MHz system clock
domain and enqueues each complete group of 32 bits, whether or not CS remains asserted.
The Jetson sends one descriptor containing up to the confirmed 4096-byte spidev buffer.
An 8192-byte protocol chunk therefore uses two data ioctls. CS deassertion on a non-32-bit
boundary remains a sticky diagnosed fault. The CSR bank and all existing offsets remain
unchanged.

The old OrangeCrab ASI 0.1 receiver remains wire-compatible for one bootstrap transfer.
After the continuous-CS image passes the small-file test, use it to receive the newly
cross-built ASI 0.3 binary and atomically replace `/root/8gb/spis/bin/asi`.
