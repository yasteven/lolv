#!/bin/sh
# Run on the Jetson, from lolv/, with the OrangeCrab's SD card in a reader.
# Copies the rv32ima serial_bridge binary onto the ocstore partition.

WORKDIR="${WORKDIR:-$(pwd)}"
OLED_DIR="$WORKDIR/../../rust/oled"
BIN="$OLED_DIR/target/rv32ima-buildroot/release/serial_bridge"
DEV="/dev/sdb"
MNT="/mnt/oc_storage"

echo "== confirming the built binary exists =="
if [ ! -f "$BIN" ]; then
  echo "MISSING: $BIN -- run build_serial_bridge.sh / patch scripts first."
else
  echo "  ok: $BIN ($(du -h "$BIN" | cut -f1))"
  echo

  echo "== safety check: confirming $DEV is the expected card =="
  SIZE_BYTES=$(sudo blockdev --getsize64 "$DEV" 2>/dev/null)
  if [ "$SIZE_BYTES" != "15524167680" ]; then
    echo "ABORTING: $DEV is not the expected 14.46GiB card (got size $SIZE_BYTES)."
    echo "Is the card actually inserted? Re-run find-sdcard.sh to check."
  else
    echo "  ok, size matches."
    echo

    echo "== mounting ${DEV}4 (ocstore) =="
    sudo mkdir -p "$MNT"
    sudo umount "$MNT" 2>/dev/null
    sudo mount "${DEV}4" "$MNT"
    MOUNT_STATUS=$?

    if [ "$MOUNT_STATUS" -ne 0 ]; then
      echo "ABORTING: mount failed (exit $MOUNT_STATUS)."
    else
      df -h "$MNT"
      echo

      echo "== copying binary =="
      TARGET_DIR="$MNT/deploy/serial_bridge"
      sudo mkdir -p "$TARGET_DIR"
      sudo cp -v "$BIN" "$TARGET_DIR/serial_bridge"
      sudo chmod +x "$TARGET_DIR/serial_bridge"
      echo

      echo "== verifying =="
      ls -la "$TARGET_DIR"
      echo

      echo "== syncing and unmounting =="
      sync
      sudo umount "$MNT"
      echo "  unmounted cleanly"
      echo

      echo "Safe to remove the card now. Put it back in the OrangeCrab and boot."
    fi
  fi
fi

echo
echo "done"
