#!/bin/bash
# Build BOTH ASI binaries. They share a wire protocol version, so a stale host
# sender talking to a fresh rv32 receiver silently mis-frames -- exactly the
# "expected END, got <INFO>" failure. Always build them together.
set -e
ASI=/mnt/storage/see/1-c0d3/rust/spis/async_spi_interface
cd "$ASI"
echo "== host sender (Jetson, spidev master) =="
./tools/build_host.sh
echo
echo "== rv32 receiver (OrangeCrab) =="
./tools/build_orangecrab.sh
echo
echo "== both built =="
sha256sum target/release/asi target/rv32ima-buildroot/release/asi
