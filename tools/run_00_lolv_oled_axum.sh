#!/usr/bin/env bash
# Run the Jetson-side OLED web frontend. Unchanged transport: plain userspace
# spidev. The lolv_spi kernel driver is OrangeCrab-only (it binds the SPI
# slave), so nothing kernel-side is needed here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OLED="$(readlink -f "$ROOT/../../rust/oled")"
BIN="$OLED/target/release/axum_serve"

BIND="${OLED_BIND:-0.0.0.0:8080}"
SPI_DEVICE="${OLED_SPI_DEVICE:-/dev/spidev0.0}"
SPEED_HZ="${OLED_SPI_SPEED_HZ:-4000000}"

[[ -x "$BIN" ]] || "$OLED/tools/build_host.sh"
[[ -e "$SPI_DEVICE" ]] || { echo "ERROR: $SPI_DEVICE not present" >&2; exit 1; }

echo "axum_serve: bind=$BIND spi=$SPI_DEVICE speed=$SPEED_HZ"
echo "open http://$(hostname -I 2>/dev/null | awk '{print $1}'):${BIND##*:}/"
exec "$BIN" --bind "$BIND" --spi-device "$SPI_DEVICE" --speed-hz "$SPEED_HZ"
