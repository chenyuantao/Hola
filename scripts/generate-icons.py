#!/usr/bin/env python3
"""从选定的言字标生成应用 ICNS 和菜单栏 PDF；需要 rsvg-convert、iconutil。"""
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
resources = root / 'Resources'
source = resources / 'Logo.svg'
body = source.read_text().split('>', 1)[1].rsplit('</svg>', 1)[0]
app = ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
       '<rect x="64" y="64" width="896" height="896" rx="202" fill="#EAF1E8"/>'
       '<svg x="102" y="110" width="820" height="820" viewBox="0 0 100 100" color="#346B57">'
       + body + '</svg></svg>')
menu = ('<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="12 7 76 76" color="black">'
        + body + '</svg>')
(resources / 'AppIcon.svg').write_text(app)
(resources / 'MenuBarIcon.svg').write_text(menu)
for filename in ('Logo.svg', 'AppIcon.svg', 'MenuBarIcon.svg'):
    ET.parse(resources / filename)
subprocess.run(['rsvg-convert', '-f', 'pdf', '-o', str(resources / 'MenuBarIcon.pdf'), str(resources / 'MenuBarIcon.svg')], check=True)
subprocess.run(['rsvg-convert', '-o', str(resources / 'AppIcon.png'), str(resources / 'AppIcon.svg')], check=True)
with tempfile.TemporaryDirectory() as temporary:
    iconset = Path(temporary) / 'AppIcon.iconset'
    iconset.mkdir()
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            output = iconset / f'icon_{points}x{points}{suffix}.png'
            subprocess.run(['rsvg-convert', '-w', str(points * scale), '-h', str(points * scale), '-o', str(output), str(resources / 'AppIcon.svg')], check=True)
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns')], check=True)
print('Generated AppIcon.icns and template MenuBarIcon.pdf')
