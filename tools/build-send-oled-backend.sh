#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OLED="$(readlink -f "$ROOT/../../rust/oled")"
ASI="$(readlink -f "$ROOT/../../rust/spis/async_spi_interface")"
BACKEND="$OLED/target/rv32ima-buildroot/release/spi_oled_backend"

"$OLED/tools/build_orangecrab.sh"
[[ -x "$ASI/target/release/asi" ]] || { echo "ERROR: missing frozen Jetson ASI sender" >&2; exit 1; }
[[ -s "$BACKEND" ]] || { echo "ERROR: missing OrangeCrab OLED backend" >&2; exit 1; }

echo
echo "OrangeCrab must already be running:"
echo "  mkdir -p /root/8gb/oled/incoming"
echo "  /root/8gb/spis/bin/asi receive /root/8gb/oled/incoming"
echo
sha256sum "$BACKEND"
"$ASI/target/release/asi" --speed-hz 1000000 --chunk-bytes 4096 --timeout-seconds 300 send "$BACKEND"
echo
echo "PASS: backend transferred. On OrangeCrab run:"
echo "  mkdir -p /root/8gb/oled/bin"
echo "  install -m 755 /root/8gb/oled/incoming/spi_oled_backend /root/8gb/oled/bin/spi_oled_backend"
echo "  /root/8gb/oled/bin/spi_oled_backend"
