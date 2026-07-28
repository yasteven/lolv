
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

**OWP2** (`rust/spis/oled_web_pipe`) — small OLED draw commands. Jetson side
only; the receiver lives in `lolv_actors` on the chardev.

```
BEGIN(seq,len)           -> READY(seq)
[frame...]                                      one burst
END(seq)                 -> OK(seq,crc16) | BAD(seq)
POLL                     -> FLUSHED(watermark24)    v2.1, optional
```

`OK` means *committed to the OrangeCrab framebuffer*. It says nothing about
the panel: the I2C actor flushes on its own tick, up to a frame later.
`FLUSHED` is the second stage and means the I2C write landed.

It is a **watermark, not a per-command ack**, because the I2C actor
coalesces — 500 brush points become one page write, so there is no
per-command flush to report. One reply retires every pending command at
once. The counter is 24 bits and wraps; compare with `watermark_reached`
(RFC 1982 style), never with `>=`. A receiver that predates this never
answers `POLL`, the short poll timeout expires, and the poller disables
itself for the session.

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
rust/spis/lolv_oled_control     Jetson controller: pipe, framebuffers, ids,
                                fonts, bitmap tiling, flush watermark
rust/oled/tiny_128x64           framebuffer (runtime-dimensioned), draw
                                commands, SH1106/SSD1306
rust/oled/lolv_actors           SPI actor + I2C actor + lolv_oled_backend
rust/oled/axum_serve            web frontend (Jetson); a client of
                                lolv_oled_control, not the SPI owner
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

**The charge pump is the thing that breaks.** Lighting most of the panel is a
current load step; on a marginal supply the controller brown-out resets,
loses its configuration, and NAKs every write until re-initialised. Plain
write retries can never heal that — only a re-init can. Three rules fell out
of this, and they are all load-shaping:

- Never rewrite the whole framebuffer to invert. Use the controller's own
  `0xA7`/`0xA6` (`DisplayInvert`): one command byte, no page traffic.
- Repaint with the display OFF. The init sequence ends in `0xAF`, so a naive
  recovery drives a fully-lit panel through an 88-transaction burst — the
  same condition that broke it.
- Apply contrast/invert/power AFTER the pixels, and back off exponentially
  between recovery attempts. Retrying a full repaint every tick is a solid
  wall of I2C traffic that never lets the supply recover.

None of that is a *fix*, it is load-shaping. The fix is electrical.

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
- Shapes on the wire: `Circle`, `Ellipse`, `Bitmap` (1-bit, MSB-first,
  byte-padded rows) — `Bitmap` is the escape hatch that makes text work
- **Controller split**: `lolv_oled_control` owns the pipe, the optimistic and
  confirmed framebuffers, ids and the CRC resync; `axum_serve` is a client
- **Runtime-dimensioned framebuffer** — `with_size(w, h)`, page-major layout
  unchanged, `--width`/`--height` on both ends. `DrawCommand` carries no
  dimensions; `ReplaceFramebuffer` is validated against the receiver's size
- **Text** rasterised on the Jetson (fontdue) and shipped as `Bitmap`.
  `POST /text` returns the bits so the browser previews the *exact* pixels —
  canvas `fillText` and fontdue disagree at 8–16 px
- **Bitmap tiling** against the 2048-byte wire MTU, sized by actually
  encoding each candidate band rather than modelling bincode's layout
- **Flush watermark** (`POLL`/`FLUSHED`): the browser's 100% now means the
  I2C write landed, not just that the command was committed
- Frontend shape + text tools, live drag preview, shift quantisation,
  42/69/100 progress states
- **Panel backpressure removed** — the I2C actor is fed by a `watch` of panel
  state, not an mpsc of commands, so the SPI task can never block on a sick
  panel (it used to, and it killed the whole link)
- `spi_oled_backend` retired; `lolv_oled_backend` is the only OLED backend

### Open bugs

Three things are known broken. Read these before starting anything new.

#### 1. Panel still flickers

