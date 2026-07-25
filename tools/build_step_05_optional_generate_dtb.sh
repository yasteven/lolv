#!/bin/sh
# build_step_05_optional_generate_dtb.sh
#
# OPTIONAL / stopgap. Only needed if you hand-edited
# build/orange_crab/orange_crab.dts (e.g. the spi_ext node from setup_lolv_spi.py)
# and have NOT re-synthesized since. It compiles that DTS to a DTB and stages
# it at images/rv32.dtb so build_step_04_deploy_kernel_to_sd.sh pushes it.
#
# NOTE: ./make.py --build regenerates orange_crab.dts and its DTB from scratch,
# wiping any hand edit. The durable fix is patch_make_dts_spi_ext.py, which makes
# synth (step 01) emit the spi_ext node itself -- after that, this step is
# unnecessary because step 01 already produces the correct images/rv32.dtb.

WORKDIR="${WORKDIR:-$(pwd)}"
DTS="$WORKDIR/build/orange_crab/orange_crab.dts"
DTB="$WORKDIR/build/orange_crab/orange_crab.dtb"
OUT="$WORKDIR/images/rv32.dtb"

echo "== optional: compile hand-edited DTS -> images/rv32.dtb =="

if ! command -v dtc >/dev/null 2>&1; then
  echo "ABORTING: dtc not found in PATH (source your fpga-env.sh, or apt install device-tree-compiler)."
  echo; echo "done"; exit 1
fi

if [ ! -f "$DTS" ]; then
  echo "ABORTING: $DTS not found -- run synth (step 01) first."
  echo; echo "done"; exit 1
fi

if ! grep -q 'spi-ext@f0005000' "$DTS"; then
  echo "WARNING: $DTS has no spi-ext@f0005000 node. If you expected the spi_ext"
  echo "         interrupt node, run setup_lolv_spi.py (hand edit) or"
  echo "         patch_make_dts_spi_ext.py + re-synth (durable). Continuing anyway."
  echo
fi

echo "== compiling DTS -> DTB =="
if ! dtc -I dts -O dtb -o "$DTB" "$DTS"; then
  echo "ABORTING: dtc failed to compile $DTS."
  echo; echo "done"; exit 1
fi
echo "  wrote $DTB"
echo

echo "== staging as images/rv32.dtb (deploy step 04 pushes this) =="
mkdir -p "$WORKDIR/images"
if [ -f "$OUT" ]; then
  cp "$OUT" "$OUT.bak.$(date +%s)"
  echo "  backed up existing $OUT"
fi
cp -v "$DTB" "$OUT"
echo

echo "== confirming the spi_ext node survived the round-trip =="
if command -v fdtget >/dev/null 2>&1; then
  IRQ="$(fdtget "$OUT" /soc/spi-ext@f0005000 interrupts 2>/dev/null)"
  if [ -n "$IRQ" ]; then
    echo "  spi_ext interrupts = $IRQ  (expect 3)"
  else
    echo "  (no spi_ext node in the DTB -- see warning above)"
  fi
else
  dtc -I dtb -O dts "$OUT" 2>/dev/null | grep -A4 'spi-ext' || echo "  (fdtget absent; couldn't introspect)"
fi
echo

echo "PASS: images/rv32.dtb staged. Run build_step_04_deploy_kernel_to_sd.sh to"
echo "push it (with the Image) to the SD boot partition."
echo
echo "done"
