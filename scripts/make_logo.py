#!/usr/bin/env python3
"""FreeFlow logo from the painted mascot (assets/brand/mascot.png, cut from the Seedream picture): the pearly bubble on
a soft lilac app-icon tile, with a glowing flow line across it and a few sparkles, in Rhythme's style.
Writes assets/brand/: logo-mark.png, logo-icon.png, logo-lockup.png, AppIcon.icns.
Run:  /opt/homebrew/bin/python3.14 scripts/make_logo.py
(scripts/make_logo_drawn.py is the earlier version that draws the bubble in code, if the painted picture is not there.)"""
import importlib.util, math, os, shutil, subprocess, tempfile
import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("drawn", os.path.join(HERE, "make_logo_drawn.py"))
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
N, OUT = D.N, D.OUT

BUBBLE = os.path.join(OUT, "logo-bubble.png")  # the painted bubble with its own glowing wave (Seedream, keyed), preferred when present

def mascot_layer(height):
    m = Image.open(BUBBLE if os.path.exists(BUBBLE) else os.path.join(OUT, "mascot.png")).convert("RGBA")
    m = m.crop(m.getbbox())
    w = round(m.width * height / m.height)
    return m.resize((w, height), Image.LANCZOS)

def flow_line(alpha_mask, origin, size):
    """A glowing white wave across the lower part of the bubble, only where the bubble is."""
    ox, oy = origin; w, h = size
    xs = np.linspace(ox + 0.12 * w, ox + 0.90 * w, 500)
    t = (xs - xs.min()) / (xs.max() - xs.min())
    ys = oy + 0.70 * h - 0.075 * h * np.sin(2 * math.pi * 1.5 * t) * np.sin(math.pi * t) ** 0.6
    pts = [(float(x), float(y)) for x, y in zip(xs, ys)]
    def line(width):
        def f(d):
            d.line(pts, fill=255, width=width, joint="curve")
            for p in (pts[0], pts[-1]): d.ellipse((p[0] - width / 2, p[1] - width / 2, p[0] + width / 2, p[1] + width / 2), fill=255)
        return D.L(f)
    inside = alpha_mask
    glow = ImageChops.multiply(line(64).filter(ImageFilter.GaussianBlur(30)), inside.filter(ImageFilter.GaussianBlur(6)))
    crisp = ImageChops.multiply(line(30).filter(ImageFilter.GaussianBlur(1.2)), inside)
    layer = Image.new("RGBA", (N, N), (255, 255, 255, 0)); layer.putalpha(glow.point(lambda v: int(v * 0.9)))
    top = Image.new("RGBA", (N, N), (255, 255, 255, 0)); top.putalpha(crisp)
    return Image.alpha_composite(layer, top)

def scene(height):
    """The mascot and its flow line on a transparent 2048 canvas."""
    m = mascot_layer(height)
    ox, oy = (N - m.width) // 2, (N - m.height) // 2
    canvas = Image.new("RGBA", (N, N), (255, 255, 255, 0)); canvas.alpha_composite(m, (ox, oy))
    alpha = canvas.getchannel("A")
    halo = D.soft(alpha, (255, 255, 255), 50, 0.55)
    out = Image.alpha_composite(halo, canvas)
    if os.path.exists(BUBBLE): return out  # the painting already carries the flow line
    return Image.alpha_composite(out, flow_line(alpha, (ox, oy), m.size))

def tile():
    """The app-icon tile: a richer lilac than the pale page colour, so the pearly bubble stands out, with a soft light behind it."""
    inset = 210; size = N - 2 * inset
    m = Image.new("L", (N, N), 0); ImageDraw.Draw(m).rounded_rectangle((inset, inset, inset + size, inset + size), radius=int(size * 0.225), fill=255)
    g = D.gradient_rgb([(0, "#d8c6f3"), (1, "#a98fdc")], 75)
    r = D.radial(N * 0.50, N * 0.46, N * 0.62)[..., None]
    g = g * (1 - 0.45 * r) + np.array([246, 238, 255], np.float32) * (0.45 * r)
    bg = Image.fromarray(np.clip(g, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    out = Image.new("RGBA", (N, N), (255, 255, 255, 0)); out.paste(bg, (0, 0), m)
    return out

def main():
    os.makedirs(OUT, exist_ok=True)
    s = scene(1240)
    bb = s.getbbox(); pad = 70
    mark = s.crop((bb[0] - pad, bb[1] - pad, bb[2] + pad, bb[3] + pad))
    side = max(mark.size); sq = Image.new("RGBA", (side, side), (255, 255, 255, 0)); sq.paste(mark, ((side - mark.width) // 2, (side - mark.height) // 2))
    sq.resize((1024, 1024), Image.LANCZOS).save(os.path.join(OUT, "logo-mark.png")); print("wrote logo-mark.png")

    icon = Image.alpha_composite(tile(), D.sparkles())
    icon = Image.alpha_composite(icon, scene(1150 if os.path.exists(BUBBLE) else 1220))
    D.save(icon, "logo-icon.png")

    f = ImageFont.truetype(D.FONT, 520); text = "FreeFlow"; tb = f.getbbox(text)
    h = 1000; mk = sq.resize((h, h), Image.LANCZOS); W = h + 80 + (tb[2] - tb[0]) + 60
    lock = Image.new("RGBA", (W, h), (255, 255, 255, 0)); lock.alpha_composite(mk, (0, 0))
    ImageDraw.Draw(lock).text((h + 80 - tb[0], (h - (tb[3] - tb[1])) // 2 - tb[1] + 20), text, font=f, fill=D.hexc("#5a4274"))
    lock.save(os.path.join(OUT, "logo-lockup.png")); print("wrote logo-lockup.png")

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
