#!/usr/bin/env bash
set -euo pipefail

WORKDIR="$(pwd -P)"
PROJECT_DIR="$WORKDIR/../../rust/spis/async_spi_interface"
ASI="$PROJECT_DIR/target/release/asi"
TEST_FILE="/tmp/asi_small_transfer_test.txt"

if [[ ! -x "$ASI" || ! -f "$WORKDIR/soc_linux.py" ]]; then
    echo "ERROR: run this from lolv after asi_install.sh succeeds" >&2
    exit 1
fi

printf '%s\n' \
    'ASI reliable bootstrap transfer' \
    'Jetson -> OrangeCrab' \
    'CRC16 per chunk and SHA-256 before atomic commit.' \
    > "$TEST_FILE"

echo "== local source =="
ls -lh "$TEST_FILE"
sha256sum "$TEST_FILE"
echo
echo "OrangeCrab must already be running:"
echo "  /root/8gb/spis/bin/asi receive /root/8gb/spis/incoming"
echo
exec "$ASI" send "$TEST_FILE"

