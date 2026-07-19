#!/bin/sh
# Run on the Jetson, from lolv/, with the OrangeCrab's SD card in a reader.
# Copies the cross-compiled bsi binary onto the ocstore partition and lays
# down the spis/ working directories, so the board has bsi and a place to
# put files the moment it boots.
#
# This is meant to be the LAST time bsi itself needs to go through the SD
# card: once both sides can run bsi, future bsi updates can be sent over
# SPI (bsi --tx the new binary, bsi --rx it into spis/incoming, then swap
# it into spis/bin on the board) instead of pulling the card again.

WORKDIR="${WORKDIR:-$(pwd)}"
SPIS_DIR="$WORKDIR/../../rust/spis/basic_spi_io"
BIN="$SPIS_DIR/target/rv32ima-buildroot/release/bsi"
DEV="/dev/sdb"
MNT="/mnt/oc_storage"

echo "== confirming the cross-built OrangeCrab binary exists =="
if [ ! -f "$BIN" ]; then
  echo "MISSING: $BIN"
  echo "Cross-build it first:"
  echo "  $SPIS_DIR/tools/build_bsi_orangecrab.sh"
else
  echo "  ok: $BIN ($(du -h "$BIN" | cut -f1))"
  file "$BIN" 2>/dev/null
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

      echo "== laying down spis/ working directories =="
      TARGET_DIR="$MNT/spis"
      sudo mkdir -p \
        "$TARGET_DIR/bin" \
        "$TARGET_DIR/incoming" \
        "$TARGET_DIR/staging" \
        "$TARGET_DIR/completed" \
        "$TARGET_DIR/state" \
        "$TARGET_DIR/logs"

      echo "== copying bsi binary =="
      sudo cp -v "$BIN" "$TARGET_DIR/bin/bsi"
      sudo chmod +x "$TARGET_DIR/bin/bsi"
      echo

      echo "== verifying what's on the card now =="
      find "$TARGET_DIR" -maxdepth 2
      echo
      echo "reference sha256 (compare after transfer if you're ever unsure):"
      sha256sum "$BIN"
      echo

      echo "== syncing and unmounting =="
      sync
      sudo umount "$MNT"
      echo "  unmounted cleanly"
      echo

      echo "Safe to remove the card now. Put it back in the OrangeCrab and boot."
      echo
      echo "On the board, once logged in, bsi is now at:"
      echo "  /root/8gb/spis/bin/bsi"
      echo
      echo "Receive a file sent from the Jetson:"
      echo "  /root/8gb/spis/bin/bsi --rx /root/8gb/spis/incoming"
      echo
      echo "Send a file from the board to the Jetson:"
      echo "  /root/8gb/spis/bin/bsi --tx /root/8gb/spis/completed/<file>"
      echo
      echo "Matching commands on the Jetson side (already built by the patch script):"
      echo "  $SPIS_DIR/target/release/bsi --tx <file>"
      echo "  $SPIS_DIR/target/release/bsi --rx <dest-dir>"
      echo
      echo "From here on, future bsi binary updates can go over SPI instead of"
      echo "the card: cross-build a new one, then"
      echo "  $SPIS_DIR/target/release/bsi --tx $BIN"
      echo "receive it into /root/8gb/spis/incoming on the board, then move it"
      echo "into spis/bin and chmod +x -- no card swap needed."
    fi
  fi
fi

echo
echo "done"