Dirty-page tracking cut a full repaint to the pages that changed, but a
*page* is still 128 bytes and ~11 I2C transactions, and the bus is bitbanged
at ~90 kHz. A full repaint is ~100 ms, which is long enough to see the panel
update in bands. Load-shaping (see **OLED reality**) made the brown-out
storms rarer; it did not make the bus faster.

Next steps, cheapest first:

- **Dirty column ranges within a page.** `flush_one_page` writes all 128
  columns of any page it touches. A brush stroke usually touches a handful.
  Track min/max dirty column per page and set the column address to match —
  the addressing commands already exist, only the range is hardcoded. This
  is pure software and should be the biggest single win for interactive
  drawing.
- **A hardware I2C master in the gateware.** LiteX ships one. Bitbang at
  90 kHz against 400 kHz fast mode is a >4x cut in flush time and it stops
  burning the CPU on bit timing. This is also the prerequisite for the
  multi-OLED work below.
- **Electrical.** 100 µF bulk plus 100 nF right at the module's VCC/GND, and
  scope the 3.3 V rail during a full repaint. If it sags, nothing in software
  will fix this properly.

#### 2. `DisplayInvert` fails at the web ↔ backend boundary

The browser sends `{"cmd":"display_invert"}` but `BrowserCommand` carries
`#[serde(tag = "cmd", rename_all = "lowercase")]`, which lowercases the whole
identifier with no separator — so serde is looking for `displayinvert`. The
command fails to deserialise and the websocket replies with
`{"kind":"error","message":"bad command: ..."}`.

Fixed by naming the variant explicitly rather than relying on the rename
rule. **Worth a rule:** any multi-word `BrowserCommand` variant needs an
explicit `#[serde(rename = "...")]`, because `lowercase` silently produces
a name nobody would guess. There is no compile-time check tying the JS
strings to the enum; a round-trip test over the JSON the frontend actually
emits would catch the next one.

#### 3. Drawing near the bottom lands at the top

Objects drawn low on the canvas appear at the top of the panel. Vertical
origin or height is wrong somewhere, and it is **not yet diagnosed** — do
not assume the cause. There are three places it could be, and they are
cleanly separable:

```sh
# 1. Draw a mark at a known low row, then dump the FRAMEBUFFER as ASCII art.
curl -X POST localhost:8080/text -H 'content-type: application/json' \
  -d '{"x":2,"y":56,"text":"LOW","size_px":8}'
curl -s localhost:8080/screenshot | tail -n +3 | tr -d ' ' | tr '01' '.#'
```

- Mark appears **low in the PBM** and low on the panel → not a bug, look
  again at what was actually clicked.
- Mark appears **low in the PBM** but high on the panel → the panel side:
  page addressing in `flush_one_page`, display offset (`0xD3`), start line
  (`0x40`), or multiplex ratio (`0xA8`) in the init sequence.
- Mark appears **high in the PBM** → the Jetson side, and since `set_pixel`
  clips rather than wraps, suspect the browser's `xy()` — it divides by
  `getBoundingClientRect().height`, which is wrong if the `#stack`
  `aspect-ratio` did not apply. Check `/stats` agrees with the backend's
  `--height` too: a mismatch there is silently clipped, not reported.

Note that `set_pixel` cannot wrap — it bounds-checks against `width`/
`height` and returns. So a true wrap has to come from the panel's own
addressing, not from the framebuffer.

### Todo

- **Incremental commit in ASI** — hash and write per chunk instead of at
  `DONE`. Currently ~1/3 of wall time is SHA-256 + SD write after the last
  chunk. `sha2::Digest::update()` per chunk, payload streamed behind the
  header.
- **Re-run the speed sweep** (`debug_step_00_asi_speed_sweep.sh`) now that
  the handshake is cheap, and sweep the chardev receiver specifically
  (`RECEIVER=chardev`, the default) — the two receivers have different
  ceilings. The cable has a real ~1% error floor at 4 MHz; 8 MHz fails CRC.
  Shorter leads and a ground return alongside the clock are the physical fix.
- **Dithered shades** as a parameter on primitives. 1 bpp means spatial
  dithering is the only route to grey.
