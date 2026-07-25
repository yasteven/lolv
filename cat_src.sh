#!/usr/bin/env bash
# Regenerate the AI-context dumps into info/.
#
# Excludes archived docs/tools and generated junk so the aggregate stays small
# enough to actually hand to a model.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$ROOT"

OUT_DIR="$ROOT/info"
# readlink -f exits non-zero on a missing path, which under `set -e` made
# the old script die silently. Resolve, then report clearly if absent.
OLED_ROOT="$(readlink -f "$ROOT/../../rust/oled" || true)"
SPIS_ROOT="$(readlink -f "$ROOT/../../rust/spis" || true)"
[[ -d "${OLED_ROOT:-}" ]] || { echo "ERROR: rust/oled not found" >&2; exit 1; }
[[ -d "${SPIS_ROOT:-}" ]] || { echo "ERROR: rust/spis not found" >&2; exit 1; }

DOCS_OUT="$OUT_DIR/cat_lolv_readmes.txt"
SCRIPTS_OUT="$OUT_DIR/cat_lolv_modified_scripts.txt"
OLED_OUT="$OUT_DIR/cat_rust_oled.txt"
SPIS_OUT="$OUT_DIR/cat_rust_spis_oled_transport.txt"
ALL_OUT="$OUT_DIR/cat_lolv_all.txt"

mkdir -p "$OUT_DIR"
: > "$DOCS_OUT"; : > "$SCRIPTS_OUT"; : > "$OLED_OUT"; : > "$SPIS_OUT"; : > "$ALL_OUT"

write_header() {
    { echo "================================================================"
      echo "$2"; echo "ROOT: $3"; echo "GENERATED: $(date -Is)"
      echo "================================================================"; echo
    } >> "$1"
}

append_hash_file() {
    { echo; echo "################################################################"
      echo "# FILE: $2"
      echo "################################################################"; echo
      cat "$3"; echo; } >> "$1"
}

append_slash_file() {
    { echo; echo "////////////////////////////////////////////////////////////////"
      echo "// FILE: $2"
      echo "////////////////////////////////////////////////////////////////"; echo
      cat "$3"; echo; } >> "$1"
}

# Shared prune list: build output, VCS, caches, archives, generated dumps.
PRUNE=(
  -path './.git' -prune -o
  -path './info' -prune -o
  -path './reports' -prune -o
  -path './build' -prune -o
  -path './images' -prune -o
  -path './backup' -prune -o
  -path './docs/archive' -prune -o
  -path './tools/archive' -prune -o
  -path '*/target' -prune -o
  -path '*/node_modules' -prune -o
  -path '*/__pycache__' -prune -o
  -name '.build_step_backups.*' -prune -o
)

echo "== collecting lolv docs =="
write_header "$DOCS_OUT" "LOLV DOCS" "$ROOT"
find . "${PRUNE[@]}" -type f -name '*.md' -print0 \
  | sort -z | while IFS= read -r -d '' f; do
        append_hash_file "$DOCS_OUT" "$f" "$f"
    done

echo "== collecting lolv scripts and gateware =="
write_header "$SCRIPTS_OUT" "LOLV SCRIPTS AND GATEWARE" "$ROOT"
find . "${PRUNE[@]}" -type f \
     \( -name '*.py' -o -name '*.sh' -o -name '*.v' -o -name '*.vhd' \) -print0 \
  | sort -z | while IFS= read -r -d '' f; do
        append_slash_file "$SCRIPTS_OUT" "$f" "$f"
    done

collect_rust() {
    local out="$1" root="$2" label="$3" prefix="$4"
    write_header "$out" "$label" "$root"
    find "$root" \
      -path "$root/.git" -prune -o \
      -path '*/target' -prune -o \
      -path '*/__pycache__' -prune -o \
      -type f \( -name '*.rs' -o -name '*.toml' -o -name '*.json' \
                 -o -name '*.sh' -o -name '*.md' \) -print0 \
      | sort -z | while IFS= read -r -d '' f; do
            append_slash_file "$out" "$prefix${f#$root/}" "$f"
        done
}

echo "== collecting rust/oled =="
collect_rust "$OLED_OUT" "$OLED_ROOT" "RUST OLED WORKSPACE" "../../rust/oled/"

echo "== collecting rust/spis =="
collect_rust "$SPIS_OUT" "$SPIS_ROOT" "RUST SPIS PROJECTS" "../../rust/spis/"

echo "== combining =="
write_header "$ALL_OUT" "LOLV COMPLETE AGGREGATE" "$ROOT"
cat "$DOCS_OUT" "$SCRIPTS_OUT" "$OLED_OUT" "$SPIS_OUT" >> "$ALL_OUT"

echo
echo "wrote:"
for f in "$DOCS_OUT" "$SCRIPTS_OUT" "$OLED_OUT" "$SPIS_OUT" "$ALL_OUT"; do
    printf '  %8s  %s\n' "$(du -h "$f" | cut -f1)" "${f#$ROOT/}"
done
