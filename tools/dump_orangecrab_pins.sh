#!/bin/bash
# Run from lolv/. Dumps the actual OrangeCrab platform pin table from your
# installed litex-boards, so the GPIO:N <-> silkscreen-label mapping is
# ground truth instead of inference.

source /mnt/storage/ext/litex-venv/bin/activate 2>/dev/null

python3 - << 'PYEOF'
from litex_boards.platforms import gsd_orangecrab
import inspect

src = inspect.getsource(gsd_orangecrab)
# Print just the _io / pin definition section
lines = src.splitlines()
printing = False
for line in lines:
    if "_io" in line and "=" in line and "[" in line:
        printing = True
    if printing:
        print(line)
    if printing and line.strip() == "]":
        break
PYEOF
echo "done"
