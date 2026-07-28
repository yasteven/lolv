#!/usr/bin/env bash
# build_step_06_generate_asi.sh
#
# Build BOTH ASI binaries. They share a wire protocol version, so a stale host
# sender talking to a fresh rv32 receiver silently mis-frames -- exactly the
# "expected END, got <INFO>" failure. Always build them together.
#
# The rv32 binary contains BOTH receivers: `asi --chardev` (interrupt-driven
# /dev/lolv_spi, the default path now) and plain `asi` (the /dev/mem CSR
# reference receiver, which needs no kernel driver). One binary, chosen at
# run time by the flag.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ASI="$(readlink -f "$ROOT/../../rust/spis/async_spi_interface")"
[[ -d "$ASI" ]] || { echo "ERROR: missing $ASI" >&2; exit 1; }

if [[ ! -d "${TMPDIR:-/tmp}" ]]; then
    echo "note: TMPDIR='${TMPDIR:-}' does not exist; falling back to /tmp" >&2
    export TMPDIR=/tmp
fi

cd "$ASI"
echo "== host sender (Jetson, spidev master) =="
./tools/build_host.sh
echo
echo "== rv32 receiver (OrangeCrab; both --chardev and CSR paths) =="
./tools/build_orangecrab.sh
echo
echo "== both built =="
sha256sum target/release/asi target/rv32ima-buildroot/release/asi
