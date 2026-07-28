#!/usr/bin/env bash
set -euo pipefail

# Run on the Jetson with the OrangeCrab SD card in the reader.
# On the board, partition 4 is mounted at /root/8gb, so this installs:
#   /root/8gb/spis/bin/asi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ASI_DIR="$ROOT/../../rust/spis/async_spi_interface"
BIN="$ASI_DIR/target/rv32ima-buildroot/release/asi"
DEV="${ASI_SD_DEVICE:-/dev/sdb}"
PART="${DEV}4"
MNT="${ASI_SD_MOUNT:-/mnt/oc_storage}"
EXPECTED_SIZE="${ASI_SD_EXPECTED_SIZE:-15524167680}"
TARGET_DIR="$MNT/spis/bin"
TARGET="$TARGET_DIR/asi"
MOUNTED_BY_SCRIPT=0

die() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    if (( MOUNTED_BY_SCRIPT )); then
        echo
        echo "== cleanup: unmounting $MNT =="
        sudo umount "$MNT" || true
        MOUNTED_BY_SCRIPT=0
    fi
}
trap cleanup EXIT

for command in cargo file findmnt sha256sum sudo blockdev mount umount sync; do
    command -v "$command" >/dev/null 2>&1 || die "missing required command: $command"
done

[[ -d "$ROOT/.git" && -f "$ROOT/soc_linux.py" ]] \
    || die "this script must be installed as lolv/tools/deploy-asi-via-sdcard.sh"
[[ -x "$ASI_DIR/tools/build_orangecrab.sh" ]] \
    || die "missing ASI OrangeCrab build script: $ASI_DIR/tools/build_orangecrab.sh"

echo "== building ASI for OrangeCrab =="
(cd "$ASI_DIR" && ./tools/build_orangecrab.sh)

[[ -s "$BIN" ]] || die "cross-built ASI binary is missing: $BIN"
FILE_INFO="$(file -- "$BIN")"
printf '%s\n' "$FILE_INFO"
grep -q 'ELF 32-bit.*RISC-V' <<<"$FILE_INFO" \
    || die "binary is not a 32-bit RISC-V ELF"

SOURCE_SHA="$(sha256sum -- "$BIN" | awk '{print $1}')"
echo "source sha256: $SOURCE_SHA"

echo
echo "== verifying OrangeCrab SD card =="
[[ -b "$DEV" ]] || die "$DEV is not a block device; run tools/misc_step_find_orangecrab_sd_card.sh"
[[ -b "$PART" ]] || die "$PART does not exist; run tools/misc_step_find_orangecrab_sd_card.sh"
ACTUAL_SIZE="$(sudo blockdev --getsize64 "$DEV")"
echo "$DEV size: $ACTUAL_SIZE bytes"
[[ "$ACTUAL_SIZE" == "$EXPECTED_SIZE" ]] \
    || die "$DEV is not the expected OrangeCrab card (wanted $EXPECTED_SIZE bytes)"

# Desktop automounters may already have partition 4 mounted elsewhere.
EXISTING_MOUNT="$(findmnt -rn -S "$PART" -o TARGET | head -n 1 || true)"
if [[ -n "$EXISTING_MOUNT" ]]; then
    echo "unmounting existing $PART mount at $EXISTING_MOUNT"
    sudo umount "$PART"
fi

sudo mkdir -p "$MNT"
sudo mount "$PART" "$MNT"
MOUNTED_BY_SCRIPT=1

echo
echo "== mounted ocstore partition =="
findmnt "$MNT"
df -h "$MNT"

echo
echo "== atomically installing ASI 0.3 =="
sudo mkdir -p "$TARGET_DIR"
sudo install -m 0755 -- "$BIN" "$TARGET.new"
sudo mv -f -- "$TARGET.new" "$TARGET"

CARD_SHA="$(sudo sha256sum -- "$TARGET" | awk '{print $1}')"
echo "source sha256: $SOURCE_SHA"
echo "card   sha256: $CARD_SHA"
[[ "$CARD_SHA" == "$SOURCE_SHA" ]] || die "SD-card copy hash mismatch"

sudo sync -f "$MNT"
sudo umount "$MNT"
MOUNTED_BY_SCRIPT=0

echo
echo "PASS: ASI 0.3 installed and verified on OrangeCrab SD partition 4"
echo "Safe to remove the card. After boot, run:"
echo "  /root/8gb/spis/bin/asi receive /root/8gb/spis/incoming"
echo "Expected banner: asi 0.3 continuous-cs fifo transport"
