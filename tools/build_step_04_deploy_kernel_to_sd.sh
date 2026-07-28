#!/bin/sh
# build_step_04_deploy_kernel_to_sd.sh
# Run on the Jetson, from lolv/, with the OrangeCrab's SD card in a reader.
# Copies the newly-built kernel Image AND the device tree (rv32.dtb) onto the
# boot partition (sdb1, LITEXBOOT/FAT32). The DTB carries the spi_ext node, so
# both must be deployed together after a kernel/DTS change.

WORKDIR="${WORKDIR:-$(pwd)}"
BR_OUT="$WORKDIR/build/orange_crab/buildroot"
NEW_IMAGE="$BR_OUT/images/Image"
NEW_DTB="$WORKDIR/images/rv32.dtb"
DEV="/dev/sdb"
MNT="/mnt/oc_boot"

echo "== confirming the new kernel Image exists =="
if [ ! -f "$NEW_IMAGE" ]; then
  echo "MISSING: $NEW_IMAGE -- run build_step_03_generate_kernel.sh first."
  echo; echo "done"; exit 1
fi
echo "  ok: $NEW_IMAGE ($(du -h "$NEW_IMAGE" | cut -f1), built $(date -r "$NEW_IMAGE"))"

echo "== confirming the device tree (rv32.dtb) exists =="
if [ ! -f "$NEW_DTB" ]; then
  echo "MISSING: $NEW_DTB"
  echo "  This is produced by synth (build_step_01) once patch_make_dts_spi_ext.py"
  echo "  is applied, or staged by build_step_05_optional_generate_dtb.sh if you"
  echo "  hand-edited the DTS. Deploy needs it to carry the spi_ext node."
  echo; echo "done"; exit 1
fi
echo "  ok: $NEW_DTB ($(du -h "$NEW_DTB" | cut -f1), built $(date -r "$NEW_DTB"))"
echo

echo "== safety check: confirming $DEV is the expected card =="
SIZE_BYTES=$(sudo blockdev --getsize64 "$DEV" 2>/dev/null)
if [ "$SIZE_BYTES" != "15524167680" ]; then
  echo "ABORTING: $DEV is not the expected 14.46GiB card (got size $SIZE_BYTES)."
  echo "Is the card actually inserted? Re-run misc_step_find_orangecrab_sd_card.sh to check."
  echo; echo "done"; exit 1
fi
echo "  ok, size matches."
echo

echo "== mounting ${DEV}1 (LITEXBOOT) =="
sudo mkdir -p "$MNT"
sudo umount "$MNT" 2>/dev/null
sudo mount "${DEV}1" "$MNT"
if [ "$?" -ne 0 ]; then
  echo "ABORTING: mount failed."
  echo; echo "done"; exit 1
fi

df -h "$MNT"
echo
echo "== boot partition contents before =="
ls -la "$MNT"
echo

if [ ! -f "$MNT/Image" ]; then
  echo "ABORTING: no existing Image at $MNT/Image -- unexpected boot partition"
  echo "layout, not overwriting blindly. Check ls output above."
  sudo umount "$MNT"
  echo; echo "done"; exit 1
fi

# Determine the existing DTB filename on the boot partition (rv32.dtb expected,
# but don't guess blindly -- fall back to whatever single *.dtb is present).
DTB_NAME="rv32.dtb"
if [ ! -f "$MNT/$DTB_NAME" ]; then
  FOUND_DTB="$(ls "$MNT"/*.dtb 2>/dev/null | head -1)"
  if [ -n "$FOUND_DTB" ]; then
    DTB_NAME="$(basename "$FOUND_DTB")"
    echo "NOTE: $MNT/rv32.dtb absent; existing DTB on card is $DTB_NAME -- will overwrite that."
    echo
  else
    echo "NOTE: no existing *.dtb on the boot partition; installing as $DTB_NAME."
    echo "      If the bootloader expects a different name, rename accordingly."
    echo
  fi
fi

STAMP="$(date +%s)"

echo "== backing up existing Image =="
sudo cp "$MNT/Image" "$MNT/Image.bak.$STAMP"
echo "  backed up -> Image.bak.$STAMP"

if [ -f "$MNT/$DTB_NAME" ]; then
  echo "== backing up existing $DTB_NAME =="
  sudo cp "$MNT/$DTB_NAME" "$MNT/$DTB_NAME.bak.$STAMP"
  echo "  backed up -> $DTB_NAME.bak.$STAMP"
fi
echo

echo "== copying new Image =="
sudo cp -v "$NEW_IMAGE" "$MNT/Image"
echo
echo "== copying new $DTB_NAME =="
sudo cp -v "$NEW_DTB" "$MNT/$DTB_NAME"
echo

echo "== boot partition contents after =="
ls -la "$MNT"
echo

echo "== syncing and unmounting =="
sync
sudo umount "$MNT"
echo "  unmounted cleanly"
echo

echo "Safe to remove the card now. Put it back in the OrangeCrab and boot."
echo "Watch the litex_term boot log for 'Copying Image to 0x40000000' -- the byte"
echo "count should match the new Image. After boot: dmesg | grep lolv_spi"
echo
echo "done"
