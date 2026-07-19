#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR:-$(pwd -P)}"
EXTERNAL="${EXTERNAL:-/mnt/storage/ext}"
FPGA_ENV="$EXTERNAL/fpga-env.sh"
BUILD_DIR="$WORKDIR/build/orange_crab"
GATEWARE_DIR="$BUILD_DIR/gateware"
CSR_CSV="$BUILD_DIR/csr.csv"
BIT="$GATEWARE_DIR/orange_crab.bit"
DFU="$GATEWARE_DIR/orange_crab.bit.dfu"
BUILD_LOG="$BUILD_DIR/asi_synth.log"
SUMMARY="$BUILD_DIR/asi_synth_summary.txt"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ "$(basename "$WORKDIR")" == "lolv" ]] || die "WORKDIR must be the lolv repository root"
[[ -f "$WORKDIR/make.py" ]] || die "missing $WORKDIR/make.py"
[[ -f "$FPGA_ENV" ]] || die "missing FPGA environment: $FPGA_ENV (set EXTERNAL if needed)"

cd "$WORKDIR"
source "$FPGA_ENV"
hash -r

for command in python3 nextpnr-ecp5 yosys dfu-suffix; do
    command -v "$command" >/dev/null || die "required command is not on PATH after fpga-env.sh: $command"
done

mkdir -p "$BUILD_DIR"
START_EPOCH="$(date +%s)"

printf '%s\n' '== synthesize OrangeCrab ASI RX FIFO gateware =='
./make.py \
  --board=orange_crab \
  --device=85F \
  --revision=0.2 \
  --cpu-count=1 \
  --rootfs=mmcblk0p2 \
  --build \
  -- \
  --sdram-device=MT41K256M16 \
  2>&1 | tee "$BUILD_LOG"

[[ -s "$CSR_CSV" ]] || die "synthesis did not produce $CSR_CSV"
[[ -s "$BIT" ]] || die "synthesis did not produce $BIT"
BIT_EPOCH="$(stat -c %Y "$BIT")"
(( BIT_EPOCH >= START_EPOCH )) || die "bitstream timestamp predates this synthesis run"

printf '\n%s\n' '== verify stable and new SPI CSR addresses =='
python3 - "$CSR_CSV" <<'PY'
import csv
import sys

path = sys.argv[1]
expected = {
    "spi_ext_rx_data":                 0xF0005000,
    "spi_ext_tx_data":                 0xF0005004,
    "spi_ext_rx_length":               0xF0005008,
    "spi_ext_status":                  0xF000500C,
    "spi_ext_transaction_count":       0xF0005010,
    "spi_ext_control":                 0xF0005014,
    "spi_ext_raw_mosi":                0xF0005018,
    "spi_ext_raw_length":              0xF000501C,
    "spi_ext_raw_done":                0xF0005020,
    "spi_ext_raw_pins":                0xF0005024,
    "spi_ext_raw_cs_assert_count":     0xF0005028,
    "spi_ext_raw_cs_deassert_count":   0xF000502C,
    "spi_ext_raw_sck_rise_count":      0xF0005030,
    "spi_ext_raw_sck_fall_count":      0xF0005034,
    "spi_ext_raw_mosi_high_on_sck_rise": 0xF0005038,
    "spi_ext_raw_mosi_low_on_sck_rise":  0xF000503C,
    "spi_ext_rx_fifo_level":           0xF0005040,
    "spi_ext_rx_fifo_capacity":        0xF0005044,
    "spi_ext_rx_dropped_count":        0xF0005048,
}

actual = {}
with open(path, newline="", encoding="utf-8") as handle:
    for row in csv.reader(handle):
        if len(row) >= 3 and row[0] == "csr_register":
            actual[row[1]] = int(row[2], 0)

errors = []
for name, address in expected.items():
    found = actual.get(name)
    if found != address:
        shown = "missing" if found is None else f"0x{found:08x}"
        errors.append(f"{name}: expected 0x{address:08x}, found {shown}")
    else:
        print(f"PASS  {name:<42} 0x{address:08x}")

if errors:
    print("CSR CONTRACT FAILED:", file=sys.stderr)
    for error in errors:
        print(f"  {error}", file=sys.stderr)
    raise SystemExit(1)
PY

printf '\n%s\n' '== create fresh DFU artifact (not flashed) =='
cp -f "$BIT" "$DFU"
dfu-suffix -v 1209 -p 5af0 -a "$DFU"

{
    printf 'ASI RX FIFO synthesis summary\n'
    printf 'generated: %s\n' "$(date -Is)"
    printf 'bitstream: %s\n' "$BIT"
    printf 'dfu: %s\n' "$DFU"
    printf 'csr: %s\n' "$CSR_CSV"
    printf '\nResource/timing lines:\n'
    grep -hE 'TRELLIS_COMB|TRELLIS_FF|DP16KD|Max frequency|frequency.*MHz|Device utilisation|Device utilization' "$BUILD_LOG" || true
} | tee "$SUMMARY"

printf '\n%s\n' '== artifacts =='
ls -lh "$BIT" "$DFU" "$CSR_CSV" "$BUILD_LOG" "$SUMMARY"

printf '\n%s\n' 'PASS: ASI RX FIFO gateware synthesized and CSR contract verified.'
printf '%s\n' 'The DFU image was prepared but NOT flashed.'
