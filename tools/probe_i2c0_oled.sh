#!/usr/bin/env bash
set -euo pipefail

# probe_i2c0_oled.sh
#
# Probe the existing LiteX/Linux i2c0 path for a 128x64 OLED.
#
# Run on the OrangeCrab Linux target when possible.

echo "== kernel i2c devices =="
ls -l /dev/i2c-* 2>/dev/null || true
ls -l /sys/class/i2c-dev 2>/dev/null || true

echo
echo "== i2c-dev modules / kernel config hints =="
grep -E 'i2c|I2C' /proc/devices 2>/dev/null || true
zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_I2C|CONFIG_I2C_CHARDEV' || true

echo
echo "== i2cdetect =="
if command -v i2cdetect >/dev/null 2>&1; then
    i2cdetect -y 0
else
    echo "i2cdetect not found."
    echo "Install/add i2c-tools later, or use Python/library probe once available."
fi

echo
echo "Expected OLED addresses:"
echo "  0x3c"
echo "  0x3d"

echo
echo "Next display tests:"
echo "  python3 ./tools/run_luma_oled_test.py --port 0 --address 0x3c --device sh1106"
echo "  python3 ./tools/run_luma_oled_test.py --port 0 --address 0x3c --device ssd1306"
