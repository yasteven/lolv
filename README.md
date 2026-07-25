# LOLV — Linux-on-LiteX-VexRiscv on OrangeCrab, driven from a Jetson

A Jetson Orin Nano drives an OrangeCrab 85F over SPI. The OrangeCrab runs
Linux on a VexRiscv softcore built with LiteX, exposes a custom SPI-slave
peripheral to that Linux, and drives a 128x64 I2C OLED. Everything above the
wire is Rust.

```
Jetson Orin Nano                    OrangeCrab 85F (ECP5)
┌──────────────────┐                ┌────────────────────────────────┐
│ axum_serve (web) │                │ gateware: LiteX SoC            │
│ asi (sender)     │──SPI mode 0───▶│   VexRiscv SMP 4x @ 64 MHz     │
│ /dev/spidev0.0   │   4 MHz        │   SpiSlaveExt @ 0xf0005000     │
│ (userspace only) │                │   4096-word RX FIFO, IRQ 3     │
└──────────────────┘                │ Linux 6.x (Buildroot, SD card) │
                                    │   lolv_spi driver /dev/lolv_spi│
                                    │ asi --chardev (receiver)       │
                                    │ lolv_oled_backend ──I2C──▶ OLED│
                                    └────────────────────────────────┘
```

The Jetson side is **pure userspace** (`/dev/spidev0.0`). The kernel driver
exists only on the OrangeCrab, because it binds the SPI *slave* peripheral.

---

## Working with an AI assistant on this repo

These conventions exist because they were learned the hard way. Keep them.

**Changes arrive as self-contained Python scripts**, run from `lolv/`:

```bash
cd /path/to/vhdl/lolv && python3 some_change.py
```

- The script edits files and **self-deletes on success**.
- Edits are **anchored** to exact existing text and abort rather than clobber
  if the tree has moved on.
- Scripts are **dry-run verified** against a reconstruction of the real tree
  before delivery, and compile-tested where the toolchain allows.
- Scripts **do not run the build**. Synthesis and kernel builds need the
  `litex-venv` and environment that only the operator has set up correctly.
- `build_step_*` scripts are **self-contained**: they may call scripts in
  *other* directories (`rust/oled/tools/`, `rust/spis/.../tools/`) but never
  another `build_step_*` in the same `tools/` directory.
- **Assume the newest code.** Do not reason about which build might be stale;
  ask for a rebuild instead.
- Every rejection path in transport code must print *why*. Silent failures
  cost multiple debugging rounds.

**Regenerate the context dump** for a fresh session:

```bash
./cat_src.sh          # writes info/
```

---

## Architecture

### Gateware — `soc_linux.py`

`SpiSlaveExt` is a custom LiteX peripheral, CSRs based at `0xf0005000`:

| offset | register | purpose |
|--------|----------|---------|
| 0x00 | `rx_data` | head of RX FIFO |
| 0x04 | `tx_data` | word presented on MISO |
| 0x08 | `rx_length` | bit count of head word (32 = whole word) |
| 0x0c | `status` | rx_valid, cs_active, overrun, invalid_length |
| 0x14 | `control` | bit0 ack (pop), bit1 clear |
| 0x40 | `rx_fifo_level` / capacity / dropped | diagnostics |
| 0x4c | `ev_status` / `ev_pending` / `ev_enable` | interrupt |

SPI mode 0. Words are framed by **bit count, not CS** — a continuous-CS burst
of N words is 32·N clocks. The 4096-word FIFO absorbs a whole chunk.

Interrupt: `rx_available` is an `EventSourceLevel` on `rx_fifo.readable`;
`rx_overflow` is an `EventSourcePulse`. Routed to the PLIC by
`self.irq.add("spi_ext")`. **PLIC line 3, Linux virq 13** — both correct, they
are different numbering spaces. `generate_dts()` emits the `lolv,spi-ext` node
automatically, reading the IRQ from `csr.json` so it can never desync.

### Kernel — `extension/lolv_spi_dev/`

`lolv_spi` is a platform driver binding `compatible = "lolv,spi-ext"`. It
sleeps on the interrupt and exposes `/dev/lolv_spi` (root only, `crw-------`):

- `read()` — returns as many queued words as fit the buffer, big-endian,
  blocking on the IRQ. **Batch these.** One word per call costs ~4000 syscalls
  per 8 KiB chunk and makes the interrupt path slower than polling.
- `write(4)` — stage the MISO response word.
- `poll()` — POLLIN when the FIFO is non-empty; this is what makes tokio's
  `AsyncFd` work.
- `ioctl(LOLV_SPI_IOC_CLEAR)` — reset FIFO/framer/faults.

Built in-tree (`drivers/misc/lolv_spi/`, `CONFIG_LOLV_SPI=y`), not as a module.

### Transports

**ASI** (`rust/spis/async_spi_interface`) — chunked file transfer.

