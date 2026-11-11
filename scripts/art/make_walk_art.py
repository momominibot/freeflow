#!/usr/bin/env python3
"""scripts/art/make_walk_art.py: the walking cats (10 Nov 2026).

Six cats walk (cream, ginger, black from Rhythme's eight-frame side-view walk cycles, pet-walk-<cat>-side.webp; smoky, snowy and
cocoa are recolours of those, see make_more_cats.py). Each cat becomes one strip: eight cells side by side, every cell the same
size for every cat, so the cell width is the strip's width divided by 8. A cell has PAD clear pixels each side, so a cell cut out of
the strip never shows its neighbour. The cats face right; the app mirrors them to walk left.
Size rule (cat_fit.py): each cat is scaled to the visual mass the ginger cat was drawn at, the eight frames share one box that is
centred in the cell, and the paws stand on the bottom row (the line the app puts on the top edge of a window).
Dreamy writes the strips as Rhythme painted them (lilac collars) to assets/art/cats/walk-<cat>.webp; Sunset writes the same cats
with the lilac turned to coral (make_sunset_art.warm), to assets/art/sunset/walk-<cat>.webp.

The Rhythme folder is read from $RHYTHME_DREAM (see make_cat_art.py).
Run:  python3 scripts/art/make_walk_art.py       (or make_more_cats.py for everything; needs Pillow with WebP and numpy)"""
import os, sys
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_more_cats import CATS, walk_frames       # noqa: E402
from make_sunset_art import warm                   # noqa: E402
from cat_fit import defringe, fit_walk, place      # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "art")
FRAMES, PAD = 8, 3          # PAD: clear pixels each side of a cell, so a cell cut out of the strip never shows its neighbour


def frames(who, sunset):
    out = []
    for im, keep in walk_frames(who):
        im = defringe(im)
        out.append(warm(im, lively=True, keep=keep) if sunset else im)
    return out


def main():
    fitted = {(folder, who): fit_walk(frames(who, folder == "sunset")) for folder in ("cats", "sunset") for who in CATS}
    cw = max(p[0].width for p in fitted.values()) + 2                  # the widest cat, with a pixel of air each side
    ch = max(p[0].height for p in fitted.values())
    total = 0
    for (folder, who), pics in fitted.items():
        os.makedirs(os.path.join(ROOT, folder), exist_ok=True)
        strip = Image.new("RGBA", ((cw + 2 * PAD) * FRAMES, ch), (0, 0, 0, 0))
        for i, p in enumerate(pics):
            strip.alpha_composite(place(p, cw, ch), (i * (cw + 2 * PAD) + PAD, 0))
        path = os.path.join(ROOT, folder, f"walk-{who}.webp")
        strip.save(path, "WEBP", quality=88, method=6)
        total += os.path.getsize(path)
    print(f"wrote {len(fitted)} walking strips ({total // 1024} KB): cell {cw + 2 * PAD} x {ch} px incl. PAD {PAD} each side "
          f"(cat area {cw} x {ch}), strip {(cw + 2 * PAD) * FRAMES} x {ch}")
    return cw + 2 * PAD, ch


if __name__ == "__main__":
    main()
