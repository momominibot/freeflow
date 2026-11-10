#!/usr/bin/env python3
"""scripts/art/make_cat_art.py: the cute-cat theme pictures (10 Nov 2026).

Jamie asked for the Rhea avatar and the extremely cute cats from Rhythme as FreeFlow's look. Those pictures already exist
there (cut out, transparent, made with Seedream and Higgsfield in Rhythme), so nothing new is painted here: this script
takes the ones that fit each part of FreeFlow, crops them square and writes assets/art/cats/*.webp.

The Rhythme folder is read from $RHYTHME_DREAM, else ~/Documents/rhythme-wt/testflight-main/assets/room/dream.
Run:  python3 scripts/art/make_cat_art.py        (needs Pillow with WebP; `uv pip install pillow` in any venv)

Square crops (hello ... sleepy) are named like the mascot pictures in assets/art so `Art.image(name)` can swap them in.
The tall full-figure pictures (hero-*) are for the iPhone screens, where a whole Rhea fits above the talk button."""
import os, sys
from PIL import Image

SRC = os.environ.get("RHYTHME_DREAM") or os.path.expanduser("~/Documents/rhythme-wt/testflight-main/assets/room/dream")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "art", "cats")

# name -> (Rhythme picture, crop box as fractions x0, y0, x1, y1)
SQUARE = {
    "hello":     ("avatar-act-hug-cat",       (0, 0, 1, 0.66)),   # Rhea hugging the cream cat: the greeting
    "learning":  ("avatar-act-note",          (0, 0, 1, 0.72)),   # writing in her notebook
    "meetings":  ("avatar-act-listen",        (0, 0, 1, 0.64)),   # headphones on, listening
    "modes":     ("avatar-act-outfit",        (0, 0, 1, 0.74)),   # choosing an outfit: choosing a tone
    "files":     ("avatar-act-hug-mewmew",    (0, 0, 1, 0.66)),   # Mew Mew
    "snippets":  ("avatar-act-hug-catginger", (0, 0, 1, 0.66)),   # the ginger cat
    "words":     ("prop-cat-black",           (0, 0, 1, 1)),      # the black cat with the moon charm
    "sleepy":    ("pet-sleep-catginger",      (0, 0, 1, 1)),      # asleep
    "kitten":    ("orb-kitten-head",          (0, 0, 1, 1)),      # the lavender kitten, round (logo and avatar)
}
FULL = {
    "hero-hug":    "avatar-act-hug-cat",
    "hero-listen": "avatar-act-listen",
    "hero-note":   "avatar-act-note",
    "hero-black":  "avatar-act-hug-catblack",
    "hero-ginger": "avatar-act-hug-catginger",
    "hero-mewmew": "avatar-act-hug-mewmew",
    "hero-sleep":  "avatar-act-bed",
}

def load(name):
    p = os.path.join(SRC, name + ".webp")
    if not os.path.exists(p):
        sys.exit(f"missing {p}  (set RHYTHME_DREAM to the Rhythme assets/room/dream folder)")
    return Image.open(p).convert("RGBA")

def square(im, box, size=384, margin=0.05):
    w, h = im.size
    im = im.crop((round(box[0] * w), round(box[1] * h), round(box[2] * w), round(box[3] * h)))
    if box[3] < 1:
        # a crop cuts the figure at the waist: fade the last tenth out instead of leaving a hard straight edge
        a = im.getchannel("A")
        px = a.load()
        fade = max(4, round(im.height * 0.12))
        for y in range(im.height - fade, im.height):
            k = (im.height - 1 - y) / fade
            for x in range(im.width):
                px[x, y] = round(px[x, y] * k)
        im.putalpha(a)
    bb = im.getbbox()
    if bb: im = im.crop(bb)
    side = max(im.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.alpha_composite(im, ((side - im.width) // 2, (side - im.height) // 2))
    inner = round(size * (1 - 2 * margin))
    canvas = canvas.resize((inner, inner), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(canvas, ((size - inner) // 2, (size - inner) // 2))
    return out

def main():
    os.makedirs(OUT, exist_ok=True)
    for name, (src, box) in SQUARE.items():
        square(load(src), box).save(os.path.join(OUT, name + ".webp"), "WEBP", quality=92, method=6)
    for name, src in FULL.items():
        im = load(src)
        bb = im.getbbox()
        if bb: im = im.crop(bb)
        im.save(os.path.join(OUT, name + ".webp"), "WEBP", quality=92, method=6)
    total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
    print(f"wrote {len(SQUARE) + len(FULL)} pictures to assets/art/cats ({total // 1024} KB)")

if __name__ == "__main__":
    main()
