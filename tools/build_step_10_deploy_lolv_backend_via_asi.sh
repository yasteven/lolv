#!/usr/bin/env bash
# build_step_10_deploy_lolv_backend_via_asi.sh
# Ship lolv_oled_backend to the OrangeCrab over the existing ASI link.
# The Jetson side stays plain userspace spidev -- the kernel driver is
# OrangeCrab-only (it binds the SPI *slave*), so nothing here needs root
# kernel changes on the Jetson.
set -euo pipefail

if (( $# != 3 )); then
    echo "usage: $0 SPEED_HZ CHUNK_BYTES TIMEOUT_SECONDS" >&2
    echo "example: $0 4000000 8192 30" >&2
    exit 2
fi
SPEED_HZ="$1"; CHUNK_BYTES="$2"; TIMEOUT_SECONDS="$3"
for value in "$SPEED_HZ" "$CHUNK_BYTES" "$TIMEOUT_SECONDS"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: arguments must be positive integers" >&2; exit 2; }
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OLED="$(readlink -f "$ROOT/../../rust/oled")"
ASI="$(readlink -f "$ROOT/../../rust/spis/async_spi_interface")"
BIN="$OLED/target/rv32ima-buildroot/release/lolv_oled_backend"

"$ROOT/tools/build_step_09_generate_lolv_backend.sh"
"$ASI/tools/build_host.sh"

[[ -x "$ASI/target/release/asi" ]] || { echo "ERROR: missing Jetson ASI sender" >&2; exit 1; }
[[ -s "$BIN" ]] || { echo "ERROR: missing $BIN" >&2; exit 1; }

echo
echo "OrangeCrab one-line receiver command:"
echo "  /root/8gb/spis/bin/asi --timeout-seconds $TIMEOUT_SECONDS receive /root/8gb/oled/incoming"
echo
echo "Jetson ASI settings: speed_hz=$SPEED_HZ chunk_bytes=$CHUNK_BYTES timeout_seconds=$TIMEOUT_SECONDS retries=forever"
sha256sum "$BIN"
"$ASI/target/release/asi" --speed-hz "$SPEED_HZ" --chunk-bytes "$CHUNK_BYTES" \
    --timeout-seconds "$TIMEOUT_SECONDS" send "$BIN"

cat <<'EOT'

PASS: lolv_oled_backend transferred.

OrangeCrab one-line install/start (run as root -- /dev/lolv_spi is crw-------):
  mkdir -p /root/8gb/oled/bin && \
  install -m 755 /root/8gb/oled/incoming/lolv_oled_backend /root/8gb/oled/bin/lolv_oled_backend && \
  /root/8gb/oled/bin/lolv_oled_backend --i2c-bus /dev/i2c-0 --i2c-addr 0x3c --fps 20

Optional per-core placement (4-core build). worker_threads does NOT pin;
this is what actually pins:
  echo 1 > /proc/irq/13/smp_affinity     # spi_ext virq -> cpu0
  /root/8gb/oled/bin/lolv_oled_backend --spi-cpu 0 --i2c-cpu 1 --fps 20

Jetson side is UNCHANGED -- same userspace spidev path as before:
  ./tools/run-oled-axum.sh
EOT
