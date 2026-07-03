#!/bin/sh
# Run axum_serve on your dev machine, headless if there's no OLED here.
# Handy for iterating on the frontend/API without the OrangeCrab attached.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
OLED_DIR="$HERE/../../../../rust/oled"

cd "$OLED_DIR"
cargo run -p axum_serve -- \
  --bind "${BIND:-127.0.0.1:8080}" \
  --i2c-bus "${I2C_BUS:-/dev/i2c-0}" \
  --i2c-addr "${I2C_ADDR:-0x3c}" \
  --static-dir "$OLED_DIR/axum_serve/static"
