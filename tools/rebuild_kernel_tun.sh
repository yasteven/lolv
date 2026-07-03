#!/bin/bash
# Run from lolv/. Rebuilds ONLY the kernel (rootfs/dtb/opensbi untouched)
# after the linux.config patch, using the same LOEXSO/BR_OUT pattern from
# the original bring-up.

WORKDIR="${WORKDIR:-$(pwd)}"
EXTERNAL="${EXTERNAL:-/mnt/storage/ext}"
LOEXSO="${LOEXSO:-$EXTERNAL}"
BR_OUT="$WORKDIR/build/orange_crab/buildroot"

echo "== pre-flight checks =="
echo "  WORKDIR:  $WORKDIR"
echo "  EXTERNAL: $EXTERNAL"
echo "  LOEXSO:   $LOEXSO"
echo "  BR_OUT:   $BR_OUT"
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

CFG="$WORKDIR/buildroot/board/litex_vexriscv/linux.config"
if ! grep -q '^CONFIG_TUN=y' "$CFG" 2>/dev/null; then
  echo "MISSING: CONFIG_TUN=y in $CFG -- run patch_kernel_config_tun.sh first."
  OK=0
fi

if [ "$OK" != "1" ]; then
  echo
  echo "ABORTING pre-flight checks failed -- nothing built."
else
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

  cd "$WORKDIR"

  echo "== forcing kernel reconfigure (picks up the patched linux.config) =="
  START=$(date +%s)
  make -C "$LOEXSO/buildroot" O="$BR_OUT" linux-reconfigure
  RECONFIG_STATUS=$?
  echo

  if [ "$RECONFIG_STATUS" -ne 0 ]; then
    echo "ABORTING: linux-reconfigure failed (exit $RECONFIG_STATUS)."
  else
    echo "== verifying the live kernel .config picked up the change =="
    KCONFIG=$(find "$BR_OUT/build" -maxdepth 1 -type d -name 'linux-*' | head -1)/.config
    grep -E 'CONFIG_UNIX=|CONFIG_TUN=' "$KCONFIG" || echo "  not found in $KCONFIG (unexpected)"
    echo

    echo "== rebuilding (kernel package only needs to change, but running the"
    echo "== full target is what your original bring-up used and is proven) =="
    make -C "$LOEXSO/buildroot" O="$BR_OUT"
    BUILD_STATUS=$?
    END=$(date +%s)
    echo
    echo "  elapsed: $(( (END - START) / 60 ))m $(( (END - START) % 60 ))s"
    echo

    if [ "$BUILD_STATUS" -ne 0 ]; then
      echo "ABORTING: build failed (exit $BUILD_STATUS)."
    else
      echo "== relinking images/Image =="
      ln -snf "$BR_OUT/images/Image" images/Image
      ls -la images/Image
      echo

      echo "== confirming CONFIG_TUN/CONFIG_UNIX made it into the final kernel config =="
      grep -E 'CONFIG_UNIX=|CONFIG_TUN=' "$KCONFIG"
      echo

      echo "BUILD OK. Next: copy the new Image onto the SD card's boot partition."
    fi
  fi
fi

echo
echo "done"