```
HELLO                    -> HELLO_ACK
per chunk:
  BEGIN(seq)             -> BEGIN_ACK(seq)      sender may repeat
  [INFO][payload...]                            one continuous-CS burst
  END(seq)               -> CHUNK_OK | CHUNK_BAD
DONE(count)              -> DONE_ACK
```

**OWP2** (`rust/spis/oled_web_pipe`) — small OLED draw commands.

```
BEGIN(seq,len)           -> READY(seq)
[frame...]                                      one burst
END(seq)                 -> OK(seq,crc16) | BAD(seq)
```

Two rules make both protocols sound, and both were learned by breaking them:

1. **Never identify a control word by value.** Payload is arbitrary binary and
   *will* equal a control word. Read exactly `ceil(len/4)` payload words and
   never inspect them.
2. **Discriminate structurally.** Control tags live in `0xA0..=0xAF`. ASI's
   INFO is `(len << 16) | crc16`, so its top byte is `len >> 8` < `0xA0` for
   any length under 40960. That makes "is this INFO?" exact, so the receiver
   can skip an *unbounded* run of duplicate control words. Fixed "budgets"
   are brittle and fail whenever the sender polls longer than the budget.

The sender polls: it re-sends each control word until it sees the reply, and
**every poll pushes another copy into the FIFO**. Receivers must expect
unbounded duplicates and re-answer a repeated `END` from a remembered result.

### Rust crates

```
rust/spis/async_spi_interface   ASI sender + both receivers (CSR and chardev)
rust/spis/oled_web_pipe         OWP2 transport (polling /dev/mem)
rust/spis/lolv_spi_async        AsyncFd chardev transport for tokio
rust/oled/tiny_128x64           framebuffer, draw commands, SH1106/SSD1306
rust/oled/lolv_actors           SPI actor + I2C actor + lolv_oled_backend
rust/oled/axum_serve            web frontend (Jetson)
rust/oled/spi_oled_backend      legacy polling backend (kept working)
rust/slog                       throttled logging, per-target atomic width
```

### Actor model (`lolv_actors`)

Split by **blocking behaviour**, not by peripheral:

- **SPI actor** — tokio task parked in the epoll reactor on `/dev/lolv_spi`,
  woken by the interrupt. Near-zero CPU idle, so it needs no core of its own.
  Half-duplex: one task serialises RX and TX.
- **I2C actor** — dedicated OS thread with its own `current_thread` runtime.
  Bitbang I2C writes block, and blocking work on a shared tokio worker stalls
  unrelated tasks.

Draw commands are applied to the framebuffer **on arrival**, so N commands
collapse into a fixed 1 KB of state. A tick (default 20 fps) then writes only
the pages that changed: 500 brush points in one pixel row = **one** page write.

`worker_threads(N)` does **not** pin anything. Real placement needs
`pin_current_thread` plus IRQ affinity (`echo 1 > /proc/irq/13/smp_affinity`).

### OLED reality

SH1106/SSD1306 are **1 bit per pixel**. No greyscale register; `0x81` is
global contrast. Spatial dithering is the only route to grey. Temporal
dithering is not viable — a full flush is ~100 ms over ~90 kHz bitbang I2C.

SH1106 needs column offset 2 (132-column RAM, 128 visible) and charge pump
`0xAD/0x8B`; SSD1306 uses offset 0 and `0x8D/0x14`. Wrong controller = shifted
image with wrapped garbage columns.

---

## Status

### Done

- Custom VHDL header probe through LiteX CSRs
- Buildroot Linux booting from SD on OrangeCrab 85F rev 0.2
- `SpiSlaveExt` gateware: continuous-CS 32-bit framing, 4096-word FIFO,
  diagnostic counters, verified mode-0 both directions
- 4-core VexRiscv SMP build, timing closed (65.83 MHz achieved vs 64.00 target)
- `spi_ext` interrupt to the PLIC, DTS node auto-generated
- `lolv_spi` kernel chardev driver, interrupt-driven, batched reads
- ASI file transfer, retry-forever, SHA-256 verified end to end
- ASI over the chardev: **43.8 → 98.6 KB/s**, retries 3 → 0, and now faster
  than the polling receiver (18.1 s vs 30.2 s for 1.78 MB)
- OWP2 v2: collapsed 5 exchanges to 2; OLED round trip **~1900 ms → ~11 ms**
- Interrupt-driven OLED backend with dirty-page flush and coalescing
- Web frontend with instant optimistic ghost drawing
- `slog` throttled logging working on rv32 (per-target atomic width)

### Todo

- **Incremental commit in ASI** — hash and write per chunk instead of at
  `DONE`. Currently ~1/3 of wall time is SHA-256 + SD write after the last
  chunk. `sha2::Digest::update()` per chunk, payload streamed behind the
  header.
- **Re-run the speed sweep** (`build_step_11`) now that the handshake is
  cheap. Note the cable has a real ~1% error floor at 4 MHz; 8 MHz fails CRC.
  Shorter leads and a ground return alongside the clock are the physical fix.
