#!/usr/bin/env bash
# build_step_02_flash_synth_to_usb.sh
#
# Flash the synthesized bitstream to the OrangeCrab over USB (DFU alt 0).
# Generalized from flash-asi-orangecrab.sh -- same DFU mechanics that work on
# this board -- but validates the current spi_ext build (incl. the ev_* IRQ
# registers) instead of the old ASI-only CSR map.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

GATEWARE="$ROOT/build/orange_crab/gateware"
BIT="$GATEWARE/orange_crab.bit"
DFU="$GATEWARE/orange_crab.bit.dfu"
CSR="$ROOT/build/orange_crab/csr.csv"
SOC="$ROOT/soc_linux.py"

die() { echo "ERROR: $*" >&2; exit 1; }

for command in dfu-suffix dfu-util sha256sum sudo; do
    command -v "$command" >/dev/null 2>&1 || die "missing required command: $command"
done

[[ -s "$BIT" ]] || die "missing synthesized bitstream: $BIT (run build_step_01 first)"
[[ -s "$CSR" ]] || die "missing generated CSR map: $CSR"
[[ -f "$SOC" ]] || die "missing source: $SOC"

# Validate this is the current spi_ext build: core FIFO CSRs AND the new
# EventManager IRQ registers must be present.
grep -q '^csr_register,spi_ext_rx_fifo_level,0xf0005040,'   "$CSR" || die "CSR map missing spi_ext_rx_fifo_level@0xf0005040"
grep -q '^csr_register,spi_ext_rx_dropped_count,0xf0005048,' "$CSR" || die "CSR map missing spi_ext_rx_dropped_count@0xf0005048"
grep -q '^csr_register,spi_ext_ev_status,0xf000504c,'  "$CSR" || die "CSR map missing spi_ext_ev_status@0xf000504c -- the IRQ gateware (015) isn't in this build"
grep -q '^csr_register,spi_ext_ev_pending,0xf0005050,' "$CSR" || die "CSR map missing spi_ext_ev_pending@0xf0005050"
grep -q '^csr_register,spi_ext_ev_enable,0xf0005054,'  "$CSR" || die "CSR map missing spi_ext_ev_enable@0xf0005054"

# Refuse a bitstream older than its source/map.
python3 - "$BIT" "$SOC" "$CSR" <<'PY'
from pathlib import Path
import sys
bit, soc, csr = map(Path, sys.argv[1:])
newest_input = max(soc.stat().st_mtime_ns, csr.stat().st_mtime_ns)
if bit.stat().st_mtime_ns < newest_input:
    raise SystemExit(
        "ERROR: orange_crab.bit is older than soc_linux.py or csr.csv; "
        "rerun build_step_01_generate_synth.sh and wait for PASS"
    )
PY

echo "== verified spi_ext IRQ build =="
ls -lh -- "$BIT" "$CSR"
sha256sum -- "$BIT"

# Always make a fresh DFU wrapper; never reuse a possibly stale .bit.dfu.
TMP_DFU="$(mktemp "$GATEWARE/.orange_crab.bit.dfu.XXXXXX")"
cleanup() { [[ -n "${TMP_DFU:-}" && -f "$TMP_DFU" ]] && rm -f -- "$TMP_DFU"; }
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
echo "== flashing gateware to OrangeCrab alt 0 (bitstream only) =="
FLASH_LOG="$(mktemp /tmp/build_step_02_flash.XXXXXX.log)"
set +e
sudo dfu-util -d 1209:5af0 -a 0 -D "$DFU" 2>&1 | tee "$FLASH_LOG"
FLASH_RC=${PIPESTATUS[0]}
set -e

# OrangeCrab disconnects right after manifestation; accept that race only when
# manifestation reported OK.
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
echo "PASS: flashed fresh spi_ext IRQ bitstream to OrangeCrab DFU alt 0"
echo "Next: build_step_03_generate_kernel.sh, then build_step_04_deploy_kernel_to_sd.sh."
