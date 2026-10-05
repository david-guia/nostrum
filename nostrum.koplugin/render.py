#!/usr/bin/env python3
"""Rejoue les tracés de render.lua avec la vraie police.

    lua render.lua | python3 render.py DroidSansMono.ttf apercu.png

L'image obtenue est ce que peint main.lua, pas une maquette : les positions
viennent du code Lua lui-même.
"""

import sys
from PIL import Image, ImageDraw, ImageFont

font_path = sys.argv[1] if len(sys.argv) > 1 else "DroidSansMono.ttf"
out = sys.argv[2] if len(sys.argv) > 2 else "apercu.png"

lines = sys.stdin.read().splitlines()
W, H = (int(v) for v in lines[0].split("\t"))
img = Image.new("L", (W, H), 0)
d = ImageDraw.Draw(img)
fonts = {}

for line in lines[1:]:
    if not line:
        continue
    parts = line.split("\t")
    if parts[0] == "R":
        x, y, w, h, c = (int(v) for v in parts[1:6])
        d.rectangle([x, y, x + w - 1, y + h - 1], fill=c)
    else:
        x, base, size, c, bold = (int(v) for v in parts[1:6])
        text = parts[6] if len(parts) > 6 else ""
        f = fonts.setdefault(size, ImageFont.truetype(font_path, size))
        # Lua passe la ligne de base ; PIL ancre en haut de l'ascendante.
        d.text((x, base - f.getmetrics()[0]), text, font=f, fill=c)
        if bold:
            d.text((x + 1, base - f.getmetrics()[0]), text, font=f, fill=c)

img.save(out)
print("écrit :", out, img.size)
