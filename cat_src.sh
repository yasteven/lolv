#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
OUT_DIR="./reports"
OLED_ROOT="$(readlink -f ../../rust/oled)"

DOCS_OUT="$OUT_DIR/cat_lolv_readmes.txt"
SCRIPTS_OUT="$OUT_DIR/cat_lolv_modified_scripts.txt"
OLED_OUT="$OUT_DIR/cat_rust_oled.txt"
ALL_OUT="$OUT_DIR/cat_lolv_all.txt"

mkdir -p "$OUT_DIR"

: > "$DOCS_OUT"
: > "$SCRIPTS_OUT"
: > "$OLED_OUT"
: > "$ALL_OUT"

write_header() {
    local out_file="$1"
    local title="$2"
    local root="$3"

    {
        echo "================================================================"
        echo "$title"
        echo "ROOT: $root"
        echo "GENERATED: $(date -Is)"
        echo "================================================================"
        echo
    } >> "$out_file"
}

append_hash_file() {
    local out_file="$1"
    local display_path="$2"
    local real_path="$3"

    {
        echo
        echo "################################################################"
        echo "# FILE: $display_path"
        echo "################################################################"
        echo
        cat "$real_path"
        echo
    } >> "$out_file"
}

append_slash_file() {
    local out_file="$1"
    local display_path="$2"
    local real_path="$3"

    {
        echo
        echo "////////////////////////////////////////////////////////////////"
        echo "// FILE: $display_path"
        echo "////////////////////////////////////////////////////////////////"
        echo
        cat "$real_path"
        echo
    } >> "$out_file"
}

write_header "$DOCS_OUT" "LOLV README / DOCS" "$ROOT"
write_header "$SCRIPTS_OUT" "LOLV MODIFIED SCRIPTS / GATEWARE / CONFIGS" "$ROOT"
write_header "$OLED_OUT" "RUST OLED WORKSPACE SOURCE / INFO" "$OLED_ROOT"

echo "== collecting lolv README/docs =="

find . \
  -path './.git' -prune -o \
  -path './build' -prune -o \
  -path './buildroot' -prune -o \
  -path './images' -prune -o \
  -path './target' -prune -o \
  -path './__pycache__' -prune -o \
  -path './reports' -prune -o \
  -type f \( -name '*.md' -o -name '*.txt' \) -print \
| sort \
| while IFS= read -r file; do
    append_hash_file "$DOCS_OUT" "$file" "$file"
done

echo "wrote $DOCS_OUT"

echo
echo "== collecting lolv modified scripts/gateware/configs =="

find . \
  -path './.git' -prune -o \
  -path './build' -prune -o \
  -path './buildroot' -prune -o \
  -path './images' -prune -o \
  -path './target' -prune -o \
  -path './__pycache__' -prune -o \
  -path './reports' -prune -o \
  -type f \( \
      -name '*.py' -o \
      -name '*.sh' -o \
      -name '*.c' -o \
      -name '*.h' -o \
      -name '*.vhd' -o \
      -name '*.vhdl' -o \
      -name '*.v' -o \
      -name '*.dts' -o \
      -name '*.dtsi' -o \
      -name '*.json' -o \
      -name '*.toml' -o \
      -name '*.config' -o \
      -name '*defconfig' -o \
      -name 'Config.in' -o \
      -name '*.mk' \
    \) -print \
| sort \
| while IFS= read -r file; do
    append_slash_file "$SCRIPTS_OUT" "$file" "$file"
done

echo "wrote $SCRIPTS_OUT"

echo
echo "== collecting ../../rust/oled source and info =="

if [[ ! -d "$OLED_ROOT" ]]; then
    echo "ERROR: missing OLED workspace: $OLED_ROOT" >&2
    exit 1
fi

find "$OLED_ROOT" \
  -path "$OLED_ROOT/.git" -prune -o \
  -path '*/target' -prune -o \
  -path '*/.git' -prune -o \
  -path '*/node_modules' -prune -o \
  -type f \( \
      -path '*/src/*.rs' -o \
      -path '*/src/**/*.rs' -o \
      -path '*/info/*' -o \
      -name 'Cargo.toml' -o \
      -name 'Cargo.lock' -o \
      -name 'rust-toolchain.toml' -o \
      -name '*.json' -o \
      -name 'README.md' -o \
      -name '*.md' \
    \) -print \
| sort \
| while IFS= read -r file; do
    rel="${file#"$OLED_ROOT"/}"
    append_slash_file "$OLED_OUT" "../../rust/oled/$rel" "$file"
done

echo "wrote $OLED_OUT"

{
    echo "================================================================"
    echo "LOLV COMPLETE AGGREGATE"
    echo "ROOT: $ROOT"
    echo "GENERATED: $(date -Is)"
    echo "================================================================"
    echo
    echo "Included sections:"
    echo "  1. LOLV README/docs"
    echo "  2. LOLV modified scripts/gateware/configs"
    echo "  3. ../../rust/oled source, manifests, and info"
    echo
    echo "Generated component files:"
    echo "  $DOCS_OUT"
    echo "  $SCRIPTS_OUT"
    echo "  $OLED_OUT"
    echo
    echo
    echo "################################################################"
    echo "# SECTION 1: LOLV README / DOCS"
    echo "################################################################"
    echo
    cat "$DOCS_OUT"
    echo
    echo
    echo "################################################################"
    echo "# SECTION 2: LOLV MODIFIED SCRIPTS / GATEWARE / CONFIGS"
    echo "################################################################"
    echo
    cat "$SCRIPTS_OUT"
    echo
    echo
    echo "################################################################"
    echo "# SECTION 3: RUST OLED SOURCE / INFO"
    echo "################################################################"
    echo
    cat "$OLED_OUT"
    echo
} >> "$ALL_OUT"

echo "wrote $ALL_OUT"

echo
echo "== aggregate sizes =="
ls -lh "$DOCS_OUT" "$SCRIPTS_OUT" "$OLED_OUT" "$ALL_OUT"

echo
echo "== OLED files captured =="
grep -c '^// FILE: ../../rust/oled/' "$OLED_OUT" || true

echo
echo "DONE."
