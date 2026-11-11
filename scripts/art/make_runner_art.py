#!/usr/bin/env python3
"""scripts/art/make_runner_art.py: the little cats that run along the top of the window (10 Nov 2026).

Six cats take turns (cream, ginger, black from Rhythme's paintings; smoky, snowy and cocoa are recolours, see make_more_cats.py),
each as a sitting picture (it hops along in it) and a sleeping one (it curls up when it gets tired).
Size rule (cat_fit.py): each cat is scaled to the visual mass the ginger cat was drawn at, then set into one fixed canvas for every
cat (sitting: W x H, asleep: W x H), centred across, with the lowest pixel of the cat on the bottom row so the app can put its
feet on the line. Drawn scale: 200 px = 38 pt sitting, 300 px = 64 pt wide asleep.
Dreamy uses the pictures as Rhythme painted them (lilac bandanas), written to assets/art/cats/runner-<cat>.webp and
runner-sleep-<cat>.webp; Sunset uses the same cats with the lilac turned to coral (make_sunset_art.warm), written to
assets/art/sunset/.

The Rhythme folder is read from $RHYTHME_DREAM (see make_cat_art.py).
Run:  python3 scripts/art/make_runner_art.py       (or make_more_cats.py for everything; needs Pillow with WebP and numpy)"""
import os, sys
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_more_cats import CATS, sit_picture, sleep_picture    # noqa: E402
from make_sunset_art import warm                               # noqa: E402
from cat_fit import defringe, fit_one, place                   # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "art")


def picture(source, who, pose, sunset):
    im, keep = source(who)
    im = defringe(im)
    return fit_one(warm(im, keep=keep) if sunset else im, pose)


def main():
    sizes, total = {}, 0
    for pose, name, source in (("sit", "runner-{}.webp", sit_picture), ("sleep", "runner-sleep-{}.webp", sleep_picture)):
        fitted = {(folder, who): picture(source, who, pose, folder == "sunset") for folder in ("cats", "sunset") for who in CATS}
        w = max(p.width for p in fitted.values()) + 2                    # the widest cat, with a pixel of air each side
        h = max(p.height for p in fitted.values())
        for (folder, who), pic in fitted.items():
            os.makedirs(os.path.join(ROOT, folder), exist_ok=True)
            path = os.path.join(ROOT, folder, name.format(who))
            place(pic, w, h).save(path, "WEBP", quality=90, method=6)
            total += os.path.getsize(path)
        sizes[pose] = (w, h)
    print(f"wrote {2 * 2 * len(CATS)} runner pictures ({total // 1024} KB): sitting {sizes['sit'][0]} x {sizes['sit'][1]} px, "
          f"sleeping {sizes['sleep'][0]} x {sizes['sleep'][1]} px")
    return sizes


if __name__ == "__main__":
    main()
