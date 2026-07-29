#!/usr/bin/env bash
# build_step_08_build_oled_backends.sh
#
# Build BOTH halves of the OLED stack:
#
#   Jetson     -- axum_serve, the web frontend.  Since the controller split
#                 it is a thin client of lolv_oled_control, which owns the
#                 SPI pipe, the framebuffers, the fonts and the watermark.
#   OrangeCrab -- lolv_oled_backend, the interrupt-driven /dev/lolv_spi
#                 backend (lolv_actors).
#
# Building them together is not a convenience.  They share the OWP2 wire
# version, and since the flush watermark (POLL/FLUSHED) that version moved:
# a stale host against a fresh rv32 receiver, or the reverse, mis-frames or
# silently loses flush confirmation.  Same reasoning as the ASI pair in
# step 06.
#
# Replaces the old steps 08 (spi_oled_backend over the /dev/mem CSR window)
# and 09.  The polling backend is retired; lolv_oled_backend is the only
# OLED backend now.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# rustdoc needs a TMPDIR that actually exists.  Prefer lolv/tmp so
# cargo/rustdoc scratch stays inside the repo tree.
# Localise temps under lolv/tmp (not /tmp). Ephemeral files are cleaned;
# results files under this dir are kept.
mkdir -p "$ROOT/tmp"
if [[ -z "${TMPDIR:-}" || ! -d "${TMPDIR}" ]]; then
    export TMPDIR="$ROOT/tmp"
fi
OLED="$(readlink -f "$ROOT/../../rust/oled")"
CONTROL="$(readlink -f "$ROOT/../../rust/spis/lolv_oled_control")"
HOST_BIN="$OLED/target/release/axum_serve"
RV32_BIN="$OLED/target/rv32ima-buildroot/release/lolv_oled_backend"

[[ -d "$OLED" ]]    || { echo "ERROR: missing $OLED" >&2; exit 1; }
[[ -d "$CONTROL" ]] || { echo "ERROR: missing $CONTROL (did the controller split run?)" >&2; exit 1; }

# build_host.sh enforces `cargo fmt --all -- --check`, so normalise first
# rather than failing a build over whitespace.  Both trees, because
# lolv_oled_control lives under rust/spis and is NOT a member of the
# rust/oled workspace.
echo "== formatting =="
( cd "$OLED"    && cargo +stable fmt --all )
( cd "$CONTROL" && cargo +stable fmt --all )

# rust/oled's `--workspace` does not reach across to rust/spis, so the
# controller's own tests -- text rasterisation, bitmap tiling, watermark
# arithmetic -- need their own invocation or they never run.
echo
echo "== host tests: lolv_oled_control (separate workspace under rust/spis) =="
( cd "$CONTROL" && cargo +stable test )

echo
echo "== Jetson build: axum_serve (also runs the rust/oled workspace tests) =="
"$OLED/tools/build_host.sh"

echo
echo "== OrangeCrab build: lolv_oled_backend =="
"$OLED/tools/build_orangecrab.sh"

for BIN in "$HOST_BIN" "$RV32_BIN"; do
    [[ -s "$BIN" ]] || { echo "ERROR: $BIN was not produced" >&2; exit 1; }
done

echo
echo "PASS: both halves built."
echo
file "$HOST_BIN"; sha256sum "$HOST_BIN"
file "$RV32_BIN"; sha256sum "$RV32_BIN"

cat <<'EOT'

Next:
  ./tools/build_step_09_deploy_oled_backend_via_asi_chardev.sh
      ship lolv_oled_backend to the OrangeCrab

  ./tools/run_00_lolv_oled_axum.sh
      run the Jetson side -- built in place, nothing to deploy

Deploy the OrangeCrab side BEFORE pointing a fresh axum_serve at it, or keep
the previous host binary to fall back on: sender and receiver share a
protocol version.
EOT
