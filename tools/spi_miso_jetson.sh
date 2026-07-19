#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

pattern="${1:-0xA55A3CC3}"
speed="${SPI_TEST_SPEED_HZ:-100000}"
device="${SPI_TEST_DEVICE:-/dev/spidev0.0}"

mapfile -t rows < <(
python3 - "$pattern" <<'PY'
import sys
value = int(sys.argv[1], 0)
if not 0 <= value <= 0xffffffff:
    raise SystemExit("pattern must fit in 32 bits")
raw = value.to_bytes(4, "big")
print(" ".join(f"0x{x:02x}" for x in raw))
print(" ".join(f"{x:02x}" for x in raw))
PY
)

send_bytes="${rows[0]}"
expected_rx="${rows[1]}"

echo "Jetson SPI MISO verification"
echo "device:      $device"
echo "speed:       $speed Hz"
echo "expected RX: $expected_rx"

set +e
output="$(
    sudo ./tools/spi_diag_master         --device "$device"         --speed "$speed"         --mode 0         $send_bytes 2>&1
)"
rc=$?
set -e

printf '%s\n' "$output"

if [[ $rc -ne 0 ]]; then
    echo "FAIL: spi_diag_master exited with status $rc" >&2
    exit "$rc"
fi

actual_rx="$(
    printf '%s\n' "$output" |
    sed -n 's/^rx=//p' |
    tail -1 |
    tr '[:upper:]' '[:lower:]' |
    xargs
)"

echo
if [[ "$actual_rx" == "$expected_rx" ]]; then
    echo "PASS: OrangeCrab -> Jetson MISO matched exactly: $actual_rx"
else
    echo "FAIL: MISO mismatch" >&2
    echo "expected: $expected_rx" >&2
    echo "actual:   $actual_rx" >&2
    exit 1
fi
