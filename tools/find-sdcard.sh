#!/bin/sh
# Read-only. Run on the Jetson with the OrangeCrab's SD card inserted via a
# reader. Helps positively identify which device node is the card before
# any partition/filesystem work touches anything.

echo "== lsblk (all block devices, sizes, mountpoints) =="
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL
echo

echo "== dmesg tail (look for the card's insertion, gives you the device name) =="
dmesg | tail -30
echo

echo "== /proc/partitions =="
cat /proc/partitions
echo

echo "== fdisk -l on each removable-looking device (read-only listing) =="
for dev in $(lsblk -dn -o NAME,RM | awk '$2==1{print $1}'); do
  echo "--- /dev/$dev ---"
  sudo fdisk -l "/dev/$dev" 2>/dev/null
  echo
done

echo "done -- do not run mkfs/parted/dd against anything until you've confirmed"
echo "the exact device name above matches a ~4-16GB card, NOT a Jetson disk."
