#!/usr/bin/env python3
"""scripts/art/make_pet_items.py: the things the cat plays with and eats (10 Nov 2026).

A ball to throw, a bowl to take a fish biscuit from, the fish biscuit, and the little pile the cat leaves behind. All four are
Rhythme's pictures (assets/room/dream/pet-ball, pet-bowl, pet-treat-fish, pet-poop), trimmed and scaled to the size they are drawn at
(about 24, 32, 18 and 22 points, so 3x on a phone). The fish biscuit is cut out of Rhythme's bag-of-biscuits picture: the golden fish
in front of the bag (the bag is cream, the biscuit is golden, so the colour tells them apart).
Dreamy gets them as they are (assets/art/cats/toy-*.webp); Sunset gets the ball and the bowl with the lilac turned to coral
(assets/art/sunset/toy-ball.webp, toy-bowl.webp); the biscuit and the pile are already warm, so Sunset uses the same two.

The Rhythme folder is read from $RHYTHME_DREAM (see make_cat_art.py).
Run:  python3 scripts/art/make_pet_items.py [--preview sheet.png]       (needs Pillow with WebP, numpy)"""
import os, sys
import numpy as np
from PIL import Image, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_cat_art import SRC                       # noqa: E402
from make_sunset_art import warm                   # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "art")


def load(name):
    return Image.open(os.path.join(SRC, name + ".webp")).convert("RGBA")


def trim(im):
    box = im.getchannel("A").point(lambda v: 255 if v > 24 else 0).getbbox()
    return im.crop(box)


def to_width(im, w):
    return im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)


def fish():
    """one golden fish biscuit from the front of the bag"""
    src = load("pet-treat-fish").crop((71, 160, 134, 206))
    a = np.array(src)
    hsv = np.array(Image.fromarray(a[..., :3], "RGB").convert("HSV"), np.float32)
    sat = hsv[..., 1] / 255.0
    val = hsv[..., 2] / 255.0
    solid = ((sat > 0.30) & (val > 0.45)).astype(np.uint8) * 255      # golden and not shadow
    m = Image.fromarray(solid, "L").filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.MinFilter(5))   # close the pale lines inside the fish
    m = m.filter(ImageFilter.GaussianBlur(0.8))
    a[..., 3] = (np.array(m, np.float32) * (a[..., 3] / 255.0)).astype(np.uint8)
    return trim(Image.fromarray(a, "RGBA"))


def items():
    return {
        "toy-ball": to_width(trim(load("pet-ball")), 96),
        "toy-bowl": to_width(trim(load("pet-bowl")), 128),
        "toy-poop": to_width(trim(load("pet-poop")), 88),
        "toy-fish": to_width(fish(), 72),
    }


def main():
    preview = sys.argv[sys.argv.index("--preview") + 1] if "--preview" in sys.argv else None
    made = items()
    total = 0
    shown = []
    for folder, only in (("cats", None), ("sunset", ("toy-ball", "toy-bowl"))):
        out = os.path.join(ROOT, folder)
        os.makedirs(out, exist_ok=True)
        for name, im in made.items():
            if only and name not in only:
                continue
            pic = im if folder == "cats" else warm(im)
            path = os.path.join(out, name + ".webp")
            pic.save(path, "WEBP", quality=90, method=6)
            total += os.path.getsize(path)
            shown.append(pic)
    print(f"wrote {len(shown)} toy pictures ({total // 1024} KB)")
    if preview:
        h = 140
        tiles = [p.resize((round(p.width * h / p.height), h), Image.LANCZOS) for p in shown]
        sheet = Image.new("RGBA", (sum(t.width for t in tiles) + 12 * len(tiles), h), (253, 247, 236, 255))
        x = 0
        for t in tiles:
            sheet.alpha_composite(t, (x, 0))
            x += t.width + 12
        sheet.convert("RGB").save(preview)


if __name__ == "__main__":
    main()
