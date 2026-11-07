#!/usr/bin/env python3
"""Zeichnet das Symbol des Chronik-Scanners und schreibt Resources/AppIcon.icns.

Ein Blatt Papier mit Textzeilen und umgeknickter Ecke auf tiefgrünem Grund; ein Lichtbalken des Scanners läuft darüber,
das Blatt darunter ist noch dunkler. Aufruf: scripts/make-icon.py   (braucht Pillow und iconutil)
"""
import math, os, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFilter

S = 2048          # Zeichenfläche, danach verkleinert
def px(v): return int(v * S / 1024)

def rounded_mask(size, box, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m

def vertical_gradient(size, top, bottom):
    g = Image.new("RGBA", (size, size))
    d = ImageDraw.Draw(g)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
    return g

def render():
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    box = (px(100), px(100), px(924), px(924))
    radius = px(185)

    # Schatten des Symbols
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), mask=rounded_mask(S, (box[0], box[1] + px(14), box[2], box[3] + px(14)), radius))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(px(18))))

    # Grund: tiefes Grün
    base = vertical_gradient(S, (30, 82, 76), (12, 40, 37))
    art = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    art.paste(base, mask=rounded_mask(S, box, radius))

    # Blatt, leicht gedreht, auf eigener Ebene
    pw, ph = px(430), px(560)
    sheet = Image.new("RGBA", (pw + px(80), ph + px(80)), (0, 0, 0, 0))
    ox = oy = px(40)
    d = ImageDraw.Draw(sheet)
    fold = px(95)
    outline = [(ox, oy), (ox + pw - fold, oy), (ox + pw, oy + fold), (ox + pw, oy + ph), (ox, oy + ph)]
    d.polygon(outline, fill=(245, 240, 227, 255))
    d.polygon([(ox + pw - fold, oy), (ox + pw, oy + fold), (ox + pw - fold, oy + fold)], fill=(214, 206, 186, 255))   # Ecke
    ink = (116, 110, 96, 255)
    x0, x1 = ox + px(54), ox + pw - px(54)
    y = oy + px(128)
    d.rounded_rectangle((x0, y, x0 + px(190), y + px(26)), radius=px(13), fill=(70, 66, 56, 255))      # Überschrift
    y += px(70)
    for i, w in enumerate([1.0, 0.94, 1.0, 0.86, 1.0, 0.72, 0.0, 1.0, 0.9, 0.55]):
        if w > 0:
            d.rounded_rectangle((x0, y, x0 + int((x1 - x0) * w), y + px(15)), radius=px(7), fill=ink)
        y += px(36)
    sheet = sheet.rotate(5, resample=Image.BICUBIC, expand=True)
    sx = (S - sheet.width) // 2 + px(6)
    sy = (S - sheet.height) // 2 + px(4)
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh.paste(sheet, (sx, sy), sheet)
    # Schatten unter dem Blatt
    sheet_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sheet_shadow.paste((0, 0, 0, 110), (sx + px(10), sy + px(22)), sheet.split()[3])
    art = Image.alpha_composite(art, sheet_shadow.filter(ImageFilter.GaussianBlur(px(16))))
    art = Image.alpha_composite(art, sh)

    # Lichtbalken des Scanners: unterhalb dunkler, die Linie leuchtet
    beam_y = px(600)
    shade = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shade).rectangle((0, beam_y, S, S), fill=(8, 32, 30, 120))
    shade_masked = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shade_masked.paste(shade, mask=rounded_mask(S, box, radius))
    art = Image.alpha_composite(art, shade_masked)
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.rectangle((box[0] + px(30), beam_y - px(10), box[2] - px(30), beam_y + px(10)), fill=(94, 234, 212, 255))
    halo = glow.filter(ImageFilter.GaussianBlur(px(26)))
    art = Image.alpha_composite(art, halo)
    art = Image.alpha_composite(art, halo)
    core = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(core).rounded_rectangle((box[0] + px(30), beam_y - px(7), box[2] - px(30), beam_y + px(7)), radius=px(7), fill=(204, 255, 246, 255))
    art = Image.alpha_composite(art, core)

    # Zuschneiden auf die Symbolform, feiner Lichtrand oben
    final = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    final.paste(art, mask=rounded_mask(S, box, radius))
    canvas = Image.alpha_composite(canvas, final)
    rim = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle(box, radius=radius, outline=(255, 255, 255, 38), width=px(4))
    return Image.alpha_composite(canvas, rim)

def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "Resources")
    os.makedirs(out, exist_ok=True)
    big = render()
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for size in (16, 32, 128, 256, 512):
            big.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
            big.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(out, "AppIcon.icns")], check=True)
    big.resize((1024, 1024), Image.LANCZOS).save(os.path.join(out, "AppIcon-1024.png"))
    print("geschrieben:", os.path.join(out, "AppIcon.icns"))

if __name__ == "__main__":
    sys.exit(main())
