#!/usr/bin/env python3
"""Icône du Dock, tirée de icone.png (fond transparent).

    python3 make-icon.py sortie.iconset

Écrit un dossier .iconset ; build.sh le passe à iconutil.
"""

import os
import sys
from PIL import Image

OUT = sys.argv[1] if len(sys.argv) > 1 else "nostrum.iconset"
os.makedirs(OUT, exist_ok=True)

S = 1024
src = Image.open(os.path.join(os.path.dirname(__file__), "icone.png")).convert("RGBA")
# Boîtier seul, sans l'ombre portée.
src = src.crop(src.getchannel("A").point(lambda v: 255 if v > 250 else 0).getbbox())
# Carré plein bord à bord : macOS 26+ le découpe lui-même en squircle ; une
# icône à marges transparentes serait enfermée dans un cadre gris.
src = src.resize((S, S), Image.LANCZOS)
big = Image.new("RGBA", (S, S), src.getpixel((40, S // 2))[:3] + (255,))
big.alpha_composite(src)

for size in (16, 32, 64, 128, 256, 512):
    big.resize((size, size), Image.LANCZOS).save(os.path.join(OUT, "icon_%dx%d.png" % (size, size)))
    big.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(OUT, "icon_%dx%d@2x.png" % (size, size)))

print("iconset écrit :", OUT)
