#!/usr/bin/env bash
set -euo pipefail

# setup_i2cs_oled_repos.sh
#
# Fetch external I2C/OLED userspace libraries into $WORKROOT/i2cs.
#
# Run from:
#   $WORKROOT/lolv

cd "$(dirname "$0")/.."

export WORKROOT="${WORKROOT:-$(cd .. && pwd)}"
export I2CSDIR="${I2CSDIR:-$WORKROOT/i2cs}"

mkdir -p "$I2CSDIR"

clone_or_update() {
    local url="$1"
    local dir="$2"

    if [[ -d "$dir/.git" ]]; then
        echo "== updating $dir =="
        git -C "$dir" fetch --all --tags
    elif [[ -d "$dir" ]]; then
        echo "ERROR: $dir exists but is not a git repo" >&2
        exit 1
    else
        echo "== cloning $url -> $dir =="
        git clone "$url" "$dir"
    fi
}

clone_or_update "https://github.com/rm-hull/luma.core.git" "$I2CSDIR/luma.core"
clone_or_update "https://github.com/rm-hull/luma.oled.git" "$I2CSDIR/luma.oled"
clone_or_update "https://github.com/rm-hull/luma.examples.git" "$I2CSDIR/luma.examples"

cat > "$I2CSDIR/README.md" <<'MD'
# i2cs external workspace

This directory is outside `lolv/` on purpose.

It stores third-party I2C/OLED userspace libraries and later custom I2C firmware/controller experiments.

Current OLED branch:

```text
lolv branch: ext_i2cs_1p3in_GME12864_70
display: GME12864-70 1.3 inch 128x64 I2C OLED
likely drivers to try: sh1106 first, ssd1306 second
likely addresses: 0x3c or 0x3d
```

Current third-party checkouts:

```text
luma.core
luma.oled
luma.examples
```

Do not commit these repos into `lolv/`.
MD

echo
echo "I2C/OLED repos ready:"
find "$I2CSDIR" -maxdepth 2 -type d -name .git -print | sort
echo
echo "Next:"
echo "  cd $WORKROOT/lolv"
echo "  ./tools/probe_i2c0_oled.sh"
echo "  python3 ./tools/run_luma_oled_test.py --port 0 --address 0x3c --device sh1106"
