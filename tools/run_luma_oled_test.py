#!/usr/bin/env python3
import argparse
import os
import sys
from pathlib import Path

def add_external_luma_paths():
    workroot = Path(os.environ.get("WORKROOT", Path.cwd().parent)).resolve()
    i2csdir = Path(os.environ.get("I2CSDIR", workroot / "i2cs")).resolve()

    for rel in ["luma.core", "luma.oled"]:
        path = i2csdir / rel
        if path.exists():
            sys.path.insert(0, str(path))

def parse_int_auto(s: str) -> int:
    return int(s, 0)

def main() -> int:
    parser = argparse.ArgumentParser(description="Draw a 128x64 test image on an I2C OLED using luma.oled.")
    parser.add_argument("--port", type=int, default=0, help="Linux I2C bus number, e.g. 0 for /dev/i2c-0.")
    parser.add_argument("--address", type=parse_int_auto, default=0x3C, help="OLED I2C address, e.g. 0x3c or 0x3d.")
    parser.add_argument("--device", choices=["sh1106", "ssd1306"], default="sh1106", help="OLED controller driver.")
    parser.add_argument("--rotate", type=int, default=0, choices=[0, 1, 2, 3], help="luma rotate setting.")
    args = parser.parse_args()

    add_external_luma_paths()

    try:
        from luma.core.interface.serial import i2c
        from luma.core.render import canvas
        from luma.oled.device import sh1106, ssd1306
    except Exception as e:
        print("ERROR: could not import luma.oled stack.", file=sys.stderr)
        print(str(e), file=sys.stderr)
        print("", file=sys.stderr)
        print("Run on the host:", file=sys.stderr)
        print("  ./tools/setup_i2cs_oled_repos.sh", file=sys.stderr)
        print("", file=sys.stderr)
        print("Then ensure Python can import luma.core/luma.oled and Pillow.", file=sys.stderr)
        print("On a Buildroot target, this may require adding python3/pillow/luma packages or copying a prepared rootfs.", file=sys.stderr)
        return 2

    driver = sh1106 if args.device == "sh1106" else ssd1306

    serial = i2c(port=args.port, address=args.address)
    device = driver(serial, width=128, height=64, rotate=args.rotate)

    with canvas(device) as draw:
        draw.rectangle(device.bounding_box, outline="white", fill="black")
        draw.line((0, 0, 127, 63), fill="white")
        draw.line((0, 63, 127, 0), fill="white")
        draw.rectangle((5, 5, 35, 20), outline="white", fill="white")
        draw.rectangle((92, 43, 122, 58), outline="white", fill="white")
        draw.text((40, 4), "LOLV", fill="white")
        draw.text((40, 18), "I2C OLED", fill="white")
        draw.text((40, 32), args.device.upper(), fill="white")
        draw.text((40, 46), f"0x{args.address:02X}", fill="white")

    print(f"displayed OLED test: device={args.device} port={args.port} address=0x{args.address:02x}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
