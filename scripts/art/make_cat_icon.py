#!/usr/bin/env python3
"""The cute-cat app icon: the Rhythme kitten on a soft lilac and blush tile.
Writes assets/brand/logo-icon-cat.png and assets/brand/AppIcon-cat.icns (the Mac icon, a rounded tile with room around it)
and ios/App/Assets.xcassets/AppIcon.appiconset/icon.png (the iPhone icon, a full square: iOS rounds the corners itself).
The kitten is read from $RHYTHME_DREAM or ~/Documents/rhythme-wt/testflight-main/assets/room/dream (orb-kitten-head.webp).
Run:  python3 scripts/art/make_cat_icon.py     (needs Pillow and numpy)"""
import os, shutil, subprocess, tempfile
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DREAM = os.environ.get("RHYTHME_DREAM") or os.path.expanduser("~/Documents/rhythme-wt/testflight-main/assets/room/dream")
N = 1024

def gradient(top, bottom, light=(250, 242, 255)):
    """Lilac at the top going to blush at the bottom, with a soft light behind where the kitten sits."""
    y = np.linspace(0, 1, N)[:, None, None]
    top, bottom = np.array(top, np.float32), np.array(bottom, np.float32)
    g = top * (1 - y) + bottom * y
    g = np.broadcast_to(g, (N, N, 3)).copy()
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
    r = np.clip(1 - np.hypot(xx - N * 0.5, yy - N * 0.47) / (N * 0.62), 0, 1)[..., None]
    g = g * (1 - 0.5 * r) + np.array(light, np.float32) * (0.5 * r)
    return Image.fromarray(np.clip(g, 0, 255).astype(np.uint8), "RGB")

def kitten(scale):
    k = Image.open(os.path.join(DREAM, "orb-kitten-head.webp")).convert("RGBA")
    k = k.crop(k.getbbox())
    size = round(N * scale)
    k = k.resize((size, round(size * k.height / k.width)), Image.LANCZOS)
    # the painting's white disc has fur spilling past its lower edge; a round, slightly soft mask keeps it a clean disc
    m = Image.new("L", (k.width * 4, k.height * 4), 0)
    ImageDraw.Draw(m).ellipse((k.width * 0.03 * 4, k.height * 0.03 * 4, k.width * 0.97 * 4, k.height * 0.97 * 4), fill=255)
    m = m.resize(k.size, Image.LANCZOS).filter(ImageFilter.GaussianBlur(1.2))
    alpha = np.array(k.getchannel("A"), np.float32) * np.array(m, np.float32) / 255
    k.putalpha(Image.fromarray(alpha.astype(np.uint8)))
    return k

def place(base, layer, dy=0):
    out = base.convert("RGBA")
    shadow = Image.new("RGBA", out.size, (0, 0, 0, 0))
    alpha = layer.getchannel("A").filter(ImageFilter.GaussianBlur(22))
    sh = Image.new("RGBA", layer.size, (90, 60, 130, 0)); sh.putalpha(alpha.point(lambda v: int(v * 0.35)))
    pos = ((N - layer.width) // 2, (N - layer.height) // 2 + dy)
    shadow.alpha_composite(sh, (pos[0], pos[1] + 18))
    out = Image.alpha_composite(out, shadow)
    out.alpha_composite(layer, pos)
    return out

def mac_icon():
    bg = gradient((214, 196, 243), (246, 201, 214))
    scene = place(bg, kitten(0.70), dy=6)
    inset = 100
    mask = Image.new("L", (N * 2, N * 2), 0)
    ImageDraw.Draw(mask).rounded_rectangle((inset * 2, inset * 2, (N - inset) * 2, (N - inset) * 2), radius=int((N - 2 * inset) * 2 * 0.225), fill=255)
    mask = mask.resize((N, N), Image.LANCZOS)
    tile = Image.new("RGBA", (N, N), (0, 0, 0, 0)); tile.paste(scene, (0, 0), mask)
    drop = Image.new("RGBA", (N, N), (60, 40, 90, 0)); drop.putalpha(mask.filter(ImageFilter.GaussianBlur(18)).point(lambda v: int(v * 0.30)))
    out = Image.new("RGBA", (N, N), (0, 0, 0, 0)); out.alpha_composite(drop, (0, 14)); out.alpha_composite(tile)
    return out

def ios_icon():
    return place(gradient((214, 196, 243), (246, 201, 214)), kitten(0.76), dy=6).convert("RGB")

def write_icns(icon, path):
    tmp = tempfile.mkdtemp(suffix=".iconset")
    for base in (16, 32, 128, 256, 512):
        icon.resize((base, base), Image.LANCZOS).save(os.path.join(tmp, f"icon_{base}x{base}.png"))
        icon.resize((base * 2, base * 2), Image.LANCZOS).save(os.path.join(tmp, f"icon_{base}x{base}@2x.png"))
    subprocess.run(["iconutil", "-c", "icns", tmp, "-o", path], check=True)
    shutil.rmtree(tmp)

if __name__ == "__main__":
    mac = mac_icon()
    mac.save(os.path.join(ROOT, "assets/brand/logo-icon-cat.png"))
    write_icns(mac, os.path.join(ROOT, "assets/brand/AppIcon-cat.icns"))
    ios_icon().save(os.path.join(ROOT, "ios/App/Assets.xcassets/AppIcon.appiconset/icon.png"))
    print("wrote the Mac and iPhone cat icons")
