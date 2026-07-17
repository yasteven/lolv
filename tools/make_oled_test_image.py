#!/usr/bin/env python3
from pathlib import Path

W = 128
H = 64

out_dir = Path("reports")
out_dir.mkdir(exist_ok=True)

pixels = [[0 for _ in range(W)] for _ in range(H)]

for x in range(W):
    pixels[0][x] = 1
    pixels[H - 1][x] = 1
for y in range(H):
    pixels[y][0] = 1
    pixels[y][W - 1] = 1

for i in range(min(W // 2, H)):
    pixels[i][i * 2] = 1
    pixels[i][W - 1 - (i * 2)] = 1

for y in range(6, 22):
    for x in range(6, 34):
        pixels[y][x] = 1

for y in range(42, 58):
    for x in range(94, 122):
        pixels[y][x] = 1

for y in range(28, 36):
    for x in range(12, 116):
        if (x // 4) % 2 == 0 or y in (28, 35):
            pixels[y][x] = 1

pbm = out_dir / "oled_test_128x64.pbm"
with pbm.open("w", encoding="utf-8") as f:
    f.write("P1\n")
    f.write(f"{W} {H}\n")
    for row in pixels:
        f.write(" ".join(str(v) for v in row))
        f.write("\n")

xbm = out_dir / "oled_test_128x64.xbm"
bytes_out = []
for y in range(H):
    for xb in range(0, W, 8):
        b = 0
        for bit in range(8):
            if pixels[y][xb + bit]:
                b |= 1 << bit
        bytes_out.append(b)

with xbm.open("w", encoding="utf-8") as f:
    f.write("#define oled_test_128x64_width 128\n")
    f.write("#define oled_test_128x64_height 64\n")
    f.write("static unsigned char oled_test_128x64_bits[] = {\n")
    for i in range(0, len(bytes_out), 12):
        f.write("  ")
        f.write(", ".join(f"0x{b:02x}" for b in bytes_out[i:i + 12]))
        if i + 12 < len(bytes_out):
            f.write(",")
        f.write("\n")
    f.write("};\n")

print(f"wrote {pbm}")
print(f"wrote {xbm}")
