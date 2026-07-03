#!/bin/sh
# Save + run: generates the rv32ima target spec, wires up .cargo/config.toml
# to use your buildroot gcc as the linker, and prints the exact build command
# for axum_serve.
#
# Prereqs checked here: rustup with a nightly toolchain + rust-src component.
# This does NOT install rustup/nightly for you -- if missing, it prints the
# exact command and stops there so nothing gets installed without you seeing
# it first.

WORKDIR="${WORKDIR:-$(pwd)}"
BR_OUT="$WORKDIR/build/orange_crab/buildroot"
GCC="$BR_OUT/host/bin/riscv32-buildroot-linux-gnu-gcc"
OLED_DIR="$WORKDIR/../../rust/oled"

echo "== 1. confirming buildroot gcc =="
if [ -x "$GCC" ]; then
  echo "  ok: $GCC"
else
  echo "  MISSING: $GCC"
  echo "  Re-run the check-gcc.sh step first."
fi
echo

echo "== 2. confirming rust/oled layout =="
if [ -d "$OLED_DIR/axum_serve" ]; then
  echo "  ok: $OLED_DIR"
else
  echo "  MISSING: $OLED_DIR/axum_serve"
  echo "  Did install.sh run correctly? Check $WORKDIR/../../rust/oled"
fi
echo

echo "== 3. confirming nightly rust + rust-src =="
HAVE_NIGHTLY=0
if command -v rustup >/dev/null 2>&1; then
  if rustup toolchain list 2>/dev/null | grep -q '^nightly'; then
    if rustup component list --toolchain nightly 2>/dev/null | grep -q '^rust-src (installed)'; then
      HAVE_NIGHTLY=1
      echo "  ok: nightly + rust-src installed"
    else
      echo "  nightly is installed, but rust-src component is missing. Install it with:"
      echo "    rustup component add rust-src --toolchain nightly"
    fi
  else
    echo "  no nightly toolchain installed. Install it with:"
    echo "    rustup toolchain install nightly"
    echo "    rustup component add rust-src --toolchain nightly"
  fi
else
  echo "  rustup not found. Install rustup first:"
  echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
fi
echo

if [ -x "$GCC" ] && [ -d "$OLED_DIR/axum_serve" ] && [ "$HAVE_NIGHTLY" = "1" ]; then
  echo "== 4. generating target spec =="
  cd "$OLED_DIR" || exit 0

  rustc +nightly -Z unstable-options --print target-spec-json \
    --target riscv32gc-unknown-linux-gnu > rv32ima-buildroot.json 2>/tmp/rv32ima-spec.err

  if [ -s rv32ima-buildroot.json ]; then
    echo "  wrote $OLED_DIR/rv32ima-buildroot.json"

    python3 - "$OLED_DIR/rv32ima-buildroot.json" << 'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    spec = json.load(f)
spec["features"] = "+m,+a"
spec["llvm-abiname"] = "ilp32"
with open(path, "w") as f:
    json.dump(spec, f, indent=2)
print("  patched features -> +m,+a, llvm-abiname -> ilp32")
PYEOF

  else
    echo "  FAILED to generate target spec, see /tmp/rv32ima-spec.err:"
    cat /tmp/rv32ima-spec.err
  fi
  echo

  echo "== 5. writing .cargo/config.toml linker entry =="
  mkdir -p "$OLED_DIR/.cargo"
  cat > "$OLED_DIR/.cargo/config.toml" << CARGOEOF
[target.rv32ima-buildroot]
linker = "$GCC"
CARGOEOF
  echo "  wrote $OLED_DIR/.cargo/config.toml"
  echo

  echo "== 6. build command =="
  echo "  cd $OLED_DIR"
  echo "  cargo +nightly build -Z build-std=std,panic_abort \\"
  echo "    --target rv32ima-buildroot.json --release -p axum_serve"
else
  echo "Skipping target-spec generation until the checks above pass."
fi

echo
echo "done"
