#!/usr/bin/env bash
# build_step_09_generate_lolv_backend.sh
# Cross-build lolv_oled_backend (the /dev/lolv_spi interrupt-driven backend)
# for the OrangeCrab. Does not touch spi_oled_backend, which keeps working.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OLED="$(readlink -f "$ROOT/../../rust/oled")"
BIN="$OLED/target/rv32ima-buildroot/release/lolv_oled_backend"

echo "== host-side sanity: build + test the actor crates natively =="
( cd "$OLED" && cargo test -p lolv_actors )

echo
echo "== cross-building lolv_oled_backend for the OrangeCrab =="
"$OLED/tools/build_orangecrab.sh"

if [[ ! -s "$BIN" ]]; then
  echo
  echo "ERROR: $BIN was not produced." >&2
  echo "build_orangecrab.sh probably names its packages explicitly." >&2
  echo "Add lolv_actors to it, e.g. alongside the existing -p flags:" >&2
  echo "    -p lolv_actors --bin lolv_oled_backend" >&2
  exit 1
fi

echo
echo "PASS: built $BIN"
ls -lh "$BIN"
sha256sum "$BIN"
