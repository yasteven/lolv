# i2c_oled_tiny_126x64 — build & deploy

Build/deploy scaffolding for the two Rust crates in
`1-c0d3/rust/oled/`:

- `tiny_128x64` — pure-Rust framebuffer, drawing primitives, and Linux-I2C
  driver for the panel. No async runtime, no web framework.
- `axum_serve` — HTTP + WebSocket server (paint frontend, REST API, live
  framebuffer sync) that depends on `tiny_128x64`.

## Scripts here

```
build.sh    cross-compile axum_serve (+ tiny_128x64) for the OrangeCrab target
deploy.sh   scp the binary + static/ to the OrangeCrab and restart the service
run-dev.sh  run axum_serve locally/headless for quick iteration, no panel needed
```

All three assume they're run from this directory and that
`../../../rust/oled/` exists (i.e. the layout is
`1-c0d3/rust/oled/{tiny_128x64,axum_serve}` alongside
`1-c0d3/vhdl/lolv/extension/i2c_oled_tiny_126x64/`, matching the git repo
layout, not the lolv-only checkout layout).

## Before first use

1. Confirm your OrangeCrab's actual Rust target triple. LiteX Linux on this
   class of board is typically riscv32/riscv64 + musl via buildroot. Check
   on the board itself:

   ```bash
   uname -m
   cat /proc/cpuinfo | head
   ```

   and set `TARGET` at the top of `build.sh` accordingly
   (e.g. `riscv64gc-unknown-linux-musl`, or `riscv64gc-unknown-linux-gnu` if
   your image is glibc-based). riscv32 linux targets are Tier 3 in Rust, so
   you may need a nightly toolchain or the buildroot-provided
   cross-toolchain directly instead of `cross`/`rustup target add`.

2. Set `ORANGECRAB_HOST` in `deploy.sh` (or export it before running) to
   whatever address the USB PPP link assigns, e.g. `192.168.7.2`.

## Typical flow

```bash
./run-dev.sh                 # sanity check on your dev machine, headless OK
./build.sh                   # cross-compile release binary
./deploy.sh                  # ship it + static/ to the board, restart it
```

Then open `http://<orangecrab-ip>/` in a browser.

## Systemd unit (if your image has systemd)

See `axum-serve.service` in this directory. Adjust `ExecStart` if you used a
different `--bind`/`--static-dir`, then:

```bash
scp axum-serve.service root@$ORANGECRAB_HOST:/etc/systemd/system/
ssh root@$ORANGECRAB_HOST "systemctl daemon-reload && systemctl enable --now axum-serve"
```
