#!/bin/sh
# Cross-compile axum_serve (which pulls in tiny_128x64) for the OrangeCrab.
#
# Run from this directory (extension/i2c_oled_tiny_126x64/).
set -eu

# --- adjust to match your board -------------------------------------------
TARGET="${TARGET:-riscv64gc-unknown-linux-musl}"
PROFILE="${PROFILE:-release}"
# ----------------------------------------------------------------------------

HERE="$(cd "$(dirname "$0")" && pwd)"
OLED_DIR="$HERE/../../../../rust/oled"

if [ ! -d "$OLED_DIR/axum_serve" ]; then
  echo "error: expected $OLED_DIR/axum_serve to exist." >&2
  echo "This script assumes the repo layout: 1-c0d3/rust/oled/{tiny_128x64,axum_serve}" >&2
  echo "alongside 1-c0d3/vhdl/lolv/extension/i2c_oled_tiny_126x64/." >&2
  exit 1
fi

cd "$OLED_DIR"

if command -v cross >/dev/null 2>&1; then
  echo "Building with cross for target $TARGET ($PROFILE)..."
  cross build --profile "$PROFILE" --target "$TARGET" -p axum_serve
else
  echo "cross not found -- falling back to plain cargo (requires the target"
  echo "and a suitable linker already installed: rustup target add $TARGET)."
  cargo build --profile "$PROFILE" --target "$TARGET" -p axum_serve
fi

BIN="$OLED_DIR/target/$TARGET/$PROFILE/axum_serve"
if [ -f "$BIN" ]; then
  echo "Built: $BIN"
else
  echo "warning: expected binary not found at $BIN -- check the profile name" >&2
  echo "(cargo uses 'debug' for the default dev profile, not 'dev')." >&2
fi
