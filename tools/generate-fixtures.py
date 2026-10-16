#!/usr/bin/env python3
"""Rebuild synthetic SDK test images; development-only Pillow/exiftool required."""
from pathlib import Path
import subprocess
from PIL import Image

root = Path(__file__).resolve().parents[1] / 'AdaptiveNoise.lrplugin' / 'fixtures'
root.mkdir(exist_ok=True)
for iso in (100, 3250, 6400):
    image = Image.new('RGB', (256, 256))
    image.putdata([(x, y, (x + y) // 2) for y in range(256) for x in range(256)])
    path = root / f'iso-{iso}.jpg'
    image.save(path, quality=92)
    subprocess.run([
        'exiftool', '-overwrite_original', '-Make=AdaptiveNoise',
        '-Model=Generated Test Camera', f'-ISO={iso}',
        '-ExposureTime=1/125', '-FNumber=4', str(path),
    ], check=True)
