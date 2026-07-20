#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OLED="$(readlink -f "$ROOT/../../rust/oled")"
BIN="$OLED/target/release/axum_serve"
[[ -x "$BIN" ]] || "$OLED/tools/build_host.sh"
exec "$BIN" --bind "${OLED_BIND:-0.0.0.0:8080}" --spi-device "${OLED_SPI_DEVICE:-/dev/spidev0.0}" --speed-hz "${OLED_SPI_SPEED_HZ:-1000000}"
