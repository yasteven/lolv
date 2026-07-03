#!/bin/sh
# Repartitions the OrangeCrab SD card: shrinks root to 1.5GiB, adds a 4GiB
# swap partition and an ~8.71GiB storage partition in the reclaimed space.
#
# DRY RUN BY DEFAULT. Run once with no args to review the plan, then again
# with --commit to actually execute it.
#
#   sh partition-sdcard.sh            # dry run, prints the plan only
#   sh partition-sdcard.sh --commit   # actually does it

DEV="/dev/sdb"
COMMIT=0
[ "$1" = "--commit" ] && COMMIT=1

echo "== safety check: confirming $DEV is the expected card =="
SIZE_BYTES=$(sudo blockdev --getsize64 "$DEV" 2>/dev/null)
echo "  $DEV size: ${SIZE_BYTES:-unknown} bytes (expect 15524167680)"

if [ "$SIZE_BYTES" != "15524167680" ]; then
  echo
  echo "ABORTING: $DEV is not the expected 14.46GiB card (got size $SIZE_BYTES)."
  echo "Do not proceed -- re-run find-sdcard.sh to re-identify the device."
else
  echo "  ok, size matches."
  echo

  echo "== current partition table =="
  sudo fdisk -l "$DEV"
  echo

  echo "== backing up current partition table (cheap, instant) =="
  BACKUP="/mnt/storage/orangecrab_sdcard_ptable_$(date +%Y%m%d_%H%M%S).sfdisk"
  sudo sfdisk -d "$DEV" > "$BACKUP" 2>/dev/null
  echo "  saved to $BACKUP"
  echo "  (restore with: sudo sfdisk $DEV < $BACKUP -- table only, not data)"
  echo

  echo "== NOTE: for extra safety, a full image backup before --commit is =="
  echo "== recommended (takes a few minutes, ~14.5GB, plenty of room on   =="
  echo "== /mnt/storage): sudo dd if=$DEV of=/mnt/storage/orangecrab_sdcard_backup.img bs=4M status=progress"
  echo

  echo "== planned new partition table =="
  cat << 'PLAN'
  p1 (unchanged): start=2048     size=522240    (255MiB)   boot, FAT32
  p2 (shrunk):    start=524288   size=3145728   (1536MiB)  root, ext4
  p3 (new):       start=3670016  size=8388608   (4096MiB)  swap
  p4 (new):       start=12058624 size=18262016  (~8.71GiB) storage, ext4
PLAN
  echo

  if [ "$COMMIT" != "1" ]; then
    echo "DRY RUN ONLY -- nothing was changed."
    echo "Review the plan above, then re-run:  sh partition-sdcard.sh --commit"
  else
    echo "== COMMIT MODE: making changes now =="
    echo

    echo "-- unmounting any mounted partitions on $DEV --"
    for p in "${DEV}1" "${DEV}2"; do
      mountpoint_check=$(mount | grep "^$p ")
      if [ -n "$mountpoint_check" ]; then
        sudo umount "$p"
        echo "  unmounted $p"
      fi
    done
    echo

    echo "-- checking filesystem on ${DEV}2 before shrink --"
    sudo e2fsck -f -y "${DEV}2"
    echo

    echo "-- shrinking filesystem on ${DEV}2 to 1536M --"
    sudo resize2fs "${DEV}2" 1536M
    RESIZE_STATUS=$?

    if [ "$RESIZE_STATUS" -ne 0 ]; then
      echo "ABORTING: resize2fs failed (exit $RESIZE_STATUS). Partition table NOT touched."
    else
      echo
      echo "-- rewriting partition table with sfdisk --"
      sudo sfdisk "$DEV" << 'SFDISK_EOF'
label: dos
unit: sectors

/dev/sdb1 : start=2048, size=522240, type=c, bootable
/dev/sdb2 : start=524288, size=3145728, type=83
/dev/sdb3 : start=3670016, size=8388608, type=82
/dev/sdb4 : start=12058624, size=18262016, type=83
SFDISK_EOF
      SFDISK_STATUS=$?

      if [ "$SFDISK_STATUS" -ne 0 ]; then
        echo "ABORTING: sfdisk failed (exit $SFDISK_STATUS)."
        echo "Restore the old table with: sudo sfdisk $DEV < $BACKUP"
      else
        echo
        echo "-- reloading partition table --"
        sudo partprobe "$DEV" 2>/dev/null
        sleep 1
        echo

        echo "-- verifying root filesystem after resize --"
        sudo e2fsck -f -y "${DEV}2"
        echo

        echo "-- creating swap on ${DEV}3 --"
        sudo mkswap -L ocswap "${DEV}3"
        echo

        echo "-- creating ext4 storage filesystem on ${DEV}4 --"
        sudo mkfs.ext4 -L ocstore "${DEV}4"
        echo

        echo "== final partition table =="
        sudo fdisk -l "$DEV"
        echo
        echo "DONE. Card is ready. Next: fstab + deploy scripts for the OrangeCrab side."
      fi
    fi
  fi
fi

echo
echo "done"
