#!/usr/bin/env bash
# Run from lolv/. Convenience wrapper so the OrangeCrab bsi cross-build can
# be kicked off without remembering the full rust/spis/basic_spi_io path.
# Requires fpga-env.sh already sourced (rustup nightly + cross toolchain on
# PATH), same as any other build in this repo.
set -euo pipefail

WORKDIR="${WORKDIR:-$(pwd)}"
RUSTROOT="$WORKDIR/../../rust"
SPIS_DIR="$RUSTROOT/spis/basic_spi_io"

pushd "$SPIS_DIR" >/dev/null
"$SPIS_DIR/tools/build_bsi_orangecrab.sh"
popd >/dev/null
