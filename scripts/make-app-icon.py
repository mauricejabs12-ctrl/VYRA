"""Zeichnet das VYRA-KI-Symbol (Planet mit Ring und Funkeln, wie Assets/VYRA-KI-256.png der Windows-Ausgabe)
in 1024 x 1024 Pixeln ohne Transparenz fuer iOS. Aufruf: python3 -I scripts/make-app-icon.py <ziel.png>"""
import sys, math
from PIL import Image, ImageDraw, ImageFilter

S = 4  # Supersampling
W = 1024 * S

def lerp(a, b, t): return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))

# Hintergrund: tiefes Nachtblau mit sanftem Verlauf (wie das Original: #1D1A3B oben, #17162F unten)
bg = Image.new("RGB", (W, W))
px = bg.load()
top, bottom = (31, 27, 62), (20, 19, 44)
for y in range(W):
    c = lerp(top, bottom, y / (W - 1))
    for x in range(W):
        px[x, y] = c

# Leuchten hinter dem Planeten
glow = Image.new("L", (W, W), 0)
gd = ImageDraw.Draw(glow)
cx, cy, r = int(W * 0.47), int(W * 0.52), int(W * 0.30)
gd.ellipse([cx - int(r * 1.45), cy - int(r * 1.45), cx + int(r * 1.45), cy + int(r * 1.45)], fill=140)
glow = glow.filter(ImageFilter.GaussianBlur(W * 0.06))
bg = Image.composite(Image.new("RGB", (W, W), (88, 96, 220)), bg, glow.point(lambda v: int(v * 0.55)))

# Ring hinten (hinter dem Planeten)
ring = Image.new("RGBA", (W, W), (0, 0, 0, 0))
rd = ImageDraw.Draw(ring)
rw, rh = int(W * 0.78), int(W * 0.22)
box = [cx - rw // 2, cy - rh // 2, cx + rw // 2, cy + rh // 2]
rd.ellipse(box, outline=(96, 222, 246, 255), width=int(W * 0.022))
ring = ring.rotate(-16, resample=Image.BICUBIC, center=(cx, cy))
back = ring.copy()
mask_front = Image.new("L", (W, W), 0)
ImageDraw.Draw(mask_front).rectangle([0, cy, W, W], fill=255)
mask_front = mask_front.rotate(-16, resample=Image.BICUBIC, center=(cx, cy))
img = bg.convert("RGBA")
img.alpha_composite(back)

# Planet: Kugel mit Verlauf (hell oben links, violett unten rechts)
planet = Image.new("RGBA", (W, W), (0, 0, 0, 0))
pp = planet.load()
lx, ly = cx - r * 0.38, cy - r * 0.42
for y in range(cy - r, cy + r + 1):
    for x in range(cx - r, cx + r + 1):
        dx, dy = x - cx, y - cy
        d = dx * dx + dy * dy
        if d > r * r:
            continue
        dist = math.hypot(x - lx, y - ly)
        t = min(1.0, dist / (r * 1.75))
        base = lerp((132, 152, 246), (88, 64, 200), t)
        hl = math.exp(-(dist / (r * 0.42)) ** 2)  # weiches Glanzlicht
        c = lerp(base, (200, 230, 252), hl * 0.85)
        edge = math.sqrt(d) / r
        a = 255 if edge < 0.985 else int(255 * (1 - (edge - 0.985) / 0.015))
        pp[x, y] = c + (max(0, a),)
img.alpha_composite(planet)

# Ring vorne (ueber dem Planeten)
front = Image.new("RGBA", (W, W), (0, 0, 0, 0))
front.paste(ring, (0, 0), Image.composite(ring.getchannel("A"), Image.new("L", (W, W), 0), mask_front))
img.alpha_composite(front)

# Funkeln oben rechts
star = Image.new("RGBA", (W, W), (0, 0, 0, 0))
sd = ImageDraw.Draw(star)
sx, sy, L, th = int(W * 0.75), int(W * 0.24), int(W * 0.085), int(W * 0.012)
sd.polygon([(sx, sy - L), (sx + th, sy - th), (sx + L, sy), (sx + th, sy + th), (sx, sy + L), (sx - th, sy + th), (sx - L, sy), (sx - th, sy - th)], fill=(255, 255, 255, 255))
img.alpha_composite(star.filter(ImageFilter.GaussianBlur(S * 0.6)))

out = img.convert("RGB").resize((1024, 1024), Image.LANCZOS)
out.save(sys.argv[1], "PNG")
print("ok", sys.argv[1])
