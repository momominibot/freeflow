#!/usr/bin/env python3
"""scripts/art/make_sunset_art.py: the Sunset colourway's pictures (10 Nov 2026).

Dreamy (the default) shows Rhea and her cats. Sunset is the second colourway: cream, butter yellow, apricot and espresso, and its
pictures are the cats on their own (ginger, cream and black), with no girl in them. They are Rhythme's cat portraits
(prop-cat*, pet-sleep-*), cut out and transparent already. Their collars, bandanas, inner ears and paw pads are lilac, so this
script turns the purple hues to coral and apricot (a hue shift limited to purple, so the pink blush, the fur and the amber eyes
stay as painted) to sit on cream paper.

Writes assets/art/sunset/*.webp with the same names as assets/art/cats, so the app only has to pick a folder.
The Rhythme folder is read from $RHYTHME_DREAM (see make_cat_art.py).
Run:  python3 scripts/art/make_sunset_art.py [--preview sheet.png]      (needs Pillow with WebP and numpy)"""
import os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_cat_art import load, square  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "art", "sunset")

# name -> (Rhythme picture, crop box); every one is a cat on its own
SQUARE = {
    "hello":    ("prop-cat-ginger--bandana", (0, 0, 1, 1)),   # the ginger cat in a bandana: the greeting
    "learning": ("prop-cat-ginger",          (0, 0, 1, 1)),   # looking up, curious
    "meetings": ("prop-cat--bandana",        (0, 0, 1, 1)),   # the cream cat, big eyes: listening
    "modes":    ("prop-cat-ginger--hat",     (0, 0, 1, 1)),   # a party hat: choosing a tone
    "files":    ("prop-cat-black--bandana",  (0, 0, 1, 1)),
    "snippets": ("prop-cat--charm",          (0, 0, 1, 1)),   # the cream cat with the moon charm
    "words":    ("prop-cat-black",           (0, 0, 1, 1)),   # the black cat with the moon charm
    "sleepy":   ("pet-sleep-catginger",      (0, 0, 1, 1)),   # asleep
}
FULL = {  # the iPhone's Talk tab: ready, listening, working, resting
    "hero-hug":    "prop-cat-ginger--bandana",
    "hero-listen": "prop-cat--bandana",
    "hero-note":   "prop-cat-black",
    "hero-sleep":  "pet-sleep-catginger",
}

PURPLE_FROM, PURPLE_TO, FEATHER = 196.0, 348.0, 14.0   # degrees of hue that count as lilac (the black cat's fur is a dark violet-navy)
GAIN = 1.9                                              # lilac gets richer on the way to coral, so it is not taupe
GREEN_FROM, GREEN_TO, GREEN_TARGET = 46.0, 150.0, 36.0  # the pale yellow-green shading under chins and on chests goes to cream


