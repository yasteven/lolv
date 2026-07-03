#!/usr/bin/env bash
set -euo pipefail

# cat_src.sh
#
# Aggregate the lolv/ project into review-friendly text dumps.
#
# Run from:
#   $WORKROOT/lolv
#
# Outputs:
#   reports/cat_lolv_readmes.txt
#   reports/cat_lolv_modified_scripts.txt
#   reports/cat_lolv_all.txt

ROOT="$(pwd)"
OUT_DIR="./reports"

DOCS_OUT="$OUT_DIR/cat_lolv_readmes.txt"
SCRIPTS_OUT="$OUT_DIR/cat_lolv_modified_scripts.txt"
ALL_OUT="$OUT_DIR/cat_lolv_all.txt"

mkdir -p "$OUT_DIR"

: > "$DOCS_OUT"
: > "$SCRIPTS_OUT"
: > "$ALL_OUT"

write_header() {
    local out_file="$1"
    local title="$2"

    {
        echo "================================================================"
        echo "$title"
        echo "ROOT: $ROOT"
        echo "GENERATED: $(date -Is)"
        echo "================================================================"
        echo
    } >> "$out_file"
}

append_file_hash() {
    local out_file="$1"
    local file_path="$2"

    {
        echo
        echo "################################################################"
        echo "# FILE: $file_path"
        echo "################################################################"
        echo
        cat "$file_path"
        echo
    } >> "$out_file"
}

append_file_slash() {
    local out_file="$1"
    local file_path="$2"

    {
        echo
        echo "////////////////////////////////////////////////////////////////"
        echo "// FILE: $file_path"
        echo "////////////////////////////////////////////////////////////////"
        echo
        cat "$file_path"
        echo
    } >> "$out_file"
}

write_header "$DOCS_OUT" "LOLV README / DOCS"
write_header "$SCRIPTS_OUT" "LOLV MODIFIED SCRIPTS / GATEWARE / CONFIGS"

echo "== collecting lolv README/docs =="

find . \
  -path './.git' -prune -o \
  -path './build' -prune -o \
  -path './images' -prune -o \
  -path './__pycache__' -prune -o \
  -path './reports/cat_*' -prune -o \
  -type f \( -name '*.md' -o -name '*.txt' \) -print \
| sort \
| while read -r doc_file; do
    append_file_hash "$DOCS_OUT" "$doc_file"
done

echo "wrote $DOCS_OUT"

echo
echo "== collecting lolv modified scripts/gateware/configs =="

{
  find . \
    -path './.git' -prune -o \
    -path './build' -prune -o \
    -path './images' -prune -o \
    -path './__pycache__' -prune -o \
    -path './reports' -prune -o \
    -type f \( \
      -name '*.py' -o \
      -name '*.sh' -o \
      -name '*.vhd' -o \
      -name '*.vhdl' -o \
      -name '*.v' -o \
      -name '*.dts' -o \
      -name '*.dtsi' -o \
      -name '*.json' -o \
      -name '*.config' -o \
      -name '*defconfig' -o \
      -name 'Config.in' -o \
      -name '*.mk' \
    \) -print
} \
| sort \
| while read -r src_file; do
    append_file_slash "$SCRIPTS_OUT" "$src_file"
done

echo "wrote $SCRIPTS_OUT"

echo
echo "== writing combined lolv aggregate =="

{
    echo "================================================================"
    echo "LOLV COMPLETE AGGREGATE"
    echo "ROOT: $ROOT"
    echo "GENERATED: $(date -Is)"
    echo "================================================================"
    echo
    echo "Included sections:"
    echo "  1. README/docs"
    echo "  2. Modified scripts/gateware/configs"
    echo
    echo "Generated component files:"
    echo "  $DOCS_OUT"
    echo "  $SCRIPTS_OUT"
    echo
    echo
    echo "################################################################"
    echo "# SECTION 1: README / DOCS"
    echo "################################################################"
    echo
    cat "$DOCS_OUT"
    echo
    echo
    echo "################################################################"
    echo "# SECTION 2: MODIFIED SCRIPTS / GATEWARE / CONFIGS"
    echo "################################################################"
    echo
    cat "$SCRIPTS_OUT"
    echo
} >> "$ALL_OUT"

echo "wrote $ALL_OUT"

echo
echo "DONE."
echo "Docs/readmes aggregate: $DOCS_OUT"
echo "Modified scripts aggregate: $SCRIPTS_OUT"
echo "Combined aggregate: $ALL_OUT"
