#!/bin/sh
# Run on the Jetson, from lolv/, with the OrangeCrab's SD card in a reader.
# Copies the newly-built kernel Image (with CONFIG_TUN/CONFIG_UNIX) onto
# the boot partition (sdb1, LITEXBOOT/FAT32) -- separate from the
# ocstore/sdb4 copy deploy-via-sdcard.sh uses for axum_serve.

WORKDIR="${WORKDIR:-$(pwd)}"
BR_OUT="$WORKDIR/build/orange_crab/buildroot"
NEW_IMAGE="$BR_OUT/images/Image"
DEV="/dev/sdb"
MNT="/mnt/oc_boot"

echo "== confirming the new kernel Image exists =="
if [ ! -f "$NEW_IMAGE" ]; then
  echo "MISSING: $NEW_IMAGE -- run rebuild_kernel_tun.sh first."
else
  echo "  ok: $NEW_IMAGE ($(du -h "$NEW_IMAGE" | cut -f1), built $(date -r "$NEW_IMAGE"))"
  echo

  echo "== safety check: confirming $DEV is the expected card =="
  SIZE_BYTES=$(sudo blockdev --getsize64 "$DEV" 2>/dev/null)
  if [ "$SIZE_BYTES" != "15524167680" ]; then
    echo "ABORTING: $DEV is not the expected 14.46GiB card (got size $SIZE_BYTES)."
    echo "Is the card actually inserted? Re-run find-sdcard.sh to check."
  else
    echo "  ok, size matches."
    echo

    echo "== mounting ${DEV}1 (LITEXBOOT) =="
    sudo mkdir -p "$MNT"
    sudo umount "$MNT" 2>/dev/null
    sudo mount "${DEV}1" "$MNT"
    MOUNT_STATUS=$?

    if [ "$MOUNT_STATUS" -ne 0 ]; then
      echo "ABORTING: mount failed (exit $MOUNT_STATUS)."
    else
      df -h "$MNT"
      echo
      echo "== boot partition contents before =="
      ls -la "$MNT"
      echo

      if [ ! -f "$MNT/Image" ]; then
        echo "ABORTING: no existing Image at $MNT/Image -- unexpected boot"
        echo "partition layout, not overwriting blindly. Check ls output above."
      else
        echo "== backing up existing Image =="
        sudo cp "$MNT/Image" "$MNT/Image.bak.$(date +%s)"
        echo "  backed up"
        echo

        echo "== copying new Image =="
        sudo cp -v "$NEW_IMAGE" "$MNT/Image"
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
        echo "Watch the litex_term boot log for 'Copying Image to 0x40000000' --"
        echo "the byte count should match the new Image's size."
      fi
    fi
  fi
fi

echo
echo "done"