- **Drawing library** — a Jetson-side crate that owns shapes (circle, ellipse,
  quantised angles, squares), text, and bitmaps, emitting `DrawCommand`s.
  `axum_serve` becomes one client of it, not the SPI owner. Rasterise fonts on
  the Jetson and ship a `Bitmap` command; do not send TTFs over a 2048-byte
  wire to a 64 MHz core.
- **Frontend drag preview** for every shape.
- **Dithered shades** as a parameter on primitives.
- **`lolv_spi` service** — systemd unit with a `flock` so ASI and the OLED
  backend cannot both hold the mailbox. Userspace; a kernel module buys
  nothing here.
- **I2C kernel driver** for multiple OLEDs.
- **`aii`** — ASI-over-I2C for touchscreen input. Design for small messages;
  ~90 kHz I2C is ~45x slower than the SPI link.

---

## How it got here

Bring-up order, each step depending on the last:

1. **VHDL/LiteX integration** — header probe exposed through CSRs, proving the
   custom-peripheral path.
2. **Linux on the softcore** — Buildroot rootfs, SD partitioning, boot through
   LiteX BIOS → OpenSBI → Linux → init. See `README_litex_on_linux.md`.
3. **SPI slave gateware** — mode-0 capture, then a stable completed-transaction
   mailbox, then a 4096-word FIFO so a whole chunk could be absorbed without
   the CPU keeping up bit by bit.
4. **ASI** — chunked, CRC-checked, retry-forever file transfer over that
   mailbox, polling `/dev/mem` from userspace.
5. **OLED** — I2C panel driven from the OrangeCrab, commands arriving over SPI
   from a web frontend on the Jetson.
6. **Latency work** — the OLED round trip was ~1900 ms. Causes, in order
   found: a result word staged but never ACKed; five control exchanges per
   message where two suffice; a full-panel flush on every draw.
7. **Interrupts** — `SpiSlaveExt` had no IRQ, so everything polled. Added an
   `EventManager`, routed it to the PLIC, wrote the `lolv_spi` chardev driver,
   and moved both transports onto it.
8. **Throughput work** — larger chunks, then removing the INFO handshake, then
   batching chardev reads. The last one mattered most: one word per `read()`
   made the interrupt path 11x *slower* than polling.

---

## Making changes

### Build pipeline

```bash
./tools/build_step_00_init_env.sh                 # environment
./tools/build_step_01_generate_synth.sh           # bitstream + rv32.dtb
./tools/build_step_02_flash_gateware_over_usb_c.sh # DFU to the ECP5
./tools/build_step_03_generate_kernel.sh          # Linux Image
./tools/build_step_04_deploy_kernel_to_sd.sh      # Image + dtb -> SD
./tools/build_step_05_optional_generate_dtb.sh    # only for a hand-edited DTS
./tools/build_step_06_generate_asi.sh             # BOTH asi binaries
./tools/build_step_07_deploy_asi_via_sdcard.sh    # bootstrap asi via SD
./tools/build_step_08_deploy_oled_backend_via_asi.sh
./tools/build_step_09_generate_lolv_backend.sh
./tools/build_step_10_deploy_lolv_backend_via_asi.sh
./tools/build_step_11_asi_speed_sweep.sh          # find the max clock
./tools/connect_over_uart.sh                      # serial console
```

### What requires what

| you changed | rebuild | redeploy |
|---|---|---|
| `soc_linux.py` gateware | 01 | 02 (bitstream), 04 (new dtb) |
| `linux.config` or the driver | 03 | 04 |
| ASI Rust | 06 | 07 or send via a running receiver |
| OLED Rust | 09 | 10 |
| Jetson-only Rust (`axum_serve`) | `build_host.sh` | nothing |

Re-synthesising does **not** require a kernel rebuild. The DTB does change,
so redeploy it. The `spi_ext` IRQ number lives in the DTB, not the Image.

**Sender and receiver share a protocol version.** `build_step_06` builds both
for exactly this reason — a stale host sender against a fresh rv32 receiver
mis-frames silently. Keep a copy of the old host binary before a protocol
change, or bootstrap over SD (`build_step_07`).

### On the OrangeCrab

```sh
/root/8gb/tools/run_asi_rx_8gb_oled_incoming.sh    # ASI receiver
/root/8gb/tools/run_lolv_oled_backend.sh           # OLED backend (root)
```

`/dev/lolv_spi` is root-only. Per-core placement:

```sh
echo 1 > /proc/irq/13/smp_affinity
/root/8gb/oled/bin/lolv_oled_backend --spi-cpu 0 --i2c-cpu 1 --fps 20
```

### Debugging transport

- Every rejection prints its reason. If something is silent, that is the bug.
- Escalating retries mean state is accumulating; a constant rate means the
  cable.
- Compare against the CSR receiver (`asi` without `--chardev`) — it is the
  reference implementation and it works.
- `i2cdetect -y 0` with the backend **stopped**; a running backend holds the
  bus and gives a false empty scan. Busybox has no `pkill`; use `killall`.
