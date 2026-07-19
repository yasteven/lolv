#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

GATEWARE="$ROOT/build/orange_crab/gateware"
BIT="$GATEWARE/orange_crab.bit"
DFU="$GATEWARE/orange_crab.bit.dfu"
CSR="$ROOT/build/orange_crab/csr.csv"
SOC="$ROOT/soc_linux.py"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

for command in dfu-suffix dfu-util sha256sum sudo; do
    command -v "$command" >/dev/null 2>&1 || die "missing required command: $command"
done

[[ -s "$BIT" ]] || die "missing synthesized bitstream: $BIT"
[[ -s "$CSR" ]] || die "missing generated CSR map: $CSR"
[[ -f "$SOC" ]] || die "missing source: $SOC"

# Refuse an old mailbox build or a bitstream older than its source/map.
grep -q '^csr_register,spi_ext_rx_fifo_level,0xf0005040,' "$CSR" \
    || die "CSR map is not the ASI RX FIFO build (missing rx_fifo_level at 0xf0005040)"
grep -q '^csr_register,spi_ext_rx_fifo_capacity,0xf0005044,' "$CSR" \
    || die "CSR map is not the ASI RX FIFO build (missing rx_fifo_capacity at 0xf0005044)"
grep -q '^csr_register,spi_ext_rx_dropped_count,0xf0005048,' "$CSR" \
    || die "CSR map is not the ASI RX FIFO build (missing rx_dropped_count at 0xf0005048)"

python3 - "$BIT" "$SOC" "$CSR" <<'PY'
from pathlib import Path
import sys

bit, soc, csr = map(Path, sys.argv[1:])
newest_input = max(soc.stat().st_mtime_ns, csr.stat().st_mtime_ns)
if bit.stat().st_mtime_ns < newest_input:
    raise SystemExit(
        "ERROR: orange_crab.bit is older than soc_linux.py or csr.csv; "
        "rerun tools/synth-asi-rx-fifo.sh and wait for PASS"
    )
PY

echo "== verified ASI FIFO build =="
ls -lh -- "$BIT" "$CSR"
sha256sum -- "$BIT"

# Always make a new DFU wrapper. Never reuse a possibly stale .bit.dfu.
TMP_DFU="$(mktemp "$GATEWARE/.orange_crab.bit.dfu.XXXXXX")"
cleanup() {
    if [[ -n "${TMP_DFU:-}" && -f "$TMP_DFU" ]]; then
        rm -f -- "$TMP_DFU"
    fi
}
trap cleanup EXIT

cp -- "$BIT" "$TMP_DFU"
dfu-suffix -v 1209 -p 5af0 -a "$TMP_DFU"
mv -f -- "$TMP_DFU" "$DFU"
TMP_DFU=""

echo
echo "== fresh DFU wrapper =="
ls -lh -- "$DFU"
sha256sum -- "$DFU"

echo
echo "== locating OrangeCrab DFU target =="
DFU_LIST="$(sudo dfu-util -l 2>&1)"
printf '%s\n' "$DFU_LIST"
grep -qi '\[1209:5af0\]' <<<"$DFU_LIST" \
    || die "OrangeCrab 1209:5af0 is not visible; put the board in DFU mode"
grep -Eq 'alt=0([^0-9]|$).*Bitstream|alt=0([^0-9]|$)' <<<"$DFU_LIST" \
    || die "OrangeCrab DFU alt 0 bitstream target is not visible"

echo
echo "== flashing ASI gateware to OrangeCrab alt 0 (bitstream only) =="
FLASH_LOG="$(mktemp /tmp/flash-asi-orangecrab.XXXXXX.log)"
set +e
sudo dfu-util -d 1209:5af0 -a 0 -D "$DFU" 2>&1 | tee "$FLASH_LOG"
FLASH_RC=${PIPESTATUS[0]}
set -e

# Some OrangeCrab revisions disconnect immediately after manifestation.
# Accept that known final-status race only when manifestation reported OK.
if (( FLASH_RC != 0 )); then
    if grep -Eq 'state\(7\)[[:space:]]*=[[:space:]]*dfuMANIFEST, status\(0\)' "$FLASH_LOG"; then
        echo "NOTE: dfu-util lost the device after successful manifestation; accepting the known re-enumeration race."
    else
        rm -f -- "$FLASH_LOG"
        die "dfu-util failed with exit status $FLASH_RC"
    fi
fi
rm -f -- "$FLASH_LOG"

echo
echo "PASS: flashed fresh ASI RX FIFO bitstream to OrangeCrab DFU alt 0"
echo "Wait for Linux to boot, then run the ASI receiver test."
