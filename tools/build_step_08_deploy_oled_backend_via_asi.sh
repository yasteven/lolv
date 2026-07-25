#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
    echo "usage: $0 SPEED_HZ CHUNK_BYTES TIMEOUT_SECONDS" >&2
    echo "example: $0 500000 1024 30" >&2
    exit 2
fi

SPEED_HZ="$1"
CHUNK_BYTES="$2"
TIMEOUT_SECONDS="$3"
for value in "$SPEED_HZ" "$CHUNK_BYTES" "$TIMEOUT_SECONDS"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: arguments must be positive integers" >&2; exit 2; }
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OLED="$(readlink -f "$ROOT/../../rust/oled")"
ASI="$(readlink -f "$ROOT/../../rust/spis/async_spi_interface")"
BACKEND="$OLED/target/rv32ima-buildroot/release/spi_oled_backend"

"$OLED/tools/build_orangecrab.sh"
"$ASI/tools/build_host.sh"
[[ -x "$ASI/target/release/asi" ]] || { echo "ERROR: missing Jetson ASI sender" >&2; exit 1; }
[[ -s "$BACKEND" ]] || { echo "ERROR: missing OrangeCrab OLED backend" >&2; exit 1; }

echo
echo "OrangeCrab one-line receiver command:"
echo "/root/8gb/spis/bin/asi --timeout-seconds $TIMEOUT_SECONDS receive /root/8gb/oled/incoming"
echo
echo "Jetson ASI settings: speed_hz=$SPEED_HZ chunk_bytes=$CHUNK_BYTES timeout_seconds=$TIMEOUT_SECONDS retries=forever"
sha256sum "$BACKEND"
"$ASI/target/release/asi" --speed-hz "$SPEED_HZ" --chunk-bytes "$CHUNK_BYTES" --timeout-seconds "$TIMEOUT_SECONDS" send "$BACKEND"
echo
echo "PASS: backend transferred. OrangeCrab one-line install/start command:"
echo "mkdir -p /root/8gb/oled/bin && install -m 755 /root/8gb/oled/incoming/spi_oled_backend /root/8gb/oled/bin/spi_oled_backend && /root/8gb/oled/bin/spi_oled_backend"