- **Multi-line and aligned text.** `rasterize` deliberately rejects newlines
  rather than guessing line spacing; layout is the caller's decision.
- **`lolv_spi` service** — systemd unit with a `flock` so ASI and the OLED
  backend cannot both hold the mailbox. Right now the board scripts guard
  this with a `pidof` check, which is advisory only. Userspace; a kernel
  module buys nothing here.
- **I2C kernel driver** for multiple OLEDs.
- **`aii`** — ASI-over-I2C for touchscreen input. Design for small messages;
  ~90 kHz I2C is ~45x slower than the SPI link.
- **The mirror system** — I2C for Jetson↔OrangeCrab, an SPI touchscreen on
  the OrangeCrab, drawing on the touchscreen and displaying in the browser.
  This is the same system with the transport swapped and the source/sink
  traded, *provided* the controller stays a hub: N command sources, N
  subscribers, one framebuffer, transport behind a trait. The `POLL`/
  `FLUSHED` exchange is already the upstream path this needs — touchscreen
  events reach a polling master the same way a watermark does, so it is a
  new message type rather than a new transport.

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
./tools/build_step_08_build_oled_backends.sh      # BOTH halves: Jetson + rv32
./tools/build_step_09_deploy_oled_backend_via_asi_chardev.sh
./tools/connect_over_uart.sh                      # serial console
./tools/run_00_lolv_oled_axum.sh                  # Jetson web frontend
./tools/debug_step_00_asi_speed_sweep.sh          # find the max clock
./tools/misc_step_find_orangecrab_sd_card.sh      # identify the card
```

`build_step_*` are ordered and each depends on the last. `debug_step_*` and
`misc_step_*` are not part of the sequence: nothing depends on them, and the
sweep is interactive.

### What requires what

| you changed | rebuild | redeploy |
|---|---|---|
| `soc_linux.py` gateware | 01 | 02 (bitstream), 04 (new dtb) |
| `linux.config` or the driver | 03 | 04 |
| ASI Rust | 06 | 07 or send via a running receiver |
| OLED Rust (either end) | 08 | 09 |
| Jetson-only Rust (`axum_serve`) | `build_host.sh` | nothing |

`lolv_oled_control` lives under `rust/spis`, so `cargo test --workspace` in
`rust/oled` does **not** reach it. `build_step_08` and `tools/build_host.sh`
test it explicitly; a bare workspace test will silently skip text,
tiling and watermark coverage.

Re-synthesising does **not** require a kernel rebuild. The DTB does change,
so redeploy it. The `spi_ext` IRQ number lives in the DTB, not the Image.

**Sender and receiver share a protocol version.** `build_step_06` builds both
ASI binaries for exactly this reason, and `build_step_08` does the same for
the OLED pair — a stale host against a fresh rv32 receiver mis-frames
silently. Keep a copy of the old host binary before a protocol change, or
bootstrap over SD (`build_step_07`).

`DrawCommand` is bincode with **positional variant indices**. New commands go
at the END of the enum; inserting one anywhere else silently renumbers every
command after it, and the failure looks like corruption rather than a
version skew.

### On the OrangeCrab

```sh
/root/8gb/tools/run_00_asi_rx_oled_chardev.sh      # ASI receiver (chardev)
/root/8gb/tools/run_01_asi_rx_oled_csr.sh          # fallback, /dev/mem only
/root/8gb/tools/run_02_lolv_oled_backend.sh        # OLED backend (root)
```

The receiver and the backend both drain the same SPI mailbox, so they cannot
run together — whichever reads a word first consumes it. The receive scripts
refuse to start while the backend is up (`STOP_BACKEND=1` to stop it first).
This is advisory; the real fix is the `flock` service in the todo list.

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
- A panel that has stopped answering at all is a different fault from one
  browning out under load. `i2cdetect` distinguishes them and the log does
  not: both look like a wall of NAKs.
- If the Jetson reports a dead peer, check whether the OrangeCrab is merely
  *busy* before blaming the link. A stale control word left on MISO —
  `last MISO=0xb7......` in a HELLO timeout, for instance — means the SPI
  task stopped being serviced, not that the wire broke.

