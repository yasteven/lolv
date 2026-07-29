#!/usr/bin/env bash
# build_step_09_deploy_oled_backend_via_asi_chardev.sh
#
# Ship lolv_oled_backend from the Jetson to the OrangeCrab over the ASI link,
# with the receiver on the interrupt-driven /dev/lolv_spi chardev rather than
# the old /dev/mem CSR polling path.
#
# Direction: Jetson (spidev master, plain userspace) -> OrangeCrab.  The
# Jetson half of the stack is built in place by step 08 and never needs
# transferring; only the rv32 binary crosses the wire.
#
# Chardev vs CSR receiver: same ASI protocol on the wire, different way of
# getting words out of the mailbox.  The chardev sleeps on the spi_ext
# interrupt and batches reads, which measured 43.8 -> 98.6 KB/s with retries
# 3 -> 0.  `asi` without --chardev is still the CSR reference receiver and is
# what to fall back to when the kernel path is suspect (missing driver, stale
# dtb after a re-synth, IRQ misrouted) -- it needs only gateware and
# /dev/mem.
#
# Self-contained per repo convention: calls scripts in OTHER directories
# (rust/oled/tools, rust/spis/.../tools) but never another build_step_* here.
set -euo pipefail

usage() {
    cat >&2 <<'EOT'
usage: build_step_09_deploy_oled_backend_via_asi_chardev.sh [SPEED_HZ [CHUNK_BYTES [TIMEOUT_SECONDS]]]

  SPEED_HZ         default 4000000   (4 MHz; the cable has a ~1% error floor
                                      here and 8 MHz fails CRC.  Drop to
                                      500000 if a run retries persistently)
  CHUNK_BYTES      default 8192      (multiple of 4, <= 16384 = 4096-word FIFO)
  TIMEOUT_SECONDS  default 60

Environment overrides: ASI_SPEED_HZ, ASI_CHUNK_BYTES, ASI_TIMEOUT_SECONDS,
OC_ASI_BIN, OC_INCOMING_DIR.
EOT
    exit 2
}

(( $# <= 3 )) || usage
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

SPEED_HZ="${1:-${ASI_SPEED_HZ:-4000000}}"
CHUNK_BYTES="${2:-${ASI_CHUNK_BYTES:-8192}}"
TIMEOUT_SECONDS="${3:-${ASI_TIMEOUT_SECONDS:-60}}"
for value in "$SPEED_HZ" "$CHUNK_BYTES" "$TIMEOUT_SECONDS"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: arguments must be positive integers" >&2; usage; }
done
(( CHUNK_BYTES % 4 == 0 ))     || { echo "ERROR: CHUNK_BYTES must be a multiple of 4 (FIFO word)" >&2; exit 2; }
(( CHUNK_BYTES <= 16384 ))     || { echo "ERROR: CHUNK_BYTES exceeds the 4096-word RX FIFO (16384 bytes)" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Localise temps under lolv/tmp (not /tmp). Ephemeral files are cleaned;
# results files under this dir are kept.
mkdir -p "$ROOT/tmp"
if [[ -z "${TMPDIR:-}" || ! -d "${TMPDIR}" ]]; then
    export TMPDIR="$ROOT/tmp"
fi
OLED="$(readlink -f "$ROOT/../../rust/oled")"
ASI="$(readlink -f "$ROOT/../../rust/spis/async_spi_interface")"
BIN="$OLED/target/rv32ima-buildroot/release/lolv_oled_backend"
SENDER="$ASI/target/release/asi"

# Paths on the board (partition 4 is mounted at /root/8gb).
OC_ASI_BIN="${OC_ASI_BIN:-/root/8gb/spis/bin/asi}"
OC_INCOMING_DIR="${OC_INCOMING_DIR:-/root/8gb/oled/incoming}"

"$OLED/tools/build_orangecrab.sh"
"$ASI/tools/build_host.sh"

[[ -x "$SENDER" ]] || { echo "ERROR: missing Jetson ASI sender: $SENDER" >&2; exit 1; }
[[ -s "$BIN" ]]    || { echo "ERROR: missing $BIN (run build_step_08 first)" >&2; exit 1; }

cat <<EOT

──────────────────────────────────────────────────────────────
  On the OrangeCrab, start the CHARDEV receiver now (as root --
  /dev/lolv_spi is crw-------):

    $OC_ASI_BIN --chardev --timeout-seconds $TIMEOUT_SECONDS receive $OC_INCOMING_DIR

  --chardev takes the device path optionally; bare means /dev/lolv_spi.
  Omit it entirely to fall back to the /dev/mem CSR receiver.
──────────────────────────────────────────────────────────────

Jetson ASI settings: speed_hz=$SPEED_HZ chunk_bytes=$CHUNK_BYTES timeout_seconds=$TIMEOUT_SECONDS retries=forever
EOT
sha256sum "$BIN"

"$SENDER" --speed-hz "$SPEED_HZ" --chunk-bytes "$CHUNK_BYTES" \
    --timeout-seconds "$TIMEOUT_SECONDS" send "$BIN"

cat <<EOT

PASS: lolv_oled_backend transferred.

OrangeCrab one-line install/start (root):
  mkdir -p /root/8gb/oled/bin && \\
  install -m 755 $OC_INCOMING_DIR/lolv_oled_backend /root/8gb/oled/bin/lolv_oled_backend && \\
  /root/8gb/oled/bin/lolv_oled_backend --i2c-bus /dev/i2c-0 --i2c-addr 0x3c --fps 20

Optional per-core placement (4-core build).  worker_threads does NOT pin;
this is what actually pins:
  echo 1 > /proc/irq/13/smp_affinity     # spi_ext virq -> cpu0
  /root/8gb/oled/bin/lolv_oled_backend --spi-cpu 0 --i2c-cpu 1 --fps 20

Non-default panel geometry (height must be a multiple of 8):
  /root/8gb/oled/bin/lolv_oled_backend --width 128 --height 32

Then on the Jetson:
  ./tools/run_00_lolv_oled_axum.sh

Confirm the watermark is live -- the websocket should show BOTH stages:
  {"kind":"confirmed","id":N,...}     committed to the OrangeCrab framebuffer
  {"kind":"flushed","through":N,...}  pixels actually written over I2C
If only "confirmed" ever appears, the running backend predates POLL/FLUSHED
and this deploy did not take effect.
EOT
