#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$ROOT"

OUT_DIR="$ROOT/reports"
OLED_ROOT="$(readlink -f "$ROOT/../../rust/oled")"
SPIS_ROOT="$(readlink -f "$ROOT/../../rust/spis")"

DOCS_OUT="$OUT_DIR/cat_lolv_readmes.txt"
SCRIPTS_OUT="$OUT_DIR/cat_lolv_modified_scripts.txt"
OLED_OUT="$OUT_DIR/cat_rust_oled.txt"
SPIS_OUT="$OUT_DIR/cat_rust_spis_oled_transport.txt"
ALL_OUT="$OUT_DIR/cat_lolv_all.txt"

mkdir -p "$OUT_DIR"

: > "$DOCS_OUT"
: > "$SCRIPTS_OUT"
: > "$OLED_OUT"
: > "$SPIS_OUT"
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

append_tree_inventory() {
    local out_file="$1"
    local title="$2"
    local tree_root="$3"
    local excluded_subtree="${4:-}"

    {
        echo "################################################################"
        echo "# $title FILE INVENTORY (path and byte size)"
        echo "################################################################"
        echo
        if [[ -n "$excluded_subtree" ]]; then
            find "$tree_root" \
              -path "$tree_root/.git" -prune -o \
              -path '*/target' -prune -o \
              -path '*/node_modules' -prune -o \
              -path '*/__pycache__' -prune -o \
              -path "$excluded_subtree" -prune -o \
              -type f -printf '%P\t%s bytes\n' \
            | sort
        else
            find "$tree_root" \
              -path "$tree_root/.git" -prune -o \
              -path '*/target' -prune -o \
              -path '*/node_modules' -prune -o \
              -path '*/__pycache__' -prune -o \
              -type f -printf '%P\t%s bytes\n' \
            | sort
        fi
        echo
    } >> "$out_file"
}

write_header "$DOCS_OUT" "LOLV README / DOCS" "$ROOT"
write_header "$SCRIPTS_OUT" "LOLV MODIFIED SCRIPTS / GATEWARE / CONFIGS" "$ROOT"
write_header "$OLED_OUT" "RUST OLED COMPLETE TEXT SOURCE / ASSET INVENTORY" "$OLED_ROOT"
write_header "$SPIS_OUT" "RUST SPI ASI + OLED TRANSPORT SOURCE / INVENTORY" "$SPIS_ROOT"

echo "== collecting lolv README/docs =="

find . \
  -path './.git' -prune -o \
  -path './build' -prune -o \
  -path './buildroot' -prune -o \
  -path './images' -prune -o \
  -path './target' -prune -o \
  -path './__pycache__' -prune -o \
  -path './reports' -prune -o \
  -iname '*bsi*' -prune -o \
  -type f \( -name '*.md' -o -name '*.txt' \) -print0 \
| sort -z \
| while IFS= read -r -d '' file; do
    append_hash_file "$DOCS_OUT" "$file" "$file"
done

echo "wrote $DOCS_OUT"

echo
echo "== collecting lolv scripts/gateware/configs =="

find . \
  -path './.git' -prune -o \
  -path './build' -prune -o \
  -path './buildroot' -prune -o \
  -path './images' -prune -o \
  -path './target' -prune -o \
  -path './__pycache__' -prune -o \
  -path './reports' -prune -o \
  -iname '*bsi*' -prune -o \
  -type f \( \
      -name '*.py' -o \
      -name '*.sh' -o \
      -name '*.c' -o \
      -name '*.h' -o \
      -name '*.rs' -o \
      -name '*.vhd' -o \
      -name '*.vhdl' -o \
      -name '*.v' -o \
      -name '*.sv' -o \
      -name '*.dts' -o \
      -name '*.dtsi' -o \
      -name '*.json' -o \
      -name '*.toml' -o \
      -name '*.yaml' -o \
      -name '*.yml' -o \
      -name '*.config' -o \
      -name '*.cfg' -o \
      -name '*.lpf' -o \
      -name '*.xdc' -o \
      -name '*.sdc' -o \
      -name '*defconfig' -o \
      -name 'Config.in' -o \
      -name '*.mk' -o \
      -name 'Makefile' -o \
      -name '.gitignore' \
    \) -print0 \
| sort -z \
| while IFS= read -r -d '' file; do
    append_slash_file "$SCRIPTS_OUT" "$file" "$file"
done

echo "wrote $SCRIPTS_OUT"

echo
echo "== collecting complete ../../rust/oled text source and asset inventory =="

if [[ ! -d "$OLED_ROOT" ]]; then
    echo "ERROR: missing OLED workspace: $OLED_ROOT" >&2
    exit 1
fi

append_tree_inventory "$OLED_OUT" "RUST OLED WORKSPACE" "$OLED_ROOT"

