#!/bin/sh
# Run on the Jetson, from lolv/, with the OrangeCrab's SD card in a reader.
# Copies the built axum_serve binary + static/ directly onto the ocstore
# partition (mmcblk0p4 on the board, /dev/sdb4 here), sidestepping PPP
# entirely for this deploy.

WORKDIR="${WORKDIR:-$(pwd)}"
OLED_DIR="$WORKDIR/../../rust/oled"
BIN="$OLED_DIR/target/rv32ima-buildroot/release/axum_serve"
STATIC_DIR="$OLED_DIR/axum_serve/static"
DEV="/dev/sdb"
MNT="/mnt/oc_storage"

echo "== confirming the built binary exists =="
if [ ! -f "$BIN" ]; then
  echo "MISSING: $BIN -- run patch_build_rv32.sh first."
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

      echo "== copying binary + static assets =="
      TARGET_DIR="$MNT/deploy/oled_tiny_128x64"
      sudo mkdir -p "$TARGET_DIR"
      sudo cp -v "$BIN" "$TARGET_DIR/axum_serve"
      sudo cp -rv "$STATIC_DIR" "$TARGET_DIR/static"
      sudo chmod +x "$TARGET_DIR/axum_serve"
      echo

      echo "== verifying what's on the card now =="
      find "$TARGET_DIR" -maxdepth 2
      echo

      echo "== syncing and unmounting =="
      sync
      sudo umount "$MNT"
      echo "  unmounted cleanly"
      echo

      echo "Safe to remove the card now. Put it back in the OrangeCrab and boot."
      echo "On the board, once logged in:"
      echo "  ls -la /root/8gb/deploy/oled_tiny_128x64/"
      echo "  /root/8gb/deploy/oled_tiny_128x64/axum_serve --bind 0.0.0.0:80 --static-dir /root/8gb/deploy/oled_tiny_128x64/static"
    fi
  fi
fi

echo
echo "done"