def warm(im, lively=False, keep=None):
    """Turn the lilac in a picture to coral and apricot (dark violet fur to warm espresso) and the green shading to cream;
    everything else stays as painted. lively=True also makes the lilac parts that are not dark (collars, charms) richer and a little
    brighter, so a small collar reads as coral and not as dusty rose.
    keep: optional 0..1 map (same size as the picture) of pixels to leave alone: make_more_cats passes the fur it has repainted
    (smoky, snowy, cocoa), whose blue-grey and white would otherwise be read as lilac and turned coral."""
    rgba = np.array(im.convert("RGBA"))
    hsv = np.array(Image.fromarray(rgba[..., :3], "RGB").convert("HSV"), np.float32)
    hue = hsv[..., 0] * 360.0 / 255.0
    sat = hsv[..., 1] / 255.0
    val = hsv[..., 2] / 255.0
    w = np.clip(np.minimum(hue - PURPLE_FROM, PURPLE_TO - hue) / FEATHER, 0, 1)
    w = w * np.clip(sat / 0.12, 0, 1)                            # grey and white pixels keep their hue
    dark = np.clip((0.5 - val) / 0.15, 0, 1)                     # 1 for dark fur and rim light, 0 for pale lilac
    target = np.clip(12 + 0.25 * (hue - 282), 4, 30) * (1 - dark) + 20 * dark      # lilac 282 -> coral 12; magenta-lilac -> apricot
    delta = (target - hue + 180) % 360 - 180                     # the short way round the colour wheel
    rich = 1 + (GAIN - 1) * np.clip((val - 0.25) / 0.3, 0, 1)    # dark pixels are not made richer: no red glow around the black cat
    cap = np.where(val < 0.55, 0.12 + 0.55 * np.clip(val - 0.1, 0, 0.45), 0.78)
    g = np.clip((hue - GREEN_FROM) / 8, 0, 1) * np.clip((GREEN_TO - hue) / 12, 0, 1) * np.clip((0.55 - sat) / 0.15, 0, 1)
    if keep is not None:
        w, g = w * (1 - keep), g * (1 - keep)
    new_hue = np.where(g > 0, hue + (GREEN_TARGET - hue) * g, (hue + delta * w) % 360.0)
    new_sat = np.where(g > 0, sat * (1 - 0.15 * g), sat + (np.minimum(cap, sat * rich) - sat) * w)
    new_val = val
    if lively:
        pale = w * np.clip((val - 0.42) / 0.08, 0, 1)
        new_sat = np.where(pale > 0, new_sat + (np.minimum(0.74, new_sat * 1.65) - new_sat) * pale, new_sat)
        new_val = np.clip(val + 0.16 * pale, 0, 1)
    hsv[..., 0] = new_hue * 255.0 / 360.0
    hsv[..., 1] = np.clip(new_sat, 0, 1) * 255.0
    hsv[..., 2] = new_val * 255.0
    rgb = np.array(Image.fromarray(np.clip(hsv, 0, 255).astype(np.uint8), "HSV").convert("RGB"))
    return Image.fromarray(np.dstack([rgb, rgba[..., 3]]), "RGBA")


def badge(size=384):
    """The round logo: the ginger cat's face on a soft cream and apricot disc (the Dreamy logo is the lilac kitten orb)."""
    cat = warm(load("prop-cat-ginger--bandana"))
    cat = cat.crop((0, 0, cat.width, round(cat.height * 0.62)))
    bb = cat.getbbox()
    if bb: cat = cat.crop(bb)
    ss = 4
    s = size * ss
    yy, xx = np.mgrid[0:s, 0:s].astype(np.float32)
    r = np.clip(np.hypot(xx - s * 0.5, yy - s * 0.42) / (s * 0.62), 0, 1)[..., None]
    inner, outer = np.array([255, 244, 222], np.float32), np.array([247, 196, 150], np.float32)
    disc = Image.fromarray((inner * (1 - r) + outer * r).astype(np.uint8), "RGB").convert("RGBA")
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).ellipse((s * 0.02, s * 0.02, s * 0.98, s * 0.98), fill=255)
    width = round(s * 0.84)
    cat = cat.resize((width, round(width * cat.height / cat.width)), Image.LANCZOS)
    disc.alpha_composite(cat, ((s - cat.width) // 2, round(s * 0.97) - cat.height))
    disc.putalpha(mask)
    return disc.resize((size, size), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    made = {}
    for name, (src, box) in SQUARE.items():
        made[name] = square(warm(load(src)), box)
    for name, src in FULL.items():
        im = warm(load(src))
        bb = im.getbbox()
        made[name] = im.crop(bb) if bb else im
    made["kitten"] = badge()
    for name, im in made.items():
        im.save(os.path.join(OUT, name + ".webp"), "WEBP", quality=92, method=6)
    total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
    print(f"wrote {len(made)} pictures to assets/art/sunset ({total // 1024} KB)")
    if "--preview" in sys.argv:
        path = sys.argv[sys.argv.index("--preview") + 1]
        names, cell, cols = list(made), 280, 5
        sheet = Image.new("RGB", (cols * cell, ((len(names) + cols - 1) // cols) * cell), (252, 245, 228))
        for i, n in enumerate(names):
            im = made[n].copy(); im.thumbnail((cell - 16, cell - 16))
            sheet.paste(im, ((i % cols) * cell + 8, (i // cols) * cell + 8), im)
        sheet.save(path)


if __name__ == "__main__":
    main()
