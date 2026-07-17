#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path.cwd()

REPLACEMENTS = [
    ("~/1tb/see/1-c0d3/vhdl/lolv", "$WORKDIR"),
    ("/home/seejn/1tb/see/1-c0d3/vhdl/lolv", "$WORKDIR"),
    ("~/1tb/see/1-c0d3/vhdl/", "$WORKROOT/"),
    ("/home/seejn/1tb/see/1-c0d3/vhdl/", "$WORKROOT/"),
]

SKIP_DIRS = {
    ".git",
    "build",
    "target",
    ".venv",
    "node_modules",
}

write = "--write" in sys.argv

md_files = []
for p in ROOT.rglob("*.md"):
    if any(part in SKIP_DIRS for part in p.parts):
        continue
    md_files.append(p)

changed = []

for p in sorted(md_files):
    old = p.read_text(errors="replace")
    new = old
    for a, b in REPLACEMENTS:
        new = new.replace(a, b)

    if new != old:
        changed.append(p)
        print(f"{'WRITE' if write else 'DRY'} {p}")
        for a, b in REPLACEMENTS:
            count = old.count(a)
            if count:
                print(f"  {count:4d} x {a} -> {b}")
        if write:
            p.write_text(new)

if not changed:
    print("No markdown path changes found.")
elif not write:
    print()
    print("Dry run only. Re-run with --write to modify files:")
    print("  python tools/normalize_md_workdir_paths.py --write")
