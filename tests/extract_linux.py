#!/usr/bin/env python3
"""Extract the embedded Linux backends for isolated syntax and integration checks."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
output = Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=True)
for stem, marker in [('install', 'INSTALLER'), ('uninstall', 'UNINSTALLER')]:
    source = (root / f'{stem}_win.ps1').read_text()
    start = source.index(f'# BEGIN EMBEDDED LINUX {marker}')
    start = source.index("return @'\n", start) + len("return @'\n")
    end = source.index("\n'@", start)
    (output / f'{stem}_wsl.sh').write_text(source[start:end] + '\n')
