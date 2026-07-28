#!/usr/bin/env bash
# build_step_01_generate_synth.sh
#
# Synthesise the LiteX SoC + VexRiscv-SMP bitstream for the OrangeCrab 85F.
# Produces the bitstream AND rv32.dtb -- the DTB carries the spi_ext IRQ
# number, so it must be redeployed (step 04) after any re-synth even though
# the kernel itself does not need rebuilding.
#
# Requires the environment from build_step_00 (source it, do not run it).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
hash -r
./make.py --board=orange_crab --device=85F --revision=0.2 --cpu-count=4 \
    --rootfs=mmcblk0p2 --build -- --sdram-device=MT41K256M16
