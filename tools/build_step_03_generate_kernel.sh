#!/bin/bash
# build_step_003_generate_kernel.sh
#
# Run from lolv/. Rebuilds ONLY the kernel (rootfs/dtb/opensbi untouched)
# after a linux.config change, using the same LOEXSO/BR_OUT/fpga-env pattern
# as the original bring-up (rebuild_kernel_tun.sh), but with the required
# kernel config symbols parameterized instead of hardcoded to CONFIG_TUN.
#
# Default expectation is the lolv_spi driver: CONFIG_LOLV_SPI=y.  Override or
# extend with REQUIRE_CONFIGS (space-separated symbol=value pairs), e.g.:
#     REQUIRE_CONFIGS="CONFIG_LOLV_SPI=y CONFIG_TUN=y" ./build_step_003_generate_kernel.sh
#
# Env overrides: WORKDIR, EXTERNAL, LOEXSO (all default as below).

WORKDIR="${WORKDIR:-$(pwd)}"
EXTERNAL="${EXTERNAL:-/mnt/storage/ext}"
LOEXSO="${LOEXSO:-$EXTERNAL}"
BR_OUT="$WORKDIR/build/orange_crab/buildroot"
CFG="$WORKDIR/buildroot/board/litex_vexriscv/linux.config"
REQUIRE_CONFIGS="${REQUIRE_CONFIGS:-CONFIG_LOLV_SPI=y}"

echo "== pre-flight checks =="
echo "  WORKDIR:          $WORKDIR"
echo "  EXTERNAL:         $EXTERNAL"
echo "  LOEXSO:           $LOEXSO"
echo "  BR_OUT:           $BR_OUT"
echo "  linux.config:     $CFG"
echo "  REQUIRE_CONFIGS:  $REQUIRE_CONFIGS"
echo

OK=1

if [ ! -f "$EXTERNAL/fpga-env.sh" ]; then
  echo "MISSING: $EXTERNAL/fpga-env.sh -- set EXTERNAL=/path/to/ext before running."
  OK=0
fi

if [ ! -d "$LOEXSO/buildroot" ]; then
  echo "MISSING: $LOEXSO/buildroot -- set LOEXSO=/path/to/ext before running."
  OK=0
fi

if [ ! -d "$BR_OUT" ]; then
  echo "MISSING: $BR_OUT -- expected this from the original image build."
  OK=0
fi

if [ ! -f "$CFG" ]; then
  echo "MISSING: $CFG -- kernel config fragment not found."
  OK=0
else
  for pair in $REQUIRE_CONFIGS; do
    if ! grep -q "^${pair}\$" "$CFG" 2>/dev/null; then
      echo "MISSING: ${pair} in $CFG -- run setup_lolv_spi.py (or the relevant"
      echo "         config patch) first so the symbol is present."
      OK=0
    fi
  done
fi

if [ "$OK" != "1" ]; then
  echo
  echo "ABORTING: pre-flight checks failed -- nothing built."
  echo
  echo "done"
  exit 1
fi

echo "  all checks passed."
echo

echo "== sourcing fpga-env.sh =="
source "$EXTERNAL/fpga-env.sh"
hash -r
echo

echo "== cleaning LD_LIBRARY_PATH (Buildroot refuses to run otherwise) =="
export LD_LIBRARY_PATH="$(python3 - << 'PY'
import os
parts = os.environ.get("LD_LIBRARY_PATH", "").split(":")
clean = [p for p in parts if p not in ("", ".")]
print(":".join(clean))
PY
)"
echo "  LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
echo

cd "$WORKDIR" || { echo "ABORTING: cannot cd to $WORKDIR"; exit 1; }

echo "== forcing kernel reconfigure (picks up the patched linux.config) =="
START=$(date +%s)
make -C "$LOEXSO/buildroot" O="$BR_OUT" linux-reconfigure
RECONFIG_STATUS=$?
echo

if [ "$RECONFIG_STATUS" -ne 0 ]; then
  echo "ABORTING: linux-reconfigure failed (exit $RECONFIG_STATUS)."
  echo; echo "done"; exit 1
fi

echo "== verifying the live kernel .config picked up the change =="
KDIR=$(find "$BR_OUT/build" -maxdepth 1 -type d -name 'linux-*' ! -name 'linux-headers*' | head -1)
KCONFIG="$KDIR/.config"
for pair in $REQUIRE_CONFIGS; do
  grep -E "^${pair}\$" "$KCONFIG" || echo "  WARNING: ${pair} not found in $KCONFIG"
done
echo

echo "== rebuilding (running the full target, as the proven bring-up did) =="
make -C "$LOEXSO/buildroot" O="$BR_OUT"
BUILD_STATUS=$?
END=$(date +%s)
echo
echo "  elapsed: $(( (END - START) / 60 ))m $(( (END - START) % 60 ))s"
echo

if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "ABORTING: build failed (exit $BUILD_STATUS)."
  echo; echo "done"; exit 1
fi

echo "== relinking images/Image =="
ln -snf "$BR_OUT/images/Image" images/Image
ls -la images/Image
echo

echo "== confirming required configs made it into the final kernel config =="
for pair in $REQUIRE_CONFIGS; do
  grep -E "^${pair}\$" "$KCONFIG" || echo "  WARNING: ${pair} missing from final $KCONFIG"
done
echo

echo "BUILD OK. Next:"
echo "  - the DTS changed (spi_ext node), so also deploy the updated rv32.dtb"
echo "    alongside the new Image."
echo "  - copy the new Image onto the SD card's boot partition"
echo "    (tools/deploy-kernel-via-sdcard.sh)."
echo
echo "done"