find "$OLED_ROOT" \
  -path "$OLED_ROOT/.git" -prune -o \
  -path '*/target' -prune -o \
  -path '*/node_modules' -prune -o \
  -path '*/__pycache__' -prune -o \
  -type f \( \
      -name '*.rs' -o \
      -name '*.toml' -o \
      -name '*.lock' -o \
      -name '*.json' -o \
      -name '*.md' -o \
      -name '*.txt' -o \
      -name '*.html' -o \
      -name '*.htm' -o \
      -name '*.css' -o \
      -name '*.js' -o \
      -name '*.mjs' -o \
      -name '*.ts' -o \
      -name '*.svg' -o \
      -name '*.xml' -o \
      -name '*.yaml' -o \
      -name '*.yml' -o \
      -name '*.sh' -o \
      -name '*.py' -o \
      -name '*.c' -o \
      -name '*.h' -o \
      -name '*.config' -o \
      -name '*.service' -o \
      -name 'config' -o \
      -name 'rust-toolchain' -o \
      -name 'Makefile' -o \
      -name 'LICENSE*' -o \
      -name '.gitignore' -o \
      -name '.gitmodules' \
    \) -print0 \
| sort -z \
| while IFS= read -r -d '' file; do
    rel="${file#"$OLED_ROOT"/}"
    append_slash_file "$OLED_OUT" "../../rust/oled/$rel" "$file"
done

echo "wrote $OLED_OUT"

echo
echo "== collecting relevant ../../rust/spis source and inventory =="

if [[ ! -d "$SPIS_ROOT" ]]; then
    echo "ERROR: missing SPI workspace: $SPIS_ROOT" >&2
    exit 1
fi

# BSI is deliberately retired from this report. The root files, ASI, and the
# future oled_web_pipe are captured automatically.
append_tree_inventory \
    "$SPIS_OUT" \
    "RUST SPI RELEVANT WORKSPACE" \
    "$SPIS_ROOT" \
    "$SPIS_ROOT/basic_spi_io"

find "$SPIS_ROOT" \
  -path "$SPIS_ROOT/.git" -prune -o \
  -path "$SPIS_ROOT/basic_spi_io" -prune -o \
  -path '*/target' -prune -o \
  -path '*/node_modules' -prune -o \
  -path '*/__pycache__' -prune -o \
  -type f \( \
      -name '*.rs' -o \
      -name '*.toml' -o \
      -name '*.lock' -o \
      -name '*.json' -o \
      -name '*.md' -o \
      -name '*.txt' -o \
      -name '*.html' -o \
      -name '*.css' -o \
      -name '*.js' -o \
      -name '*.svg' -o \
      -name '*.yaml' -o \
      -name '*.yml' -o \
      -name '*.sh' -o \
      -name '*.py' -o \
      -name '*.c' -o \
      -name '*.h' -o \
      -name '*.config' -o \
      -name 'config' -o \
      -name 'rust-toolchain' -o \
      -name 'Makefile' -o \
      -name 'LICENSE*' -o \
      -name '.gitignore' -o \
      -name '.gitmodules' \
    \) -print0 \
| sort -z \
| while IFS= read -r -d '' file; do
    rel="${file#"$SPIS_ROOT"/}"
    append_slash_file "$SPIS_OUT" "../../rust/spis/$rel" "$file"
done

echo "wrote $SPIS_OUT"

{
    echo "================================================================"
    echo "LOLV COMPLETE AGGREGATE"
    echo "ROOT: $ROOT"
    echo "GENERATED: $(date -Is)"
    echo "================================================================"
    echo
    echo "Included sections:"
    echo "  1. LOLV README/docs"
    echo "  2. LOLV scripts/gateware/configs"
    echo "  3. ../../rust/oled complete text source and asset inventory"
    echo "  4. ../../rust/spis root + ASI + OLED transport (BSI excluded)"
    echo
    echo "Generated component files:"
    echo "  $DOCS_OUT"
    echo "  $SCRIPTS_OUT"
    echo "  $OLED_OUT"
    echo "  $SPIS_OUT"
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
    echo "# SECTION 2: LOLV SCRIPTS / GATEWARE / CONFIGS"
    echo "################################################################"
    echo
    cat "$SCRIPTS_OUT"
    echo
    echo
    echo "################################################################"
    echo "# SECTION 3: RUST OLED COMPLETE SOURCE / ASSET INVENTORY"
    echo "################################################################"
    echo
    cat "$OLED_OUT"
    echo
    echo
    echo "################################################################"
    echo "# SECTION 4: RUST SPI ASI + OLED TRANSPORT SOURCE / INVENTORY"
    echo "################################################################"
    echo
    cat "$SPIS_OUT"
    echo
} >> "$ALL_OUT"

echo "wrote $ALL_OUT"

echo
echo "== aggregate sizes =="
ls -lh "$DOCS_OUT" "$SCRIPTS_OUT" "$OLED_OUT" "$SPIS_OUT" "$ALL_OUT"

echo
echo "== OLED text files captured =="
grep -c '^// FILE: ../../rust/oled/' "$OLED_OUT" || true

echo
echo "== relevant SPI text files captured =="
grep -c '^// FILE: ../../rust/spis/' "$SPIS_OUT" || true

echo
echo "DONE."
