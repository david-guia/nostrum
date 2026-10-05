#!/usr/bin/env python3
"""Icône du Dock, même vocabulaire graphique que l'écran du Kindle.

    python3 make-icon.py sortie.iconset

Écrit un dossier .iconset ; install-agent.sh le passe à iconutil.
"""

import os
import sys
from PIL import Image, ImageDraw

OUT = sys.argv[1] if len(sys.argv) > 1 else "nostrum.iconset"
os.makedirs(OUT, exist_ok=True)

S = 1024
BG, INK, DIM, FAINT = (10, 10, 10, 255), (255, 255, 255, 255), (168, 168, 168, 255), (96, 96, 96, 255)


def render(size):
    """Tracé à 1024 puis réduction : les traits fins restent nets."""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Champ arrondi façon icône macOS, avec la marge que le système attend.
    pad, radius = 92, 200
    d.rounded_rectangle([pad, pad, S - pad, S - pad], radius=radius, fill=BG)

    # Cadre double + équerres, comme le cadre de l'écran.
    d.rounded_rectangle([pad + 46, pad + 46, S - pad - 46, S - pad - 46],
                        radius=radius - 40, outline=DIM, width=6)
    d.rounded_rectangle([pad + 76, pad + 76, S - pad - 76, S - pad - 76],
                        radius=radius - 66, outline=INK, width=10)

    long_, thick = 150, 18
    for cx, cy, sx, sy in ((pad + 150, pad + 76, 1, 1), (S - pad - 150, pad + 76, -1, 1),
                           (pad + 150, S - pad - 76, 1, -1), (S - pad - 150, S - pad - 76, -1, -1)):
        for dx, dy in ((long_, thick), (thick, long_)):
            xs = sorted([cx, cx + sx * dx])
            ys = sorted([cy, cy + sy * dy])
            d.rectangle([xs[0], ys[0], xs[1], ys[1]], fill=INK)

    # Le « N » de Nostrum, tracé en barres : pas de dépendance à une police.
    w, h = 210, 330
    cx, cy = S // 2, S // 2 - 40
    x0, y0 = cx - w // 2, cy - h // 2
    bar = 46
    d.rectangle([x0, y0, x0 + bar, y0 + h], fill=INK)
    d.rectangle([x0 + w - bar, y0, x0 + w, y0 + h], fill=INK)
    d.line([(x0 + bar // 2, y0), (x0 + w - bar // 2, y0 + h)], fill=INK, width=bar)

    # Rangée de tirets sous le sigle, le séparateur de la passerelle.
    tx = cx - 200
    while tx < cx + 200:
        d.rectangle([tx, cy + h // 2 + 70, tx + 6, cy + h // 2 + 106], fill=FAINT)
        tx += 26

    return img.resize((size, size), Image.LANCZOS)


for size in (16, 32, 64, 128, 256, 512):
    render(size).save(os.path.join(OUT, "icon_%dx%d.png" % (size, size)))
    render(size * 2).save(os.path.join(OUT, "icon_%dx%d@2x.png" % (size, size)))

print("iconset écrit :", OUT)
