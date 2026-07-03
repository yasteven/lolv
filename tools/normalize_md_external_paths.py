#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path.cwd()
write = "--write" in sys.argv

SKIP_DIRS = {
    ".git",
    "build",
    "target",
    ".venv",
    "node_modules",
}

REPLACEMENTS = [
    ("~/1tb/ext", "$EXTERNAL"),
    ("$HOME/1tb/ext", "$EXTERNAL"),
    ("/home/seejn/1tb/ext", "$EXTERNAL"),

    ("~/1tb/see/1-c0d3/vhdl/lolv", "$WORKDIR"),
    ("$HOME/1tb/see/1-c0d3/vhdl/lolv", "$WORKDIR"),
    ("/home/seejn/1tb/see/1-c0d3/vhdl/lolv", "$WORKDIR"),

    ("~/1tb/see/1-c0d3/vhdl", "$WORKROOT"),
    ("$HOME/1tb/see/1-c0d3/vhdl", "$WORKROOT"),
    ("/home/seejn/1tb/see/1-c0d3/vhdl", "$WORKROOT"),

    ("~/1tb", "$EXTERNAL"),
    ("$HOME/1tb", "$EXTERNAL"),
    ("/home/seejn/1tb", "$EXTERNAL"),
]

changed = []

for p in sorted(ROOT.rglob("*.md")):
    if any(part in SKIP_DIRS for part in p.parts):
        continue

    old = p.read_text(errors="replace")
    new = old

    for src, dst in REPLACEMENTS:
        new = new.replace(src, dst)

    if new != old:
        changed.append(p)
        print(f"{'WRITE' if write else 'DRY'} {p}")
        for src, dst in REPLACEMENTS:
            count = old.count(src)
            if count:
                print(f"  {count:4d} x {src} -> {dst}")

        if write:
            p.write_text(new)

if not changed:
    print("No markdown path changes found.")
elif not write:
    print()
    print("Dry run only. Re-run with --write:")
    print("  python tools/normalize_md_external_paths.py --write")
