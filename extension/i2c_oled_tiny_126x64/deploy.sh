#!/bin/sh
# Ship the cross-compiled axum_serve binary + static/ to the OrangeCrab and
# (re)start it. Run from this directory (extension/i2c_oled_tiny_126x64/)
# after build.sh.
set -eu

TARGET="${TARGET:-riscv64gc-unknown-linux-musl}"
PROFILE="${PROFILE:-release}"
ORANGECRAB_HOST="${ORANGECRAB_HOST:?set ORANGECRAB_HOST, e.g. ORANGECRAB_HOST=192.168.7.2 ./deploy.sh}"
ORANGECRAB_USER="${ORANGECRAB_USER:-root}"
REMOTE_BIN_DIR="${REMOTE_BIN_DIR:-/usr/local/bin}"
REMOTE_STATIC_DIR="${REMOTE_STATIC_DIR:-/usr/local/share/axum-serve-static}"

HERE="$(cd "$(dirname "$0")" && pwd)"
OLED_DIR="$HERE/../../../../rust/oled"
BIN="$OLED_DIR/target/$TARGET/$PROFILE/axum_serve"
STATIC_DIR="$OLED_DIR/axum_serve/static"

if [ ! -f "$BIN" ]; then
  echo "error: $BIN not found -- run build.sh first." >&2
  exit 1
fi

echo "Copying binary to $ORANGECRAB_USER@$ORANGECRAB_HOST:$REMOTE_BIN_DIR/axum_serve"
scp "$BIN" "$ORANGECRAB_USER@$ORANGECRAB_HOST:$REMOTE_BIN_DIR/axum_serve"

echo "Copying static/ to $ORANGECRAB_USER@$ORANGECRAB_HOST:$REMOTE_STATIC_DIR"
ssh "$ORANGECRAB_USER@$ORANGECRAB_HOST" "mkdir -p '$REMOTE_STATIC_DIR'"
scp -r "$STATIC_DIR"/. "$ORANGECRAB_USER@$ORANGECRAB_HOST:$REMOTE_STATIC_DIR/"

echo "Restarting service (if systemd unit is installed)..."
ssh "$ORANGECRAB_USER@$ORANGECRAB_HOST" \
  "systemctl restart axum-serve 2>/dev/null || echo 'no axum-serve systemd unit yet -- run it manually:'; \
   echo \"$REMOTE_BIN_DIR/axum_serve --i2c-bus /dev/i2c-0 --i2c-addr 0x3c --bind 0.0.0.0:80 --static-dir $REMOTE_STATIC_DIR\""

echo "Done. Open http://$ORANGECRAB_HOST/ in a browser."
