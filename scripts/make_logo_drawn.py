#!/usr/bin/env python3
"""Draws the FreeFlow logo in the Rhythme look: a pearly lilac, blush and peach speech bubble, a kawaii face,
and a glowing flow line through it (the way Rhythme's heart has its pulse line).
Writes assets/brand/: logo-mark.png (bubble, transparent), logo-icon.png (app icon), logo-lockup.png, AppIcon.icns.
Run:  /opt/homebrew/bin/python3.14 scripts/make_logo.py
"""
import math, os, subprocess, sys, shutil, tempfile
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "brand")
FONT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "fonts", "Newsreader-SemiBold.ttf")
N = 2048   # drawn at 2048, saved at 1024

def hexc(h, a=255):
    h = h.lstrip("#"); return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)

def blur(img, r): return img.filter(ImageFilter.GaussianBlur(r))

def smooth_mask(draw_fn, radius=14):
    m = Image.new("L", (N, N), 0); d = ImageDraw.Draw(m); draw_fn(d)
    m = blur(m, radius); return m.point(lambda v: 255 if v > 127 else 0).filter(ImageFilter.GaussianBlur(1.6))

def gradient_rgb(stops, angle_deg=45):
    ys, xs = np.mgrid[0:N, 0:N].astype(np.float32)
    a = math.radians(angle_deg); t = (xs * math.cos(a) + ys * math.sin(a))
    t = (t - t.min()) / (t.max() - t.min())
    cols = np.array([[int(s[1][i:i+2], 16) for i in (1, 3, 5)] for s in stops], np.float32)
    pos = np.array([s[0] for s in stops], np.float32)
    out = np.zeros((N, N, 3), np.float32)
    for c in range(3): out[..., c] = np.interp(t, pos, cols[:, c])
    return out

def radial(cx, cy, r):
    ys, xs = np.mgrid[0:N, 0:N].astype(np.float32)
    d = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2) / r
    return np.clip(1 - d, 0, 1) ** 1.6

def soft(mask, color, radius=0.0, alpha=1.0):
    """A flat colour through a (blurred) mask. Blurring a transparent RGBA layer would leave dark fringes, so only the mask is blurred."""
    m = blur(mask, radius) if radius else mask
    if alpha != 1.0: m = m.point(lambda v: int(v * alpha))
    layer = Image.new("RGBA", (N, N), tuple(color[:3]) + (0,)); layer.putalpha(m); return layer

def L(draw_fn):
    m = Image.new("L", (N, N), 0); draw_fn(ImageDraw.Draw(m)); return m

def star_pts(cx, cy, r):
    pts = []
    for i in range(8):
        ang = math.pi / 4 * i - math.pi / 2
        rr = r if i % 2 == 0 else r * 0.26
        pts.append((cx + rr * math.cos(ang), cy + rr * math.sin(ang)))
    return pts

def bubble():
    """The speech bubble with face and flow line, on a transparent 2048 canvas."""
    cx, cy, R = 1024, 940, 600
    def shape(d):
        d.ellipse((cx - R, cy - R, cx + R, cy + R), fill=255)
        d.polygon([(600, 1380), (540, 1640), (880, 1500)], fill=255)
    mask = smooth_mask(shape, 40)

    # pearly body: lilac at the top left, blush in the middle, peach at the bottom right, a soft light in the centre
    base = gradient_rgb([(0, "#bda6ea"), (0.45, "#f1bfdc"), (1, "#fcd8b2")], 52)
    glow = radial(cx - 40, cy - 120, 700)[..., None]
    base = base * (1 - 0.40 * glow) + np.array([255, 249, 244], np.float32) * (0.40 * glow)
    inner = np.asarray(blur(mask, 50), np.float32) / 255
    rim = np.clip(1 - inner, 0, 1)[..., None]
    base = base * (1 - 0.10 * rim) + np.array([190, 165, 235], np.float32) * (0.10 * rim)
    img = Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB").convert("RGBA")

    # pearl shine
    img = Image.alpha_composite(img, soft(L(lambda d: d.ellipse((cx - 430, cy - 470, cx - 150, cy - 360), fill=255)), (255, 255, 255), 10, 0.85))
    img = Image.alpha_composite(img, soft(L(lambda d: d.ellipse((cx - 480, cy - 340, cx - 410, cy - 280), fill=255)), (255, 255, 255), 3, 0.95))
    img = Image.alpha_composite(img, soft(L(lambda d: d.ellipse((cx + 330, cy + 120, cx + 520, cy + 330), fill=255)), (255, 236, 214), 60, 0.55))

    # the flow line: one smooth wave, flat at both ends, glowing
    xs = np.linspace(560, 1490, 500)
    t = (xs - 560) / 930
    ys = 1262 - 112 * np.sin(2 * math.pi * 1.5 * t) * np.sin(math.pi * t) ** 0.6
    pts = [(float(x), float(y)) for x, y in zip(xs, ys)]
    def line(width):
        def f(d):
            d.line(pts, fill=255, width=width, joint="curve")
            for p in (pts[0], pts[-1]): d.ellipse((p[0] - width / 2, p[1] - width / 2, p[0] + width / 2, p[1] + width / 2), fill=255)
        return L(f)
    img = Image.alpha_composite(img, soft(line(60), (255, 255, 255), 34, 0.95))
    img = Image.alpha_composite(img, soft(line(30), (255, 255, 255), 1.4, 1.0))

    # face
    face = Image.new("RGBA", (N, N), (255, 255, 255, 0)); fd = ImageDraw.Draw(face)
    for ex in (800, 1248):
        fd.ellipse((ex - 74, 670, ex + 74, 864), fill=hexc("#2a1d4a"))
        fd.ellipse((ex - 62, 750, ex + 62, 856), fill=hexc("#5b3f93"))
        fd.ellipse((ex - 62, 680, ex + 62, 800), fill=hexc("#2a1d4a"))
        fd.ellipse((ex - 38, 702, ex + 6, 746), fill=(255, 255, 255, 255))
        fd.ellipse((ex + 22, 788, ex + 46, 812), fill=(255, 255, 255, 235))
    img = Image.alpha_composite(img, face)
    img = Image.alpha_composite(img, soft(L(lambda d: [d.ellipse((bx - 96, 868, bx + 96, 960), fill=255) for bx in (668, 1380)]), (244, 138, 164), 24, 0.62))
    def mouth(d):
        d.arc((944, 846, 1104, 986), start=25, end=155, fill=255, width=28)
        for a in (25, 155):
            px = 1024 + 80 * math.cos(math.radians(a)); py = 916 + 70 * math.sin(math.radians(a))
            d.ellipse((px - 14, py - 14, px + 14, py + 14), fill=255)
    img = Image.alpha_composite(img, soft(L(mouth), (207, 99, 130), 1.2, 1.0))

    out = Image.new("RGBA", (N, N), (255, 255, 255, 0)); out.paste(img, (0, 0), mask)
    halo = soft(mask, (255, 255, 255), 44, 0.5)
    return Image.alpha_composite(halo, out)

