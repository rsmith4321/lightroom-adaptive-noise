#!/usr/bin/env python3
"""Build the install ZIP from tracked public plugin files and documentation."""
from pathlib import Path
import hashlib
import re
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
info = (root / 'AdaptiveNoise.lrplugin/Info.lua').read_text()
version = re.search(r'major\s*=\s*(\d+),\s*minor\s*=\s*(\d+),\s*revision\s*=\s*(\d+)', info)
if not version:
    raise SystemExit('Plugin version is missing')
tag = 'v' + '.'.join(version.groups())
tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
docs = {'README.md', 'LICENSE', 'VALIDATION.md', 'REVIEW.md', 'CHANGELOG.md'}
files = sorted(p for p in tracked if p.startswith('AdaptiveNoise.lrplugin/') or p in docs)
if any('Private' in p for p in files) or 'Private' in info:
    raise SystemExit('Private helper found in release files')
for needed in ['AdaptiveNoise.lrplugin/SkipPolicy.lua', 'AdaptiveNoise.lrplugin/Main.lua']:
    if needed not in files:
        raise SystemExit('Required file is not tracked: ' + needed)
out = root / 'local/releases' / tag
out.mkdir(parents=True, exist_ok=True)
archive = out / 'AdaptiveNoise.zip'
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
    for name in files:
        z.write(root / name, name)
with zipfile.ZipFile(archive) as z:
    if z.testzip() is not None:
        raise SystemExit('ZIP integrity check failed')
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(out / 'SHA256SUMS.txt').write_text(f'{digest}  AdaptiveNoise.zip\n')
print(f'{tag}: {archive} ({archive.stat().st_size} bytes; {len(files)} files)')
print(f'SHA-256: {digest}')