def sparkles():
    m = L(lambda d: [d.polygon(star_pts(x, y, r), fill=255) for x, y, r in ((1668, 560, 96), (1790, 770, 48), (390, 580, 42))])
    return Image.alpha_composite(soft(m, (255, 255, 255), 14, 0.9), soft(m, (255, 255, 255), 0, 1.0))

def icon_background():
    inset = 210; size = N - 2 * inset
    m = Image.new("L", (N, N), 0); ImageDraw.Draw(m).rounded_rectangle((inset, inset, inset + size, inset + size), radius=int(size * 0.225), fill=255)
    g = gradient_rgb([(0, "#e9def7"), (1, "#cdb9ea")], 80)
    r = radial(N * 0.42, N * 0.30, N * 0.8)[..., None]
    g = g * (1 - 0.5 * r) + np.array([252, 248, 255], np.float32) * (0.5 * r)
    bg = Image.fromarray(np.clip(g, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    out = Image.new("RGBA", (N, N), (255, 255, 255, 0)); out.paste(bg, (0, 0), m)
    return out

def save(img, name, size=1024):
    p = os.path.join(OUT, name); img.resize((size, size), Image.LANCZOS).save(p); print("wrote", p)

def main():
    os.makedirs(OUT, exist_ok=True)
    b = bubble()
    # the bubble alone, cropped to its edge with a small margin
    bb = b.getbbox(); pad = 60
    mark = b.crop((bb[0] - pad, bb[1] - pad, bb[2] + pad, bb[3] + pad))
    side = max(mark.size); sq = Image.new("RGBA", (side, side), (255, 255, 255, 0)); sq.paste(mark, ((side - mark.size[0]) // 2, (side - mark.size[1]) // 2))
    sq.resize((1024, 1024), Image.LANCZOS).save(os.path.join(OUT, "logo-mark.png")); print("wrote logo-mark.png")

    icon = Image.alpha_composite(icon_background(), sparkles())
    scaled = b.resize((int(N * 0.82), int(N * 0.82)), Image.LANCZOS)
    icon.alpha_composite(scaled, ((N - scaled.size[0]) // 2 - 6, (N - scaled.size[1]) // 2 + 2))
    save(icon, "logo-icon.png")

    # lockup: mark + wordmark
    f = ImageFont.truetype(FONT, 520)
    text = "FreeFlow"; tb = f.getbbox(text)
    h = 1000; mk = sq.resize((h, h), Image.LANCZOS)
    W = h + 80 + (tb[2] - tb[0]) + 60
    lock = Image.new("RGBA", (W, h), (255, 255, 255, 0)); lock.alpha_composite(mk, (0, 0))
    d = ImageDraw.Draw(lock); d.text((h + 80 - tb[0], (h - (tb[3] - tb[1])) // 2 - tb[1] + 20), text, font=f, fill=hexc("#5a4274"))
    lock.save(os.path.join(OUT, "logo-lockup.png")); print("wrote logo-lockup.png")

    # app icon set -> icns
    master = Image.open(os.path.join(OUT, "logo-icon.png")).convert("RGBA")
    tmp = tempfile.mkdtemp(suffix=".iconset")
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}.png" if scale == 1 else f"icon_{base}x{base}@2x.png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(tmp, name))
    subprocess.run(["iconutil", "-c", "icns", tmp, "-o", os.path.join(OUT, "AppIcon.icns")], check=True)
    shutil.rmtree(tmp); print("wrote AppIcon.icns")

if __name__ == "__main__":
    main()
